import SwiftUI
import MapKit
import CoreLocation
import UIKit

/// Apple's native place-detail UI (photos, hours, ratings, call, website,
/// order actions — the full Apple Maps place card) for a map item that
/// carries a real place identifier. Zero server, zero API keys: MapKit
/// renders it all from the item's identifier (iOS 18+).
@available(iOS 18.0, *)
private struct MapItemDetailView: UIViewControllerRepresentable {
    let item: MKMapItem
    /// The concrete size the sheet currently grants this view. Passed as a
    /// PROPERTY (not just a frame) so detent changes trigger
    /// `updateUIViewController` — on device, a medium→large drag resized the
    /// SwiftUI frame but the hosted controller's view kept its old layout,
    /// leaving the content stuck at half height with a dead band below
    /// (device feedback, twice). Forcing the frame + a layout pass here is
    /// what actually makes the UIKit child track the sheet.
    var size: CGSize = .zero
    /// Called when the user taps the detail view's own close control — the
    /// sheet's single close affordance.
    var onFinish: () -> Void = {}

    func makeUIViewController(context: Context) -> MKMapItemDetailViewController {
        // displaysMap false — the full-screen map is already behind the
        // sheet; a second inline map read as clutter.
        let vc = MKMapItemDetailViewController(mapItem: item, displaysMap: false)
        vc.delegate = context.coordinator
        // NOTE: do not set autoresizingMask here — it fights the SwiftUI
        // representable container's sizing and froze the content at a fixed
        // height regardless of the sheet size (screenshot-verified).
        return vc
    }

