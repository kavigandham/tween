import Foundation

/// The local user's display name — what other participants see in their
/// bubbles when this device sends "I'm in", proposes a spot, etc.
///
/// Stored in the App Group suite so the host app (which captures the name
/// during onboarding) and the iMessage extension (which uses it when sending)
/// agree. Plain string; no PII beyond a chosen name.
enum UserName {
    static let storageKey = "userName"
    static let fallback = "You"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: LocationCache.appGroup)
    }

    /// Returns the stored name, or nil if the user has never set one.
    /// Use `loadOrFallback()` when you need a non-nil display string.
    static func load() -> String? {
        let raw = defaults?.string(forKey: storageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }

    static func loadOrFallback() -> String {
        load() ?? fallback
    }

    static func save(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaults?.set(trimmed, forKey: storageKey)
    }

    static func clear() {
        defaults?.removeObject(forKey: storageKey)
    }
}
