import CoreLocation
import Foundation

/// The parts of a published network snapshot the app uses. Unknown keys
/// (for example `stepFreeTopology`) are ignored by the decoder.
struct NetworkSnapshot: Decodable, Sendable {
    struct Line: Decodable, Sendable {
        let id: String
        let name: String
    }

    struct Station: Decodable, Sendable {
        let id: String
        let name: String
        let latitude: Double?
        let longitude: Double?
        let lineIds: [String]
        let accessViaLift: String?
        let hubId: String?
    }

    struct Route: Decodable, Sendable {
        let id: String
        let lineId: String
        let direction: String
        let serviceType: String
        let name: String
        let stationIds: [String]
    }

    struct Interchange: Decodable, Sendable {
        let id: String
        let type: String
        let stationIds: [String]
    }

    let schemaVersion: Int
    let networkId: String
    let version: String
    let generatedAt: String
    let lines: [Line]
    let stations: [Station]
    let routes: [Route]
    let interchanges: [Interchange]
}

/// Immutable, query-friendly view of a network snapshot.
final class NetworkGraph: Sendable {
    struct Station: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let latitude: Double
        let longitude: Double
        let lineIds: [String]
        /// TfL `AccessViaLift`: true = "Yes", false = "No", nil = not recorded.
        let liftAccess: Bool?

        var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    }

    struct Edge: Hashable, Sendable {
        let from: String
        let to: String
        let lineId: String
        let minutes: Double
    }

    let version: String
    let generatedAt: Date?
    let stations: [String: Station]
    /// Stations sorted by display name, for pickers.
    let sortedStations: [Station]
    let lineNames: [String: String]
    let edgesFrom: [String: [Edge]]
    /// Stations TfL links under one hub but models as separate nodes
    /// (for example the two Hammersmith stations).
    let linkedStations: [String: [String]]
    private let regularRoutes: [NetworkSnapshot.Route]
    /// "line|a|b|c" for every three consecutive stops a single train serves.
    private let continuations: Set<String>

    init(snapshot: NetworkSnapshot) {
        version = snapshot.version
        generatedAt = ISO8601DateFormatter().date(from: snapshot.generatedAt)

        var stations: [String: Station] = [:]
        for item in snapshot.stations {
            guard let latitude = item.latitude, let longitude = item.longitude else { continue }
            stations[item.id] = Station(
                id: item.id,
                name: Self.displayName(item.name),
                latitude: latitude,
                longitude: longitude,
                lineIds: item.lineIds,
                liftAccess: item.accessViaLift.map { $0.caseInsensitiveCompare("Yes") == .orderedSame }
            )
        }
        self.stations = stations
        sortedStations = stations.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lineNames = Dictionary(snapshot.lines.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        // Night routes duplicate regular paths; route on the regular service.
        let regular = snapshot.routes.filter { $0.serviceType.caseInsensitiveCompare("Regular") == .orderedSame }
        regularRoutes = regular

        var edges: [String: Set<Edge>] = [:]
        var continuations = Set<String>()
        for route in regular {
            let ids = route.stationIds.filter { stations[$0] != nil }
            for (a, b) in zip(ids, ids.dropFirst()) {
                guard let from = stations[a], let to = stations[b] else { continue }
                let edge = Edge(from: a, to: b, lineId: route.lineId, minutes: Self.rideMinutes(from: from, to: to))
                edges[a, default: []].insert(edge)
            }
            if ids.count >= 3 {
                for index in 0..<(ids.count - 2) {
                    continuations.insert("\(route.lineId)|\(ids[index])|\(ids[index + 1])|\(ids[index + 2])")
                }
            }
        }
        edgesFrom = edges.mapValues { Array($0) }
        self.continuations = continuations

        var linked: [String: [String]] = [:]
        for group in snapshot.interchanges where group.type == "linked-stations" {
            for id in group.stationIds {
                linked[id, default: []].append(contentsOf: group.stationIds.filter { $0 != id })
            }
        }
        linkedStations = linked
    }

    var stationCount: Int { stations.count }

    func lineName(_ id: String) -> String { lineNames[id] ?? id.capitalized }

    /// True when one train can run a → b → c without passengers changing.
    func continues(line: String, from a: String, via b: String, to c: String) -> Bool {
        continuations.contains("\(line)|\(a)|\(b)|\(c)")
    }

    func nearestStation(to location: CLLocation, within metres: CLLocationDistance) -> (station: Station, distance: CLLocationDistance)? {
        let nearest = stations.values
            .map { ($0, location.distance(from: $0.location)) }
            .min { $0.1 < $1.1 }
        guard let nearest, nearest.1 <= metres else { return nil }
        return nearest
    }

    /// Stops on the longest regular service of `line` that calls at `stationId`,
    /// in running order. Used to list "stations on your line" in the picker.
    func lineOrder(line: String, around stationId: String) -> [Station] {
        let candidates = regularRoutes.filter { $0.lineId == line && $0.stationIds.contains(stationId) }
        guard let route = candidates.max(by: { $0.stationIds.count < $1.stationIds.count }) else { return [] }
        return route.stationIds.compactMap { stations[$0] }
    }

    /// Undirected segment keys of `line` between two stations, on every
    /// regular service that calls at both. Used for "no service between A and B".
    func segmentKeys(line: String, between a: String, and b: String) -> Set<String> {
        var keys = Set<String>()
        for route in regularRoutes where route.lineId == line {
            guard let i = route.stationIds.firstIndex(of: a), let j = route.stationIds.firstIndex(of: b), i != j else { continue }
            let slice = Array(route.stationIds[min(i, j)...max(i, j)])
            for (x, y) in zip(slice, slice.dropFirst()) { keys.insert(RerouteRequest.segmentKey(line: line, x, y)) }
        }
        return keys
    }

    /// The terminus of a regular service that runs through these stops in order.
    func terminus(line: String, stops: [String]) -> String? {
        guard stops.count >= 2 else { return nil }
        for route in regularRoutes where route.lineId == line {
            guard let start = route.stationIds.firstIndex(of: stops[0]) else { continue }
            let tail = route.stationIds[start...]
            if tail.starts(with: stops), let last = route.stationIds.last { return stations[last]?.name }
        }
        return nil
    }

    // MARK: - Estimates

    /// No timetabled run times are in the snapshot, so estimate from distance:
    /// about 33 km/h average between stops plus dwell time.
    static func rideMinutes(from a: Station, to b: Station) -> Double {
        let metres = a.location.distance(from: b.location)
        return 0.6 + metres / 550
    }

    /// Street walking estimate: straight-line distance × 1.3 at 80 m/min.
    static func walkMinutes(metres: CLLocationDistance) -> Double { (metres * 1.3) / 80 }

    static func displayName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "&amp;", with: "&")
        for suffix in [" Underground Station", "-Underground", " Underground"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return name.trimmingCharacters(in: .whitespaces)
    }
}
