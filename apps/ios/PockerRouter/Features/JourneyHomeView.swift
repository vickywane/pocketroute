import CoreLocation
import AVFAudio
import CryptoKit
import Speech
import SwiftUI

private enum PocketPalette {
    static let ink = Color(red: 34/255, green: 36/255, blue: 40/255)
    static let secondary = Color(red: 80/255, green: 87/255, blue: 101/255)
    static let accent = Color(red: 14/255, green: 94/255, blue: 88/255)
    static let canvas = Color(red: 241/255, green: 244/255, blue: 250/255)
    static let line = Color(red: 213/255, green: 219/255, blue: 230/255)
}

private struct RouteChoice: Identifiable {
    let id = UUID()
    let title: String
    let lineNames: [String]
    let detail: String
    let minutes: Int
    let badge: String?
    let steps: [String]
}

@MainActor
private final class StationLocator: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published var message = "Use your last known station underground"
    @Published var suggestion: String?
    var stations = TubeStations.all
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func locate() {
        guard CLLocationManager.locationServicesEnabled() else {
            message = "Location is unavailable. Choose your station below."
            return
        }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
            message = "Checking nearby stations…"
        case .notDetermined:
            message = "Allow location access to suggest a nearby station."
            manager.requestWhenInUseAuthorization()
        default:
            message = "Location access is off. Choose your station below."
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
            message = "Checking nearby stations…"
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        message = "Couldn’t get a fix. GPS often drops underground; choose your station."
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let point = locations.first else { return }
        let nearest = stations.min { a, b in
            point.distance(from: CLLocation(latitude: a.lat, longitude: a.lon)) < point.distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
        }
        guard let nearest, point.distance(from: CLLocation(latitude: nearest.lat, longitude: nearest.lon)) < 2_000 else {
            message = "You’re outside the available station area. Choose a station manually."
            return
        }
        suggestion = nearest.name
        message = "Nearby: \(nearest.name) · confirm station"
    }
}

private struct DatasetCatalog: Decodable {
    struct City: Decodable {
        let cityId: String
        let displayName: String
        let networks: [Network]
    }
    struct Network: Decodable {
        let networkId: String
        let displayName: String
        let manifestPath: String
    }
    let catalogSchemaVersion: Int
    let cities: [City]
}

private struct DatasetManifest: Decodable {
    let schemaVersion: Int
    let cityId: String
    let networkId: String
    let version: String
    let snapshot: String
    let sizeBytes: Int
    let sha256: String
}

private struct NetworkSnapshot: Decodable {
    struct Station: Decodable {
        let id: String
        let name: String
        let latitude: Double?
        let longitude: Double?
    }
    let schemaVersion: Int
    let networkId: String
    let version: String
    let stations: [Station]
}

private struct DatasetChoice: Identifiable, Hashable {
    let cityId: String
    let cityName: String
    let networkId: String
    let networkName: String
    let manifestPath: String
    var id: String { "\(cityId):\(networkId)" }
    var title: String { networkName.isEmpty ? cityName : "\(cityName) · \(networkName)" }
}

@MainActor
private final class DatasetDownloadStore: ObservableObject {
    @Published private(set) var choices: [DatasetChoice] = []
    @Published private(set) var selectedID = "gb-london:london-underground"
    @Published private(set) var activeVersion = ""
    @Published private(set) var stations: [TubeStation] = TubeStations.all
    @Published private(set) var stationNames: [String] = TubeStations.all.map(\.name)
    @Published private(set) var status = "Loading saved map…"
    @Published private(set) var isDownloading = false
    private var didStart = false
    var selectedTitle: String { choices.first(where: { $0.id == selectedID })?.title ?? defaults.string(forKey: selectedTitleKey) ?? "London Underground" }

    private let defaults = UserDefaults.standard
    private let baseURL = URL(string: "https://pockerrouter-2026.web.app")!
    private let selectedKey = "pocketroute.dataset.selected"
    private let selectedTitleKey = "pocketroute.dataset.selectedTitle"
    private let selectedManifestKey = "pocketroute.dataset.selectedManifest"
    private let activeFileKey = "pocketroute.dataset.activeFile"
    private let activeChecksumKey = "pocketroute.dataset.activeChecksum"
    private var persistedSnapshotLoaded = false

    func loadBundledOnly() {
        loadBundledSnapshot()
        status = "Using the map that came with this app"
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        loadBundledSnapshot()
        selectedID = defaults.string(forKey: selectedKey) ?? selectedID
        loadSavedSnapshot()
        do {
            let (data, response) = try await URLSession.shared.data(from: resourceURL("/datasets/v1/catalog.json"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadError.badResponse }
            let catalog = try JSONDecoder().decode(DatasetCatalog.self, from: data)
            guard catalog.catalogSchemaVersion == 1 else { throw DownloadError.unsupportedCatalog }
            choices = catalog.cities.flatMap { city in
                city.networks.map { network in
                    DatasetChoice(cityId: city.cityId, cityName: city.displayName, networkId: network.networkId, networkName: network.displayName, manifestPath: network.manifestPath)
                }
            }
            if let activeChoice = choices.first(where: { $0.id == selectedID }) {
                await download(activeChoice)
            } else if let first = choices.first {
                await download(first)
            } else {
                status = "No map datasets are published yet."
            }
        } catch {
            if choices.isEmpty {
                let parts = selectedID.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                let cityId = parts.count == 2 ? parts[0] : "gb-london"
                let networkId = parts.count == 2 ? parts[1] : "london-underground"
                choices = [DatasetChoice(cityId: cityId, cityName: defaults.string(forKey: selectedTitleKey) ?? "London, UK · London Underground", networkId: networkId, networkName: "", manifestPath: defaults.string(forKey: selectedManifestKey) ?? "/datasets/v1/cities/gb-london/networks/london-underground/manifest.json")]
            }
            status = "Using saved map · update unavailable"
        }
    }

    func select(_ id: String) async {
        guard let choice = choices.first(where: { $0.id == id }), id != selectedID else { return }
        await download(choice)
    }

    private func download(_ choice: DatasetChoice) async {
        guard !isDownloading else { return }
        isDownloading = true
        status = "Downloading \(choice.cityName)…"
        defer { isDownloading = false }
        do {
            guard isSafePathSegment(choice.cityId), isSafePathSegment(choice.networkId) else { throw DownloadError.invalidPath }
            let manifestURL = try resourceURL(choice.manifestPath)
            let (manifestData, manifestResponse) = try await URLSession.shared.data(from: manifestURL)
            guard (manifestResponse as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadError.badResponse }
            let manifest = try JSONDecoder().decode(DatasetManifest.self, from: manifestData)
            guard manifest.schemaVersion == 1, manifest.cityId == choice.cityId, manifest.networkId == choice.networkId else { throw DownloadError.datasetMismatch }
            guard isSafePathSegment(manifest.version) else { throw DownloadError.invalidPath }
            if persistedSnapshotLoaded, selectedID == choice.id, activeVersion == manifest.version {
                status = "Saved offline · \(stationNames.count) stations · v\(manifest.version)"
                return
            }
            let snapshotURL = try resourceURL(manifest.snapshot)
            let (snapshotData, snapshotResponse) = try await URLSession.shared.data(from: snapshotURL)
            guard (snapshotResponse as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadError.badResponse }
            guard snapshotData.count == manifest.sizeBytes else { throw DownloadError.sizeMismatch }
            let digest = SHA256.hash(data: snapshotData).map { String(format: "%02x", $0) }.joined()
            guard digest.caseInsensitiveCompare(manifest.sha256) == .orderedSame else { throw DownloadError.checksumMismatch }
            let snapshot = try JSONDecoder().decode(NetworkSnapshot.self, from: snapshotData)
            guard snapshot.schemaVersion == 1, snapshot.networkId == choice.networkId, snapshot.version == manifest.version, !snapshot.stations.isEmpty else { throw DownloadError.datasetMismatch }

            let directory = try datasetDirectory()
                .appending(path: choice.cityId)
                .appending(path: choice.networkId)
                .appending(path: manifest.version, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: "network.json")
            try snapshotData.write(to: destination, options: .atomic)

            apply(snapshot, statusText: "Saved offline · \(snapshot.stations.count) stations · v\(manifest.version)")
            selectedID = choice.id
            defaults.set(choice.id, forKey: selectedKey)
            defaults.set(choice.title, forKey: selectedTitleKey)
            defaults.set(choice.manifestPath, forKey: selectedManifestKey)
            defaults.set(destination.path, forKey: activeFileKey)
            defaults.set(digest, forKey: activeChecksumKey)
            persistedSnapshotLoaded = true
            status = "Saved offline · \(snapshot.stations.count) stations · v\(manifest.version)"
        } catch {
            status = "Couldn’t download \(choice.cityName). Keeping the saved map."
        }
    }

    private func resourceURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/datasets/v1/") else { throw DownloadError.invalidPath }
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw DownloadError.invalidPath }
        guard url.host == baseURL.host else { throw DownloadError.invalidPath }
        return url
    }

    private func isSafePathSegment(_ value: String) -> Bool {
        value != "." && value != ".." && value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    private func datasetDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appending(path: "PocketRoute/Datasets", directoryHint: .isDirectory)
    }

    private func loadBundledSnapshot() {
        guard let url = Bundle.main.url(forResource: "london-underground-network-v1", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(NetworkSnapshot.self, from: data) else { return }
        apply(snapshot, statusText: "Bundled map · \(snapshot.stations.count) stations · v\(snapshot.version)")
    }

    private func loadSavedSnapshot() {
        guard let path = defaults.string(forKey: activeFileKey), let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let expectedDigest = defaults.string(forKey: activeChecksumKey),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedDigest,
              let snapshot = try? JSONDecoder().decode(NetworkSnapshot.self, from: data) else { return }
        apply(snapshot, statusText: "Saved offline · \(snapshot.stations.count) stations · v\(snapshot.version)")
        persistedSnapshotLoaded = true
    }

    private func apply(_ snapshot: NetworkSnapshot, statusText: String) {
        stationNames = snapshot.stations.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        stations = snapshot.stations.compactMap { item in
            guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
            return TubeStation(name: item.name, lat: latitude, lon: longitude)
        }
        activeVersion = snapshot.version
        status = statusText
    }

    private enum DownloadError: Error {
        case badResponse, unsupportedCatalog, datasetMismatch, sizeMismatch, checksumMismatch, invalidPath
    }
}

