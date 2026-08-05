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
    /// Bumped once per SETTLED detent change. The container controller swaps
    /// in a fresh detail controller behind a snapshot cross-fade — the detail
    /// VC pins its scroll layout to the size it first sees, so a rebuild at
    /// the settled size is unavoidable; what's avoidable is SHOWING it. The
    /// old `.id()`-driven SwiftUI teardown rendered as a visible flash on
    /// every medium↔large drag (device feedback: "visible refresh and jump").
    var rebuildToken: Int = 0
    /// Called when the user taps the detail view's own close control — the
    /// sheet's single close affordance.
    var onFinish: () -> Void = {}

    func makeUIViewController(context: Context) -> MapItemDetailHostController {
        let host = MapItemDetailHostController()
        host.detailDelegate = context.coordinator
        host.embedDetail(for: item)
        context.coordinator.lastToken = rebuildToken
        return host
    }

    func updateUIViewController(_ host: MapItemDetailHostController, context: Context) {
        context.coordinator.parent = self
        host.detailDelegate = context.coordinator
        if context.coordinator.lastToken != rebuildToken {
            context.coordinator.lastToken = rebuildToken
            host.rebuildDetail(for: item)
        } else {
            host.updateItem(item)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MKMapItemDetailViewControllerDelegate {
        var parent: MapItemDetailView
        var lastToken = 0
        init(_ parent: MapItemDetailView) { self.parent = parent }

        func mapItemDetailViewControllerDidFinish(_ detailViewController: MKMapItemDetailViewController) {
            parent.onFinish()
        }
    }
}

/// Plain UIKit container between SwiftUI and `MKMapItemDetailViewController`.
/// SwiftUI sizes THIS controller's view; the detail child is pinned to it
/// with constraints (the same pattern the extension's `embed()` uses — an
/// autoresizing mask directly under a representable froze layout entirely,
/// screenshot-verified). Rebuilds happen inside the container so the swap
/// can hide behind a snapshot of the outgoing view instead of a blank frame.
@available(iOS 18.0, *)
final class MapItemDetailHostController: UIViewController {
    weak var detailDelegate: MKMapItemDetailViewControllerDelegate? {
        didSet { detail?.delegate = detailDelegate }
    }
    private var detail: MKMapItemDetailViewController?

    func updateItem(_ item: MKMapItem) {
        guard let detail, detail.mapItem !== item else { return }
        detail.mapItem = item
    }

    func embedDetail(for item: MKMapItem) {
        // displaysMap false — the full-screen map is already behind the
        // sheet; a second inline map read as clutter.
        let vc = MKMapItemDetailViewController(mapItem: item, displaysMap: false)
        vc.delegate = detailDelegate
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            vc.view.topAnchor.constraint(equalTo: view.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        vc.didMove(toParent: self)
        detail = vc
    }

    /// Recreates the detail controller at the container's CURRENT size,
    /// covered by a snapshot of the outgoing view that fades out once the
    /// replacement has laid out — the rebuild itself is never visible.
    func rebuildDetail(for item: MKMapItem) {
        guard let old = detail else {
            embedDetail(for: item)
            return
        }
        let snapshot = old.view.snapshotView(afterScreenUpdates: false)
        old.willMove(toParent: nil)
        old.view.removeFromSuperview()
        old.removeFromParent()
        embedDetail(for: item)
        guard let snapshot else { return }
        snapshot.frame = view.bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(snapshot)
        view.layoutIfNeeded()
        UIView.animate(withDuration: 0.25, delay: 0.05, options: [.curveEaseOut]) {
            snapshot.alpha = 0
        } completion: { _ in
            snapshot.removeFromSuperview()
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
    /// The user's own location (or declared "where I'll be" point). Lets the
    /// card fetch a drive time for spots that arrive WITHOUT a fairness
    /// ranking, so the Directions controls always carry a time — Apple Maps
    /// puts the ETA on the drive button and ours went blank (device feedback).
    var selfCoordinate: CLLocationCoordinate2D? = nil
    /// When set, this card represents a proposal received via `tween://` link
    /// (i.e. from a friend's "Send to friends" SMS). Switches the CTAs from
    /// "Send to chat" to "Agree" / "Change".
    var incoming: IncomingProposal? = nil
    var isCurrentMeetup = false
    var isFavorite = false
    var onToggleFavorite: () -> Void = {}
    var onSendToChat: () -> Void = {}
    var onAgree: () -> Void = {}
    var onChange: () -> Void = {}
    /// Pro: open the planning sheet (time, travel modes, reminder, calendar).
    var onPlan: () -> Void = {}
    /// Changes the LOCAL user's travel mode and re-ranks. Hooked to a
    /// hold-to-change menu on the directions tile: that tile already shows the
    /// mode's icon and the time computed in it, so it is the control nearest to
    /// the thing it affects — the Plan sheet was two taps away and nobody found
    /// it (device report 2026-08-05).
    var onSetTravelMode: (TravelMode) -> Void = { _ in }
    /// Whether a scheduled plan already exists, so the button can say so.
    var planIsSet = false

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

    /// One-shot drive time fetched for spots that arrive unranked (map POI
    /// taps, plain search browsing) — fills the Directions controls' time.
    @State private var fetchedETA: TimeInterval?

    /// Rebuild token + bookkeeping for the embedded place detail: the hosted
    /// controller lays out for the size it first sees, so each settled
    /// detent change asks the UIKit container for one recreation at the
    /// final size, hidden behind a snapshot cross-fade.
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
                // The hosted controller pins its scroll layout to the size it
                // FIRST sees and ignores later container growth — a medium→
                // large swipe left content stuck at half height with a dead
                // band (device feedback twice; reproduced in sim via
                // -DEMO_SPOT_SHEET_GROW; autoresizing, setNeedsLayout, and an
                // immediate rebuild all verified insufficient — the immediate
                // rebuild re-pins to a MID-ANIMATION size). Fix: rebuild ONCE
                // after the detent spring settles so the new controller lays
                // out at the final size — inside the UIKit container, hidden
                // behind a snapshot cross-fade, because the old SwiftUI-side
                // `.id()` teardown flashed visibly on every detent change
                // (device feedback: "visible refresh and jump").
                // ignoresSafeArea lets the content run to the physical bottom
                // edge like Apple Maps' card.
                MapItemDetailView(item: item, rebuildToken: detailRebuild, onFinish: { dismiss() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .task { await fetchETAIfNeeded() }
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
                        Image(systemName: "xmark")
                            .font(Tokens.Typography.headline)
                            .foregroundStyle(Tokens.Palette.textPrimary)
                            .frame(width: Tokens.Layout.minTapTarget,
                                   height: Tokens.Layout.minTapTarget)
                            .background(Tokens.Palette.neutralAction, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }

            if let incoming { incomingHeadline(incoming) }

            if isCurrentMeetup {
                Label("Current meetup", systemImage: "checkmark.circle.fill")
                    .font(Tokens.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Tokens.Palette.success)
            }

            if let ranked {
                // Every person's own drive time (device feedback), plus a
                // plain-language line on how even this one spot is. Single spot,
                // so no best-of-list comparison — the caption stays neutral.
                SpotETAStrip(spot: ranked)
                Text(SpotETADisplay.fairnessCaption(for: ranked))
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
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
                    actionTiles(includeSendToChat: !isCurrentMeetup)
                }
            } else {
                primaryActions
            }

            HStack(spacing: Tokens.Spacing.s2) {
                favoriteButton
                planButton
            }
        }
    }

    /// Pro entry point. Shows for everyone — a locked user taps it and gets the
    /// paywall, which is how they learn the feature exists at all; hiding it
    /// would mean the only mention of scheduling is inside a purchase sheet
    /// they have no reason to open.
    private var planButton: some View {
        Button(action: onPlan) {
            Label(planIsSet ? "Planned" : "Plan",
                  systemImage: planIsSet ? "calendar.badge.checkmark" : "calendar")
                .font(Tokens.Typography.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: Tokens.Layout.minTapTarget)
                .background(Tokens.Palette.brandLight, in: Capsule())
                .foregroundStyle(Tokens.Palette.accent)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Set a time, travel modes, a leave-by reminder, and a calendar event for \(name)")
    }

    private var favoriteButton: some View {
        Button(action: onToggleFavorite) {
            Label(
                isFavorite ? "Saved to Favorites" : "Add to Favorites",
                systemImage: isFavorite ? "star.fill" : "star")
                .font(Tokens.Typography.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: Tokens.Layout.minTapTarget)
                .background(Tokens.Palette.brandLight, in: Capsule())
                .foregroundStyle(Tokens.Palette.accent)
        }
        .buttonStyle(.plain)
        .accessibilityHint(isFavorite
                           ? "Removes \(name) from Favorites"
                           : "Saves \(name) to Favorites")
    }

    /// The Apple-Maps action row: equal-width tiles, icon over label. Call
    /// and Website appear only when the place actually has them.
    private func actionTiles(includeSendToChat: Bool) -> some View {
        let phoneURL = mapItem?.phoneNumber
            .flatMap { URL(string: "tel:\($0.filter { !$0.isWhitespace })") }
        let webURL = mapItem?.url
        return HStack(spacing: Tokens.Spacing.s2) {
            actionTile(icon: myTravelMode.systemImage, label: driveLabel) {
                openInPreferredMaps()
            }
            // Tap still opens directions; HOLD changes how you're getting
            // there. A context menu rather than a cycling tap because the tile
            // has one primary action already, and a menu names all three modes
            // instead of making the user tap through them.
            .contextMenu {
                Picker("How you're getting there", selection: Binding(
                    get: { myTravelMode },
                    set: { onSetTravelMode($0) }
                )) {
                    ForEach(TravelMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
            }
            .accessibilityHint("Opens directions to \(name) in your maps app. Touch and hold to change how you're getting there.")
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

    /// The user's own drive time to this spot: their leg of the fairness
    /// ranking when the spot was ranked, otherwise the one-shot fetched ETA.
    /// MATCHED BY ID. `etas.first` is positional, and the roster starts with
    /// the PEER when the local user has no coordinate yet
    /// (buildRankingParticipants), so index 0 could be someone else's time
    /// shown as yours — the exact thing GroupStatusBarTests pins for the bar.
    private var myDriveETA: TimeInterval? {
        if let ranked {
            if let mine = ranked.etas.first(where: { $0.id == TweenIdentity.stableID }) {
                return mine.eta
            }
            // A legacy roster keys the local user by name, not by stable id.
            if let mine = ranked.etas.first(where: { $0.name == myDisplayName }) {
                return mine.eta
            }
        }
        return fetchedETA
    }

    /// Label for every Directions control — the drive time when known (Apple
    /// Maps puts the ETA on the drive button), otherwise "Directions".
    /// `formatETA` keeps hour-long drives reading "1h 5m", not "65 min".
    /// The local user's planned mode. The tile's NUMBER is computed in this
    /// mode, so its icon has to match: a hardcoded `car.fill` sat next to a
    /// walking ETA and told the user they were driving — the display half of
    /// the "an hour away from stuff right next to me" report (2026-08-05).
    /// The action itself is mode-agnostic (MapLinks hands off to the user's
    /// maps app, which picks its own default), so the hint no longer says
    /// "driving" either.
    private var myDisplayName: String {
        UserProfile.displayName ?? UserName.fallback
    }

    private var myTravelMode: TravelMode {
        MeetupPlanStore.current.mode(for: TweenIdentity.stableID)
    }

    private var driveLabel: String {
        guard let myDriveETA else { return "Directions" }
        return formatETA(myDriveETA)
    }

    /// Fetches the user's drive time when the spot arrived without a ranking.
    /// The controls read "Directions" until the time lands; no spinner — the
    /// label swap is the feedback.
    private func fetchETAIfNeeded() async {
        guard myDriveETA == nil, fetchedETA == nil else { return }
        guard let origin = selfCoordinate ?? LocationCache.freshSelfCoordinate() else { return }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = mapItem ?? MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        request.transportType = .automobile
        guard let response = try? await MKDirections(request: request).calculateETA(),
              !Task.isCancelled else { return }
        fetchedETA = response.expectedTravelTime
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
            .foregroundStyle(primary ? Tokens.Palette.onBrand : Tokens.Palette.accent)
        }
        .buttonStyle(.plain)
    }

    /// Opens directions to the actual map item (keeps the place identity,
    /// unlike a bare coordinate deep link) in the user's PLANNED mode.
    ///
    /// This was hardcoded to driving while the tile above it drew a live,
    /// mode-aware icon — so holding the tile, picking Walking, then tapping it
    /// opened driving directions under a walking glyph. A comment here even
    /// claimed the action was "mode-agnostic"; it never was (audit 2026-08-05).
    private func openDirectionsInline(_ item: MKMapItem) {
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: Self.appleDirectionsMode(myTravelMode)
        ])
    }

    static func appleDirectionsMode(_ mode: TravelMode) -> String {
        switch mode {
        case .driving: return MKLaunchOptionsDirectionsModeDriving
        case .transit: return MKLaunchOptionsDirectionsModeTransit
        case .walking: return MKLaunchOptionsDirectionsModeWalking
        }
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
        } else if isCurrentMeetup {
            Button {
                openInPreferredMaps()
            } label: {
                Label(driveLabel, systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.tweenPrimary())
            .accessibilityHint("Opens driving directions to \(name) in your maps app")
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
                    openInPreferredMaps()
                } label: {
                    Label(driveLabel, systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.tweenPrimary(.subtle))
                .accessibilityHint("Opens driving directions to \(name) in your maps app")
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
        // One button, the user's maps app (Settings → Apple/Google) — replaces
        // the old Apple/Google side-by-side pair.
        Button {
            openInPreferredMaps()
        } label: {
            Label(myDriveETA.map { "Open in Maps · \(formatETA($0))" } ?? "Open in Maps",
                  systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.tweenPrimary(.subtle))
        .accessibilityHint("Opens \(name) in your maps app")
    }

    // MARK: - Deep links

    /// THE directions dispatcher for this card — every Directions control
    /// routes here so a new button can't fork behavior again (post-push audit:
    /// two sibling controls bypassed the maps preference, and the Apple branch
    /// opened a search PIN while Google opened DIRECTIONS). Apple keeps place
    /// identity via the map item when one exists; both branches open driving
    /// directions.
    private func openInPreferredMaps() {
        switch MapsPreference.current {
        case .apple:
            if let mapItem {
                openDirectionsInline(mapItem)
            } else {
                let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
                item.name = name
                openDirectionsInline(item)
            }
        case .google:
            openGoogleMaps()
        }
    }

    /// App scheme first; when Google Maps isn't installed the scheme is
    /// unhandled, so fall back to the universal `/maps/dir/` link (opens the
    /// web version) instead of silently doing nothing.
    private func openGoogleMaps() {
        guard let appURL = MapLinks.googleMapsURL(
            name: name, coordinate: coordinate, mode: myTravelMode) else { return }
        UIApplication.shared.open(appURL) { opened in
            guard !opened,
                  let webURL = MapLinks.googleMapsWebURL(name: name, coordinate: coordinate) else { return }
            DispatchQueue.main.async {
                UIApplication.shared.open(webURL)
            }
        }
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
