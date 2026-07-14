import SwiftUI
import UIKit
import MapKit
import CoreLocation

/// A single map marker: a coordinate paired with the `TweenPin` role that
/// decides its color and glyph. Used to describe what a snapshot should draw.
struct MapMarker: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let role: TweenPin.Role
}

/// Pure geometry helpers shared by the snapshot view, the bubble renderer, and
/// the extension. Kept free of UI so both processes can frame the same region.
enum MapGeometry {
    /// Default focus when there's nothing to frame: the geographic center of the
    /// continental US — deliberately generic rather than a misleading city.
    static let defaultCenter = CLLocationCoordinate2D(latitude: 39.8283, longitude: -98.5795)

    /// Average of two coordinates.
    static func midpoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2,
                               longitude: (a.longitude + b.longitude) / 2)
    }

    /// Geographic centroid of N coordinates — the simple average of latitudes
    /// and longitudes. For N=2 this equals `midpoint`. For N=0 returns
    /// `defaultCenter` so callers don't have to special-case empty input.
    static func centroid(of coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        guard !coordinates.isEmpty else { return defaultCenter }
        let lat = coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count)
        let lon = coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Convenience for participant arrays.
    static func centroid(of participants: [Participant]) -> CLLocationCoordinate2D {
        centroid(of: participants.map(\.coordinate))
    }

    /// Frames `coordinates` with padding on the span. A single point (or a
    /// degenerate cluster) falls back to a comfortable neighborhood zoom so the
    /// snapshot never renders the whole globe.
    static func region(
        for coordinates: [CLLocationCoordinate2D],
        fallback: CLLocationCoordinate2D = defaultCenter,
        padding: Double = 1.4,
        minSpan: CLLocationDegrees = 0.02
    ) -> MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion(
                center: fallback,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coordinates {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let latDelta = max((maxLat - minLat) * padding, minSpan)
        let lonDelta = max((maxLon - minLon) * padding, minSpan)
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
    }
}

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
struct CompactView: View {
    let received: TweenState?
    let isUserIn: Bool
    var localParticipantID: String? = nil
    /// The controller's live roster count (self included once joined). The
    /// decoded `received` bubble lags one message behind — it can't include
    /// the local user's own just-sent join — so pills prefer this when set.
    /// Nil keeps the legacy received-derived rendering.
    var currentParticipantCount: Int? = nil
    var isSending: Bool = false
    var statusMessage: String?
    var onImIn: () -> Void
    var onImOut: () -> Void = {}
    var onExpand: () -> Void

