import UIKit
import MapKit
import CoreLocation

/// Renders the image baked into an iMessage bubble.
///
/// Fully static — no instance state — so it can be called from the extension's
/// send path without holding anything alive past the async draw. The happy path
/// snapshots the meeting area with `MKMapSnapshotter` (never `MKMapView`) and
/// composites every participant pin, an optional dashed connector (only when
/// exactly two people are present — for groups the centroid implies grouping),
/// and a branded footer onto it. Every failure mode falls back to a fully
/// offline, network-free image so a bubble always has artwork.
enum BubbleImageRenderer {
    /// 600×400 points — a 3:2 bubble — rendered @3x for Retina crispness.
    private static let size = CGSize(width: 600, height: 400)
    private static let scale: CGFloat = 3
    private static let footerHeight: CGFloat = 56

    // MARK: - Public

    /// Snapshots the region spanning every participant plus the proposed spot
    /// (when present), composites the overlays, and returns the bubble image.
    /// Falls back to a drawn image if the snapshot fails (offline, throttled,
    /// or cancelled).
    ///
    /// `localName` lets us colour the local user's pin distinctly from the
    /// others. Pass nil when rendering for the host app or in unit tests
    /// where local identity is unknown.
    static func makeImage(
        state: TweenState,
        participants: [Participant],
        localName: String? = nil
    ) async -> UIImage {
        let placeCoord = state.kind == .place ? state.coordinate : nil
        var coords = participants.map(\.coordinate)
        if let placeCoord { coords.append(placeCoord) }
        guard !coords.isEmpty else { return fallbackImage(state: state) }

        let options = MKMapSnapshotter.Options()
        options.size = size
        options.scale = scale
        options.mapType = .standard
        options.region = MapGeometry.region(for: coords)

        let snapshotter = MKMapSnapshotter(options: options)
        guard let snapshot = try? await snapshotter.start() else {
            return fallbackImage(state: state, participants: participants, localName: localName)
        }
        return composite(snapshot: snapshot, state: state, participants: participants, localName: localName)
    }

    /// Legacy 2-person entry point. Existing internal callers (and any caller
    /// not yet migrated) can keep passing (selfCoord, peerCoord); we synthesise
    /// a 2-element participants array and dispatch to the canonical path.
    @available(*, deprecated, message: "Pass participants: [Participant] instead.")
    static func makeImage(
        state: TweenState,
        selfCoord: CLLocationCoordinate2D?,
        peerCoord: CLLocationCoordinate2D?
    ) async -> UIImage {
        var participants: [Participant] = []
        if let selfCoord {
            participants.append(Participant(id: "self", name: "You", coordinate: selfCoord))
        }
        if let peerCoord {
            participants.append(Participant(id: "peer", name: "Friend", coordinate: peerCoord))
        } else if state.kind == .participant {
            // Legacy: when no explicit peer is supplied and the bubble itself
            // represents a participant, the main coord is that participant.
            participants.append(Participant(id: "peer", name: "Friend", coordinate: state.coordinate))
        }
        return await makeImage(state: state, participants: participants, localName: "You")
    }

    // MARK: - Composition

    /// Draws the snapshot, an optional dashed connector for the 2-person case,
    /// colored pin halos for every participant, and the footer with the spot
    /// name. The local user's pin is drawn with the self palette; everyone
    /// else uses the friend palette.
    static func composite(
        snapshot: MKMapSnapshotter.Snapshot,
        state: TweenState,
        participants: [Participant],
        localName: String? = nil
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { context in
            let ctx = context.cgContext
            snapshot.image.draw(in: CGRect(origin: .zero, size: size))

            // Dashed connector: only meaningful in the 2-person case. For 3+
            // the centroid implies the grouping and a line through 3+ pins
            // would be visually noisy.
            if participants.count == 2 {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 3, color: UIColor.black.withAlphaComponent(0.4).cgColor)
                ctx.setStrokeColor(UIColor.white.cgColor)
                ctx.setLineWidth(4)
                ctx.setLineDash(phase: 0, lengths: [10, 8])
                ctx.move(to: snapshot.point(for: participants[0].coordinate))
                ctx.addLine(to: snapshot.point(for: participants[1].coordinate))
                ctx.strokePath()
                ctx.restoreGState()
            }

            // Pin halos: every participant, with the local user (matched by
            // name) coloured distinctly.
            for participant in participants {
                let color = (localName != nil && participant.name == localName)
                    ? Tokens.Palette.UI.pinSelf
                    : Tokens.Palette.UI.pinFriend
                drawHalo(color, at: snapshot.point(for: participant.coordinate), in: ctx)
            }

            // Place pin sits on top of participants when this is a propose/agree.
            if state.kind == .place {
                drawHalo(Tokens.Palette.UI.pinFair, at: snapshot.point(for: state.coordinate), in: ctx, emphasized: true)
            }

            drawFooter(spotName: state.text, in: ctx)
        }
    }

    // MARK: - Fallback

    /// A self-contained image for when no snapshot is available: a gradient, a
    /// faint grid, abstract pins joined by a dashed line, and the spot name.
    /// Needs no network and no map tiles.
    static func fallbackImage(spotName: String) -> UIImage {
        fallbackImage(state: TweenState(text: spotName, latitude: 0, longitude: 0, kind: .place))
    }

    static func fallbackImage(
        state: TweenState,
        participants: [Participant] = [],
        localName: String? = nil
    ) -> UIImage {
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

            // Pins: lay them in an arc around the place. For groups (3+) we
            // skip the connector; for the 2-person case we still draw the
            // dashed line so the abstract image reads like the live one.
            let count = max(participants.count, 2)
            let centerY = size.height * 0.42
            let radius = size.width * 0.25
            var points: [CGPoint] = []
            for i in 0..<count {
                let t = (Double(i) / Double(max(count - 1, 1))) - 0.5  // -0.5 ... 0.5
                let x = size.width * 0.5 + CGFloat(t) * radius * 2
                points.append(CGPoint(x: x, y: centerY))
            }

            if count == 2 {
                ctx.saveGState()
                ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.8).cgColor)
                ctx.setLineWidth(4)
                ctx.setLineDash(phase: 0, lengths: [10, 8])
                ctx.move(to: points[0]); ctx.addLine(to: points[1]); ctx.strokePath()
                ctx.restoreGState()
            }

            for (i, point) in points.enumerated() {
                let participant = i < participants.count ? participants[i] : nil
                let color = (participant?.name == localName)
                    ? Tokens.Palette.UI.pinSelf
                    : (i == 0 ? Tokens.Palette.UI.pinSelf : Tokens.Palette.UI.pinFriend)
                drawHalo(color, at: point, in: ctx)
            }
            if state.kind == .place {
                drawHalo(Tokens.Palette.UI.pinFair, at: CGPoint(x: size.width * 0.50, y: centerY - 4), in: ctx, emphasized: true)
            }

            drawFooter(spotName: state.text, in: ctx)
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
