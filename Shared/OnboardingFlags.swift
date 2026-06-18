import Foundation

/// Persistent onboarding flags shared across the app and extension via the
/// App Group suite.
enum OnboardingFlags {
    private static let appGroup = "group.com.hassan.tween"
    private static let hasSeenOnboardingKey = "tween.onboarding.hasSeen"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    static var hasSeenOnboarding: Bool {
        get { defaults?.bool(forKey: hasSeenOnboardingKey) ?? false }
        set { defaults?.set(newValue, forKey: hasSeenOnboardingKey) }
    }
}
