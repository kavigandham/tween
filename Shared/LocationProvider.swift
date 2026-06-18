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

    private let manager = CLLocationManager()

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
            manager.requestLocation()
        case .denied, .restricted:
            status = .denied
        @unknown default:
            status = .failed
        }
    }

    /// Requests a single fix only if already authorized; otherwise stays idle.
    /// Useful in the extension where we never want to trigger a prompt.
    func requestOnceIfAuthorized() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            status = .requesting
            manager.requestLocation()
        case .denied, .restricted:
            status = .denied
        default:
            status = .idle
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if status == .requesting {
                manager.requestLocation()
            }
        case .denied, .restricted:
            status = .denied
        case .notDetermined:
            break
        @unknown default:
            status = .failed
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else {
            status = .failed
            return
        }
        status = .got(coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        status = .failed
    }
}
