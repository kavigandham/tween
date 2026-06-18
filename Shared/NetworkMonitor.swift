import Foundation
import Network

/// Live reachability state from `NWPathMonitor`.
///
/// Defaults to `true` so the UI never blocks on a not-yet-fired first callback;
/// the monitor updates `isOnline` on its own queue, hopping to the main actor.
@Observable
final class NetworkMonitor {
    private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "tween.network.monitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
