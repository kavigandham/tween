import SwiftUI
import MapKit
import CoreLocation
import MessageUI
import Messages
import UIKit
import Combine
import os

/// The host app's primary surface: a full-screen map with an "I'm in" flow and
/// a draggable bottom sheet. Capturing your location drops a self pin; once a
/// peer coordinate arrives via the shared cache, the camera reframes to fit both
/// participants and their midpoint.
///
/// The bottom sheet's peek exposes place search and category chips; pulling it
/// up reveals the presence controls and the fairness-ranked results.
/// The bottom sheet's surface: on iOS 26 the system's Liquid Glass floating
/// panel (what Apple Maps' pill is made of — see "Adopting Liquid Glass" in
/// the technology overviews); before that, the near-opaque material blur
/// that read correctly pre-glass. Deployment target is iOS 17, so both
/// worlds ship.
private struct TweenSheetSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.presentationBackground(.regularMaterial)
        }
    }
}

/// Card surface for the floating meetup/proposal cards: Liquid Glass on
/// iOS 26, a translucent material blur (NOT the near-black opaque fill that
/// read as an ugly black box) on earlier systems. The tapped-search-result
/// card doesn't use this — it renders directly on the sheet's own glass.
private struct TweenCardSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape).tweenElevation(.floating)
        } else {
            content.background(.regularMaterial, in: shape).tweenElevation(.floating)
        }
    }
}

/// Chrome for the floating map controls: Liquid Glass on iOS 26 (interactive,
/// brand-tinted when selected), the surface fill + hairline + shadow stack on
/// earlier systems. One modifier so every control switches worlds together.
private struct TweenGlassControl<S: InsettableShape>: ViewModifier {
    let shape: S
    var isSelected = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Plain glass, NOT .interactive(): these sit on Button LABELS,
            // and interactive glass installs its own touch handling that
            // swallowed the button taps on device — reset-map and the map
            // style picker went completely dead. The press feedback comes
            // from the Button itself; glass only needs to look right.
            if isSelected {
                content
                    .contentShape(shape)
                    .glassEffect(.regular.tint(Tokens.Palette.brand), in: shape)
            } else {
                content
                    .contentShape(shape)
                    .glassEffect(.regular, in: shape)
            }
        } else {
            content
                .background(
                    isSelected
                        ? AnyShapeStyle(Tokens.Palette.brand)
                        : AnyShapeStyle(Tokens.Palette.surface.opacity(0.92)),
                    in: shape)
                .overlay {
                    shape.strokeBorder(Tokens.Palette.surfaceSecondary.opacity(isSelected ? 0 : 1), lineWidth: 1)
                }
                .tweenElevation(.floating)
        }
    }
}

struct OnboardingView: View {
    /// Default camera focus when there's no cached location and none can be
    /// resolved (e.g. location denied). The geographic center of the
    /// continental US — deliberately generic rather than a misleading city.
    private static let defaultCenter = CLLocationCoordinate2D(latitude: 39.8283, longitude: -98.5795)

    /// How many candidates the fairness engine resolves routes for in the app.
    private static let rankCap = 8

    /// A reply banner shows only while the last inbound bubble is this fresh.
    private static let replyFreshness: TimeInterval = 60 * 60 // 1 hour
    private static var isHostTabHarness: Bool {
        CommandLine.arguments.contains("-HARNESS_HOST_RIDES")
        || CommandLine.arguments.contains("-HARNESS_HOST_FRIENDS")
        || CommandLine.arguments.contains("-HARNESS_HOST_RIDE_MAP")
    }
    private let logger = Logger(subsystem: "com.kavigandham.TweenApp", category: "Host")

    /// Prefilled body for an out-of-band SMS nudge to a friend.
    private static let inviteText =
        "Where should we meet? Open Tween and tap “I'm in” so we can find a fair spot. 📍"

    /// Plain-text body for a spot message. Keep this human-readable: the rich
    /// MSMessage bubble already carries the route payload, and exposing the raw
    /// Maps URL in the typed text makes the send preview feel noisy.
    static func spotBody(prefix: String, name: String, coordinate: CLLocationCoordinate2D) -> String {
        "\(prefix) \(name)."
    }
    private static let suggestedSpot = QuickSpotShortcut(
        title: "Coffee near the midpoint",
        subtitle: "Suggested spot",
        query: "coffee",
        systemImage: "sparkles")
    private static let recentSpotShortcuts: [QuickSpotShortcut] = [
        QuickSpotShortcut(title: "Lunch spots", subtitle: "Food nearby", query: "restaurants", systemImage: "fork.knife"),
        QuickSpotShortcut(title: "Gas stations", subtitle: "Easy stop on the way", query: "gas", systemImage: "fuelpump.fill"),
        QuickSpotShortcut(title: "Study spots", subtitle: "Quiet places to sit", query: "library cafe", systemImage: "book.fill")
    ]

    @Environment(\.scenePhase) private var scenePhase

    @State private var savedCoordinate: CLLocationCoordinate2D?
    /// When the in-memory `savedCoordinate` was last set from an ACTUAL
    /// device fix. A silent launch fix updates `savedCoordinate` (to recenter
    /// the map) but deliberately doesn't write the cache, so this is how a
    /// pending send knows that in-memory coordinate is current. Nil for a
    /// coordinate restored from disk at launch, whose age is unknown — those
    /// fall through to the cache's own freshness check.
    @State private var savedCoordinateAt: Date?
    @State private var peerCoordinate: CLLocationCoordinate2D?
    @State private var agreedMeetup: TweenState?
    /// The in-flight proposal/counter (not yet fully agreed) mirrored from the
    /// conversation-scoped store, so the host app shows the SAME negotiation
    /// the extension does — spot card, agreement progress, Agree & reply.
    @State private var pendingProposal: TweenState?
    /// Every "in" participant beyond the local user and the primary peer —
    /// only populated in group chats (3+ people). Empty for DMs, preserving
    /// the original 2-person behaviour. Refreshed each tick of `pollPeer`.
    @State private var additionalParticipants: [Participant] = []
    /// Locally-added points for the solo "A→B, see what's in between" mode and
    /// for adding someone who lacks the app — a friend's home, the store, a
    /// typed address. Every entry is a `manual:` `Participant`. This array is
    /// NEVER read or written by `refreshFromAppGroup` (so the poll can't clobber
    /// it) and NEVER handed to a send path (so it can't ride into a bubble).
    @State private var manualParticipants: [Participant] = []
    /// True when the local user declared a future location ("I'll be at…")
    /// instead of sharing live GPS. Keeps a background fix from overwriting it
    /// and drives the "You'll be at X" labels. `selfManualLabel` is the place.
    @State private var selfIsManual = false
    @State private var selfManualLabel: String? = nil
    @State private var currentParticipants: [Participant] = []
    @State private var peerDisplayName = "Friend"
    @State private var peerNeedsRide = false
    @State private var localNeedsRide = false
    @State private var isUserIn = false
    /// True while we're waiting on the location fix the user explicitly asked
    /// for via "I'm in"; distinguishes that from the silent launch-time fix that
    /// only centers the map without flipping presence on.
    @State private var awaitingImIn = false
    @State private var provider = LocationProvider()
    @State private var monitor = NetworkMonitor()
    @State private var position: MapCameraPosition
    @State private var mapDisplayStyle: MapDisplayStyle = .standard
    @State private var isMapStylePickerExpanded = false
    @State private var resetNextTapReturnsToUser = false
    /// Opens at the half detent (search bar + chips + "I'm in" + the
    /// Search/Friends toggle), Apple-Maps style. Drag down to the search-only
    /// peek, or up to full.
    @State private var selectedSheetDetent: PresentationDetent = .fraction(0.45)

    /// Gate for the recurring App Group poll to skip writes to
    /// `selectedSheetDetent`. Docs: `docs/ui-research.md` §1 — the self-jump
    /// is caused by a poll re-asserting the detent-selection binding mid-drag.
    /// Set only via `pollRefreshFromAppGroup()`, which owns the `defer` reset;
    /// user-initiated refresh paths leave this `false` so the "agreed just
    /// landed" nudge still fires when a URL open or scene resume drives it.
    @State private var suppressPollDetentWrites: Bool = false
    /// Consume-once latches for the selection onChange. The one-tap rewiring
    /// made `selectedResult` a control signal ("selection ⟹ present sheet"),
    /// so PROGRAMMATIC writes must opt out explicitly — and they can't reuse
    /// `suppressPollDetentWrites`, because onChange runs in the NEXT view
    /// update, after that flag's defer already reset it (audit at bb6740d).
    @State private var suppressNextSelectionPresentation = false
    @State private var suppressNextDeselectDetentRestore = false

    /// Handle for the pending `expandThenFocusSearch` post-animation focus so a
    /// second call (rapid re-entry) can cancel the first — otherwise queued
    /// tasks each fire `searchFocused = true` after the user may have already
    /// backed out of the sheet. See `docs/ui-research.md` §7.
    @State private var focusExpandTask: Task<Void, Never>?

    /// Floating map-control tap-target size, scaled with Dynamic Type per
    /// `docs/ui-research.md` §11. `Tokens.Layout.minTapTarget` (44 pt) is the
    /// HIG floor at the default text size; at XXL Dynamic Type this grows so
    /// users with larger system text still hit the target easily. Applied to
    /// `resetMapButton` and `infoButton`, and the pattern other icon-button
    /// call sites should follow.
    @ScaledMetric private var floatingControlSize: CGFloat = Tokens.Layout.minTapTarget
    /// Friends-circle diameter, scaled relative to the caption type its
    /// initials render in — a fixed 44pt let AX-size initials overflow it.
    @ScaledMetric(relativeTo: .caption) private var friendsCircleSize: CGFloat = Tokens.Layout.searchBarHeight

    // Search
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var rankedSpots: [RankedSpot] = []
    @State private var isSearchActive = false
    @State private var isSearchLoading = false
    /// Whether the user is mid-typing (showing completer suggestions) or has
    /// committed a search (showing rich result cards). Drives which surface the
    /// sheet renders so suggestions and results never look alike.
    @State private var searchState: SearchState = .idle
    @State private var completer = SearchCompleter()
    /// Set when we mutate `searchText` programmatically (committing a suggestion
    /// or a category) so the field's `onChange` doesn't treat it as fresh typing
    /// and cancel the very search we just kicked off.
    @State private var suppressNextQueryChange = false
    /// Tracks the search field's focus so tapping it lifts the sheet to
    /// medium. Plain state (not @FocusState): the field is a bridged
    /// UISearchBar whose delegate reports focus both ways.
    @State private var searchFocused = false
    /// Tracks the profile-name field so the name persists when focus leaves it.
    @FocusState private var nameFieldFocused: Bool
    /// The tapped/selected search result — drives the highlighted map pin and the
    /// compact floating detail card (Apple-Maps style).
    @State private var selectedResult: MKMapItem?
    /// Whether results show as a scrollable list or as pins on the full map.
    @State private var searchViewMode: SearchViewMode = .list
    @State private var selectedCategory: CategoryPreset?
    @State private var searchTask: Task<Void, Never>?

    // Friends / social
    @State private var friendsPanelTab: FriendsPanelTab = .people
    @State private var friends: [TweenFriend] = FriendRoster.load()
    @State private var editorMode: FriendEditor?
    @State private var lastReplyAt: Date? = PingLog.lastIncomingReplyAt
    @State private var lastGenericInviteAt: Date? = PingLog.lastGenericInviteAt
    @State private var pingTick = 0
    @State private var renameText = ""
    @State private var toast: String?
    @State private var showLocationAlert = false

    // Profile (the name that rides along on invites)
    @State private var profileName = UserProfile.displayName ?? ""
    @State private var showNamePrompt = false
    @State private var nameDraft = ""
    /// Action to run once the user supplies a name from the prompt.
    @State private var pendingNameAction: (() -> Void)?
    /// Action to resume once a location fix arrives — the send/agree the user
    /// asked for while no coordinate was available yet. Mirrors
    /// `pendingNameAction`; without it those taps were silently discarded.
    @State private var pendingLocationAction: (() -> Void)?
    /// Keeps the cross-process MeetupSync observation alive for the life of
    /// this screen (registration ends when the token deallocates).
    @State private var syncToken: MeetupSyncToken?

    // Hand-off / onboarding
    @State private var showTutorial = !OnboardingFlags.hasSeenOnboarding
        && !CommandLine.arguments.contains("-SKIP_TUTORIAL")

    /// The single secondary sheet currently presented. Consolidated into one
    /// enum-driven `.sheet(item:)` because stacking multiple `.sheet` modifiers
    /// on the same view as the always-on bottom sheet caused presentations to
    /// silently no-op (Add Friend / Invite never appeared).
    @State private var activeSheet: ActiveSheet?

    /// Identifiable wrapper so the SMS composer can be presented via `sheet(item:)`.
    ///
    /// `message` is the rich iMessage payload (Tween bubble) — when non-nil the
    /// composer pre-fills it. `body` is still set as a plain-text fallback for
    /// recipients on SMS / non-iMessage handles.
    struct PendingMessage: Identifiable {
        let id = UUID()
        let recipients: [String]
        let body: String
        var message: MSMessage? = nil
        var onSent: (() -> Void)? = nil
        /// Runs when the composer closes WITHOUT sending (cancel or failure).
        /// Sends commit local state only on delivery, so a cancelled send
        /// silently changes nothing — these callbacks say so out loud
        /// ("You're still in") instead of leaving the user to guess.
        var onCancelled: (() -> Void)? = nil
    }

    private struct PendingInviteRow: Identifiable, Equatable {
        let id: String
        let name: String
        let sentAt: Date
        let count: Int
        let isGeneric: Bool
    }

    /// A tapped search result staged for the detail card. Carries the map item
    /// plus its ranking (when both coordinates are known) so the card can show
    /// an ETA chip.
    ///
    /// `incoming` is non-nil when the card is being shown because a friend's
    /// `tween://` link was opened (rather than the user picking a search
    /// result themselves). It flips the card into Agree/Change mode and
    /// carries the metadata needed to compose the reply bubble.
    struct SpotSelection: Identifiable {
        let id = UUID()
        let item: MKMapItem
        let ranked: RankedSpot?
        var incoming: IncomingProposalContext? = nil

        var name: String { item.name ?? "Spot" }
        var address: String? { item.placemark.cleanLine }
        var coordinate: CLLocationCoordinate2D { item.placemark.coordinate }
    }

    /// Context for an incoming spot proposal received via `tween://` link.
    /// Used by SpotDetailCard's Agree/Change actions to build the reply
    /// bubble's TweenState (sender name + participants + counter flag).
    struct IncomingProposalContext {
        let senderName: String?
        let senderID: String?
        let participants: [Participant]
        let agreedNames: [String]
        let agreedIDs: [String]
        let isCounter: Bool
    }

    /// Every secondary sheet the home surface can present, multiplexed through a
    /// single `.sheet(item:)`.
    enum ActiveSheet: Identifiable {
        case friends
        case contacts
        case invite
        case message(PendingMessage)
        case spot(SpotSelection)
        case addPoint
        case whereIllBe

        var id: String {
            switch self {
            case .friends:           return "friends"
            case .contacts:          return "contacts"
            case .invite:            return "invite"
            case .message(let m):    return "message-\(m.id)"
            case .spot(let s):       return "spot-\(s.id)"
            case .addPoint:          return "addPoint"
            case .whereIllBe:        return "whereIllBe"
            }
        }
    }

    /// The three phases of the search surface. Keeps "while typing" (completer
    /// suggestions) visually and structurally separate from "after committing"
    /// (full result cards), with a clean home in between.
    enum SearchState {
        /// Nothing searched — the sheet shows category chips and presence.
        case idle
        /// User is typing — show `MKLocalSearchCompleter` suggestion rows.
        case suggesting
        /// User committed a search — show full `ResultCard`s / map pins.
        case results
    }

    /// How search results are browsed: a scrollable list, or pins on the map.
    enum SearchViewMode: String, CaseIterable, Identifiable {
        case list
        case map
        var id: String { rawValue }
        var title: String { self == .list ? "List" : "Map" }
    }

    enum MapDisplayStyle: String, CaseIterable, Identifiable {
        case standard
        case traffic
        case satellite
        case hybrid

        var id: String { rawValue }

        var title: String {
            switch self {
            case .standard:  return "Standard"
            case .traffic:   return "Traffic"
            case .satellite: return "Satellite"
            case .hybrid:    return "Hybrid"
            }
        }

        var icon: String {
            switch self {
            case .standard:  return "map"
            case .traffic:   return "car.fill"
            case .satellite: return "globe.americas.fill"
            case .hybrid:    return "map.fill"
            }
        }

        var mapStyle: MapStyle {
            switch self {
            case .standard:
                return .standard(elevation: .flat)
            case .traffic:
                return .standard(elevation: .flat, showsTraffic: true)
            case .satellite:
                return .imagery(elevation: .flat)
            case .hybrid:
                return .hybrid(elevation: .flat, showsTraffic: true)
            }
        }
    }