    var body: some View {
        VStack(spacing: Tokens.Spacing.s3) {
            if received == nil {
                launcherState
            } else {
                activeMeetupState
            }
        }
        // Tight vertical padding: the compact surface is only keyboard height,
        // and every point of chrome comes out of the content's budget.
        .padding(.horizontal, Tokens.Spacing.s4)
        .padding(.vertical, Tokens.Spacing.s2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque background so the compact strip never reads as transparent
        // against the iMessage keyboard backdrop. systemBackground tracks
        // light/dark mode automatically.
        .background(Color(.systemBackground))
        // The whole surface expands; the real Button below intercepts its own taps.
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
        // No `.accessibilityElement(children: .combine)` here — collapsing the
        // surface into one element made the nested I'm in / I'm out / Browse
        // buttons unreachable to VoiceOver. The custom action mirrors the
        // background tap instead.
        .accessibilityAction(named: "Open Tween", onExpand)
    }

    private var launcherState: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s3) {
            HStack(spacing: Tokens.Spacing.s3) {
                compactAppIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(isUserIn ? "You're in" : "Start a meetup")
                        .font(Tokens.Typography.headline)
                        .foregroundStyle(Tokens.Palette.textPrimary)
                    Text(isUserIn ? "Waiting for others." : "Share in this chat.")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                rosterCountPill
            }

            compactPrimaryAction

            // Delivery status (e.g. the insert-fallback's "tap send to
            // deliver" hint, or a send failure) — the launcher previously had
            // no status surface at all, so staged sends looked like silence.
            if let statusMessage, !isSending {
                Text(statusMessage)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: Tokens.Spacing.s2) {
                Button(action: onExpand) {
                    Label("Browse", systemImage: "arrow.up.forward.app")
                        .font(Tokens.Typography.captionBold)
                        .frame(maxWidth: .infinity, minHeight: Tokens.Layout.minTapTarget)
                }
                .buttonStyle(.tweenPrimary(.subtle))

                if isUserIn {
                    Button(action: onImOut) {
                        Label("I'm out", systemImage: "location.slash")
                            .font(Tokens.Typography.captionBold)
                            .frame(maxWidth: .infinity, minHeight: Tokens.Layout.minTapTarget)
                    }
                    .buttonStyle(.tweenPrimary(.destructive))
                    // handleImOut drops taps while a send is in flight (the
                    // double-fire guard) — reflect that instead of looking
                    // tappable and doing nothing (post-push verify).
                    .disabled(isSending)
                    .accessibilityHint("Stops sharing you as active for this meetup")
                } else {
                    Button(action: onExpand) {
                        Label("Details", systemImage: "person.2")
                            .font(Tokens.Typography.captionBold)
                            .frame(maxWidth: .infinity, minHeight: Tokens.Layout.minTapTarget)
                    }
                    .buttonStyle(.tweenPrimary(.subtle))
                }
            }
        }
        .padding(Tokens.Spacing.s3)
        .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous))
    }

    private var activeMeetupState: some View {
        VStack(spacing: Tokens.Spacing.s3) {
            Button(action: onExpand) {
                HStack(spacing: Tokens.Spacing.s4) {
                    thumbnail
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
                        Text(title)
                            .font(Tokens.Typography.headline)
                            .foregroundStyle(Tokens.Palette.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(subtitle)
                            .font(Tokens.Typography.callout)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: Tokens.Spacing.s2) {
                            statusPill
                            compactRoster
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(Tokens.Spacing.s3)
                .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous)
                        .strokeBorder(Tokens.Palette.brand.opacity(0.18), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)

            compactPrimaryAction

            // Secondary row only while in: Browse + I'm out. When not in, the
            // card tap and the "I'm in" CTA cover both actions, and dropping
            // the row keeps the stack inside the keyboard-height budget.
            if isUserIn {
                HStack(spacing: Tokens.Spacing.s2) {
                    Button(action: onExpand) {
                        Label(received?.kind == .place ? "Review spot" : "Browse spots",
                              systemImage: received?.kind == .place ? "checkmark.bubble" : "arrow.up.forward.app")
                            .font(Tokens.Typography.captionBold)
                            .frame(maxWidth: .infinity, minHeight: Tokens.Layout.minTapTarget)
                    }
                    .buttonStyle(.tweenPrimary(.subtle))

                    Button(action: onImOut) {
                        Label("I'm out", systemImage: "location.slash")
                            .font(Tokens.Typography.captionBold)
                            .frame(maxWidth: .infinity, minHeight: Tokens.Layout.minTapTarget)
                    }
                    .buttonStyle(.tweenPrimary(.destructive))
                    .disabled(isSending)
                    .accessibilityHint("Stops sharing you as active for this meetup")
                }
            }
        }
    }

    private var compactAppIcon: some View {
        ZStack {
            Circle()
                .fill(Tokens.Palette.brandLight)
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Palette.brand)
        }
        .frame(width: 42, height: 42)
    }

    private var rosterCountPill: some View {
        let count = currentParticipantCount ?? (isUserIn ? 1 : 0)
        return rosterPill("\(count) in", systemImage: "person.2.fill", color: isUserIn ? Tokens.Palette.success : Tokens.Palette.textSecondary)
    }

    /// Overlapping avatar dots for who's in (redesign: the roster strip, at
    /// compact scale) — falls back to a plain count when no roster is on the
    /// bubble yet. Names are sanitised so an unnamed sender reads as a glyph.
    @ViewBuilder
    private var compactRoster: some View {
        let participants = received?.participants ?? []
        let rosterCount = currentParticipantCount ?? participants.count
        if participants.count > 1 {
            HStack(spacing: -8) {
                ForEach(Array(participants.prefix(3).enumerated()), id: \.offset) { _, p in
                    Text(UserName.peerDisplayName(p.name) == "Friend" ? "•" : SpotETADisplay.initials(for: p.name))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(Tokens.Palette.onBrand)
                        .frame(width: 24, height: 24)
                        .background(Tokens.Palette.brand, in: Circle())
                        .overlay(Circle().strokeBorder(Tokens.Palette.surfaceSecondary, lineWidth: 1.5))
                }
                if participants.count > 3 {
                    Text("+\(participants.count - 3)")
                        .font(Tokens.Typography.caption2Bold)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .padding(.horizontal, Tokens.Spacing.s2)
                        .frame(height: 24)
                        .background(Tokens.Palette.surface, in: Capsule())
                        .padding(.leading, 12)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(rosterCount) people in")
        } else if rosterCount > 1 {
            rosterPill("\(rosterCount) in", systemImage: "person.2.fill", color: Tokens.Palette.brand)
        }
    }

    private func rosterPill(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(Tokens.Typography.captionBold)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, Tokens.Spacing.s2)
            .frame(minHeight: 30)
            .background(color.opacity(0.12), in: Capsule())
    }

    /// The compact CTA. Nothing renders when the user is already in — the
    /// header/status pill carries that state, and the confirmation banner it
    /// used to show pushed the layout past the keyboard-height budget.
    @ViewBuilder
    private var compactPrimaryAction: some View {
        if isUserIn {
            // Nothing: the header/status pill already says "You're in", and any
            // delivery status (staged "tap send to deliver" hint, failures)
            // renders via the card subtitle / launcher status line. A banner
            // here pushed the stack past the keyboard-height budget.
            EmptyView()
        } else if isSending {
            HStack(spacing: Tokens.Spacing.s2) {
                ProgressView()
                Text(statusMessage ?? "Sharing...")
                    .font(Tokens.Typography.headline)
            }
            .frame(maxWidth: .infinity, minHeight: Tokens.Layout.primaryControlHeight)
            .background(Tokens.Palette.neutralAction, in: Capsule())
        } else {
            Button(action: onImIn) {
                Label("I'm in", systemImage: "location.fill")
                    .font(Tokens.Typography.headline)
                    .frame(maxWidth: .infinity, minHeight: Tokens.Layout.primaryControlHeight)
            }
            .buttonStyle(.tweenPrimary())
            .accessibilityHint("Shares where you are with your friend")
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let received {
            TweenMapSnapshotView(
                markers: markers(for: received),
                cornerRadius: Tokens.Radius.card,
                focusCoordinate: received.kind == .place ? received.coordinate : nil)
                .frame(width: 96, height: 72)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.card).fill(Tokens.Palette.surfaceSecondary)
                Image(systemName: "map.fill").foregroundStyle(Tokens.Palette.textTertiary)
            }
            .frame(width: 96, height: 72)
        }
    }

    private var statusPill: some View {
        HStack(spacing: Tokens.Spacing.s1) {
            Image(systemName: isUserIn ? "checkmark.circle.fill" : "location.circle")
            Text(isUserIn ? "You are in" : "Waiting on you")
        }
        .font(Tokens.Typography.captionBold)
        .foregroundStyle(isUserIn ? Tokens.Palette.success : Tokens.Palette.brand)
        .padding(.horizontal, Tokens.Spacing.s2)
        .frame(minHeight: 26)
        .background((isUserIn ? Tokens.Palette.success : Tokens.Palette.brand).opacity(0.12), in: Capsule())
    }

    /// The received payload plus fresh participant cache when available. In a
    /// group chat the bubble carries everyone who's "in" via
    /// `state.participants`; render a friend pin for each. Self is rendered
    /// separately from the local cache, deduped by participant identity so I don't double-pin
    /// when I'm in the received roster.
    private func markers(for state: TweenState) -> [MapMarker] {
        var result: [MapMarker] = []
        let myName = UserProfile.displayName ?? UserName.fallback
        let myId = localParticipantID ?? myName

        if state.kind == .place {
            // The place itself.
            result.append(MapMarker(coordinate: state.coordinate, role: .fairSpot))
        }

        // Every "in" participant other than me from the group roster.
        for participant in state.participants where !participant.matches(id: myId, name: myName) {
            result.append(MapMarker(coordinate: participant.coordinate, role: .friend))
        }
        // For legacy bubbles (kind=.participant, empty participants[]) the
        // main coord IS the friend's pin. representsParticipantLocation rules
        // out `.leave` payloads, whose main coord is the LEAVER's last position
        // — an empty-roster leave must not pin the person who just left.
        if state.representsParticipantLocation && state.participants.isEmpty {
            result.append(MapMarker(coordinate: state.coordinate, role: .friend))
        }

        if let me = LocationCache.loadSelf()?.coordinate {
            result.append(MapMarker(coordinate: me, role: isUserIn ? .selfActive : .selfDot))
        }
        return result
    }

    private var title: String {
        if received?.kind == .place, let received {
            return received.text
        }
        if let name = received?.senderName, !name.isEmpty {
            return "\(name) invited you to meet up"
        }
        if let received { return received.text }
        return isUserIn ? "You're in" : "Find a place to meet"
    }

    private var subtitle: String {
        if let statusMessage {
            return statusMessage
        }
        if received?.messageType == .leave {
            return isUserIn ? "They stepped out — you're still in" : "They stepped out"
        }
        if received?.kind == .place, received?.isFullyAgreed == true {
            return isUserIn ? "It's a plan — tap for directions" : "It's a plan — tap “I'm in” to rejoin"
        }
        if received?.kind == .place {
            return isUserIn ? "Review maps and agreement" : "Tap “I'm in” to share"
        }
        if received?.senderName != nil {
            return "Tap to find a fair spot"
        }
        if received != nil {
            return isUserIn ? "Tap to pick a fair spot" : "Your friend shared a spot — tap to join"
        }
        return isUserIn ? "Waiting for your friend…" : "Tap “I'm in” to share where you are"
    }

}

/// Formats a drive-time duration as a compact human string: "<1 min", "8 min",
/// or "1h 5m". The ONLY ETA formatter — both targets use it, so the same drive
/// can never read "9 min" in the extension and "10 min" in the app. Rounds to
/// the nearest minute (matching ETAChip's arithmetic) rather than truncating.
func formatETA(_ seconds: TimeInterval) -> String {
    let minutes = Int((seconds / 60).rounded())
    if minutes < 1 { return "<1 min" }
    if minutes < 60 { return "\(minutes) min" }
    return "\(minutes / 60)h \(minutes % 60)m"
}

