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

    @State private var image: UIImage?

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
            // Re-render only when the framing inputs actually change.
            .task(id: cacheKey(for: geo.size)) {
                await render(size: geo.size)
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(Tokens.Palette.surfaceSecondary)
            Image(systemName: "map")
                .font(Tokens.Typography.title2)
                .foregroundStyle(Tokens.Palette.textTertiary)
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

    @MainActor
    private func render(size: CGSize) async {
        guard size.width > 1, size.height > 1, !coordinates.isEmpty else { return }

        let options = MKMapSnapshotter.Options()
        options.region = MapGeometry.region(for: coordinates)
        options.size = size
        options.mapType = .standard

        let snapshotter = MKMapSnapshotter(options: options)
        guard let snapshot = try? await snapshotter.start() else { return }
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

    /// A colored dot inside a faint halo with a white rim — a flattened echo of
    /// `TweenPin` that survives rasterization at small sizes.
    private static func drawMarker(_ role: TweenPin.Role, at point: CGPoint, in ctx: CGContext) {
        let color = UIColor(role.fill)
        let d = role.diameter * 0.7

        ctx.setFillColor(color.withAlphaComponent(0.25).cgColor)
        ctx.fillEllipse(in: CGRect(x: point.x - d * 0.8, y: point.y - d * 0.8, width: d * 1.6, height: d * 1.6))

        let dot = CGRect(x: point.x - d / 2, y: point.y - d / 2, width: d, height: d)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: dot)
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(2)
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
    var onImIn: () -> Void
    var onExpand: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Spacing.s3) {
            thumbnail
            VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                Text(title)
                    .font(Tokens.Typography.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Tokens.Spacing.s2)
            imInControl
        }
        .padding(.horizontal, Tokens.Spacing.s4)
        .padding(.vertical, Tokens.Spacing.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole surface expands; the real Button below intercepts its own taps.
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens Tween to find a fair place to meet")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let received {
            TweenMapSnapshotView(markers: markers(for: received), cornerRadius: Tokens.Radius.card)
                .frame(width: 84, height: 84)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.card).fill(Tokens.Palette.surfaceSecondary)
                Image(systemName: "map.fill").foregroundStyle(Tokens.Palette.textTertiary)
            }
            .frame(width: 84, height: 84)
        }
    }

    /// The friend's shared spot, plus our own cached pin when we have one.
    private func markers(for state: TweenState) -> [MapMarker] {
        var result = [MapMarker(coordinate: state.coordinate, role: .friend)]
        if let me = LocationCache.loadSelf()?.coordinate {
            result.append(MapMarker(coordinate: me, role: isUserIn ? .selfActive : .selfDot))
        }
        return result
    }

    private var title: String {
        if let received { return received.text }
        return isUserIn ? "You're in" : "Find a place to meet"
    }

    private var subtitle: String {
        if received != nil {
            return isUserIn ? "Tap to pick a fair spot" : "Your friend shared a spot — tap to join"
        }
        return isUserIn ? "Waiting for your friend…" : "Tap “I'm in” to share where you are"
    }

    @ViewBuilder
    private var imInControl: some View {
        Group {
            if isUserIn {
                Image(systemName: "checkmark.circle.fill")
                    .font(Tokens.Typography.title2)
                    .foregroundStyle(Tokens.Palette.success)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: isUserIn)
                    .accessibilityLabel("You're in")
            } else {
                Button(action: onImIn) {
                    Text("I'm in")
                        .font(Tokens.Typography.subheadline.weight(.semibold))
                        .padding(.horizontal, Tokens.Spacing.s4)
                        .padding(.vertical, Tokens.Spacing.s2)
                        .background(Tokens.Palette.brand, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("I'm in")
                .accessibilityHint("Shares where you are with your friend")
            }
        }
        .sensoryFeedback(.success, trigger: isUserIn)
    }
}

/// Full-screen presentation for the Messages extension.
///
/// Shows a large map snapshot, the spot a friend shared (if any), a horizontal
/// rail of fairness-ranked spots, and a primary call to action that adapts to
/// whether you've shared your location yet. An offline banner replaces the live
/// ranking when there's no network.
struct ExpandedView: View {
    let received: TweenState?
    let selfCoord: CLLocationCoordinate2D?
    let rankedSpots: [RankedSpot]
    let isUserIn: Bool
    /// Additive to the spec's parameter list so the offline banner has a source.
    var isOnline: Bool = true
    /// A spot handed off from the host app, awaiting confirmation before send.
    var draft: OutgoingDraft? = nil
    var onImIn: () -> Void
    var onSelectSpot: (RankedSpot) -> Void
    var onSendDraft: () -> Void = {}

    @State private var selectedSpotID: RankedSpot.ID?
    /// Bumped on every send so the CTA can fire an impact haptic.
    @State private var sendTick = 0

