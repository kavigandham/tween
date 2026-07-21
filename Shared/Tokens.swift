import SwiftUI
import UIKit

/// The single source of truth for Tween's visual design.
///
/// Everything visual — color, spacing, corner radius, type, motion, elevation —
/// flows from here so the host app and the Messages extension stay in lockstep
/// and a change lands everywhere at once. No view should hard-code a `Color`, a
/// font size, a padding number, or a shadow; reach for a token instead.
///
/// Custom (non-system) colors carry explicit light/dark variants via
/// `dynamicColor` so dark mode is correct without per-call-site branching.
/// System semantic colors (`.label`, `.systemBackground`, …) adapt on their own.
enum Tokens {

    // MARK: - Palette

    enum Palette {
        // Surfaces
        static let surface = Color(uiColor: .systemBackground)
        static let surfaceSecondary = Color(uiColor: .secondarySystemBackground)
        /// Opaque fill for text inputs (search bar, name field). Deliberately
        /// NOT a material: inputs sit inside the material bottom sheet, and
        /// material-on-material reads as a muddy "bar inside a bar".
        /// systemGray5 matches Apple Maps' search field in both modes
        /// (#E5E5EA light / #2C2C2E dark) — tertiarySystemFill was too faint
        /// to read as a field over the sheet blur.
        static let inputFill = Color(uiColor: .systemGray5)

        // Brand — a restrained midnight navy. Teal remains available to the
        // map as a functional result-pin colour; it no longer competes with
        // navigation, selection, and primary actions throughout the product.
        static let brand = dynamicColor(
            light: UIColor(red: 0.071, green: 0.196, blue: 0.322, alpha: 1),  // #123252
            dark:  UIColor(red: 0.176, green: 0.380, blue: 0.557, alpha: 1))   // #2D618E
        /// Interactive text, icons, selection marks, and native tint. Dark mode
        /// lifts the lightness so small affordances remain legible on glass;
        /// filled primary controls continue to use the deeper `brand` navy.
        static let accent = dynamicColor(
            light: UIColor(red: 0.071, green: 0.196, blue: 0.322, alpha: 1),  // #123252
            dark:  UIColor(red: 0.396, green: 0.710, blue: 0.918, alpha: 1))   // #65B5EA
        /// Foreground for content sitting on the navy action fill.
        static let onBrand = dynamicColor(
            light: UIColor.white,
            dark:  UIColor.white)
        static let brandLight = dynamicColor(
            light: UIColor(red: 0.918, green: 0.945, blue: 0.969, alpha: 1),  // #EAF1F7
            dark:  UIColor(red: 0.090, green: 0.145, blue: 0.208, alpha: 1))   // #172535
        static let neutralAction = dynamicColor(
            light: UIColor(red: 0.925, green: 0.941, blue: 0.957, alpha: 1),   // #ECF0F4
            dark:  UIColor(red: 0.122, green: 0.137, blue: 0.165, alpha: 1))   // #1F232A
        static let destructiveLight = dynamicColor(
            light: UIColor(red: 1.000, green: 0.918, blue: 0.918, alpha: 1),   // #FFEAEA
            dark:  UIColor(red: 0.282, green: 0.114, blue: 0.122, alpha: 1))   // #481D1F

        // Map pins — system colors so they track Increase Contrast and dark mode.
        // Each pin also carries a distinct glyph, so color is never the sole cue.
        static let pinSelf = Color(uiColor: .systemBlue)
        static let pinSelfActive = Color(uiColor: .systemBlue)
        static let pinFriend = Color(uiColor: .systemOrange)
        static let pinRideNeeded = Color(uiColor: .systemMint)
        static let pinFair = Color(uiColor: .systemYellow)
        static let pinMidpoint = Color(uiColor: .systemOrange)
        static let pinClosest = Color(uiColor: .systemGreen)
        static let pinResult = Color(uiColor: .systemTeal)

        // Text — semantic label colors, fully adaptive.
        static let textPrimary = Color(uiColor: .label)
        static let textSecondary = Color(uiColor: .secondaryLabel)
        static let textTertiary = Color(uiColor: .tertiaryLabel)

