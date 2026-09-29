import Foundation
import UserNotifications

/// Arrival Sync's notifications: "X is on the way", and the "time to go" that
/// fires when this device's own departure time arrives.
///
/// LOCAL notifications only — no push tokens, no server, nothing leaves the
/// device (constraint 8). The event travels in the iMessage bubble; the WAITING
/// happens here, on the receiving device, which is what lets a serverless app
/// deliver a reminder ten minutes into the future with nothing left running.
///
/// Sibling of `LeaveByReminder`, deliberately not folded into it: that one is
/// keyed to a PLANNED arrival the user typed ("let's meet at 7") and owns a
/// single identifier, while this one is keyed to somebody else's actual
/// departure and needs one identifier per meetup per person. They can be armed
/// at the same time for different meetups, so sharing an identifier would have
/// them silently evict each other.
///
/// The hard-won mechanics are inherited from `LeaveByReminder` rather than
/// rediscovered:
///   * `UNTimeIntervalNotificationTrigger`, NEVER calendar components — a
///     calendar trigger truncates seconds, so a fire date under 60 s out
///     rounds into the past and never fires while `add` still reports success;
///     it is also wall-clock, so crossing a timezone moves the reminder
///     (2026-08-04).
///   * A past fire date is fired IMMEDIATELY instead of scheduled, because
///     scheduling one silently no-ops and the caller would believe it worked.
///   * Authorization is requested only from the HOST APP. The extension may
///     schedule against an EXISTING grant and may cancel, but must never put
///     up a permission alert from inside iMessage.
enum ArrivalSyncNotifier {
    /// Emoji live in the copy on purpose — these land on a lock screen, and
    /// "🚗" is read before the sentence is.
    private static let carEmoji = "🚗"

    /// The reminder for one participant in one meetup.
    ///
    /// Per-meetup AND per-participant so that re-delivering the same event
    /// REPLACES the pending request instead of stacking a second one — which
    /// is the whole of "duplicate taps/events cannot produce duplicate
    /// notifications", handled by iOS rather than by a seen-event list we
    /// would have to keep in sync.
    static func reminderIdentifier(meetingID: String, participantID: String) -> String {
        "arrival-sync-\(meetingID)-\(participantID)"
    }

    /// The "somebody left" notice. Keyed to the DEPARTING person, so two
    /// people leaving produce two notices while one person's event arriving
    /// twice produces one.
    static func departureIdentifier(meetingID: String, departingID: String) -> String {
        "arrival-sync-left-\(meetingID)-\(departingID)"
    }

    /// Deep link carried in `userInfo`, so tapping a notification opens the
    /// meetup rather than just the app. See `OnboardingView.handleIncomingURL`.
    static let deepLinkKey = "tweenDeepLink"
    static let meetupDeepLink = "tween://meetup"

    // MARK: - Authorization

