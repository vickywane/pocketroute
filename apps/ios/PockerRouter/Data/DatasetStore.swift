import CryptoKit
import Foundation
import Observation

struct DatasetCatalog: Decodable, Sendable {
    struct City: Decodable, Sendable {
        let cityId: String
        let displayName: String
        let networks: [Network]
    }
    struct Network: Decodable, Sendable {
        let networkId: String
        let displayName: String
        let manifestPath: String
    }
    let catalogSchemaVersion: Int
    let cities: [City]
}

struct DatasetManifest: Decodable, Sendable {
    let schemaVersion: Int
    let cityId: String
    let networkId: String
    let version: String
    let snapshot: String
    let sizeBytes: Int
    let sha256: String
}

struct DatasetChoice: Identifiable, Hashable, Sendable {
    let cityId: String
    let cityName: String
    let networkId: String
    let networkName: String
    let manifestPath: String
    var id: String { "\(cityId):\(networkId)" }
    var title: String { networkName.isEmpty ? cityName : "\(cityName) · \(networkName)" }
}

/// Owns the offline network: the copy bundled with the app, the last verified
/// download, and refreshing from Firebase Hosting when online.
@MainActor
@Observable
final class DatasetStore {
    enum RefreshResult: Equatable { case updated, upToDate, failed }

    private(set) var graph: NetworkGraph?
    private(set) var choices: [DatasetChoice] = []
    private(set) var selectedID = DatasetStore.defaultChoice.id
    private(set) var isBundled = true
    private(set) var sizeBytes: Int?
    private(set) var isDownloading = false
    private(set) var lastError: String?
    private(set) var didLoad = false

    static let defaultChoice = DatasetChoice(
        cityId: "gb-london", cityName: "London, UK",
        networkId: "london-underground", networkName: "London Underground",
        manifestPath: "/datasets/v1/cities/gb-london/networks/london-underground/manifest.json"
    )

    private let defaults: UserDefaults
    private let baseURL = URL(string: "https://pockerrouter-2026.web.app")!
    private let session: URLSession
    private let datasetsRoot: URL?

    private enum Key {
        static let selected = "pocketroute.dataset.selected"
        static let selectedTitle = "pocketroute.dataset.selectedTitle"
        static let selectedManifest = "pocketroute.dataset.selectedManifest"
        static let activeRelativePath = "pocketroute.dataset.activeRelativePath"
        static let activeChecksum = "pocketroute.dataset.activeChecksum"
        static let legacyActiveFile = "pocketroute.dataset.activeFile"
    }