@MainActor
private final class VoiceCapture: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() {
        if isRecording { stop(); return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else { self.transcript = "Speech recognition permission is needed to use voice input."; return }
                self.start()
            }
        }
    }

    func begin() { transcript = ""; toggle() }
    func finish() { if isRecording { stop() } }
    func cancel() { stop(); transcript = "" }

    private func start() {
        guard let recognizer, recognizer.isAvailable else { transcript = "Voice input is unavailable right now."; return }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            recognitionRequest.shouldReportPartialResults = true
            guard recognizer.supportsOnDeviceRecognition else { transcript = "Offline speech recognition isn’t available on this iPhone."; return }
            recognitionRequest.requiresOnDeviceRecognition = true
            request = recognitionRequest
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in recognitionRequest.append(buffer) }
            engine.prepare()
            try engine.start()
            transcript = "Listening…"
            isRecording = true
            task = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if error != nil || result?.isFinal == true { self.stop() }
                }
            }
        } catch { transcript = "Couldn’t start voice input. Try again."; stop() }
    }

    private func stop() {
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio()
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private struct TubeStation {
    let name: String
    let lat: Double
    let lon: Double
}

private enum TubeStations {
    static let all: [TubeStation] = [
        .init(name: "Kentish Town", lat: 51.5507, lon: -0.1402), .init(name: "Camden Town", lat: 51.5392, lon: -0.1426),
        .init(name: "Euston", lat: 51.5282, lon: -0.1337), .init(name: "King’s Cross St Pancras", lat: 51.5308, lon: -0.1238),
        .init(name: "Angel", lat: 51.5322, lon: -0.1058), .init(name: "Warren Street", lat: 51.5247, lon: -0.1384),
        .init(name: "Oxford Circus", lat: 51.5152, lon: -0.1419), .init(name: "Bank", lat: 51.5133, lon: -0.0886),
        .init(name: "Waterloo", lat: 51.5036, lon: -0.1143), .init(name: "Victoria", lat: 51.4965, lon: -0.1447),
        .init(name: "Tottenham Court Road", lat: 51.5165, lon: -0.1309), .init(name: "Leicester Square", lat: 51.5113, lon: -0.1281),
        .init(name: "Goodge Street", lat: 51.5206, lon: -0.1347), .init(name: "Mornington Crescent", lat: 51.5342, lon: -0.1387),
        .init(name: "London Bridge", lat: 51.5055, lon: -0.0860), .init(name: "Piccadilly Circus", lat: 51.5098, lon: -0.1342)
    ]
}

struct JourneyHomeView: View {
    @StateObject private var locator = StationLocator()
    @StateObject private var voice = VoiceCapture()
    @StateObject private var datasetStore = DatasetDownloadStore()
    @State private var station = "Camden Town"
    @State private var destination = "Warren Street"
    @State private var disruptions: Set<String> = []
    @State private var selectedRoute: RouteChoice?
    @State private var showingResults = false
    @State private var routeStarted = false
    @State private var showingStationPicker = false
    @State private var showingOfflineInfo = false
    @State private var pickingOrigin = true
    @State private var search = ""
    @State private var pendingStation = "Camden Town"
    @State private var browseAllStations = false
    @State private var followUp = ""
    @State private var tab = 0
    @State private var stepIndex = 0
    @State private var stepFreeOnly = false
    @State private var suggestWalking = true
    @State private var showingAccountMessage = false
    @State private var showingVoiceSheet = false
    @State private var disruptionsBeforeVoice: Set<String> = []
    @AppStorage("pocketroute.onboarding.complete") private var onboardingComplete = false
    @State private var onboardingStep = 0
    @State private var keepMapUpdated = true
    @State private var useCloudAI = false
    @State private var downloadingOnboardingMap = false
    @State private var onboardingMapDownloadFailed = false
    @State private var hasFollowedUp = false
    @State private var lastFollowUpText = ""
    @State private var showEarlierRoutes = false
    @State private var showingAccountSheet = false
    @State private var accountIntent = "Create your account"
    @State private var showingCityPicker = false
    @State private var citySearch = ""

    private let routes: [RouteChoice] = [
        .init(title: "Charing Cross branch", lineNames: ["Northern"], detail: "3 stops · change platforms here", minutes: 7, badge: "Fastest", steps: ["Change to the Charing Cross branch at Camden Town", "Stay on through Mornington Crescent to Euston", "Change to the Victoria line for one stop to Warren Street"]),
        .init(title: "Via Euston and Victoria line", lineNames: ["Northern", "Victoria"], detail: "2 stops · change at Euston", minutes: 9, badge: nil, steps: ["Stay on the Northern line to Euston", "Change to the Victoria line southbound", "Get off at Warren Street"]),
        .init(title: "Walk instead", lineNames: ["Walk"], detail: "2.1 km · leave the station", minutes: 27, badge: nil, steps: ["Leave Camden Town station", "Walk south toward Warren Street", "Arrive at Warren Street"])
    ]

    private var disruptionSummary: String {
        disruptions.isEmpty ? "My journey has changed." : "Reported: \(disruptions.sorted().joined(separator: ", "))."
    }

    var body: some View {
        Group {
            if !onboardingComplete { onboardingScreen }
            else if tab == 1 { savedScreen }
            else if tab == 2 { settingsScreen }
            else if routeStarted, let selectedRoute { guidanceScreen(selectedRoute) }
            else if showingResults {
                if hasFollowedUp { followUpScreen }
                else { resultsScreen }
            }
            else { captureScreen }
        }
        .safeAreaInset(edge: .bottom) { if onboardingComplete && !showingResults && !routeStarted { tabBar } }
        .background(PocketPalette.canvas.ignoresSafeArea())
        .preferredColorScheme(.light)
        .sheet(isPresented: $showingStationPicker) { stationPicker(title: pickingOrigin ? "Where are you?" : "Where are you going?", isOrigin: pickingOrigin) }
        .sheet(isPresented: $showingOfflineInfo) { offlineInfoSheet }
        .sheet(isPresented: $showingAccountSheet) { accountSheet }
        .sheet(isPresented: $showingCityPicker) { cityPickerSheet }
        .onChange(of: voice.transcript) { _, transcript in applyVoiceReport(transcript) }
        .onChange(of: locator.suggestion) { _, suggestion in
            guard let suggestion else { return }
            station = suggestion
            pendingStation = suggestion
        }
        .onChange(of: datasetStore.selectedID) { _, _ in
            locator.stations = datasetStore.stations
            if !datasetStore.stationNames.contains(station), let first = datasetStore.stationNames.first { station = first }
            if !datasetStore.stationNames.contains(destination), let next = datasetStore.stationNames.dropFirst().first { destination = next }
        }
        .task {
            if onboardingComplete { await datasetStore.start() }
            else { datasetStore.loadBundledOnly() }
            locator.stations = datasetStore.stations
        }
        .alert("Account setup", isPresented: $showingAccountMessage) { Button("Got it", role: .cancel) {} } message: { Text("Account sign-in and backup aren’t connected in this prototype.") }
    }

    private var onboardingScreen: some View {
        Group {
            if onboardingStep == 0 { welcomeScreen }
            else { setupScreen }
        }
        .background(PocketPalette.canvas.ignoresSafeArea())
    }

    private var welcomeScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 64, height: 64).background(PocketPalette.accent, in: RoundedRectangle(cornerRadius: 16))
                        Text("When your travel plan breaks, find another way.")
                            .font(.system(size: 29, weight: .semibold)).tracking(-0.4).foregroundStyle(PocketPalette.ink)
                        Text("Works deep underground with no signal. Your Tube map, AI and voice all live on this iPhone.")
                            .font(.system(size: 17)).lineSpacing(3).foregroundStyle(PocketPalette.secondary)
                    }
                    VStack(spacing: 16) {
                        onboardingFeature("map", title: "Saved Tube map", detail: "Every station, line and walking link")
                        onboardingFeature("sparkles", title: "On-device AI", detail: "Describe what happened in plain English")
                        onboardingFeature("mic", title: "Voice that works offline", detail: "Speak instead of typing on a busy train")
                    }
                }.padding(24).padding(.top, 24)
            }
            VStack(spacing: 12) {
                onboardingButton("Start as a guest", primary: true) { onboardingStep = 1 }
                onboardingButton("Create an account", primary: false) { accountIntent = "Create your account"; showingAccountSheet = true }
                HStack(spacing: 4) {
                    Text("Already have an account?").foregroundStyle(PocketPalette.secondary)
                    Button("Sign in") { accountIntent = "Sign in"; showingAccountSheet = true }.fontWeight(.semibold).foregroundStyle(PocketPalette.accent)
                }.font(.system(size: 16)).frame(maxWidth: .infinity).padding(.top, 4)
            }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 28)
        }
    }

    private var setupScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if onboardingStep < 4 { setupProgress }
                    else {
                        HStack { Text("Set-up complete").font(.system(size: 14, weight: .semibold)).foregroundStyle(PocketPalette.secondary); Spacer(); connectivityPillLabel }
                    }
                    Group {
                        switch onboardingStep {
                        case 1: mapSetupContent
                        case 2: aiSetupContent
                        case 3: locationSetupContent
                        default: readySetupContent
                        }
                    }
                }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 24)
            }
            VStack(spacing: 8) {
                onboardingButton(setupPrimaryTitle, primary: true, action: advanceSetup)
                if onboardingStep < 4 {
                    Button(onboardingStep == 3 ? "Not now" : onboardingMapDownloadFailed ? "Continue with the older map" : "Not now") {
                        if onboardingStep == 3 { onboardingStep = 4 }
                        else if onboardingStep == 1 { onboardingMapDownloadFailed = false; onboardingStep = 2 }
                        else { advanceSetup() }
                    }.font(.system(size: 16, weight: .medium)).foregroundStyle(PocketPalette.accent).frame(maxWidth: .infinity, minHeight: 48)
                }
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 20)
                .background(PocketPalette.canvas)
        }
    }

    private var setupPrimaryTitle: String {
        switch onboardingStep {
        case 1: return downloadingOnboardingMap ? "Saving the Tube map…" : onboardingMapDownloadFailed ? "Try again" : "Download map"
        case 2: return "Continue"
        case 3: return "Allow location"
        default: return "Start using PocketRoute"
        }
    }

    private var setupProgress: some View {
        HStack(spacing: 12) {
            Text("\(onboardingStep == 3 ? 3 : onboardingStep) of 3").font(.system(size: 14, weight: .semibold)).foregroundStyle(PocketPalette.secondary)
            HStack(spacing: 6) { ForEach(0..<3, id: \.self) { i in Capsule().fill(i < onboardingStep ? PocketPalette.accent : PocketPalette.line).frame(height: 6) } }
            Image(systemName: "wifi").font(.system(size: 16, weight: .semibold)).foregroundStyle(PocketPalette.accent).frame(width: 40, height: 40).background(Color(red: 225/255, green: 239/255, blue: 227/255), in: Circle())
        }
    }

    private var mapSetupContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(downloadingOnboardingMap ? "Saving the Tube map…" : onboardingMapDownloadFailed ? "Download paused — no signal" : "Save the Tube map to this iPhone")
                .font(.system(size: 29, weight: .semibold)).tracking(-0.4).foregroundStyle(PocketPalette.ink)
            Text(downloadingOnboardingMap || onboardingMapDownloadFailed ? datasetStore.status : "PocketRoute uses a map stored on your phone to find another way when you lose signal.").font(.system(size: 17)).lineSpacing(3).foregroundStyle(PocketPalette.secondary)
            Button { showingCityPicker = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "globe.europe.africa.fill").foregroundStyle(PocketPalette.accent).frame(width: 40, height: 40).background(Color(red: 226/255, green: 238/255, blue: 236/255), in: Circle())
                VStack(alignment: .leading, spacing: 2) { Text("City").font(.system(size: 14)).foregroundStyle(PocketPalette.secondary); Text(datasetStore.selectedTitle).font(.system(size: 17, weight: .semibold)).foregroundStyle(PocketPalette.ink) }
                Spacer(); Image(systemName: "chevron.down").foregroundStyle(PocketPalette.secondary)
            }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain)
            VStack(spacing: 0) {
                onboardingSetupRow("tram.fill", title: "Every station, line and branch", detail: "\(datasetStore.stationNames.count) stations in the saved map")
                Divider().padding(.leading, 68)
                onboardingSetupRow("arrow.left.arrow.right", title: "Interchanges", detail: "Where to change and how long it takes")
                Divider().padding(.leading, 68)
                HStack(spacing: 12) {
                    Image(systemName: "arrow.clockwise").foregroundStyle(PocketPalette.accent).frame(width: 40, height: 40).background(Color(red: 226/255, green: 238/255, blue: 236/255), in: Circle())
                    VStack(alignment: .leading, spacing: 3) { Text("Keep it up to date").font(.system(size: 16, weight: .semibold)); Text("Updates in the background when you’re online").font(.system(size: 13)).foregroundStyle(PocketPalette.secondary) }
                    Spacer(); Toggle("Keep map updated", isOn: $keepMapUpdated).labelsHidden().tint(PocketPalette.accent)
                }.padding(12).frame(minHeight: 70)
            }.background(.white, in: RoundedRectangle(cornerRadius: 16))
            if downloadingOnboardingMap { ProgressView().tint(PocketPalette.accent).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    private var aiSetupContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            onboardingSetupRow("sparkles", title: "Describe what happened", detail: "AI can understand a plain-English report", prominent: true)
            Text("AI & voice work on this iPhone, even when you’re offline.").font(.system(size: 17)).lineSpacing(3).foregroundStyle(PocketPalette.secondary)
            VStack(spacing: 0) {
                onboardingSetupRow("sparkles", title: "On-device AI", detail: "Private and available without signal")
                Divider().padding(.leading, 68)
                HStack(spacing: 12) {
                    Image(systemName: "cloud").foregroundStyle(PocketPalette.accent).frame(width: 40, height: 40).background(Color(red: 226/255, green: 238/255, blue: 236/255), in: Circle())
                    VStack(alignment: .leading, spacing: 3) { Text("Cloud AI when online").font(.system(size: 16, weight: .semibold)); Text("Faster with signal. Sends your report to a service.").font(.system(size: 13)).foregroundStyle(PocketPalette.secondary) }
                    Spacer(); Toggle("Cloud AI", isOn: $useCloudAI).labelsHidden().tint(PocketPalette.accent)
                }.padding(12).frame(minHeight: 70)
                Divider().padding(.leading, 68)
                onboardingSetupRow("mic", title: "Voice input", detail: "Speech is recognised on this iPhone")
            }.background(.white, in: RoundedRectangle(cornerRadius: 16))
            Label("You can change these choices later in Settings.", systemImage: "info.circle").font(.system(size: 13)).foregroundStyle(PocketPalette.secondary)
        }
    }

    private var locationSetupContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "location.fill").font(.system(size: 24)).foregroundStyle(PocketPalette.accent).frame(width: 56, height: 56).background(Color(red: 226/255, green: 238/255, blue: 236/255), in: Circle())
            Text("Remember the last station you passed")
                .font(.system(size: 29, weight: .semibold)).tracking(-0.4).foregroundStyle(PocketPalette.ink)
            Text("GPS doesn’t work underground. With permission, PocketRoute remembers the last station where your phone had signal and suggests nearby stations.").font(.system(size: 17)).lineSpacing(3).foregroundStyle(PocketPalette.secondary)
            VStack(spacing: 0) {
                onboardingSetupRow("lock.fill", title: "Stays on this iPhone")
                Divider().padding(.leading, 68)
                onboardingSetupRow("clock", title: "Only while the app is open")
                Divider().padding(.leading, 68)
                onboardingSetupRow("flag.fill", title: "You can always pick your station by hand")
            }.background(.white, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var readySetupContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "checkmark").font(.system(size: 24, weight: .bold)).foregroundStyle(.white).frame(width: 56, height: 56).background(PocketPalette.accent, in: Circle())
            Text("You’re ready for the Tube").font(.system(size: 29, weight: .semibold)).tracking(-0.4).foregroundStyle(PocketPalette.ink)
            Text("Your map is saved. Core features work without a signal.").font(.system(size: 17)).foregroundStyle(PocketPalette.secondary)
            VStack(spacing: 0) {
                onboardingSetupRow("map", title: "London Tube map", detail: "Saved · \(datasetStore.stationNames.count) stations")
                Divider().padding(.leading, 68)
                onboardingSetupRow("sparkles", title: "On-device AI", detail: "Ready")
                Divider().padding(.leading, 68)
                onboardingSetupRow("mic", title: "Voice input", detail: "On this iPhone")
                Divider().padding(.leading, 68)
                onboardingSetupRow("location", title: "Last station", detail: "You can pick it by hand")
            }.background(.white, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var connectivityPillLabel: some View {
        Image(systemName: "wifi").font(.system(size: 15)).foregroundStyle(PocketPalette.accent).frame(width: 40, height: 40).background(Color(red: 225/255, green: 239/255, blue: 227/255), in: Circle())
    }

    private func onboardingSetupRow(_ icon: String, title: String, detail: String? = nil, prominent: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(PocketPalette.accent).frame(width: prominent ? 56 : 40, height: prominent ? 56 : 40).background(Color(red: 226/255, green: 238/255, blue: 236/255), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: prominent ? 17 : 16, weight: .semibold)).foregroundStyle(PocketPalette.ink)
                if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(PocketPalette.secondary) }
            }
            Spacer(minLength: 4)
        }.padding(12).frame(minHeight: prominent ? 80 : 64)
    }

    private func onboardingFeature(_ icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(PocketPalette.accent).frame(width: 48, height: 48).background(Color(red: 226/255, green: 238/255, blue: 236/255), in: Circle())
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(PocketPalette.ink); Text(detail).font(.system(size: 14)).foregroundStyle(PocketPalette.secondary) }
            Spacer(minLength: 0)
        }
    }

    private func onboardingButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(primary ? .white : Color(red: 13/255, green: 75/255, blue: 70/255))
                .frame(maxWidth: .infinity, minHeight: 56).background(primary ? PocketPalette.accent : Color(red: 226/255, green: 238/255, blue: 236/255), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }

    private func advanceSetup() {
        if onboardingStep == 1 {
            guard !downloadingOnboardingMap else { return }
            downloadingOnboardingMap = true
            Task {
                await datasetStore.start()
                locator.stations = datasetStore.stations
                downloadingOnboardingMap = false
                onboardingMapDownloadFailed = datasetStore.status.localizedCaseInsensitiveContains("unavailable")
                if !onboardingMapDownloadFailed { onboardingStep = 2 }
            }
        } else if onboardingStep == 3 {
            locator.locate()
            onboardingStep = 4
        } else if onboardingStep < 4 { onboardingStep += 1 }
        else { onboardingComplete = true }
    }

    private var captureScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Button { showingOfflineInfo = true } label: { connectivityPill }.buttonStyle(.plain).accessibilityLabel("Offline status. Show offline details.")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Train stopped?").foregroundStyle(PocketPalette.ink)
                    Text("Let’s find another way.").foregroundStyle(PocketPalette.ink)
                }.font(.system(size: 29, weight: .semibold)).tracking(-0.4).lineSpacing(0)
                VStack(spacing: 0) {
                    stationRow(label: "I’m at", value: station, icon: "location.fill") { pendingStation = station; pickingOrigin = true; showingStationPicker = true }
                    Divider()
                    stationRow(label: "Going to", value: destination, icon: "flag.fill") { pendingStation = destination; pickingOrigin = false; showingStationPicker = true }
                    Divider()
                    HStack(spacing: 16) {
                        Image(systemName: "tram.fill").foregroundStyle(PocketPalette.accent).frame(width: 40, height: 40).background(Color(red: 226/255, green: 238/255, blue: 236/255), in: Circle())
                        VStack(alignment: .leading, spacing: 2) { Text("I was on").font(.system(size: 14)).foregroundStyle(PocketPalette.secondary); HStack(spacing: 8) { Text("Northern").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 2).background(PocketPalette.ink, in: RoundedRectangle(cornerRadius: 6)); Text("Morden via Bank").font(.system(size: 17)).foregroundStyle(PocketPalette.ink) } }
                        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }.padding(16)
                }.background(.white, in: RoundedRectangle(cornerRadius: 16))
                Text("What happened?").font(.system(size: 20, weight: .semibold)).foregroundStyle(PocketPalette.ink)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        situation("Train held", icon: "")
                        situation("Terminating here", icon: "stop.circle")
                        situation("Line closed", icon: "xmark.circle")
                        situation("Missed my stop", icon: "arrow.right.to.line")
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
        }
    }

    private var connectivityPill: some View {
        HStack(spacing: 6) { Image(systemName: "wifi.slash").font(.system(size: 16)); Text("Offline").fontWeight(.semibold); Text("· Tube map saved 14 Nov"); Spacer(); Image(systemName: "chevron.right").font(.system(size: 12)) }
            .font(.system(size: 14)).foregroundStyle(Color(red: 132/255, green: 93/255, blue: 3/255)).padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading).background(Color(red: 243/255, green: 234/255, blue: 221/255), in: Capsule())
    }

    private var voiceInputSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label(voice.isRecording ? "Listening…" : "Voice input", systemImage: voice.isRecording ? "waveform" : "mic").font(.system(size: 15, weight: .semibold)); Spacer(); Label("Offline", systemImage: "wifi.slash").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(red: 132/255, green: 93/255, blue: 3/255)).padding(.horizontal, 8).padding(.vertical, 5).background(Color(red: 243/255, green: 234/255, blue: 221/255), in: Capsule()) }
            Text(voice.transcript.isEmpty ? "Say what happened on your journey…" : voice.transcript).font(.system(size: 17, weight: .medium)).lineSpacing(3).foregroundStyle(PocketPalette.ink).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 54, alignment: .topLeading)
            HStack(alignment: .center, spacing: 4) { ForEach(Array([8.0, 14, 22, 30, 18, 34, 26, 16, 28, 36, 20, 12, 24, 30, 14, 8].enumerated()), id: \.offset) { _, height in Capsule().fill(PocketPalette.accent.opacity(voice.isRecording ? 0.9 : 0.35)).frame(width: 3, height: height) } }.frame(maxWidth: .infinity).frame(height: 38)
            Label("Speech is turned into text on this iPhone. Nothing leaves your phone.", systemImage: "lock").font(.system(size: 11)).foregroundStyle(PocketPalette.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { voice.cancel(); disruptions = disruptionsBeforeVoice; showingVoiceSheet = false } label: { Text("Cancel").font(.system(size: 14, weight: .semibold)).foregroundStyle(PocketPalette.ink).frame(maxWidth: .infinity, minHeight: 44).background(Color(red: 232/255, green: 236/255, blue: 243/255), in: RoundedRectangle(cornerRadius: 10)) }
                Button { voice.finish(); showingVoiceSheet = false } label: { Text("Done").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 44).background(PocketPalette.accent, in: RoundedRectangle(cornerRadius: 10)) }
            }
        }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12).background(PocketPalette.canvas.ignoresSafeArea())
            .presentationDetents([.height(446)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(22)
    }

    private var offlineInfoSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule().fill(PocketPalette.line).frame(width: 40, height: 4).frame(maxWidth: .infinity).padding(.top, 2)
            HStack(spacing: 12) {
                Image(systemName: "wifi.slash").font(.system(size: 18)).foregroundStyle(Color(red: 132/255, green: 93/255, blue: 3/255)).frame(width: 42, height: 42).background(Color(red: 243/255, green: 234/255, blue: 221/255), in: Circle())
                VStack(alignment: .leading, spacing: 3) { Text("You’re offline").font(.system(size: 17, weight: .semibold)).foregroundStyle(PocketPalette.ink); Text("Last known station · \(station)").font(.system(size: 12)).foregroundStyle(PocketPalette.secondary) }
            }
            Text("That’s fine. PocketRoute keeps this demo’s station sample on this iPhone. Here’s what’s available:").font(.system(size: 13)).lineSpacing(2).foregroundStyle(PocketPalette.secondary)
            VStack(spacing: 0) {
                offlineFeature("Re-routing", detail: "Demo station sample is saved on this iPhone", available: true)
                offlineFeature("On-device AI", detail: "AI isn’t connected in this prototype", available: false)
                offlineFeature("Voice", detail: "Speech recognition uses this iPhone when supported", available: true)
                offlineFeature("Live service updates", detail: "Needs a network connection", available: false)
                offlineFeature("Account sync", detail: "Resumes when you’re back online", available: false, last: true)
            }.background(Color(red: 232/255, green: 237/255, blue: 245/255), in: RoundedRectangle(cornerRadius: 12))
            Button { showingOfflineInfo = false } label: { Text("Got it").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 44).background(PocketPalette.accent, in: RoundedRectangle(cornerRadius: 10)) }
            Spacer(minLength: 0)
        }.padding(.horizontal, 18).padding(.top, 8).background(PocketPalette.canvas.ignoresSafeArea())
            .presentationDetents([.fraction(0.56)])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(22)
    }

    private var accountSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule().fill(PocketPalette.line).frame(width: 40, height: 4).frame(maxWidth: .infinity).padding(.top, 6)
            Text(accountIntent).font(.system(size: 29, weight: .semibold)).tracking(-0.4).foregroundStyle(PocketPalette.ink)
            Text("Optional. Re-routing always works without an account.").font(.system(size: 16)).lineSpacing(3).foregroundStyle(PocketPalette.secondary)
            VStack(spacing: 10) {
                Button { showingAccountSheet = false; showingAccountMessage = true } label: {
                    Label("Continue with Apple", systemImage: "apple.logo").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 54).background(PocketPalette.ink, in: RoundedRectangle(cornerRadius: 12))
                }
                Button { showingAccountSheet = false; showingAccountMessage = true } label: {
                    Label("Continue with email", systemImage: "envelope").font(.system(size: 16, weight: .semibold)).foregroundStyle(PocketPalette.ink)
                        .frame(maxWidth: .infinity, minHeight: 54).background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(PocketPalette.line, lineWidth: 1))
                }
            }
            Label("You’re online, so we can create your account now.", systemImage: "wifi").font(.system(size: 13)).foregroundStyle(PocketPalette.secondary)
            Button("Not now") { showingAccountSheet = false }.font(.system(size: 16, weight: .semibold)).foregroundStyle(PocketPalette.accent).frame(maxWidth: .infinity, minHeight: 48)
            Spacer(minLength: 0)
        }.padding(.horizontal, 20).background(PocketPalette.canvas.ignoresSafeArea())
            .presentationDetents([.medium, .large]).presentationDragIndicator(.hidden).presentationCornerRadius(22)
    }

    private var cityPickerSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Search cities", text: $citySearch)
                    .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
                if citySearch.isEmpty || "London · Tube".localizedCaseInsensitiveContains(citySearch) {
                    Button { citySearch = ""; showingCityPicker = false } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tram.fill").foregroundStyle(PocketPalette.accent).frame(width: 40, height: 40).background(Color(red: 226/255, green: 238/255, blue: 236/255), in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text("London · Tube").font(.system(size: 16, weight: .semibold)).foregroundStyle(PocketPalette.ink)
                                Text("\(datasetStore.stationNames.count) stations · 4.2 MB").font(.system(size: 13)).foregroundStyle(PocketPalette.secondary)
                            }
                            Spacer(); Image(systemName: "checkmark").foregroundStyle(PocketPalette.accent)
                        }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain)
                }
                ForEach(["Paris · Métro", "NYC · Subway"].filter { citySearch.isEmpty || $0.localizedCaseInsensitiveContains(citySearch) }, id: \.self) { city in
                    HStack(spacing: 12) {
                        Image(systemName: "tram.fill").foregroundStyle(PocketPalette.secondary).frame(width: 40, height: 40).background(PocketPalette.canvas, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(city).font(.system(size: 16, weight: .semibold)).foregroundStyle(PocketPalette.ink)
                            Text("Coming soon").font(.system(size: 13, weight: .medium)).foregroundStyle(PocketPalette.secondary)
                        }
                        Spacer()
                    }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 14)).opacity(0.55)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(city), coming soon")
                }
                Spacer(minLength: 0)
            }.padding(20).background(PocketPalette.canvas)
                .navigationTitle("Choose your city").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { showingCityPicker = false; citySearch = "" } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private func offlineFeature(_ title: String, detail: String, available: Bool, last: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: available ? "checkmark" : "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(available ? Color(red: 40/255, green: 115/255, blue: 58/255) : PocketPalette.secondary).frame(width: 18, height: 18).background(available ? Color(red: 215/255, green: 233/255, blue: 217/255) : Color(red: 224/255, green: 229/255, blue: 237/255), in: Circle())
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(PocketPalette.ink); Text(detail).font(.system(size: 10)).foregroundStyle(PocketPalette.secondary) }
            Spacer(minLength: 0)
        }.padding(.horizontal, 10).frame(minHeight: 42).overlay(alignment: .bottom) { if !last { PocketPalette.line.frame(height: 0.5) } }
    }

    private func stationRow(label: String, value: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) { Image(systemName: icon).foregroundStyle(PocketPalette.accent).frame(width: 40, height: 40).background(Color(red: 226/255, green: 238/255, blue: 236/255), in: Circle()); VStack(alignment: .leading, spacing: 2) { Text(label).font(.system(size: 14)).foregroundStyle(PocketPalette.secondary); Text(value).font(.system(size: 20, weight: .semibold)).foregroundStyle(PocketPalette.ink) }; Spacer(); Image(systemName: "chevron.right").font(.system(size: 14)).foregroundStyle(.tertiary) }.padding(16).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func situation(_ title: String, icon: String) -> some View {
        Button { if disruptions.contains(title) { disruptions.remove(title) } else { disruptions.insert(title) } } label: {
            HStack(spacing: 8) {
                if disruptions.contains(title) { Image(systemName: "checkmark") }
                else if !icon.isEmpty { Image(systemName: icon) }
                Text(title).font(.system(size: 17, weight: .medium)).fixedSize()
            }
            .foregroundStyle(disruptions.contains(title) ? PocketPalette.accent : PocketPalette.ink)
            .frame(height: 52).padding(.leading, 8).padding(.trailing, 16)
            .background(disruptions.contains(title) ? Color(red: 231/255, green: 241/255, blue: 240/255) : .white, in: Capsule())
            .overlay(Capsule().stroke(disruptions.contains(title) ? PocketPalette.accent : PocketPalette.line, lineWidth: disruptions.contains(title) ? 2 : 1))
        }.buttonStyle(.plain)
    }

    private func applyVoiceReport(_ transcript: String) {
        let report = transcript.lowercased()
        if report.contains("held") || report.contains("stopped") { disruptions.insert("Train held") }
        if report.contains("terminat") { disruptions.insert("Terminating here") }
        if report.contains("closed") { disruptions.insert("Line closed") }
        if report.contains("missed") { disruptions.insert("Missed my stop") }
    }

    private var resultsScreen: some View {
        VStack(spacing: 0) {
            threadHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .trailing, spacing: 6) {
                        bubble("I’m on the Northern line to Morden via Bank. The train’s stopped at \(station). \(disruptionSummary) How do I get to \(destination)?", isUser: true)
                        if !voice.transcript.isEmpty { Label("Dictated · on this iPhone", systemImage: "mic").font(.system(size: 12)).foregroundStyle(PocketPalette.secondary) }
                    }
                    HStack(alignment: .top, spacing: 8) { Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(PocketPalette.accent).frame(width: 24, height: 24).background(Color(red: 226/255, green: 238/255, blue: 236/255), in: Circle()); bubble("There are 3 ways to \(destination) from here:", isUser: false) }
                    ForEach(routes.filter { (!stepFreeOnly || $0.title != "Walk instead") && (suggestWalking || $0.title != "Walk instead") && (!routesDropCharingBranch || $0.title != "Charing Cross branch") }) { route in Button { selectedRoute = route; routeStarted = true; stepIndex = 0 } label: { routeCard(route) }.buttonStyle(.plain) }
                    Label("From your saved Tube map · no live service info", systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(PocketPalette.secondary).padding(.top, 2)
                }.padding(20)
            }
            quickReplies
        }.background(PocketPalette.canvas)
    }

    private var followUpScreen: some View {
        VStack(spacing: 0) {
            threadHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Button { showEarlierRoutes.toggle() } label: {
                        HStack { Image(systemName: showEarlierRoutes ? "chevron.down" : "chevron.right"); Text("3 earlier options from \(station)").font(.system(size: 14, weight: .medium)); Spacer(); Text("Show").font(.system(size: 14, weight: .semibold)) }
                            .foregroundStyle(PocketPalette.accent).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                    if showEarlierRoutes { ForEach(routes) { route in routeCard(route) } }
                    bubble(lastFollowUpText.isEmpty ? "The Charing Cross branch isn’t running." : lastFollowUpText, isUser: true)
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(PocketPalette.accent).frame(width: 24, height: 24).background(Color(red: 226/255, green: 238/255, blue: 236/255), in: Circle())
                        bubble("OK, skipping that branch. Stay on to Euston, then change to the Victoria line.", isUser: false)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("New route").font(.system(size: 18, weight: .semibold)); Spacer(); Text("2 stops · 1 change").font(.system(size: 13)).foregroundStyle(PocketPalette.secondary) }
                        VStack(spacing: 0) {
                            itineraryStep("1", title: "Stay on to Euston", detail: "Northern · 1 stop")
                            Divider().padding(.leading, 44)
                            itineraryStep("2", title: "Change to the Victoria line", detail: "Southbound, towards Brixton")
                            Divider().padding(.leading, 44)
                            itineraryStep("3", title: "Get off at Warren Street", detail: "1 stop on the Victoria line")
                        }
                        Button {
                            selectedRoute = routes.first(where: { $0.title == "Via Euston and Victoria line" })
                            routeStarted = selectedRoute != nil; showingResults = false; stepIndex = 0
                        } label: { Text("Start step-by-step").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 52).background(PocketPalette.accent, in: RoundedRectangle(cornerRadius: 12)) }
                        Text("If your train doesn’t move in a minute, tell me and I’ll find another way.").font(.system(size: 13)).foregroundStyle(PocketPalette.secondary)
                    }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    HStack(spacing: 8) {
                        Button { selectedRoute = routes.first(where: { $0.title == "Walk instead" }); routeStarted = selectedRoute != nil; showingResults = false; stepIndex = 0 } label: { Text("Show walking route").font(.system(size: 13, weight: .medium)).foregroundStyle(PocketPalette.accent).frame(maxWidth: .infinity, minHeight: 44).background(.white, in: Capsule()).overlay(Capsule().stroke(PocketPalette.line, lineWidth: 1)) }
                        Button { lastFollowUpText = "The train still isn’t moving"; disruptions.insert("Train held") } label: { Text("Train still not moving").font(.system(size: 13, weight: .medium)).foregroundStyle(PocketPalette.accent).frame(maxWidth: .infinity, minHeight: 44).background(.white, in: Capsule()).overlay(Capsule().stroke(PocketPalette.line, lineWidth: 1)) }
                    }
                }.padding(20)
            }
            quickReplies
        }.background(PocketPalette.canvas)
    }

    private func itineraryStep(_ number: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Text(number).font(.system(size: 13, weight: .semibold)).foregroundStyle(PocketPalette.secondary).frame(width: 28, height: 28).background(PocketPalette.canvas, in: Circle())
            VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(PocketPalette.ink); Text(detail).font(.system(size: 13)).foregroundStyle(PocketPalette.secondary) }
            Spacer(minLength: 0)
        }.padding(.vertical, 10)
    }

    private var threadHeader: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) { Button { if routeStarted { routeStarted = false } else { selectedRoute = nil; showingResults = false } } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }; Spacer(minLength: 4); VStack(spacing: 4) { Text("\(station) → \(destination)").font(.system(size: 17, weight: .semibold)); HStack(spacing: 5) { Image(systemName: "wifi.slash"); Text("Offline · saved map") }.font(.system(size: 12, weight: .medium)).foregroundStyle(Color(red: 132/255, green: 93/255, blue: 3/255)).padding(.horizontal, 9).padding(.vertical, 3).background(Color(red: 243/255, green: 234/255, blue: 221/255), in: Capsule()) }; Spacer(minLength: 4); Color.clear.frame(width: 44, height: 44) }
        }.padding(.horizontal, 8).padding(.vertical, 8).background(PocketPalette.canvas).overlay(alignment: .bottom) { PocketPalette.line.frame(height: 0.5) }
    }

    private func bubble(_ text: String, isUser: Bool) -> some View {
        HStack { if isUser { Spacer(minLength: 50) }; Text(text).font(.system(size: 17)).lineSpacing(3).foregroundStyle(isUser ? .white : PocketPalette.ink).padding(.horizontal, 16).padding(.vertical, 12).background(isUser ? PocketPalette.accent : Color(red: 232/255, green: 236/255, blue: 243/255), in: RoundedRectangle(cornerRadius: 16)); if !isUser { Spacer(minLength: 0) } }
    }

    private func routeCard(_ route: RouteChoice) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text(route.title).font(.system(size: 17, weight: .semibold)); Spacer(minLength: 2); VStack(alignment: .trailing, spacing: 0) { Text("\(route.minutes)").font(.system(size: 29, weight: .semibold)); Text("min").font(.system(size: 14)).foregroundStyle(PocketPalette.secondary) }; Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(PocketPalette.secondary) }
                HStack(spacing: 6) { ForEach(route.lineNames, id: \.self) { name in Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 3).background(lineColor(name), in: RoundedRectangle(cornerRadius: 5)) }; if let badge = route.badge { Text(badge).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(red: 29/255, green: 99/255, blue: 51/255)).padding(.horizontal, 8).padding(.vertical, 3).background(Color(red: 225/255, green: 239/255, blue: 227/255), in: RoundedRectangle(cornerRadius: 5)) } }
                Text(route.detail).font(.system(size: 14)).foregroundStyle(PocketPalette.secondary)
            }
        }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(route.badge == nil ? PocketPalette.line : PocketPalette.accent, lineWidth: route.badge == nil ? 1 : 2))
    }

    private func lineColor(_ name: String) -> Color {
        switch name { case "Northern": return Color(red: 38/255, green: 38/255, blue: 38/255); case "Victoria": return Color(red: 0/255, green: 152/255, blue: 216/255); default: return PocketPalette.accent }
    }

    private var quickReplies: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { quickChip("Train is moving again"); quickChip("Branch isn’t running"); quickChip("Step-free only") }.padding(.horizontal, 20) }
            HStack(spacing: 10) { TextField("Type, or hold the mic to talk", text: $followUp).padding(.horizontal, 20).frame(height: 56).background(.white, in: Capsule()).overlay(Capsule().stroke(PocketPalette.line, lineWidth: 1)); Button { applyFollowUp(followUp) } label: { Image(systemName: "arrow.up").foregroundStyle(.white).frame(width: 56, height: 56).background(PocketPalette.accent, in: Circle()) }; Button { disruptionsBeforeVoice = disruptions; voice.begin(); showingVoiceSheet = true } label: { Image(systemName: "mic").foregroundStyle(.white).frame(width: 56, height: 56).background(PocketPalette.accent, in: Circle()) }.accessibilityLabel("Speak a follow-up").sheet(isPresented: $showingVoiceSheet) { voiceInputSheet } }.padding(.horizontal, 20).padding(.bottom, 12)
        }.padding(.top, 8).background(PocketPalette.canvas)
    }

    private func quickChip(_ text: String) -> some View {
        Button { applyFollowUp(text) } label: { Text(text).font(.system(size: 15, weight: .medium)).foregroundStyle(PocketPalette.accent).padding(.horizontal, 16).frame(height: 48).background(.white, in: Capsule()).overlay(Capsule().stroke(PocketPalette.line, lineWidth: 1)) }
    }

    private func applyFollowUp(_ text: String) {
        let normalized = text.lowercased()
        if normalized.contains("step-free") { stepFreeOnly = true }
        if normalized.contains("walking") { suggestWalking = true }
        if normalized.contains("branch") { routesDropCharingBranch = true }
        if normalized.contains("moving") { disruptions.remove("Train held") }
        selectedRoute = nil
        routeStarted = false
        showingResults = true
        hasFollowedUp = true
        lastFollowUpText = text
        showEarlierRoutes = false
        tab = 0
        followUp = ""
    }

    @State private var routesDropCharingBranch = false

    private func guidanceScreen(_ route: RouteChoice) -> some View {
        VStack(spacing: 0) {
            HStack { Button("Close") { routeStarted = false; showingResults = false; selectedRoute = nil }; Spacer(); Text("To \(destination)").font(.system(size: 14, weight: .semibold)); Spacer(); Button("Ask") { routeStarted = false; showingResults = true } }.font(.system(size: 14)).foregroundStyle(PocketPalette.accent).padding(.horizontal, 20).frame(height: 52)
            Label("Offline · saved map", systemImage: "wifi.slash").font(.system(size: 12, weight: .medium)).foregroundStyle(Color(red: 132/255, green: 93/255, blue: 3/255)).padding(.horizontal, 12).padding(.vertical, 6).background(Color(red: 243/255, green: 234/255, blue: 221/255), in: Capsule()).padding(.top, 2)
            HStack { Text("Step \(stepIndex + 1) of \(route.steps.count)").font(.system(size: 14, weight: .semibold)).foregroundStyle(PocketPalette.ink); Spacer(); Text("~\(max(route.minutes - stepIndex * 3, 1)) min to go").font(.system(size: 12)).foregroundStyle(PocketPalette.secondary) }.padding(.horizontal, 20).padding(.top, 12)
            HStack(spacing: 6) { ForEach(0..<route.steps.count, id: \.self) { index in Capsule().fill(index <= stepIndex ? PocketPalette.accent : PocketPalette.line).frame(height: 4) } }.padding(.horizontal, 20).padding(.top, 8)
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: stepIndex == 0 ? "arrow.left.arrow.right" : "arrow.up.and.down").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white).frame(width: 40, height: 40).background(Color(red: 5/255, green: 124/255, blue: 182/255), in: Circle())
                Text(route.steps[min(stepIndex, route.steps.count - 1)]).font(.system(size: 20, weight: .semibold)).foregroundStyle(PocketPalette.ink).fixedSize(horizontal: false, vertical: true)
                Text(stepIndex == 0 ? "Follow the signs to the platform shown on your saved Tube map." : "At the station, follow the signs for your next line.").font(.system(size: 14)).lineSpacing(3).foregroundStyle(PocketPalette.secondary)
                HStack(spacing: 10) { Text(route.lineNames[min(stepIndex, route.lineNames.count - 1)]).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 5).background(lineColor(route.lineNames[min(stepIndex, route.lineNames.count - 1)]), in: RoundedRectangle(cornerRadius: 5)); VStack(alignment: .leading, spacing: 2) { Text(stepIndex + 1 < route.steps.count ? "Next: \(route.steps[stepIndex + 1])" : "You’ve arrived at \(destination)").font(.system(size: 13, weight: .semibold)); Text("\(destination) is the next stop").font(.system(size: 12)).foregroundStyle(PocketPalette.secondary) } }.padding(12).background(Color(red: 228/255, green: 240/255, blue: 249/255), in: RoundedRectangle(cornerRadius: 12))
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 20).padding(.top, 24)
            if stepIndex + 1 < route.steps.count { HStack(spacing: 10) { Text("\(stepIndex + 2)").font(.system(size: 12, weight: .semibold)).foregroundStyle(PocketPalette.secondary).frame(width: 28, height: 28).background(PocketPalette.canvas, in: Circle()); VStack(alignment: .leading, spacing: 2) { Text("Next: \(route.steps[stepIndex + 1])").font(.system(size: 14, weight: .medium)); Text("\(route.lineNames[min(stepIndex + 1, route.lineNames.count - 1)]) line · 1 stop").font(.system(size: 12)).foregroundStyle(PocketPalette.secondary) } }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 20).padding(.top, 14) }
            Spacer(minLength: 12)
            VStack(spacing: 6) {
                Button { if stepIndex + 1 < route.steps.count { stepIndex += 1 } else { routeStarted = false; selectedRoute = nil; showingResults = false; tab = 0 } } label: { Text(stepIndex + 1 < route.steps.count ? "I’m on the \(route.lineNames[min(stepIndex, route.lineNames.count - 1)]) line" : "Arrived · Finish").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 56).background(PocketPalette.accent, in: RoundedRectangle(cornerRadius: 12)) }
                Button { routeStarted = false; selectedRoute = nil; showingResults = true; tab = 0 } label: { Label("Something’s wrong — find another way", systemImage: "arrow.clockwise").font(.system(size: 13, weight: .medium)).foregroundStyle(Color(red: 180/255, green: 35/255, blue: 24/255)).frame(maxWidth: .infinity, minHeight: 42) }
            }.padding(.horizontal, 20).padding(.bottom, 12)
        }.background(PocketPalette.canvas)
    }

    private func stationPicker(title: String, isOrigin: Bool) -> some View {
        let lineStationOrder = ["Kentish Town", "Camden Town", "Euston", "King’s Cross St Pancras", "King's Cross St. Pancras", "Angel"]
        let orderedLineStations = lineStationOrder.filter { datasetStore.stationNames.contains($0) }
        let visibleStations = search.isEmpty && !browseAllStations ? orderedLineStations : datasetStore.stationNames.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
        return NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Label("Not sure? Look for the station name on the platform wall.", systemImage: "eye").font(.system(size: 12)).foregroundStyle(PocketPalette.accent).frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                Button { if let suggestion = locator.suggestion { pendingStation = suggestion } else { locator.locate() } } label: { Label(locator.suggestion.map { "Select nearby · \($0)" } ?? locator.message, systemImage: locator.suggestion == nil ? "location.circle" : "checkmark.circle").font(.system(size: 13)).foregroundStyle(PocketPalette.accent).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading) }
                Text(search.isEmpty ? (browseAllStations ? "Stations" : "On your line · Northern, Bank branch") : "Stations").font(.system(size: 12)).foregroundStyle(PocketPalette.secondary)
                ScrollView { LazyVStack(alignment: .leading, spacing: 10) {
                    LazyVStack(spacing: 0) {
                    ForEach(visibleStations, id: \.self) { name in
                        Button { pendingStation = name } label: { HStack(spacing: 12) { Circle().fill(name == pendingStation ? PocketPalette.accent : .white).frame(width: 9, height: 9).overlay(Circle().stroke(name == pendingStation ? PocketPalette.accent : PocketPalette.secondary, lineWidth: 1.5)); VStack(alignment: .leading, spacing: 3) { Text(name).foregroundStyle(PocketPalette.ink); if name == pendingStation { Text("Last place your phone had signal").font(.system(size: 11)).foregroundStyle(PocketPalette.secondary) } else if name == "Euston" { Text("Change for Victoria line").font(.system(size: 11)).foregroundStyle(PocketPalette.secondary) } else if name == "King's Cross St. Pancras" || name == "King’s Cross St Pancras" { Text("Change for 5 more lines").font(.system(size: 11)).foregroundStyle(PocketPalette.secondary) } }; Spacer(); if name == pendingStation { Image(systemName: "checkmark").foregroundStyle(PocketPalette.accent) } }.padding(.horizontal, 12).frame(minHeight: 48).contentShape(Rectangle()) }.buttonStyle(.plain)
                    }
                    }.background(.white, in: RoundedRectangle(cornerRadius: 14))
                    if search.isEmpty && !browseAllStations {
                        Button { browseAllStations = true } label: { Text("Browse all \(datasetStore.stationNames.count) stations  ›").font(.system(size: 14, weight: .medium)).foregroundStyle(PocketPalette.accent).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(.horizontal, 12).background(.white, in: RoundedRectangle(cornerRadius: 12)) }
                    }
                } }
                Text("\(datasetStore.stationNames.count) stations · map v\(datasetStore.activeVersion.isEmpty ? "bundled" : datasetStore.activeVersion)").font(.system(size: 12)).foregroundStyle(PocketPalette.secondary)
            }.padding(.horizontal, 16).padding(.top, 8).background(PocketPalette.canvas)
                .searchable(text: $search, prompt: "Search or say a station")
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingStationPicker = false; search = ""; browseAllStations = false } }; ToolbarItem(placement: .confirmationAction) { Button("Done") { if isOrigin { station = pendingStation } else { destination = pendingStation }; showingStationPicker = false; search = ""; browseAllStations = false } } }
        }.presentationDetents([.large])
    }

    private var settingsScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) { Image(systemName: "wifi"); Text("Online").fontWeight(.semibold); Text("· \(datasetStore.selectedTitle)"); Spacer(); Image(systemName: "chevron.right") }.font(.system(size: 14)).foregroundStyle(Color(red: 29/255, green: 99/255, blue: 51/255)).padding(.horizontal, 12).padding(.vertical, 8).background(Color(red: 225/255, green: 239/255, blue: 227/255), in: Capsule())
                Text("Settings").font(.system(size: 29, weight: .semibold)).tracking(-0.4).foregroundStyle(PocketPalette.ink)
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 16) { Image(systemName: "person.crop.circle").font(.system(size: 26)).foregroundStyle(PocketPalette.secondary).frame(width: 56, height: 56).background(Color(red: 232/255, green: 236/255, blue: 243/255), in: Circle()); VStack(alignment: .leading, spacing: 4) { Text("You’re using a guest profile").font(.system(size: 17, weight: .semibold)); Text("Everything works without an account. Saved places stay on this iPhone.").font(.system(size: 14)).foregroundStyle(PocketPalette.secondary) } }
                    VStack(alignment: .leading, spacing: 4) { Label("Back up saved places and journeys", systemImage: "checkmark"); Label("Use PocketRoute on iPhone and iPad", systemImage: "checkmark") }.font(.system(size: 14)).labelStyle(.titleAndIcon)
                    HStack(spacing: 12) { Button("Sign in") { accountIntent = "Sign in"; showingAccountSheet = true }.foregroundStyle(PocketPalette.accent).frame(maxWidth: .infinity, minHeight: 48).background(Color(red: 226/255, green: 238/255, blue: 236/255), in: RoundedRectangle(cornerRadius: 12)); Button("Create account") { accountIntent = "Create your account"; showingAccountSheet = true }.fontWeight(.semibold).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 48).background(PocketPalette.accent, in: RoundedRectangle(cornerRadius: 12)) }
                }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
                settingsSection("Offline data") {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Image(systemName: "map").font(.system(size: 16)).foregroundStyle(PocketPalette.accent).frame(width: 40, height: 40).background(Color(red: 226/255, green: 238/255, blue: 236/255), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text("City map").font(.system(size: 16, weight: .medium)).foregroundStyle(PocketPalette.ink)
                                Text(datasetStore.status).font(.system(size: 12)).foregroundStyle(PocketPalette.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            if datasetStore.isDownloading { ProgressView().tint(PocketPalette.accent) }
                            Picker("City map", selection: Binding(get: { datasetStore.selectedID }, set: { newValue in Task { await datasetStore.select(newValue) } })) {
                                ForEach(datasetStore.choices) { choice in Text(choice.title).tag(choice.id) }
                            }.labelsHidden().pickerStyle(.menu).disabled(datasetStore.isDownloading || datasetStore.choices.isEmpty)
                        }.padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 60)
                        Divider().padding(.leading, 68)
                        settingsRow(icon: "internaldrive", title: "Saved on this iPhone", subtitle: "\(datasetStore.stationNames.count) stations · version \(datasetStore.activeVersion.isEmpty ? "bundled" : datasetStore.activeVersion)") { Text("Offline").font(.system(size: 14, weight: .medium)).foregroundStyle(PocketPalette.accent) }
                    }
                    Divider().padding(.leading, 68)
                    settingsRow(icon: "arrow.clockwise", title: "Refresh map on launch", subtitle: "Checks the selected map when online") { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(PocketPalette.accent) }
                }
                settingsSection("AI & voice") {
                    settingsRow(icon: "sparkles", title: "On-device AI", subtitle: "AI integration isn’t connected yet") { Text("Not set up").font(.system(size: 12)).foregroundStyle(PocketPalette.secondary) }
                    Divider().padding(.leading, 68)
                    settingsRow(icon: "cloud", title: "Use cloud AI when online", subtitle: "Cloud model isn’t connected in this prototype") { Image(systemName: "chevron.right").font(.caption).foregroundStyle(PocketPalette.secondary) }
                    Divider().padding(.leading, 68)
                    settingsRow(icon: "mic", title: "Voice input", subtitle: "English (UK) · on-device when supported") { Image(systemName: "chevron.right").font(.caption).foregroundStyle(PocketPalette.secondary) }
                }
                settingsSection("Routes") {
                    Toggle(isOn: $stepFreeOnly) { Label("Step-free routes first", systemImage: "figure.roll") }.tint(PocketPalette.accent).font(.system(size: 16)).padding(.horizontal, 12).frame(minHeight: 56)
                    Divider().padding(.leading, 68)
                    Toggle(isOn: $suggestWalking) { VStack(alignment: .leading, spacing: 3) { Label("Suggest walking", systemImage: "figure.walk"); Text("Up to 30 minutes").font(.system(size: 12)).foregroundStyle(PocketPalette.secondary) } }.tint(PocketPalette.accent).font(.system(size: 16)).padding(.horizontal, 12).frame(minHeight: 64)
                }
                settingsSection("About") {
                    settingsRow(icon: "hand.raised", title: "Privacy", subtitle: "Location helps suggest a nearby station") { Image(systemName: "chevron.right").font(.caption).foregroundStyle(PocketPalette.secondary) }
                    Divider().padding(.leading, 68)
                    settingsRow(icon: "info.circle", title: "Map data & licences", subtitle: "TfL open data · static map, no live service status") { Image(systemName: "chevron.right").font(.caption).foregroundStyle(PocketPalette.secondary) }
                }
                Text("PocketRoute 1.0").font(.system(size: 12)).foregroundStyle(PocketPalette.secondary)
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 28)
        }.background(PocketPalette.canvas)
    }

    private var savedScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("Saved").font(.system(size: 29, weight: .semibold)).tracking(-0.4); Spacer(); Button { showingAccountMessage = true } label: { Image(systemName: "plus").font(.system(size: 17, weight: .medium)).foregroundStyle(PocketPalette.accent).frame(width: 40, height: 40).background(Color(red: 226/255, green: 238/255, blue: 236/255), in: Circle()) } }
                settingsSection("Places") {
                    savedPlaceRow(icon: "house", title: "Home", stationName: "Kentish Town", destinationName: "Kentish Town")
                    Divider().padding(.leading, 64)
                    savedPlaceRow(icon: "building.2", title: "Work", stationName: "Warren Street", destinationName: "Warren Street")
                }
                settingsSection("Recent re-routes") {
                    savedRecentRow(title: "Camden Town → Warren Street", subtitle: "Today 08:45 · via Euston and Victoria line")
                    Divider().padding(.leading, 64)
                    savedRecentRow(title: "Bank → King’s Cross", subtitle: "Tue · walked from Moorgate")
                }
                HStack(alignment: .top, spacing: 10) { Image(systemName: "icloud").foregroundStyle(PocketPalette.secondary); VStack(alignment: .leading, spacing: 3) { Text("Saved on this iPhone only").font(.system(size: 13, weight: .semibold)); Text("Create an account to back up your places. You can do it when you’re back online.").font(.system(size: 12)).foregroundStyle(PocketPalette.secondary) } }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(PocketPalette.line, lineWidth: 1))
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 28)
        }.background(PocketPalette.canvas)
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(PocketPalette.secondary)
            VStack(spacing: 0, content: content).background(.white, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func settingsRow<Accessory: View>(icon: String, title: String, subtitle: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(PocketPalette.accent).frame(width: 40, height: 40).background(Color(red: 226/255, green: 238/255, blue: 236/255), in: Circle())
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(PocketPalette.ink); Text(subtitle).font(.system(size: 12)).foregroundStyle(PocketPalette.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 4); accessory()
        }.padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 60)
    }

    private func savedPlaceRow(icon: String, title: String, stationName: String, destinationName: String) -> some View {
        Button { destination = destinationName; tab = 0; selectedRoute = nil; showingResults = false } label: {
            HStack(spacing: 12) { Image(systemName: icon).font(.system(size: 15)).foregroundStyle(PocketPalette.accent).frame(width: 36, height: 36).background(Color(red: 226/255, green: 238/255, blue: 236/255), in: Circle()); VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(PocketPalette.ink); Text(stationName).font(.system(size: 12)).foregroundStyle(PocketPalette.secondary) }; Spacer(); Text("Go").font(.system(size: 12, weight: .semibold)).foregroundStyle(PocketPalette.accent) }.padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 54)
        }.buttonStyle(.plain)
    }

    private func savedRecentRow(title: String, subtitle: String) -> some View {
        Button { station = "Camden Town"; destination = "Warren Street"; tab = 0; hasFollowedUp = false; selectedRoute = nil; showingResults = true } label: {
            HStack(spacing: 12) { Image(systemName: "clock").font(.system(size: 14)).foregroundStyle(PocketPalette.secondary).frame(width: 36, height: 36).background(Color(red: 232/255, green: 236/255, blue: 243/255), in: Circle()); VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(PocketPalette.ink); Text(subtitle).font(.system(size: 12)).foregroundStyle(PocketPalette.secondary) }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(PocketPalette.secondary) }.padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 62)
        }.buttonStyle(.plain)
    }

    private var tabBar: some View {
        VStack(spacing: 8) {
            if tab == 0 && !showingResults && !routeStarted {
                HStack(spacing: 12) {
                    Button { selectedRoute = nil; hasFollowedUp = false; showingResults = true; tab = 0 } label: { Label("Find another way", systemImage: "point.topleft.down.curvedto.point.bottomright.up").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 56).background(PocketPalette.accent, in: RoundedRectangle(cornerRadius: 12)) }
                    Button { disruptionsBeforeVoice = disruptions; voice.begin(); showingVoiceSheet = true } label: { Image(systemName: "mic").font(.system(size: 20, weight: .medium)).foregroundStyle(PocketPalette.accent).frame(width: 56, height: 56).background(PocketPalette.canvas, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(PocketPalette.accent, lineWidth: 1)) }.accessibilityLabel("Speak what happened").sheet(isPresented: $showingVoiceSheet) { voiceInputSheet }
                }
                if !voice.transcript.isEmpty { Text(voice.transcript).font(.system(size: 12)).foregroundStyle(PocketPalette.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading) }
            }
            HStack(spacing: 4) {
                tabButton(0, "Re-route", "arrow.triangle.turn.up.right.diamond")
                tabButton(1, "Saved", "bookmark")
                tabButton(2, "Settings", "slider.horizontal.3")
            }.padding(6).background(.white, in: Capsule()).overlay(Capsule().stroke(PocketPalette.line, lineWidth: 1)).shadow(color: PocketPalette.ink.opacity(0.12), radius: 6, y: 3)
        }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16).background(PocketPalette.canvas)
    }

    private func tabButton(_ value: Int, _ title: String, _ icon: String) -> some View {
        Button { tab = value; if value != 0 { selectedRoute = nil; routeStarted = false; showingResults = false } } label: { VStack(spacing: 2) { Image(systemName: icon).font(.system(size: 23)); Text(title).font(.system(size: 12, weight: .medium)) }.foregroundStyle(tab == value ? PocketPalette.accent : PocketPalette.secondary).frame(maxWidth: .infinity).frame(height: 58).background(tab == value ? Color(red: 226/255, green: 238/255, blue: 236/255) : .clear, in: Capsule()).contentShape(Rectangle()) }
    }
}