    var body: some View {
        VStack(spacing: 0) {
            if !isOnline { offlineBanner }

            ScrollView {
                VStack(spacing: Tokens.Spacing.s4) {
                    map
                    if let draft { draftPanel(draft) }
                    if let received { receivedPanel(received) }
                    if !rankedSpots.isEmpty { spotRail }
                }
                .padding(Tokens.Spacing.s4)
            }

            primaryCTA
                .padding(Tokens.Spacing.s4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Map

    private var markers: [MapMarker] {
        var result: [MapMarker] = []
        if let selfCoord {
            result.append(MapMarker(coordinate: selfCoord, role: isUserIn ? .selfActive : .selfDot))
        }
        if let received {
            result.append(MapMarker(coordinate: received.coordinate, role: .friend))
        }
        if let selfCoord, let received {
            result.append(MapMarker(coordinate: MapGeometry.midpoint(selfCoord, received.coordinate), role: .midpoint))
        }
        if let draft {
            result.append(MapMarker(coordinate: draft.coordinate, role: .midpoint))
        }
        return result
    }

    @ViewBuilder
    private var map: some View {
        if markers.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.card).fill(Tokens.Palette.surfaceSecondary)
                VStack(spacing: Tokens.Spacing.s2) {
                    Image(systemName: "location.slash").font(Tokens.Typography.title)
                    Text("Share your location to see the map")
                        .font(Tokens.Typography.footnote)
                }
                .foregroundStyle(Tokens.Palette.textSecondary)
            }
            .frame(height: 220)
        } else {
            TweenMapSnapshotView(markers: markers, cornerRadius: Tokens.Radius.card)
                .frame(height: 220)
                .accessibilityLabel("Map of you, your friend, and the fair midpoint")
        }
    }

    // MARK: Received panel

    private func receivedPanel(_ state: TweenState) -> some View {
        HStack(spacing: Tokens.Spacing.s3) {
            TweenPin(role: .friend).scaleEffect(0.7)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                Text("Your friend shared")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                Text(state.text)
                    .font(Tokens.Typography.headline)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Spacing.s4)
        .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your friend shared \(state.text)")
    }

    // MARK: Draft panel

    /// Confirmation card for a spot the host app handed off. The `primaryCTA`
    /// becomes "Send [name]" while this is showing.
    private func draftPanel(_ draft: OutgoingDraft) -> some View {
        HStack(spacing: Tokens.Spacing.s3) {
            TweenPin(role: .midpoint).scaleEffect(0.7)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                Text("Ready to send")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                Text(draft.spotName)
                    .font(Tokens.Typography.headline)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Spacing.s4)
        .background(Tokens.Palette.brand.opacity(0.14), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ready to send \(draft.spotName)")
    }

    // MARK: Spot rail

    private var spotRail: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            Text("Fair spots")
                .font(Tokens.Typography.subheadline.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Tokens.Spacing.s3) {
                    ForEach(rankedSpots) { spot in
                        spotChip(spot)
                    }
                }
                .padding(.vertical, Tokens.Spacing.s1)
            }
        }
    }

    private func spotChip(_ spot: RankedSpot) -> some View {
        let isSelected = (selectedSpotID ?? rankedSpots.first?.id) == spot.id
        let name = spot.item?.name ?? "Spot"
        return Button {
            selectedSpotID = spot.id
        } label: {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
                Text(name)
                    .font(Tokens.Typography.subheadline.weight(.semibold))
                    .lineLimit(1)
                Label("\(minutes(spot.worseETA)) min", systemImage: "car.fill")
                    .font(Tokens.Typography.captionBold.monospacedDigit())
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
            .frame(width: 150, alignment: .leading)
            .padding(Tokens.Spacing.s3)
            .background(
                isSelected ? AnyShapeStyle(Tokens.Palette.brand.opacity(0.16))
                           : AnyShapeStyle(Tokens.Palette.surfaceSecondary),
                in: RoundedRectangle(cornerRadius: Tokens.Radius.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.card)
                    .stroke(isSelected ? Tokens.Palette.brand : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selectedSpotID)
        .accessibilityLabel("\(name), longest drive \(minutes(spot.worseETA)) minutes")
        .accessibilityHint("Selects this spot to send")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: CTA

    private var selectedSpot: RankedSpot? {
        if let id = selectedSpotID, let match = rankedSpots.first(where: { $0.id == id }) {
            return match
        }
        return rankedSpots.first
    }

    @ViewBuilder
    private var primaryCTA: some View {
        Group {
            if let draft {
                Button { sendTick += 1; onSendDraft() } label: {
                    Label("Send \(draft.spotName)", systemImage: "paperplane.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.tweenPrimary())
                .accessibilityHint("Drops \(draft.spotName) into your conversation")
            } else if !isUserIn {
                Button(action: onImIn) {
                    Label("I'm in", systemImage: "location.fill")
                }
                .buttonStyle(.tweenPrimary())
                .accessibilityHint("Shares where you are with your friend")
            } else if let spot = selectedSpot {
                Button { sendTick += 1; onSelectSpot(spot) } label: {
                    Label("Send \(spot.item?.name ?? "Spot")", systemImage: "paperplane.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.tweenPrimary())
                .accessibilityHint("Drops this spot into your conversation")
            } else {
                Text("Finding fair spots…")
                    .font(Tokens.Typography.footnote)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Tokens.Spacing.s2)
            }
        }
        .sensoryFeedback(.impact, trigger: sendTick)
    }

    private var offlineBanner: some View {
        HStack(spacing: Tokens.Spacing.s2) {
            Image(systemName: "wifi.slash")
            Text("You're offline. Reconnect to find fair spots.")
            Spacer(minLength: 0)
        }
        .font(Tokens.Typography.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(Tokens.Spacing.s3)
        .frame(maxWidth: .infinity)
        .background(Tokens.Palette.warning)
        .accessibilityElement(children: .combine)
    }

    private func minutes(_ eta: TimeInterval) -> Int { Int((eta / 60).rounded()) }
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
