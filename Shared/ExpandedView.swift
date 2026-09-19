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
    /// The local user's ride flag, resolved ONCE by the host controller. Read
    /// in `staticMarkers`, which is re-evaluated on every render — decoding the
    /// full roster there did a JSON parse per frame (lag audit 2026-08-08).
    var localNeedsRide: Bool = false
    /// The live roster, straight from the controller. The board is scored by
    /// participant ID, and `otherParticipants` falls back to a SYNTHETIC
    /// `Participant(id: "peer")` whenever `received` is nil — which is the
    /// state right after you add your pick (`sendBubble` clears it). Scoring a
    /// vote against a made-up id silently produced "1 of 2 voted" forever and
    /// meant unanimity could never fire. Empty falls back to the old
    /// derivation, so previews and the harness are unaffected.
    var rosterParticipants: [Participant] = []
    /// Spot name the extension just sent with `MSConversation.send`, used to
    /// keep the CTA from looking tappable while Messages has already queued it.
    var recentlySentSpotName: String? = nil
    /// The vote board for this chat — every place on the table and who voted
    /// for what. Conversation state owned by the controller, NOT derived from
    /// `received`: which bubble you happen to have tapped must not change what
    /// the group has picked. See `MeetupPoll`.
    var poll: MeetupPoll = .empty
    /// Who has said "leaving now", newest first (`EnRouteLog`).
    var enRouteMarks: [EnRouteLog.Mark] = []
    /// Whether the spot search is hiding places that are closed right now.
    var openNowOnly: Bool = true
    var onImIn: () -> Void
    var onImOut: () -> Void = {}
    /// Puts the spot on the board under your name (and votes for it).
    var onSelectSpot: (RankedSpot) -> Void
    /// Casts (or changes) your vote for a place already on the board.
    var onVote: (PollOption) -> Void = { _ in }
    /// Ends the vote on one option — the plurality / tie-break escape hatch.
    var onLockIn: (PollOption) -> Void = { _ in }
    /// "I'm heading over" — sends your live ETA to the settled place.
    var onLeavingNow: () -> Void = {}
    var onToggleOpenNow: () -> Void = {}
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
    /// "Hassan invited you — tell them you're on Tween."
    var referralReply: ReferralReplyPrompt? = nil

    @State var selectedSpotID: RankedSpot.ID?
    /// Bumped on every send so the CTA can fire an impact haptic.
    @State var sendTick = 0
    /// While a vote is open the panel shows the BOARD, not the search results
    /// — the places people already picked are the thing to act on. This
    /// reveals the ranked list underneath so you can add one of your own.
    @State var isPickingAlternative = false

    // Accessibility (Phase C): the floating panel + status pill are translucent
    // material; fall back to a solid surface under Reduce Transparency, and drop
    // the slide-in under Reduce Motion.
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    // Spot cards grow with the user's text size instead of clipping.
    /// Retained for the memberwise initializer's stability; the spot list is
    /// row-based now and sizes itself (see ExpandedView+SpotCards).
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

    /// Everyone the board counts — the roster the vote is scored against.
    /// Real IDs only: see `rosterParticipants` for why the `received`-derived
    /// fallback can't be trusted here.
    var pollParticipants: [Participant] {
        if !rosterParticipants.isEmpty { return rosterParticipants }
        var people = otherParticipants
        if isUserIn || selfCoord != nil {
            people.append(Participant(id: localParticipantID ?? myName, name: myName,
                                      coordinate: selfCoord ?? MapGeometry.defaultCenter))
        }
        return people
    }

    /// The board this view actually renders.
    ///
    /// The controller's merged copy is authoritative, but the SELECTED
    /// bubble's own board is folded in on top: tapping a bubble is how you
    /// learn about a pick this device hasn't seen yet, and a pre-poll
    /// `.propose`/`.agree` only becomes an option at all through
    /// `absorbedPoll`. Doing it here means the view is correct whether or not
    /// the caller pre-merged — which is also what keeps the DEBUG harness and
    /// previews honest.
    var board: MeetupPoll {
        guard let received, received.kind == .place else { return poll }
        return MeetupPoll.merged(local: poll, incoming: received.absorbedPoll)
    }

    /// The place the group settled on, if it has: an explicit lock-in, a
    /// unanimous vote, or a decided bubble from a pre-poll thread.
    var settledOption: PollOption? {
        if let option = board.settledOption(participants: pollParticipants) { return option }
        guard let received, received.isDecided, received.kind == .place else { return nil }
        return PollOption(name: received.text,
                          latitude: received.latitude,
                          longitude: received.longitude,
                          proposerID: received.senderID ?? received.senderName ?? "")
    }

    /// Terminal state — the group has a place. Once true, the body swaps from
    /// the vote board to the dedicated MEETUP SET hero. No more negotiation.
    var isMeetupSet: Bool { settledOption != nil }

    /// The state the terminal hero renders from. Prefers the real decided
    /// bubble (it carries the roster and the sender), and synthesises one from
    /// the board when this device worked the decision out locally — the
    /// unanimous case, where nobody had to tap "confirm".
    var meetupSetState: TweenState? {
        guard let option = settledOption else { return nil }
        if let received, received.isDecided, received.kind == .place,
           abs(received.latitude - option.latitude) < 1e-4,
           abs(received.longitude - option.longitude) < 1e-4 {
            return received
        }
        return TweenState(text: option.name,
                          latitude: option.latitude,
                          longitude: option.longitude,
                          senderName: received?.senderName,
                          senderID: option.proposerID,
                          kind: .place,
                          messageType: .decided,
                          participants: received?.participants ?? pollParticipants,
                          poll: board)
    }

    /// True while there is an open vote to show: at least one place on the
    /// board and no winner yet.
    var hasOpenVote: Bool {
        !isMeetupSet && !board.options.isEmpty
    }

    /// The board, with each option's proposer resolved to a display name.
    func proposerName(for option: PollOption) -> String {
        if option.proposerID == (localParticipantID ?? myName) || option.proposerID == myName {
            return "You"
        }
        if let match = otherParticipants.first(where: { $0.id == option.proposerID }) {
            return match.name
        }
        return UserName.peerDisplayName(received?.senderName ?? "")
    }

    /// Which option this user voted for, if any.
    var myVote: String? {
        board.vote(by: localParticipantID ?? myName) ?? board.vote(by: myName)
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
            if let settled = meetupSetState {
                meetupSetView(state: settled)
            } else if isInvitePrompt, let received {
                invitePromptView(state: received)
            } else {
                browseLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The pill belongs to ALL THREE states, not just browse. It used to
        // hang off `browseLayout` alone, so the two hero states — an invite
        // bubble and an agreed meetup, the first thing most recipients ever
        // see — had no way to report anything. Tap "I'm in" with location
        // denied, or "Open in Maps" offline, and you got a brief spinner and
        // then silence (audit 2026-08-04). Every layout here is
        // `mapSection` + a bottom inset, so the top overlay lands identically
        // in each.
        .overlay(alignment: .top) {
            VStack(spacing: Tokens.Spacing.s2) {
                if let referralReply {
                    ReferralReplyBanner(prompt: referralReply, isSending: isSending)
                        .padding(.horizontal, Tokens.Spacing.s4)
                }
                if let pill = statusPill {
                    statusPillView(pill.text, isError: pill.isError)
                }
            }
            .padding(.top, Tokens.Spacing.s3)
        }
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
        // The status pill lives on `body` so all three layouts get it.
        mapSection
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

            if hasOpenVote {
                // A vote is open: the board IS the screen. The ranked list is
                // one tap away behind "Add your pick" rather than competing
                // with the places people already put up.
                voteBoard
                if isPickingAlternative {
                    if shouldShowCategoryRail { categoryRail }
                    if rankedSpots.isEmpty { panelEmptyState } else { spotCardRail }
                    pickCTA
                }
                voteActionRow
            } else {
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

    /// The headline's two lines. `trailingGlyph` adds the directions mark that
    /// makes the title read as tappable.
    func headlineText(trailingGlyph: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: Tokens.Spacing.s1) {
                Text(statusTitle)
                    .font(Tokens.Typography.sectionTitle)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if trailingGlyph {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.accent)
                        .accessibilityHidden(true)
                }
            }
            if received != nil {
                Text(statusEyebrow)
                    .font(Tokens.Typography.subheadline)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Eyebrow + title (place name, "Waiting for someone else", …) with an
    /// optional group-progress chip — the panel's single line of context,
    /// replacing the old 120pt status card.
    var panelHeadline: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.s2) {
            // Apple's place-card order: the NAME leads, big and bold, and the
            // context ("Coffee Shop" there, "Hassan chose" here) sits under it
            // in small grey sentence case. Tween had it inverted — a tiny
            // uppercase eyebrow on top of a 17pt name — which buried the one
            // thing the panel is actually about.
            //
            // On a place, the whole headline is the directions button. Until
            // now `directionButtons` only rendered once EVERYONE had agreed,
            // so the common case — "someone sent me a spot, where is it?" —
            // had no way to reach a maps app at all (product decision
            // 2026-08-02). The glyph is what makes it discoverable; a bare
            // tappable title is an invisible affordance.
            if let received, received.kind == .place {
                Button {
                    sendTick += 1
                    onOpenInMaps(received)
                } label: {
                    headlineText(trailingGlyph: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(statusTitle), \(statusEyebrow)")
                .accessibilityHint("Opens directions to \(received.text) in your maps app")
            } else {
                headlineText(trailingGlyph: false)
            }
            Spacer(minLength: 0)
            if let received, let progress = groupProgress(for: received) {
                Text(progress)
                    .font(Tokens.Typography.caption2Bold)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, Tokens.Spacing.s2)
                    .frame(minHeight: 24)
                    .background(Tokens.Palette.elevated, in: Capsule())
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
                        .background(Tokens.Palette.elevated, in: Capsule())
                }
                let waiting = max(totalSeats - activeParticipantCount, 0)
                if waiting > 0 {
                    Label("Waiting \(waiting)", systemImage: "hourglass")
                        .font(Tokens.Typography.caption2Bold)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, Tokens.Spacing.s2)
                        .frame(minHeight: 26)
                        .background(Tokens.Palette.elevated, in: Capsule())
                }
            }
            .padding(.horizontal, 1)
        }
        .accessibilityLabel("Who's in")
    }

    var categoryRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Spacing.s2) {
                // Open Now leads the rail because it's ON by default and it's
                // the filter most likely to explain a short list ("why are
                // there only three?"). Tappable off — the hours filter rides
                // an undocumented MapKit behaviour, so the user always keeps
                // a way back to the unfiltered results.
                Button(action: onToggleOpenNow) {
                    Label("Open now", systemImage: openNowOnly ? "clock.fill" : "clock")
                        .font(Tokens.Typography.captionBold)
                        .lineLimit(1)
                        .padding(.horizontal, Tokens.Spacing.s3)
                        .frame(minHeight: 36)
                        .background(openNowOnly ? AnyShapeStyle(Tokens.Palette.brand)
                                                : AnyShapeStyle(Tokens.Palette.elevated),
                                    in: Capsule())
                        .foregroundStyle(openNowOnly ? Tokens.Palette.onBrand : Tokens.Palette.textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(isSending)
                .accessibilityHint(openNowOnly
                                   ? "Showing only places open right now. Tap to include closed places."
                                   : "Showing all places. Tap to hide ones that are closed.")
                .accessibilityAddTraits(openNowOnly ? [.isButton, .isSelected] : .isButton)

                Divider().frame(height: 22)

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
                            .background(selected ? AnyShapeStyle(Tokens.Palette.brand) : AnyShapeStyle(Tokens.Palette.elevated),
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
        .sensoryFeedback(.selection, trigger: openNowOnly)
    }

    var shouldShowCategoryRail: Bool {
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
        .background(Tokens.Palette.elevated, in: Capsule())
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
            } else if hasOpenVote {
                // The vote board owns these states — see voteActionRow.
                EmptyView()
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

    /// The send button shown under the revealed ranked list while a vote is
    /// open: it PUTS YOUR PICK ON THE BOARD rather than replacing anyone's.
    @ViewBuilder
    var pickCTA: some View {
        if let spot = selectedSpot {
            let spotName = spot.item?.name ?? "Spot"
            let didSend = recentlySentSpotName == spotName
            Button {
                guard !didSend else { return }
                sendTick += 1
                onSelectSpot(spot)
                isPickingAlternative = false
            } label: {
                Label(didSend ? "Added \(spotName)" : "Add \(spotName) to the vote",
                      systemImage: didSend ? "checkmark.circle.fill" : "plus.circle.fill")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(.tweenPrimary(.subtle))
            .disabled(isSending || didSend)
            .accessibilityHint("Puts \(spotName) on the board for everyone to vote on")
        } else if !rankedSpots.isEmpty {
            Button {} label: {
                Label("Pick a spot to add", systemImage: "mappin.and.ellipse")
                    .lineLimit(1)
            }
            .buttonStyle(.tweenPrimary(.subtle))
            .disabled(true)
            .opacity(0.5)
            .accessibilityHint("Tap a spot on the map or list to add it to the vote")
        }
    }

    // `waitingChangeRow` / `agreeChangeRow` / `draftAlternateButton` lived
    // here. They were the Agree · Others · <draft> · I'm out row of the old
    // one-live-proposal model, and they are gone with it: "Others" selected a
    // replacement for the proposal on screen, so choosing somewhere else
    // DELETED the thing you were disagreeing with. The board (ExpandedView+Poll)
    // shows every pick side by side instead, and `pickCTA` adds to it.

    /// The panel's tertiary row. Deliberately QUIETER than the CTAs above it:
    /// these are escape hatches ("look somewhere else", "count me out"), not
    /// the thing the screen is for. Rendered as compact text actions rather
    /// than two more filled blocks — the proposal screen was stacking four
    /// rows of same-weight buttons, so nothing read as primary (screenshot
    /// audit: "the buttons don't flow").
    @ViewBuilder
    var bottomAction: some View {
        if let received, received.kind == .place, received.isFullyAgreed {
            openFullAppButton
        } else if isUserIn, received?.kind == .place {
            // "I'm out" lives in the action row on a proposal, so all that's
            // left down here is the escape hatch to the full app.
            tertiaryAction(title: "Open Tween", systemImage: "magnifyingglass",
                           tint: Tokens.Palette.accent, action: onOpenFullApp)
                .accessibilityHint("Opens the full Tween app to search for places")
        } else if isUserIn {
            HStack(spacing: 0) {
                tertiaryAction(title: "Open Tween", systemImage: "magnifyingglass",
                               tint: Tokens.Palette.accent, action: onOpenFullApp)
                    .accessibilityHint("Opens the full Tween app to search for places")
                Divider()
                    .frame(height: 18)
                tertiaryAction(title: "I'm out", systemImage: "location.slash",
                               tint: Tokens.Palette.destructive, action: onImOut)
                    .accessibilityHint("Stops sharing you as active for this meetup")
            }
        } else {
            openFullAppButton
        }
    }

    func tertiaryAction(title: String, systemImage: String, tint: Color,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Tokens.Typography.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: Tokens.Layout.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var openFullAppButton: some View {
        Button(action: onOpenFullApp) {
            // magnifyingglass, not arrow.up.forward.app: an external-link
            // glyph told the user "this leaves Messages" when the useful
            // meaning is "search for places" (screenshot review).
            // lineLimit(1) + scale: in a 2-up row "Open Tween" wrapped to
            // two lines, making the row taller than its neighbour and visibly
            // lopsided (screenshot audit).
            Label("Open Tween", systemImage: "magnifyingglass")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
