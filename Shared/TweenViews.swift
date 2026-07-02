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
        if let focusCoordinate {
            let span = MKCoordinateSpan(latitudeDelta: 0.045, longitudeDelta: 0.045)
            options.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: focusCoordinate.latitude - (span.latitudeDelta * focusYOffsetRatio),
                    longitude: focusCoordinate.longitude),
                span: span)
        } else {
            options.region = MapGeometry.region(for: coordinates)
        }
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
    var isSending: Bool = false
    var statusMessage: String?
    var onImIn: () -> Void
    var onImOut: () -> Void = {}
    var onExpand: () -> Void

    var body: some View {
        VStack(spacing: Tokens.Spacing.s4) {
            if received == nil {
                launcherState
            } else {
                activeMeetupState
            }
        }
        .padding(Tokens.Spacing.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque background so the compact strip never reads as transparent
        // against the iMessage keyboard backdrop. systemBackground tracks
        // light/dark mode automatically.
        .background(Color(.systemBackground))
        // The whole surface expands; the real Button below intercepts its own taps.
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens Tween to find a fair place to meet")
    }

    private var launcherState: some View {
        VStack(spacing: Tokens.Spacing.s4) {
            compactHeader
            starterHero
            starterSteps
            bottomActionRow(
                title: isUserIn ? "Waiting for your friend" : "Start from this chat",
                subtitle: isUserIn ? "You are already in. Open Tween to watch fair spots appear." : "Tap I'm in to share your side of the meetup.",
                control: { imInControl }
            )
        }
    }

    private var activeMeetupState: some View {
        VStack(spacing: Tokens.Spacing.s4) {
            compactHeader
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
                        statusPill
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

            bottomActionRow(
                title: received?.kind == .place ? "Ready when you are" : "Join the meetup",
                subtitle: received?.kind == .place ? "Open the card for maps, agreement, and directions." : "Share where you are so Tween can find fair places.",
                control: { imInControl }
            )
        }
    }

    private var compactHeader: some View {
        HStack(spacing: Tokens.Spacing.s3) {
            ZStack {
                Circle()
                    .fill(Tokens.Palette.brandLight)
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Palette.brand)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("Tween")
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                Text("Meet halfway in Messages")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: Tokens.Spacing.s1) {
                Text("Open")
                    .font(Tokens.Typography.captionBold)
                Image(systemName: "chevron.up")
                    .font(Tokens.Typography.captionBold)
            }
            .foregroundStyle(Tokens.Palette.brand)
            .padding(.horizontal, Tokens.Spacing.s3)
            .frame(minHeight: 34)
            .background(Tokens.Palette.brandLight, in: Capsule())
        }
    }

    private var starterHero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Tokens.Palette.brand.opacity(0.22),
                            Tokens.Palette.pinSelf.opacity(0.12),
                            Tokens.Palette.surfaceSecondary
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing)
                )

            GeometryReader { proxy in
                Path { path in
                    path.move(to: CGPoint(x: proxy.size.width * 0.08, y: proxy.size.height * 0.72))
                    path.addCurve(
                        to: CGPoint(x: proxy.size.width * 0.92, y: proxy.size.height * 0.24),
                        control1: CGPoint(x: proxy.size.width * 0.30, y: proxy.size.height * 0.30),
                        control2: CGPoint(x: proxy.size.width * 0.66, y: proxy.size.height * 0.86)
                    )
                }
                .stroke(Color.white.opacity(0.78), style: StrokeStyle(lineWidth: 7, lineCap: .round))

                Path { path in
                    path.move(to: CGPoint(x: proxy.size.width * 0.14, y: proxy.size.height * 0.25))
                    path.addLine(to: CGPoint(x: proxy.size.width * 0.88, y: proxy.size.height * 0.74))
                }
                .stroke(Tokens.Palette.textTertiary.opacity(0.34), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [9, 8]))

                compactPin(color: TweenPin.Role.selfActive.fill, symbol: "location.fill")
                    .position(x: proxy.size.width * 0.20, y: proxy.size.height * 0.66)
                compactPin(color: TweenPin.Role.friend.fill, symbol: "person.fill")
                    .position(x: proxy.size.width * 0.82, y: proxy.size.height * 0.30)

                ZStack {
                    Circle()
                        .fill(Tokens.Palette.pinFair.opacity(0.24))
                        .frame(width: 70, height: 70)
                    TweenPin(role: .fairSpot)
                }
                .position(x: proxy.size.width * 0.52, y: proxy.size.height * 0.50)
            }
            .padding(Tokens.Spacing.s3)

            VStack {
                HStack {
                    Text("Find the fair spot")
                        .font(Tokens.Typography.captionBold)
                        .foregroundStyle(Tokens.Palette.textPrimary)
                        .padding(.horizontal, Tokens.Spacing.s3)
                        .frame(minHeight: 30)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    Text("You + friend")
                        .font(Tokens.Typography.captionBold)
                        .foregroundStyle(Tokens.Palette.textPrimary)
                        .padding(.horizontal, Tokens.Spacing.s3)
                        .frame(minHeight: 30)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(Tokens.Spacing.s3)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous)
                .strokeBorder(Tokens.Palette.brand.opacity(0.20), lineWidth: 1)
        }
        .tweenElevation(.floating)
        .accessibilityHidden(true)
    }

    private var starterSteps: some View {
        HStack(spacing: Tokens.Spacing.s2) {
            starterStep("1", "I'm in", "location.fill", Tokens.Palette.pinSelf)
            starterStep("2", "Friend joins", "person.fill", Tokens.Palette.pinFriend)
            starterStep("3", "Pick spot", "star.fill", Tokens.Palette.pinFair)
        }
    }

    private func starterStep(_ number: String, _ title: String, _ symbol: String, _ color: Color) -> some View {
        VStack(spacing: Tokens.Spacing.s2) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol)
                    .font(Tokens.Typography.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(color, in: Circle())
                Text(number)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .frame(width: 18, height: 18)
                    .background(Color(uiColor: .systemBackground), in: Circle())
                    .offset(x: 5, y: -5)
            }
            Text(title)
                .font(Tokens.Typography.captionBold)
                .foregroundStyle(Tokens.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.Spacing.s3)
        .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
    }

    private func bottomActionRow<Control: View>(
        title: String,
        subtitle: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: Tokens.Spacing.s3) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                Text(title)
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Tokens.Spacing.s2)
            control()
        }
        .padding(Tokens.Spacing.s3)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let received {
            TweenMapSnapshotView(
                markers: markers(for: received),
                cornerRadius: Tokens.Radius.card,
                focusCoordinate: received.kind == .place ? received.coordinate : nil)
                .frame(width: 112, height: 92)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.card).fill(Tokens.Palette.surfaceSecondary)
                Image(systemName: "map.fill").foregroundStyle(Tokens.Palette.textTertiary)
            }
            .frame(width: 112, height: 92)
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

    private func compactPin(color: Color, symbol: String) -> some View {
        Image(systemName: symbol)
            .font(Tokens.Typography.callout.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(color, in: Circle())
            .overlay {
                Circle().strokeBorder(.white.opacity(0.82), lineWidth: 2)
            }
    }

    /// The received payload plus fresh participant cache when available. In a
    /// group chat the bubble carries everyone who's "in" via
    /// `state.participants`; render a friend pin for each. Self is rendered
    /// separately from the local cache, deduped by name so I don't double-pin
    /// when I'm in the received roster.
    private func markers(for state: TweenState) -> [MapMarker] {
        var result: [MapMarker] = []
        let myName = UserProfile.displayName ?? UserName.fallback

        if state.kind == .place {
            // The place itself.
            result.append(MapMarker(coordinate: state.coordinate, role: .fairSpot))
        }

        // Every "in" participant other than me from the group roster.
        for participant in state.participants where participant.name != myName {
            result.append(MapMarker(coordinate: participant.coordinate, role: .friend))
        }
        // For legacy bubbles (kind=.participant, empty participants[]) the
        // main coord IS the friend's pin.
        if state.kind == .participant && state.participants.isEmpty {
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
            return isUserIn ? "Tap to view this meetup spot" : "Tap “I'm in” to share where you are"
        }
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
                Button(action: onImOut) {
                    Label("I'm out", systemImage: "checkmark.circle.fill")
                        .font(Tokens.Typography.subheadline.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .padding(.horizontal, Tokens.Spacing.s3)
                        .frame(minHeight: Tokens.Layout.minTapTarget)
                        .foregroundStyle(Tokens.Palette.success)
                        .background(Tokens.Palette.success.opacity(0.12), in: Capsule())
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: isUserIn)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("I'm out")
                .accessibilityHint("Stops sharing you as active for this meetup")
            } else if isSending {
                ProgressView()
                    .frame(width: Tokens.Layout.minTapTarget, height: Tokens.Layout.minTapTarget)
                    .accessibilityLabel(statusMessage ?? "Sharing your location")
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

    @State private var selectedSpotID: RankedSpot.ID?
    /// Drives the interactive map's camera. `.automatic` frames every annotation
    /// (self, peer, midpoint, spots) with padding; selecting a row switches it to
    /// a region centered on that spot. A user pan/zoom hands control back to them.
    @State private var mapPosition: MapCameraPosition = .automatic
    /// Bumped on every send so the CTA can fire an impact haptic.
    @State private var sendTick = 0

    /// Every "in" participant other than the local user, drawn from the
    /// received bubble's roster. The 2-person fallback (no participants array
    /// on the bubble, or only legacy info present) still resolves to a single
    /// peer via the existing single-peer cache so prior conversations look
    /// identical.
    private var otherParticipants: [Participant] {
        let myName = UserProfile.displayName ?? UserName.fallback
        if let received, !received.participants.isEmpty {
            return received.participants.filter { $0.name != myName }
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

    private var isInvitePrompt: Bool {
        received?.messageType == .invite && !isUserIn && !inviteHasEnoughPeopleForSpots
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

    private var hasEnoughPeopleForSpots: Bool {
        activeParticipantCount >= 2 || inviteHasEnoughPeopleForSpots
    }

    private var canSendSpotFromCurrentPeople: Bool {
        hasEnoughPeopleForSpots
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isOnline { offlineBanner }
            if let statusMessage, !isSending { statusBanner(statusMessage) }
            if !isInvitePrompt { inviteBanner }

            GeometryReader { geo in
                if isMeetupSet, let received {
                    meetupSetView(state: received)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if isInvitePrompt, let received {
                    invitePromptView(state: received)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    // Split the space between the interactive map (~60%) and the
                    // scrollable spot list (~40%). The map can't live inside a
                    // vertical ScrollView — its pan gesture would fight the scroll.
                    VStack(spacing: 0) {
                        mapSection
                            .frame(height: geo.size.height * 0.6)
                        VStack(spacing: 0) {
                            proposedPlacePanel
                            spotList
                        }
                            .frame(height: geo.size.height * 0.4)
                    }
                }
            }

            if !isMeetupSet && !isInvitePrompt {
                primaryCTA
                    .padding(Tokens.Spacing.s4)
                bottomAction
                    .padding(.horizontal, Tokens.Spacing.s4)
                    .padding(.bottom, Tokens.Spacing.s3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque background for the expanded surface for the same reason
        // CompactView sets one — never read as transparent against the
        // iMessage host.
        .background(Color(.systemBackground))
    }

    // MARK: Invitation

    /// Shown when this surface opened from an invite that named its sender.
    /// Picks up group-chat copy from `state.messageType` and `state.participants`
    /// — the 2-person path collapses to the original behaviour because
    /// participants.count is 0 or 1 in those legacy bubbles.
    @ViewBuilder
    private var inviteBanner: some View {
        if let received, !isMeetupSet, let name = received.senderName, !name.isEmpty {
            let isPlace = received.kind == .place
            let isFullyAgreed = received.isFullyAgreed
            VStack(spacing: Tokens.Spacing.s1) {
                Text(bannerHeadline(state: received, name: name, isFullyAgreed: isFullyAgreed))
                    .font(Tokens.Typography.callout)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                Text(isPlace ? received.text : name)
                    .font(Tokens.Typography.title)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                if isPlace {
                    Text(bannerSubcopy(state: received, isFullyAgreed: isFullyAgreed))
                        .font(Tokens.Typography.subheadline)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
                // Group-aware "X of Y ready" or "X of Y agreed".
                if let progress = groupProgress(for: received) {
                    Text(progress)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
            }
            .padding(Tokens.Spacing.s4)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .padding(.horizontal, Tokens.Spacing.s4)
            .padding(.top, Tokens.Spacing.s2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(bannerAccessibilityLabel(state: received, name: name, isFullyAgreed: isFullyAgreed))
        }
    }

    private func bannerHeadline(state: TweenState, name: String, isFullyAgreed: Bool) -> String {
        switch state.messageType {
        case .invite:
            return "You've been invited by"
        case .leave:
            return "\(name) is out"
        case .propose:
            return "\(name) chose"
        case .agree where isFullyAgreed:
            return "Everyone agreed to meet at"
        case .agree:
            return "\(name) agreed to meet at"
        case .counter:
            return "\(name) suggests instead"
        }
    }

    private func bannerSubcopy(state: TweenState, isFullyAgreed: Bool) -> String {
        switch state.messageType {
        case .agree where isFullyAgreed:
            return "Tap for directions."
        case .agree:
            return "Open Tween to see all pings."
        case .leave:
            return "They are no longer active for this meetup."
        case .counter, .propose:
            return "Do you want to agree or change it?"
        case .invite:
            return ""
        }
    }

    private func groupProgress(for state: TweenState) -> String? {
        let count = state.participants.count
        switch state.messageType {
        case .invite where count >= 2:
            let notInYet = max(totalSeats - count, 0)
            return notInYet > 0 ? "\(count) ready now · \(notInYet) not in yet" : "\(count) ready"
        case .leave:
            return count > 0 ? "\(count) still ready" : "No one is in"
        case .agree where !state.agreedNames.isEmpty && !state.isFullyAgreed:
            let needed = max(count - 1, 1)
            return "\(state.agreedNames.count) of \(needed) agreed"
        default:
            return nil
        }
    }

    private func bannerAccessibilityLabel(state: TweenState, name: String, isFullyAgreed: Bool) -> String {
        if state.kind == .place {
            if isFullyAgreed {
                return "Everyone agreed to meet at \(state.text)"
            }
            return "\(name) \(state.messageType == .agree ? "agreed to meet at" : "chose") \(state.text)"
        }
        return "You've been invited by \(name)"
    }

    private func invitePromptView(state: TweenState) -> some View {
        ZStack(alignment: .bottom) {
            mapSection

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
                    Label("Search in Tween", systemImage: "arrow.up.forward.app")
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

    @ViewBuilder
    private var mapSection: some View {
        if hasMapContent {
            if useStaticMap || usesStaticMapForCurrentState {
                // Memory-pressure fallback: the cheap snapshot path, no MKMapView.
                TweenMapSnapshotView(
                    markers: staticMarkers,
                    cornerRadius: 0,
                    focusCoordinate: receivedPlaceCoord ?? draft?.coordinate,
                    focusYOffsetRatio: (receivedPlaceCoord != nil || draft != nil) ? 0.22 : 0)
            } else {
                interactiveMap
            }
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
            result.append(MapMarker(coordinate: selfCoord, role: isUserIn ? .selfActive : .selfDot))
        }
        for participant in otherParticipants {
            result.append(MapMarker(coordinate: participant.coordinate, role: .friend))
        }
        if allMeetupCoords.count >= 2 {
            result.append(MapMarker(coordinate: MapGeometry.centroid(of: allMeetupCoords), role: .midpoint))
        }
        if let receivedPlaceCoord {
            result.append(MapMarker(coordinate: receivedPlaceCoord, role: .fairSpot))
        }
        if let draft {
            result.append(MapMarker(coordinate: draft.coordinate, role: .fairSpot))
        }
        for (index, spot) in rankedSpots.enumerated() {
            if let coordinate = spot.item?.placemark.coordinate {
                result.append(MapMarker(coordinate: coordinate, role: index == 0 ? .fairSpot : .result))
            }
        }
        return result
    }

    private var interactiveMap: some View {
        Map(position: $mapPosition, bounds: cameraBounds) {
            // Your location pin
            if let selfCoord {
                Annotation("You", coordinate: selfCoord) {
                    TweenPin(role: isUserIn ? .selfActive : .selfDot, animated: false)
                }
            }

            // Every other participant who's "in" — one pin each, labelled
            // with their name (which is what other people see on their map
            // when their device is the local "self").
            ForEach(otherParticipants) { participant in
                Annotation(participant.name, coordinate: participant.coordinate) {
                    TweenPin(role: .friend, animated: false)
                }
            }

            // Centroid pin — the geographic middle of everyone "in".
            // Equivalent to the old midpoint for the 2-person case.
            if allMeetupCoords.count >= 2 {
                Annotation("Midpoint", coordinate: MapGeometry.centroid(of: allMeetupCoords)) {
                    TweenPin(role: .midpoint, animated: false)
                }
            }

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
        if draft != nil { return true }
        guard let received else { return false }
        switch received.messageType {
        case .invite, .propose, .counter, .agree, .leave:
            return true
        }
    }

    /// A ranked-spot map pin: a drive-time chip floating above a category
    /// glyph. For ≤4 participants we show "Alice 8 · Bob 12"; for 5+ we drop
    /// names and just list the minutes to keep the chip readable.
    private func spotPin(_ spot: RankedSpot) -> some View {
        let isSelected = selectedSpotID == spot.id
        let isBestFair = rankedSpots.first?.id == spot.id
        let role: TweenPin.Role = isBestFair ? .fairSpot : .result
        return VStack(spacing: 2) {
            Text(Self.compactETALabel(for: spot))
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
        .accessibilityLabel("\(spot.item?.name ?? "Spot"), \(Self.compactETALabel(for: spot))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// "Alice 8 · Bob 12 · Carol 15" for ≤4 participants; "8 / 12 / 15 / 9 / 11"
    /// for 5+ so the pin chip stays compact. Falls back to the legacy A·B form
    /// when the etas array is empty (only the legacy 2-person init path).
    static func compactETALabel(for spot: RankedSpot) -> String {
        let etas = spot.etas
        if etas.isEmpty {
            return "A \(formatETA(spot.etaFromA)) · B \(formatETA(spot.etaFromB))"
        }
        if etas.count <= 4 {
            return etas.map { "\($0.name) \(formatETA($0.eta))" }.joined(separator: " · ")
        }
        return etas.map { formatETA($0.eta) }.joined(separator: " / ")
    }

    // MARK: Spot list

    @ViewBuilder
    private var proposedPlacePanel: some View {
        // Hidden when the meetup is set — the body swaps to meetupSetView.
        if let received, received.kind == .place, !isMeetupSet {
            HStack(spacing: Tokens.Spacing.s3) {
                TweenPin(role: .fairSpot, animated: false)
                    .scaleEffect(0.82)
                VStack(alignment: .leading, spacing: 2) {
                    Text(received.text)
                        .font(Tokens.Typography.headline)
                        .lineLimit(1)
                    Text(panelSubcopy(for: received))
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tokens.Spacing.s4)
            .padding(.vertical, Tokens.Spacing.s3)
            .background(Tokens.Palette.pinFair.opacity(0.14))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(received.text) — \(panelSubcopy(for: received))")
        }
    }

    /// Subcopy under the spot name in the proposed-place panel. Uses
    /// `messageType` (the canonical source) and pulls the agreer's name from
    /// `agreedNames.last` rather than `senderName`, which is the original
    /// proposer's identity on every bubble in the chain.
    private func panelSubcopy(for received: TweenState) -> String {
        let proposer = received.senderName ?? "Your friend"
        switch received.messageType {
        case .agree:
            // Partial-agree case (group, not everyone agreed yet). Fully-agreed
            // never reaches here because the panel is hidden via isMeetupSet.
            let agreer = received.agreedNames.last ?? "Your friend"
            return "\(agreer) agreed — waiting on the rest"
        case .propose:
            return "\(proposer) picked this spot"
        case .counter:
            return "\(proposer) suggests this instead"
        case .leave:
            return "\(proposer) stepped out"
        case .invite:
            return ""
        }
    }

    /// MEETUP SET — the terminal hero shown when the bubble's messageType is
    /// `.agree` and every non-proposer participant has agreed. Agreement is
    /// terminal for negotiation, but the user still needs to leave the meetup.
    private func meetupSetView(state: TweenState) -> some View {
        ZStack(alignment: .bottom) {
            mapSection

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
                    .buttonStyle(.tweenPrimary(.neutral))
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

    private var spotList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Tokens.Spacing.s2) {
                    if rankedSpots.isEmpty {
                        emptySpotListState
                    } else {
                        ForEach(rankedSpots) { spot in
                            spotRow(spot)
                                .id(spot.id)
                        }
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

    private var emptySpotListState: some View {
        VStack(spacing: Tokens.Spacing.s2) {
            Image(systemName: emptySpotListIcon)
                .font(Tokens.Typography.title2)
                .foregroundStyle(Tokens.Palette.brand)
            Text(emptySpotListTitle)
                .font(Tokens.Typography.subheadline.weight(.semibold))
                .foregroundStyle(Tokens.Palette.textPrimary)
            Text(emptySpotListSubtitle)
                .font(Tokens.Typography.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(Tokens.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(Tokens.Spacing.s4)
        .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .accessibilityElement(children: .combine)
    }

    private var emptySpotListIcon: String {
        if !hasEnoughPeopleForSpots { return "person.2" }
        return isRanking ? "mappin.and.ellipse" : "magnifyingglass"
    }

    private var emptySpotListTitle: String {
        if !hasEnoughPeopleForSpots { return "Waiting for someone else" }
        return isRanking ? "Finding fair spots..." : "No fair spots found"
    }

    private var emptySpotListSubtitle: String {
        if !hasEnoughPeopleForSpots {
            return "Fair spots appear once at least two people are in."
        }
        return isRanking
            ? "Hang tight while Tween ranks nearby places."
            : "Try Search in Tween to pick a spot manually."
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
                if spot.etas.isEmpty {
                    // Legacy 2-person fallback path.
                    Text("A \(formatETA(spot.etaFromA))")
                        .font(Tokens.Typography.captionBold)
                    Text("B \(formatETA(spot.etaFromB))")
                        .font(Tokens.Typography.captionBold)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                } else if spot.etas.count <= 4 {
                    ForEach(spot.etas) { participantETA in
                        HStack(spacing: 4) {
                            Text(participantETA.name)
                                .foregroundStyle(Tokens.Palette.textSecondary)
                            Text(formatETA(participantETA.eta))
                        }
                        .font(Tokens.Typography.captionBold)
                    }
                } else {
                    // 5+ participants: compact minutes-only row.
                    Text(spot.etas.map { formatETA($0.eta) }.joined(separator: " / "))
                        .font(Tokens.Typography.captionBold)
                        .multilineTextAlignment(.trailing)
                    Text("Longest: \(formatETA(spot.worstETA))")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
            }
        }
        .padding(Tokens.Spacing.s3)
        .background(isSelected ? Tokens.Palette.brand.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.chip))
        .contentShape(Rectangle())
        // Tapping a row animates the map to this spot and highlights its pin.
        .onTapGesture { select(spot, animateMap: true) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(Self.compactETALabel(for: spot))")
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
                let needsMyAgreement = received.senderName != myName && !received.agreedNames.contains(myName)
                if needsMyAgreement {
                    VStack(spacing: Tokens.Spacing.s2) {
                        agreeChangeRow(for: received)
                        draftAlternateButton
                    }
                } else {
                    let missing = received.participants
                        .map(\.name)
                        .filter { $0 != received.senderName && !received.agreedNames.contains($0) && $0 != myName }
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
                        .disabled(rankedSpots.isEmpty)
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
                Button { sendTick += 1; onSendDraft() } label: {
                    Label("Send \(draft.spotName)", systemImage: "paperplane.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.tweenPrimary())
                .accessibilityHint("Drops \(draft.spotName) into your conversation")
            } else if canSendSpotFromCurrentPeople {
                if let spot = selectedSpot {
                    Button { sendTick += 1; onSelectSpot(spot) } label: {
                        Label("Send \(spot.item?.name ?? "Spot")", systemImage: "paperplane.fill")
                            .lineLimit(1)
                    }
                    .buttonStyle(.tweenPrimary())
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
                Label("Waiting for someone else", systemImage: "person.2")
                    .lineLimit(1)
                    .font(Tokens.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: Tokens.Layout.minTapTarget)
                    .background(Tokens.Palette.surfaceSecondary, in: Capsule())
                    .accessibilityHint("Fair spots appear once at least two people are in")
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
            .disabled(rankedSpots.isEmpty)
            .accessibilityHint(selectedSpot == nil ? "Shows fair alternatives to \(received.text)" : "Sends the selected alternative")
        }
    }

    @ViewBuilder
    private var draftAlternateButton: some View {
        if let draft {
            Button {
                sendTick += 1
                onSendDraft()
            } label: {
                Label("Send \(draft.spotName) instead", systemImage: "paperplane.fill")
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.tweenPrimary(.neutral))
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
                .buttonStyle(.tweenPrimary(.subtle))
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
            Label("Search in Tween", systemImage: "arrow.up.forward.app")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.tweenPrimary(.subtle))
        .accessibilityHint("Opens the full Tween app to search for places")
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

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: Tokens.Spacing.s2) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(message)
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