// NOTE: ExpandedView uses an interactive SwiftUI `Map`, which IS an `MKMapView`
// under the hood — there is no lighter variant. This is a *deliberate* exception
// to CLAUDE.md HARD CONSTRAINT #1 ("MKMapSnapshotter only") for this view only,
// because expanded browsing needs pan/zoom. The ~120 MB extension ceiling is real,
// so the footprint is held down by: flat elevation (no 3D meshes), no material
// blur or pulse on annotations, a capped camera zoom, and a memory-warning
// fallback (`useStaticMap`) that swaps in the cheap `TweenMapSnapshotView`.
// CompactView and BubbleImageRenderer still use MKMapSnapshotter unconditionally.
//
/// Full-screen presentation for the Messages extension.
///
/// Shows an interactive SwiftUI `Map` framing both friends, the fair midpoint,
/// and every ranked spot (each tagged with both drive times), above a scrollable
/// list of those spots. Tapping a pin highlights its row and vice-versa; the
/// primary call to action adapts to whether you've shared your location yet and,
/// once you have, sends the spot you pick. An offline banner replaces the live
/// ranking when there's no network.
struct ExpandedView: View {
    let received: TweenState?
    let selfCoord: CLLocationCoordinate2D?
    let rankedSpots: [RankedSpot]
    let isUserIn: Bool
    var totalSeats: Int = 1
    /// True only while the extension has an active ranking task. Empty results
    /// alone are not enough to imply loading because MapKit can legitimately
    /// return nothing or ranking can be blocked by missing participants.
    var isRanking: Bool = false
    /// Additive to the spec's parameter list so the offline banner has a source.
    var isOnline: Bool = true
    /// When true, the live `Map` is replaced by the static `MKMapSnapshotter`-backed
    /// `TweenMapSnapshotView`. The extension flips this on a memory warning to shed
    /// the `MKMapView` before the process is jettisoned. Defaults to the live map.
    var useStaticMap: Bool = false
    /// A spot handed off from the host app, awaiting confirmation before send.
    var draft: OutgoingDraft? = nil
    var localParticipantID: String? = nil
    /// Spot name the extension just sent with `MSConversation.send`, used to
    /// keep the CTA from looking tappable while Messages has already queued it.
    var recentlySentSpotName: String? = nil
    var onImIn: () -> Void
    var onImOut: () -> Void = {}
    var onSelectSpot: (RankedSpot) -> Void
    var onAgreePlace: (TweenState) -> Void = { _ in }
    var onSendDraft: () -> Void = {}
    var onOpenFullApp: () -> Void = {}
    /// Fired by the MEETUP SET view's map-app buttons.
    var onOpenAppleMaps: (TweenState) -> Void = { _ in }
    var onOpenGoogleMaps: (TweenState) -> Void = { _ in }
    var isSending: Bool = false
    var statusMessage: String?
    /// Whether `statusMessage` reports a failure (warning banner) or routine
    /// progress/confirmation copy (neutral banner). One string channel carries
    /// both, so the sender must say which it is.
    var statusIsError: Bool = false

    @State private var selectedSpotID: RankedSpot.ID?
    /// Drives the interactive map's camera. `.automatic` frames every annotation
    /// (self, peer, midpoint, spots) with padding; selecting a row switches it to
    /// a region centered on that spot. A user pan/zoom hands control back to them.
    @State private var mapPosition: MapCameraPosition = .automatic
    /// Bumped on every send so the CTA can fire an impact haptic.
    @State private var sendTick = 0

    // Accessibility (Phase C): the floating panel + status pill are translucent
    // material; fall back to a solid surface under Reduce Transparency, and drop
    // the slide-in under Reduce Motion.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Spot cards grow with the user's text size instead of clipping.
    @ScaledMetric(relativeTo: .subheadline) private var spotCardWidth: CGFloat = 176
    @ScaledMetric(relativeTo: .subheadline) private var spotCardHeight: CGFloat = 176

