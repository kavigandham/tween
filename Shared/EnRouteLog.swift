import Foundation

/// Who has said "leaving now", and how far out they were when they said it.
///
/// Deliberately DEVICE-LOCAL and deliberately small. An `.enroute` bubble is
/// an announcement, not shared state — its whole job is done by the caption in
/// the thread ("Belal is leaving now · about 12 min away"), which everyone
/// reads without tapping anything. This log is the bonus: the people who do
/// open Tween see a live "on the way" strip instead of having to scroll back.
///
/// Constraint 6 (App Group is unencrypted): ids and a travel time only. No
/// coordinates — where someone is en route FROM is not stored anywhere.
enum EnRouteLog {
    /// One person's departure.
    struct Mark: Codable, Equatable {
        let participantID: String
        let name: String
        /// Travel seconds as measured when they left. Nil when the sender's
        /// device couldn't produce one.
        let etaSeconds: Int?
        let sentAt: Date

        /// Seconds still to go, counted down from when they left. Nil when no
        /// ETA rode along; clamped at zero once they should have arrived.
        var remainingSeconds: Int? {
            guard let etaSeconds else { return nil }
            let elapsed = Int(Date().timeIntervalSince(sentAt))
            return max(etaSeconds - elapsed, 0)
        }

        /// "12 min away" / "Arriving now" / "On the way".
        var summary: String {
            guard let remaining = remainingSeconds else { return "On the way" }
            let minutes = Int((Double(remaining) / 60).rounded())
            return minutes <= 0 ? "Arriving now" : "\(minutes) min away"
        }
    }

    /// Departures go stale fast — a "leaving now" from this morning tells you
    /// nothing at dinner. Two hours covers any realistic meetup trip.
    static let ttl: TimeInterval = 2 * 60 * 60

    private static let prefix = "tween.enroute."

    private static var defaults: UserDefaults? { LocationCache.sharedDefaults }

    static func marks(key conversationKey: String) -> [Mark] {
        guard let data = defaults?.data(forKey: storageKey(conversationKey)),
              let decoded = try? JSONDecoder().decode([Mark].self, from: data)
        else { return [] }
        let cutoff = Date().addingTimeInterval(-ttl)
        return decoded.filter { $0.sentAt > cutoff }
    }

    /// Records (or refreshes) one person's departure. Atomic single-key JSON,
    /// like every other App Group writer here.
    static func note(_ mark: Mark, key conversationKey: String) {
        var current = marks(key: conversationKey)
        current.removeAll { $0.participantID == mark.participantID }
        current.append(mark)
        // Bound the blob: a big group chat must not accumulate forever.
        let trimmed = Array(current.sorted { $0.sentAt > $1.sentAt }.prefix(12))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        defaults?.set(data, forKey: storageKey(conversationKey))
        MeetupSync.post()
    }

    /// Wipes the log for a chat — a new round of voting, or a leave.
    static func clear(key conversationKey: String) {
        guard defaults?.data(forKey: storageKey(conversationKey)) != nil else { return }
        defaults?.removeObject(forKey: storageKey(conversationKey))
        MeetupSync.post()
    }

    private static func storageKey(_ conversationKey: String) -> String {
        prefix + conversationKey
    }
}
