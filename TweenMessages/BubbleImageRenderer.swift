import UIKit
import MapKit
import CoreLocation

/// Renders the image baked into an iMessage bubble.
///
/// Fully static — no instance state — so it can be called from the extension's
/// send path without holding anything alive past the async draw. The happy path
/// snapshots the meeting area with `MKMapSnapshotter` (never `MKMapView`) and
/// composites the participants, a dashed connector, and a branded footer onto
/// it. Every failure mode falls back to a fully offline, network-free image so a
/// bubble always has artwork.
enum BubbleImageRenderer {
    /// 600×400 points — a 3:2 bubble — rendered @3x for Retina crispness.
    private static let size = CGSize(width: 600, height: 400)
    private static let scale: CGFloat = 3
    private static let footerHeight: CGFloat = 56

    // MARK: - Public

    /// Snapshots the region spanning the spot and both participants, composites
    /// the overlays, and returns the bubble image. Falls back to a drawn image
    /// if the snapshot fails (offline, throttled, or cancelled).
    static func makeImage(
        state: TweenState,
        selfCoord: CLLocationCoordinate2D?,
        peerCoord: CLLocationCoordinate2D?
    ) async -> UIImage {
        let coords = [state.coordinate, selfCoord, peerCoord].compactMap { $0 }

        let options = MKMapSnapshotter.Options()
        options.size = size
        options.scale = scale
        options.mapType = .standard
        options.region = MapGeometry.region(for: coords)

        let snapshotter = MKMapSnapshotter(options: options)
        guard let snapshot = try? await snapshotter.start() else {
            return fallbackImage(spotName: state.text)
        }
        return composite(snapshot: snapshot, state: state, selfCoord: selfCoord, peerCoord: peerCoord)
    }

    // MARK: - Composition

    /// Draws the snapshot, a dashed line between the two people, colored pin
    /// halos, and the footer carrying the spot name.
    static func composite(
        snapshot: MKMapSnapshotter.Snapshot,
        state: TweenState,
        selfCoord: CLLocationCoordinate2D?,
        peerCoord: CLLocationCoordinate2D?
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { context in
            let ctx = context.cgContext
            snapshot.image.draw(in: CGRect(origin: .zero, size: size))

            // Dashed connector between the two participants.
            if let a = selfCoord, let b = peerCoord {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 3, color: UIColor.black.withAlphaComponent(0.4).cgColor)
                ctx.setStrokeColor(UIColor.white.cgColor)
                ctx.setLineWidth(4)
                ctx.setLineDash(phase: 0, lengths: [10, 8])
                ctx.move(to: snapshot.point(for: a))
                ctx.addLine(to: snapshot.point(for: b))
                ctx.strokePath()
                ctx.restoreGState()
            }

            // Pin halos: people first, then the spot as the emphasized target.
            // UIKit token equivalents mirror the SwiftUI pin palette.
            if let s = selfCoord { drawHalo(Tokens.Palette.UI.pinSelf, at: snapshot.point(for: s), in: ctx) }
            if let p = peerCoord { drawHalo(Tokens.Palette.UI.pinFriend, at: snapshot.point(for: p), in: ctx) }
            drawHalo(Tokens.Palette.UI.pinMidpoint, at: snapshot.point(for: state.coordinate), in: ctx, emphasized: true)

            drawFooter(spotName: state.text, in: ctx)
        }
    }

    // MARK: - Fallback

    /// A self-contained image for when no snapshot is available: a gradient, a
    /// faint grid, abstract pins joined by a dashed line, and the spot name.
    /// Needs no network and no map tiles.
    static func fallbackImage(spotName: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { context in
            let ctx = context.cgContext

            // Diagonal brand gradient.
            let colors = [
                UIColor(red: 0.12, green: 0.30, blue: 0.65, alpha: 1).cgColor,
                UIColor(red: 0.20, green: 0.55, blue: 0.85, alpha: 1).cgColor
            ]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: .zero,
                                       end: CGPoint(x: size.width, y: size.height), options: [])
            }

            // Faint map-like grid.
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.12).cgColor)
            ctx.setLineWidth(1)
            let step: CGFloat = 40
            var x: CGFloat = 0
            while x <= size.width {
                ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: size.height)); x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: size.width, y: y)); y += step
            }
            ctx.strokePath()

            // Abstract pins joined by a dashed line, midpoint emphasized.
            let a = CGPoint(x: size.width * 0.30, y: size.height * 0.42)
            let b = CGPoint(x: size.width * 0.70, y: size.height * 0.40)
            ctx.saveGState()
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(4)
            ctx.setLineDash(phase: 0, lengths: [10, 8])
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            ctx.restoreGState()

            drawHalo(Tokens.Palette.UI.pinSelf, at: a, in: ctx)
            drawHalo(Tokens.Palette.UI.pinFriend, at: b, in: ctx)
            drawHalo(Tokens.Palette.UI.pinMidpoint, at: CGPoint(x: size.width * 0.50, y: size.height * 0.41), in: ctx, emphasized: true)

            drawFooter(spotName: spotName, in: ctx)
        }
    }

    // MARK: - Primitives

    private static func drawHalo(_ color: UIColor, at point: CGPoint, in ctx: CGContext, emphasized: Bool = false) {
        let d: CGFloat = emphasized ? 30 : 22

        ctx.setFillColor(color.withAlphaComponent(0.3).cgColor)
        ctx.fillEllipse(in: CGRect(x: point.x - d, y: point.y - d, width: d * 2, height: d * 2))

        let dot = CGRect(x: point.x - d / 2, y: point.y - d / 2, width: d, height: d)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: dot)
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: dot)
    }

    private static func drawFooter(spotName: String, in ctx: CGContext) {
        let rect = CGRect(x: 0, y: size.height - footerHeight, width: size.width, height: footerHeight)
        ctx.setFillColor(Tokens.Palette.UI.brand.withAlphaComponent(0.95).cgColor)
        ctx.fill(rect)

        // Brand wordmark on the leading edge.
        let brand = "Tween"
        let brandAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .heavy),
            .foregroundColor: UIColor.white.withAlphaComponent(0.85)
        ]
        let brandSize = brand.size(withAttributes: brandAttrs)
        brand.draw(at: CGPoint(x: 20, y: rect.midY - brandSize.height / 2), withAttributes: brandAttrs)

        // Spot name fills the rest, right-aligned and truncated if long.
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.alignment = .right
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: para
        ]
        let leading = 20 + brandSize.width + 16
        let nameRect = CGRect(x: leading, y: rect.midY - 16,
                              width: max(size.width - leading - 20, 0), height: 32)
        (spotName as NSString).draw(in: nameRect, withAttributes: nameAttrs)
    }
}
