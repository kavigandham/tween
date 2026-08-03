import Foundation
import MapKit
import CoreLocation

/// Keeps an armed leave-by reminder honest.
///
/// The paywall promises "a nudge when it's time to head out, based on **live
/// drive time**". The reminder was scheduled once, from the ETA at the moment
/// you tapped the button, and never revisited — so if traffic got worse
/// afterwards it fired too late, which is the one failure the feature exists to
/// prevent. That made the copy a false promise (audit 2026-08-02).
///
/// This re-measures the drive whenever the app comes to the foreground and
/// moves the reminder if it has drifted. Foreground-only is deliberate:
/// re-checking while backgrounded would need Always location, which this app
/// does not ask for and does not need (constraint 4). In practice you open
/// Tween on the way out, which is exactly when the correction matters.
enum LeaveByRefresher {
    /// Don't churn the notification for noise. Traffic estimates wobble by a
    /// minute or two constantly; only a meaningful drift is worth rescheduling.
    static let significantDriftSeconds: TimeInterval = 5 * 60

    /// Re-measures and reschedules if needed. No-ops unless there's a scheduled
    /// plan with a spot, an armed reminder, and a known origin.
    @discardableResult
    static func refresh(from origin: CLLocationCoordinate2D?) async -> Date? {
        let plan = MeetupPlanStore.current
        guard let arrival = plan.arrivalDate,
              let spotName = plan.spotName,
              let destination = plan.coordinate,
              let origin,
              await LeaveByReminder.isArmed()
        else { return nil }

        // Past meetups are the store's problem, not ours — but don't waste a
        // routing call on one.
        guard arrival > Date() else {
            LeaveByReminder.cancel()
            return nil
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = plan.mode(for: TweenIdentity.stableID).transportType
        request.arrivalDate = arrival

        guard let seconds = await DeadlinedSearch.eta(for: request, seconds: 10) else {
            // Couldn't re-measure — leave the existing reminder alone rather
            // than replacing a real estimate with a guess.
            return nil
        }

        // The plan may have changed while that routing call was in flight —
        // the user can foreground the app and immediately re-plan. Without
        // this, a stale in-flight refresh would overwrite the reminder they
        // just deliberately set, for the OLD time and possibly the old place,
        // while the sheet still read "Reminder set for …" (audit 2026-08-03).
        guard MeetupPlanStore.current == plan else { return nil }

        let newFire = LeaveByReminder.fireDate(arrivalDate: arrival, travelTime: seconds)
        guard let currentFire = await LeaveByReminder.pendingFireDate(),
              abs(newFire.timeIntervalSince(currentFire)) >= significantDriftSeconds
        else { return nil }

        // Traffic got bad enough that leaving on time is no longer possible.
        // `schedule` refuses past fire dates and returns nil, which would leave
        // the original too-late reminder armed and say nothing — the exact
        // failure this class exists to catch. Tell them instead.
        guard newFire > Date() else {
            await LeaveByReminder.notifyLeaveNow(spotName: spotName, arrivalDate: arrival)
            return nil
        }

        return await LeaveByReminder.schedule(spotName: spotName,
                                              arrivalDate: arrival,
                                              travelTime: seconds)
    }
}