        // Status
        static let destructive = Color(uiColor: .systemRed)
        static let success = Color(uiColor: .systemGreen)
        static let warning = Color(uiColor: .systemOrange)

        // Fairness ramp — how lopsided a meetup's drive times are.
        static let fairnessGood = Color(uiColor: .systemGreen)
        static let fairnessOkay = Color(uiColor: .systemYellow)
        static let fairnessPoor = Color(uiColor: .systemOrange)

        /// UIColor equivalents for the Core Graphics bubble renderer, which draws
        /// with `UIColor` and cannot consume the SwiftUI `Color` tokens above.
        enum UI {
            static let pinSelf = UIColor.systemBlue
            static let pinSelfActive = UIColor.systemBlue
            static let pinFriend = UIColor.systemOrange
            static let pinRideNeeded = UIColor.systemMint
            static let pinFair = UIColor.systemYellow
            static let pinMidpoint = UIColor.systemOrange
            static let pinClosest = UIColor.systemGreen
            static let pinResult = UIColor.systemTeal
            static let brand = UIColor { traits in
                traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.176, green: 0.380, blue: 0.557, alpha: 1)      // #2D618E
                : UIColor(red: 0.071, green: 0.196, blue: 0.322, alpha: 1)      // #123252
            }
        }
    }

    // MARK: - Spacing (4pt grid)

    enum Spacing {
        static let s0: CGFloat = 0
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 20
        static let s6: CGFloat = 24
        static let s7: CGFloat = 32
        static let s8: CGFloat = 40
        static let s9: CGFloat = 56
    }

    // MARK: - Radius

    enum Radius {
        static let chip: CGFloat = 8
        static let card: CGFloat = 12
        static let sheet: CGFloat = 24
        static let pin: CGFloat = 22
        static let pill: CGFloat = .infinity
    }

    // MARK: - Layout

    /// Minimum control geometry. Apple's HIG calls for a 44×44pt minimum hit
    /// area; primary CTAs read better slightly taller. Centralized so no view
    /// hardcodes a tap-target literal.
    enum Layout {
        /// HIG minimum interactive target (chips, icon buttons, friend/suggestion
        /// rows, the search field).
        static let minTapTarget: CGFloat = 44
        /// Primary filled CTA height ("I'm in", "Send to chat").
        static let primaryControlHeight: CGFloat = 50
        /// Search field height.
        static let searchBarHeight: CGFloat = 44
        /// Collapsed-sheet peek height. The single source of truth for the
        /// minimal `PresentationDetent` so its value-equality comparisons can
        /// never drift apart.
        static let sheetPeekHeight: CGFloat = 70
    }

    // MARK: - Typography

    /// Semantic type ramp built on `Font.system(_:)` text styles so every label
    /// scales with Dynamic Type automatically.
    enum Typography {
        /// Oversized decorative glyph for hero/onboarding illustrations.
        static let heroIcon = Font.system(size: 64)
        static let display = Font.system(.largeTitle, weight: .bold)
        static let title = Font.system(.title, weight: .bold)
        static let title2 = Font.system(.title2)
        static let headline = Font.system(.headline)
        static let subheadline = Font.system(.subheadline)
        static let body = Font.system(.body)
        static let callout = Font.system(.callout)
        static let footnote = Font.system(.footnote)
        static let caption = Font.system(.caption)
        static let captionBold = Font.system(.caption, weight: .semibold)
        static let caption2Bold = Font.system(.caption2, weight: .bold)
    }

    // MARK: - Motion

    enum Motion {
        /// Resolve at the call site so changing Reduce Motion in Settings takes
        /// effect without relaunching Tween. A near-instant fade preserves the
        /// state change while removing spatial travel and spring motion.
        private static var reduced: Animation { .linear(duration: 0.01) }

        static var quick: Animation {
            UIAccessibility.isReduceMotionEnabled ? reduced : .easeOut(duration: 0.12)
        }

        static var snappy: Animation {
            UIAccessibility.isReduceMotionEnabled ? reduced : .easeOut(duration: 0.28)
        }

        static var spring: Animation {
            UIAccessibility.isReduceMotionEnabled
                ? reduced
                : .spring(duration: 0.36, bounce: 0.08)
        }

        static var gentle: Animation {
            UIAccessibility.isReduceMotionEnabled ? reduced : .easeInOut(duration: 0.45)
        }
    }

    // MARK: - Elevation

    /// A composable shadow definition. Presets cover the three depths Tween uses:
    /// floating controls, sheets/cards, and map pins.
    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat

        static let floating = Shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
        static let sheet = Shadow(color: .black.opacity(0.12), radius: 20, x: 0, y: 8)
        static let pin = Shadow(color: .black.opacity(0.28), radius: 2, x: 0, y: 1)
        /// Cheap card elevation for items that move during interactive
        /// gestures (result cards in a resizing sheet): a tight blur costs a
        /// fraction of `floating`'s 12px pass per card per frame.
        static let card = Shadow(color: .black.opacity(0.16), radius: 5, x: 0, y: 3)
    }
}

