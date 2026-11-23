import Foundation
import Network
import Observation

/// Whether the phone currently has a usable network path.
@MainActor
@Observable
final class Connectivity {
    private(set) var isOnline = false
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "pocketroute.connectivity"))
    }

    deinit { monitor.cancel() }
}
