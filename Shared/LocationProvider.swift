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

    /// True once a caller asked for the continuous stream — lets a grant that
    /// arrives later (first-launch permission alert) start the stream the
    /// moment authorization lands instead of waiting for another call.
    private var continuousRequested = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // Continuous mode is foreground-only (When-In-Use); the filter keeps
        // delegate traffic to genuine movement instead of GPS jitter.
        manager.distanceFilter = 35
    }

    /// Streams fixes while the app is foregrounded so the user's pin tracks
    /// them as they move — no more frozen location until "I'm in" or a
    /// relaunch. Updates land through the same `didUpdateLocations` →
    /// `.got` path one-shot fixes use, so existing observers just keep
    /// firing. When-In-Use only: callers stop the stream on backgrounding.
    /// Never prompts — an unauthorized call arms `continuousRequested` and
    /// the stream starts when (if) authorization arrives.
    func startContinuous() {
        continuousRequested = true
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    /// `startContinuous`, but it ALSO asks for When-In-Use the first time.
    ///
    /// Open Apple Maps and your blue dot is there — it asks on open and starts
    /// tracking. Tween made you tap "I'm in" before it would even ask, so the
    /// map sat on a stale or empty location until you committed to a meetup
    /// (device report 2026-08-02: "I had to hit I'm in for it to fix my
    /// location, it needs to be like Maps").
    ///
    /// HOST APP ONLY. The extension keeps the silent `startContinuous` — an
    /// iMessage extension throwing a permission alert the instant you tap its
    /// icon in the drawer is hostile, and the extension already prompts at the
    /// point the user asks to share ("I'm in").
    ///
    /// Still When-In-Use only (constraint 4). When the user answers, the
    /// existing `locationManagerDidChangeAuthorization` arm sees
    /// `continuousRequested` and opens the stream.
    func startContinuousAskingIfNeeded() {
        continuousRequested = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
            // Authorized but no fix yet (cold launch): ask for one instead of
            // waiting for the stream's first delivery, which can lag seconds.
            if case .got = status {} else if status != .requesting {
                status = .requesting
                requestFix()
            }
        default:
            break
        }
    }

    func stopContinuous() {
        continuousRequested = false
        manager.stopUpdatingLocation()
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
                // A continuous stream requested before the user answered the
                // permission alert starts now that they've granted.
                if self.continuousRequested {
                    self.manager.startUpdatingLocation()
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
        // kCLErrorLocationUnknown is TRANSIENT — CoreLocation keeps trying
        // and delivers through didUpdateLocations moments later. Treating it
        // as terminal failed every fix attempt the instant the continuous
        // stream started before a first fix existed (simulator boot, airplane
        // mode blips). The fixWatchdog still bounds the wait for one-shots.
        if let clError = error as? CLError, clError.code == .locationUnknown {
            return
        }
        settle(.failed)
    }
}
