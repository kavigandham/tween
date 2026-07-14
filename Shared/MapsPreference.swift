import Foundation

/// Which maps app every "Open in Maps" button launches.
///
/// One preference, set in the host app's Settings sheet, read by BOTH
/// processes at tap time via the App Group (constraint 6: preferences are
/// sanctioned App Group content). Replaces the old Apple-and-Google
/// side-by-side button pairs — the user picks once, every surface obeys.
enum PreferredMapsApp: String, CaseIterable, Identifiable {
    case apple
    case google

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple:  return "Apple Maps"
        case .google: return "Google Maps"
        }
    }

    var icon: String {
        switch self {
        case .apple:  return "map"
        case .google: return "globe"
        }
    }
}

enum MapsPreference {
    private static let key = "tween.pref.mapsApp"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: LocationCache.appGroup)
    }

    /// Defaults to Apple Maps — installed on every device, zero setup. An
    /// unknown stored value (future provider removed in a downgrade) also
    /// falls back to Apple rather than crashing or dead-ending.
    static var current: PreferredMapsApp {
        get {
            defaults?.string(forKey: key)
                .flatMap(PreferredMapsApp.init(rawValue:)) ?? .apple
        }
        set { defaults?.set(newValue.rawValue, forKey: key) }
    }
}
