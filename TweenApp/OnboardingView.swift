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
struct OnboardingView: View {
    /// Default camera focus when there's no cached location and none can be
    /// resolved (e.g. location denied). The geographic center of the
    /// continental US — deliberately generic rather than a misleading city.
    static let defaultCenter = CLLocationCoordinate2D(latitude: 39.8283, longitude: -98.5795)

    /// How many candidates the fairness engine resolves routes for in the app.
    static let rankCap = 8

    /// A reply banner shows only while the last inbound bubble is this fresh.
    static let replyFreshness: TimeInterval = 60 * 60 // 1 hour
    static var isHostTabHarness: Bool {
        CommandLine.arguments.contains("-HARNESS_HOST_RIDES")
        || CommandLine.arguments.contains("-HARNESS_HOST_FRIENDS")
        || CommandLine.arguments.contains("-HARNESS_HOST_RIDE_MAP")
    }
    let logger = Logger(subsystem: "com.kavigandham.TweenApp", category: "Host")

    /// Prefilled body for an out-of-band SMS nudge to a friend.
    static let inviteText =
        "Where should we meet? Open Tween and tap “I'm in” so we can find a fair spot. 📍"

    /// Plain-text body for a spot message. Keep this human-readable: the rich
    /// MSMessage bubble already carries the route payload, and exposing the raw
    /// Maps URL in the typed text makes the send preview feel noisy.
    static func spotBody(prefix: String, name: String, coordinate: CLLocationCoordinate2D) -> String {
        "\(prefix) \(name)."
    }
    static let suggestedSpot = QuickSpotShortcut(
        title: "Coffee near the midpoint",
        subtitle: "Suggested spot",
        query: "coffee",
        systemImage: "sparkles")
    static let recentSpotShortcuts: [QuickSpotShortcut] = [
        QuickSpotShortcut(title: "Lunch spots", subtitle: "Food nearby", query: "restaurants", systemImage: "fork.knife"),
        QuickSpotShortcut(title: "Gas stations", subtitle: "Easy stop on the way", query: "gas", systemImage: "fuelpump.fill"),
        QuickSpotShortcut(title: "Study spots", subtitle: "Quiet places to sit", query: "library cafe", systemImage: "book.fill")
    ]

    @Environment(\.scenePhase) var scenePhase

    @State var savedCoordinate: CLLocationCoordinate2D?
    /// When the in-memory `savedCoordinate` was last set from an ACTUAL
    /// device fix. A silent launch fix updates `savedCoordinate` (to recenter
    /// the map) but deliberately doesn't write the cache, so this is how a
    /// pending send knows that in-memory coordinate is current. Nil for a
    /// coordinate restored from disk at launch, whose age is unknown — those
    /// fall through to the cache's own freshness check.
    @State var savedCoordinateAt: Date?
    @State var peerCoordinate: CLLocationCoordinate2D?
    @State var agreedMeetup: TweenState?
    /// The in-flight proposal/counter (not yet fully agreed) mirrored from the
    /// conversation-scoped store, so the host app shows the SAME negotiation
    /// the extension does — spot card, agreement progress, Agree & reply.
    @State var pendingProposal: TweenState?
    /// Every "in" participant beyond the local user and the primary peer —
    /// only populated in group chats (3+ people). Empty for DMs, preserving
    /// the original 2-person behaviour. Refreshed each tick of `pollPeer`.
    @State var additionalParticipants: [Participant] = []
    /// Locally-added points for the solo "A→B, see what's in between" mode and
    /// for adding someone who lacks the app — a friend's home, the store, a
    /// typed address. Every entry is a `manual:` `Participant`. This array is
    /// NEVER read or written by `refreshFromAppGroup` (so the poll can't clobber
    /// it) and NEVER handed to a send path (so it can't ride into a bubble).
    @State var manualParticipants: [Participant] = []
    /// True when the local user declared a future location ("I'll be at…")
    /// instead of sharing live GPS. Keeps a background fix from overwriting it
    /// and drives the "You'll be at X" labels. `selfManualLabel` is the place.
    @State var selfIsManual = false
    @State var selfManualLabel: String? = nil
    @State var currentParticipants: [Participant] = []
    @State var peerDisplayName = "Friend"
    @State var peerNeedsRide = false
    @State var localNeedsRide = false
    @State var isUserIn = false
    /// True while we're waiting on the location fix the user explicitly asked
    /// for via "I'm in"; distinguishes that from the silent launch-time fix that
    /// only centers the map without flipping presence on.
    @State var awaitingImIn = false
    @State var provider = LocationProvider()
    @State var monitor = NetworkMonitor()
    @State var position: MapCameraPosition
    @State var mapDisplayStyle: MapDisplayStyle = .standard
    @State var resetNextTapReturnsToUser = false
    /// Opens at the half detent (search bar + chips + "I'm in" + the
    /// Search/Friends toggle), Apple-Maps style. Drag down to the search-only
    /// peek, or up to full.
    @State var selectedSheetDetent: PresentationDetent = .fraction(0.45)

