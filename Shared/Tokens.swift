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

        // Brand — deep teal #008C8C, brightened in dark mode for contrast.
        static let brand = dynamicColor(
            light: UIColor(red: 0.00, green: 0.549, blue: 0.549, alpha: 1),   // #008C8C
            dark:  UIColor(red: 0.10, green: 0.722, blue: 0.722, alpha: 1))    // #19B8B8
        static let brandLight = dynamicColor(
            light: UIColor(red: 0.878, green: 0.953, blue: 0.953, alpha: 1),   // #E0F3F3
            dark:  UIColor(red: 0.063, green: 0.247, blue: 0.247, alpha: 1))   // #103F3F

        // Map pins — system colors so they track Increase Contrast and dark mode.
        // Each pin also carries a distinct glyph, so color is never the sole cue.
        static let pinSelf = Color(uiColor: .systemBlue)
        static let pinSelfActive = Color(uiColor: .systemBlue)
        static let pinFriend = Color(uiColor: .systemOrange)
        static let pinFair = Color(uiColor: .systemYellow)
        static let pinClosest = Color(uiColor: .systemGreen)
        static let pinResult = Color(uiColor: .systemTeal)
        static let pinMidpoint = pinFair

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
            static let pinFair = UIColor.systemYellow
            static let pinClosest = UIColor.systemGreen
            static let pinResult = UIColor.systemTeal
            static let pinMidpoint = pinFair
            static let brand = UIColor(red: 0.00, green: 0.549, blue: 0.549, alpha: 1)         // #008C8C
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
    }

    // MARK: - Motion

    enum Motion {
        static let snappy = Animation.easeInOut(duration: 0.40)
        static let spring = Animation.spring(duration: 0.48, bounce: 0.12)
        static let gentle = Animation.easeInOut(duration: 0.66)
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
    func tweenPressFeedback(isPressed: Bool) -> some View {
        self.scaleEffect(isPressed ? 0.96 : 1)
            .animation(Tokens.Motion.snappy, value: isPressed)
    }
}

// MARK: - Button styles

/// The house button style. `.prominent` is a filled brand capsule for primary
/// CTAs; `.subtle` is a brand-tinted capsule for secondary actions. Both press
/// down with `tweenPressFeedback`.
struct TweenPrimaryButtonStyle: ButtonStyle {
    enum Variant {
        case prominent
        case subtle
    }

    var variant: Variant = .prominent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Tokens.Typography.headline)
            .foregroundStyle(foreground)
            .padding(.vertical, Tokens.Spacing.s3)
            .padding(.horizontal, Tokens.Spacing.s5)
            .frame(maxWidth: .infinity, minHeight: Tokens.Layout.primaryControlHeight)
            .background(background, in: Capsule())
            .tweenPressFeedback(isPressed: configuration.isPressed)
    }

    private var foreground: Color {
        switch variant {
        case .prominent: return .white
        case .subtle:    return Tokens.Palette.brand
        }
    }

    private var background: AnyShapeStyle {
        switch variant {
        case .prominent: return AnyShapeStyle(Tokens.Palette.brand)
        case .subtle:    return AnyShapeStyle(Tokens.Palette.brandLight)
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
