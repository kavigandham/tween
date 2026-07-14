import SwiftUI
import UIKit
import MapKit
import CoreLocation

// NOTE: ExpandedView renders its map with `TweenMapSnapshotView`
// (MKMapSnapshotter) — never `MKMapView` — per CLAUDE.md HARD CONSTRAINT #1.
// An interactive pan/zoom Map once lived here behind a feature flag that was
// never enabled; it was removed 2026-07-14 (git history preserves it) so the
// extension is snapshotter-only everywhere, the safest footprint under the
// ~120 MB ceiling.
//
/// Full-screen presentation for the Messages extension.
///
/// Shows a snapshot map framing both friends and every ranked spot, above a
/// scrollable list of those spots. Tapping a pin highlights its row and
/// vice-versa; the primary call to action adapts to whether you've shared your
/// location yet and, once you have, sends the spot you pick. An offline banner
/// replaces the live ranking when there's no network.
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
    /// Opens driving directions in the user's PREFERRED maps app (Settings →
    /// Apple/Google) — one button, one callback; the controller resolves the
    /// preference at tap time.
    var onOpenInMaps: (TweenState) -> Void = { _ in }
    var isSending: Bool = false
    var statusMessage: String?
    /// Whether `statusMessage` reports a failure (warning banner) or routine
    /// progress/confirmation copy (neutral banner). One string channel carries
    /// both, so the sender must say which it is.
    var statusIsError: Bool = false

    @State private var selectedSpotID: RankedSpot.ID?
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
            // Snapshotter-only (constraint #1): the cheap static path, no MKMapView.
            TweenMapSnapshotView(
                markers: staticMarkers,
                cornerRadius: 0,
                focusCoordinate: snapshotFocus,
                // The map has its own region above the panel, so only a
                // gentle lift keeps the spot off dead-center (room for the pill).
                focusYOffsetRatio: snapshotFocus != nil ? 0.1 : 0)
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

    /// Markers for the snapshot: people, any proposed place, and ranked spots
    /// using the shared pin role system.
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
        // place anyone meets, and on the small extension map it just adds clutter.
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

                // One button, the user's maps app (Settings → Apple/Google) —
                // the old Apple/Google pair made every user read two options
                // to find theirs.
                directionRow(
                    title: "Open in Maps",
                    subtitle: "Driving directions to \(state.text)",
                    systemImage: "arrow.triangle.turn.up.right.diamond.fill",
                    foreground: .white,
                    background: Tokens.Palette.brand
                ) {
                    sendTick += 1
                    onOpenInMaps(state)
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

    /// Single point of truth for selection. Updates `selectedSpotID`, which
    /// scrolls the list, re-styles the pin, and re-focuses the snapshot (the
    /// snapshot's focusCoordinate follows the selected spot).
    private func select(_ spot: RankedSpot, animateMap: Bool = false) {
        selectedSpotID = spot.id
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
        Button {
            sendTick += 1
            onOpenInMaps(state)
        } label: {
            Label("Open in Maps", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.tweenPrimary())
        .accessibilityHint("Opens driving directions to \(state.text) in your maps app")
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
