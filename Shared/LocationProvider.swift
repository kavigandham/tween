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

    /// True while `startUpdatingLocation` is live. While streaming, the last
    /// fix is current BY CONSTRUCTION: CoreLocation keeps the fix warm and the
    /// distance filter only suppresses deliveries below the threshold — so no
    /// delivery means no movement, not no data.
    private(set) var isStreaming = false

    /// When the most recent fix was MEASURED (CLLocation.timestamp, not receipt
    /// time) — guards against CoreLocation's first post-start delivery, which
    /// can be a cached fix from before a 20-minute drive.
    private(set) var lastFixAt: Date?

    /// The coordinate a caller may use RIGHT NOW without waiting: streaming,
    /// got a fix, and the fix was measured recently. This is what makes
    /// "I'm in" instant when the user can already see their dot — the tap
    /// previously fired requestLocation() alongside the live stream, a
    /// combination CLLocationManager documents as unsupported; it frequently
    /// never delivered, the 20 s watchdog failed the request, and the user
    /// retried into the same wall ("45 seconds when I can see my person",
    /// device report 2026-08-05).
    var currentFreshCoordinate: CLLocationCoordinate2D? {
        guard isStreaming, case let .got(coord) = status,
              let at = lastFixAt,
              Date().timeIntervalSince(at) < Self.freshFixMaxAge else { return nil }
        return coord
    }

    /// Deadline for CoreLocation to produce a fix once authorization is
    /// settled. Without it a stalled `requestLocation()` pins `status` at
    /// `.requesting` forever — and every "Finding you..." spinner with it.
    /// Armed only AFTER authorization resolves, so a user reading the
    /// permission alert slowly is never timed out by us.
    private static let fixTimeout: Duration = .seconds(20)
    private var fixWatchdog: Task<Void, Never>?

    /// One shared definition of "fresh" — the gate below and
    /// `currentFreshCoordinate` used to disagree (60 vs 90), so a 61-second-old
    /// fix joined instantly via the stream path but was refused via the
    /// waiting path (audit 2026-08-05).
    private static let freshFixMaxAge: TimeInterval = 90


    /// True once a caller asked for the continuous stream — lets a grant that
    /// arrives later (first-launch permission alert) start the stream the
    /// moment authorization lands instead of waiting for another call.
    private var continuousRequested = false

    /// The stream profile the caller asked for, applied when the stream
    /// starts — including a deferred start after the permission alert.
    private var streamFilter: CLLocationDistance = 35
    private var streamAccuracy: CLLocationAccuracy = kCLLocationAccuracyHundredMeters

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // Continuous mode is foreground-only (When-In-Use); the filter keeps
        // delegate traffic to genuine movement instead of GPS jitter.
        manager.distanceFilter = 35
    }

    /// Deliveries older than this are refused until the stream produces a
    /// genuinely current one, for a short window after the stream starts.
    /// CoreLocation's FIRST delivery is typically its cached fix, so opening
    /// the app after a drive painted the dot at the OLD place until a real fix
    /// arrived — the app looked like it thought you were still at home
    /// (device report 2026-08-06). Showing nothing briefly beats asserting a
    /// position the user has already left.
    private static let staleOnResumeMaxAge: TimeInterval = 120
    /// True from stream start until the first delivery is accepted.
    private var awaitingFirstFreshFix = false

    private func beginStream() {
        manager.distanceFilter = streamFilter
        manager.desiredAccuracy = streamAccuracy
        manager.startUpdatingLocation()
        isStreaming = true
        awaitingFirstFreshFix = true
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
        // The extension keeps the conservative profile: 35 m filter, coarse
        // accuracy. Its surfaces are snapshots, not a live map, and constraint
        // 1 (memory ceiling) argues against per-second delegate traffic.
        streamFilter = 35
        streamAccuracy = kCLLocationAccuracyHundredMeters
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            beginStream()
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
        // HOST profile: no distance filter, ten-metre accuracy — the dot
        // glides the way Maps' does instead of jumping in 35 m steps, and
        // fix timestamps stay fresh even when the user is stationary, which
        // is what lets "I'm in" resolve instantly from the stream.
        // Foreground-only, so the battery cost is the same class as having
        // Apple or Google Maps open.
        streamFilter = kCLDistanceFilterNone
        streamAccuracy = kCLLocationAccuracyNearestTenMeters
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // No watchdog here on purpose: this path leaves `status` at .idle,
            // so nothing is spinning and nothing can wedge. `requestOnce` is
            // where the deadline belongs — it's the call that sets .requesting.
        case .authorizedWhenInUse, .authorizedAlways:
            beginStream()
            // The stream's own first delivery lands in ~a second; no separate
            // requestLocation() here. The previous one-shot-alongside-stream
            // call was the unsupported combination that made cold launches
            // sit on the LAST session's location for tens of seconds
            // (device report 2026-08-05).
        default:
            break
        }
    }

    func stopContinuous() {
        continuousRequested = false
        manager.stopUpdatingLocation()
        isStreaming = false
    }

    /// Requests When-In-Use authorization if needed, then a single fix.
    func requestOnce() {
        status = .requesting
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // With Location Services off system-wide, iOS shows "Turn On
            // Location Services?" instead of the app's permission alert — and
            // declining it leaves authorization at .notDetermined with NO
            // delegate callback, ever. `status` then sat at .requesting for
            // the life of the process, which disables the primary CTA: a
            // permanent spinner recoverable only by force-quitting
            // (audit 2026-08-04).
            armAuthorizationWatchdog()
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


    /// Fails the request if authorization never resolves. Cancelled by the
    /// authorization delegate on any real answer, including denial.
    private func armAuthorizationWatchdog() {
        fixWatchdog?.cancel()
        fixWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, self.status == .requesting,
                  self.manager.authorizationStatus == .notDetermined else { return }
            self.status = .failed
        }
    }

    private func requestFix() {
        if isStreaming {
            // requestLocation() while startUpdatingLocation() is live is
            // documented as unsupported and in practice often never delivers.
            // Restarting the stream instead forces CoreLocation to redeliver
            // its current fix immediately through the same delegate path.
            manager.stopUpdatingLocation()
            manager.startUpdatingLocation()
        } else {
            manager.requestLocation()
        }
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
    private func settle(_ newStatus: Status, measuredAt: Date? = nil) {
        fixWatchdog?.cancel()
        Task { @MainActor in
            if let measuredAt { self.lastFixAt = measuredAt }
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
                self.fixWatchdog?.cancel()
                // Stream FIRST, parked fix second. In the old order requestFix()
                // ran while isStreaming was still false, took the
                // requestLocation() branch, and beginStream() then started the
                // stream underneath it — recreating the exact unsupported
                // combination this class exists to avoid, on the first-grant
                // path every new user (and every App Review) hits
                // (audit 2026-08-05).
                if self.continuousRequested {
                    self.beginStream()
                }
                // `.failed` belongs here too: the authorization watchdog parks
                // an unanswered prompt at .failed, and a grant arriving after
                // that (the user turned Location Services on in Settings and
                // came back) has to start a fix or the CTA never recovers.
                if self.status == .requesting || self.status == .denied
                    || self.status == .failed {
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
        guard let location = locations.last else {
            settle(.failed)
            return
        }
        // While a caller is actively WAITING, refuse cached fixes. The restart
        // trick (and a stream's first post-start delivery) hands back
        // CoreLocation's cached location — after a tunnel or a drive that can
        // be from a mile back, and the .got observer would join there, stamp
        // it fresh, and release a parked send with the wrong coordinate.
        // Silent-and-wrong is worse than the alert the watchdog gives
        // (audit 2026-08-05). Display-path deliveries (not .requesting) stay
        // unfiltered: a stale pin beats no pin, and it self-heals.
        // Refuse stale deliveries ONLY where refusal is recoverable: a live
        // stream redelivers within seconds and the watchdog bounds the worst
        // case. On the one-shot path (the extension never streams) a refusal
        // is terminal — requestLocation delivers exactly one fix — and a
        // retry can't be funded either: the extension's poll gives the whole
        // acquisition ~5 s, less than a second CoreLocation round-trip needs
        // (audits 2026-08-05, twice). So one-shots accept the newest fix
        // available, and lastFixAt records its HONEST measurement time for
        // the caller to stamp the cache with — never receipt time.
        let age = Date().timeIntervalSince(location.timestamp)
        if status == .requesting, isStreaming, age > Self.freshFixMaxAge {
            return
        }
        // Just-resumed display path: refuse a stale FIRST delivery so the map
        // doesn't assert a position the user has driven away from. Bounded to
        // the first accepted fix — every later tick is unfiltered, so a
        // stationary user's dot never disappears.
        if awaitingFirstFreshFix, isStreaming, age > Self.staleOnResumeMaxAge {
            return
        }
        awaitingFirstFreshFix = false
        // lastFixAt travels INSIDE settle's main-actor hop, atomic with the
        // status write — two separate Tasks had no formal ordering guarantee.
        settle(.got(location.coordinate), measuredAt: location.timestamp)
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
