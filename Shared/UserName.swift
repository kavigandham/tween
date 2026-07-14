import Foundation

/// The local user's display name — what other participants see in their
/// bubbles when this device sends "I'm in", proposes a spot, etc.
///
/// Stored in the App Group suite so the host app (which captures the name
/// during onboarding) and the iMessage extension (which uses it when sending)
/// agree. Plain string; no PII beyond a chosen name.
/// Durable per-install identity for cross-device participant matching.
///
/// iMessage's `localParticipantIdentifier` is scoped to the device (a peer's
/// roster entry carries a UUID minted on THEIR device, so IDs never match
/// across devices), and display names collide (two users both defaulting to
/// "You"). This UUID is minted once into the App Group and never changes, so
/// every payload this install emits identifies the user the same way — across
/// conversations, renames, and the app/extension boundary.
enum TweenIdentity {
    static let storageKey = "tween.identity.stableID"

    static var stableID: String {
        let defaults = UserDefaults(suiteName: LocationCache.appGroup)
        if let existing = defaults?.string(forKey: storageKey), !existing.isEmpty {
            return existing
        }
        let minted = UUID().uuidString
        defaults?.set(minted, forKey: storageKey)
        return minted
    }
}

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

    /// The fallback shown for a PEER whose payload carried no real name — either
    /// empty (a modern unnamed sender) or a legacy literal "You" (an unnamed
    /// sender from before the fix). Never call this for the local user: self is
    /// always shown as "You". A trimmed real name passes through untouched.
    static func peerDisplayName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == fallback { return "Friend" }
        return trimmed
    }

    static func save(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaults?.set(trimmed, forKey: storageKey)
    }
}
