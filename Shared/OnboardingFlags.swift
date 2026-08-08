import Foundation

/// Persistent onboarding flags shared across the app and extension via the
/// App Group suite.
enum OnboardingFlags {
    private static let appGroup = LocationCache.appGroup
    private static let hasSeenOnboardingKey = "tween.onboarding.hasSeen"

    // Cached suite (lag audit 2026-08-08) — see LocationCache.sharedDefaults.
    private static var defaults: UserDefaults? { LocationCache.sharedDefaults }

    static var hasSeenOnboarding: Bool {
        get { defaults?.bool(forKey: hasSeenOnboardingKey) ?? false }
        set { defaults?.set(newValue, forKey: hasSeenOnboardingKey) }
    }
}
