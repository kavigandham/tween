import Foundation

/// How far the user is willing to drive for a casual meetup.
///
/// This is a SOFT preference, not a filter (product decision 2026-08-02:
/// "rank them but don't disregard places, just have it be not as promising").
/// Over-limit spots still appear in the list — they just carry a ranking
/// penalty so genuinely-close options surface first. Hard-filtering would
/// strand the user with an empty list whenever their area is sparse, and the
/// honest answer in that case is "here's the closest thing, it's 35 minutes",
/// not silence.
///
/// Stored in App Group UserDefaults so the extension ranks the same way the
/// host app does. Coordinates and preferences only — no PII (constraint 6).
enum DriveTimePreference {
    /// Presets in minutes. `nil` (the "Any" chip) means no preference.
    static let options: [Int] = [10, 20, 30, 45]

    private static let key = "tween.maxDriveMinutes"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: LocationCache.appGroup) ?? .standard
    }

    /// The user's cap in minutes, or nil for "Any".
    static var maxMinutes: Int? {
        get {
            let stored = defaults.integer(forKey: key)
            return stored > 0 ? stored : nil
        }
        set {
            if let newValue, newValue > 0 {
                defaults.set(newValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    static var maxSeconds: TimeInterval? {
        maxMinutes.map { TimeInterval($0 * 60) }
    }

    /// Multiplier applied to a spot's ranking score when someone's drive
    /// exceeds the cap. Ramps in rather than cliff-edging: 1 minute over is
    /// barely penalised, double the limit is heavily penalised. A cliff would
    /// make a 21-minute spot rank below a 40-minute one under a 20-minute cap,
    /// which is obviously wrong.
    ///
    /// Returns 1.0 (no effect) when no preference is set or nothing exceeds it.
    static func penaltyMultiplier(worstETA: TimeInterval) -> Double {
        guard let cap = maxSeconds, worstETA > cap, cap > 0 else { return 1 }
        let overage = (worstETA - cap) / cap
        return 1 + min(overage, 2) * 1.5
    }

    /// True when this spot asks someone to drive longer than the user wanted —
    /// the flag the UI uses to mark a row as "over your limit".
    static func exceedsLimit(worstETA: TimeInterval) -> Bool {
        guard let cap = maxSeconds else { return false }
        return worstETA > cap
    }
}
