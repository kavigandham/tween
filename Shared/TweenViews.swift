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
        if let name = received?.senderName, !name.isEmpty {
            return "\(name) invited you to meet up"
        }
        if let received { return received.text }
        return isUserIn ? "You're in" : "Find a place to meet"
    }

    private var subtitle: String {
        if received?.senderName != nil {
            return "Tap to find a fair spot"
        }
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

/// Formats a drive-time duration as a compact human string: "<1 min", "8 min",
/// or "1h 5m". Shared by the expanded map's A/B chips and the spot list.
func formatETA(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 1 { return "<1 min" }
    if minutes < 60 { return "\(minutes) min" }
    return "\(minutes / 60)h \(minutes % 60)m"
}

// NOTE: Using SwiftUI Map instead of MKMapSnapshotter in expanded view
// for interactive browsing. SwiftUI Map is lighter than MKMapView.
// If memory issues arise on older devices, revert to snapshotter.
// CompactView and BubbleImageRenderer still use MKMapSnapshotter.
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
    /// Additive to the spec's parameter list so the offline banner has a source.
    var isOnline: Bool = true
    /// A spot handed off from the host app, awaiting confirmation before send.
    var draft: OutgoingDraft? = nil
    var onImIn: () -> Void
    var onSelectSpot: (RankedSpot) -> Void
    var onSendDraft: () -> Void = {}

    @State private var selectedSpotID: RankedSpot.ID?
    /// Drives the interactive map's camera. `.automatic` frames every annotation
    /// (self, peer, midpoint, spots) with padding; selecting a row switches it to
    /// a region centered on that spot. A user pan/zoom hands control back to them.
    @State private var mapPosition: MapCameraPosition = .automatic
    /// Bumped on every send so the CTA can fire an impact haptic.
    @State private var sendTick = 0

    /// The peer's shared coordinate, if we've received one.
    private var peerCoord: CLLocationCoordinate2D? { received?.coordinate }

    /// True when there's nothing geographic to plot yet — no self, peer, or draft.
    private var hasMapContent: Bool {
        selfCoord != nil || peerCoord != nil || draft != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isOnline { offlineBanner }
            inviteBanner

            // Split the space between the interactive map (~60%) and the
            // scrollable spot list (~40%). The map can't live inside a vertical
            // ScrollView — its pan gesture would fight the scroll — so it gets its
            // own fixed slice here instead.
            GeometryReader { geo in
                VStack(spacing: 0) {
                    mapSection
                        .frame(height: geo.size.height * 0.6)
                    spotList
                        .frame(height: geo.size.height * 0.4)
                }
            }

            primaryCTA
                .padding(Tokens.Spacing.s4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Invitation

    /// Shown when this surface opened from an invite that named its sender.
    @ViewBuilder
    private var inviteBanner: some View {
        if let name = received?.senderName, !name.isEmpty {
            VStack(spacing: Tokens.Spacing.s1) {
                Text("You've been invited by")
                    .font(Tokens.Typography.callout)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                Text(name)
                    .font(Tokens.Typography.title)
                    .foregroundStyle(Tokens.Palette.textPrimary)
            }
            .padding(Tokens.Spacing.s4)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .padding(.horizontal, Tokens.Spacing.s4)
            .padding(.top, Tokens.Spacing.s2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You've been invited by \(name)")
        }
    }

    // MARK: Map

    @ViewBuilder
    private var mapSection: some View {
        if hasMapContent {
            interactiveMap
        } else {
            ZStack {
                Rectangle().fill(Tokens.Palette.surfaceSecondary)
                VStack(spacing: Tokens.Spacing.s2) {
                    Image(systemName: "location.slash").font(Tokens.Typography.title)
                    Text("Share your location to see the map")
                        .font(Tokens.Typography.footnote)
                }
                .foregroundStyle(Tokens.Palette.textSecondary)
            }
        }
    }

    private var interactiveMap: some View {
        Map(position: $mapPosition) {
            // Your location pin
            if let selfCoord {
                Annotation("You", coordinate: selfCoord) {
                    TweenPin(role: isUserIn ? .selfActive : .selfDot)
                }
            }

            // Friend's location pin
            if let peerCoord {
                Annotation("Friend", coordinate: peerCoord) {
                    TweenPin(role: .friend)
                }
            }

            // Midpoint pin
            if let selfCoord, let peerCoord {
                Annotation("Midpoint", coordinate: MapGeometry.midpoint(selfCoord, peerCoord)) {
                    TweenPin(role: .midpoint)
                }
            }

            // A spot the host app staged for hand-off
            if let draft {
                Annotation(draft.spotName, coordinate: draft.coordinate) {
                    TweenPin(role: .midpoint)
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
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .accessibilityLabel("Interactive map of you, your friend, the fair midpoint, and ranked spots")
    }

    /// A ranked-spot map pin: an A/B drive-time chip floating above a category
    /// glyph. The selected spot reads in brand color and slightly larger so it
    /// stands out from the red of the others.
    private func spotPin(_ spot: RankedSpot) -> some View {
        let isSelected = selectedSpotID == spot.id
        return VStack(spacing: 2) {
            HStack(spacing: 2) {
                Text("A \(formatETA(spot.etaFromA))")
                Text("·")
                Text("B \(formatETA(spot.etaFromB))")
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())

            Image(systemName: "fork.knife")
                .font(.system(size: isSelected ? 16 : 14))
                .foregroundStyle(.white)
                .padding(isSelected ? 9 : 8)
                .background(isSelected ? Tokens.Palette.brand : Color.red)
                .clipShape(Circle())
                .shadow(radius: 2)
        }
        // Tapping a pin highlights its row in the list below (which scrolls to it).
        .onTapGesture { select(spot, animateMap: false) }
        .accessibilityLabel("\(spot.item?.name ?? "Spot"), A \(formatETA(spot.etaFromA)), B \(formatETA(spot.etaFromB))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Spot list

    private var spotList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Tokens.Spacing.s2) {
                    ForEach(rankedSpots) { spot in
                        spotRow(spot)
                            .id(spot.id)
                    }
                }
                .padding(.horizontal, Tokens.Spacing.s4)
                .padding(.vertical, Tokens.Spacing.s2)
            }
            // Keep the selected spot in view whether it was picked here or on the map.
            .onChange(of: selectedSpotID) { _, newValue in
                guard let newValue else { return }
                withAnimation(Tokens.Motion.snappy) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .sensoryFeedback(.selection, trigger: selectedSpotID)
        }
    }

    private func spotRow(_ spot: RankedSpot) -> some View {
        let isSelected = selectedSpotID == spot.id
        let name = spot.item?.name ?? "Unknown"
        return HStack {
            Image(systemName: "fork.knife")
                .foregroundStyle(Tokens.Palette.brand)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Tokens.Typography.headline)
                    .lineLimit(1)
                Text(spot.item?.placemark.title ?? "")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("A \(formatETA(spot.etaFromA))")
                    .font(Tokens.Typography.captionBold)
                Text("B \(formatETA(spot.etaFromB))")
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
        }
        .padding(Tokens.Spacing.s3)
        .background(isSelected ? Tokens.Palette.brand.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.chip))
        .contentShape(Rectangle())
        // Tapping a row animates the map to this spot and highlights its pin.
        .onTapGesture { select(spot, animateMap: true) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), A \(formatETA(spot.etaFromA)), B \(formatETA(spot.etaFromB))")
        .accessibilityHint("Selects this spot to send")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
                // No spot picked yet: a disabled prompt that adapts while the
                // ranking is still loading.
                Button {} label: {
                    Label(rankedSpots.isEmpty ? "Finding fair spots…" : "Pick a spot to send",
                          systemImage: "mappin.and.ellipse")
                        .lineLimit(1)
                }
                .buttonStyle(.tweenPrimary())
                .disabled(true)
                .opacity(0.5)
                .accessibilityHint("Tap a spot on the map or list to choose where to meet")
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