    /// Gate for the recurring App Group poll to skip writes to
    /// `selectedSheetDetent`. Docs: `docs/ui-research.md` §1 — the self-jump
    /// is caused by a poll re-asserting the detent-selection binding mid-drag.
    /// Set only via `pollRefreshFromAppGroup()`, which owns the `defer` reset;
    /// user-initiated refresh paths leave this `false` so the "agreed just
    /// landed" nudge still fires when a URL open or scene resume drives it.
    @State var suppressPollDetentWrites: Bool = false
    /// Consume-once latches for the selection onChange. The one-tap rewiring
    /// made `selectedResult` a control signal ("selection ⟹ present sheet"),
    /// so PROGRAMMATIC writes must opt out explicitly — and they can't reuse
    /// `suppressPollDetentWrites`, because onChange runs in the NEXT view
    /// update, after that flag's defer already reset it (audit at bb6740d).
    @State var suppressNextSelectionPresentation = false
    @State var suppressNextDeselectDetentRestore = false

    /// Handle for the pending `expandThenFocusSearch` post-animation focus so a
    /// second call (rapid re-entry) can cancel the first — otherwise queued
    /// tasks each fire `searchFocused = true` after the user may have already
    /// backed out of the sheet. See `docs/ui-research.md` §7.
    @State var focusExpandTask: Task<Void, Never>?

    /// Floating map-control tap-target size, scaled with Dynamic Type per
    /// `docs/ui-research.md` §11. `Tokens.Layout.minTapTarget` (44 pt) is the
    /// HIG floor at the default text size; at XXL Dynamic Type this grows so
    /// users with larger system text still hit the target easily. Applied to
    /// The two controls in `topMapToolbar` use this shared hit target, and the
    /// pattern applies to other icon-button call sites.
    @ScaledMetric var floatingControlSize: CGFloat = Tokens.Layout.minTapTarget
    /// Friends-circle diameter, scaled relative to the caption type its
    /// initials render in — a fixed 44pt let AX-size initials overflow it.
    @ScaledMetric(relativeTo: .caption) var friendsCircleSize: CGFloat = Tokens.Layout.searchBarHeight