    func updateUIViewController(_ vc: MKMapItemDetailViewController, context: Context) {
        context.coordinator.parent = self
        vc.mapItem = item
        // The `size` property changing (detent drag) is what triggers this
        // update — ask the hosted controller to relayout at its new bounds.
        // Never set the frame directly: SwiftUI owns it, and forcing it
        // desynced the whole layout (blank content, misplaced close button).
        if size != .zero {
            vc.view.setNeedsLayout()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MKMapItemDetailViewControllerDelegate {
        var parent: MapItemDetailView
        init(_ parent: MapItemDetailView) { self.parent = parent }

        func mapItemDetailViewControllerDidFinish(_ detailViewController: MKMapItemDetailViewController) {
            parent.onFinish()
        }
    }
}

/// The detail sheet shown when a user taps a search result OR receives an
/// incoming Tween-link spot from a friend.
///
/// Layout mirrors Apple Maps' place card (device feedback: "ours is just a
/// tiny thing… implement something like this"): a pinned Tween header — spot
/// name, meetup ETAs, and the meetup actions — with Apple's own place-detail
/// UI (photos, hours, ratings, call, website, order) filling the rest of the
/// sheet when the spot carries a real place identifier. Synthesized pins
/// (incoming proposals decoded from a URL) and iOS 17 fall back to the
/// original thumbnail + info + open-in-maps layout.
///
/// Behaviour switches on `incoming`:
/// - `incoming == nil` → "Send to chat" primary CTA.
/// - `incoming != nil` → **Agree** / **Change** pair for a friend's proposal.
struct SpotDetailCard: View {
    let name: String
    let address: String?
    let coordinate: CLLocationCoordinate2D
    /// Present only when the spot was fairness-ranked (both coordinates known).
    let ranked: RankedSpot?
    /// The full map item behind this spot. Search results carry Apple's
    /// place identifier (unlocks the rich native detail view); synthesized
    /// proposal pins don't and use the fallback layout.
    var mapItem: MKMapItem? = nil
    /// When set, this card represents a proposal received via `tween://` link
    /// (i.e. from a friend's "Send to friends" SMS). Switches the CTAs from
    /// "Send to chat" to "Agree" / "Change".
    var incoming: IncomingProposal? = nil
    var onSendToChat: () -> Void = {}
    var onAgree: () -> Void = {}
    var onChange: () -> Void = {}

    /// Metadata for an incoming proposal. Drives the headline + per-message-
    /// type copy variations (a counter reads "suggests instead" rather than
    /// "suggests").
    struct IncomingProposal {
        let senderName: String?
        /// True when the link is a counter-proposal (overrides a previous
        /// agreement); shifts the headline copy.
        let isCounter: Bool
    }

    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    /// Bumped on send so the CTA can fire an impact haptic.
    @State private var sendTick = 0

    /// Rebuild key + bookkeeping for the embedded place detail: the hosted
    /// controller lays out for the size it first sees, so each settled
    /// detent change forces one recreation at the final size.
    @State private var detailRebuild = 0
    @State private var lastBuiltDetent: PresentationDetent?

    /// Sheet size. Starts at half; swipe up for everything. The DEBUG launch
    /// arg opens at .large so screenshots can verify the full-screen layout
    /// (the detail must fill to the bottom edge — device feedback caught it
    /// stuck at half height with a dead band below).
    @State private var detent: PresentationDetent = {
        #if DEBUG
        if CommandLine.arguments.contains("-DEMO_SPOT_SHEET_LARGE") { return .large }
        #endif
        return .medium
    }()

    /// The map item to hand Apple's native detail view — only items with a
    /// real place identifier populate it (search results do; pins
    /// synthesized from bare coordinates don't).
    private var richDetailItem: MKMapItem? {
        guard let mapItem else { return nil }
        if #available(iOS 18.0, *), mapItem.identifier != nil {
            return mapItem
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            tweenHeader
                .padding([.top, .horizontal], Tokens.Spacing.s5)
                .padding(.bottom, Tokens.Spacing.s4)

            Divider()

            if #available(iOS 18.0, *), let item = richDetailItem {
                // Apple's own place card — photos, hours, ratings, call,
                // website, order — scrolls internally below our header.
                // GeometryReader hands the hosted UIKit controller a CONCRETE
                // size on every detent change: with a bare maxHeight frame it
                // kept its medium-detent height at .large, leaving a dead
                // band and mid-screen scrolling (device feedback — "invisible
                // bar in the middle"). ignoresSafeArea lets the content run
                // to the physical bottom edge like Apple Maps' card.
                GeometryReader { geo in
                    MapItemDetailView(item: item, size: geo.size, onFinish: { dismiss() })
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                // The hosted controller pins its scroll layout to the size it
                // FIRST sees and ignores later container growth — a medium→
                // large swipe left content stuck at half height with a dead
                // band (device feedback twice; reproduced in sim via
                // -DEMO_SPOT_SHEET_GROW; autoresizing, setNeedsLayout, and an
                // immediate .id(detent) rebuild all verified insufficient —
                // the immediate rebuild re-pins to a MID-ANIMATION size).
                // Fix: rebuild ONCE after the detent spring settles, so the
                // new controller lays out at the final size. MapKit caches
                // the place data, so the rebuild is imperceptible.
                .id(detailRebuild)
                .task(id: detent) {
                    if lastBuiltDetent == nil { lastBuiltDetent = detent; return }
                    guard detent != lastBuiltDetent else { return }
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    guard !Task.isCancelled else { return }
                    lastBuiltDetent = detent
                    detailRebuild += 1
                }
                .ignoresSafeArea(edges: .bottom)
            } else {
                fallbackDetail
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        #if DEBUG
        // -DEMO_SPOT_SHEET_GROW: auto-switch medium → large after the sheet
        // settles, exercising the exact resize path a user's drag takes (a
        // launch directly at .large never resizes, which is how the stuck-at-
        // half-height bug slipped past the earlier screenshot check).
        .task {
            guard CommandLine.arguments.contains("-DEMO_SPOT_SHEET_GROW") else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            detent = .large
        }
        #endif
    }

    // MARK: - Tween header (pinned: identity + meetup actions)

    private var tweenHeader: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s3) {
            // When Apple's rich detail fills the sheet, IT owns the identity
            // (big title, category, rating) and the close control — repeating
            // the name and a second X here read as a glitch (screenshot
            // verification). Our header slims to just the meetup layer.
            if richDetailItem == nil {
                HStack(alignment: .top, spacing: Tokens.Spacing.s2) {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                        Text(name)
                            .font(Tokens.Typography.title2.weight(.semibold))
                            .lineLimit(2)
                        if let address, !address.isEmpty {
                            Text(address)
                                .font(Tokens.Typography.subheadline)
                                .foregroundStyle(Tokens.Palette.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(Tokens.Typography.title2)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }

            if let incoming { incomingHeadline(incoming) }

            if let ranked {
                ETAChip(etaFromA: ranked.etaFromA, etaFromB: ranked.etaFromB)
            }

            if richDetailItem != nil {
                // Apple-Maps-style tile row, pinned so nobody scrolls to find
                // Call/Website (device feedback): drive time, Call, Website,
                // and Send to chat where Maps puts Order. Incoming proposals
                // keep Agree/Change as the pinned pair with the tiles below.
                if incoming != nil {
                    primaryActions
                    actionTiles(includeSendToChat: false)
                } else {
                    actionTiles(includeSendToChat: true)
                }
            } else {
                primaryActions
            }
        }
    }

    /// The Apple-Maps action row: equal-width tiles, icon over label. Call
    /// and Website appear only when the place actually has them.
    private func actionTiles(includeSendToChat: Bool) -> some View {
        let phoneURL = mapItem?.phoneNumber
            .flatMap { URL(string: "tel:\($0.filter { !$0.isWhitespace })") }
        let webURL = mapItem?.url
        return HStack(spacing: Tokens.Spacing.s2) {
            actionTile(icon: "car.fill", label: driveLabel) {
                if let mapItem { openDirectionsInline(mapItem) } else if let url = appleMapsURL { openURL(url) }
            }
            .accessibilityHint("Opens driving directions to \(name)")
            if let phoneURL {
                actionTile(icon: "phone.fill", label: "Call") { openURL(phoneURL) }
                    .accessibilityHint("Calls \(name)")
            }
            if let webURL {
                actionTile(icon: "safari.fill", label: "Website") { openURL(webURL) }
                    .accessibilityHint("Opens the website for \(name)")
            }
            if includeSendToChat {
                actionTile(icon: "paperplane.fill", label: "Send to chat", primary: true) {
                    sendTick += 1
                    onSendToChat()
                    dismiss()
                }
                .sensoryFeedback(.impact, trigger: sendTick)
                .accessibilityHint("Drops \(name) into your conversation")
            }
        }
    }

    /// Drive-time label for the Directions tile — "12 min" when this spot was
    /// fairness-ranked (my leg), otherwise just "Directions".
    private var driveLabel: String {
        guard let ranked else { return "Directions" }
        return "\(max(Int((ranked.etaFromA / 60).rounded()), 1)) min"
    }

    private func actionTile(icon: String, label: String, primary: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Tokens.Spacing.s1) {
                Image(systemName: icon)
                    .font(Tokens.Typography.headline)
                Text(label)
                    .font(Tokens.Typography.caption2Bold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Tokens.Spacing.s3)
            .background(
                primary ? AnyShapeStyle(Tokens.Palette.brand) : AnyShapeStyle(Tokens.Palette.neutralAction),
                in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            .foregroundStyle(primary ? Tokens.Palette.onBrand : Tokens.Palette.brand)
        }
        .buttonStyle(.plain)
    }

    /// Opens driving directions to the actual map item (keeps the place
    /// identity, unlike a bare coordinate deep link).
    private func openDirectionsInline(_ item: MKMapItem) {
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }

    /// Shown above the actions when this card represents an incoming
    /// proposal from a friend, so the user understands they're being asked
    /// to respond — not browsing a search result they picked themselves.
    private func incomingHeadline(_ proposal: IncomingProposal) -> some View {
        let who = proposal.senderName ?? "Your friend"
        let verb = proposal.isCounter ? "suggests instead" : "suggests"
        return VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
            Text("\(who) \(verb)")
                .font(Tokens.Typography.callout)
                .foregroundStyle(Tokens.Palette.textSecondary)
            Text("Do you want to agree or change it?")
                .font(Tokens.Typography.subheadline)
                .foregroundStyle(Tokens.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Either the original "Send to chat" CTA for self-picked spots, OR an
    /// Agree / Change pair when this card represents an incoming proposal.
    @ViewBuilder
    private var primaryActions: some View {
        if incoming != nil {
            HStack(spacing: Tokens.Spacing.s2) {
                Button {
                    sendTick += 1
                    onAgree()
                    dismiss()
                } label: {
                    Label("Agree", systemImage: "checkmark.circle.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.tweenPrimary())
                .accessibilityHint("Sends back a reply that you agree to meet at \(name)")

                Button {
                    sendTick += 1
                    onChange()
                    dismiss()
                } label: {
                    Label("Change", systemImage: "arrow.triangle.2.circlepath")
                        .lineLimit(1)
                }
                .buttonStyle(.tweenPrimary(.subtle))
                .accessibilityHint("Opens search to pick a different spot")
            }
            .sensoryFeedback(.impact, trigger: sendTick)
        } else {
            HStack(spacing: Tokens.Spacing.s2) {
                Button {
                    sendTick += 1
                    onSendToChat()
                    dismiss()
                } label: {
                    Label("Send to chat", systemImage: "paperplane.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.tweenPrimary())
                .accessibilityHint("Drops \(name) into your conversation")

                Button {
                    if let url = appleMapsURL { openURL(url) }
                } label: {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.tweenPrimary(.subtle))
                .accessibilityHint("Opens driving directions to \(name)")
            }
            .sensoryFeedback(.impact, trigger: sendTick)
        }
    }

    // MARK: - Fallback detail (iOS 17, or no place identifier)

    private var fallbackDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s4) {
                thumbnail
                contactButtons
                secondaryButtons
            }
            .padding(Tokens.Spacing.s5)
        }
    }

    private var thumbnail: some View {
        TweenMapSnapshotView(
            markers: [MapMarker(coordinate: coordinate, role: .fairSpot)],
            cornerRadius: Tokens.Radius.card,
            focusCoordinate: coordinate
        )
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Map showing \(name)")
    }

    /// Call / Website — from the map item's own metadata when present, so
    /// even the fallback isn't just "A to B".
    @ViewBuilder
    private var contactButtons: some View {
        let phoneURL = mapItem?.phoneNumber
            .flatMap { URL(string: "tel:\($0.filter { !$0.isWhitespace })") }
        let webURL = mapItem?.url
        if phoneURL != nil || webURL != nil {
            HStack(spacing: Tokens.Spacing.s3) {
                if let phoneURL {
                    Button {
                        openURL(phoneURL)
                    } label: {
                        Label("Call", systemImage: "phone.fill")
                    }
                    .buttonStyle(.tweenPrimary(.subtle))
                    .accessibilityHint("Calls \(name)")
                }
                if let webURL {
                    Button {
                        openURL(webURL)
                    } label: {
                        Label("Website", systemImage: "safari")
                    }
                    .buttonStyle(.tweenPrimary(.subtle))
                    .accessibilityHint("Opens the website for \(name)")
                }
            }
        }
    }

    private var secondaryButtons: some View {
        HStack(spacing: Tokens.Spacing.s3) {
            Button {
                if let url = appleMapsURL { openURL(url) }
            } label: {
                Label("Apple Maps", systemImage: "map")
            }
            .buttonStyle(.tweenPrimary(.subtle))
            .accessibilityHint("Opens \(name) in Apple Maps")

            Button {
                if let url = googleMapsURL { openURL(url) }
            } label: {
                Label("Google Maps", systemImage: "globe")
            }
            .buttonStyle(.tweenPrimary(.subtle))
            .accessibilityHint("Opens \(name) in Google Maps")
        }
    }

    // MARK: - Deep links

    /// `http://maps.apple.com/?ll=LAT,LON&q=NAME` — opens the native Maps app.
    private var appleMapsURL: URL? {
        MapLinks.appleMapsURL(name: name, coordinate: coordinate)
    }

    /// `comgooglemaps://?q=NAME&center=LAT,LON` — opens Google Maps when installed.
    private var googleMapsURL: URL? {
        MapLinks.googleMapsURL(name: name, coordinate: coordinate)
    }
}

#Preview {
    SpotDetailCard(
        name: "Blue Bottle Coffee",
        address: "66 Mint St, San Francisco",
        coordinate: CLLocationCoordinate2D(latitude: 37.7825, longitude: -122.4099),
        ranked: RankedSpot(item: nil, etaFromA: 540, etaFromB: 600, confidence: 1.0),
        onSendToChat: {}
    )
}
