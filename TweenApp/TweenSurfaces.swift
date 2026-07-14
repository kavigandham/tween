import SwiftUI

/// The bottom sheet's surface: on iOS 26 the system's Liquid Glass floating
/// panel (what Apple Maps' pill is made of — see "Adopting Liquid Glass" in
/// the technology overviews); before that, the near-opaque material blur
/// that read correctly pre-glass. Deployment target is iOS 17, so both
/// worlds ship.
struct TweenSheetSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.presentationBackground(.regularMaterial)
        }
    }
}

/// Card surface for the floating meetup/proposal cards: Liquid Glass on
/// iOS 26, a translucent material blur (NOT the near-black opaque fill that
/// read as an ugly black box) on earlier systems. The tapped-search-result
/// card doesn't use this — it renders directly on the sheet's own glass.
struct TweenCardSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape).tweenElevation(.floating)
        } else {
            content.background(.regularMaterial, in: shape).tweenElevation(.floating)
        }
    }
}

/// Chrome for the floating map controls: Liquid Glass on iOS 26 (interactive,
/// brand-tinted when selected), the surface fill + hairline + shadow stack on
/// earlier systems. One modifier so every control switches worlds together.
struct TweenGlassControl<S: InsettableShape>: ViewModifier {
    let shape: S
    var isSelected = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Plain glass, NOT .interactive(): these sit on Button LABELS,
            // and interactive glass installs its own touch handling that
            // swallowed the button taps on device — reset-map and the map
            // style picker went completely dead. The press feedback comes
            // from the Button itself; glass only needs to look right.
            if isSelected {
                content
                    .contentShape(shape)
                    .glassEffect(.regular.tint(Tokens.Palette.brand), in: shape)
            } else {
                content
                    .contentShape(shape)
                    .glassEffect(.regular, in: shape)
            }
        } else {
            content
                .background(
                    isSelected
                        ? AnyShapeStyle(Tokens.Palette.brand)
                        : AnyShapeStyle(Tokens.Palette.surface.opacity(0.92)),
                    in: shape)
                .overlay {
                    shape.strokeBorder(Tokens.Palette.surfaceSecondary.opacity(isSelected ? 0 : 1), lineWidth: 1)
                }
                .tweenElevation(.floating)
        }
    }
}
