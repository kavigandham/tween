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
    private static let defaultCenter = CLLocationCoordinate2D(latitude: 39.8283, longitude: -98.5795)

    /// How many candidates the fairness engine resolves routes for in the app.
    private static let rankCap = 8

    /// A reply banner shows only while the last inbound bubble is this fresh.
    private static let replyFreshness: TimeInterval = 60 * 60 // 1 hour
    private let logger = Logger(subsystem: "com.kavigandham.TweenApp", category: "Host")

    /// Prefilled body for an out-of-band SMS nudge to a friend.
    private static let inviteText =
        "Where should we meet? Open Tween and tap “I'm in” so we can find a fair spot. 📍"

    @Environment(\.scenePhase) private var scenePhase

    @State private var savedCoordinate: CLLocationCoordinate2D?
    @State private var peerCoordinate: CLLocationCoordinate2D?
    @State private var agreedMeetup: TweenState?
    /// Every "in" participant beyond the local user and the primary peer —
    /// only populated in group chats (3+ people). Empty for DMs, preserving
    /// the original 2-person behaviour. Refreshed each tick of `pollPeer`.
    @State private var additionalParticipants: [Participant] = []
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
    /// Tracks the search field's focus so tapping it lifts the sheet to medium.
    @FocusState private var searchFocused: Bool
    /// The tapped/selected search result — drives the highlighted map pin and the
    /// compact floating detail card (Apple-Maps style).
    @State private var selectedResult: MKMapItem?
    /// Whether results show as a scrollable list or as pins on the full map.
    @State private var searchViewMode: SearchViewMode = .list
    @State private var selectedCategory: CategoryPreset?
    @State private var searchTask: Task<Void, Never>?

    // Friends / social
    @State private var panelTab: HomePanelTab = .map
    @State private var friendsPanelTab: FriendsPanelTab = .people
    @State private var friends: [TweenFriend] = FriendRoster.load()
    @State private var editorMode: FriendEditor?
    @State private var lastReplyAt: Date? = PingLog.lastIncomingReplyAt
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

    // Hand-off / onboarding
    @State private var showTutorial = !OnboardingFlags.hasSeenOnboarding

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
        var address: String? { item.placemark.title }
        var coordinate: CLLocationCoordinate2D { item.placemark.coordinate }
    }

    /// Context for an incoming spot proposal received via `tween://` link.
    /// Used by SpotDetailCard's Agree/Change actions to build the reply
    /// bubble's TweenState (sender name + participants + counter flag).
    struct IncomingProposalContext {
        let senderName: String?
        let participants: [Participant]
        let agreedNames: [String]
        let isCounter: Bool
    }

    /// Every secondary sheet the home surface can present, multiplexed through a
    /// single `.sheet(item:)`.
    enum ActiveSheet: Identifiable {
        case contacts
        case invite
        case message(PendingMessage)
        case spot(SpotSelection)

        var id: String {
            switch self {
            case .contacts:          return "contacts"
            case .invite:            return "invite"
            case .message(let m):    return "message-\(m.id)"
            case .spot(let s):       return "spot-\(s.id)"
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

    init() {
        let cached = LocationCache.loadSelf()
        _savedCoordinate = State(initialValue: cached?.coordinate)
        _isUserIn = State(initialValue: cached != nil && LocationCache.isActive)
        _agreedMeetup = State(initialValue: LocationCache.loadAgreedMeetup())
        _position = State(initialValue: Self.cameraPosition(for: [cached?.coordinate ?? Self.defaultCenter]))
    }

    var body: some View {
        Map(position: $position, selection: $selectedResult) {
            if let coord = savedCoordinate {
                Annotation("You", coordinate: coord) {
                    TweenPin(role: isUserIn ? .selfActive : .selfDot)
                }
            }
            if let peer = peerCoordinate {
                Annotation("Friend", coordinate: peer) {
                    TweenPin(role: .friend)
                }
            }
            // Additional remote participants (groups of 3+). Each is named so
            // the map matches what the iMessage bubble shows.
            ForEach(additionalParticipants) { participant in
                Annotation(participant.name, coordinate: participant.coordinate) {
                    TweenPin(role: .friend)
                }
            }
            if let midpoint {
                Annotation("Midpoint", coordinate: midpoint) {
                    TweenPin(role: .midpoint)
                }
            }
            if let agreedMeetup, agreedMeetup.kind == .place {
                Annotation(agreedMeetup.text, coordinate: agreedMeetup.coordinate, anchor: .bottom) {
                    TweenPin(role: .fairSpot)
                }
            }
            // A selectable pin for every visible search result. The selected one
            // becomes a custom annotation carrying the A/B distance label above a
            // larger brand icon; the rest are category markers. Tapping the empty
            // map clears the selection.
            ForEach(displayedItems, id: \.self) { item in
                if item == selectedResult {
                    Annotation(item.name ?? "Place", coordinate: item.placemark.coordinate, anchor: .bottom) {
                        VStack(spacing: Tokens.Spacing.s1) {
                            ABDistanceLabel(
                                selfCoord: savedCoordinate,
                                peerCoord: peerCoordinate,
                                target: item.placemark.coordinate,
                                ranked: rankedMatch(for: item))
                            Image(systemName: resultSymbol(for: item))
                                .font(Tokens.Typography.title2)
                                .foregroundStyle(.white)
                                .padding(Tokens.Spacing.s3)
                                .background(resultRole(for: item).fill, in: Circle())
                                .tweenElevation(.pin)
                        }
                    }
                    .tag(item)
                } else {
                    Marker(item.name ?? "Place", systemImage: resultSymbol(for: item), coordinate: item.placemark.coordinate)
                        .tint(resultRole(for: item).fill)
                        .tag(item)
                }
            }
        }
        .ignoresSafeArea()
        .mapStyle(mapDisplayStyle.mapStyle)
        .overlay(alignment: .top) { topSafeAreaGlass }
        .overlay(alignment: .topTrailing) { topTrailingControls }
        .overlay(alignment: .top) { viewModeToggle }
        .overlay(alignment: .bottom) { compactCard }
        .animation(Tokens.Motion.snappy, value: selectedResult)
        .onChange(of: selectedResult) { _, item in
            resetNextTapReturnsToUser = false
            if let item { focusMap(on: item) }
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
                .presentationBackgroundInteraction(.enabled)
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
                .sheet(item: $activeSheet) { sheet in
                    switch sheet {
                    case .contacts:
                        ContactSearchView { friend in
                            FriendRoster.add(friend)
                            friends = FriendRoster.load()
                            activeSheet = nil
                        }
                    case .invite:
                        ActivityView(items: [Self.inviteText]) { activeSheet = nil }
                    case .message(let pending):
                        MessageComposeSheet(recipients: pending.recipients,
                                            body: pending.body,
                                            message: pending.message) {
                            activeSheet = nil
                        }
                    case .spot(let selection):
                        SpotDetailCard(
                            name: selection.name,
                            address: selection.address,
                            coordinate: selection.coordinate,
                            ranked: selection.ranked,
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
                    }
                }
        }
        .alert("Rename Friend", isPresented: renameBinding, presenting: editorMode) { _ in
            TextField("Name", text: $renameText)
            Button("Save", action: commitRename)
            Button("Cancel", role: .cancel) { editorMode = nil }
        } message: { editor in
            Text("Choose a new name for \(editor.friend.name).")
        }
        .onChange(of: provider.status) { _, status in
            let wasAwaitingImIn = awaitingImIn
            if case let .got(coord) = status {
                withAnimation(Tokens.Motion.spring) {
                    savedCoordinate = coord
                    // Only the explicit "I'm in" gesture flips presence on and
                    // persists the coordinate for the peer hand-off. The silent
                    // launch fix just recenters the map on a self dot.
                    if awaitingImIn {
                        LocationCache.save(coord, isActive: true)
                        saveLocalParticipant(coord)
                        isUserIn = true
                    }
                }
                awaitingImIn = false
                reframe()
            } else if status == .denied || status == .failed {
                awaitingImIn = false
                if wasAwaitingImIn {
                    showLocationAlert = true
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Mirror the extension's memory discipline: drop in-flight work when
            // we're no longer foregrounded.
            if phase != .active { searchTask?.cancel() }
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
        .task { await pollPeer() }
        .task { requestInitialLocation() }
        .onAppear { _ = refreshFromAppGroup() }
        .onReceive(appGroupDidChangePublisher) { _ in
            // Catches in-process writes (e.g. host app's own "I'm in" button).
            // Extension writes don't fire this — see pollPeer + scenePhase
            // handler above for the cross-process path.
            Task { @MainActor in
                _ = refreshFromAppGroup()
            }
        }
        .onOpenURL(perform: handleIncomingURL)
        .alert("Location Unavailable", isPresented: $showLocationAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(provider.status == .denied
                 ? "Turn on location access in Settings to share where you are."
                 : "We couldn't get your location. Try again in a moment.")
        }
    }

    // MARK: - Bottom sheet

    /// True when the sheet is collapsed to its search-bar-only peek.
    private var isMinimalDetent: Bool { selectedSheetDetent == .height(Tokens.Layout.sheetPeekHeight) }

    @ViewBuilder
    private var sheetContent: some View {
        VStack(spacing: Tokens.Spacing.s3) {
            // Always visible — at the minimal detent this is the entire sheet, an
            // Apple-Maps-style search bar floating over a full-screen map.
            searchBar

            // Everything else is revealed once the sheet is lifted off its peek.
            if !isMinimalDetent {
                if !monitor.isOnline { offlineBanner }
                replyBanner

                // The Search/Friends switch — and the friend roster behind it —
                // are reachable at the half detent too; only the collapsed peek
                // hides them so it stays a clean search bar.
                Picker("Panel", selection: $panelTab) {
                    ForEach(HomePanelTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .frame(minHeight: Tokens.Layout.minTapTarget)
                .accessibilityHint("Switches between place search and your friend roster")

                if panelTab == .waiting {
                    friendsPanel
                } else {
                    mapPanel
                }
            }
        }
        .padding(.top, Tokens.Spacing.s2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Tokens.Motion.snappy, value: selectedSheetDetent)
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
        switch searchState {
        case .suggesting:
            suggestionsList
        case .idle, .results:
            categoryChips
            Divider()
            resultsScroll
        }
    }

    /// Compact completer-driven suggestion rows shown while the user types.
    /// Tapping a row commits that suggestion as a full search.
    private var suggestionsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if completer.results.isEmpty {
                    HStack(spacing: Tokens.Spacing.s2) {
                        ProgressView()
                        Text("Searching nearby...")
                            .font(Tokens.Typography.footnote)
                            .foregroundStyle(Tokens.Palette.textSecondary)
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
        let step = Tokens.Layout.minTapTarget + Tokens.Spacing.s2
        return ZStack(alignment: .topTrailing) {
            infoButton
            mapStyleButton
                .offset(y: step)
            resetMapButton
                .offset(y: step * 2)
        }
        .frame(
            width: Tokens.Layout.minTapTarget * 5 + Tokens.Spacing.s2 * 4,
            height: Tokens.Layout.minTapTarget * 3 + Tokens.Spacing.s2 * 2,
            alignment: .topTrailing
        )
        .padding(.top, Tokens.Spacing.s9 + Tokens.Spacing.s2)
        .padding(.trailing, Tokens.Spacing.s4)
    }

    private var topSafeAreaGlass: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .frame(height: 132)
            .mask(
                LinearGradient(
                    colors: [.black, .black.opacity(0.72), .clear],
                    startPoint: .top,
                    endPoint: .bottom)
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
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
            .frame(width: 44, height: 44)
            .background(
                isSelected ? Tokens.Palette.brand : Color(.systemBackground).opacity(0.92),
                in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .strokeBorder(Tokens.Palette.surfaceSecondary.opacity(isSelected ? 0 : 1), lineWidth: 1)
            }
            .tweenElevation(.floating)
    }


    private var resetMapButton: some View {
        Button {
            resetMapCamera()
        } label: {
            Image(systemName: "location.viewfinder")
                .font(Tokens.Typography.callout)
                .foregroundStyle(Tokens.Palette.brand)
                .frame(width: 44, height: 44)
                .background(Color(.systemBackground).opacity(0.92), in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                        .strokeBorder(Tokens.Palette.surfaceSecondary, lineWidth: 1)
                }
                .tweenElevation(.floating)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reset map")
        .accessibilityHint("First shows visible places, then returns to your location")
    }

    /// Floating control to re-show the first-run walkthrough.
    private var infoButton: some View {
        Button { showTutorial = true } label: {
            Image(systemName: "info.circle.fill")
                .font(Tokens.Typography.title2)
                .foregroundStyle(Tokens.Palette.brand)
                .frame(width: 44, height: 44)
                .background(Color(.systemBackground).opacity(0.92), in: Circle())
                .overlay {
                    Circle().strokeBorder(Tokens.Palette.surfaceSecondary, lineWidth: 1)
                }
                .tweenElevation(.floating)
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
            .frame(width: 200)
            .padding(Tokens.Spacing.s1)
            .background(.ultraThinMaterial, in: Capsule())
            .tweenElevation(.floating)
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

            switch friendsPanelTab {
            case .people:
                peoplePanel
            case .rides:
                ridesPanel
            }
        }
        .animation(Tokens.Motion.snappy, value: friendsPanelTab)
    }

    private var peoplePanel: some View {
        VStack(spacing: Tokens.Spacing.s3) {
            HStack(spacing: Tokens.Spacing.s2) {
                Image(systemName: "person.text.rectangle")
                    .foregroundStyle(Tokens.Palette.textSecondary)
                TextField("Your name", text: $profileName)
                    .textFieldStyle(.plain)
                    .submitLabel(.done)
                    .onSubmit(saveProfileName)
                    .onChange(of: profileName) { _, _ in saveProfileName() }
                    .accessibilityLabel("Your name")
                    .accessibilityHint("Shown to friends when you invite them")
            }
            .padding(Tokens.Spacing.s3)
            .tweenGlass()
            .padding(.horizontal)

            HStack(spacing: Tokens.Spacing.s2) {
                Button { activeSheet = .contacts } label: {
                    Label("Add Friend", systemImage: "person.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(Tokens.Palette.brand)
                .accessibilityHint("Picks someone from your contacts")

                Button { activeSheet = .invite } label: {
                    Label("Invite", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(Tokens.Palette.brand)
                .accessibilityHint("Shares an invite link to Tween")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)

            if friends.isEmpty {
                ContentUnavailableView(
                    "No Friends Yet",
                    systemImage: "person.2",
                    description: Text("Add someone to ping them when you're ready to meet up."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
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
                .listStyle(.plain)
            }
        }
    }

    private var ridesPanel: some View {
        VStack(spacing: Tokens.Spacing.s4) {
            ContentUnavailableView(
                "No Rides Yet",
                systemImage: "car.2",
                description: Text("Group pickup planning will appear here."))
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal)
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

    private var searchBar: some View {
        HStack(spacing: Tokens.Spacing.s2) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Tokens.Palette.textSecondary)
            TextField("Search for a spot...", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .submitLabel(.search)
                .accessibilityLabel("Search for a spot")
                .onSubmit(commitSearch)
                .onChange(of: searchText) { _, query in
                    if query != selectedCategory?.searchQuery { selectedCategory = nil }
                    // A new query invalidates any pin/card from the old result set.
                    selectedResult = nil
                    handleQueryChange(query)
                }
            if !searchText.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .frame(width: Tokens.Layout.minTapTarget, height: Tokens.Layout.minTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(Tokens.Spacing.s3)
        .frame(minHeight: Tokens.Layout.searchBarHeight)
        .tweenGlass()
        .padding(.horizontal)
        // Tapping into the field lifts the collapsed sheet to medium so the chips
        // and suggestions have room to appear.
        .onTapGesture { expandToSearchDetent() }
        .onChange(of: searchFocused) { _, focused in
            if focused { expandToSearchDetent() }
        }
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
                                selected ? AnyShapeStyle(Tokens.Palette.brand) : AnyShapeStyle(.thinMaterial),
                                in: Capsule()
                            )
                            .foregroundStyle(selected ? Color.white : Tokens.Palette.textPrimary)
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
            VStack(spacing: Tokens.Spacing.s3) {
                if searchState == .idle {
                    presenceControls
                } else if searchState == .results || isSearchLoading {
                    resultsList
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    @ViewBuilder
    private var presenceControls: some View {
        if isUserIn {
            Button(role: .destructive, action: leave) {
                Label("Leave", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Tokens.Palette.destructive)
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
                .background(.thinMaterial, in: Capsule())
                .accessibilityLabel(peerDistanceText)
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
        if let item = selectedResult {
            let ranked = rankedMatch(for: item)
            compactCardContent(item: item, ranked: ranked, isAgreedMeetup: false)
        } else if let agreedMeetup, agreedMeetup.kind == .place {
            compactCardContent(item: mapItem(for: agreedMeetup), ranked: nil, isAgreedMeetup: true)
        }
    }

    private func compactCardContent(item: MKMapItem, ranked: RankedSpot?, isAgreedMeetup: Bool) -> some View {
        let selection = SpotSelection(item: item, ranked: ranked)
        return VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            HStack(alignment: .top, spacing: Tokens.Spacing.s2) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                    Text(item.name ?? "Place")
                        .font(Tokens.Typography.headline)
                        .lineLimit(1)
                    if let address = item.placemark.title, !address.isEmpty {
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
        .padding(Tokens.Spacing.s4)
        .tweenGlass(radius: Tokens.Radius.card)
        .tweenElevation(.floating)
        .padding(.horizontal)
        // Clear the always-peeked search sheet without leaving a loose map
        // strip between the card and search bar.
        .padding(.bottom, Tokens.Layout.sheetPeekHeight - Tokens.Spacing.s4)
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

    private var peerDistanceText: String? {
        guard let savedCoordinate, let peerCoordinate else { return nil }
        let distance = ABDistanceLabel.formatDistance(from: savedCoordinate, to: peerCoordinate)
        return "Distance between you: \(distance)"
    }

    // MARK: - Actions

    private func imIn() {
        ensureNamed {
            awaitingImIn = true
            provider.requestOnce()
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
    private func requestInitialLocation() {
        guard !(savedCoordinate != nil && LocationCache.isActive) else { return }
        provider.requestOnce()
    }

    private func leave() {
        withAnimation(Tokens.Motion.spring) { isUserIn = false }
        let myName = UserProfile.displayName ?? UserName.fallback
        let fallbackCoordinate = LocationCache.loadSelf()?.coordinate
            ?? LocationCache.loadParticipants().first(where: { $0.name == myName })?.coordinate
            ?? Self.defaultCenter
        let remainingParticipants = LocationCache.loadParticipants().filter { $0.name != myName }
        // The outgoing leave bubble tells everyone else who remains in.
        // Locally, leaving means this device is no longer watching the meetup.
        LocationCache.saveParticipantSnapshot([], localName: myName)
        LocationCache.deactivateSelf()
        LocationCache.clearAgreedMeetup()
        agreedMeetup = nil
        selectedResult = nil
        _ = refreshFromAppGroup()
        presentLeaveMessage(participants: remainingParticipants, fallbackCoordinate: fallbackCoordinate)
    }

    private func presentLeaveMessage(participants: [Participant],
                                     fallbackCoordinate: CLLocationCoordinate2D) {
        let state = TweenState(
            text: "I'm out",
            latitude: fallbackCoordinate.latitude,
            longitude: fallbackCoordinate.longitude,
            senderName: UserProfile.displayName,
            kind: .participant,
            messageType: .leave,
            participants: participants
        )

        guard MFMessageComposeViewController.canSendText() else {
            UIPasteboard.general.string = "I'm out of this meetup."
            showToast("Messages unavailable - copied an I'm out reply")
            return
        }

        Task { @MainActor in
            let image = await BubbleImageRenderer.makeImage(
                state: state,
                participants: state.participants,
                localName: UserProfile.displayName ?? UserName.fallback)

            let layout = MSMessageTemplateLayout()
            layout.image = image
            BubbleCaption.apply(to: layout, state: state, totalSeats: max(participants.count + 1, 2))

            let message = MSMessage()
            message.url = state.encodedURL(scheme: "tween", host: "m")
            message.layout = layout

            activeSheet = .message(PendingMessage(
                recipients: [],
                body: "I'm out of this meetup.",
                message: message))
        }
    }

    private func saveLocalParticipant(_ coordinate: CLLocationCoordinate2D) {
        let myName = UserProfile.displayName ?? UserName.fallback
        let participants = LocationCache.loadParticipants().filter { $0.name != myName } + [
            Participant(id: myName, name: myName, coordinate: coordinate)
        ]
        LocationCache.saveParticipantSnapshot(participants, localName: myName)
    }

    // MARK: - Hand-off

    /// Centers the map on a tapped result and drops the sheet to its peek so the
    /// map is visible. Frames self, peer, and the spot together when both
    /// participants are known; otherwise zooms tight on the spot.
    private func focusMap(on item: MKMapItem) {
        let coords = [savedCoordinate, peerCoordinate, item.placemark.coordinate].compactMap { $0 }
        if coords.count > 1 {
            withAnimation(Tokens.Motion.gentle) {
                position = Self.cameraPosition(for: coords, padding: 1.45, minSpan: 0.04)
            }
        } else {
            withAnimation(Tokens.Motion.gentle) {
                position = .region(MKCoordinateRegion(
                    center: item.placemark.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
            }
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
        let context = [savedCoordinate, peerCoordinate].compactMap { $0 }
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
            let coord = selection.coordinate
            let state = TweenState(
                text: selection.name,
                latitude: coord.latitude,
                longitude: coord.longitude,
                senderName: UserProfile.displayName,
                kind: .place,
                senderCoordinate: savedCoordinate)        // set by ensureNamed
            guard let appURL = state.encodedURL(scheme: "tween", host: "m") else { return }

            // Still stage the draft so the sender's own extension can pre-fill if
            // they open Tween in the drawer (device-local; not how the friend gets it).
            OutgoingDraftStore.save(OutgoingDraft(
                spotName: selection.name,
                latitude: coord.latitude,
                longitude: coord.longitude))

            let who = UserProfile.displayName ?? "I"
            let body = """
            \(who) picked \(selection.name) on Tween.
            Open this in Tween to share your ping:
            \(appURL.absoluteString)
            """

            if MFMessageComposeViewController.canSendText() {
                // Route through the existing enum-driven sheet; empty recipients so
                // the user picks who in Messages (no selected-friend concept here).
                activeSheet = .message(PendingMessage(recipients: [], body: body))
            } else {
                UIPasteboard.general.string = body
                showToast("Message copied — paste it into your chat")
            }
        }
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
    private func pingFriend(_ friend: TweenFriend) {
        PingLog.logPing(for: friend.id)
        pingTick += 1

        guard let handle = friend.handle, MFMessageComposeViewController.canSendText() else {
            UIPasteboard.general.string = Self.inviteText
            let reason = friend.handle == nil ? "No phone number" : "Messages unavailable"
            showToast("\(reason) - invite copied for \(friend.name)")
            return
        }

        // If we don't have a self coord yet, fall back to the plain-text
        // composer immediately — no point waiting on a snapshot for an empty
        // map. The user can still tap "I'm in" themselves once they open Tween.
        guard let myCoord = LocationCache.loadSelf()?.coordinate else {
            activeSheet = .message(PendingMessage(recipients: [handle], body: Self.inviteText))
            return
        }

        let myName = UserProfile.displayName ?? UserName.fallback
        let state = TweenState(
            text: "I'm in",
            latitude: myCoord.latitude,
            longitude: myCoord.longitude,
            senderName: UserProfile.displayName,
            kind: .participant,
            messageType: .invite,
            participants: [Participant(id: myName, name: myName, coordinate: myCoord)]
        )

        // Render the bubble image off the main actor (it's an MKMapSnapshotter
        // round-trip — usually under a second, but we don't want to block).
        // Once ready, build the MSMessage on the main actor and present.
        Task { @MainActor in
            let image = await BubbleImageRenderer.makeImage(
                state: state,
                participants: state.participants,
                localName: myName)

            let layout = MSMessageTemplateLayout()
            layout.image = image
            BubbleCaption.apply(to: layout, state: state, totalSeats: 2)

            let message = MSMessage()
            message.url = state.encodedURL(scheme: "tween", host: "m")
            message.layout = layout

            activeSheet = .message(PendingMessage(
                recipients: [handle],
                body: Self.inviteText,
                message: message))
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

    /// The region search is biased toward the midpoint when both friends are
    /// known, otherwise whichever single location we have. A tighter local span
    /// keeps common searches like coffee, food, and gas near the active context.
    private var searchRegion: MKCoordinateRegion {
        if let me = savedCoordinate, let peer = peerCoordinate {
            let center = Self.midpoint(me, peer)
            let latDelta = max(abs(me.latitude - peer.latitude) * 1.35, 0.25)
            let lonDelta = max(abs(me.longitude - peer.longitude) * 1.35, 0.25)
            return MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
        }

        let center = savedCoordinate ?? peerCoordinate ?? Self.defaultCenter
        let span = savedCoordinate != nil || peerCoordinate != nil ? 0.18 : 0.5
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
    }

    /// Reacts to each keystroke. An empty field returns to quick chips; anything
    /// else feeds the completer immediately and launches a lightly debounced real
    /// local search so results appear without waiting for Return.
    private func handleQueryChange(_ query: String) {
        expandToSearchDetent()
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
        isSearchLoading = true
        searchState = .suggesting
        completer.update(query: trimmed, region: searchRegion)

        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await runSearch(trimmed: trimmed, reframeMap: false)
        }
    }

    /// Commits a suggestion as a full search.
    private func selectSuggestion(_ completion: MKLocalSearchCompletion) {
        suppressNextQueryChange = true
        searchText = completion.title
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
        return true
    }

    /// Runs `MKLocalSearch`, surfaces raw hits immediately, then ranks the same
    /// hits by fairness when both coordinates are known. Live typing keeps the
    /// map still; committed searches (Return, suggestion, chip) may reframe it.
    @MainActor
    private func runSearch(trimmed: String, reframeMap: Bool) async {
        guard monitor.isOnline else {
            isSearchLoading = false
            searchResults = []
            rankedSpots = []
            searchState = .idle
            return
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.region = searchRegion

        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch {
            guard !Task.isCancelled else { return }
            isSearchLoading = false
            searchResults = []
            rankedSpots = []
            isSearchActive = true
            searchState = .results
            return
        }

        guard !Task.isCancelled else { return }
        let items = response.mapItems

        rankedSpots = []
        searchResults = items
        isSearchActive = true
        isSearchLoading = false
        searchState = .results
        if reframeMap {
            frameSearchResults()
        }

        if let me = savedCoordinate, let peer = peerCoordinate {
            let myName = UserProfile.displayName ?? UserName.fallback
            var participants: [Participant] = [
                Participant(id: myName, name: myName, coordinate: me),
                Participant(id: "peer", name: "Friend", coordinate: peer)
            ]
            participants.append(contentsOf: additionalParticipants)
            let cap = participants.count >= 3
                ? FairnessRanker.recommendedCap(for: participants.count)
                : Self.rankCap
            let ranked = await FairnessRanker.rank(
                candidates: items, participants: participants, cap: cap)
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
            suppressNextQueryChange = true
            selectedCategory = preset
            searchText = preset.searchQuery
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
        while !Task.isCancelled {
            _ = refreshFromAppGroup()
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    @MainActor
    @discardableResult
    private func refreshFromAppGroup() -> Bool {
        // Group-aware path: the extension writes the full participants roster
        // whenever it receives or sends a bubble. If present, keep the first
        // remote participant as `peerCoordinate` for legacy call sites and draw
        // the rest as group participants.
        let myName = UserProfile.displayName ?? UserName.fallback
        let roster = LocationCache.loadParticipants()
        let remotes = roster.filter { $0.name != myName }

        let newPeer: CLLocationCoordinate2D?
        let newExtras: [Participant]
        if let firstRemote = remotes.first {
            newPeer = firstRemote.coordinate
            newExtras = Array(remotes.dropFirst())
        } else {
            newPeer = LocationCache.isPeerActive ? LocationCache.loadPeer()?.coordinate : nil
            newExtras = []
        }

        var didChange = false
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

        let cachedSelf = LocationCache.loadSelf()?.coordinate
        if !same(savedCoordinate, cachedSelf) {
            savedCoordinate = cachedSelf
            didChange = true
        }
        let active = LocationCache.isActive
        if isUserIn != active {
            isUserIn = active
            didChange = true
        }

        let cachedAgreedMeetup = LocationCache.loadAgreedMeetup()
        if agreedMeetup != cachedAgreedMeetup {
            agreedMeetup = cachedAgreedMeetup
            selectedResult = nil
            didChange = true
            if cachedAgreedMeetup != nil {
                panelTab = .map
                selectedSheetDetent = .height(Tokens.Layout.sheetPeekHeight)
            }
        }

        lastReplyAt = PingLog.lastIncomingReplyAt
        if didChange {
            reframe()
        }
        return didChange
    }

    // MARK: - Geometry

    private var midpoint: CLLocationCoordinate2D? {
        guard let me = savedCoordinate, let peer = peerCoordinate else { return nil }
        // Groups (3+): centroid of every "in" participant. 2-person path
        // collapses to the legacy midpoint because the extra-participants
        // array is empty there.
        if additionalParticipants.isEmpty {
            return Self.midpoint(me, peer)
        }
        let extras = additionalParticipants.map(\.coordinate)
        let all = [me, peer] + extras
        let lat = all.map(\.latitude).reduce(0, +) / Double(all.count)
        let lon = all.map(\.longitude).reduce(0, +) / Double(all.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func reframe() {
        var coords = [savedCoordinate, peerCoordinate].compactMap { $0 }
        coords.append(contentsOf: additionalParticipants.map(\.coordinate))
        if let agreedMeetup {
            coords.append(agreedMeetup.coordinate)
        }
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

    private func handleIncomingURL(_ url: URL) {
        if url.scheme == "tween", url.host == "search" {
            panelTab = .map
            selectedSheetDetent = .fraction(0.45)
            searchFocused = true
            return
        }

        guard let state = TweenState(url: url) else { return }
        logger.debug("Host opened Tween URL type=\(state.messageType.rawValue, privacy: .public) kind=\(state.kind.rawValue, privacy: .public)")

        // Save the sender's coord as peer so the map can frame both pings.
        if let peer = state.participantCoordinate {
            LocationCache.savePeer(peer, isActive: true)
            peerCoordinate = peer
            logger.debug("Host saved peer from URL lat=\(peer.latitude, privacy: .public) lon=\(peer.longitude, privacy: .public)")
        }
        // Refresh participants array too so the group view sees everyone "in".
        // A `.leave` message may intentionally carry an empty roster.
        if !state.participants.isEmpty || state.messageType == .leave {
            let myName = UserProfile.displayName ?? UserName.fallback
            LocationCache.saveParticipantSnapshot(state.participants, localName: myName)
            if let firstRemote = state.participants.first(where: { $0.name != myName }) {
                peerCoordinate = firstRemote.coordinate
            } else {
                peerCoordinate = nil
            }
        }
        // Only stamp the inbound-reply timestamp for ACTUAL replies — invites,
        // proposals, and agrees from a peer. Plain `tween://search` deep links
        // (handled above) and self-opened URLs shouldn't inflate the banner.
        if state.kind == .participant || state.messageType == .agree || state.messageType == .leave {
            PingLog.lastIncomingReplyAt = Date()
            lastReplyAt = PingLog.lastIncomingReplyAt
        }

        switch state.messageType {
        case .propose, .counter:
            if state.messageType == .counter {
                LocationCache.clearAgreedMeetup()
                agreedMeetup = nil
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
                    participants: state.participants,
                    agreedNames: state.agreedNames,
                    isCounter: state.messageType == .counter))
            activeSheet = .spot(selection)
            // Frame the map so the user can see the proposed spot in context.
            withAnimation(Tokens.Motion.gentle) {
                position = Self.cameraPosition(
                    for: [savedCoordinate, peerCoordinate, state.coordinate].compactMap { $0 },
                    padding: 1.45,
                    minSpan: 0.04)
            }

        case .agree:
            if state.isFullyAgreed {
                LocationCache.saveAgreedMeetup(state)
                agreedMeetup = state
                selectedResult = nil
            }
            // A friend's reply that they agree to a previously-proposed spot.
            // No interactive UI needed — just frame the map on it and toast.
            withAnimation(Tokens.Motion.gentle) {
                position = Self.cameraPosition(
                    for: [savedCoordinate, peerCoordinate, state.coordinate].compactMap { $0 },
                    padding: 1.45,
                    minSpan: 0.04)
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
            LocationCache.clearAgreedMeetup()
            agreedMeetup = nil
            reframe()
            let who = state.senderName ?? "Your friend"
            showToast("\(who) is out.")
        }
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
        var agreed = incoming.agreedNames
        if !agreed.contains(myName) { agreed.append(myName) }
        let mySelf = LocationCache.loadSelf()?.coordinate

        let state = TweenState(
            text: selection.name,
            latitude: selection.coordinate.latitude,
            longitude: selection.coordinate.longitude,
            senderName: UserProfile.displayName,
            kind: .place,
            senderCoordinate: mySelf,
            action: .agree,
            messageType: .agree,
            participants: incoming.participants,
            agreedNames: agreed
        )

        // Async render the bubble image, then present the composer. The
        // recipient field is left empty so the user picks the same friend
        // they got the link from.
        Task { @MainActor in
            let image = await BubbleImageRenderer.makeImage(
                state: state,
                participants: state.participants,
                localName: myName)

            let layout = MSMessageTemplateLayout()
            layout.image = image
            BubbleCaption.apply(to: layout, state: state, totalSeats: state.participants.count)

            let message = MSMessage()
            message.url = state.encodedURL(scheme: "tween", host: "m")
            message.layout = layout

            activeSheet = .message(PendingMessage(
                recipients: [],
                body: "I'm in for \(selection.name)",
                message: message))
        }
    }

    /// Lifts the bottom sheet and focuses the search bar so the user can
    /// pick a different spot than the one their friend proposed. Drops a
    /// pin on the rejected spot so they have spatial context.
    private func startChangeFlow(initialCoord: CLLocationCoordinate2D) {
        panelTab = .map
        selectedSheetDetent = .fraction(0.45)
        searchFocused = true
        withAnimation(Tokens.Motion.gentle) {
            position = Self.cameraPosition(
                for: [savedCoordinate, peerCoordinate, initialCoord].compactMap { $0 },
                padding: 1.45,
                minSpan: 0.04)
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
}

#Preview {
    OnboardingView()
}