    // Search
    @State var searchText = ""
    @State var searchResults: [MKMapItem] = []
    @State var rankedSpots: [RankedSpot] = []
    @State var isSearchActive = false
    @State var isSearchLoading = false
    /// Whether the user is mid-typing (showing completer suggestions) or has
    /// committed a search (showing rich result cards). Drives which surface the
    /// sheet renders so suggestions and results never look alike.
    @State var searchState: SearchState = .idle
    @State var completer = SearchCompleter()
    /// Set when we mutate `searchText` programmatically (committing a suggestion
    /// or a category) so the field's `onChange` doesn't treat it as fresh typing
    /// and cancel the very search we just kicked off.
    @State var suppressNextQueryChange = false
    /// Tracks the search field's focus so tapping it lifts the sheet to
    /// medium. Plain state (not @FocusState): the field is a bridged
    /// UISearchBar whose delegate reports focus both ways.
    @State var searchFocused = false
    /// Tracks the profile-name field so the name persists when focus leaves it.
    @FocusState var nameFieldFocused: Bool
    /// The tapped/selected search result — drives the highlighted map pin and the
    /// compact floating detail card (Apple-Maps style).
    @State var selectedResult: MKMapItem?
    /// Whether results show as a scrollable list or as pins on the full map.
    @State var searchViewMode: SearchViewMode = .list
    @State var selectedCategory: CategoryPreset?
    @State var searchTask: Task<Void, Never>?

    // Friends / social
    @State var friendsPanelTab: FriendsPanelTab = .people
    @State var friends: [TweenFriend] = FriendRoster.load()
    @State var editorMode: FriendEditor?
    @State var lastReplyAt: Date? = PingLog.lastIncomingReplyAt
    @State var lastGenericInviteAt: Date? = PingLog.lastGenericInviteAt
    @State var pingTick = 0
    @State var renameText = ""
    @State var toast: String?
    @State var showLocationAlert = false

    // Profile (the name that rides along on invites)
    @State var profileName = UserProfile.displayName ?? ""
    @State var showNamePrompt = false
    @State var nameDraft = ""
    /// Action to run once the user supplies a name from the prompt.
    @State var pendingNameAction: (() -> Void)?
    /// Action to resume once a location fix arrives — the send/agree the user
    /// asked for while no coordinate was available yet. Mirrors
    /// `pendingNameAction`; without it those taps were silently discarded.
    @State var pendingLocationAction: (() -> Void)?
    /// Keeps the cross-process MeetupSync observation alive for the life of
    /// this screen (registration ends when the token deallocates).
    @State var syncToken: MeetupSyncToken?

    // Hand-off / onboarding
    @State var showTutorial = !OnboardingFlags.hasSeenOnboarding
        && !CommandLine.arguments.contains("-SKIP_TUTORIAL")

    /// The single secondary sheet currently presented. Consolidated into one
    /// enum-driven `.sheet(item:)` because stacking multiple `.sheet` modifiers
    /// on the same view as the always-on bottom sheet caused presentations to
    /// silently no-op (Add Friend / Invite never appeared).
    @State var activeSheet: ActiveSheet?

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

    struct PendingInviteRow: Identifiable, Equatable {
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
        case settings

        var id: String {
            switch self {
            case .friends:           return "friends"
            case .contacts:          return "contacts"
            case .invite:            return "invite"
            case .message(let m):    return "message-\(m.id)"
            case .spot(let s):       return "spot-\(s.id)"
            case .addPoint:          return "addPoint"
            case .whereIllBe:        return "whereIllBe"
            case .settings:          return "settings"
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

    struct QuickSpotShortcut: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let query: String
        let systemImage: String
    }

    static let hostTabHarnessParticipants: [Participant] = [
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
    var mapLayer: some View {
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
        // SwiftUI's automatic compass otherwise occupies the same top-right
        // plane as Tween's controls and can appear stranded there. Orientation
        // and recentering now live in the deliberate map toolbar below.
        .mapControlVisibility(.hidden)
    }

    var body: some View {
        // Full-bleed map with floating controls laid out inside the safe area
        // (the ZStack respects it; only the map ignores it). No top gradient
        // or glass — Apple Maps runs the map clean to the screen edge, and
        // every attempt at a status-bar treatment read as a weird band.
        ZStack {
            mapLayer
            topMapToolbar
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
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button("Close") { activeSheet = nil }
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
                    case .settings:
                        SettingsSheet()
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

}
