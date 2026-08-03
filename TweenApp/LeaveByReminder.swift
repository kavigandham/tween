import Foundation
import UserNotifications

/// "Leave-by reminders" — a local notification fired when it's time to head
/// out, derived from the meetup's arrival time minus this person's predicted
/// travel time.
///
/// Local notifications only: no server, no push tokens, nothing leaves the
/// device (constraint 8). Scheduling happens in the HOST APP — a Messages
/// extension shouldn't be requesting notification authorization, and the
/// extension is short-lived anyway.
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

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fire)
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))

        do {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
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
        guard let request = pending.first(where: { $0.identifier == identifier }),
              let trigger = request.trigger as? UNCalendarNotificationTrigger
        else { return nil }
        return trigger.nextTriggerDate()
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
