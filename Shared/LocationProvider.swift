import Foundation
import CoreLocation

/// One-shot location acquisition wrapping `CLLocationManager`.
///
/// The manager is retained for the lifetime of the provider (releasing it
/// mid-request silently drops the callback). All requests are When-In-Use only.
@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    enum Status: Equatable {
        case idle
        case requesting
        case denied
        case got(CLLocationCoordinate2D)
        case failed

        static func == (lhs: Status, rhs: Status) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.requesting, .requesting),
                 (.denied, .denied), (.failed, .failed):
                return true
            case let (.got(a), .got(b)):
                return a.latitude == b.latitude && a.longitude == b.longitude
            default:
                return false
            }
        }
    }

    private(set) var status: Status = .idle

    /// Mirror of the manager's authorization so callers can distinguish "the
    /// permission alert is still on screen" (.notDetermined) from "we're
    /// waiting on a fix" and budget their deadlines accordingly.
    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    private let manager = CLLocationManager()

    /// Deadline for CoreLocation to produce a fix once authorization is
    /// settled. Without it a stalled `requestLocation()` pins `status` at
    /// `.requesting` forever — and every "Finding you..." spinner with it.
    /// Armed only AFTER authorization resolves, so a user reading the
    /// permission alert slowly is never timed out by us.
    private static let fixTimeout: Duration = .seconds(20)
    private var fixWatchdog: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Requests When-In-Use authorization if needed, then a single fix.
    func requestOnce() {
        status = .requesting
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            requestFix()
        case .denied, .restricted:
            // Already-denied MUST settle asynchronously. A synchronous
            // `status = .denied` here makes the whole call collapse to
            // .denied → .requesting → .denied within one run-loop turn, which
            // SwiftUI coalesces into "no change" — so the `.onChange(of:
            // status)` observers that clear spinners and parked send intents
            // never fire, and every denied tap dead-ends on "Finding you...".
            settle(.denied)
        @unknown default:
            settle(.failed)
        }
    }


    private func requestFix() {
        manager.requestLocation()
        fixWatchdog?.cancel()
        fixWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.fixTimeout)
            guard !Task.isCancelled, let self, self.status == .requesting else { return }
            self.status = .failed
        }
    }

    /// Terminal transitions land here: cancel the watchdog and mutate the
    /// `@Observable` state on the main actor — CoreLocation may call the
    /// delegate off-main, and observers of `status` drive SwiftUI directly.
    private func settle(_ newStatus: Status) {
        fixWatchdog?.cancel()
        Task { @MainActor in
            self.status = newStatus
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            // .requesting: the user just answered the permission alert.
            // .denied: the user re-granted in Settings mid-session — without
            // this arm the provider stayed wedged at .denied until relaunch.
            // Read + write `status` on the main actor like every other terminal
            // transition (via settle) — this delegate can be called off-main, and
            // a bare `status =` here was an off-main write to @Observable state.
            Task { @MainActor in
                if self.status == .requesting || self.status == .denied {
                    self.status = .requesting
                    self.requestFix()
                }
            }
        case .denied, .restricted:
            settle(.denied)
        case .notDetermined:
            break
        @unknown default:
            settle(.failed)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else {
            settle(.failed)
            return
        }
        settle(.got(coordinate))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        settle(.failed)
    }
}
