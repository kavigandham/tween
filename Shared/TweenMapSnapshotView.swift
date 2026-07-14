import SwiftUI
import UIKit
import MapKit
import CoreLocation

/// A static map image rendered with `MKMapSnapshotter` — never `MKMapView`, to
/// respect the extension's tight memory ceiling. Markers are composited onto the
/// snapshot with Core Graphics. A gray placeholder shows while the snapshot is
/// in flight, and the rendered image is cached in `@State` so scrolling or a
/// re-layout doesn't re-snapshot the same region.
struct TweenMapSnapshotView: View {
    let markers: [MapMarker]
    var cornerRadius: CGFloat = Tokens.Radius.card
    var focusCoordinate: CLLocationCoordinate2D? = nil
    var focusYOffsetRatio: CLLocationDegrees = 0

    @State private var image: UIImage?
    /// Bumping this re-keys the `.task(id:)` below, forcing a fresh render —
    /// the automatic-retry path after a transient snapshotter failure.
    @State private var retryAttempt = 0
    private static let maxRetries = 3

    private var coordinates: [CLLocationCoordinate2D] { markers.map(\.coordinate) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    placeholder
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            // Crossfade from the loading filler to the rendered map instead
            // of a hard pop-in.
            .animation(Tokens.Motion.gentle, value: image != nil)
            // Re-render only when the framing inputs actually change —
            // or when a failed attempt schedules a retry.
            .task(id: "\(cacheKey(for: geo.size))#\(retryAttempt)") {
                await render(size: geo.size)
            }
        }
    }

    /// Filler shown while the snapshot is in flight — an explicit "loading"
    /// state instead of a bare icon that read as a broken blank map (device
    /// feedback). The image swaps in only once it has actually rendered;
    /// failures land on the fallback grid via `render`'s retry path.
    private var placeholder: some View {
        ZStack {
            Rectangle().fill(Tokens.Palette.surfaceSecondary)
            VStack(spacing: Tokens.Spacing.s2) {
                ProgressView()
                Text("Loading map…")
                    .font(Tokens.Typography.footnote)
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
        }
        .accessibilityHidden(true)
    }

    /// A stable identity for the current request: rounding the coordinates keeps
    /// sub-meter jitter from forcing needless re-snapshots.
    private func cacheKey(for size: CGSize) -> String {
        let parts = markers.map { marker -> String in
            let lat = (marker.coordinate.latitude * 10_000).rounded() / 10_000
            let lon = (marker.coordinate.longitude * 10_000).rounded() / 10_000
            return "\(marker.role.symbol):\(lat),\(lon)"
        }
        return "\(Int(size.width))x\(Int(size.height))#" + parts.joined(separator: "|")
    }

    /// Hard ceiling on a single snapshotter attempt. Under the extension's
    /// ~120 MB limit (and on a GeoServices cold start) `snapshotter.start()`
    /// can stall indefinitely — awaiting forever left `image == nil`, i.e.
    /// the bare-icon placeholder "until you close and reopen the extension".
    /// Racing it against a deadline turns a stall into a throw that routes
    /// into the fallback + retry path.
    private static let snapshotTimeout: UInt64 = 6_000_000_000

    @MainActor
    private func render(size: CGSize) async {
        guard size.width > 1, size.height > 1 else { return }
        // No coordinates yet (e.g. a leave bubble with an empty roster, or
        // self location not shared): draw the neutral grid instead of
        // returning with `image == nil`, which stuck on the bare map icon
        // forever. A later marker set re-keys `.task(id:)` and re-renders.
        guard !coordinates.isEmpty else {
            if image == nil { image = Self.fallbackImage(markers: markers, size: size) }
            return
        }

        let options = MKMapSnapshotter.Options()
        if let focusCoordinate {
            // Frame the focused spot IN CONTEXT with everyone — the old fixed
            // tight span (0.045) around just the spot hid the participants and
            // read as "so zoomed the map is useless" (device feedback). Fit all
            // points (which includes the focus), gently bias the center toward
            // the focus so it reads as the subject, and widen a touch so nobody
            // falls off the edge. A floor keeps a tight cluster from over-zooming.
            var region = MapGeometry.region(for: coordinates)
            region.span.latitudeDelta = max(region.span.latitudeDelta, 0.02) * 1.2
            region.span.longitudeDelta = max(region.span.longitudeDelta, 0.02) * 1.2
            region.center = CLLocationCoordinate2D(
                latitude: region.center.latitude * 0.65 + focusCoordinate.latitude * 0.35
                    - region.span.latitudeDelta * focusYOffsetRatio,
                longitude: region.center.longitude * 0.65 + focusCoordinate.longitude * 0.35)
            options.region = region
        } else {
            options.region = MapGeometry.region(for: coordinates)
        }
        options.size = size
        options.mapType = .standard
        // Render at the device's native pixel density (@3x on Retina) so the
        // snapshot doesn't look pixelated when the memory-warning path swaps
        // out the live Map. `size` is in points; `scale` maps them to pixels.
        // Per docs/ui-research.md §5. `UIScreen.main.scale` is safe from a
        // @MainActor context and matches BubbleImageRenderer (which hardcodes
        // 3 because its output is a fixed-size bubble image).
        options.scale = UIScreen.main.scale

        let snapshotter = MKMapSnapshotter(options: options)
        // Deadline: a sibling task cancels the snapshotter if it stalls past
        // the timeout, turning an unending await into a thrown error that
        // routes into the fallback + retry below (both tasks are on the main
        // actor, so `snapshotter` isn't captured across an actor boundary).
        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.snapshotTimeout)
            snapshotter.cancel()
        }
        let snapshot = try? await snapshotter.start()
        deadline.cancel()
        guard let snapshot else {
            // A cancelled task is NOT a failure — the next `.task(id:)` run
            // re-renders naturally. Don't cache anything for it.
            guard !Task.isCancelled else { return }
            // Transient snapshotter failures (extension cold-start racing
            // GeoServices, momentary network loss) used to be cached forever
            // as a tile-less fallback — "no map until you close and reopen
            // the extension". Show the fallback for now, but keep retrying
            // with backoff; a later success replaces it.
            if image == nil {
                image = Self.fallbackImage(markers: markers, size: size)
            }
            if retryAttempt < Self.maxRetries {
                try? await Task.sleep(nanoseconds: UInt64(retryAttempt + 1) * 1_500_000_000)
                guard !Task.isCancelled else { return }
                retryAttempt += 1   // re-keys .task(id:) → fresh render
            }
            return
        }
        guard !Task.isCancelled else { return }
        image = Self.draw(markers: markers, on: snapshot)
    }

    /// Composites the markers onto a finished snapshot.
    static func draw(markers: [MapMarker], on snapshot: MKMapSnapshotter.Snapshot) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: snapshot.image.size)
        return renderer.image { context in
            snapshot.image.draw(at: .zero)
            for marker in markers {
                drawMarker(marker.role, at: snapshot.point(for: marker.coordinate), in: context.cgContext)
            }
        }
    }

    /// Network-free fallback when MapKit cannot fetch tiles in the extension.
    /// Keeps the surface useful instead of leaving a blank/gray map forever.
    static func fallbackImage(markers: [MapMarker], size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        let coordinates = markers.map(\.coordinate)
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let minLat = latitudes.min() ?? 0
        let maxLat = latitudes.max() ?? 0
        let minLon = longitudes.min() ?? 0
        let maxLon = longitudes.max() ?? 0
        let latSpan = max(maxLat - minLat, 0.01)
        let lonSpan = max(maxLon - minLon, 0.01)
        let inset = max(min(size.width, size.height) * 0.12, 18)

        func point(for coordinate: CLLocationCoordinate2D) -> CGPoint {
            let x = inset + ((coordinate.longitude - minLon) / lonSpan) * (size.width - inset * 2)
            let y = inset + ((maxLat - coordinate.latitude) / latSpan) * (size.height - inset * 2)
            return CGPoint(x: x, y: y)
        }

        return renderer.image { context in
            let ctx = context.cgContext
            UIColor(Tokens.Palette.surfaceSecondary).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            ctx.setStrokeColor(UIColor(Tokens.Palette.textTertiary.opacity(0.18)).cgColor)
            ctx.setLineWidth(1)
            let step = max(min(size.width, size.height) / 6, 28)
            var x: CGFloat = 0
            while x <= size.width {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            ctx.strokePath()

            if markers.count >= 2 {
                ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.72).cgColor)
                ctx.setLineWidth(3)
                ctx.setLineDash(phase: 0, lengths: [8, 7])
                let people = markers.filter { $0.role == .selfActive || $0.role == .selfDot || $0.role == .friend || $0.role == .rideNeeded }
                for pair in zip(people, people.dropFirst()) {
                    ctx.move(to: point(for: pair.0.coordinate))
                    ctx.addLine(to: point(for: pair.1.coordinate))
                }
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            }

            for marker in markers {
                drawMarker(marker.role, at: point(for: marker.coordinate), in: ctx)
            }
        }
    }

    /// A flat colored dot with a thin white rim — a flattened echo of `TweenPin`
    /// at the `.compact` scale. The old 1.6× halo (audit F5) inflated every
    /// marker's footprint and cluttered the extension's thumbnail map; dropped
    /// in favour of a clean rim-only dot.
    private static func drawMarker(_ role: TweenPin.Role, at point: CGPoint, in ctx: CGContext,
                                   context: TweenPin.Context = .compact) {
        let color = UIColor(role.fill)
        let d = role.diameter(context)

        let dot = CGRect(x: point.x - d / 2, y: point.y - d / 2, width: d, height: d)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: dot)
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: dot)
    }
}

/// Keyboard-height presentation for the Messages extension.
///
/// Deliberately input-free: no text fields, no first responder, no keyboard. The
/// whole row is tappable to expand; the "I'm in" pill is the only nested action.
