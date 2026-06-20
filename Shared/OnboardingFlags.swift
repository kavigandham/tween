import Foundation

/// Persistent onboarding flags shared across the app and extension via the
/// App Group suite.
enum OnboardingFlags {
    private static let appGroup = "group.com.kavigandham.tween"
    private static let hasSeenOnboardingKey = "tween.onboarding.hasSeen"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    static var hasSeenOnboarding: Bool {
        get { defaults?.bool(forKey: hasSeenOnboardingKey) ?? false }
        set { defaults?.set(newValue, forKey: hasSeenOnboardingKey) }
    }
}

/// The user's own display name, shared across the app and extension via the App
/// Group so invite bubbles can say who sent them. Set in the host app; read by
/// the extension when composing a bubble.
enum UserProfile {
    private static let displayNameKey = "userName"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: LocationCache.appGroup)
    }

    static var displayName: String? {
        get { defaults?.string(forKey: displayNameKey) }
        set { defaults?.set(newValue, forKey: displayNameKey) }
    }
}
