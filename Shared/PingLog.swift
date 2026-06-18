import Foundation

/// Per-friend ping history and incoming-reply bookkeeping, shared across the
/// host app and extension via the App Group suite.
///
/// The log is a `[friendID: Date]` map encoded under one key — an atomic
/// single-key write, like the rest of the cache. Stores timestamps only.
enum PingLog {
    static let storageKey = "pingLog"
    static let lastReplyKey = "lastIncomingReplyAt"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: LocationCache.appGroup)
    }

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

    static func clear() {
        defaults?.removeObject(forKey: storageKey)
        defaults?.removeObject(forKey: lastReplyKey)
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