    /// The panel/pill background: translucent material, or an opaque surface
    /// when the user has asked to reduce transparency.
    private var panelSurface: AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(Tokens.Palette.surface) : AnyShapeStyle(.regularMaterial)
    }

    private var myName: String {
        UserProfile.displayName ?? UserName.fallback
    }

    /// Every "in" participant other than the local user, drawn from the
    /// received bubble's roster. The 2-person fallback (no participants array
    /// on the bubble, or only legacy info present) still resolves to a single
    /// peer via the existing single-peer cache so prior conversations look
    /// identical.
    private var otherParticipants: [Participant] {
        if let received, !received.participants.isEmpty {
            let myId = localParticipantID ?? myName
            // Sanitise legacy "You"/empty peer names to "Friend" for display
            // (audit F2). Identity keeps riding on the id, so filtering above
            // is unaffected; only the shown label changes.
            return received.participants
                .filter { !$0.matches(id: myId, name: myName) }
                .map { Participant(id: $0.id, name: UserName.peerDisplayName($0.name),
                                   coordinate: $0.coordinate, needsRide: $0.needsRide) }
        }
        // Legacy fallback: only one peer's worth of info.
        if let legacyPeer = legacyPeerCoord {
            return [Participant(id: "peer", name: "Friend", coordinate: legacyPeer)]
        }
        return []
    }

    /// The peer's shared coordinate. Place payloads are intentionally ignored so
    /// a chosen cafe can never masquerade as the friend.
    private var peerCoord: CLLocationCoordinate2D? {
        otherParticipants.first?.coordinate
    }

    private var legacyPeerCoord: CLLocationCoordinate2D? {
        if received?.representsParticipantLocation == true {
            return received?.coordinate
        }
        guard LocationCache.isPeerActive else { return nil }
        return LocationCache.loadPeer()?.coordinate
    }

    private var receivedPlaceCoord: CLLocationCoordinate2D? {
        received?.kind == .place ? received?.coordinate : nil
    }

    /// True when there's nothing geographic to plot yet — no self, peer, or draft.
    private var hasMapContent: Bool {
        selfCoord != nil || peerCoord != nil || receivedPlaceCoord != nil || draft != nil || !rankedSpots.isEmpty
    }

    /// Terminal state — everyone the proposer needs has agreed. Once true,
    /// the body swaps from the spot-list/agree-or-change UI to the dedicated
    /// MEETUP SET hero with map-app choices. No more negotiation.
    private var isMeetupSet: Bool {
        guard let received else { return false }
        return received.messageType == .agree && received.isFullyAgreed
    }

    /// Every not-in recipient of an invite gets the join hero — including the
    /// 3rd+ person in a group chat whose invite already carries ≥2 participants.
    /// (Gating on !inviteHasEnoughPeopleForSpots dropped those users into the
    /// spot-list layout, which has no "I'm in" affordance at all.)
    private var isInvitePrompt: Bool {
        received?.messageType == .invite && !isUserIn
    }

    private var inviteHasEnoughPeopleForSpots: Bool {
        guard let received, received.messageType == .invite else { return false }
        return received.participants.count >= 2
    }

    private var activeParticipantCount: Int {
        var count = otherParticipants.count
        if isUserIn || selfCoord != nil {
            count += 1
        }
        if inviteHasEnoughPeopleForSpots, let received {
            count = max(count, received.participants.count)
        }
        return count
    }

    private var coordinateParticipantCount: Int {
        var count = otherParticipants.count
        if selfCoord != nil {
            count += 1
        }
        if inviteHasEnoughPeopleForSpots, let received {
            count = max(count, received.participants.count)
        }
        return count
    }

    private var hasEnoughPeopleForSpots: Bool {
        coordinateParticipantCount >= 2 || inviteHasEnoughPeopleForSpots
    }

    private var isWaitingForCoordinates: Bool {
        activeParticipantCount >= 2 && !hasEnoughPeopleForSpots
    }

    private var canSendSpotFromCurrentPeople: Bool {
        hasEnoughPeopleForSpots
    }

    // MARK: - Layout
    //
    // Redesign (audit Part 2): the extension used to stack up to five opaque
    // chrome bands (offline banner · status banner · 120pt status card · 60/40
    // map/list split · CTA footer) around a squeezed map. The new shape is one
    // full-bleed map canvas with everything else floating on it in two layers —
    // a slim status pill up top and a single translucent panel (roster strip ·
    // horizontal spot cards · one contextual CTA) at the bottom. The hero states
    // (invite, meetup set) already use this map+panel shape and are unchanged.

    var body: some View {
        Group {
            if isMeetupSet, let received {
                meetupSetView(state: received)
            } else if isInvitePrompt, let received {
                invitePromptView(state: received)
            } else {
                browseLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque background for the expanded surface for the same reason
        // CompactView sets one — never read as transparent against the
        // iMessage host.
        .background(Color(.systemBackground))
    }

    /// Map canvas + floating status pill + bottom panel. Covers the Browse,
    /// Waiting, and Terminal-place (non-agreed) configurations of the state
    /// matrix; the panel's contents adapt to the current negotiation state.
    private var browseLayout: some View {
        // The panel is a bottom safe-area inset, so the map gets its OWN region
        // ABOVE it and frames its content there — the old full-bleed-behind-panel
        // layout hid the map's lower half under the panel and read as "cut off"
        // (device feedback). The panel keeps its floating material look.
        mapSection
            .overlay(alignment: .top) {
                if let pill = statusPill {
                    statusPillView(pill.text, isError: pill.isError)
                        .padding(.top, Tokens.Spacing.s3)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                browsePanel
            }
    }

    // MARK: Status pill

    /// The one thing worth saying over the map right now: offline, a send in
    /// flight / failure, or nothing (most states — the panel carries the rest).
    private var statusPill: (text: String, isError: Bool)? {
        if !isOnline { return ("You're offline. Reconnect to find fair spots.", true) }
        if let statusMessage, !isSending { return (statusMessage, statusIsError) }
        return nil
    }

    private func statusPillView(_ text: String, isError: Bool) -> some View {
        let tint = isError ? Tokens.Palette.destructive : Tokens.Palette.textSecondary
        return Label {
            Text(text).lineLimit(2).multilineTextAlignment(.center)
        } icon: {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
        }
        .font(Tokens.Typography.captionBold)
        .foregroundStyle(tint)
        .padding(.horizontal, Tokens.Spacing.s3)
        .padding(.vertical, Tokens.Spacing.s2)
        .background(panelSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
        .padding(.horizontal, Tokens.Spacing.s4)
        .tweenElevation(.pin)
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        .accessibilityLabel(text)
    }

    // MARK: Bottom panel

    private var browsePanel: some View {
        VStack(spacing: Tokens.Spacing.s3) {
            Capsule()
                .fill(Tokens.Palette.textTertiary.opacity(0.35))
                .frame(width: 42, height: 5)
                .accessibilityHidden(true)

            panelHeadline

            rosterStrip

            if rankedSpots.isEmpty {
                panelEmptyState
            } else {
                spotCardRail
            }

            primaryCTA
            bottomAction
        }
        .padding(Tokens.Spacing.s4)
        .frame(maxWidth: .infinity)
        .background(panelSurface, in: UnevenRoundedRectangle(
            topLeadingRadius: Tokens.Radius.sheet,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: Tokens.Radius.sheet,
            style: .continuous))
        .tweenElevation(.sheet)
    }

    /// Eyebrow + title (place name, "Waiting for someone else", …) with an
    /// optional group-progress chip — the panel's single line of context,
    /// replacing the old 120pt status card.
    private var panelHeadline: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.s2) {
            VStack(alignment: .leading, spacing: 2) {
                if received != nil {
                    Text(statusEyebrow)
                        .font(Tokens.Typography.caption2Bold)
                        .textCase(.uppercase)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
                Text(statusTitle)
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            if let received, let progress = groupProgress(for: received) {
                Text(progress)
                    .font(Tokens.Typography.caption2Bold)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, Tokens.Spacing.s2)
                    .frame(minHeight: 24)
                    .background(Tokens.Palette.surface, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Roster strip

    /// Avatar dots + names for everyone "in" — replaces the readiness chips.
    private var rosterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Spacing.s2) {
                if isUserIn || selfCoord != nil {
                    rosterDot(name: "You", isSelf: true)
                }
                ForEach(otherParticipants.prefix(8)) { participant in
                    rosterDot(name: participant.name, isSelf: false)
                }
                if otherParticipants.count > 8 {
                    Text("+\(otherParticipants.count - 8)")
                        .font(Tokens.Typography.caption2Bold)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .padding(.horizontal, Tokens.Spacing.s2)
                        .frame(minHeight: 26)
                        .background(Tokens.Palette.surface, in: Capsule())
                }
                let waiting = max(totalSeats - activeParticipantCount, 0)
                if waiting > 0 {
                    Label("Waiting \(waiting)", systemImage: "hourglass")
                        .font(Tokens.Typography.caption2Bold)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, Tokens.Spacing.s2)
                        .frame(minHeight: 26)
                        .background(Tokens.Palette.surface, in: Capsule())
                }
            }
            .padding(.horizontal, 1)
        }
        .accessibilityLabel("Who's in")
    }

    private func rosterDot(name: String, isSelf: Bool) -> some View {
        HStack(spacing: Tokens.Spacing.s1) {
            Text(isSelf ? "You" : SpotETADisplay.initials(for: name))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Tokens.Palette.onBrand)
                .frame(width: isSelf ? nil : 26, height: 26)
                .padding(.horizontal, isSelf ? Tokens.Spacing.s2 : 0)
                .background(isSelf ? Tokens.Palette.pinSelf : Tokens.Palette.brand,
                            in: isSelf ? AnyShape(Capsule()) : AnyShape(Circle()))
            if !isSelf {
                Text(name)
                    .font(Tokens.Typography.caption2Bold)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
            }
        }
        .padding(.trailing, isSelf ? 0 : Tokens.Spacing.s2)
        .padding(.vertical, 2)
        .background(Tokens.Palette.surface, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isSelf ? "You, in" : "\(name), in")
    }

    // MARK: Spot cards

    /// Horizontally paging spot cards — every person's time on every card,
    /// replacing the vertical 40%-height list.
    private var spotCardRail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Tokens.Spacing.s3) {
                    ForEach(rankedSpots) { spot in
                        spotCard(spot).id(spot.id)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 2)
            }
            .onChange(of: selectedSpotID) { _, newValue in
                guard let newValue else { return }
                withAnimation(Tokens.Motion.snappy) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .sensoryFeedback(.selection, trigger: selectedSpotID)
        }
    }

    private func spotCard(_ spot: RankedSpot) -> some View {
        let isSelected = selectedSpotID == spot.id
        let name = spot.item?.name ?? "Spot"
        return VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            spotCardHeader(spot, name: name)
            spotCardPeople(spot)
            Spacer(minLength: 0)
            spotCardSpread(spot)
        }
        .padding(Tokens.Spacing.s3)
        .frame(width: spotCardWidth, height: spotCardHeight, alignment: .topLeading)
        .background(isSelected ? Tokens.Palette.brand.opacity(0.14) : Tokens.Palette.surface,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(isSelected ? Tokens.Palette.brand : Color.clear, lineWidth: 1.5)
        }
        .animation(reduceMotion ? nil : Tokens.Motion.snappy, value: isSelected)
        .contentShape(Rectangle())
        .onTapGesture { select(spot, animateMap: true) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(SpotETADisplay.compactLabel(for: spot, bestWorstETA: spotBestWorstETA))")
        .accessibilityHint("Selects this spot to send")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func spotCardHeader(_ spot: RankedSpot, name: String) -> some View {
        let isBest = rankedSpots.first?.id == spot.id
        return HStack(spacing: Tokens.Spacing.s1) {
            Text(name)
                .font(Tokens.Typography.subheadline.weight(.semibold))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
            if isBest {
                // Brand-colored "Best" — the recommendation, kept distinct from
                // the green/yellow/orange fairness tiers (device feedback: a
                // yellow star clashed with a green "Even" spot).
                Text("Best")
                    .font(Tokens.Typography.caption2Bold)
                    .foregroundStyle(Tokens.Palette.onBrand)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 18)
                    .background(Tokens.Palette.brand, in: Capsule())
            }
        }
    }

    /// Shortest worst-case drive across the ranked spots — the reference the
    /// per-spot quality colour compares against.
    private var spotBestWorstETA: TimeInterval? { rankedSpots.map(\.worstETA).min() }

    @ViewBuilder
    private func spotCardPeople(_ spot: RankedSpot) -> some View {
        let extra = spot.etas.count - 4
        let tint = SpotETADisplay.qualityColor(for: spot, bestWorstETA: spotBestWorstETA)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(spot.etas.prefix(4)) { eta in
                spotCardPersonRow(eta, tint: tint)
            }
            if extra > 0 {
                Text("+\(extra) more")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
            }
        }
    }

    private func spotCardPersonRow(_ eta: ParticipantETA, tint: Color) -> some View {
        HStack(spacing: Tokens.Spacing.s1) {
            Text(SpotETADisplay.initials(for: eta.name))
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Tokens.Palette.onBrand)
                .frame(width: 18, height: 18)
                .background(Tokens.Palette.brand, in: Circle())
            Text(eta.name)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: Tokens.Spacing.s1)
            // Time coloured by the spot's fairness so a fair spot's rows read
            // green at a glance (device feedback: restore the color-coded times).
            // On a tinted capsule (like the host chip) so it stays readable in
            // both light and dark (post-push audit: bare yellow text was low
            // contrast on a light surface).
            Text(formatETA(eta.eta))
                .font(Tokens.Typography.captionBold.monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .frame(minHeight: 20)
                .background(tint.opacity(0.16), in: Capsule())
        }
    }

    private func spotCardSpread(_ spot: RankedSpot) -> some View {
        let tint = SpotETADisplay.qualityColor(for: spot, bestWorstETA: spotBestWorstETA)
        return HStack(spacing: Tokens.Spacing.s1) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(SpotETADisplay.qualityWord(for: spot, bestWorstETA: spotBestWorstETA))
                .font(Tokens.Typography.caption2Bold)
                .foregroundStyle(tint)
        }
    }

    /// The card rail's empty slot — ranking shimmer, waiting, or "no spots".
    /// Compact horizontal layout so it doesn't waste a tall block of space
    /// repeating the status (device feedback).
    private var panelEmptyState: some View {
        HStack(spacing: Tokens.Spacing.s3) {
            Image(systemName: emptySpotListIcon)
                .font(.system(size: 22))
                .foregroundStyle(Tokens.Palette.brand)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(emptySpotListTitle)
                    .font(Tokens.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                Text(emptySpotListSubtitle)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Spacing.s3)
        .background(Tokens.Palette.surface.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: Invitation

    private var statusEyebrow: String {
        guard let received else {
            return isUserIn ? "You're in" : "Tween"
        }
        let name = received.senderName ?? "Your friend"
        switch received.messageType {
        case .invite: return "Invite"
        case .leave: return "\(name) left"
        case .propose: return "\(name) chose"
        case .counter: return "\(name) suggests"
        case .agree where received.isFullyAgreed: return "Meetup set"
        case .agree: return "Agreement"
        }
    }

    private var statusTitle: String {
        if let draft, received == nil {
            return "Ready to send \(draft.spotName)"
        }
        guard let received else {
            if isRanking { return "Finding fair spots" }
            if hasEnoughPeopleForSpots { return "Ready to pick a spot" }
            if isWaitingForCoordinates { return "Getting locations" }
            // "You're in" (your status) — the "waiting for someone else"
            // explanation lives once in the empty-state card, not repeated as
            // the headline too (device feedback).
            return isUserIn ? "You're in" : "Find a fair spot"
        }
        if received.kind == .place {
            return received.text
        }
        if let sender = received.senderName, !sender.isEmpty {
            return sender
        }
        return received.text
    }

    private func groupProgress(for state: TweenState) -> String? {
        let count = state.participants.count
        switch state.messageType {
        case .invite where count >= 2:
            let notInYet = max(totalSeats - count, 0)
            return notInYet > 0 ? "\(count) ready now · \(notInYet) not in yet" : "\(count) ready"
        case .leave:
            return count > 0 ? "\(count) still ready" : "No one is in"
        case .agree where (!state.agreedNames.isEmpty || !state.agreedIDs.isEmpty) && !state.isFullyAgreed:
            let needed = max(count - 1, 1)
            let agreedCount = state.agreedIDs.isEmpty ? state.agreedNames.count : state.agreedIDs.count
            return "\(agreedCount) of \(needed) agreed"
        default:
            return nil
        }
    }


    private func invitePromptView(state: TweenState) -> some View {
        // Map gets its own region above the panel (device feedback: the map
        // read as "cut off" behind the floating panel).
        mapSection
            .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Tokens.Spacing.s4) {
                Capsule()
                    .fill(Tokens.Palette.textTertiary.opacity(0.35))
                    .frame(width: 42, height: 5)
                    .accessibilityHidden(true)

                VStack(spacing: Tokens.Spacing.s2) {
                    Image(systemName: "person.2.fill")
                        .font(Tokens.Typography.title2)
                        .foregroundStyle(Tokens.Palette.brand)
                        .frame(width: 48, height: 48)
                        .background(Tokens.Palette.brandLight, in: Circle())

                    Text("You've been invited")
                        .font(Tokens.Typography.callout)
                        .foregroundStyle(Tokens.Palette.textSecondary)

                    Text(state.senderName ?? "Your friend")
                        .font(Tokens.Typography.title.weight(.bold))
                        .foregroundStyle(Tokens.Palette.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)

                    if let progress = groupProgress(for: state) {
                        Text(progress)
                            .font(Tokens.Typography.captionBold)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .padding(.horizontal, Tokens.Spacing.s3)
                            .padding(.vertical, Tokens.Spacing.s1)
                            .background(.thinMaterial, in: Capsule())
                    }
                }

                Button(action: onImIn) {
                    if isSending {
                        HStack(spacing: Tokens.Spacing.s2) {
                            ProgressView()
                            Text(statusMessage ?? "Sharing...")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("I'm in", systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.tweenPrimary())
                .disabled(isSending)
                .accessibilityHint("Shares where you are for this meetup")

                Button(action: onOpenFullApp) {
                    Label("Browse spots", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.tweenPrimary(.subtle))
                .accessibilityHint("Opens the full Tween app to search for places")
            }
            .padding(Tokens.Spacing.s4)
            .background(.regularMaterial, in: UnevenRoundedRectangle(
                topLeadingRadius: Tokens.Radius.sheet,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: Tokens.Radius.sheet,
                style: .continuous
            ))
            .tweenElevation(.sheet)
        }
        .background(Color(.systemBackground))
    }

    // MARK: Map

    /// What the static snapshot centers on. The spot you've selected takes
    /// priority — tapping a card recenters the map (redesign: "selection
    /// re-focuses the snapshot") — then a received place or staged draft.
    private var snapshotFocus: CLLocationCoordinate2D? {
        selectedSpot?.item?.placemark.coordinate ?? receivedPlaceCoord ?? draft?.coordinate
    }

    @ViewBuilder
    private var mapSection: some View {
        if hasMapContent {
            if useStaticMap || usesStaticMapForCurrentState {
                // Memory-pressure fallback: the cheap snapshot path, no MKMapView.
                TweenMapSnapshotView(
                    markers: staticMarkers,
                    cornerRadius: 0,
                    focusCoordinate: snapshotFocus,
                    // The map now has its own region above the panel, so only a
                    // gentle lift keeps the spot off dead-center (room for the pill).
                    focusYOffsetRatio: snapshotFocus != nil ? 0.1 : 0)
            } else {
                interactiveMap
            }
        } else {
            ZStack {
                Rectangle().fill(Tokens.Palette.surfaceSecondary)
                VStack(spacing: Tokens.Spacing.s2) {
                    Image(systemName: isWaitingForCoordinates ? "location.circle" : "location.slash")
                        .font(Tokens.Typography.title)
                    Text(isWaitingForCoordinates ? "Waiting for locations" : "Share your location to see the map")
                        .font(Tokens.Typography.footnote)
                }
                .foregroundStyle(Tokens.Palette.textSecondary)
            }
        }
    }

    /// All coordinates currently "in" the meetup (self + every other
    /// participant), used to compute the centroid pin and frame the camera.
    private var allMeetupCoords: [CLLocationCoordinate2D] {
        var coords = otherParticipants.map(\.coordinate)
        if let selfCoord { coords.append(selfCoord) }
        return coords
    }

    /// Markers for the static fallback snapshot: people, any proposed place, and
    /// ranked spots using the shared pin role system.
    private var staticMarkers: [MapMarker] {
        var result: [MapMarker] = []
        if let selfCoord {
            let myId = localParticipantID ?? myName
            let localNeedsRide = LocationCache.loadParticipants().first(where: { $0.matches(id: myId, name: myName) })?.needsRide ?? false
            result.append(MapMarker(coordinate: selfCoord, role: localNeedsRide ? .rideNeeded : (isUserIn ? .selfActive : .selfDot)))
        }
        for participant in otherParticipants {
            result.append(MapMarker(coordinate: participant.coordinate, role: participant.needsRide ? .rideNeeded : .friend))
        }
        // No centroid/midpoint marker (audit F3): the geographic middle isn't a
        // place anyone meets, and on the small extension map it just adds
        // clutter. The centroid still frames the camera via allMeetupCoords.
        // Exactly ONE gold "the spot" pin. When a proposed place and/or a draft
        // is on the map, the ranked candidates all render as plain results —
        // three identical gold pins gave the user no way to tell which one was
        // the actual proposal.
        let hasHeroSpot = receivedPlaceCoord != nil || draft != nil
        if let receivedPlaceCoord {
            result.append(MapMarker(coordinate: receivedPlaceCoord, role: .fairSpot))
        }
        if let draft {
            result.append(MapMarker(coordinate: draft.coordinate, role: receivedPlaceCoord == nil ? .fairSpot : .result))
        }
        for (index, spot) in rankedSpots.enumerated() {
            if let coordinate = spot.item?.placemark.coordinate {
                let isBest = index == 0 && !hasHeroSpot
                result.append(MapMarker(coordinate: coordinate, role: isBest ? .fairSpot : .result))
            }
        }
        return result
    }

    private var interactiveMap: some View {
        Map(position: $mapPosition, bounds: cameraBounds) {
            // Your location pin
            if let selfCoord {
                let myId = localParticipantID ?? myName
                let localNeedsRide = LocationCache.loadParticipants().first(where: { $0.matches(id: myId, name: myName) })?.needsRide ?? false
                Annotation("You", coordinate: selfCoord) {
                    TweenPin(role: isUserIn ? .selfActive : .selfDot,
                             needsRide: localNeedsRide, animated: false)
                }
            }

            // Every other participant who's "in" — one pin each, labelled
            // with their name (which is what other people see on their map
            // when their device is the local "self").
            ForEach(otherParticipants) { participant in
                Annotation(participant.name, coordinate: participant.coordinate) {
                    TweenPin(role: .friend,
                             initials: TweenPin.initials(for: participant.name),
                             needsRide: participant.needsRide,
                             animated: false)
                }
            }

            // Centroid marker removed (audit F3): no midpoint pin. The
            // centroid still frames the camera, it just isn't drawn.

            if let receivedPlaceCoord {
                Annotation(received?.text ?? "Meetup spot", coordinate: receivedPlaceCoord) {
                    TweenPin(role: .fairSpot, animated: false)
                }
            }

            // A spot the host app staged for hand-off
            if let draft {
                Annotation(draft.spotName, coordinate: draft.coordinate) {
                    TweenPin(role: .fairSpot, animated: false)
                }
            }

            // All ranked spot pins, each with an A/B drive-time chip
            ForEach(rankedSpots) { spot in
                if let item = spot.item {
                    Annotation(item.name ?? "Spot", coordinate: item.placemark.coordinate) {
                        spotPin(spot)
                    }
                }
            }
        }
        // Flat, not .realistic: 3D terrain/building meshes are a large memory + GPU
        // cost we can't afford in the extension, and a meetup map doesn't need them.
        .mapStyle(.standard(elevation: .flat))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .accessibilityLabel("Interactive map of you, your friend, and meetup spots")
    }

    /// Caps how far out the camera can zoom so it can't pull in a continent's worth
    /// of tiles, while still letting users zoom in to street level.
    private var cameraBounds: MapCameraBounds {
        MapCameraBounds(minimumDistance: 400, maximumDistance: 200_000)
    }

    private var usesStaticMapForCurrentState: Bool {
        true
    }

    /// A ranked-spot map pin: a drive-time chip floating above a category
    /// glyph. For ≤4 participants we show "Alice 8 · Bob 12"; for 5+ we drop
    /// names and just list the minutes to keep the chip readable.
    private func spotPin(_ spot: RankedSpot) -> some View {
        let isSelected = selectedSpotID == spot.id
        let isBestFair = rankedSpots.first?.id == spot.id
        let role: TweenPin.Role = isBestFair ? .fairSpot : .result
        return VStack(spacing: 2) {
            Text(SpotETADisplay.compactLabel(for: spot, bestWorstETA: spotBestWorstETA))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                // Solid fill rather than .ultraThinMaterial: a per-annotation GPU blur
                // layer ×N is memory we can't spare in the extension.
                .background(Tokens.Palette.surface)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Tokens.Palette.surfaceSecondary, lineWidth: 0.5))

            Image(systemName: "fork.knife")
                .font(.system(size: isSelected ? 16 : 14))
                .foregroundStyle(.white)
                .padding(isSelected ? 9 : 8)
                .background(isSelected ? Tokens.Palette.brand : role.fill)
                .clipShape(Circle())
                .shadow(radius: 2)
        }
        // Tapping a pin highlights its row in the list below (which scrolls to it).
        .onTapGesture { select(spot, animateMap: false) }
        .accessibilityLabel("\(spot.item?.name ?? "Spot"), \(SpotETADisplay.compactLabel(for: spot, bestWorstETA: spotBestWorstETA))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Spot list

    /// MEETUP SET — the terminal hero shown when the bubble's messageType is
    /// `.agree` and every non-proposer participant has agreed. Agreement is
    /// terminal for negotiation, but the user still needs to leave the meetup.
    private func meetupSetView(state: TweenState) -> some View {
        // Map gets its own region above the panel (device feedback).
        mapSection
            .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Tokens.Spacing.s4) {
                Capsule()
                    .fill(Tokens.Palette.textTertiary.opacity(0.35))
                    .frame(width: 42, height: 5)
                    .accessibilityHidden(true)

                HStack(alignment: .center, spacing: Tokens.Spacing.s3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(Tokens.Typography.title)
                        .foregroundStyle(Tokens.Palette.success)
                        .symbolRenderingMode(.hierarchical)

                    VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                        Text("It's a plan")
                            .font(Tokens.Typography.headline)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                        Text(state.text)
                            .font(Tokens.Typography.title.weight(.bold))
                            .foregroundStyle(Tokens.Palette.textPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)
                    }

                    Spacer(minLength: 0)
                }

                VStack(spacing: Tokens.Spacing.s2) {
                    directionRow(
                        title: "Apple Maps",
                        subtitle: "Open driving directions",
                        systemImage: "map",
                        foreground: .white,
                        background: Tokens.Palette.brand
                    ) {
                        sendTick += 1
                        onOpenAppleMaps(state)
                    }

                    directionRow(
                        title: "Google Maps",
                        subtitle: "Open in Google Maps",
                        systemImage: "globe",
                        foreground: Tokens.Palette.brand,
                        background: Tokens.Palette.brandLight
                    ) {
                        sendTick += 1
                        onOpenGoogleMaps(state)
                    }
                }

                HStack(spacing: Tokens.Spacing.s2) {
                    if isUserIn {
                        Button {
                            sendTick += 1
                            onImOut()
                        } label: {
                            Label("I'm out", systemImage: "location.slash")
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.tweenPrimary(.destructive))
                        .disabled(isSending)
                        .accessibilityHint("Stops sharing you as active for this meetup")
                    } else {
                        Button(action: onImIn) {
                            Label("I'm in", systemImage: "location.fill")
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.tweenPrimary())
                        .disabled(isSending)
                        .accessibilityHint("Shares where you are for this meetup")
                    }

                    Button(action: onOpenFullApp) {
                        Label("Search", systemImage: "magnifyingglass")
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.tweenPrimary(.subtle))
                    .accessibilityHint("Opens the full Tween app to search for places")
                }
            }
            .padding(Tokens.Spacing.s4)
            .background(.regularMaterial, in: UnevenRoundedRectangle(
                topLeadingRadius: Tokens.Radius.sheet,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: Tokens.Radius.sheet,
                style: .continuous
            ))
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(
                    topLeadingRadius: Tokens.Radius.sheet,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: Tokens.Radius.sheet,
                    style: .continuous
                )
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            }
            .tweenElevation(.sheet)
            .sensoryFeedback(.success, trigger: isMeetupSet)
        }
        .background(Color(.systemBackground))
    }

    private func directionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        foreground: Color,
        background: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.s3) {
                Image(systemName: systemImage)
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(foreground)
                    .frame(width: 40, height: 40)
                    .background(foreground.opacity(0.16), in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Tokens.Typography.headline)
                        .foregroundStyle(foreground)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(foreground.opacity(0.78))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(foreground.opacity(0.72))
            }
            .padding(Tokens.Spacing.s3)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(background, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var emptySpotListIcon: String {
        if isWaitingForCoordinates { return "location.circle" }
        if !hasEnoughPeopleForSpots { return "person.2" }
        return isRanking ? "mappin.and.ellipse" : "magnifyingglass"
    }

    private var emptySpotListTitle: String {
        if isWaitingForCoordinates { return "Getting locations" }
        if !hasEnoughPeopleForSpots { return "Waiting for someone else" }
        return isRanking ? "Finding fair spots..." : "No fair spots found"
    }

    private var emptySpotListSubtitle: String {
        if isWaitingForCoordinates {
            return "Both people are in, but Tween needs both shared locations before ranking."
        }
        if !hasEnoughPeopleForSpots {
            return "Fair spots appear once at least two people are in."
        }
        return isRanking
            ? "Hang tight while Tween ranks nearby places."
            : "Try Browse spots to pick a place manually."
    }

    /// Single point of truth for selection. Always updates `selectedSpotID`
    /// (which scrolls the list and re-styles the pin); optionally flies the map
    /// camera to the spot when the selection came from a list tap.
    private func select(_ spot: RankedSpot, animateMap: Bool) {
        selectedSpotID = spot.id
        guard animateMap, let coordinate = spot.item?.placemark.coordinate else { return }
        withAnimation(Tokens.Motion.spring) {
            mapPosition = .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
        }
    }

    // MARK: CTA

    private var selectedSpot: RankedSpot? {
        guard let id = selectedSpotID else { return nil }
        return rankedSpots.first { $0.id == id }
    }

    @ViewBuilder
    private var primaryCTA: some View {
        Group {
            if isMeetupSet {
                // Terminal state actions live inside meetupSetView.
                EmptyView()
            } else if let received, received.messageType == .agree {
                // Group / partial-agree case: bubble carries an agree but not
                // everyone currently in has agreed yet. People who still need
                // to agree get the same Agree / Change controls as a proposal;
                // people who already agreed get a wait state without blocking
                // the rest of the spot flow.
                let myName = UserProfile.displayName ?? UserName.fallback
                let needsMyAgreement = !received.isProposer(participantID: localParticipantID, name: myName)
                    && !received.hasAgreed(participantID: localParticipantID, name: myName)
                if needsMyAgreement {
                    VStack(spacing: Tokens.Spacing.s2) {
                        agreeChangeRow(for: received)
                        draftAlternateButton
                    }
                } else {
                    let missing = received.missingAgreementNames(excluding: localParticipantID, name: myName)
                    HStack(spacing: Tokens.Spacing.s2) {
                        Label(missing.isEmpty
                                ? "Waiting for your friend"
                                : "Waiting for \(missing.joined(separator: ", "))",
                              systemImage: "hourglass")
                            .lineLimit(1)
                            .font(Tokens.Typography.subheadline.weight(.semibold))
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .padding(.horizontal, Tokens.Spacing.s3)
                            .frame(minHeight: Tokens.Layout.minTapTarget)
                            .background(Tokens.Palette.surfaceSecondary, in: Capsule())

                        Button {
                            sendTick += 1
                            if let spot = selectedSpot {
                                onSelectSpot(spot)
                            } else if let first = rankedSpots.first {
                                select(first, animateMap: true)
                            }
                        } label: {
                            Label(selectedSpot == nil ? "Find fair spots" : "Send change",
                                  systemImage: selectedSpot == nil ? "mappin.and.ellipse" : "paperplane.fill")
                                .lineLimit(1)
                        }
                        .buttonStyle(.tweenPrimary())
                        .disabled(rankedSpots.isEmpty || isSending)
                        .accessibilityHint(selectedSpot == nil ? "Shows fair options for the people who are in" : "Sends the selected spot")
                    }
                }
            } else if let received, received.kind == .place {
                if received.isFullyAgreed {
                    directionButtons(for: received)
                } else {
                    VStack(spacing: Tokens.Spacing.s2) {
                        agreeChangeRow(for: received)
                        draftAlternateButton
                    }
                }
            } else if let draft {
                let didSend = recentlySentSpotName == draft.spotName
                Button {
                    guard !didSend else { return }
                    sendTick += 1
                    onSendDraft()
                } label: {
                    Label(didSend ? "Sent \(draft.spotName)" : "Send \(draft.spotName)",
                          systemImage: didSend ? "checkmark.circle.fill" : "paperplane.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.tweenPrimary())
                .disabled(isSending || didSend)
                .accessibilityHint("Drops \(draft.spotName) into your conversation")
            } else if canSendSpotFromCurrentPeople {
                if let spot = selectedSpot {
                    let spotName = spot.item?.name ?? "Spot"
                    let didSend = recentlySentSpotName == spotName
                    Button {
                        guard !didSend else { return }
                        sendTick += 1
                        onSelectSpot(spot)
                    } label: {
                        Label(didSend ? "Sent \(spotName)" : "Send \(spotName)",
                              systemImage: didSend ? "checkmark.circle.fill" : "paperplane.fill")
                            .lineLimit(1)
                    }
                    .buttonStyle(.tweenPrimary())
                    .disabled(isSending || didSend)
                    .accessibilityHint("Drops this spot into your conversation")
                } else {
                    if isRanking {
                        Button {} label: {
                            Label("Finding fair spots...", systemImage: "mappin.and.ellipse")
                                .lineLimit(1)
                        }
                        .buttonStyle(.tweenPrimary())
                        .disabled(true)
                        .opacity(0.5)
                        .accessibilityHint("Tween is ranking fair places for everyone who is in")
                    } else if rankedSpots.isEmpty {
                        EmptyView()
                    } else {
                        Button {} label: {
                            Label("Pick a spot to send", systemImage: "mappin.and.ellipse")
                                .lineLimit(1)
                        }
                        .buttonStyle(.tweenPrimary())
                        .disabled(true)
                        .opacity(0.5)
                        .accessibilityHint("Tap a spot on the map or list to choose where to meet")
                    }
                }
            } else if isUserIn {
                // The waiting / getting-locations status is already the panel's
                // empty-state card — a duplicate CTA label just repeated
                // "Waiting for someone else" a fourth time (device feedback).
                EmptyView()
            } else if !isUserIn {
                Button(action: onImIn) {
                    if isSending {
                        HStack(spacing: Tokens.Spacing.s2) {
                            ProgressView()
                            Text(statusMessage ?? "Sharing...")
                        }
                    } else {
                        Label("I'm in", systemImage: "location.fill")
                    }
                }
                .buttonStyle(.tweenPrimary())
                .disabled(isSending)
                .accessibilityHint("Shares where you are with your friend")
            }
        }
        .sensoryFeedback(.impact, trigger: sendTick)
    }

    private func agreeChangeRow(for received: TweenState) -> some View {
        HStack(spacing: Tokens.Spacing.s2) {
            Button {
                sendTick += 1
                onAgreePlace(received)
            } label: {
                Label("Agree", systemImage: "checkmark.circle.fill")
                    .lineLimit(1)
            }
            .buttonStyle(.tweenPrimary())
            // Every other send CTA disables mid-flight; without this the user
            // could double-fire agreements while the first was still sending.
            .disabled(isSending)
            .accessibilityHint("Sends that you agree to meet at \(received.text)")

            Button {
                sendTick += 1
                if let spot = selectedSpot {
                    onSelectSpot(spot)
                } else if let first = rankedSpots.first {
                    select(first, animateMap: true)
                }
            } label: {
                Label(selectedSpot == nil ? "Change" : "Send change", systemImage: "arrow.triangle.2.circlepath")
                    .lineLimit(1)
            }
            .buttonStyle(.tweenPrimary(.subtle))
            .disabled(rankedSpots.isEmpty || isSending)
            .accessibilityHint(selectedSpot == nil ? "Shows fair alternatives to \(received.text)" : "Sends the selected alternative")
        }
    }

    @ViewBuilder
    private var draftAlternateButton: some View {
        if let draft {
            let didSend = recentlySentSpotName == draft.spotName
            Button {
                guard !didSend else { return }
                sendTick += 1
                onSendDraft()
            } label: {
                Label(didSend ? "Sent \(draft.spotName)" : "Send \(draft.spotName) instead",
                      systemImage: didSend ? "checkmark.circle.fill" : "paperplane.fill")
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.tweenPrimary(.subtle))
            .disabled(isSending || didSend)
            .accessibilityHint("Sends your preloaded spot instead of the received proposal")
        }
    }

    @ViewBuilder
    private var bottomAction: some View {
        if let received, received.kind == .place, received.isFullyAgreed {
            openFullAppButton
        } else if isUserIn {
            HStack(spacing: Tokens.Spacing.s2) {
                openFullAppButton
                Button(action: onImOut) {
                    Label("I'm out", systemImage: "location.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.tweenPrimary(.destructive))
                .accessibilityHint("Stops sharing you as active for this meetup")
            }
        } else {
            openFullAppButton
        }
    }

    private func directionButtons(for state: TweenState) -> some View {
        HStack(spacing: Tokens.Spacing.s2) {
            Button {
                sendTick += 1
                onOpenAppleMaps(state)
            } label: {
                Label("Apple Maps", systemImage: "map")
                    .lineLimit(1)
            }
            .buttonStyle(.tweenPrimary())
            .accessibilityHint("Opens driving directions to \(state.text) in Apple Maps")

            Button {
                sendTick += 1
                onOpenGoogleMaps(state)
            } label: {
                Label("Google Maps", systemImage: "globe")
                    .lineLimit(1)
            }
            .buttonStyle(.tweenPrimary(.subtle))
            .accessibilityHint("Opens driving directions to \(state.text) in Google Maps")
        }
    }

    private var openFullAppButton: some View {
        Button(action: onOpenFullApp) {
            Label("Browse spots", systemImage: "arrow.up.forward.app")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.tweenPrimary(.subtle))
        .accessibilityHint("Opens the full Tween app to search for places")
    }
}

#Preview("Compact") {
    CompactView(
        received: TweenState(text: "Blue Bottle Coffee", latitude: 37.7765, longitude: -122.4255),
        isUserIn: false,
        onImIn: {},
        onExpand: {}
    )
    .frame(height: 120)
}

#Preview("Expanded") {
    ExpandedView(
        received: TweenState(text: "Dolores Park", latitude: 37.7596, longitude: -122.4269),
        selfCoord: CLLocationCoordinate2D(latitude: 37.7849, longitude: -122.4094),
        rankedSpots: [
            RankedSpot(item: nil, etaFromA: 540, etaFromB: 600, confidence: 1.0),
            RankedSpot(item: nil, etaFromA: 420, etaFromB: 780, confidence: 0.5)
        ],
        isUserIn: true,
        onImIn: {},
        onSelectSpot: { _ in }
    )
}
