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
        let box = ContinuationBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.store(continuation)
                // The cancellation handler can fire before the continuation
                // was stored — settle immediately instead of waiting out the
                // deadline on work nobody wants (post-push audit M1: a
                // superseded ladder must stop, and the extension's
                // willResignActive cancel must not pin the search alive).
                if Task.isCancelled {
                    search.cancel()
                    box.take()?.resume(returning: [])
                    return
                }
                search.start { response, _ in
                    box.take()?.resume(returning: response?.mapItems ?? [])
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    guard let continuation = box.take() else { return }
                    search.cancel()
                    continuation.resume(returning: [])
                }
            }
        } onCancel: {
            guard let continuation = box.take() else { return }
            search.cancel()
            continuation.resume(returning: [])
        }
    }

    /// Holds the continuation so exactly ONE of the three racers — callback,
    /// deadline, task cancellation — resumes it.
    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[MKMapItem], Never>?

        func store(_ continuation: CheckedContinuation<[MKMapItem], Never>) {
            lock.lock()
            defer { lock.unlock() }
            self.continuation = continuation
        }

        func take() -> CheckedContinuation<[MKMapItem], Never>? {
            lock.lock()
            defer { lock.unlock() }
            let taken = continuation
            continuation = nil
            return taken
        }
    }
}