/// Resolves a light/dark color pair into a single adaptive SwiftUI `Color`.
private func dynamicColor(light: UIColor, dark: UIColor) -> Color {
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? dark : light
    })
}

// MARK: - View modifiers

extension View {
    /// Frosted glass surface: ultra-thin material clipped to the card radius.
    func tweenGlass(radius: CGFloat = Tokens.Radius.card) -> some View {
        self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
    }

    /// Applies one of the elevation presets.
    func tweenElevation(_ shadow: Tokens.Shadow = .floating) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }

    /// Scales the view down slightly while pressed for tactile feedback.
    /// Uses the QUICK curve: press feedback must land on touch-down, and the
    /// broader navigation curve made buttons feel like they responded on release.
    func tweenPressFeedback(isPressed: Bool) -> some View {
        self.scaleEffect(isPressed ? 0.98 : 1)
            .animation(Tokens.Motion.quick, value: isPressed)
    }
}

// MARK: - Button styles

/// The house button style. `.prominent` is a filled brand rounded-rect for
/// primary CTAs; `.subtle` is a neutral one for secondary actions. Both
/// press down with `tweenPressFeedback`. Shape matches the filled
/// rounded-rectangle buttons Apple's own place card renders ("Get
/// Directions" / "Open in Apple Maps") — the look every Tween button now
/// shares (device feedback).
struct TweenPrimaryButtonStyle: ButtonStyle {
    enum Variant {
        case prominent
        case subtle
        case neutral
        case destructive
    }

    var variant: Variant = .prominent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Tokens.Typography.headline)
            .foregroundStyle(foreground)
            .padding(.vertical, Tokens.Spacing.s3)
            .padding(.horizontal, Tokens.Spacing.s5)
            .frame(maxWidth: .infinity, minHeight: Tokens.Layout.primaryControlHeight)
            .background(background,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            .tweenPressFeedback(isPressed: configuration.isPressed)
    }

    private var foreground: Color {
        switch variant {
        case .prominent: return Tokens.Palette.onBrand
        case .subtle:    return Tokens.Palette.accent
        case .neutral:   return Tokens.Palette.textPrimary
        case .destructive: return Tokens.Palette.destructive
        }
    }

    private var background: AnyShapeStyle {
        switch variant {
        case .prominent: return AnyShapeStyle(Tokens.Palette.brand)
        case .subtle:    return AnyShapeStyle(Tokens.Palette.neutralAction)
        case .neutral:   return AnyShapeStyle(Tokens.Palette.neutralAction)
        case .destructive: return AnyShapeStyle(Tokens.Palette.destructiveLight)
        }
    }
}

extension ButtonStyle where Self == TweenPrimaryButtonStyle {
    /// `.buttonStyle(.tweenPrimary())` for the filled brand CTA, or
    /// `.tweenPrimary(.subtle)` for the tinted secondary variant.
    static func tweenPrimary(_ variant: TweenPrimaryButtonStyle.Variant = .prominent) -> TweenPrimaryButtonStyle {
        TweenPrimaryButtonStyle(variant: variant)
    }
}
