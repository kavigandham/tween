import Foundation
import UserNotifications

/// "Leave-by reminders" — a local notification fired when it's time to head
/// out, derived from the meetup's arrival time minus this person's predicted
/// travel time.
///
/// Local notifications only: no server, no push tokens, nothing leaves the
/// device (constraint 8). SCHEDULING happens in the HOST APP — a Messages
/// extension shouldn't be requesting notification authorization, and the
/// extension is short-lived anyway. `cancel()` is the one member the
/// extension may call: removing a pending request needs no authorization,
/// and leaving from inside iMessage must not leave a "time to head out"
/// nudge armed for a meetup the user just left (audit 2026-08-06). Whether
/// an extension's notification center reaches the host's pending requests is
/// unverified on device, so this is belt-and-braces: LeaveByRefresher also
/// collects the orphan on the host's next foreground.
enum LeaveByReminder {
    /// One identifier, so re-planning the same meetup replaces its reminder
    /// instead of stacking a second one.
    static let identifier = "tween.leaveBy"

    /// How early to nudge, on top of travel time — time to find keys, get to
    /// the car, and so on.
    static let bufferSeconds: TimeInterval = 5 * 60

    /// Asks for notification permission. Returns false when denied — callers
    /// surface that rather than silently doing nothing.
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    /// Fire date for a given arrival and travel time.
    static func fireDate(arrivalDate: Date, travelTime: TimeInterval) -> Date {
        arrivalDate.addingTimeInterval(-(travelTime + bufferSeconds))
    }

    /// Schedules (or replaces) the reminder. Returns the scheduled fire date,
    /// or nil when it would already be in the past — you can't be reminded to
    /// leave for something you should have left for already, and scheduling a
    /// past trigger silently no-ops in UNUserNotificationCenter, which would
    /// look like success to the caller.
    @discardableResult
    static func schedule(spotName: String,
                         arrivalDate: Date,
                         travelTime: TimeInterval,
                         now: Date = Date()) async -> Date? {
        let fire = fireDate(arrivalDate: arrivalDate, travelTime: travelTime)
        guard fire > now else { return nil }
        guard await requestAuthorization() else { return nil }

        let content = UNMutableNotificationContent()
        content.title = "Time to head out"
        content.body = "Leave now to reach \(spotName) by \(Self.timeFormatter.string(from: arrivalDate))."
        content.sound = .default

        // Interval, not calendar components. A calendar trigger built from
        // [.year…​.minute] truncates seconds, so a fire date under 60s out
        // rounds INTO THE PAST and never fires — while `add` still reports
        // success, so the UI claimed a reminder that could not arrive. Calendar
        // components are also wall-clock, so crossing a timezone shifted the
        // reminder. An interval is neither (2026-08-04).
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: max(fire.timeIntervalSince(now), 1), repeats: false))

        do {
            let center = UNUserNotificationCenter.current()
            // Add FIRST, remove after: the old order retired a working
            // reminder and then had nothing to replace it with if `add` threw.
            try await center.add(request)
            return fire
        } catch {
            return nil
        }
    }

    static func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// True when a leave-by reminder is currently pending.
    static func isArmed() async -> Bool {
        await pendingFireDate() != nil
    }

    /// When the pending reminder is set to fire, or nil if none is armed.
    /// Used by `LeaveByRefresher` to decide whether live traffic has drifted
    /// far enough to be worth rescheduling.
    static func pendingFireDate() async -> Date? {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        guard let request = pending.first(where: { $0.identifier == identifier })
        else { return nil }
        if let interval = request.trigger as? UNTimeIntervalNotificationTrigger {
            return interval.nextTriggerDate()
        }
        // Reminders scheduled by a build before 2026-08-04 still carry a
        // calendar trigger; keep reading them so an upgrade doesn't orphan one.
        return (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

extension LeaveByReminder {
    /// Fires immediately when a re-measurement finds you should ALREADY have
    /// left. Scheduling a past trigger silently does nothing, so without this
    /// the worst case — traffic degraded past the point of arriving on time —
    /// was the one case that produced no notification at all.
    static func notifyLeaveNow(spotName: String, arrivalDate: Date) async {
        guard await requestAuthorization() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Leave now"
        content.body = "Traffic got worse — leave now to reach \(spotName) near \(timeFormatter.string(from: arrivalDate))."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        try? await center.add(request)
    }
}
