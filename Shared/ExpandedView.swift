import SwiftUI
import UIKit
import MapKit
import CoreLocation

enum MessagesSearchCategory: String, CaseIterable, Identifiable, Equatable {
    case coffee
    case food
    case gas
    case study

    var id: String { rawValue }

    var title: String {
        switch self {
        case .coffee: return "Coffee"
        case .food: return "Food"
        case .gas: return "Gas"
        case .study: return "Study"
        }
    }

    var icon: String {
        switch self {
        case .coffee: return "cup.and.saucer.fill"
        case .food: return "fork.knife"
        case .gas: return "fuelpump.fill"
        case .study: return "book.fill"
        }
    }

    var mapKitQuery: String {
        switch self {
        case .coffee: return "coffee shop"
        case .food: return "restaurant"
        case .gas: return "gas station"
        case .study: return "library"
        }
    }

    var poiCategories: [MKPointOfInterestCategory] {
        switch self {
        case .coffee: return [.cafe, .bakery]
        case .food: return [.restaurant]
        case .gas: return [.gasStation]
        case .study: return [.library, .cafe, .university]
        }
    }
}

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
    var selectedSearchCategory: MessagesSearchCategory = .food
    var onSelectSearchCategory: (MessagesSearchCategory) -> Void = { _ in }
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

    @State var selectedSpotID: RankedSpot.ID?
    /// Bumped on every send so the CTA can fire an impact haptic.
    @State var sendTick = 0

    // Accessibility (Phase C): the floating panel + status pill are translucent
    // material; fall back to a solid surface under Reduce Transparency, and drop
    // the slide-in under Reduce Motion.
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    // Spot cards grow with the user's text size instead of clipping.
    @ScaledMetric(relativeTo: .subheadline) var spotCardWidth: CGFloat = 176
    @ScaledMetric(relativeTo: .subheadline) var spotCardHeight: CGFloat = 176

    /// The panel/pill background: translucent material, or an opaque surface
    /// when the user has asked to reduce transparency.
    var panelSurface: AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(Tokens.Palette.surface) : AnyShapeStyle(.regularMaterial)
    }

    var myName: String {
        UserProfile.displayName ?? UserName.fallback
    }

    /// Every "in" participant other than the local user, drawn from the
    /// received bubble's roster. The 2-person fallback (no participants array
    /// on the bubble, or only legacy info present) still resolves to a single
    /// peer via the existing single-peer cache so prior conversations look
    /// identical.
    var otherParticipants: [Participant] {
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
    var peerCoord: CLLocationCoordinate2D? {
        otherParticipants.first?.coordinate
    }

    var legacyPeerCoord: CLLocationCoordinate2D? {
        if received?.representsParticipantLocation == true {
            return received?.coordinate
        }
        guard LocationCache.isPeerActive else { return nil }
        return LocationCache.loadPeer()?.coordinate
    }

    var receivedPlaceCoord: CLLocationCoordinate2D? {
        received?.kind == .place ? received?.coordinate : nil
    }

    /// True when there's nothing geographic to plot yet — no self, peer, or draft.
    var hasMapContent: Bool {
        selfCoord != nil || peerCoord != nil || receivedPlaceCoord != nil || draft != nil || !rankedSpots.isEmpty
    }

    /// Terminal state — everyone the proposer needs has agreed. Once true,
    /// the body swaps from the spot-list/agree-or-change UI to the dedicated
    /// MEETUP SET hero with map-app choices. No more negotiation.
    var isMeetupSet: Bool {
        guard let received else { return false }
        return received.messageType == .agree && received.isFullyAgreed
    }

    /// Every not-in recipient of an invite gets the join hero — including the
    /// 3rd+ person in a group chat whose invite already carries ≥2 participants.
    /// (Gating on !inviteHasEnoughPeopleForSpots dropped those users into the
    /// spot-list layout, which has no "I'm in" affordance at all.)
    var isInvitePrompt: Bool {
        received?.messageType == .invite && !isUserIn
    }

    var inviteHasEnoughPeopleForSpots: Bool {
        guard let received, received.messageType == .invite else { return false }
        return received.participants.count >= 2
    }

    var activeParticipantCount: Int {
        var count = otherParticipants.count
        if isUserIn || selfCoord != nil {
            count += 1
        }
        if inviteHasEnoughPeopleForSpots, let received {
            count = max(count, received.participants.count)
        }
        return count
    }

    var coordinateParticipantCount: Int {
        var count = otherParticipants.count
        if selfCoord != nil {
            count += 1
        }
        if inviteHasEnoughPeopleForSpots, let received {
            count = max(count, received.participants.count)
        }
        return count
    }

    var hasEnoughPeopleForSpots: Bool {
        coordinateParticipantCount >= 2 || inviteHasEnoughPeopleForSpots
    }

    var isWaitingForCoordinates: Bool {
        activeParticipantCount >= 2 && !hasEnoughPeopleForSpots
    }

    var canSendSpotFromCurrentPeople: Bool {
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
    var browseLayout: some View {
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
    var statusPill: (text: String, isError: Bool)? {
        if !isOnline { return ("You're offline. Reconnect to find fair spots.", true) }
        if let statusMessage, !isSending { return (statusMessage, statusIsError) }
        return nil
    }

    func statusPillView(_ text: String, isError: Bool) -> some View {
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

    var browsePanel: some View {
        VStack(spacing: Tokens.Spacing.s3) {
            Capsule()
                .fill(Tokens.Palette.textTertiary.opacity(0.35))
                .frame(width: 42, height: 5)
                .accessibilityHidden(true)

            panelHeadline

            rosterStrip

            if shouldShowCategoryRail {
                categoryRail
            }

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
    var panelHeadline: some View {
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
    var rosterStrip: some View {
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

    var categoryRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Spacing.s2) {
                ForEach(MessagesSearchCategory.allCases) { category in
                    let selected = category == selectedSearchCategory
                    Button {
                        onSelectSearchCategory(category)
                    } label: {
                        Label(category.title, systemImage: category.icon)
                            .font(Tokens.Typography.captionBold)
                            .lineLimit(1)
                            .padding(.horizontal, Tokens.Spacing.s3)
                            .frame(minHeight: 36)
                            .background(selected ? Tokens.Palette.brand : Tokens.Palette.surface,
                                        in: Capsule())
                            .foregroundStyle(selected ? Tokens.Palette.onBrand : Tokens.Palette.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending)
                    .accessibilityHint("Finds fair \(category.title.lowercased()) spots")
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 38)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(3)
        .sensoryFeedback(.selection, trigger: selectedSearchCategory)
    }

    var shouldShowCategoryRail: Bool {
        guard received?.kind != .place else { return false }
        return isUserIn || hasEnoughPeopleForSpots || isRanking || !rankedSpots.isEmpty
    }

    func rosterDot(name: String, isSelf: Bool) -> some View {
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

    // MARK: CTA

    var selectedSpot: RankedSpot? {
        guard let id = selectedSpotID else { return nil }
        return rankedSpots.first { $0.id == id }
    }

    @ViewBuilder
    var primaryCTA: some View {
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
                                select(first)
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

    func agreeChangeRow(for received: TweenState) -> some View {
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
                    select(first)
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
    var draftAlternateButton: some View {
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
    var bottomAction: some View {
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

    func directionButtons(for state: TweenState) -> some View {
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

    var openFullAppButton: some View {
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