    private struct QuickSpotShortcut: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let query: String
        let systemImage: String
    }

    private static let hostTabHarnessParticipants: [Participant] = [
        Participant(id: "You", name: "You",
                    latitude: 37.3382, longitude: -121.8863,
                    needsRide: true),
        Participant(id: "Kavi", name: "Kavi Gandham",
                    latitude: 37.4419, longitude: -122.1430),
        Participant(id: "Maya", name: "Maya",
                    latitude: 37.5483, longitude: -121.9886,
                    needsRide: true)
    ]

    init() {
        // NOTE: the old unconditional LocationCache.startFreshMeetup() moved to
        // TweenAppApp.init, gated on ConversationMeetupStore.hasLiveMeetup —
        // launching the app must not erase a meetup that's in flight.
        let harnessParticipants = Self.isHostTabHarness ? Self.hostTabHarnessParticipants : []
        if Self.isHostTabHarness {
            LocationCache.save(harnessParticipants[0].coordinate, isActive: true)
            LocationCache.saveParticipantSnapshot(harnessParticipants, localName: "You")
        }

        let cached = LocationCache.loadSelf()
        _savedCoordinate = State(initialValue: cached?.coordinate)
        _currentParticipants = State(initialValue: harnessParticipants)
        _peerCoordinate = State(initialValue: harnessParticipants.dropFirst().first?.coordinate)
        _peerDisplayName = State(initialValue: harnessParticipants.dropFirst().first?.name ?? "Friend")
        _peerNeedsRide = State(initialValue: harnessParticipants.dropFirst().first?.needsRide ?? false)
        _additionalParticipants = State(initialValue: Array(harnessParticipants.dropFirst(2)))
        _localNeedsRide = State(initialValue: harnessParticipants.first?.needsRide ?? false)
        _isUserIn = State(initialValue: Self.isHostTabHarness)
        _friendsPanelTab = State(initialValue: CommandLine.arguments.contains("-HARNESS_HOST_RIDES") ? .rides : .people)
        // Friends is its own sheet now (behind the search-row circle); the
        // friends/rides harnesses open it directly so screenshots still land
        // on the right surface. RIDE_MAP keeps the map visible.
        let wantsFriendsSheet = CommandLine.arguments.contains("-HARNESS_HOST_FRIENDS")
            || CommandLine.arguments.contains("-HARNESS_HOST_RIDES")
        _activeSheet = State(initialValue: wantsFriendsSheet ? .friends : nil)
        let hostHarnessDetent: PresentationDetent = CommandLine.arguments.contains("-HARNESS_HOST_RIDE_MAP")
            ? .height(Tokens.Layout.sheetPeekHeight)
            : .fraction(0.90)
        // -START_AT_PEEK: screenshot/UI-test hook for the collapsed pill,
        // which is otherwise only reachable by dragging.
        let defaultDetent: PresentationDetent = CommandLine.arguments.contains("-START_AT_PEEK")
            ? .height(Tokens.Layout.sheetPeekHeight)
            : .fraction(0.45)
        // Default selection/detent; the DEBUG demo hook below can override
        // them to preselect a spot for screenshot/UI-test verification.
        var demoSelection: MKMapItem?
        var initialDetent = Self.isHostTabHarness ? hostHarnessDetent : defaultDetent
        #if DEBUG
        // -DEMO_SPOT_CARD: preselects a synthesized spot (no place
        // identifier → fallback sheet layout) without a live search
        // round-trip; openDemoSpotSheetIfRequested presents its sheet on
        // launch since the initial value never fires onChange. DEBUG-only so
        // the deprecated addressDictionary init never ships in release.
        if CommandLine.arguments.contains("-DEMO_SPOT_CARD") {
            let coord = CLLocationCoordinate2D(latitude: 38.786, longitude: -77.271)
            let placemark = MKPlacemark(coordinate: coord, addressDictionary: [
                "Street": "9540 Old Keene Mill Rd", "City": "Burke", "State": "VA"])
            let demo = MKMapItem(placemark: placemark)
            demo.name = "Hangry Joe's Hot Chicken"
            demoSelection = demo
            initialDetent = .height(Tokens.Layout.sheetPeekHeight)
        }
        // -DEMO_ROUTE_AB: seeds a self location + one added point so the solo
        // A→B "what's in between" view (route chip, both pins, ranked spots)
        // can be screenshot-verified without live GPS/typing.
        if CommandLine.arguments.contains("-DEMO_ROUTE_AB") {
            _savedCoordinate = State(initialValue: CLLocationCoordinate2D(latitude: 37.3382, longitude: -121.8863))
            _manualParticipants = State(initialValue: [
                Participant.manual(label: "Kavi's place",
                                   coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194))
            ])
            initialDetent = .fraction(0.45)
        }
        // -DEMO_WHERE_ILL_BE: seeds a DECLARED future self location so the
        // "You'll be at X" label + active state can be screenshot-verified.
        if CommandLine.arguments.contains("-DEMO_WHERE_ILL_BE") {
            let blueBottle = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
            LocationCache.save(blueBottle, isActive: true, isManual: true)
            _savedCoordinate = State(initialValue: blueBottle)
            _selfIsManual = State(initialValue: true)
            _selfManualLabel = State(initialValue: "Blue Bottle, SF")
            _isUserIn = State(initialValue: true)
            initialDetent = .fraction(0.45)
        }
        #endif
        _selectedResult = State(initialValue: demoSelection)
        _selectedSheetDetent = State(initialValue: initialDetent)
        _agreedMeetup = State(initialValue: nil)
        let initialCoords = Self.isHostTabHarness
            ? harnessParticipants.map(\.coordinate)
            : [cached?.coordinate ?? Self.defaultCenter]
        _position = State(initialValue: Self.cameraPosition(for: initialCoords))
    }

    /// The full-bleed map plus its annotations. Safe-area-dependent chrome does
    /// NOT live here — it's layered on in `body`, where it can respect the real
    /// device insets instead of guessing them with hardcoded paddings.
    private var mapLayer: some View {
        Map(position: $position, selection: $selectedResult) {
            if let coord = savedCoordinate {
                Annotation(selfIsManual ? (selfManualLabel.map { "You'll be at \($0)" } ?? "You'll be there") : "You", coordinate: coord) {
                    // Self stays in the location-dot family even when a ride
                    // is needed — the badge overlays it (post-push audit).
                    TweenPin(role: isUserIn ? .selfActive : .selfDot, needsRide: localNeedsRide)
                }
            }
            // Locally-added points — a place/person you added for the solo A→B
            // "what's in between" view, or someone who lacks the app. Always
            // shown (a solo user isn't "in" a meetup), labelled with the name.
            ForEach(manualParticipants) { point in
                Annotation(point.name, coordinate: point.coordinate) {
                    TweenPin(role: .friend, initials: TweenPin.initials(for: point.name))
                }
            }
            // The meetup layer (friends, midpoint, agreement) renders only
            // while YOU are in it. After "I'm out" the roster deliberately
            // survives in the store so a rejoin can restore the group (D4),
            // but your map must stop showing the meetup you left — rendering
            // it read as "I'm out didn't work" (device feedback).
            if isUserIn {
                if let peer = peerCoordinate {
                    Annotation(peerDisplayName, coordinate: peer) {
                        // The legacy single-peer fallback names its entry
                        // "Friend" — a placeholder, not a name; show the
                        // person glyph rather than a bare "F" avatar.
                        TweenPin(role: .friend,
                                 initials: peerDisplayName == "Friend"
                                    ? nil : TweenPin.initials(for: peerDisplayName),
                                 needsRide: peerNeedsRide)
                    }
                }
                // Additional remote participants (groups of 3+). Each is named
                // so the map matches what the iMessage bubble shows.
                ForEach(additionalParticipants) { participant in
                    Annotation(participant.name, coordinate: participant.coordinate) {
                        TweenPin(role: .friend,
                                 initials: TweenPin.initials(for: participant.name),
                                 needsRide: participant.needsRide)
                    }
                }
                if let midpointCoordinate {
                    Annotation("Midpoint", coordinate: midpointCoordinate) {
                        TweenPin(role: .midpoint)
                    }
                }
                if let agreedMeetup, agreedMeetup.kind == .place {
                    Annotation(agreedMeetup.text, coordinate: agreedMeetup.coordinate, anchor: .bottom) {
                        TweenPin(role: .fairSpot)
                    }
                }
            }
            // The spot currently under negotiation (no agreement yet).
            // Dual-render (W8): the proposal pin shows even while a meetup
            // is set — visiblePendingProposal already filtered same-spot.
            if let pendingProposal, pendingProposal.kind == .place {
                Annotation(pendingProposal.text, coordinate: pendingProposal.coordinate, anchor: .bottom) {
                    TweenPin(role: .fairSpot)
                }
            }
            // A selectable pin for every visible search result. Selection uses
            // MapKit's native Marker treatment (the same subtle pop Apple Maps
            // does) — the old custom annotation ballooned into a chip + giant
            // circle on tap, which read as a glitch. The A/B distances live in
            // the floating card instead. Tapping the empty map clears the
            // selection.
            ForEach(displayedItems, id: \.self) { item in
                Marker(item.name ?? "Place", systemImage: resultSymbol(for: item), coordinate: item.placemark.coordinate)
                    .tint(item == selectedResult ? Tokens.Palette.brand : resultRole(for: item).fill)
                    .tag(item)
            }
        }
        .ignoresSafeArea()
        .mapStyle(mapDisplayStyle.mapStyle)
    }

    var body: some View {
        // Full-bleed map with floating controls laid out inside the safe area
        // (the ZStack respects it; only the map ignores it). No top gradient
        // or glass — Apple Maps runs the map clean to the screen edge, and
        // every attempt at a status-bar treatment read as a weird band.
        ZStack {
            mapLayer
            topTrailingControls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            viewModeToggle
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            compactCard
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .animation(Tokens.Motion.snappy, value: selectedResult)
        .onChange(of: selectedResult) { _, item in
            resetNextTapReturnsToUser = false
            if let item {
                if suppressNextSelectionPresentation {
                    // Programmatic waiting-pin selection (showOwnProposalOnMap):
                    // the caller staged its own camera/detent/toast, and
                    // presenting here re-opened the sheet the user JUST sent
                    // from — a double-propose invitation with the waiting
                    // toast buried beneath it (audit at bb6740d).
                    suppressNextSelectionPresentation = false
                } else {
                    // ONE tap → the full place sheet, like Apple Maps. The old
                    // intermediate compact card forced a second tap for the
                    // real information — "a waste" (device feedback).
                    focusMap(on: item)
                    activeSheet = .spot(SpotSelection(item: item, ranked: rankedMatch(for: item)))
                }
            } else {
                // A programmatic deselect (agreement landed, negotiation
                // moved on, poll cleared a dead session) must also close the
                // place sheet it opened — one-directional sync left the sheet
                // orphaned over a finished negotiation while the "Meeting at
                // X" toast rendered invisibly beneath it (audit at 8affc61).
                // No-op for user-initiated closes: onDismiss already nilled
                // the sheet before clearing the selection.
                if case .spot = activeSheet { activeSheet = nil }
                // Restore the search peek — but never from a background
                // refresh, which must not yank the sheet out from under the
                // user's drag (docs/ui-research.md §1). Uses the consume-once
                // latch: the old `!suppressPollDetentWrites` check was dead
                // code because that flag's defer resets before onChange runs
                // in the next view-update pass (audit at bb6740d).
                if suppressNextDeselectDetentRestore {
                    suppressNextDeselectDetentRestore = false
                } else {
                    withAnimation(Tokens.Motion.snappy) {
                        selectedSheetDetent = .height(Tokens.Layout.sheetPeekHeight)
                    }
                }
            }
        }
        .onChange(of: searchResults.count) { _, _ in resetNextTapReturnsToUser = false }
        .onChange(of: isSearchActive) { _, _ in resetNextTapReturnsToUser = false }
        .onChange(of: searchViewMode) { _, mode in
            switch mode {
            case .map:
                withAnimation(Tokens.Motion.snappy) { selectedSheetDetent = .height(Tokens.Layout.sheetPeekHeight) }
                frameResults()
            case .list:
                withAnimation(Tokens.Motion.snappy) { selectedSheetDetent = .fraction(0.45) }
            }
        }
        .sheet(isPresented: .constant(true)) {
            sheetContent
                .presentationDetents(
                    [.height(Tokens.Layout.sheetPeekHeight), .fraction(0.45), .fraction(0.90)],
                    selection: $selectedSheetDetent
                )
                // iOS 26 gets the system's Liquid Glass floating panel — the
                // exact chrome Maps' bottom pill uses (design brief:
                // developer.apple.com "Adopting Liquid Glass"). Pre-26 keeps
                // the near-opaque material that read correctly there.
                .modifier(TweenSheetSurface())
                .presentationBackgroundInteraction(.enabled)
                // A vertical swipe RESIZES the sheet in preference to
                // scrolling its content (scrolling still works at the top
                // detent) — without this, the results/suggestions ScrollView
                // and the detent gesture fought over every drag whenever the
                // search field had text, which is exactly the "clunky and
                // boxy, not smooth like when it's empty" device feedback.
                .presentationContentInteraction(.resizes)
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
                // Secondary sheets are presented from *within* the bottom sheet's
                // content, not from the Map. The Map already permanently presents
                // this bottom sheet, and a view can only present one sheet at a
                // time — attaching these to the Map silently no-ops (Add Friend /
                // Invite / the detail card never appeared).
                .fullScreenCover(isPresented: $showTutorial) {
                    OnboardingTutorialView(onDone: dismissTutorial)
                }
                .sheet(item: $activeSheet, onDismiss: {
                    // Closing the place sheet deselects its pin, so the map
                    // returns to browse state and the search peek restores
                    // (via the selectedResult onChange). Harmless for the
                    // other sheet types — they never set a selection.
                    if selectedResult != nil { selectedResult = nil }
                }) { sheet in
                    switch sheet {
                    case .friends:
                        NavigationStack {
                            friendsPanel
                                .navigationTitle("Friends")
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("Done") { activeSheet = nil }
                                    }
                                }
                                // Presented from THIS sheet: the trigger is a
                                // swipe action inside it, and UIKit refuses to
                                // present an alert from a VC that's already
                                // presenting — attached one level up, Rename
                                // silently never appeared (audit W13).
                                .alert("Rename Friend", isPresented: renameBinding, presenting: editorMode) { _ in
                                    TextField("Name", text: $renameText)
                                    Button("Save", action: commitRename)
                                    Button("Cancel", role: .cancel) { editorMode = nil }
                                } message: { editor in
                                    Text("Choose a new name for \(editor.friend.name).")
                                }
                        }
                        .presentationDetents([.large])
                    case .contacts:
                        ContactSearchView { friend in
                            FriendRoster.add(friend)
                            friends = FriendRoster.load()
                            // Contacts was reached from the Friends sheet —
                            // land back there with the new row visible.
                            activeSheet = .friends
                        }
                    case .invite:
                        ActivityView(items: [Self.inviteText]) { activeSheet = nil }
                    case .message(let pending):
                        MessageComposeSheet(recipients: pending.recipients,
                                            body: pending.body,
                                            message: pending.message) { result in
                            activeSheet = nil
                            if result == .sent {
                                pending.onSent?()
                            } else {
                                pending.onCancelled?()
                            }
                        }
                    case .spot(let selection):
                        SpotDetailCard(
                            name: selection.name,
                            address: selection.address,
                            coordinate: selection.coordinate,
                            ranked: selection.ranked,
                            mapItem: selection.item,
                            incoming: selection.incoming.map {
                                SpotDetailCard.IncomingProposal(
                                    senderName: $0.senderName,
                                    isCounter: $0.isCounter)
                            },
                            onSendToChat: { sendToChat(selection) },
                            onAgree: {
                                if let incoming = selection.incoming {
                                    sendAgreeReply(for: selection, incoming: incoming)
                                }
                            },
                            onChange: { startChangeFlow(initialCoord: selection.coordinate) }
                        )
                    case .addPoint:
                        AddPointSheet(region: searchRegion,
                                      resolvePlace: resolvePlace,
                                      onAdd: addManualPoint)
                    case .whereIllBe:
                        AddPointSheet(title: "Where will you be?",
                                      prompt: "The address you're heading to",
                                      region: searchRegion,
                                      resolvePlace: resolvePlace,
                                      onAdd: setManualSelf)
                    }
                }
                // Alerts triggered from inside the sheet must present FROM the
                // sheet. Attached to the Map they sat beneath the permanently
                // presented bottom sheet and silently never appeared — the
                // same trap the ActiveSheet consolidation comment documents.
                // (Rename Friend lives one level deeper still — on the
                // Friends sheet's own content — because its trigger is a
                // swipe action inside THAT sheet; audit W13.)
                .alert("Location Unavailable", isPresented: $showLocationAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(provider.status == .denied
                         ? "Turn on location access in Settings to share where you are."
                         : "We couldn't get your location. Try again in a moment.")
                }
        }
        .onChange(of: provider.status) { _, status in
            let wasAwaitingImIn = awaitingImIn
            if case let .got(coord) = status {
                // A declared "I'll be at…" self must survive a background GPS
                // fix — ignore the silent fix entirely (keep the map + coord on
                // the declared place). An explicit "I'm in" tap already cleared
                // selfIsManual, so a deliberate live join still wins.
                let keepManual = selfIsManual && !awaitingImIn
                if !keepManual {
                    withAnimation(Tokens.Motion.spring) {
                        savedCoordinate = coord
                        // Stamp the freshness of this in-memory fix so a pending
                        // send (which resumes right below) knows it's current even
                        // though the silent branch doesn't touch the cache.
                        savedCoordinateAt = Date()
                        // Only the explicit "I'm in" gesture flips presence on and
                        // persists the coordinate for the peer hand-off. The silent
                        // launch fix just recenters the map on a self dot.
                        if awaitingImIn {
                            LocationCache.save(coord, isActive: true)
                            saveLocalParticipant(coord)
                            isUserIn = true
                        }
                    }
                    reframe()
                }
                awaitingImIn = false
                // Resume whatever send the user initiated before the fix
                // landed (send-to-chat, agree reply). Runs after the cache
                // writes above so the action sees the fresh coordinate.
                if let action = pendingLocationAction {
                    pendingLocationAction = nil
                    action()
                }
            } else if status == .denied || status == .failed {
                awaitingImIn = false
                if pendingLocationAction != nil {
                    pendingLocationAction = nil
                    showToast("Couldn't get your location — try again")
                }
                if wasAwaitingImIn {
                    showLocationAlert = true
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Mirror the extension's memory discipline: drop in-flight work when
            // we're no longer foregrounded.
            if phase != .active {
                searchTask?.cancel()
                // A backgrounding cancel returns at runSearch's Task.isCancelled
                // guard, before `isSearchLoading = false` — reset it here or the
                // spinner hangs until the next keystroke (audit). A search
                // SUPERSEDED by a new one isn't reset here: its replacement task
                // owns the flag, so there's no premature clear.
                isSearchLoading = false
            }
            // When the user comes back to the host app (typically after
            // tapping "I'm in" in the iMessage extension), refresh from the
            // App Group BEFORE the next paint. Without this the user briefly
            // sees stale isUserIn / pin state until pollPeer's next 300 ms
            // tick, which reads as "the extension didn't sync." Cross-process
            // UserDefaults.didChangeNotification doesn't fire for extension
            // writes, so this scene-resume callback is the immediate hook.
            if phase == .active {
                _ = refreshFromAppGroup()
            }
        }
        .task {
            // Darwin notifications are the primary cross-process signal now:
            // every canonical App Group writer posts one, so extension state
            // appears here the instant it lands instead of on the next poll
            // tick. The poll below survives only as a slow fallback.
            if syncToken == nil {
                syncToken = MeetupSync.observe {
                    Task { @MainActor in _ = pollRefreshFromAppGroup() }
                }
            }
            await pollPeer()
        }
        .task { requestInitialLocation() }
        .task { await openDemoSpotSheetIfRequested() }
        .onAppear {
            _ = refreshFromAppGroup()
            // Cold-open with a live negotiation: drop the sheet to its peek so
            // the floating proposal/agreed card is visible. Explicit (not
            // transition-driven) because the poll task's first tick often runs
            // before this and consumes the nil→value transition under the
            // anti-yank suppression gate.
            if pendingProposal != nil || agreedMeetup != nil {
                selectedSheetDetent = .height(Tokens.Layout.sheetPeekHeight)
            }
            // Same first-tick race for the CAMERA: the suppressed poll tick
            // can consume the initial App Group load, leaving the refresh
            // above with didChange == false and restored peer pins framed
            // off-screen. An explicit cold-open reframe is user-initiated by
            // definition (post-push audit).
            reframe()
        }
        .onReceive(appGroupDidChangePublisher) { _ in
            // Catches in-process writes (e.g. host app's own "I'm in" button).
            // Extension writes don't fire this — see pollPeer + scenePhase
            // handler above for the cross-process path.
            // Route through the poll-safe wrapper: this fires on background
            // App Group activity that isn't a direct user gesture on the
            // sheet, so it must not re-assert the detent selection binding
            // (docs/ui-research.md §1).
            Task { @MainActor in
                _ = pollRefreshFromAppGroup()
            }
        }
        .onOpenURL(perform: handleIncomingURL)
    }

    // MARK: - Bottom sheet

    /// True when the sheet is collapsed to its search-bar-only peek.
    private var isMinimalDetent: Bool { selectedSheetDetent == .height(Tokens.Layout.sheetPeekHeight) }

    @ViewBuilder
    private var sheetContent: some View {
        VStack(spacing: Tokens.Spacing.s3) {
            // The persistent search row lives in a FIXED-HEIGHT header
            // exactly one peek tall, centered within it — a constant
            // offset from the sheet's top edge in every phase so it
            // rides the edge on drags instead of teleporting when the
            // detent settles. (A tapped result no longer swaps this
            // surface for an intermediate card: selection goes straight
            // to the full place sheet — one tap, like Apple Maps.)
            searchBar
                .frame(height: Tokens.Layout.sheetPeekHeight)

            // Everything else is revealed once the sheet lifts off peek.
            if !isMinimalDetent {
                if !monitor.isOnline { offlineBanner }
                replyBanner
                mapPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Tokens.Motion.snappy, value: selectedSheetDetent)
        // Dragging the results down slides the keyboard out with the finger
        // instead of leaving it planted over a resizing sheet.
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: selectedSheetDetent) { _, detent in
            // Collapsing to the peek pill ends the editing session — holding
            // first responder under a collapsed sheet kept the keyboard (and
            // its re-focus) fighting the drag whenever the field had text.
            if detent == .height(Tokens.Layout.sheetPeekHeight) { searchFocused = false }
        }
        .overlay(alignment: .bottom) { toastView }
        .sensoryFeedback(trigger: isUserIn) { _, isIn in isIn ? .success : nil }
        .sensoryFeedback(.impact, trigger: pingTick)
        .alert("Your Name", isPresented: $showNamePrompt) {
            TextField("Name", text: $nameDraft)
            Button("Save", action: saveName)
            Button("Cancel", role: .cancel) { pendingNameAction = nil }
        } message: {
            Text("Add your name so friends see who's inviting them.")
        }
    }

    /// The place-search surface below the search bar. What it shows depends on
    /// where the search flow is: suggestions while typing, otherwise chips +
    /// presence (+ result cards once a search is committed).
    @ViewBuilder
    private var mapPanel: some View {
        // Cross-fade between the two phases: the old hard identity swap
        // (suggestion list ⟷ chips + result cards) replaced the whole
        // subtree with no transition, which read as a boxy jump whenever a
        // drag or keystroke crossed a state boundary (device feedback).
        Group {
            switch searchState {
            case .suggesting:
                suggestionsList
                    .transition(.opacity)
            case .idle, .results:
                VStack(spacing: Tokens.Spacing.s3) {
                    categoryChips
                    Divider()
                    resultsScroll
                }
                .transition(.opacity)
            }
        }
        .animation(Tokens.Motion.snappy, value: searchState)
    }

    /// Compact completer-driven suggestion rows shown while the user types.
    /// Tapping a row commits that suggestion as a full search.
    private var suggestionsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if completer.results.isEmpty {
                    // Phase-aware empty state (audit W16): the spinner was
                    // shown for EVERY empty result set, so a completer
                    // failure or a no-match query spun forever.
                    HStack(spacing: Tokens.Spacing.s2) {
                        switch completer.phase {
                        case .failed:
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(Tokens.Palette.textSecondary)
                            Text("Search unavailable — check your connection")
                                .font(Tokens.Typography.footnote)
                                .foregroundStyle(Tokens.Palette.textSecondary)
                        case .resolved:
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(Tokens.Palette.textSecondary)
                            Text("No matches — try a different name")
                                .font(Tokens.Typography.footnote)
                                .foregroundStyle(Tokens.Palette.textSecondary)
                        case .idle, .searching:
                            ProgressView()
                            Text("Searching nearby...")
                                .font(Tokens.Typography.footnote)
                                .foregroundStyle(Tokens.Palette.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Spacing.s3)
                }
                ForEach(completer.results.prefix(6), id: \.self) { completion in
                    Button { selectSuggestion(completion) } label: {
                        SuggestionRow(completion: completion)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Searches for \(completion.title)")
                    Divider()
                }
            }
            .padding(.horizontal)
        }
    }

    private var topTrailingControls: some View {
        VStack(alignment: .trailing, spacing: Tokens.Spacing.s2) {
            infoButton
            mapStyleButton
            resetMapButton
        }
        .padding(.top, Tokens.Spacing.s2)
        .padding(.trailing, Tokens.Spacing.s4)
    }


    private var mapStyleButton: some View {
        HStack(spacing: Tokens.Spacing.s2) {
            if isMapStylePickerExpanded {
                HStack(spacing: Tokens.Spacing.s2) {
                    ForEach(MapDisplayStyle.allCases) { style in
                        Button {
                            withAnimation(Tokens.Motion.snappy) {
                                mapDisplayStyle = style
                                isMapStylePickerExpanded = false
                            }
                        } label: {
                            mapControlIcon(style.icon, isSelected: style == mapDisplayStyle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(style.title)
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            Button {
                withAnimation(Tokens.Motion.snappy) {
                    isMapStylePickerExpanded.toggle()
                }
            } label: {
                mapControlIcon(mapDisplayStyle.icon)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Map style")
            .accessibilityValue(mapDisplayStyle.title)
            .accessibilityHint("Shows map style choices")
        }
        .animation(Tokens.Motion.snappy, value: isMapStylePickerExpanded)
    }

    private func mapControlIcon(_ systemName: String, isSelected: Bool = false) -> some View {
        Image(systemName: systemName)
            .font(Tokens.Typography.callout)
            .foregroundStyle(isSelected ? .white : Tokens.Palette.brand)
            .frame(width: floatingControlSize, height: floatingControlSize)
            .modifier(TweenGlassControl(
                shape: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous),
                isSelected: isSelected))
    }


    private var resetMapButton: some View {
        Button {
            resetMapCamera()
        } label: {
            Image(systemName: "location.viewfinder")
                .font(Tokens.Typography.callout)
                .foregroundStyle(Tokens.Palette.brand)
                .frame(width: floatingControlSize, height: floatingControlSize)
                .modifier(TweenGlassControl(
                    shape: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reset map")
        .accessibilityHint("First shows visible places, then returns to your location")
    }

    /// Floating control to re-show the first-run walkthrough.
    private var infoButton: some View {
        // Dismiss any open place sheet first: `.fullScreenCover` and
        // `.sheet(item:)` share this hierarchy, and SwiftUI presents only one —
        // so tapping Help while a sheet is up would otherwise silently no-op.
        Button { activeSheet = nil; showTutorial = true } label: {
            Image(systemName: "info.circle.fill")
                .font(Tokens.Typography.title2)
                .foregroundStyle(Tokens.Palette.brand)
                .frame(width: floatingControlSize, height: floatingControlSize)
                .modifier(TweenGlassControl(shape: Circle()))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Help")
        .accessibilityHint("Shows the welcome walkthrough")
    }

    /// Floating List/Map switch over the map, shown only when there are results
    /// so it stays reachable even when the sheet is collapsed to its peek.
    @ViewBuilder
    private var viewModeToggle: some View {
        if isSearchActive && !searchResults.isEmpty {
            Picker("Results view", selection: $searchViewMode) {
                ForEach(SearchViewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: Tokens.Layout.minTapTarget * 4 + Tokens.Spacing.s6)
            .padding(Tokens.Spacing.s1)
            .modifier(TweenGlassControl(shape: Capsule()))
            .padding(.top, Tokens.Spacing.s2)
            .accessibilityHint("Switches between a list of results and pins on the map")
        }
    }

    /// Top-of-sheet banner when the network drops; search is gated while offline.
    private var offlineBanner: some View {
        HStack(spacing: Tokens.Spacing.s2) {
            Image(systemName: "wifi.slash")
            Text("You're offline. Reconnect to find meetup spots.")
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(Tokens.Typography.footnote.weight(.medium))
        .foregroundStyle(.white)
        .padding(Tokens.Spacing.s3)
        .frame(maxWidth: .infinity)
        .background(Tokens.Palette.warning, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }

    /// A nudge that the other side just shared a spot, shown across both tabs
    /// while the inbound bubble is still fresh.
    @ViewBuilder
    private var replyBanner: some View {
        if let lastReplyAt,
           peerCoordinate != nil,
           Date().timeIntervalSince(lastReplyAt) < Self.replyFreshness {
            HStack(spacing: Tokens.Spacing.s2) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                Text("Your friend replied \(RelativeTime.string(from: lastReplyAt))")
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(Tokens.Typography.footnote.weight(.medium))
            .padding(Tokens.Spacing.s3)
            .background(Tokens.Palette.brand.opacity(0.15), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .padding(.horizontal)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Friends panel

    @ViewBuilder
    private var friendsPanel: some View {
        VStack(spacing: Tokens.Spacing.s3) {
            Picker("Friends section", selection: $friendsPanelTab) {
                ForEach(FriendsPanelTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .frame(minHeight: Tokens.Layout.minTapTarget)
            .accessibilityHint("Switches between people and rides")

            Group {
                switch friendsPanelTab {
                case .people:
                    peoplePanel
                case .rides:
                    ridesPanel
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        // No cross-animation on tab switches — the People/Rides panels differ
        // wildly in height, so animating the swap stretched and snapped the
        // content. Apple Maps swaps segment content instantly.
    }

    /// One scrolling List for the entire People tab. The old layout stacked the
    /// header content above a nested List in a fixed VStack, so at the half
    /// detent the roster collapsed to zero height and clipped.
    private var peoplePanel: some View {
        List {
            Group {
                nameFieldRow
                friendActionButtons
                meetupStatusSection
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: Tokens.Spacing.s1, leading: Tokens.Spacing.s4,
                                      bottom: Tokens.Spacing.s1, trailing: Tokens.Spacing.s4))

            if friends.isEmpty {
                ContentUnavailableView(
                    "No Saved Friends",
                    systemImage: "person.2",
                    description: Text("Add contacts here, or open a Tween iMessage to see the live meetup roster above."))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(friends) { friend in
                    FriendRow(friend: friend, pingTick: pingTick)
                        .contentShape(Rectangle())
                        .onTapGesture { pingFriend(friend) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Pings \(friend.name) to meet up")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteFriend(friend)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { startRename(friend) } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(Tokens.Palette.pinSelf)
                        }
                }
            }
        }
        .listStyle(.plain)
    }

    /// The profile-name field as a form row — icon badge, caption label, and an
    /// opaque secondary surface — so it can't be mistaken for the place-search
    /// bar. Persists on submit or when focus leaves the field, not per keystroke
    /// (every write fans out through the App Group change publisher).
    private var nameFieldRow: some View {
        HStack(spacing: Tokens.Spacing.s3) {
            Image(systemName: "person.text.rectangle")
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Palette.brand)
                .frame(width: 36, height: 36)
                .background(Tokens.Palette.brandLight, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Your name")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                TextField("Add your name", text: $profileName)
                    .textFieldStyle(.plain)
                    .focused($nameFieldFocused)
                    .submitLabel(.done)
                    .onSubmit(saveProfileName)
                    .accessibilityLabel("Your name")
                    .accessibilityHint("Shown to friends when you invite them")
            }
        }
        .padding(Tokens.Spacing.s3)
        .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .onChange(of: nameFieldFocused) { _, focused in
            if !focused { saveProfileName() }
        }
    }

    private var friendActionButtons: some View {
        HStack(spacing: Tokens.Spacing.s2) {
            Button { activeSheet = .contacts } label: {
                Label("Add Friend", systemImage: "person.badge.plus")
            }
            .buttonStyle(.tweenPrimary())
            .accessibilityHint("Picks someone from your contacts")

            Button { activeSheet = .invite } label: {
                Label("Invite", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.tweenPrimary(.subtle))
            .accessibilityHint("Shares an invite link to Tween")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var meetupStatusSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            HStack {
                Label("Current meetup", systemImage: "person.2.fill")
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                Text(pendingInvitesForDisplay.isEmpty
                     ? "\(activeParticipantsForDisplay.count) in"
                     : "\(activeParticipantsForDisplay.count) in · \(pendingInvitePersonCount) pending")
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(Tokens.Palette.brand)
            }

            if activeParticipantsForDisplay.isEmpty, pendingInvitesForDisplay.isEmpty {
                Text("No one is in yet. People invited from Messages appear here as pending once you send the invite.")
                    .font(Tokens.Typography.footnote)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Spacing.s3)
                    .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(activeParticipantsForDisplay.enumerated()), id: \.element.id) { index, participant in
                        participantStatusRow(participant)
                        if index < activeParticipantsForDisplay.count - 1 || !pendingInvitesForDisplay.isEmpty {
                            Divider().padding(.leading, 48)
                        }
                    }
                    ForEach(Array(pendingInvitesForDisplay.enumerated()), id: \.element.id) { index, invite in
                        pendingInviteStatusRow(invite)
                        if index < pendingInvitesForDisplay.count - 1 {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
                .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            }
        }
    }

    /// Identity-based "is this the local user" test (audit F2 step 4). The old
    /// `participant.name == (displayName ?? "You")` string compare misclassified
    /// a REMOTE participant literally named "You" as the local user; matching on
    /// the stable ID (name fallback only for id-less legacy entries) fixes it.
    private func isLocalParticipant(_ participant: Participant) -> Bool {
        participant.matches(LocalParticipantContext(
            id: TweenIdentity.stableID,
            name: UserProfile.displayName ?? UserName.fallback))
    }

    /// A participant row label: "You" for the local user, otherwise the peer's
    /// name sanitised so an unnamed sender reads "Friend", never "You".
    private func participantLabel(_ participant: Participant) -> String {
        isLocalParticipant(participant) ? "You" : UserName.peerDisplayName(participant.name)
    }

    private func participantStatusRow(_ participant: Participant) -> some View {
        let isLocal = isLocalParticipant(participant)
        return HStack(spacing: Tokens.Spacing.s3) {
            Image(systemName: participant.needsRide ? "figure.wave" : "checkmark.circle.fill")
                .font(Tokens.Typography.headline)
                .foregroundStyle(participant.needsRide ? Tokens.Palette.pinRideNeeded : Tokens.Palette.success)
                .frame(width: 36, height: 36)
                .background((participant.needsRide ? Tokens.Palette.pinRideNeeded : Tokens.Palette.success).opacity(0.14),
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(participantLabel(participant))
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                Text(participant.needsRide ? "Needs pickup" : "Can meet there")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
            Spacer(minLength: 0)
            Text(isLocal ? "You" : "In")
                .font(Tokens.Typography.captionBold)
                .foregroundStyle(Tokens.Palette.textSecondary)
        }
        .padding(Tokens.Spacing.s3)
        .accessibilityElement(children: .combine)
    }

    private func pendingInviteStatusRow(_ invite: PendingInviteRow) -> some View {
        HStack(spacing: Tokens.Spacing.s3) {
            Image(systemName: invite.isGeneric ? "paperplane.circle.fill" : "hourglass.circle.fill")
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Palette.warning)
                .frame(width: 36, height: 36)
                .background(Tokens.Palette.warning.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(invite.name)
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                Text(invite.isGeneric
                     ? "Sent from iMessage - waiting for them to tap I'm in"
                     : "Invite sent \(RelativeTime.string(from: invite.sentAt))")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("Pending")
                .font(Tokens.Typography.captionBold)
                .foregroundStyle(Tokens.Palette.warning)
        }
        .padding(Tokens.Spacing.s3)
        .accessibilityElement(children: .combine)
    }

    private var ridesPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s3) {
                rideRequestCard

                if activeParticipantsForDisplay.isEmpty {
                    ContentUnavailableView(
                        "No Meetup Yet",
                        systemImage: "car.2",
                        description: Text("Tap I'm in or open a Tween iMessage so ride planning has people to work with."))
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if pickupRiders.isEmpty {
                    ContentUnavailableView(
                        "No Pickup Requests",
                        systemImage: "checkmark.circle",
                        description: Text("Everyone in the meetup can get to the spot for now."))
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    rideSection(title: "Needs pickup", participants: pickupRiders, emptyText: nil)
                    rideSection(title: "Can drive or meet there", participants: rideDrivers, emptyText: "No available drivers yet.")
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private var rideRequestCard: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s3) {
            HStack(alignment: .top, spacing: Tokens.Spacing.s3) {
                Image(systemName: localNeedsRide ? "figure.wave" : "car.fill")
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(localNeedsRide ? Tokens.Palette.pinRideNeeded : Tokens.Palette.brand)
                    .frame(width: 40, height: 40)
                    .background((localNeedsRide ? Tokens.Palette.pinRideNeeded : Tokens.Palette.brand).opacity(0.14),
                                in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))
                VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                    Text(localNeedsRide ? "You need a ride" : "Ride status")
                        .font(Tokens.Typography.headline)
                    Text(localNeedsRide ? "Your map pin is green so friends know to pick you up." : "Mark yourself if someone should pick you up before the meetup.")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }

            Button {
                setNeedsRide(!localNeedsRide)
            } label: {
                Label(localNeedsRide ? "I don't need a ride" : "I need a ride",
                      systemImage: localNeedsRide ? "checkmark.circle" : "figure.wave")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(localNeedsRide ? .tweenPrimary(.subtle) : .tweenPrimary())
            .disabled(savedCoordinate == nil && !isUserIn)
            .accessibilityHint("Updates your meetup pin and ride status")
        }
        .padding(Tokens.Spacing.s3)
        .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
    }

    private func rideSection(title: String, participants: [Participant], emptyText: String?) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            Text(title)
                .font(Tokens.Typography.captionBold)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .textCase(.uppercase)

            if participants.isEmpty, let emptyText {
                Text(emptyText)
                    .font(Tokens.Typography.footnote)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .padding(Tokens.Spacing.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(participants.enumerated()), id: \.element.id) { index, participant in
                        rideParticipantRow(participant)
                        if index < participants.count - 1 {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
                .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            }
        }
    }

    private func rideParticipantRow(_ participant: Participant) -> some View {
        return HStack(spacing: Tokens.Spacing.s3) {
            Image(systemName: participant.needsRide ? "figure.wave" : "car.fill")
                .font(Tokens.Typography.headline)
                .foregroundStyle(participant.needsRide ? Tokens.Palette.pinRideNeeded : Tokens.Palette.brand)
                .frame(width: 36, height: 36)
                .background((participant.needsRide ? Tokens.Palette.pinRideNeeded : Tokens.Palette.brand).opacity(0.14),
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(participantLabel(participant))
                    .font(Tokens.Typography.headline)
                    .lineLimit(1)
                Text(rideSubtitle(for: participant))
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Spacing.s3)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(Tokens.Typography.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, Tokens.Spacing.s4)
                .padding(.vertical, Tokens.Spacing.s3)
                // Toasts read as a dark scrim capsule in both color schemes.
                .background(.black.opacity(0.8), in: Capsule())
                .padding(.bottom, Tokens.Spacing.s4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
        }
    }

    /// Apple-Maps search row: the NATIVE search field (bridged UISearchBar —
    /// the component family Maps itself uses) plus the circular Friends
    /// button in their avatar slot. One persistent row, every detent.
    private var searchBar: some View {
        HStack(spacing: Tokens.Spacing.s2) {
            NativeSearchBar(
                text: $searchText,
                isEditing: $searchFocused,
                placeholder: "Search for a spot...",
                onSubmit: commitSearch)
                .frame(minHeight: Tokens.Layout.searchBarHeight)
                .onChange(of: searchText) { _, query in
                    if query != selectedCategory?.searchQuery { selectedCategory = nil }
                    // A new query invalidates any pin/card from the old result set.
                    selectedResult = nil
                    handleQueryChange(query)
                }

            friendsButton
        }
        .padding(.leading, Tokens.Spacing.s2)
        .padding(.trailing)
        .onChange(of: searchFocused) { _, focused in
            // Focusing the field lifts the collapsed sheet so suggestions
            // have room — the begin-editing delegate replaces the old
            // tap-gesture + @FocusState pair.
            if focused { focusSearchPanel() }
        }
    }

    /// The Friends surface lives behind this circle (where Apple Maps puts
    /// the account avatar), not in a segmented tab — the tab swap reflowed
    /// the whole sheet and never matched the Maps feel.
    private var friendsButton: some View {
        Button { activeSheet = .friends } label: {
            Group {
                if let name = UserName.load() {
                    Text(Self.initials(for: name))
                        .font(Tokens.Typography.captionBold)
                        .foregroundStyle(Tokens.Palette.onBrand)
                        // The circle scales with Dynamic Type (below), but at
                        // AX sizes the initials can still outgrow it — clamp
                        // rather than overflow the capsule row.
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Image(systemName: "person.2.fill")
                        .font(Tokens.Typography.footnote.weight(.semibold))
                        .foregroundStyle(Tokens.Palette.onBrand)
                }
            }
            // @ScaledMetric, not the fixed searchBarHeight: caption-relative
            // scaling keeps the circle wrapped around its initials at AX
            // text sizes instead of letting them spill out of a 44pt frame.
            .frame(width: friendsCircleSize, height: friendsCircleSize)
            .background(Tokens.Palette.brand, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Friends")
        .accessibilityHint("Opens your friends, meetup roster, and rides")
    }

    private static func initials(for name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        let result = String(letters).uppercased()
        return result.isEmpty ? "?" : result
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Spacing.s2) {
                ForEach(CategoryPreset.allCases) { preset in
                    let selected = preset == selectedCategory
                    Button { selectCategory(preset) } label: {
                        Label(preset.title, systemImage: preset.icon)
                            .font(Tokens.Typography.subheadline)
                            .padding(.horizontal, Tokens.Spacing.s4)
                            .frame(minHeight: Tokens.Layout.minTapTarget)
                            .background(
                                selected ? AnyShapeStyle(Tokens.Palette.brand) : AnyShapeStyle(Tokens.Palette.surfaceSecondary),
                                in: Capsule()
                            )
                            .foregroundStyle(selected ? Tokens.Palette.onBrand : Tokens.Palette.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.title)
                    .accessibilityHint("Searches for \(preset.searchQuery.lowercased()) near the midpoint")
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal)
        }
        .sensoryFeedback(.selection, trigger: selectedCategory)
    }

    private var resultsScroll: some View {
        ScrollView {
            // Lazy: result cards carry shadows and action rows — rendering
            // every card during an interactive sheet resize dropped frames
            // exactly when the search bar had text (device feedback: "you
            // can feel the stops"; the empty state has light content and
            // stayed smooth).
            LazyVStack(spacing: Tokens.Spacing.s3) {
                if searchState == .idle {
                    presenceControls
                    discoverySections
                } else if searchState == .results || isSearchLoading {
                    resultsList
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        // Below the top detent a live scroll view negotiates scroll-vs-
        // resize on every drag frame, which reads as mid-gesture stops.
        // Scoped to the RESULTS state (the heavy content that stuttered) —
        // the idle discovery stack must stay scrollable at the half detent
        // or its lower rows become unreachable on smaller devices
        // (post-push audit at 42fdc68).
        .scrollDisabled(searchState == .results && selectedSheetDetent != .fraction(0.90))
    }

    @ViewBuilder
    private var presenceControls: some View {
        if isUserIn {
            Button(role: .destructive, action: leave) {
                Label("Leave", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.tweenPrimary(.destructive))
            .accessibilityHint("Stops sharing your location")
        } else {
            Button(action: imIn) {
                if awaitingImIn || provider.status == .requesting {
                    HStack(spacing: Tokens.Spacing.s2) {
                        ProgressView()
                        Text("Finding you...")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label("I'm in", systemImage: "location.fill")
                        .symbolEffect(.bounce, value: isUserIn)
                }
            }
            .buttonStyle(.tweenPrimary())
            .disabled(awaitingImIn || provider.status == .requesting)
            .accessibilityHint("Shares where you are and finds fair places to meet")

            // Join with a place you're HEADING to instead of where you are now
            // (a plan for later while you're driving).
            Button { activeSheet = .whereIllBe } label: {
                Text("or share where you'll be")
                    .font(Tokens.Typography.footnote.weight(.medium))
                    .foregroundStyle(Tokens.Palette.brand)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Join with an address you're heading to instead of your current location")
        }

        Text(statusText)
            .font(Tokens.Typography.footnote)
            .foregroundStyle(Tokens.Palette.textSecondary)
            .multilineTextAlignment(.center)

        if let peerDistanceText {
            Label(peerDistanceText, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                .font(Tokens.Typography.footnote.weight(.medium))
                .foregroundStyle(Tokens.Palette.textSecondary)
                .padding(.horizontal, Tokens.Spacing.s3)
                .padding(.vertical, Tokens.Spacing.s2)
                .background(Tokens.Palette.surfaceSecondary, in: Capsule())
                .accessibilityLabel(peerDistanceText)
        }

        // Solo "A→B, see what's in between": add any address or where a friend
        // is, and get the distance + fair spots between — no ping sent.
        ForEach(manualParticipants) { point in
            routePointChip(point)
        }
        Button { activeSheet = .addPoint } label: {
            Label(manualParticipants.isEmpty ? "Add a place or person" : "Add another point",
                  systemImage: "plus.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.tweenPrimary(.subtle))
        .accessibilityHint("Add an address or where a friend is to see the distance and fair spots in between — nothing is sent")
    }

    /// A removable chip for one added A→B point, with its straight-line distance.
    private func routePointChip(_ point: Participant) -> some View {
        HStack(spacing: Tokens.Spacing.s2) {
            Image(systemName: "mappin.circle.fill")
                .foregroundStyle(Tokens.Palette.brand)
            Text(point.name)
                .font(Tokens.Typography.footnote.weight(.medium))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .lineLimit(1)
            if let distance = manualPointDistance(point) {
                Text(distance)
                    .font(Tokens.Typography.caption.monospacedDigit())
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
            Spacer(minLength: 0)
            Button { removeManualPoint(point) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Tokens.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(point.name)")
        }
        .padding(.horizontal, Tokens.Spacing.s3)
        .padding(.vertical, Tokens.Spacing.s2)
        .background(Tokens.Palette.surfaceSecondary, in: Capsule())
    }

    private var discoverySections: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s4) {
            quickSpotSection(title: "Suggested Spot", shortcuts: [Self.suggestedSpot])
            quickSpotSection(title: "Recent Spots", shortcuts: Self.recentSpotShortcuts)
        }
        .padding(.top, Tokens.Spacing.s2)
    }

    private func quickSpotSection(title: String, shortcuts: [QuickSpotShortcut]) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            Text(title)
                .font(Tokens.Typography.captionBold)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .textCase(.uppercase)
                .padding(.horizontal, Tokens.Spacing.s1)

            VStack(spacing: 0) {
                ForEach(Array(shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                    Button {
                        startShortcutSearch(shortcut)
                    } label: {
                        HStack(spacing: Tokens.Spacing.s3) {
                            Image(systemName: shortcut.systemImage)
                                .font(Tokens.Typography.headline)
                                .foregroundStyle(Tokens.Palette.brand)
                                .frame(width: 36, height: 36)
                                .background(Tokens.Palette.brandLight, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(shortcut.title)
                                    .font(Tokens.Typography.headline)
                                    .foregroundStyle(Tokens.Palette.textPrimary)
                                    .lineLimit(1)
                                Text(shortcut.subtitle)
                                    .font(Tokens.Typography.caption)
                                    .foregroundStyle(Tokens.Palette.textSecondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            Image(systemName: "chevron.right")
                                .font(Tokens.Typography.captionBold)
                                .foregroundStyle(Tokens.Palette.textTertiary)
                        }
                        .padding(Tokens.Spacing.s3)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Searches for \(shortcut.query)")

                    if index < shortcuts.count - 1 {
                        Divider()
                            .padding(.leading, 60)
                    }
                }
            }
            .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        if displayedItems.isEmpty, isSearchLoading {
            HStack(spacing: Tokens.Spacing.s2) {
                ProgressView()
                Text("Finding places near you...")
                    .font(Tokens.Typography.footnote)
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Tokens.Spacing.s3)
        } else if displayedItems.isEmpty {
            ContentUnavailableView(
                "No Places Nearby",
                systemImage: "magnifyingglass",
                description: Text("Try a broader search like coffee, food, gas, or groceries."))
                .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            ForEach(displayedItems, id: \.self) { item in
                ResultCard(
                    item: item,
                    rankedSpot: rankedMatch(for: item),
                    userCoord: savedCoordinate,
                    isBest: !rankedSpots.isEmpty && rankedSpots.first?.item == item,
                    bestWorstETA: rankedSpots.map(\.worstETA).min(),
                    onDirections: { openDirections(to: item) },
                    onSendToChat: {
                        sendToChat(SpotSelection(item: item, ranked: rankedMatch(for: item)))
                    })
                    .contentShape(Rectangle())
                    // Tapping the card body (outside its buttons) highlights the
                    // pin and focuses the map, matching a pin tap.
                    .onTapGesture { selectedResult = item }
            }
        }
    }

    /// The map items currently shown in the list — ranked when both coordinates
    /// are known, otherwise the raw search hits. Source of truth for map markers.
    private var displayedItems: [MKMapItem] {
        rankedSpots.isEmpty ? searchResults : rankedSpots.compactMap(\.item)
    }

    private func mapItem(for state: TweenState) -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: state.coordinate))
        item.name = state.text
        return item
    }

    /// The ranked entry for a given map item, when one exists (so the card can
    /// show an ETA chip).
    private func rankedMatch(for item: MKMapItem) -> RankedSpot? {
        rankedSpots.first { $0.item == item }
    }

    /// Pin role for a result:
    /// gold = best fair option, green = closest to the current user, teal = other.
    private func resultRole(for item: MKMapItem) -> TweenPin.Role {
        if rankedSpots.first?.item == item {
            return .fairSpot
        }
        guard let closest = closestDisplayedItemToUser else {
            return .result
        }
        return closest == item ? .closestToUser : .result
    }

    /// Glyph for result pins — the active category's icon when a preset drove the
    /// search, otherwise the role's semantic symbol.
    private func resultSymbol(for item: MKMapItem) -> String {
        let role = resultRole(for: item)
        if role == .result {
            return selectedCategory?.icon ?? role.symbol
        }
        return role.symbol
    }

    private var closestDisplayedItemToUser: MKMapItem? {
        guard let me = savedCoordinate else { return nil }
        let origin = CLLocation(latitude: me.latitude, longitude: me.longitude)
        return displayedItems.min { lhs, rhs in
            let lhsCoord = lhs.placemark.coordinate
            let rhsCoord = rhs.placemark.coordinate
            let lhsDistance = origin.distance(from: CLLocation(latitude: lhsCoord.latitude, longitude: lhsCoord.longitude))
            let rhsDistance = origin.distance(from: CLLocation(latitude: rhsCoord.latitude, longitude: rhsCoord.longitude))
            return lhsDistance < rhsDistance
        }
    }

    /// Apple-Maps-style floating card for the selected pin: name, address, the
    /// A/B distance label, and Send-to-chat / Directions actions. Tapping the body
    /// expands to the full detail sheet; the close button (or tapping the empty
    /// map) deselects.
    @ViewBuilder
    private var compactCard: some View {
        // A tapped search result opens the full place sheet directly (one
        // tap — no intermediate card; device feedback). Only the
        // agreed-meetup / incoming-proposal states float over the map, and
        // only while no result is selected.
        // Owner decision (audit W8): a set meetup and a newer suggestion
        // render TOGETHER — a new proposal does not cancel the agreement.
        VStack(spacing: Tokens.Spacing.s2) {
            if selectedResult == nil {
                if let agreedMeetup, agreedMeetup.kind == .place {
                    compactCardContent(item: mapItem(for: agreedMeetup), ranked: nil, isAgreedMeetup: true)
                }
                if let pendingProposal {
                    proposalCard(for: pendingProposal)
                }
            }
        }
    }

    /// Which in-flight proposal deserves its own card given the agreement
    /// state. Owner decision (audit W8): a new suggestion does NOT cancel a
    /// set meetup — both render. The exclusions are load-bearing:
    /// `saveAgreed` also writes `proposedState = state`, so without the
    /// messageType + same-spot checks every agreement would double-render
    /// as its own "new suggestion".
    static func visiblePendingProposal(proposed: TweenState?, agreed: TweenState?) -> TweenState? {
        guard let proposed, proposed.kind == .place else { return nil }
        guard let agreed else { return proposed }
        guard proposed.messageType == .propose || proposed.messageType == .counter,
              !proposed.sameSpot(as: agreed)
        else { return nil }
        return proposed
    }

    /// The in-flight negotiation, rendered with the same vocabulary the
    /// extension uses: who proposed, agreement progress, and either an
    /// "Agree & reply" CTA or a waiting state — so switching from Messages to
    /// the app never loses the thread of the meetup.
    private func proposalCard(for proposal: TweenState) -> some View {
        let myName = UserProfile.displayName ?? UserName.fallback
        let myID = TweenIdentity.stableID
        let needsMyAgreement = !proposal.isProposer(participantID: myID, name: myName)
            && !proposal.hasAgreed(participantID: myID, name: myName)
        let proposer = proposal.senderName ?? "Your friend"
        return VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                // Over a standing agreement, the header must mark this as a
                // CHANGE ("new spot") so it can't be misread as the plan.
                Text(agreedMeetup != nil
                     ? "\(proposer) suggests a new spot"
                     : (proposal.messageType == .counter ? "\(proposer) suggests instead" : "\(proposer) suggests"))
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .textCase(.uppercase)
                Text(proposal.text)
                    .font(Tokens.Typography.headline)
                    .lineLimit(1)
                if !proposal.agreedNames.isEmpty || !proposal.agreedIDs.isEmpty {
                    Text(agreementProgress(for: proposal))
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
            }
            ABDistanceLabel(
                selfCoord: savedCoordinate,
                peerCoord: peerCoordinate,
                target: proposal.coordinate,
                ranked: nil)
            HStack(spacing: Tokens.Spacing.s2) {
                if needsMyAgreement {
                    Button { agreeToPendingProposal(proposal) } label: {
                        Label("Agree & reply", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.tweenPrimary())
                    .accessibilityHint("Opens Messages with your agreement to \(proposal.text)")
                } else {
                    Label(waitingText(for: proposal), systemImage: "hourglass")
                        .font(Tokens.Typography.captionBold)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: Tokens.Layout.primaryControlHeight)
                        .background(Tokens.Palette.surfaceSecondary, in: Capsule())
                }
                Button { openDirections(to: mapItem(for: proposal)) } label: {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                }
                .buttonStyle(.tweenPrimary(.subtle))
            }
        }
        .padding(Tokens.Spacing.s4)
        .background(Tokens.Palette.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .tweenElevation(.floating)
        .padding(.horizontal)
        .padding(.bottom, Tokens.Layout.sheetPeekHeight + Tokens.Spacing.s2)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func agreementProgress(for proposal: TweenState) -> String {
        let needed = max(proposal.participants.count - 1, 1)
        let have = proposal.agreedIDs.isEmpty ? proposal.agreedNames.count : proposal.agreedIDs.count
        return "\(have) of \(needed) agreed"
    }

    private func waitingText(for proposal: TweenState) -> String {
        let myName = UserProfile.displayName ?? UserName.fallback
        let missing = proposal.missingAgreementNames(excluding: TweenIdentity.stableID, name: myName)
        return missing.isEmpty ? "Waiting for replies" : "Waiting for \(missing.joined(separator: ", "))"
    }

    private func agreeToPendingProposal(_ proposal: TweenState) {
        let selection = SpotSelection(item: mapItem(for: proposal), ranked: nil)
        let incoming = IncomingProposalContext(
            senderName: proposal.senderName,
            senderID: proposal.senderID,
            participants: proposal.participants,
            agreedNames: proposal.agreedNames,
            agreedIDs: proposal.agreedIDs,
            isCounter: false)
        sendAgreeReply(for: selection, incoming: incoming)
    }

    /// The inner card — title, address, A/B (or solo) distance, and the action
    /// buttons — wrapped in a floating glass card for the agreed-meetup /
    /// proposal states (`compactCardContent`).
    private func spotCardInner(item: MKMapItem, ranked: RankedSpot?, isAgreedMeetup: Bool) -> some View {
        let selection = SpotSelection(item: item, ranked: ranked)
        return VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            HStack(alignment: .top, spacing: Tokens.Spacing.s2) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                    Text(item.name ?? "Place")
                        .font(Tokens.Typography.headline)
                        .lineLimit(1)
                    if let address = item.placemark.cleanLine, !address.isEmpty,
                       address != item.name {
                        Text(address)
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if !isAgreedMeetup {
                    Button {
                        selectedResult = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(Tokens.Typography.title2)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Deselect")
                }
            }
            ABDistanceLabel(
                selfCoord: savedCoordinate,
                peerCoord: peerCoordinate,
                target: item.placemark.coordinate,
                ranked: ranked)
            HStack(spacing: Tokens.Spacing.s2) {
                if isAgreedMeetup {
                    Button(role: .destructive, action: leave) {
                        Label("I'm out", systemImage: "location.slash")
                    }
                    .buttonStyle(.tweenPrimary(.subtle))
                } else {
                    Button { sendToChat(selection) } label: {
                        Label("Send to chat", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.tweenPrimary())
                }
                Button { openDirections(to: item) } label: {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                }
                .buttonStyle(isAgreedMeetup ? .tweenPrimary() : .tweenPrimary(.subtle))
            }
        }
    }

    /// The floating card for the agreed-meetup / incoming-proposal states: the
    /// inner content on a glass surface (no longer an opaque black fill),
    /// lifted just above the collapsed sheet.
    private func compactCardContent(item: MKMapItem, ranked: RankedSpot?, isAgreedMeetup: Bool) -> some View {
        let selection = SpotSelection(item: item, ranked: ranked)
        return spotCardInner(item: item, ranked: ranked, isAgreedMeetup: isAgreedMeetup)
            .padding(Tokens.Spacing.s4)
            .modifier(TweenCardSurface())
            .padding(.horizontal)
            // Float just above the collapsed sheet. Both this padding and the
            // peek detent are measured from the bottom safe-area edge, so the
            // gap is the same on every device.
            .padding(.bottom, Tokens.Layout.sheetPeekHeight + Tokens.Spacing.s2)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isAgreedMeetup else { return }
                activeSheet = .spot(selection)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityHint(isAgreedMeetup ? "Current agreed meetup" : "Tap for full details, or send this spot to your chat")
    }

    private var statusText: String {
        if !monitor.isOnline {
            return "You're offline. Reconnect to find meetup spots."
        }
        switch provider.status {
        case .denied:
            return "Location access is off. Enable it in Settings to share where you are."
        case .failed:
            return "Couldn't get your location. Try again."
        default:
            break
        }
        if isUserIn {
            if peerCoordinate != nil {
                return "You're both in. Search for a fair spot between you."
            }
            return "You're in. Waiting for your friend to share their location…"
        }
        return "Tap “I'm in” to share where you are and find fair places to meet."
    }

    private var activeParticipantsForDisplay: [Participant] {
        var participants = currentParticipants
        let myName = UserProfile.displayName ?? UserName.fallback
        let localContext = LocalParticipantContext(id: TweenIdentity.stableID, name: myName)
        if isUserIn, let coordinate = savedCoordinate, !participants.contains(where: { $0.matches(localContext) }) {
            participants.append(Participant(id: TweenIdentity.stableID, name: myName, coordinate: coordinate, needsRide: localNeedsRide))
        }
        // Legacy 2-person projection: only synthesise a peer when the roster
        // carries NO remote participant. The old `$0.name == peerDisplayName`
        // guard broke once F2 sanitised the display name — it compared "Friend"
        // against the raw ""/"You" roster entry, never matched, and double-listed
        // the peer (inflating "N in"). Identity-based, and never a display string
        // as an id.
        if let peerCoordinate, !participants.contains(where: { !isLocalParticipant($0) }) {
            participants.append(Participant(id: "peer", name: peerDisplayName, coordinate: peerCoordinate, needsRide: peerNeedsRide))
        }
        return participants.sorted { lhs, rhs in
            if isLocalParticipant(lhs) { return true }
            if isLocalParticipant(rhs) { return false }
            if lhs.needsRide != rhs.needsRide { return lhs.needsRide && !rhs.needsRide }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var pendingInvitesForDisplay: [PendingInviteRow] {
        let activeNames = Set(activeParticipantsForDisplay.map { $0.name.lowercased() })
        var rows = friends.compactMap { friend -> PendingInviteRow? in
            guard let sentAt = PingLog.lastPing(for: friend.id),
                  !activeNames.contains(friend.name.lowercased())
            else { return nil }
            return PendingInviteRow(
                id: friend.id.uuidString,
                name: friend.name,
                sentAt: sentAt,
                count: 1,
                isGeneric: false)
        }

        if let genericSentAt = lastGenericInviteAt,
           lastReplyAt.map({ genericSentAt > $0 }) ?? true {
            let pendingCount = PingLog.lastGenericInviteCount
            rows.append(PendingInviteRow(
                id: "generic-\(genericSentAt.timeIntervalSince1970)",
                name: pendingCount == 1 ? "Waiting for someone else" : "Waiting for \(pendingCount) people",
                sentAt: genericSentAt,
                count: pendingCount,
                isGeneric: true))
        }

        return rows.sorted { $0.sentAt > $1.sentAt }
    }

    private var pendingInvitePersonCount: Int {
        pendingInvitesForDisplay.reduce(0) { $0 + $1.count }
    }

    private var pickupRiders: [Participant] {
        activeParticipantsForDisplay.filter(\.needsRide)
    }

    private var rideDrivers: [Participant] {
        activeParticipantsForDisplay.filter { !$0.needsRide }
    }

    private func rideSubtitle(for participant: Participant) -> String {
        if participant.needsRide {
            if let driver = nearestDriver(to: participant) {
                let distance = ABDistanceLabel.formatDistance(from: participant.coordinate, to: driver.coordinate)
                return "Closest pickup: \(driver.name), \(distance) away"
            }
            return "Waiting for someone who can drive"
        }
        if pickupRiders.isEmpty {
            return "No pickup requests"
        }
        if let rider = nearestRider(for: participant) {
            let distance = ABDistanceLabel.formatDistance(from: participant.coordinate, to: rider.coordinate)
            return "Nearest pickup: \(rider.name), \(distance) away"
        }
        return "Available for pickup"
    }

    private func nearestDriver(to rider: Participant) -> Participant? {
        rideDrivers.min { lhs, rhs in
            distance(from: lhs.coordinate, to: rider.coordinate) < distance(from: rhs.coordinate, to: rider.coordinate)
        }
    }

    private func nearestRider(for driver: Participant) -> Participant? {
        pickupRiders.min { lhs, rhs in
            distance(from: lhs.coordinate, to: driver.coordinate) < distance(from: rhs.coordinate, to: driver.coordinate)
        }
    }

    private func distance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private var peerDistanceText: String? {
        guard let savedCoordinate, let peerCoordinate else { return nil }
        let distance = ABDistanceLabel.formatDistance(from: savedCoordinate, to: peerCoordinate)
        return "Distance between you: \(distance)"
    }

    // MARK: - Actions

    private func imIn() {
        ensureNamed {
            // A live GPS join clears any declared "I'll be at…" so the fresh fix
            // takes over.
            selfIsManual = false
            selfManualLabel = nil
            awaitingImIn = true
            provider.requestOnce()
        }
    }

    /// Joins the meetup with a DECLARED future location (a place you're heading
    /// to) instead of live GPS — "I'll be at…". The declared coordinate is
    /// freshness-exempt (LocationCache.isManual) so it travels in the bubble and
    /// isn't overwritten by a background GPS fix.
    private func setManualSelf(_ point: Participant) {
        ensureNamed {
            // Cancel any in-flight GPS request so its late .got can't overwrite
            // this declaration (the .got guard keys on !awaitingImIn).
            awaitingImIn = false
            pendingLocationAction = nil
            let coord = point.coordinate
            selfIsManual = true
            selfManualLabel = point.name
            savedCoordinate = coord
            savedCoordinateAt = Date()
            isUserIn = true
            LocationCache.save(coord, isActive: true, isManual: true)
            saveLocalParticipant(coord)   // this is what travels to the group
            withAnimation(Tokens.Motion.spring) {
                position = Self.cameraPosition(for: [coord])
            }
            showToast("You'll be at \(point.name)")
        }
    }

    // MARK: - Profile name

    /// Persists the Friends-tab name field (clearing it when blank).
    private func saveProfileName() {
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        UserProfile.displayName = trimmed.isEmpty ? nil : trimmed
    }

    /// Runs `action` immediately when a display name is set; otherwise prompts
    /// for one first and runs `action` after the user saves it.
    private func ensureNamed(_ action: @escaping () -> Void) {
        if let name = UserProfile.displayName, !name.isEmpty {
            action()
        } else {
            nameDraft = profileName
            pendingNameAction = action
            showNamePrompt = true
        }
    }

    private func saveName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            UserProfile.displayName = trimmed
            profileName = trimmed
        }
        pendingNameAction?()
        pendingNameAction = nil
    }

    /// Auto-requests location on launch so the map opens on the user's real
    /// location instead of a generic default. Prompts on first launch
    /// (`requestOnce` handles the authorization branch internally); silent on
    /// subsequent launches once granted. Skipped when we already have a fresh
    /// shared coordinate, so an active "I'm in" session isn't disturbed.
    /// -DEMO_SPOT_SHEET: runs a real MKLocalSearch on launch and opens the
    /// full place sheet for the first hit — screenshot/UI-test hook for the
    /// rich native place-detail layout, which needs a REAL place identifier
    /// (the coordinate-only demo pin can't exercise it).
    private func openDemoSpotSheetIfRequested() async {
        #if DEBUG
        // -DEMO_ROUTE_AB seeded one added point at init; also seed a self
        // location (in the cache, so the poll keeps it) and run a real search so
        // the solo A→B ranking (fair spots between the two) renders.
        if CommandLine.arguments.contains("-DEMO_ROUTE_AB") {
            let sanJose = CLLocationCoordinate2D(latitude: 37.3382, longitude: -121.8863)
            LocationCache.save(sanJose, isActive: true)
            savedCoordinate = sanJose
            await runSearch(trimmed: "coffee", reframeMap: true)
            return
        }
        // -DEMO_CATEGORY_STUDY: seeds two points then taps the Study chip —
        // screenshot hook proving category chips run the POI-category engine
        // (libraries/cafés BETWEEN the points, not a dead text search).
        if CommandLine.arguments.contains("-DEMO_CATEGORY_STUDY") {
            let sanJose = CLLocationCoordinate2D(latitude: 37.3382, longitude: -121.8863)
            LocationCache.save(sanJose, isActive: true)
            savedCoordinate = sanJose
            manualParticipants = [Participant.manual(label: "Adams Center",
                coordinate: CLLocationCoordinate2D(latitude: 37.28, longitude: -121.95))]
            selectCategory(.study)
            return
        }
        // -DEMO_SOLO_AFTER_LEAVE: regression for the "ranking wiped on refresh"
        // device bug. Seeds a LEFT-meetup tombstone in the active conversation,
        // then a solo A→B search (self + one added place). The leave tombstone
        // makes refreshFromAppGroup's localLeft branch clear rankedSpots on every
        // poll tick, so the fresh solo ranking flickers away ~2 s after it lands.
        if CommandLine.arguments.contains("-DEMO_SOLO_AFTER_LEAVE") {
            let key = ConversationMeetupStore.conversationKey(localID: "me", remotes: ["friend"])
            ConversationMeetupStore.lastActiveConversationKey = key
            ConversationMeetupStore.save(MeetupSnapshot(
                conversationKey: key,
                participants: [Participant(id: "friend", name: "Friend",
                    coordinate: CLLocationCoordinate2D(latitude: 39.05, longitude: -77.5))]))
            ConversationMeetupStore.setLocalUserLeft(true, key: key)
            let sanJose = CLLocationCoordinate2D(latitude: 37.3382, longitude: -121.8863)
            LocationCache.save(sanJose, isActive: true)
            savedCoordinate = sanJose
            manualParticipants = [Participant.manual(label: "Adams Center",
                coordinate: CLLocationCoordinate2D(latitude: 37.28, longitude: -121.95))]
            await runSearch(trimmed: "coffee", reframeMap: true)
            return
        }
        // -DEMO_SPOT_CARD seeded a selection at init, which never fires
        // onChange — present its sheet here (fallback layout, no identifier).
        if CommandLine.arguments.contains("-DEMO_SPOT_CARD"), let item = selectedResult {
            // -DEMO_SPOT_GROUP seeds a 4-person ranking so the place sheet shows
            // the per-person time chips + drive-balance track (audit F1) — the
            // host used to cap this at two people. Screenshot hook only.
            let ranked = CommandLine.arguments.contains("-DEMO_SPOT_GROUP")
                ? RankedSpot(item: item, etas: [
                    ParticipantETA(id: "you", name: "You", eta: 480, fromRoute: true),
                    ParticipantETA(id: "kavi", name: "Kavi", eta: 720, fromRoute: true),
                    ParticipantETA(id: "maya", name: "Maya", eta: 600, fromRoute: true),
                    ParticipantETA(id: "sam", name: "Sam", eta: 960, fromRoute: true)
                  ], confidence: 1.0)
                : nil
            activeSheet = .spot(SpotSelection(item: item, ranked: ranked))
            return
        }
        guard CommandLine.arguments.contains("-DEMO_SPOT_SHEET") else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "coffee"
        request.region = MKCoordinateRegion(
            center: savedCoordinate ?? Self.defaultCenter,
            span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3))
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return }
        activeSheet = .spot(SpotSelection(item: item, ranked: nil))
        #endif
    }

    private func requestInitialLocation() {
        guard !(savedCoordinate != nil && LocationCache.isActive) else { return }
        provider.requestOnce()
    }

    private func leave() {
        let myName = UserProfile.displayName ?? UserName.fallback
        let localContext = LocalParticipantContext(id: TweenIdentity.stableID, name: myName)
        let roster = scopedFirstRoster()
        let fallbackCoordinate = LocationCache.loadSelf()?.coordinate
            ?? roster.first(where: { $0.matches(localContext) })?.coordinate
            ?? Self.defaultCenter
        let remainingParticipants = roster.filter { !$0.matches(localContext) }
        if remainingParticipants.isEmpty && !hasSharedPlanToCancel {
            commitLeaveLocally(remaining: [], revision: nil)
            showToast("You're out")
            return
        }
        // Nothing commits here. Leaving takes effect only once the leave
        // bubble is actually sent (commitLeaveLocally, via onSent) — the same
        // didSend gating the extension uses. Committing up front left this
        // device "out" with no leave bubble in the chat when the composer was
        // cancelled: a split-brain the peers could never repair.
        presentLeaveMessage(participants: remainingParticipants, fallbackCoordinate: fallbackCoordinate)
    }

    private var hasSharedPlanToCancel: Bool {
        if pendingProposal != nil || agreedMeetup != nil { return true }
        guard let key = ConversationMeetupStore.lastActiveConversationKey,
              let snapshot = ConversationMeetupStore.load(key: key),
              Date().timeIntervalSince(snapshot.updatedAt) <= ConversationMeetupStore.snapshotTTL
        else { return false }
        return snapshot.proposedState != nil || snapshot.agreedState != nil
    }

    private func presentLeaveMessage(participants: [Participant],
                                     fallbackCoordinate: CLLocationCoordinate2D) {
        let revision = nextOutgoingRevisionForActiveConversation()
        let state = TweenState(
            text: "I'm out",
            latitude: fallbackCoordinate.latitude,
            longitude: fallbackCoordinate.longitude,
            senderName: UserProfile.displayName,
            senderID: TweenIdentity.stableID,
            kind: .participant,
            messageType: .leave,
            participants: participants,
            revision: revision
        )

        guard MFMessageComposeViewController.canSendText() else {
            UIPasteboard.general.string = "I'm out of this meetup."
            showToast("Messages unavailable - copied an I'm out reply")
            return
        }

        Task { @MainActor in
            guard let message = await composeTweenMessage(
                for: state, totalSeats: max(participants.count + 1, 2)) else { return }
            activeSheet = .message(PendingMessage(
                recipients: [],
                body: "I'm out of this meetup.",
                message: message,
                onSent: {
                    commitLeaveLocally(remaining: participants, revision: revision)
                },
                onCancelled: {
                    // Leaving IS a message in a serverless app — without the
                    // bubble, nobody can ever learn you left. Say so.
                    showToast("You're still in — your I'm out wasn't sent")
                }))
        }
    }

    /// The local effects of leaving, applied only after the leave bubble was
    /// actually sent. Keeps the REMAINING roster rather than wiping to [] —
    /// the meetup is still live for everyone else (group-session semantics),
    /// and an empty roster made the next rejoin broadcast just [me], erasing
    /// the group on every device that tapped it. "Out" is expressed by
    /// membership + the leave tombstone, not by roster emptiness.
    private func commitLeaveLocally(remaining: [Participant], revision: Int?) {
        withAnimation(Tokens.Motion.spring) { isUserIn = false }
        localNeedsRide = false
        let myName = UserProfile.displayName ?? UserName.fallback
        let localContext = LocalParticipantContext(id: TweenIdentity.stableID, name: myName)
        noteOutgoingRevision(revision)
        if let key = ConversationMeetupStore.lastActiveConversationKey {
            // The rejoin roster (D4) lives in the SCOPED snapshot only.
            ConversationMeetupStore.saveParticipants(remaining, key: key)
            ConversationMeetupStore.clearProposalState(key: key)
            // Tombstone: stale peer rosters must not re-add this user as "in".
            ConversationMeetupStore.setLocalUserLeft(true, key: key)
        }
        // The GLOBAL mirrors never keep a departed conversation's roster:
        // they have no TTL, so a roster parked there outlived the scoped
        // snapshot's 24 h window and resurrected the departed peer in
        // ranking/banners once the provenance gate lost its snapshot (audit
        // at 18c182a). Rejoin reads the scoped snapshot (saveLocalParticipant),
        // so clearing here costs nothing.
        LocationCache.clearParticipants()
        LocationCache.setPeerActive(false)
        LocationCache.deactivateSelf()
        LocationCache.clearAgreedMeetup()
        agreedMeetup = nil
        selectedResult = nil
        // Explicit, not just via the refresh below — the recompute path
        // depends on lastActiveConversationKey being set, and a stale
        // proposal card surviving a leave is exactly the "leftover state
        // after I'm out" the device feedback flagged.
        pendingProposal = nil
        // Fairness rankings were computed against the meetup you just left —
        // an open results list must drop its "You X min | Sam Y min" chips
        // immediately, not keep scoring spots against the departed friend
        // (device feedback: leaving must fully reset).
        rankedSpots = []
        // A staged "Send to chat" hand-off is a pending message; leaving must
        // not let the extension re-adopt it within its 15-min handoff window.
        OutgoingDraftStore.clear()
        _ = refreshFromAppGroup()
    }

    /// Mints the next outgoing payload revision for the most recently active
    /// conversation, mirroring the extension. Deliberately NOT recorded at
    /// mint time — `noteOutgoingRevision` runs in the composer's onSent so a
    /// cancelled send never burns a revision (burned revisions made the
    /// peer's genuinely-new bubbles decode as stale and vanish).
    private func nextOutgoingRevisionForActiveConversation() -> Int? {
        guard let key = ConversationMeetupStore.lastActiveConversationKey else { return nil }
        return ConversationMeetupStore.lastRevision(key: key) + 1
    }

    private func noteOutgoingRevision(_ revision: Int?) {
        guard let revision, let key = ConversationMeetupStore.lastActiveConversationKey else { return }
        ConversationMeetupStore.noteRevision(revision, sender: TweenIdentity.stableID, key: key)
    }

    /// Builds the Tween-styled `MSMessage` for a state: renders the bubble
    /// image, applies the caption layout, and attaches the payload URL. The
    /// single composer behind every host-app send — this block used to be
    /// copy-pasted at five call sites. Returns nil when the payload can't be
    /// encoded: never ship a payload-less bubble, the recipient's extension
    /// would decode nothing from the tapped message.
    private func composeTweenMessage(for state: TweenState, totalSeats: Int) async -> MSMessage? {
        // Departure gossip, mirroring the extension's deliverBubble: outgoing
        // payloads carry this device's tombstones so any later tap anywhere
        // in the group propagates removals.
        var outgoing = state
        if let key = ConversationMeetupStore.lastActiveConversationKey {
            outgoing.departed = RosterMerge.gossipKeys(
                departed: ConversationMeetupStore.departedParticipants(key: key),
                roster: state.participants)
        }
        let image = await BubbleImageRenderer.makeImage(
            state: state,
            participants: state.participants,
            localName: UserProfile.displayName ?? UserName.fallback)
        let layout = MSMessageTemplateLayout()
        layout.image = image
        BubbleCaption.apply(to: layout, state: state, totalSeats: totalSeats)
        // https, never tween:// — MSMessage.url is resolved by recipients
        // without the app (and macOS Messages) through the browser fallback,
        // and the hard constraint mandates https/file. The extension already
        // sends https; the decoder accepts both.
        guard let bubbleURL = outgoing.encodedURL() else { return nil }
        let message = MSMessage()
        message.url = bubbleURL
        message.layout = layout
        return message
    }

    /// The conversation-scoped roster when FRESH, else the legacy global
    /// blob. The scoped snapshot is authoritative — it alone survives a
    /// leave, carrying the D4 rejoin roster (the global mirrors are dammed
    /// while the tombstone is set) — but a snapshot past its TTL is history,
    /// not a live meetup, and must not be rebroadcast as current (audit at
    /// 69a3886). One helper so every outgoing-roster read agrees.
    private func scopedFirstRoster() -> [Participant] {
        if let key = ConversationMeetupStore.lastActiveConversationKey,
           let snapshot = ConversationMeetupStore.load(key: key),
           Date().timeIntervalSince(snapshot.updatedAt) <= ConversationMeetupStore.snapshotTTL {
            return snapshot.participants
        }
        return LocationCache.loadParticipants()
    }

    private func saveLocalParticipant(_ coordinate: CLLocationCoordinate2D) {
        let myName = UserProfile.displayName ?? UserName.fallback
        let localContext = LocalParticipantContext(id: TweenIdentity.stableID, name: myName)
        let participants = scopedFirstRoster().filter { !$0.matches(localContext) } + [
            Participant(id: TweenIdentity.stableID, name: myName, coordinate: coordinate, needsRide: localNeedsRide)
        ]
        if let key = ConversationMeetupStore.lastActiveConversationKey {
            ConversationMeetupStore.saveParticipants(participants, key: key)
            // Opting in clears the leave tombstone — BEFORE the global
            // write below, which LocationCache dams while it's set
            // (audit at 69a3886).
            ConversationMeetupStore.setLocalUserLeft(false, key: key)
        }
        LocationCache.saveParticipantSnapshot(participants, localContext: localContext)
        currentParticipants = participants
    }

    private func setNeedsRide(_ needsRide: Bool) {
        // Requires being IN, not just having a cached coordinate: the ride
        // toggle used to auto-rejoin (and clear the leave tombstone) for a
        // user who had explicitly said "I'm out" — a silent resurrection.
        guard isUserIn else {
            showToast("Tap I'm in first so friends know where to pick you up")
            return
        }
        // Fresh-only: a ride update broadcasts a pickup point, so a stale
        // coordinate must not ride along (audit W4). Park + request a fresh
        // fix and resume, rather than sending an old location.
        guard let coordinate = freshSelfCoordinateForSend else {
            pendingLocationAction = { setNeedsRide(needsRide) }
            provider.requestOnce()
            showToast("Getting your location — updating your ride status right after")
            return
        }
        localNeedsRide = needsRide
        saveLocalParticipant(coordinate)
        _ = refreshFromAppGroup()
        presentRideStatusMessage(needsRide: needsRide, coordinate: coordinate)
        showToast(needsRide ? "Ride request ready to send" : "Ride update ready to send")
    }

    private func presentRideStatusMessage(needsRide: Bool, coordinate: CLLocationCoordinate2D) {
        let myName = UserProfile.displayName ?? UserName.fallback
        let participants = scopedFirstRoster()
        let revision = nextOutgoingRevisionForActiveConversation()
        let state = TweenState(
            text: needsRide ? "I need a ride" : "I can meet there",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            senderName: UserProfile.displayName,
            senderID: TweenIdentity.stableID,
            kind: .participant,
            messageType: .invite,
            participants: participants,
            revision: revision
        )

        guard MFMessageComposeViewController.canSendText() else {
            UIPasteboard.general.string = needsRide
                ? "\(myName) needs a ride for this Tween meetup."
                : "\(myName) can meet there for this Tween meetup."
            showToast("Messages unavailable - copied the ride update")
            return
        }

        Task { @MainActor in
            guard let message = await composeTweenMessage(
                for: state, totalSeats: max(participants.count, 2)) else { return }
            activeSheet = .message(PendingMessage(
                recipients: [],
                body: needsRide ? "\(myName) needs a ride." : "\(myName) can meet there.",
                message: message,
                onSent: {
                    noteOutgoingRevision(revision)
                    showToast(needsRide ? "Ride request sent" : "Ride update sent")
                },
                onCancelled: {
                    showToast(needsRide ? "Ride request not sent" : "Ride update not sent")
                }))
        }
    }

    // MARK: - Hand-off

    /// Centers the map on a tapped result and sizes the sheet to the spot card
    /// (which now renders AS the sheet). The camera is biased so the pin clears
    /// the taller card; the reset-map control can still pull back to the route.
    private func focusMap(on item: MKMapItem) {
        withAnimation(Tokens.Motion.gentle) {
            position = Self.placeCameraPosition(for: item.placemark.coordinate, bottomBias: 0.18)
        }
        withAnimation(Tokens.Motion.snappy) { selectedSheetDetent = .height(Tokens.Layout.sheetPeekHeight) }
    }

    /// Frames the camera to fit every visible result pin (Map mode).
    private func frameResults() {
        let coords = displayedItems.map(\.placemark.coordinate)
        guard !coords.isEmpty else { return }
        withAnimation(Tokens.Motion.gentle) { position = Self.cameraPosition(for: coords, padding: 1.35) }
    }

    /// Frames the social context plus the visible search hits, so the result list
    /// and map feel connected as soon as a live search returns.
    private func frameSearchResults() {
        let resultCoords = displayedItems.prefix(Self.rankCap).map(\.placemark.coordinate)
        let context = [savedCoordinate, peerCoordinate].compactMap { $0 } + manualParticipants.map(\.coordinate)
        let coords = context + resultCoords
        guard !coords.isEmpty else { return }
        withAnimation(Tokens.Motion.gentle) {
            position = Self.cameraPosition(for: coords, padding: 1.45, minSpan: 0.04)
        }
    }

    private func expandToSearchDetent() {
        guard isMinimalDetent else { return }
        withAnimation(Tokens.Motion.snappy) { selectedSheetDetent = .fraction(0.45) }
    }

    /// Expand-then-focus (`docs/ui-research.md` §7): first drive the sheet
    /// to the search detent, then wait for the sheet's detent animation to
    /// finish before setting `@FocusState`. SwiftUI drops the first responder
    /// if a sheet is still animating between detents when focus is requested,
    /// so setting both in the same synchronous block silently no-ops.
    ///
    /// `Tokens.Motion.snappy` is a 400 ms `.easeInOut` (see
    /// `Shared/Tokens.swift:148`), so we wait 450 ms — a small margin past
    /// the animation's end. The pending focus task is retained on `self` so
    /// a rapid re-entry cancels the prior one; otherwise a user who backs
    /// out of the sheet between call and fire would get an unexpected
    /// keyboard.
    private func expandThenFocusSearch() {
        withAnimation(Tokens.Motion.snappy) {
            selectedSheetDetent = .fraction(0.45)
        }
        focusExpandTask?.cancel()
        focusExpandTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450 * 1_000_000)
            guard !Task.isCancelled else { return }
            searchFocused = true
        }
    }

    /// Frames every result pin PLUS self and peer, biased upward so the pins
    /// clear the bottom sheet. Called on every committed search (both view
    /// modes) so the map is correctly positioned the instant the sheet is
    /// lowered — in list mode the sheet snaps to full and covers most of the
    /// map, so this framing is what the user sees the moment they drag down or
    /// tap a result card.
    private func frameResultsWithParticipants() {
        var coords = displayedItems.map(\.placemark.coordinate)
        if let me = savedCoordinate { coords.append(me) }
        if let peer = peerCoordinate { coords.append(peer) }
        coords.append(contentsOf: manualParticipants.map(\.coordinate))
        guard !coords.isEmpty else { return }
        withAnimation(Tokens.Motion.gentle) {
            position = Self.cameraPosition(for: coords, bottomBias: 0.35)
        }
    }

    /// Composes a pre-filled iMessage for the chosen spot: a short blurb plus the
    /// `TweenState` deep link the friend's extension decodes. The old `sms:` bounce
    /// opened a blank composer, so the friend received nothing.
    private func sendToChat(_ selection: SpotSelection) {
        ensureNamed {
            guard autoJoinForOutgoingMessage() else {
                // Park the send and resume it the moment the fix arrives —
                // discarding the tap made "Send to chat" feel broken.
                pendingLocationAction = { sendToChat(selection) }
                provider.requestOnce()
                showToast("Getting your location — sending right after")
                return
            }
            let coord = selection.coordinate
            let participants = proposalParticipantsForCurrentContext()
            guard !participants.isEmpty else {
                showToast("Tap I'm in first so your friend has a way to join")
                return
            }
            let revision = nextOutgoingRevisionForActiveConversation()
            let messageType: TweenState.MessageType = agreedMeetup == nil ? .propose : .counter
            let state = TweenState(
                text: selection.name,
                latitude: coord.latitude,
                longitude: coord.longitude,
                senderName: UserProfile.displayName,
                senderID: TweenIdentity.stableID,
                kind: .place,
                senderCoordinate: savedCoordinate,        // set by ensureNamed
                messageType: messageType,
                participants: participants,
                revision: revision)
            guard let appURL = state.encodedURL(scheme: "tween", host: "m") else { return }

            // Still stage the draft so the sender's own extension can pre-fill if
            // they open Tween in the drawer (device-local; not how the friend gets
            // it). Bound to the last-active conversation so no other chat adopts it.
            OutgoingDraftStore.save(OutgoingDraft(
                spotName: selection.name,
                latitude: coord.latitude,
                longitude: coord.longitude,
                conversationKey: ConversationMeetupStore.lastActiveConversationKey))

            if MFMessageComposeViewController.canSendText() {
                Task { @MainActor in
                    guard let message = await composeTweenMessage(
                        for: state, totalSeats: max(participants.count, 2)) else { return }
                    // Route through the existing enum-driven sheet; empty recipients so
                    // the user picks who in Messages (no selected-friend concept here).
                    activeSheet = .message(PendingMessage(
                        recipients: [],
                        // The plain-text body carries a universal Apple Maps link
                        // so anyone in the chat — including people without Tween —
                        // can tap for directions (the rich bubble is app-only).
                        body: Self.spotBody(prefix: "Let's meet at", name: selection.name, coordinate: coord),
                        message: message,
                        onSent: {
                            noteOutgoingRevision(revision)
                            if let key = ConversationMeetupStore.lastActiveConversationKey {
                                ConversationMeetupStore.saveProposed(state, key: key)
                            }
                            pendingProposal = state
                            if messageType == .counter {
                                LocationCache.clearAgreedMeetup()
                                agreedMeetup = nil
                            }
                            PingLog.logGenericInvite()
                            lastGenericInviteAt = PingLog.lastGenericInviteAt
                            showOwnProposalOnMap(state)
                        },
                        onCancelled: {
                            // Cancel rollback: the staged hand-off must die with
                            // the send, or the extension force-expands over a
                            // proposal the user abandoned (W7).
                            OutgoingDraftStore.clear()
                            showToast("Not sent — your proposal stayed here")
                        }))
                }
            } else {
                let who = UserProfile.displayName ?? "I"
                let body = """
                \(who) picked \(selection.name) on Tween.
                Open this in Tween to share your ping:
                \(appURL.absoluteString)
                """
                UIPasteboard.general.string = body
                showToast("Message copied — paste it into your chat")
            }
        }
    }

    /// The coordinate safe to embed in an outgoing payload as "where I am
    /// now": the in-memory fix if we know it's fresh, else the cache's own
    /// fresh coordinate. Nil when everything we have is stale/absent — the
    /// caller must then request a fresh fix rather than shipping an old one.
    /// This is the single funnel that stops stale-coordinate laundering on
    /// the host side (audit W4).
    private var freshSelfCoordinateForSend: CLLocationCoordinate2D? {
        if let saved = savedCoordinate, let at = savedCoordinateAt,
           Date().timeIntervalSince(at) <= LocationCache.freshnessWindow {
            return saved
        }
        return LocationCache.freshSelfCoordinate()
    }

    @discardableResult
    private func autoJoinForOutgoingMessage() -> Bool {
        // Only join with a coordinate we KNOW is current. This used to reuse
        // a cached coord of ANY age and re-save it isActive:true with a
        // now-timestamp — laundering a stale location into the outgoing
        // bubble and defeating the 5-min freshness window the fairness
        // ranking depends on (audit W4, host half). No fresh fix → return
        // false; callers park the action + requestOnce(), then resume once a
        // current coordinate lands (their existing no-coordinate path).
        guard let coordinate = freshSelfCoordinateForSend else { return false }
        withAnimation(Tokens.Motion.spring) {
            savedCoordinate = coordinate
            savedCoordinateAt = Date()
            isUserIn = true
        }
        // Preserve declared-location provenance on re-save — dropping it here
        // stripped isManual on the first proposal/agree, after which the poll
        // and a background GPS fix clobbered the "I'll be at…" pin (post-push
        // audit).
        LocationCache.save(coordinate, isActive: true, isManual: selfIsManual)
        saveLocalParticipant(coordinate)
        return true
    }

    private func proposalParticipantsForCurrentContext() -> [Participant] {
        let myName = UserProfile.displayName ?? UserName.fallback
        let localContext = LocalParticipantContext(id: TweenIdentity.stableID, name: myName)
        var participants = scopedFirstRoster().filter { !$0.matches(localContext) }
        if let savedCoordinate {
            participants.append(Participant(id: TweenIdentity.stableID, name: myName, coordinate: savedCoordinate, needsRide: localNeedsRide))
        }
        return participants
    }

    /// Opens Apple Maps with driving directions to the chosen spot.
    private func openDirections(to item: MKMapItem) {
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }

    private func dismissTutorial() {
        OnboardingFlags.hasSeenOnboarding = true
        showTutorial = false
    }

    // MARK: - Friends

    /// Pings a friend with a Tween-styled "I'm in" iMessage bubble pre-filled
    /// in the composer (not a plain text). On iMessage the recipient sees the
    /// full rich bubble — same UX as if it had been composed from inside the
    /// Messages extension. SMS-only handles still see `Self.inviteText` as a
    /// plain-text fallback.
    ///
    /// Falls back to plain text if (a) we have no fresh self coord to put in
    /// the bubble, (b) MSMessage rendering fails, or (c) the device can't send
    /// text at all (no SIM / no iMessage).
    /// Inviting a friend is a first-compose path, so gate on a name too (audit
    /// F2 step 1) — the same one-time prompt `imIn`/`sendToChat` use — before we
    /// put the user on anyone's roster.
    private func pingFriend(_ friend: TweenFriend) {
        ensureNamed { self.performPing(friend) }
    }

    private func performPing(_ friend: TweenFriend) {
        pingTick += 1

        guard let handle = friend.handle, MFMessageComposeViewController.canSendText() else {
            UIPasteboard.general.string = Self.inviteText
            let reason = friend.handle == nil ? "No phone number" : "Messages unavailable"
            showToast("\(reason) - invite copied for \(friend.name)")
            return
        }

        // No FRESH self coord → fall back to the plain-text invite (audit W4:
        // a stale coordinate must not ride into the bubble). The invite still
        // works; your location shares once you're both in. Matches this
        // method's doc contract — "no fresh self coord → plain text".
        guard let myCoord = freshSelfCoordinateForSend else {
            activeSheet = .message(PendingMessage(
                recipients: [handle],
                body: Self.inviteText,
                onSent: {
                    PingLog.logPing(for: friend.id)
                    pingTick += 1
                    showToast("\(friend.name) is pending")
                }))
            return
        }

        let myName = UserProfile.displayName ?? UserName.fallback
        // The last host send path without a revision (audit W9) — without it
        // this bubble decodes under legacy trust-the-tap semantics forever.
        let revision = nextOutgoingRevisionForActiveConversation()
        let state = TweenState(
            text: "I'm in",
            latitude: myCoord.latitude,
            longitude: myCoord.longitude,
            senderName: UserProfile.displayName,
            senderID: TweenIdentity.stableID,
            kind: .participant,
            messageType: .invite,
            participants: [Participant(id: TweenIdentity.stableID, name: myName, coordinate: myCoord, needsRide: localNeedsRide)],
            revision: revision
        )

        // Render the bubble image off the main actor (it's an MKMapSnapshotter
        // round-trip — usually under a second, but we don't want to block).
        // Once ready, build the MSMessage on the main actor and present.
        Task { @MainActor in
            guard let message = await composeTweenMessage(for: state, totalSeats: 2) else { return }
            activeSheet = .message(PendingMessage(
                recipients: [handle],
                body: Self.inviteText,
                message: message,
                onSent: {
                    noteOutgoingRevision(revision)
                    PingLog.logPing(for: friend.id)
                    pingTick += 1
                    showToast("\(friend.name) is pending")
                }))
        }
    }

    private func deleteFriend(_ friend: TweenFriend) {
        FriendRoster.delete(id: friend.id)
        friends = FriendRoster.load()
    }

    private func startRename(_ friend: TweenFriend) {
        renameText = friend.name
        editorMode = .rename(friend)
    }

    private func commitRename() {
        guard case let .rename(friend) = editorMode else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            FriendRoster.rename(id: friend.id, to: trimmed)
            friends = FriendRoster.load()
        }
        editorMode = nil
    }

    /// Bridges optional `editorMode` to the boolean an `alert` needs.
    private var renameBinding: Binding<Bool> {
        Binding(get: { editorMode != nil },
                set: { if !$0 { editorMode = nil } })
    }

    private func showToast(_ message: String) {
        withAnimation(Tokens.Motion.snappy) { toast = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(Tokens.Motion.snappy) { toast = nil }
        }
    }

    // MARK: - Search

    /// Every point that participates in the fair-spot comparison.
    private var comparisonCoordinates: [CLLocationCoordinate2D] {
        var points = [savedCoordinate, peerCoordinate].compactMap { $0 }
        points.append(contentsOf: additionalParticipants.map(\.coordinate))
        points.append(contentsOf: manualParticipants.map(\.coordinate))
        return points
    }

    /// The visible center Tween is searching around when comparing two or more
    /// people/points.
    private var midpointCoordinate: CLLocationCoordinate2D? {
        let points = comparisonCoordinates
        guard points.count >= 2 else { return nil }
        let lats = points.map(\.latitude)
        let lons = points.map(\.longitude)
        return CLLocationCoordinate2D(
            latitude: lats.reduce(0, +) / Double(points.count),
            longitude: lons.reduce(0, +) / Double(points.count))
    }

    /// The region search is biased toward the midpoint when multiple points are
    /// known, otherwise whichever single location we have. A tighter local span
    /// keeps common searches like coffee, food, and gas near the active context.
    private var searchRegion: MKCoordinateRegion {
        let points = comparisonCoordinates
        if points.count >= 2 {
            let lats = points.map(\.latitude), lons = points.map(\.longitude)
            let latDelta = max((lats.max()! - lats.min()!) * 1.35, 0.25)
            let lonDelta = max((lons.max()! - lons.min()!) * 1.35, 0.25)
            return MKCoordinateRegion(
                center: midpointCoordinate ?? Self.defaultCenter,
                span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
        }

        let center = points.first ?? Self.defaultCenter
        let span = points.isEmpty ? 0.5 : 0.18
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
    }

    /// Reacts to each keystroke. An empty field returns to quick chips; anything
    /// else feeds the completer immediately. Full result cards only appear after
    /// Return, a suggestion tap, or a category/shortcut tap.
    private func handleQueryChange(_ query: String) {
        // A programmatic commit (suggestion/category) already started its search;
        // don't let the resulting onChange cancel it or revert to suggestions.
        if suppressNextQueryChange {
            suppressNextQueryChange = false
            return
        }
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            rankedSpots = []
            isSearchActive = false
            isSearchLoading = false
            searchState = .idle
            completer.update(query: "")
            return
        }
        // New query — drop stale committed results so the map clears while typing.
        searchResults = []
        rankedSpots = []
        isSearchActive = false
        isSearchLoading = false
        searchState = .suggesting
        // Debounced (300 ms) — the completer only fires on the query the user
        // paused on, not every intermediate keystroke. Per
        // docs/ui-research.md §7.
        completer.debouncedUpdate(query: trimmed, region: searchRegion)
    }

    /// Commits a suggestion as a full search.
    /// Programmatic `searchText` assignment with the suppress flag armed
    /// ONLY when the text actually changes. Arming unconditionally left the
    /// flag set when the assignment was a no-op (tapping a completion titled
    /// exactly what you typed) — SwiftUI's onChange never fired, and the
    /// stale flag then swallowed the NEXT real change: the clear-(x)
    /// gesture, leaving ghost results behind an empty field (audit W15).
    private func setSearchTextProgrammatically(_ text: String) {
        suppressNextQueryChange = text != searchText
        searchText = text
    }

    private func selectSuggestion(_ completion: MKLocalSearchCompletion) {
        setSearchTextProgrammatically(completion.title)
        commitSearch()
    }

    /// Runs the committed search (keyboard "Search", or a tapped suggestion).
    /// Resigns the keyboard so the result cards / pins are visible.
    private func commitSearch() {
        searchTask?.cancel()
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSearch(trimmed) else { return }
        searchFocused = false
        expandToSearchDetent()
        isSearchLoading = true

        searchTask = Task { @MainActor in
            await runSearch(trimmed: trimmed, reframeMap: true)
        }
    }

    private func focusSearchPanel() {
        expandToSearchDetent()
    }

    private func startShortcutSearch(_ shortcut: QuickSpotShortcut) {
        selectedCategory = nil
        setSearchTextProgrammatically(shortcut.query)
        focusSearchPanel()
        commitSearch()
    }

    /// Clears results and returns `false` when there's nothing to search — an
    /// empty query, or offline (the offline banner gates the field). Returns
    /// `true` when a search should proceed.
    private func canSearch(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty, monitor.isOnline else {
            searchResults = []
            rankedSpots = []
            isSearchActive = false
            isSearchLoading = false
            searchState = .idle
            return false
        }
        // No anchor at all → searchRegion would fall back to the center of the
        // continental US and quietly return results in Kansas. A manually-added
        // A→B point is a valid anchor too — otherwise a GPS-denied user doing a
        // pure manual A→B search got nagged for location even though searchRegion
        // already centers on their points (post-push audit). Ask for a fix only
        // when there's truly nothing to anchor on.
        guard savedCoordinate != nil || peerCoordinate != nil || !manualParticipants.isEmpty else {
            searchResults = []
            rankedSpots = []
            isSearchActive = false
            isSearchLoading = false
            searchState = .idle
            pendingLocationAction = { commitSearch() }
            provider.requestOnce()
            showToast(provider.status == .denied
                      ? "Turn on location access in Settings so search knows where to look"
                      : "Getting your location — searching right after")
            return false
        }
        return true
    }

    /// Resolves a query (address or place name) to map items. Shared by
    /// `runSearch` and the "add a place / person" flow so both hit MapKit
    /// identically; returns [] on failure or zero results.
    private func resolvePlace(query: String, region: MKCoordinateRegion) async -> [MKMapItem] {
        func search(regionRequired: Bool) async -> [MKMapItem] {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = region
            if regionRequired, #available(iOS 18.0, *) {
                request.regionPriority = .required
            }
            return (try? await MKLocalSearch(request: request).start().mapItems) ?? []
        }
        // First pass constrains the search to the meetup area (not just a hint),
        // so a query with no LOCAL name match generalises to the IDEA within the
        // region — like Apple/Google Maps, "unlimited sushi" → nearby sushi,
        // instead of a business literally named "Sushi Unlimited" on the far side
        // of the world (device feedback). A tiny strict result set can still be
        // incomplete for category-style searches, though, so merge the broader
        // region-hint pass until we have enough candidates for ranking.
        let local = await search(regionRequired: true)
        if #available(iOS 18.0, *) {
            let fallback = local.count < Self.rankCap ? await search(regionRequired: false) : []
            return SearchResultMerger.merge(local: local, fallback: fallback, minimumCount: Self.rankCap)
        }
        return SearchResultMerger.deduped(local)
    }

    /// Resolves a category CHIP the way Apple Maps' own category buttons do: an
    /// `MKLocalPointsOfInterestRequest` for the chip's POI categories, strictly
    /// confined to the meetup region — no text relevance to drift off toward a
    /// commercial corridor, and no dependence on the text engine understanding
    /// a phrase like "Study Spots" (device feedback: the Study chip was dead).
    /// Sparse areas fall back to the text engine with a term it DOES know,
    /// still filtered to the chip's categories.
    private func resolveCategory(_ preset: CategoryPreset, region: MKCoordinateRegion) async -> [MKMapItem] {
        let request = MKLocalPointsOfInterestRequest(coordinateRegion: region)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: preset.poiCategories)
        let items = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
        if !items.isEmpty { return SearchResultMerger.deduped(items) }

        let textRequest = MKLocalSearch.Request()
        textRequest.naturalLanguageQuery = preset.mapKitQuery
        textRequest.region = region
        textRequest.resultTypes = .pointOfInterest
        textRequest.pointOfInterestFilter = MKPointOfInterestFilter(including: preset.poiCategories)
        if #available(iOS 18.0, *) {
            textRequest.regionPriority = .required
        }
        let fallback = (try? await MKLocalSearch(request: textRequest).start().mapItems) ?? []
        return SearchResultMerger.deduped(fallback)
    }

    /// The participant set the local fairness ranking compares — you, every live
    /// peer/participant, AND every manually-added point (solo A→B / added
    /// non-app-users). Nil when there's nobody to compare against (need ≥2
    /// points), so the caller skips ranking and shows plain search results.
    /// Manual points make the app useful alone without pinging anyone.
    private var searchRankingParticipants: [Participant]? {
        var participants: [Participant] = []
        if let me = savedCoordinate {
            let myName = UserProfile.displayName ?? UserName.fallback
            participants.append(Participant(id: myName, name: myName, coordinate: me))
        }
        if let peer = peerCoordinate {
            participants.append(Participant(id: "peer", name: "Friend", coordinate: peer))
        }
        participants.append(contentsOf: additionalParticipants)
        participants.append(contentsOf: manualParticipants)
        return participants.count >= 2 ? participants : nil
    }

    /// Adds a locally-picked point (solo A→B / a non-app-user) and refreshes the
    /// map + any on-screen ranking. Never sent.
    private func addManualPoint(_ point: Participant) {
        manualParticipants.append(point)
        frameUserContext()
        if searchResults.isEmpty, searchRankingParticipants != nil {
            // Nothing to rank yet — auto-find fair spots between the points so the
            // "best spot" ranking activates immediately, instead of adding a point
            // doing nothing until you separately search (device feedback: it should
            // behave like a person joining). The category chips still let you
            // change what's shown.
            startShortcutSearch(Self.suggestedSpot)
        } else {
            // Funnel through searchTask so a rapid add/remove — or a committed
            // search — cancels an in-flight re-rank; otherwise a slower older
            // MKDirections round-trip could finish last and stomp the current
            // ranking (post-push audit).
            searchTask?.cancel()
            searchTask = Task { @MainActor in await rerankCurrentResults() }
        }
    }

    private func removeManualPoint(_ point: Participant) {
        manualParticipants.removeAll { $0.id == point.id }
        frameUserContext()
        searchTask?.cancel()
        searchTask = Task { @MainActor in await rerankCurrentResults() }
    }

    /// Re-ranks the search results already on screen against the current
    /// participant set — used after adding/removing a manual point, no fresh
    /// MapKit round-trip. Clears ranking when there's nobody to compare against.
    @MainActor
    private func rerankCurrentResults() async {
        guard let participants = searchRankingParticipants, !searchResults.isEmpty else {
            rankedSpots = []
            return
        }
        let cap = participants.count >= 3
            ? FairnessRanker.recommendedCap(for: participants.count)
            : Self.rankCap
        // Same hard between-people cut as runSearch — adding/removing a point
        // reshapes the corridor, so re-filter against the NEW participant set.
        let candidates = SpotVicinity.filter(searchResults, participants: participants, minimumCount: 3)
        let ranked = await FairnessRanker.rank(
            candidates: candidates, participants: participants, cap: cap)
        // A newer search/re-rank may have superseded this one mid-flight.
        guard !Task.isCancelled else { return }
        rankedSpots = ranked
    }

    /// Straight-line distance from you to a manual point, for the route chips.
    private func manualPointDistance(_ point: Participant) -> String? {
        guard let me = savedCoordinate else { return nil }
        return ABDistanceLabel.formatDistance(from: me, to: point.coordinate)
    }

    /// Runs `MKLocalSearch`, surfaces raw hits immediately, then ranks the same
    /// hits by fairness whenever there's someone/somewhere to compare against
    /// (a live peer OR a manually-added point). Committed searches (Return,
    /// suggestion, chip, shortcut) may reframe the map.
    @MainActor
    private func runSearch(trimmed: String, reframeMap: Bool) async {
        guard monitor.isOnline else {
            isSearchLoading = false
            searchResults = []
            rankedSpots = []
            searchState = .idle
            return
        }

        // A chip tap is a CATEGORY browse, not a text search — route it through
        // the POI-category engine (how Apple Maps' own category buttons work).
        // "Study Spots" means nothing to the text engine, which is why the
        // Study chip found nothing (device feedback).
        let items: [MKMapItem]
        if let preset = selectedCategory, trimmed == preset.searchQuery {
            items = await resolveCategory(preset, region: searchRegion)
        } else {
            items = await resolvePlace(query: trimmed, region: searchRegion)
        }
        guard !Task.isCancelled else { return }

        rankedSpots = []
        searchResults = items
        isSearchActive = true
        isSearchLoading = false
        searchState = .results
        if reframeMap {
            frameSearchResults()
        }

        // Rank fair spots whenever there's at least one other point to compare
        // against — a live peer OR a manually-added place/person (solo A→B).
        // The old code gated on a peer coordinate, which is why the app did
        // nothing useful alone (device feedback).
        if !items.isEmpty, let participants = searchRankingParticipants {
            let cap = participants.count >= 3
                ? FairnessRanker.recommendedCap(for: participants.count)
                : Self.rankCap
            // Hard between-people cut BEFORE ranking (device feedback: spots
            // must actually sit between the group, not in whatever commercial
            // corridor MapKit's relevance drifted to). When the cut leaves
            // nothing rankable — a typed search for one specific far place —
            // rankedSpots stays empty and the raw results still display.
            let candidates = SpotVicinity.filter(items, participants: participants, minimumCount: 3)
            let ranked = await FairnessRanker.rank(
                candidates: candidates, participants: participants, cap: cap)
            guard !Task.isCancelled else { return }
            rankedSpots = ranked
            if reframeMap {
                frameSearchResults()
            }
        }

        guard reframeMap else { return }

        // Always zoom to fit the results together with both participants, in
        // either view mode, so the camera is never stale once the sheet moves.
        frameResultsWithParticipants()

        switch searchViewMode {
        case .list:
            // Results arrived — expand to full so the cards fill the screen
            // (the framed map becomes the backdrop, visible on drag-down).
            withAnimation(Tokens.Motion.snappy) { selectedSheetDetent = .fraction(0.90) }
        case .map:
            // Keep the sheet at its peek so the freshly framed pins stay visible.
            withAnimation(Tokens.Motion.snappy) {
                selectedSheetDetent = .height(Tokens.Layout.sheetPeekHeight)
            }
        }
    }

    private func clearSearch() {
        searchTask?.cancel()
        searchText = ""
        searchResults = []
        rankedSpots = []
        isSearchActive = false
        isSearchLoading = false
        searchState = .idle
        completer.update(query: "")
        selectedCategory = nil
        selectedResult = nil
        searchViewMode = .list
        searchFocused = false
    }

    /// Toggles a preset chip. Re-tapping the active chip clears the search;
    /// otherwise the preset commits straight to results (skipping suggestions,
    /// since a category is already a complete query).
    private func selectCategory(_ preset: CategoryPreset) {
        if selectedCategory == preset {
            clearSearch()
        } else {
            selectedCategory = preset
            setSearchTextProgrammatically(preset.searchQuery)
            expandToSearchDetent()
            commitSearch()
        }
    }

    // MARK: - Peer polling

    private var appGroupDidChangePublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification,
            object: UserDefaults(suiteName: LocationCache.appGroup)
        )
    }

    @MainActor
    private func pollPeer() async {
        // Fallback cadence only — MeetupSync Darwin notifications deliver
        // changes immediately; this loop just catches anything a missed
        // notification would leave behind (e.g. a writer predating the posts).
        while !Task.isCancelled {
            _ = pollRefreshFromAppGroup()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Poll-safe wrapper around `refreshFromAppGroup()` — suppresses any
    /// programmatic write to `selectedSheetDetent` for the duration of the
    /// refresh so the 300 ms App Group poll cannot fight the user's sheet
    /// drag. Docs: `docs/ui-research.md` §1 (self-jump).
    ///
    /// User-initiated refresh paths (`.onAppear`, scene resume,
    /// `handleIncomingURL`) still call `refreshFromAppGroup()` directly so the
    /// "agreed just landed" detent nudge fires as intended when a user opens
    /// or returns to the app.
    @MainActor
    @discardableResult
    private func pollRefreshFromAppGroup() -> Bool {
        suppressPollDetentWrites = true
        defer { suppressPollDetentWrites = false }
        return refreshFromAppGroup()
    }

    /// Whether a poll/refresh that observes a local leave should reset an open
    /// search ranking. TRUE only when the refresh is tearing down live peer
    /// state THIS tick — never on the subsequent polls where the tombstone still
    /// reads "left" but the peer is already gone, or a fresh solo/manual A→B
    /// search started after leaving would be wiped on every 2 s tick.
    static func shouldResetRankingOnLeave(localLeft: Bool, hasLivePeerState: Bool) -> Bool {
        localLeft && hasLivePeerState
    }

    @MainActor
    @discardableResult
    private func refreshFromAppGroup() -> Bool {
        // Group-aware path: the extension writes the full participants roster
        // whenever it receives or sends a bubble. If present, keep the first
        // remote participant as `peerCoordinate` for legacy call sites and draw
        // the rest as group participants.
        let myName = UserProfile.displayName ?? UserName.fallback
        // Same freshness rule as the extension: a snapshot past its TTL is
        // history, not a live meetup, so the poll must not keep painting it.
        let scopedSnapshot = ConversationMeetupStore.lastActiveConversationKey
            .flatMap { ConversationMeetupStore.load(key: $0) }
            .flatMap { Date().timeIntervalSince($0.updatedAt) <= ConversationMeetupStore.snapshotTTL ? $0 : nil }
        let roster = scopedSnapshot?.participants ?? LocationCache.loadParticipants()
        let localContext = LocalParticipantContext(id: TweenIdentity.stableID, name: myName)
        let remotes = roster.filter { !$0.matches(localContext) }
        let localParticipant = roster.first { $0.matches(localContext) }

        // Peers stop existing for THIS device once the local user LEFT the
        // conversation's meetup. The roster deliberately keeps the remaining
        // group in the STORE after "I'm out" (a rejoin must restore everyone
        // — D4), but projecting those coordinates into live state kept the
        // leaver's search results ranking against the departed friend and
        // showing "distance between you" chips (device feedback: leaving
        // must fully reset, not just hide the pin). Keyed on the
        // per-conversation leave TOMBSTONE — not membership/opt-in — so a
        // pinged friend who joined FIRST still previews (reply banner,
        // framed pins) before this user taps I'm in, and conversation A's
        // opt-in can't resurrect conversation B's departed roster
        // (post-push audit at 42fdc68).
        // Provenance-matched: the tombstone only judges a roster that came
        // from ITS conversation's snapshot. When the scoped snapshot is
        // absent (TTL-expired, or a drawer-peek re-pointed the key at a
        // thread this user left long ago) the roster above fell back to the
        // GLOBAL participants blob — possibly a different, live meetup that
        // key's tombstone has no authority over (audit at 2b894b0).
        let localLeft = scopedSnapshot != nil
            && (ConversationMeetupStore.lastActiveConversationKey
                .map { ConversationMeetupStore.localUserLeft(key: $0) } ?? false)
        let newPeer: CLLocationCoordinate2D?
        let newPeerName: String
        let newPeerNeedsRide: Bool
        let newExtras: [Participant]
        if let firstRemote = remotes.first, !localLeft {
            newPeer = firstRemote.coordinate
            // Sanitise for display (audit F2): an unnamed sender's legacy "You"
            // (or an empty name) reads as "Friend", never "You". Identity keeps
            // riding on the stable id, so only the shown label changes.
            newPeerName = UserName.peerDisplayName(firstRemote.name)
            newPeerNeedsRide = firstRemote.needsRide
            newExtras = remotes.dropFirst().map { p in
                Participant(id: p.id, name: UserName.peerDisplayName(p.name),
                            coordinate: p.coordinate, needsRide: p.needsRide)
            }
        } else if !localLeft {
            newPeer = LocationCache.isPeerActive ? LocationCache.loadPeer()?.coordinate : nil
            newPeerName = "Friend"
            newPeerNeedsRide = false
            newExtras = []
        } else {
            newPeer = nil
            newPeerName = "Friend"
            newPeerNeedsRide = false
            newExtras = []
        }
        // An extension-side leave reaches this device as the tombstone +
        // deactivated flags — it must reset an open results list exactly
        // like the app-side leave (commitLeaveLocally) does, or the stale
        // "You X min | Sam Y min" chips survive until the next search.
        //
        // But ONLY on the tick that actually tears down live peer state — NOT
        // on every poll. The leave tombstone lingers for the conversation, so
        // an unconditional clear here wiped a fresh solo/manual A→B search the
        // user started AFTER leaving: it ranked, then the next 2 s poll nuked
        // rankedSpots and the list fell back to raw distance (device feedback:
        // "search works, then it refreshes and loses all logic"). A solo ranking
        // (self + an added place, no peer) has no departed-peer chips to clear.
        // `peerCoordinate`/`additionalParticipants` still hold their pre-update
        // values here (reconciled below), so they detect the teardown tick.
        let hasLivePeerState = peerCoordinate != nil || !additionalParticipants.isEmpty
        if Self.shouldResetRankingOnLeave(localLeft: localLeft, hasLivePeerState: hasLivePeerState) {
            if !rankedSpots.isEmpty {
                rankedSpots = []
            }
            // An open place sheet captured its ranked ETAs at present time —
            // scored against the meetup just left. Solo-opened sheets carry
            // ranked == nil (post-leave searches can't rank), so they stay.
            if case .spot(let selection) = activeSheet, selection.ranked != nil {
                activeSheet = nil
            }
        }

        var didChange = false
        if currentParticipants != roster {
            currentParticipants = roster
            didChange = true
        }
        if peerDisplayName != newPeerName {
            peerDisplayName = newPeerName
            didChange = true
        }
        if peerNeedsRide != newPeerNeedsRide {
            peerNeedsRide = newPeerNeedsRide
            didChange = true
        }
        if localNeedsRide != (localParticipant?.needsRide ?? false) {
            localNeedsRide = localParticipant?.needsRide ?? false
            didChange = true
        }
        if !same(peerCoordinate, newPeer) {
            peerCoordinate = newPeer
            didChange = true
            if let newPeer {
                logger.debug("Main app loaded peer coordinate lat=\(newPeer.latitude, privacy: .public) lon=\(newPeer.longitude, privacy: .public)")
            } else {
                logger.debug("Main app cleared inactive peer coordinate")
            }
        }
        if additionalParticipants != newExtras {
            additionalParticipants = newExtras
            didChange = true
            if !newExtras.isEmpty {
                logger.debug("Main app loaded \(newExtras.count, privacy: .public) additional participants")
            }
        }

        let cachedSelfBlob = LocationCache.loadSelf()
        let cachedSelf = cachedSelfBlob?.coordinate
        if !same(savedCoordinate, cachedSelf) {
            savedCoordinate = cachedSelf
            // This coordinate came from the cache, not a live fix — clear the
            // in-memory freshness stamp so `freshSelfCoordinateForSend` judges
            // it by the cache's own timestamp rather than treating it as fresh
            // as of now. (Otherwise a refresh could overwrite a live fix with
            // an older cache value while the stamp still read "recent".)
            savedCoordinateAt = nil
            didChange = true
        }
        // Restore the declared-location provenance from the cache so a relaunch
        // or a poll tick keeps the GPS-clobber guard + "You'll be at…" labels
        // consistent with what was saved (the place NAME isn't persisted — the
        // cache holds coords + prefs only — so the label may generalise). Only
        // an ACTIVE declaration counts — after a leave it's deactivated and must
        // stop lingering as a manual self (post-push audit).
        let cachedIsManual = cachedSelfBlob?.isManual == true && cachedSelfBlob?.isActive == true
        if selfIsManual != cachedIsManual {
            selfIsManual = cachedIsManual
            if !cachedIsManual { selfManualLabel = nil }
        }
        // Presence tracks the opt-in flag, NOT coordinate freshness — the old
        // `isActive` read silently flipped "I'm in" back off five minutes
        // after the last fix while peers still counted this user in.
        let active = LocationCache.isOptedIn
        if isUserIn != active {
            isUserIn = active
            didChange = true
        }

        let cachedAgreedMeetup = scopedSnapshot?.agreedState ?? LocationCache.loadAgreedMeetup()
        if agreedMeetup != cachedAgreedMeetup {
            agreedMeetup = cachedAgreedMeetup
            // Poll-driven deselect: latch the detent restore off (read the
            // defer-scoped flag NOW, while it's still true — the onChange
            // that consumes the latch runs after the defer resets it).
            if suppressPollDetentWrites, selectedResult != nil {
                suppressNextDeselectDetentRestore = true
            }
            selectedResult = nil
            didChange = true
            if cachedAgreedMeetup != nil {
                // Self-jump gate: skip the tab AND detent writes when this
                // refresh was driven by the 300 ms poll (or another background
                // App Group signal) — a background tick must not yank controls
                // the user may be interacting with. User-initiated refresh
                // paths keep the peek nudge. See docs/ui-research.md §1.
                if !suppressPollDetentWrites {
                    selectedSheetDetent = .height(Tokens.Layout.sheetPeekHeight)
                }
            }
        }

        // Mirror the in-flight proposal (propose / counter / partial agree)
        // so opening the app mid-negotiation shows it. Renders ALONGSIDE a
        // set meetup when both exist — see visiblePendingProposal.
        let cachedProposal = Self.visiblePendingProposal(
            proposed: scopedSnapshot?.proposedState,
            agreed: cachedAgreedMeetup)
        if pendingProposal != cachedProposal {
            pendingProposal = cachedProposal
            didChange = true
            // Same peek nudge as the agreed path: the proposal card floats
            // over the map just above the collapsed sheet, so a half-open
            // sheet would hide it. Gated like every background-driven write
            // so a poll/notification tick can't yank controls mid-drag.
            if cachedProposal != nil, !suppressPollDetentWrites {
                selectedSheetDetent = .height(Tokens.Layout.sheetPeekHeight)
            }
        }

        lastReplyAt = PingLog.lastIncomingReplyAt
        lastGenericInviteAt = PingLog.lastGenericInviteAt
        // Camera writes obey the same self-jump gate as detent writes: a
        // background poll/notification tick detecting a change (e.g. a peer
        // coordinate update) must not yank the map out from under a user
        // who has panned or zoomed. User-initiated refresh paths (.onAppear,
        // scene resume, handleIncomingURL) still reframe as intended.
        if didChange, !suppressPollDetentWrites {
            reframe()
        }
        return didChange
    }

    // MARK: - Geometry

    private func reframe() {
        if let agreedMeetup, agreedMeetup.kind == .place {
            logger.debug("Map reframe centered on agreed meetup")
            withAnimation(Tokens.Motion.gentle) {
                position = Self.placeCameraPosition(for: agreedMeetup.coordinate)
            }
            return
        }

        var coords = [savedCoordinate, peerCoordinate].compactMap { $0 }
        coords.append(contentsOf: additionalParticipants.map(\.coordinate))
        coords.append(contentsOf: manualParticipants.map(\.coordinate))
        guard !coords.isEmpty else { return }
        logger.debug("Map reframe triggered for \(coords.count, privacy: .public) coordinate(s)")
        withAnimation(Tokens.Motion.gentle) { position = Self.cameraPosition(for: coords) }
    }

    private func resetMapCamera() {
        let hasSearchContext = selectedResult != nil || (isSearchActive && !displayedItems.isEmpty)
        if hasSearchContext && !resetNextTapReturnsToUser {
            resetNextTapReturnsToUser = true
            frameVisibleSearchContext()
            return
        }

        resetNextTapReturnsToUser = false
        selectedResult = nil
        frameUserContext()
    }

    private func frameVisibleSearchContext() {
        var coords = [savedCoordinate, peerCoordinate].compactMap { $0 }
        coords.append(contentsOf: additionalParticipants.map(\.coordinate))
        coords.append(contentsOf: manualParticipants.map(\.coordinate))

        if let selectedResult {
            coords.append(selectedResult.placemark.coordinate)
        } else {
            coords.append(contentsOf: displayedItems.prefix(Self.rankCap).map(\.placemark.coordinate))
        }

        guard !coords.isEmpty else {
            frameUserContext()
            return
        }

        logger.debug("Manual map reset to search context for \(coords.count, privacy: .public) coordinate(s)")
        withAnimation(Tokens.Motion.gentle) {
            position = Self.cameraPosition(for: coords, padding: 1.35, minSpan: 0.04, bottomBias: 0.25)
        }
    }

    private func frameUserContext() {
        if let savedCoordinate {
            // Frame you together with any added A→B points, so adding a place
            // shows both ends rather than snapping tightly onto you.
            let others = manualParticipants.map(\.coordinate) + additionalParticipants.map(\.coordinate)
            if !others.isEmpty {
                withAnimation(Tokens.Motion.gentle) {
                    position = Self.cameraPosition(for: [savedCoordinate] + others, padding: 1.35, minSpan: 0.04)
                }
                return
            }
            logger.debug("Manual map reset to user location")
            withAnimation(Tokens.Motion.gentle) {
                position = .region(MKCoordinateRegion(
                    center: savedCoordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.018, longitudeDelta: 0.018)))
            }
            return
        }

        var coords = [peerCoordinate].compactMap { $0 }
        coords.append(contentsOf: additionalParticipants.map(\.coordinate))
        coords.append(contentsOf: manualParticipants.map(\.coordinate))
        guard !coords.isEmpty else {
            withAnimation(Tokens.Motion.gentle) {
                position = Self.cameraPosition(for: [Self.defaultCenter])
            }
            return
        }

        logger.debug("Manual map reset to available participant context")
        withAnimation(Tokens.Motion.gentle) {
            position = Self.cameraPosition(for: coords, padding: 1.2, minSpan: 0.04)
        }
    }

    /// Hands off to Google Maps: app scheme first (opens the app directly when
    /// installed), Google's universal `/maps/dir/` link otherwise (opens the
    /// app via universal link, or the web version — never a dead end).
    private func openGoogleMapsExternally(name: String, coordinate: CLLocationCoordinate2D) {
        showToast("Opening Google Maps…")
        guard let appURL = MapLinks.googleMapsURL(name: name, coordinate: coordinate) else { return }
        UIApplication.shared.open(appURL) { opened in
            guard !opened,
                  let webURL = MapLinks.googleMapsWebURL(name: name, coordinate: coordinate) else { return }
            DispatchQueue.main.async {
                UIApplication.shared.open(webURL)
            }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        if url.scheme == "tween", url.host == "search" {
            // Expand-then-focus per docs/ui-research.md §7 — SwiftUI drops the
            // first responder if the sheet is still animating between detents
            // when `searchFocused = true` fires.
            expandThenFocusSearch()
            return
        }
        // Google Maps handoff from the Messages extension (which cannot open
        // other apps itself — extensionContext.open only launches THIS app).
        // Pure trampoline: bounce straight out to Google Maps and touch no
        // meetup state, so Tween is only a hop, not a destination.
        if let handoff = MapLinks.decodeHandoff(url) {
            openGoogleMapsExternally(name: handoff.name, coordinate: handoff.coordinate)
            return
        }

        guard let state = TweenState(url: url) else { return }
        logger.debug("Host opened Tween URL type=\(state.messageType.rawValue, privacy: .public) kind=\(state.kind.rawValue, privacy: .public)")
        let myName = UserProfile.displayName ?? UserName.fallback
        let activeConversationKey = ConversationMeetupStore.lastActiveConversationKey
        let openedOwnProposal = state.kind == .place && state.senderName == myName
        // "I left this conversation's meetup" — the same tombstone the
        // projection gate reads. Direct peer writes below must respect it
        // too, or a departed user tapping a fresh bubble gets the peer pin
        // for one beat before the next refresh nils it (audit at 2b894b0).
        let departedHere = activeConversationKey
            .map { ConversationMeetupStore.localUserLeft(key: $0) } ?? false

        // Save the sender's coord as peer so the map can frame both pings.
        if !openedOwnProposal, !departedHere, let peer = state.participantCoordinate {
            LocationCache.savePeer(peer, isActive: true)
            peerCoordinate = peer
            logger.debug("Host saved peer from URL lat=\(peer.latitude, privacy: .public) lon=\(peer.longitude, privacy: .public)")
        }
        // Roster adoption mirrors the extension's decode path — revision
        // guard, self-tombstone filter, and MERGE instead of verbatim
        // replace. This URL path used to bypass all three, so opening an old
        // link resurrected a stale roster (including this user after they'd
        // left). A `.leave` message may intentionally carry an empty roster.
        var adoptRoster = true
        if let revision = state.revision, let activeConversationKey {
            // Pass messageType so a concurrent .invite opened via the host
            // tween:// path unions too — host/extension must agree on the
            // same payload (parity with decodeAndCache).
            adoptRoster = ConversationMeetupStore.shouldAcceptInbound(
                revision: revision, senderID: state.senderID,
                messageType: state.messageType, key: activeConversationKey)
            if adoptRoster {
                ConversationMeetupStore.noteRevision(
                    revision, sender: state.senderID, key: activeConversationKey)
            }
        }
        if adoptRoster, !state.participants.isEmpty || state.messageType == .leave {
            let localContext = LocalParticipantContext(id: TweenIdentity.stableID, name: myName)
            let senderKeys = RosterMerge.senderKeys(senderID: state.senderID, senderName: state.senderName)
            if let activeConversationKey {
                // Absorb gossiped departures — minus the local user, whose
                // presence is governed solely by localUserLeft.
                let myKeys: Set<String> = [TweenIdentity.stableID, myName]
                ConversationMeetupStore.noteDeparted(state.departed.filter { !myKeys.contains($0) },
                                                     key: activeConversationKey)
                if state.messageType == .leave {
                    ConversationMeetupStore.noteDeparted(senderKeys, key: activeConversationKey)
                } else {
                    ConversationMeetupStore.clearDeparted(senderKeys, key: activeConversationKey)
                }
            }
            var incoming = state.participants
            if departedHere {
                incoming.removeAll { $0.matches(localContext) }
            }
            let departed = activeConversationKey
                .map { ConversationMeetupStore.departedParticipants(key: $0) } ?? []
            // Scoped-first merge base (parity with the extension's decode):
            // post-leave the global blob is deliberately empty, and merging
            // against [] would collapse the D4 rejoin roster to one sender's
            // partial view (audit at 69a3886).
            let merged = RosterMerge.merge(
                local: scopedFirstRoster(),
                incoming: incoming,
                messageType: state.messageType,
                senderKeys: senderKeys,
                departed: departed)
            // Post-leave, the merged roster stays SCOPED-only: writing it to
            // the un-TTL'd global mirrors would restock exactly the blob the
            // hour-24 resurrection fires from (audit at 18c182a).
            if !departedHere {
                LocationCache.saveParticipantSnapshot(merged, localContext: localContext)
            }
            if let activeConversationKey {
                ConversationMeetupStore.saveParticipants(merged, key: activeConversationKey)
            }
            if !departedHere, let firstRemote = merged.first(where: { !$0.matches(localContext) }) {
                peerCoordinate = firstRemote.coordinate
            } else {
                peerCoordinate = nil
            }
        }
        // Only stamp the inbound-reply timestamp for ACTUAL replies — invites,
        // proposals, and agrees from a peer. Plain `tween://search` deep links
        // (handled above), self-opened URLs, and STALE payloads the revision
        // guard rejected (audit at 69a3886) shouldn't inflate the banner.
        if !openedOwnProposal && adoptRoster
            && (state.kind == .participant || state.messageType == .agree || state.messageType == .leave) {
            PingLog.lastIncomingReplyAt = Date()
            lastReplyAt = PingLog.lastIncomingReplyAt
        }

        switch state.messageType {
        case .propose, .counter:
            if openedOwnProposal {
                if state.messageType == .counter {
                    LocationCache.clearAgreedMeetup()
                    agreedMeetup = nil
                }
                if let activeConversationKey {
                    ConversationMeetupStore.saveProposed(state, key: activeConversationKey)
                }
                showOwnProposalOnMap(state)
                return
            }
            if state.messageType == .counter {
                LocationCache.clearAgreedMeetup()
                agreedMeetup = nil
            }
            if let activeConversationKey {
                ConversationMeetupStore.saveProposed(state, key: activeConversationKey)
            }
            // A friend has suggested a place — open the SpotDetailCard in
            // incoming mode so the user sees Agree / Change buttons rather
            // than the search-result CTA. Build a synthetic MKMapItem to
            // reuse the existing .spot sheet plumbing.
            let placemark = MKPlacemark(coordinate: state.coordinate)
            let item = MKMapItem(placemark: placemark)
            item.name = state.text
            let selection = SpotSelection(
                item: item,
                ranked: nil,  // no ETA chip until we re-rank against fresh self
                incoming: IncomingProposalContext(
                    senderName: state.senderName,
                    senderID: state.senderID,
                    participants: state.participants,
                    agreedNames: state.agreedNames,
                    agreedIDs: state.agreedIDs,
                    isCounter: state.messageType == .counter))
            activeSheet = .spot(selection)
            // Frame the map so the user can see the proposed spot in context.
            withAnimation(Tokens.Motion.gentle) {
                position = Self.placeCameraPosition(for: state.coordinate)
            }

        case .agree:
            if state.isFullyAgreed {
                LocationCache.saveAgreedMeetup(state)
                if let activeConversationKey {
                    ConversationMeetupStore.saveAgreed(state, key: activeConversationKey)
                }
                agreedMeetup = state
                selectedResult = nil
                // URL-presented proposal sheets carry no selection, so the
                // deselect above can't close them — dismiss explicitly or
                // the user keeps reading an Agree/Change card for a
                // negotiation that just finished (audit at bb6740d).
                if case .spot(let sel) = activeSheet, sel.incoming != nil {
                    activeSheet = nil
                }
            }
            // A friend's reply that they agree to a previously-proposed spot.
            // No interactive UI needed — just frame the map on it and toast.
            withAnimation(Tokens.Motion.gentle) {
                position = Self.placeCameraPosition(for: state.coordinate)
            }
            let who = state.senderName ?? "Your friend"
            showToast(state.isFullyAgreed
                      ? "Meeting at \(state.text) — \(who) is in."
                      : "\(who) agreed to \(state.text).")

        case .invite:
            // Bare participant invite — the legacy "I'm in" case. Cache and
            // reframe; the user sees the friend's pin and decides what to
            // do (tap I'm in themselves, search a spot, etc).
            reframe()

        case .leave:
            // Gated on the revision guard: a STALE leave URL (its sender may
            // have since rejoined) must not tear down a newer agreement or
            // roster the floor exists to protect. The MERGED roster saved
            // above (departure-filtered by RosterMerge) is authoritative —
            // the payload's verbatim roster never overwrites it (audit at
            // 18c182a).
            guard adoptRoster else { break }
            if state.participants.isEmpty {
                LocationCache.clearAgreedMeetup()
                if let activeConversationKey {
                    ConversationMeetupStore.clearProposalState(key: activeConversationKey)
                }
                agreedMeetup = nil
                pendingProposal = nil
            }
            // A proposal card from someone who just left is dead — dismiss
            // it rather than leaving it orphaned over the departure toast.
            if case .spot(let sel) = activeSheet, sel.incoming != nil {
                activeSheet = nil
            }
            reframe()
            let who = state.senderName ?? "Your friend"
            showToast("\(who) is out.")
        }
    }

    private func showOwnProposalOnMap(_ state: TweenState) {
        pendingProposal = state
        selectedSheetDetent = .height(Tokens.Layout.sheetPeekHeight)
        let placemark = MKPlacemark(coordinate: state.coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = state.text
        // Waiting-pin selection, NOT a browse tap: latch the one-tap
        // presentation off or the sheet the user just sent from re-presents
        // over the waiting toast (audit at bb6740d).
        if selectedResult != item { suppressNextSelectionPresentation = true }
        selectedResult = item
        activeSheet = nil
        withAnimation(Tokens.Motion.gentle) {
            position = Self.placeCameraPosition(for: state.coordinate)
        }
        showToast("Waiting for them to agree to \(state.text).")
    }

    /// Sends an agree-bubble back to a friend after they proposed a place
    /// via `tween://` link. Uses the same MFMessageComposeViewController +
    /// MSMessage plumbing as the rich-bubble ping (Slice B), but with an
    /// `.agree` TweenState containing the local user appended to agreedNames.
    private func sendAgreeReply(for selection: SpotSelection,
                                 incoming: IncomingProposalContext) {
        guard MFMessageComposeViewController.canSendText() else {
            UIPasteboard.general.string = "I'm in for \(selection.name)"
            showToast("Messages unavailable - copied a reply for you")
            return
        }
        // Synthesise the agree state. Append my name to agreedNames if not
        // already present; the bubble's `isFullyAgreed` flag fires on the
        // receiver's side once everyone-but-the-proposer is in.
        let myName = UserProfile.displayName ?? UserName.fallback
        let myID = TweenIdentity.stableID
        var agreed = incoming.agreedNames
        if !agreed.contains(myName) { agreed.append(myName) }
        // Same namespace rule as the extension (T6/T7): a legacy proposal
        // (no senderID) stays name-namespaced end to end — mixing UUID
        // agreedIDs with name-ids makes consensus unreachable.
        var agreedIDs: [String]
        if incoming.senderID != nil {
            agreedIDs = incoming.agreedIDs
            if !agreedIDs.contains(myID) { agreedIDs.append(myID) }
        } else {
            agreedIDs = []
        }
        guard autoJoinForOutgoingMessage() else {
            // Same parking pattern as sendToChat: the user already said yes —
            // resume the agreement once the fix lands instead of dropping it.
            pendingLocationAction = { sendAgreeReply(for: selection, incoming: incoming) }
            provider.requestOnce()
            showToast("Getting your location — agreeing right after")
            return
        }
        // Fresh-only (audit W4). autoJoin above only returns true after
        // caching a current fix, so this is non-nil here — but reading the
        // fresh accessor (not raw loadSelf) keeps a stale coord from ever
        // entering the agreement roster if that invariant changes.
        let mySelf = freshSelfCoordinateForSend
        var participants = incoming.participants.filter { !$0.matches(LocalParticipantContext(id: myID, name: myName)) }
        if let mySelf {
            participants.append(Participant(id: myID, name: myName, coordinate: mySelf, needsRide: localNeedsRide))
        }

        let revision = nextOutgoingRevisionForActiveConversation()
        let state = TweenState(
            text: selection.name,
            latitude: selection.coordinate.latitude,
            longitude: selection.coordinate.longitude,
            senderName: incoming.senderName ?? UserProfile.displayName,
            senderID: incoming.senderID,
            kind: .place,
            senderCoordinate: mySelf,
            action: .agree,
            messageType: .agree,
            participants: participants,
            agreedNames: agreed,
            agreedIDs: agreedIDs,
            revision: revision
        )

        // Async render the bubble image, then present the composer. The
        // recipient field is left empty so the user picks the same friend
        // they got the link from. The agreement is committed in onSent ONLY:
        // committing before the composer meant a cancelled send still
        // rendered MEETUP SET here for an agreement the peer never received
        // (the extension has always gated these commits on didSend).
        Task { @MainActor in
            guard let message = await composeTweenMessage(
                for: state, totalSeats: state.participants.count) else { return }
            activeSheet = .message(PendingMessage(
                recipients: [],
                body: Self.spotBody(prefix: "I'm in —", name: selection.name, coordinate: selection.coordinate),
                message: message,
                onSent: {
                    noteOutgoingRevision(revision)
                    if let key = ConversationMeetupStore.lastActiveConversationKey {
                        if state.isFullyAgreed {
                            ConversationMeetupStore.saveAgreed(state, key: key)
                        } else {
                            ConversationMeetupStore.saveProposed(state, key: key)
                        }
                    }
                    _ = refreshFromAppGroup()
                },
                onCancelled: {
                    showToast("Not sent — friends still see the old plan")
                }))
        }
    }

    /// Lifts the bottom sheet and focuses the search bar so the user can
    /// pick a different spot than the one their friend proposed. Drops a
    /// pin on the rejected spot so they have spatial context.
    private func startChangeFlow(initialCoord: CLLocationCoordinate2D) {
        // Expand-then-focus per docs/ui-research.md §7. The camera nudge runs
        // in parallel with the sheet animation; SwiftUI schedules them on the
        // same tick so the map reframes as the sheet lifts.
        expandThenFocusSearch()
        withAnimation(Tokens.Motion.gentle) {
            position = Self.placeCameraPosition(for: initialCoord, bottomBias: 0.12)
        }
    }

    private func same(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D?) -> Bool {
        switch (a, b) {
        case (.none, .none):
            return true
        case let (.some(a), .some(b)):
            return a.latitude == b.latitude && a.longitude == b.longitude
        default:
            return false
        }
    }

    /// Average of two coordinates.
    static func midpoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2,
                               longitude: (a.longitude + b.longitude) / 2)
    }

    /// Frames the given coordinates with 20% padding on the span. A single point
    /// (or a degenerate cluster) falls back to a comfortable city-level zoom.
    ///
    /// `bottomBias` (0 = none) grows the latitude span and pushes the framed
    /// center south, so the fitted content settles in the upper portion of the
    /// map that the bottom sheet covers nothing of. SwiftUI exposes no live
    /// height for a `.sheet`, so we bias the framing rather than measure it.
    static func cameraPosition(
        for coordinates: [CLLocationCoordinate2D],
        padding: Double = 1.2,
        minSpan: CLLocationDegrees = 0.05,
        bottomBias: CGFloat = 0
    ) -> MapCameraPosition {
        guard let first = coordinates.first else {
            return .region(MKCoordinateRegion(
                center: defaultCenter,
                span: MKCoordinateSpan(latitudeDelta: minSpan, longitudeDelta: minSpan)))
        }

        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coordinates {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }

        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let degenerate = (maxLat - minLat) < 0.0001 && (maxLon - minLon) < 0.0001
        let baseLatDelta = degenerate ? minSpan : max((maxLat - minLat) * padding, minSpan)
        let lonDelta = degenerate ? minSpan : max((maxLon - minLon) * padding, minSpan)

        let bias = Double(bottomBias)
        let latDelta = baseLatDelta * (1 + bias)
        let biasedCenter = CLLocationCoordinate2D(
            latitude: center.latitude - latDelta * bias * 0.5,
            longitude: center.longitude)

        return .region(MKCoordinateRegion(
            center: biasedCenter,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)))
    }

    /// Opens concrete places tightly and a touch above center so the bottom
    /// sheet does not hide the pin. Context framing is still available through
    /// reset-map; initial place openings should never land on a midpoint.
    static func placeCameraPosition(
        for coordinate: CLLocationCoordinate2D,
        span: CLLocationDegrees = 0.018,
        bottomBias: CGFloat = 0.18
    ) -> MapCameraPosition {
        let center = CLLocationCoordinate2D(
            latitude: coordinate.latitude - (span * Double(bottomBias)),
            longitude: coordinate.longitude)
        return .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))
    }
}

/// A lightweight place/address picker for the solo A→B "what's in between" mode
/// and for adding someone who lacks the app. Reuses `SearchCompleter` for
/// typeahead and the caller's `resolvePlace` to turn the pick into a
/// coordinate. Nothing is sent — the result becomes a local `manual:` point.
private struct AddPointSheet: View {
    var title = "Add a place or person"
    var prompt = "Address, or where they are"
    let region: MKCoordinateRegion
    let resolvePlace: (String, MKCoordinateRegion) async -> [MKMapItem]
    let onAdd: (Participant) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var completer = SearchCompleter()
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                if adding {
                    HStack(spacing: Tokens.Spacing.s2) { ProgressView(); Text("Adding…") }
                        .foregroundStyle(Tokens.Palette.textSecondary)
                } else if !query.isEmpty && completer.results.isEmpty {
                    Text(completer.phase == .searching ? "Searching…" : "No matches")
                        .foregroundStyle(Tokens.Palette.textSecondary)
                } else {
                    ForEach(completer.results, id: \.self) { completion in
                        Button { pick(completion) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(completion.title)
                                    .foregroundStyle(Tokens.Palette.textPrimary)
                                if !completion.subtitle.isEmpty {
                                    Text(completion.subtitle)
                                        .font(Tokens.Typography.caption)
                                        .foregroundStyle(Tokens.Palette.textSecondary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: prompt)
            .onChange(of: query) { _, q in completer.debouncedUpdate(query: q, region: region) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func pick(_ completion: MKLocalSearchCompletion) {
        adding = true
        // @MainActor: onAdd mutates OnboardingView @State and dismiss() drives
        // presentation — both must run on the main actor, not off the bare Task.
        Task { @MainActor in
            let query = completion.subtitle.isEmpty
                ? completion.title : "\(completion.title), \(completion.subtitle)"
            let items = await resolvePlace(query, region)
            if let item = items.first {
                onAdd(Participant.manual(label: item.name ?? completion.title,
                                         coordinate: item.placemark.coordinate))
            }
            dismiss()
        }
    }
}

#Preview {
    OnboardingView()
}
