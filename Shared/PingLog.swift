import Foundation

/// Per-friend ping history and incoming-reply bookkeeping, shared across the
/// host app and extension via the App Group suite.
///
/// The log is a `[friendID: Date]` map encoded under one key — an atomic
/// single-key write, like the rest of the cache. Stores timestamps only.
enum PingLog {
    static let storageKey = "pingLog"
    static let lastReplyKey = "lastIncomingReplyAt"
    static let genericInviteKey = "lastGenericInviteAt"
    static let genericInviteCountKey = "lastGenericInviteCount"

    // Cached suite (lag audit 2026-08-08) — see LocationCache.sharedDefaults.
    private static var defaults: UserDefaults? { LocationCache.sharedDefaults }

    /// Records that we just pinged a friend (overwrites any earlier stamp).
    static func logPing(for friendID: UUID, at date: Date = Date()) {
        var log = loadLog()
        log[friendID.uuidString] = date
        save(log)
    }

    /// When we last pinged this friend, or `nil` if never.
    static func lastPing(for friendID: UUID) -> Date? {
        loadLog()[friendID.uuidString]
    }

    /// A ping is only shown as PENDING for a bounded window. Without this a
    /// friend who never joins pollutes the Current-meetup list forever, across
    /// meetups and relaunches (E2E audit 2026-08-07).
    static let pendingTTL: TimeInterval = 6 * 60 * 60

    /// The ping stamp only if it is still within the pending window — used by
    /// the display so a stale ping ages out on its own.
    static func activePing(for friendID: UUID, now: Date = Date()) -> Date? {
        guard let at = lastPing(for: friendID) else { return nil }
        return now.timeIntervalSince(at) <= pendingTTL ? at : nil
    }

    /// Whether a joined participant's display name identifies this friend.
    /// iMessage never hands the extension a sender's handle, so identity
    /// matching across the contact/participant namespaces is impossible — we
    /// match on name. Full-string equality alone missed the common case: a
    /// contact saved "Kavi Gandham" joining with the short profile name "Kavi"
    /// showed as BOTH "In" and "Pending" forever (E2E audit 2026-08-07). So a
    /// shorter name matches when its tokens are the leading tokens of the
    /// longer — "Kavi" resolves "Kavi Gandham", without matching "Sam".
    static func namesMatch(_ a: String, _ b: String) -> Bool {
        let ta = a.lowercased().split(separator: " ").map(String.init)
        let tb = b.lowercased().split(separator: " ").map(String.init)
        guard let firstA = ta.first, let firstB = tb.first else { return false }
        if ta == tb { return true }
        let (short, long) = ta.count <= tb.count ? (ta, tb) : (tb, ta)
        guard firstA == firstB else { return false }
        return Array(long.prefix(short.count)) == short
    }

    /// Timestamp of the most recent inbound bubble the extension decoded. Set by
    /// `MessagesViewController.didReceive`; read by the host app to surface a
    /// "they replied" banner.
    static var lastIncomingReplyAt: Date? {
        get { defaults?.object(forKey: lastReplyKey) as? Date }
        set {
            if let newValue {
                defaults?.set(newValue, forKey: lastReplyKey)
            } else {
                defaults?.removeObject(forKey: lastReplyKey)
            }
        }
    }

    /// Timestamp for a sent invite where Apple Messages did not expose a named
    /// recipient back to Tween, such as when the user typed a handle manually.
    static var lastGenericInviteAt: Date? {
        get { defaults?.object(forKey: genericInviteKey) as? Date }
        set {
            if let newValue {
                defaults?.set(newValue, forKey: genericInviteKey)
            } else {
                defaults?.removeObject(forKey: genericInviteKey)
            }
        }
    }

    static var lastGenericInviteCount: Int {
        let count = defaults?.integer(forKey: genericInviteCountKey) ?? 0
        return max(count, 1)
    }

    static func logGenericInvite(at date: Date = Date(), count: Int = 1) {
        // Two keys, deliberately NOT atomic (accepted exception to the
        // one-blob rule): this is a display-only banner hint, the count
        // clamps to ≥1 on read, and a torn read costs a cosmetic frame.
        lastGenericInviteAt = date
        defaults?.set(max(count, 1), forKey: genericInviteCountKey)
    }

    static func clear() {
        defaults?.removeObject(forKey: storageKey)
        defaults?.removeObject(forKey: lastReplyKey)
        defaults?.removeObject(forKey: genericInviteKey)
        defaults?.removeObject(forKey: genericInviteCountKey)
    }

    // MARK: - Atomic single-key codec

    private static func loadLog() -> [String: Date] {
        guard let data = defaults?.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
    }

    private static func save(_ log: [String: Date]) {
        guard let data = try? JSONEncoder().encode(log) else { return }
        defaults?.set(data, forKey: storageKey)
    }
}

/// Formats a past date as a short, human relative string for ping rows.
enum RelativeTime {
    static func string(from date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        // Treat future/near-zero stamps as the present.
        guard seconds >= 60 else { return "just now" }

        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }

        let hours = Int(seconds / 3600)
        if hours < 24 { return "\(hours)h ago" }

        let days = Int(seconds / 86_400)
        if days == 1 { return "yesterday" }
        return "\(days)d ago"
    }
}
