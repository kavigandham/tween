import Foundation
import MapKit

/// `MKLocalSearch.start()` can stall FOREVER under geod throttling (observed
/// 2026-07-31: a throttled request simply never called back — the extension's
/// snapshotter had the same failure mode). This wrapper races the callback
/// against a hard deadline and cancels the search on timeout, so a stalled
/// request degrades to "no results" instead of a spinner that never ends.
///
/// Deliberately built on the callback API + a resume-once guard rather than a
/// task-group race: a task group awaits its unfinished children on scope exit,
/// so a search that ignores cancellation would block the "timeout" path
/// exactly when it matters.
enum DeadlinedSearch {

    static func mapItems(for request: MKLocalSearch.Request,
                         seconds: TimeInterval = 8) async -> [MKMapItem] {
        await run(MKLocalSearch(request: request), seconds: seconds)
    }

    static func mapItems(for request: MKLocalPointsOfInterestRequest,
                         seconds: TimeInterval = 8) async -> [MKMapItem] {
        await run(MKLocalSearch(request: request), seconds: seconds)
    }

    private static func run(_ search: MKLocalSearch, seconds: TimeInterval) async -> [MKMapItem] {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            search.start { response, _ in
                guard once.claim() else { return }
                continuation.resume(returning: response?.mapItems ?? [])
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                guard once.claim() else { return }
                search.cancel()
                continuation.resume(returning: [])
            }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return false }
            resumed = true
            return true
        }
    }
}