    /// Whether notifications are ALREADY allowed. Never prompts.
    ///
    /// This is the check the Messages extension uses: it may use a grant the
    /// host app obtained, but a permission alert must not appear over a
    /// conversation because somebody tapped a bubble. `notDetermined` reads as
    /// false here, and the host's reconciliation pass asks properly later.
    static func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied, .notDetermined: return false
        @unknown default: return false
        }
    }

    // MARK: - Copy
    //
    // Centralised so the three surfaces (notification, extension strip, host
    // banner) cannot drift into describing the same state three ways — and so
    // the wording rule from the spec holds in one place: ETA, departure,
    // arrival, leave time. Never "tracking", never "location".

    static func timeToGoTitle() -> String { "Time to go \(carEmoji)" }

    static func timeToGoBody(departingName: String) -> String {
        "Leave now to arrive around the same time as \(departingName)."
    }

    static func onTheWayTitle(departingName: String) -> String {
        "\(departingName) is on the way \(carEmoji)"
    }

    static func justLeftTitle(departingName: String) -> String {
        "\(departingName) just left \(carEmoji)"
    }

    /// The reciprocal prompt. A departure notice that only informs leaves the
    /// other half of the coordination undone — the person reading it is the
    /// next one to leave, and the useful next action is telling everyone so.
    static func tellThemPrompt(departingName: String) -> String {
        "Tap to tell \(departingName) when you leave."
    }

    /// One person's row in a leave-time read-out: "Shiraaz in 10 min", or
    /// "Shiraaz should leave now".
    static func leaveLine(for entry: ArrivalParticipantState,
                          targetArrival: Date,
                          now: Date = Date()) -> String? {
        guard entry.departureStatus != .departed,
              let travel = entry.estimatedTravelTime else { return nil }
        if ArrivalSyncTiming.shouldLeaveNow(targetArrival: targetArrival,
                                            travelTime: travel, now: now) {
            return "\(entry.displayName) should leave now"
        }
        let minutes = ArrivalSyncTiming.leaveInMinutes(
            targetArrival: targetArrival, travelTime: travel, now: now)
        return "\(entry.displayName) in \(minutes) min"
    }

    /// The banner shown to the person who just left: their own ETA, plus when
    /// everyone else should go.
    ///
    /// Lives here, in `Shared`, rather than on the Messages controller — both
    /// the extension and the host describe this state, the numbers come from
    /// one place, and a copy helper on a target the test bundle cannot import
    /// is a copy helper with no tests.
    static func departureStatus(sync: ArrivalSyncState?,
                                seconds: Int?,
                                now: Date = Date()) -> String {
        let eta = seconds.map { "On your way — about \(max(Int((Double($0) / 60).rounded()), 1)) min" }
            ?? "On your way"
        guard let sync else { return eta }
        let waiting = sync.pending.compactMap {
            leaveLine(for: $0, targetArrival: sync.targetArrivalTime, now: now)
        }
        guard !waiting.isEmpty else { return eta }
        // One name reads as a sentence; several read as a list.
        if waiting.count == 1 { return "\(eta) · \(waiting[0])" }
        return "\(eta) · leave: " + waiting.joined(separator: ", ")
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    // MARK: - Scheduling

    /// Arms (or re-arms) this device's "time to go" for `departure`.
    ///
    /// Returns the fire date, or nil when nothing was scheduled — a departure
    /// at or before now (the caller should have fired `notifyLeaveNow` for
    /// that), or no authorization. Callers must handle nil by showing the
    /// departure time in-app, which works with notifications denied.
    @discardableResult
    static func scheduleReminder(meetingID: String,
                                 participantID: String,
                                 departingName: String,
                                 spotName: String,
                                 departure: Date,
                                 now: Date = Date()) async -> Date? {
        // A non-positive interval is refused by UNTimeIntervalNotification-
        // Trigger, and rounding it up to 1 s would fire a "time to go" the
        // instant the bubble was opened, duplicating the immediate notice the
        // caller already posted for that case.
        guard departure > now else { return nil }
        guard await isAuthorized() else { return nil }

        let content = UNMutableNotificationContent()
        content.title = timeToGoTitle()
        content.body = timeToGoBody(departingName: departingName)
        content.sound = .default
        content.userInfo = [deepLinkKey: meetupDeepLink]
        // Grouped by meetup, so a chat's notices collapse together in
        // Notification Centre instead of interleaving with another meetup's.
        content.threadIdentifier = "arrival-sync-\(meetingID)"

        let request = UNNotificationRequest(
            identifier: reminderIdentifier(meetingID: meetingID, participantID: participantID),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: max(departure.timeIntervalSince(now), 1), repeats: false))

        do {
            // Add over the top: `add` REPLACES a request with the same
            // identifier, so this is the idempotent path. Removing first would
            // open a window where a throw left the user with no reminder at
            // all (the ordering lesson in `LeaveByReminder.schedule`).
            try await UNUserNotificationCenter.current().add(request)
            return departure
        } catch {
            return nil
        }
    }

    /// The immediate case: this person should already be leaving.
    ///
    /// Combines the two messages the spec keeps separate when there is time to
    /// wait — telling someone "Hassan is on the way, we'll let you know when
    /// to leave" and then "leave now" a second later would be two buzzes for
    /// one fact.
    static func notifyLeaveNow(meetingID: String,
                               departingID: String,
                               departingName: String,
                               spotName: String) async {
        guard await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = justLeftTitle(departingName: departingName)
        content.body = "Leave now to arrive around the same time. "
            + tellThemPrompt(departingName: departingName)
        content.sound = .default
        content.userInfo = [deepLinkKey: meetupDeepLink]
        content.threadIdentifier = "arrival-sync-\(meetingID)"
        await post(content,
                   identifier: departureIdentifier(meetingID: meetingID,
                                                   departingID: departingID))
    }

    /// The informational case: somebody left, this person has time in hand.
    ///
    /// Posted even though the recipient is, at this exact moment, looking at
    /// Tween — because it is also the record of the departure in Notification
    /// Centre, it names the leave time they will want again in five minutes,
    /// and it carries the reciprocal prompt.
    static func notifyOnTheWay(meetingID: String,
                               departingID: String,
                               departingName: String,
                               spotName: String,
                               departure: Date) async {
        guard await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = onTheWayTitle(departingName: departingName)
        content.body = "Leave at \(timeFormatter.string(from: departure)) to reach \(spotName) together. "
            + tellThemPrompt(departingName: departingName)
        content.sound = .default
        content.userInfo = [deepLinkKey: meetupDeepLink]
        content.threadIdentifier = "arrival-sync-\(meetingID)"
        await post(content,
                   identifier: departureIdentifier(meetingID: meetingID,
                                                   departingID: departingID))
    }

    private static func post(_ content: UNMutableNotificationContent,
                             identifier: String) async {
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            // 1 s, not nil: a nil trigger delivers immediately but is treated
            // as a foreground-only presentation on some paths, and 1 s keeps
            // this on exactly the same code path as the scheduled variant.
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Cancellation

    /// Retires one person's reminder — they departed, or the meetup ended.
    /// Needs no authorization, so the extension may call it.
    static func cancelReminder(meetingID: String, participantID: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [reminderIdentifier(meetingID: meetingID,
                                                 participantID: participantID)])
    }

    /// Retires everything this device armed for a meetup: the local user's
    /// reminder plus every participant's departure notice.
    ///
    /// Takes the roster explicitly because `removePendingNotificationRequests`
    /// has no prefix form — identifiers must be named. Callers pass the sync's
    /// own participant list, which is exactly who could have a request.
    static func cancelAll(meetingID: String, participantIDs: [String]) {
        var identifiers = participantIDs.map {
            reminderIdentifier(meetingID: meetingID, participantID: $0)
        }
        identifiers += participantIDs.map {
            departureIdentifier(meetingID: meetingID, departingID: $0)
        }
        guard !identifiers.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        // Delivered ones too: a "time to go" sitting on the lock screen for a
        // meetup that was cancelled is worse than no notification, because it
        // is still an instruction.
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// When this device's pending reminder is set to fire, or nil if none is
    /// armed. Lets the reconciliation pass tell "not armed" from "armed for
    /// the right time" without re-adding on every foreground.
    static func pendingFireDate(meetingID: String, participantID: String) async -> Date? {
        let wanted = reminderIdentifier(meetingID: meetingID, participantID: participantID)
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        guard let request = pending.first(where: { $0.identifier == wanted }),
              let trigger = request.trigger as? UNTimeIntervalNotificationTrigger
        else { return nil }
        return trigger.nextTriggerDate()
    }
}
