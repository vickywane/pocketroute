import CoreLocation
import Foundation
import Observation

/// Suggests the station the passenger is most likely at.
///
/// GPS rarely works underground, so the last good fix is kept (also across
/// launches) and matched against whichever network map is loaded. When the map
/// changes — for example after the download finishes — the suggestion is
/// recomputed against the new stations instead of the old ones.
@MainActor
@Observable
final class StationLocator: NSObject, @preconcurrency CLLocationManagerDelegate {
    enum Status: Equatable {
        case idle, locating, needsPermission, denied, servicesOff, failed, tooImprecise, outsideArea, found
    }

    /// Fixes worse than this can't tell neighbouring stations apart.
    static let maxAccuracy: CLLocationAccuracy = 1_000
    /// Further than this from any station: probably not on this network.
    static let maxStationDistance: CLLocationDistance = 2_000

    private(set) var status: Status = .idle
    private(set) var lastFix: CLLocation?
    private(set) var suggestion: NetworkGraph.Station?
    private(set) var suggestionDistance: CLLocationDistance?
    private(set) var authorization: CLAuthorizationStatus

    var graph: NetworkGraph? {
        didSet { if graph !== oldValue { recompute() } }
    }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let defaults: UserDefaults
    private enum Key {
        static let latitude = "pocketroute.location.lastLatitude"
        static let longitude = "pocketroute.location.lastLongitude"
        static let accuracy = "pocketroute.location.lastAccuracy"
        static let timestamp = "pocketroute.location.lastTimestamp"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        lastFix = Self.restoreFix(from: defaults)
    }

    var isAuthorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }

    /// Ask for a fresh fix. Only shows the permission prompt when `prompt` is true.
    func locate(prompt: Bool) {
        guard CLLocationManager.locationServicesEnabled() else { status = .servicesOff; return }
        switch authorization {
        case .authorizedAlways, .authorizedWhenInUse:
            status = .locating
            manager.requestLocation()
        case .notDetermined:
            if prompt { manager.requestWhenInUseAuthorization() } else { status = .needsPermission }
        default:
            status = .denied
        }
    }

    var message: String {
        switch status {
        case .found:
            guard let suggestion else { return "Choose your station" }
            if let age = fixAgeDescription { return "Near \(suggestion.name) · \(age)" }
            return "Nearby: \(suggestion.name) · confirm station"
        case .locating: return "Checking nearby stations…"
        case .needsPermission: return "Allow location to suggest a nearby station"
        case .denied: return "Location access is off. Choose your station below."
        case .servicesOff: return "Location is unavailable. Choose your station below."
        case .failed: return "Couldn’t get a fix. GPS often drops underground; choose your station."
        case .tooImprecise: return "Location is too rough to pick a station. Choose it below."
        case .outsideArea: return "You’re not near a station on this map. Choose one below."
        case .idle: return suggestion.map { "Last known: \($0.name)" } ?? "Use your last known station underground"
        }
    }

    /// "fix from 18 min ago" when the fix is old enough to matter.
    var fixAgeDescription: String? {
        guard let lastFix else { return nil }
        let age = Date().timeIntervalSince(lastFix.timestamp)
        guard age > 5 * 60 else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "last signal \(formatter.localizedString(for: lastFix.timestamp, relativeTo: Date()))"
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if isAuthorized {
            status = .locating
            manager.requestLocation()
        } else if authorization == .denied || authorization == .restricted {
            status = .denied
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A failed fix keeps the last good one; underground this is normal.
        status = (error as? CLError)?.code == .denied ? .denied : .failed
        if status == .failed, suggestion != nil { status = .found }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // The array is oldest first; use the newest usable fix.
        guard let fix = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { status = .failed; return }
        guard fix.horizontalAccuracy <= Self.maxAccuracy else {
            status = suggestion == nil ? .tooImprecise : .found
            return
        }
        lastFix = fix
        persist(fix)
        recompute()
    }

    // MARK: - Matching

    /// Match the last fix to the nearest station on the loaded map.
    func recompute() {
        guard let graph, let fix = lastFix else {
            suggestion = nil
            suggestionDistance = nil
            return
        }
        if let match = graph.nearestStation(to: fix, within: Self.maxStationDistance) {
            suggestion = match.station
            suggestionDistance = match.distance
            status = .found
        } else {
            suggestion = nil
            suggestionDistance = nil
            status = .outsideArea
        }
    }

    private func persist(_ fix: CLLocation) {
        defaults.set(fix.coordinate.latitude, forKey: Key.latitude)
        defaults.set(fix.coordinate.longitude, forKey: Key.longitude)
        defaults.set(fix.horizontalAccuracy, forKey: Key.accuracy)
        defaults.set(fix.timestamp.timeIntervalSince1970, forKey: Key.timestamp)
    }

    private static func restoreFix(from defaults: UserDefaults) -> CLLocation? {
        guard defaults.object(forKey: Key.latitude) != nil, defaults.object(forKey: Key.longitude) != nil else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: defaults.double(forKey: Key.latitude), longitude: defaults.double(forKey: Key.longitude))
        let timestamp = Date(timeIntervalSince1970: defaults.double(forKey: Key.timestamp))
        // A day-old fix says nothing about where someone is now.
        guard Date().timeIntervalSince(timestamp) < 12 * 3_600 else { return nil }
        return CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: defaults.double(forKey: Key.accuracy),
                          verticalAccuracy: -1, timestamp: timestamp)
    }
}
