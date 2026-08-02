import UIKit
import SwiftUI

/// Core Graphics twin of `TweenPin` — THE pin drawer for every rasterized
/// surface (the extension's snapshot maps and the iMessage bubble image).
///
/// Both of those used to draw an identity-free filled circle (the bubble added
/// a big translucent halo), so the same person read as a Find-My-style avatar
/// in the app and an anonymous blob in Messages — the "colored blobs" the
/// TweenPin doc says device feedback already rejected once. This renders the
/// SAME three visual families as `TweenPin`, so a pin looks like itself
/// wherever it appears:
///   * **You** — white circle with the blue location dot inside (Apple's own
///     location language), soft halo while sharing.
///   * **People** — participant-colored circle with white ring + the person's
///     initials (person glyph when unknown), plus the car badge when they need
///     a ride.
///   * **Spots** — colored circle with the role's SF Symbol glyph.
enum PinRenderer {

    /// Draws one pin centered on `point`. `diameter` sizes the avatar/glyph
    /// family; the You dot derives its proportions from it so a 24 pt compact
    /// pin and a 38 pt bubble pin stay recognisably the same mark.
    static func draw(role: TweenPin.Role,
                     initials: String? = nil,
                     needsRide: Bool = false,
                     at point: CGPoint,
                     diameter: CGFloat,
                     in ctx: CGContext) {
        switch role {
        case .selfDot, .selfActive:
            drawSelfDot(active: role == .selfActive, at: point, diameter: diameter, in: ctx)
        case .friend, .rideNeeded:
            drawAvatar(initials: initials, at: point, diameter: diameter, in: ctx)
        case .midpoint:
            drawPlainDot(color: UIColor(role.fill), at: point, diameter: diameter, in: ctx)
        case .fairSpot, .closestToUser, .result:
            drawGlyphCircle(role: role, at: point, diameter: diameter, in: ctx)
        }
        if needsRide || role == .rideNeeded {
            drawRideBadge(at: CGPoint(x: point.x + diameter * 0.34, y: point.y + diameter * 0.34),
                          diameter: max(diameter * 0.42, 12), in: ctx)
        }
    }

    // MARK: - Families

    /// Apple's location dot: white disc, blue core, soft halo while sharing.
    private static func drawSelfDot(active: Bool, at point: CGPoint,
                                    diameter: CGFloat, in ctx: CGContext) {
        let blue = Tokens.Palette.UI.pinSelf
        if active {
            let halo = diameter * 1.6
            ctx.setFillColor(blue.withAlphaComponent(0.20).cgColor)
            ctx.fillEllipse(in: centered(point, halo))
        }
        withShadow(in: ctx) { ctx in
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillEllipse(in: centered(point, diameter * 0.82))
        }
        ctx.setFillColor(blue.cgColor)
        ctx.fillEllipse(in: centered(point, diameter * 0.60))
    }

    /// Find-My-style avatar: filled circle, white ring, initials inside.
    private static func drawAvatar(initials: String?, at point: CGPoint,
                                   diameter: CGFloat, in ctx: CGContext) {
        let rect = centered(point, diameter)
        withShadow(in: ctx) { ctx in
            ctx.setFillColor(Tokens.Palette.UI.pinFriend.cgColor)
            ctx.fillEllipse(in: rect)
        }
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(max(diameter * 0.075, 1.5))
        ctx.strokeEllipse(in: rect)

        let text = (initials?.isEmpty == false) ? initials! : nil
        if let text {
            drawCenteredText(text, at: point,
                             font: .systemFont(ofSize: diameter * 0.42, weight: .bold),
                             in: ctx)
        } else {
            drawCenteredSymbol("person.fill", at: point,
                               pointSize: diameter * 0.46, in: ctx)
        }
    }

    /// Spot marks: colored circle carrying the role's SF Symbol.
    private static func drawGlyphCircle(role: TweenPin.Role, at point: CGPoint,
                                        diameter: CGFloat, in ctx: CGContext) {
        let rect = centered(point, diameter)
        withShadow(in: ctx) { ctx in
            ctx.setFillColor(UIColor(role.fill).cgColor)
            ctx.fillEllipse(in: rect)
        }
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.92).cgColor)
        ctx.setLineWidth(max(diameter * 0.07, 1.5))
        ctx.strokeEllipse(in: rect)
        drawCenteredSymbol(role.symbol, at: point, pointSize: diameter * 0.44, in: ctx)
    }

    private static func drawPlainDot(color: UIColor, at point: CGPoint,
                                     diameter: CGFloat, in ctx: CGContext) {
        let rect = centered(point, diameter)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.92).cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: rect)
    }

    private static func drawRideBadge(at point: CGPoint, diameter: CGFloat, in ctx: CGContext) {
        let rect = centered(point, diameter)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fillEllipse(in: rect)
        drawCenteredSymbol("car.fill", at: point, pointSize: diameter * 0.58,
                           color: Tokens.Palette.UI.pinRideNeeded, in: ctx)
    }

    // MARK: - Primitives

    private static func centered(_ point: CGPoint, _ diameter: CGFloat) -> CGRect {
        CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
               width: diameter, height: diameter)
    }

    /// Subtle elevation so pins separate from busy map tiles — the same job
    /// `tweenElevation(.pin)` does for the SwiftUI pins.
    private static func withShadow(in ctx: CGContext, _ body: (CGContext) -> Void) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3,
                      color: UIColor.black.withAlphaComponent(0.30).cgColor)
        body(ctx)
        ctx.restoreGState()
    }

    /// SF Symbols rasterize through `UIImage(systemName:)`; `.alwaysOriginal`
    /// with a white tint keeps the glyph legible on every fill color.
    private static func drawCenteredSymbol(_ name: String, at point: CGPoint,
                                           pointSize: CGFloat,
                                           color: UIColor = .white,
                                           in ctx: CGContext) {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        guard let image = UIImage(systemName: name, withConfiguration: config)?
            .withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        image.draw(in: CGRect(x: point.x - image.size.width / 2,
                              y: point.y - image.size.height / 2,
                              width: image.size.width, height: image.size.height))
    }

    private static func drawCenteredText(_ text: String, at point: CGPoint,
                                         font: UIFont, in ctx: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: point.x - size.width / 2,
                                            y: point.y - size.height / 2),
                                withAttributes: attributes)
    }
}
