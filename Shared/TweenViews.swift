import SwiftUI
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
    /// Default focus when there's nothing to frame.
    static let sanFrancisco = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

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
        fallback: CLLocationCoordinate2D = sanFrancisco,
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
    var cornerRadius: CGFloat = 16

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
            Rectangle().fill(Color(.secondarySystemBackground))
            Image(systemName: "map")
                .font(.title2)
                .foregroundStyle(.tertiary)
        }
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
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            imInControl
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole surface expands; the real Button below intercepts its own taps.
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let received {
            TweenMapSnapshotView(markers: markers(for: received), cornerRadius: 12)
                .frame(width: 84, height: 84)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground))
                Image(systemName: "map.fill").foregroundStyle(.tertiary)
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
        if isUserIn {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
        } else {
            Button(action: onImIn) {
                Text("I'm in")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
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

    var body: some View {
        VStack(spacing: 0) {
            if !isOnline { offlineBanner }

            ScrollView {
                VStack(spacing: 16) {
                    map
                    if let draft { draftPanel(draft) }
                    if let received { receivedPanel(received) }
                    if !rankedSpots.isEmpty { spotRail }
                }
                .padding(16)
            }

            primaryCTA
                .padding(16)
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
                RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground))
                VStack(spacing: 8) {
                    Image(systemName: "location.slash").font(.title)
                    Text("Share your location to see the map")
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)
            }
            .frame(height: 220)
        } else {
            TweenMapSnapshotView(markers: markers, cornerRadius: 18)
                .frame(height: 220)
        }
    }

    // MARK: Received panel

    private func receivedPanel(_ state: TweenState) -> some View {
        HStack(spacing: 12) {
            TweenPin(role: .friend).scaleEffect(0.7)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your friend shared")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(state.text)
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Draft panel

    /// Confirmation card for a spot the host app handed off. The `primaryCTA`
    /// becomes "Send [name]" while this is showing.
    private func draftPanel(_ draft: OutgoingDraft) -> some View {
        HStack(spacing: 12) {
            TweenPin(role: .midpoint).scaleEffect(0.7)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ready to send")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(draft.spotName)
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Spot rail

    private var spotRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fair spots")
                .font(.subheadline.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(rankedSpots) { spot in
                        spotChip(spot)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func spotChip(_ spot: RankedSpot) -> some View {
        let isSelected = (selectedSpotID ?? rankedSpots.first?.id) == spot.id
        return Button {
            selectedSpotID = spot.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(spot.item?.name ?? "Spot")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Label("\(minutes(spot.worseETA)) min", systemImage: "car.fill")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)
            .padding(12)
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.16))
                           : AnyShapeStyle(Color(.secondarySystemBackground)),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
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
        if let draft {
            Button(action: onSendDraft) {
                Label("Send \(draft.spotName)", systemImage: "paperplane.fill")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else if !isUserIn {
            Button(action: onImIn) {
                Label("I'm in", systemImage: "location.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else if let spot = selectedSpot {
            Button { onSelectSpot(spot) } label: {
                Label("Send \(spot.item?.name ?? "Spot")", systemImage: "paperplane.fill")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            Text("Finding fair spots…")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }

    private var offlineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text("You're offline. Reconnect to find fair spots.")
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.orange)
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