    init(defaults: UserDefaults = .standard, datasetsRoot: URL? = nil) {
        self.defaults = defaults
        let configuration = URLSessionConfiguration.default
        // Short timeouts: the app is often used with patchy signal.
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        self.datasetsRoot = datasetsRoot ?? (try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "PocketRoute/Datasets", directoryHint: .isDirectory))
        selectedID = defaults.string(forKey: Key.selected) ?? selectedID
    }

    var selectedTitle: String {
        choices.first(where: { $0.id == selectedID })?.title
            ?? defaults.string(forKey: Key.selectedTitle)
            ?? Self.defaultChoice.title
    }

    var savedDate: Date? { graph?.generatedAt }

    /// Load the last verified download, or the bundled map. Never touches the network.
    func loadLocal() async {
        guard !didLoad else { return }
        migrateLegacyPath()
        if let saved = await loadSaved() {
            apply(saved.graph, bundled: false, size: saved.size)
        } else if let bundled = await loadBundled() {
            apply(bundled.graph, bundled: true, size: bundled.size)
        }
        didLoad = true
        if choices.isEmpty { choices = [fallbackChoice()] }
    }

    /// Check Hosting for a newer map. Safe to call again after a failure.
    @discardableResult
    func refresh() async -> RefreshResult {
        await loadLocal()
        guard !isDownloading else { return .failed }
        isDownloading = true
        lastError = nil
        defer { isDownloading = false }
        do {
            let catalog: DatasetCatalog = try await fetchJSON(resourceURL("/datasets/v1/catalog.json"))
            guard catalog.catalogSchemaVersion == 1 else { throw DownloadError.unsupported }
            let published = catalog.cities.flatMap { city in
                city.networks.map {
                    DatasetChoice(cityId: city.cityId, cityName: city.displayName, networkId: $0.networkId,
                                  networkName: $0.displayName, manifestPath: $0.manifestPath)
                }
            }
            if !published.isEmpty { choices = published }
            guard let choice = published.first(where: { $0.id == selectedID }) ?? published.first else {
                throw DownloadError.noDatasets
            }
            return try await download(choice)
        } catch {
            lastError = Self.describe(error)
            return .failed
        }
    }

    func select(_ id: String) async {
        guard id != selectedID, let choice = choices.first(where: { $0.id == id }), !isDownloading else { return }
        isDownloading = true
        lastError = nil
        defer { isDownloading = false }
        do { _ = try await download(choice) } catch { lastError = Self.describe(error) }
    }

    // MARK: - Download

    private func download(_ choice: DatasetChoice) async throws -> RefreshResult {
        guard isSafePathSegment(choice.cityId), isSafePathSegment(choice.networkId) else { throw DownloadError.invalidPath }
        let manifest: DatasetManifest = try await fetchJSON(resourceURL(choice.manifestPath))
        guard manifest.schemaVersion == 1, manifest.cityId == choice.cityId, manifest.networkId == choice.networkId else {
            throw DownloadError.mismatch
        }
        guard isSafePathSegment(manifest.version) else { throw DownloadError.invalidPath }
        if choice.id == selectedID, graph?.version == manifest.version {
            remember(choice)
            return .upToDate
        }

        let (data, response) = try await session.data(from: resourceURL(manifest.snapshot))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadError.badResponse }
        guard data.count == manifest.sizeBytes else { throw DownloadError.sizeMismatch }
        let digest = Self.sha256(data)
        guard digest.caseInsensitiveCompare(manifest.sha256) == .orderedSame else { throw DownloadError.checksumMismatch }
        let snapshot = try await Self.decode(data)
        guard snapshot.schemaVersion == 1, snapshot.networkId == choice.networkId, snapshot.version == manifest.version,
              !snapshot.stations.isEmpty else { throw DownloadError.mismatch }

        guard let root = datasetsRoot else { throw DownloadError.storage }
        let relative = "\(choice.cityId)/\(choice.networkId)/\(manifest.version)/network.json"
        let destination = root.appending(path: relative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)

        // Activate only after the file is safely written.
        defaults.set(relative, forKey: Key.activeRelativePath)
        defaults.set(digest, forKey: Key.activeChecksum)
        remember(choice)
        selectedID = choice.id
        apply(NetworkGraph(snapshot: snapshot), bundled: false, size: data.count)
        pruneVersions(keeping: destination.deletingLastPathComponent())
        return .updated
    }

    private func remember(_ choice: DatasetChoice) {
        defaults.set(choice.id, forKey: Key.selected)
        defaults.set(choice.title, forKey: Key.selectedTitle)
        defaults.set(choice.manifestPath, forKey: Key.selectedManifest)
    }

    /// Delete every saved version except the active one.
    private func pruneVersions(keeping active: URL) {
        guard let root = datasetsRoot else { return }
        let fm = FileManager.default
        let keep = active.standardizedFileURL.path
        guard let cities = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for city in cities {
            for network in (try? fm.contentsOfDirectory(at: city, includingPropertiesForKeys: nil)) ?? [] {
                for version in (try? fm.contentsOfDirectory(at: network, includingPropertiesForKeys: nil)) ?? []
                where version.standardizedFileURL.path != keep {
                    try? fm.removeItem(at: version)
                }
            }
        }
    }

    // MARK: - Local loading

    private func loadSaved() async -> (graph: NetworkGraph, size: Int)? {
        guard let root = datasetsRoot,
              let relative = defaults.string(forKey: Key.activeRelativePath),
              let expected = defaults.string(forKey: Key.activeChecksum),
              let data = try? Data(contentsOf: root.appending(path: relative)),
              Self.sha256(data) == expected,
              let snapshot = try? await Self.decode(data),
              snapshot.schemaVersion == 1 else { return nil }
        return (NetworkGraph(snapshot: snapshot), data.count)
    }

    private func loadBundled() async -> (graph: NetworkGraph, size: Int)? {
        guard let url = Bundle.main.url(forResource: "london-underground-network-v1", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let snapshot = try? await Self.decode(data) else { return nil }
        return (NetworkGraph(snapshot: snapshot), data.count)
    }

    /// Earlier builds stored an absolute path, which breaks when iOS moves the
    /// app container on update. Convert it to a path relative to Datasets/.
    private func migrateLegacyPath() {
        guard defaults.string(forKey: Key.activeRelativePath) == nil,
              let legacy = defaults.string(forKey: Key.legacyActiveFile) else { return }
        let parts = legacy.split(separator: "/").map(String.init)
        if parts.count >= 4 { defaults.set(parts.suffix(4).joined(separator: "/"), forKey: Key.activeRelativePath) }
        defaults.removeObject(forKey: Key.legacyActiveFile)
    }

    private func apply(_ graph: NetworkGraph, bundled: Bool, size: Int) {
        self.graph = graph
        isBundled = bundled
        sizeBytes = size
    }

    private func fallbackChoice() -> DatasetChoice {
        let parts = selectedID.split(separator: ":").map(String.init)
        guard parts.count == 2 else { return Self.defaultChoice }
        return DatasetChoice(
            cityId: parts[0], cityName: defaults.string(forKey: Key.selectedTitle) ?? Self.defaultChoice.cityName,
            networkId: parts[1], networkName: "",
            manifestPath: defaults.string(forKey: Key.selectedManifest) ?? Self.defaultChoice.manifestPath
        )
    }

    // MARK: - Helpers

    private func fetchJSON<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadError.badResponse }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func resourceURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/datasets/v1/"), !path.contains(".."),
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.host == baseURL.host else { throw DownloadError.invalidPath }
        return url
    }

    private func isSafePathSegment(_ value: String) -> Bool {
        value != "." && value != ".." && value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    @concurrent nonisolated private static func decode(_ data: Data) async throws -> NetworkSnapshot {
        try JSONDecoder().decode(NetworkSnapshot.self, from: data)
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? DownloadError { return error.message }
        if (error as? URLError)?.code == .notConnectedToInternet { return "No connection. Keeping the saved map." }
        return "Couldn’t reach the map server. Keeping the saved map."
    }

    private enum DownloadError: Error {
        case badResponse, unsupported, noDatasets, mismatch, sizeMismatch, checksumMismatch, invalidPath, storage

        var message: String {
            switch self {
            case .noDatasets: "No maps are published yet."
            case .sizeMismatch, .checksumMismatch: "The download was incomplete. Keeping the saved map."
            case .unsupported, .mismatch: "This map version isn’t supported by this app version."
            default: "Couldn’t download the map. Keeping the saved map."
            }
        }
    }
}
