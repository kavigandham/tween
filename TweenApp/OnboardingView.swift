import SwiftUI
import MapKit
import CoreLocation
import MessageUI
import UIKit

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

    /// Prefilled body for an out-of-band SMS nudge to a friend.
    private static let inviteText =
        "Where should we meet? Open Tween and tap “I'm in” so we can find a fair spot. 📍"

    @Environment(\.scenePhase) private var scenePhase

    @State private var savedCoordinate: CLLocationCoordinate2D?
    @State private var peerCoordinate: CLLocationCoordinate2D?
    @State private var isUserIn = false
    /// True while we're waiting on the location fix the user explicitly asked
    /// for via "I'm in"; distinguishes that from the silent launch-time fix that
    /// only centers the map without flipping presence on.
    @State private var awaitingImIn = false
    @State private var provider = LocationProvider()
    @State private var monitor = NetworkMonitor()
    @State private var position: MapCameraPosition
    @State private var selectedSheetDetent: PresentationDetent = .height(120)

    // Search
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var rankedSpots: [RankedSpot] = []
    @State private var isSearchActive = false
    @State private var selectedCategory: CategoryPreset?
    @State private var searchTask: Task<Void, Never>?

    // Friends / social
    @State private var panelTab: HomePanelTab = .map
    @State private var friends: [TweenFriend] = FriendRoster.load()
    @State private var editorMode: FriendEditor?
    @State private var lastReplyAt: Date? = PingLog.lastIncomingReplyAt
    @State private var pingTick = 0
    @State private var renameText = ""
    @State private var toast: String?

    // Hand-off / onboarding
    @State private var showTutorial = !OnboardingFlags.hasSeenOnboarding

    /// The single secondary sheet currently presented. Consolidated into one
    /// enum-driven `.sheet(item:)` because stacking multiple `.sheet` modifiers
    /// on the same view as the always-on bottom sheet caused presentations to
    /// silently no-op (Add Friend / Invite never appeared).
    @State private var activeSheet: ActiveSheet?

    /// Identifiable wrapper so the SMS composer can be presented via `sheet(item:)`.
    struct PendingMessage: Identifiable {
        let id = UUID()
        let recipients: [String]
        let body: String
    }

    /// A tapped search result staged for the detail card. Carries the map item
    /// plus its ranking (when both coordinates are known) so the card can show
    /// an ETA chip.
    struct SpotSelection: Identifiable {
        let id = UUID()
        let item: MKMapItem
        let ranked: RankedSpot?

        var name: String { item.name ?? "Spot" }
        var address: String? { item.placemark.title }
        var coordinate: CLLocationCoordinate2D { item.placemark.coordinate }
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

    init() {
        let cached = LocationCache.loadSelf()
        _savedCoordinate = State(initialValue: cached?.coordinate)
        _isUserIn = State(initialValue: cached != nil && LocationCache.isActive)
        _position = State(initialValue: Self.cameraPosition(for: [cached?.coordinate ?? Self.defaultCenter]))
    }

    var body: some View {
        Map(position: $position) {
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
            if let mid = midpoint {
                Annotation("Midpoint", coordinate: mid) {
                    TweenPin(role: .midpoint)
                }
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) { infoButton }
        .sheet(isPresented: .constant(true)) {
            sheetContent
                .presentationDetents(
                    [.height(120), .fraction(0.48), .fraction(0.80)],
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
                .sheet(item: $activeSheet) { sheet in
                    switch sheet {
                    case .contacts:
                        ContactSearchView { friend in
                            FriendRoster.add(friend)
                            friends = FriendRoster.load()
                            activeSheet = nil
                        }
                    case .invite:
                        ActivityView(items: [Self.inviteText])
                    case .message(let pending):
                        MessageComposeSheet(recipients: pending.recipients, body: pending.body) {
                            activeSheet = nil
                        }
                    case .spot(let selection):
                        SpotDetailCard(
                            name: selection.name,
                            address: selection.address,
                            coordinate: selection.coordinate,
                            ranked: selection.ranked,
                            onSendToChat: { sendToChat(selection) }
                        )
                    }
                }
        }
        .fullScreenCover(isPresented: $showTutorial) {
            OnboardingTutorialView(onDone: dismissTutorial)
        }
        .alert("Rename Friend", isPresented: renameBinding, presenting: editorMode) { _ in
            TextField("Name", text: $renameText)
            Button("Save", action: commitRename)
            Button("Cancel", role: .cancel) { editorMode = nil }
        } message: { editor in
            Text("Choose a new name for \(editor.friend.name).")
        }
        .onChange(of: provider.status) { _, status in
            if case let .got(coord) = status {
                withAnimation(Tokens.Motion.spring) {
                    savedCoordinate = coord
                    // Only the explicit "I'm in" gesture flips presence on and
                    // persists the coordinate for the peer hand-off. The silent
                    // launch fix just recenters the map on a self dot.
                    if awaitingImIn {
                        LocationCache.save(coord)
                        isUserIn = true
                    }
                }
                awaitingImIn = false
                reframe()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Mirror the extension's memory discipline: drop in-flight work when
            // we're no longer foregrounded.
            if phase != .active { searchTask?.cancel() }
        }
        .task { await pollPeer() }
        .task { requestInitialLocation() }
    }

    // MARK: - Bottom sheet

    @ViewBuilder
    private var sheetContent: some View {
        VStack(spacing: Tokens.Spacing.s3) {
            if !monitor.isOnline { offlineBanner }
            replyBanner
            Picker("Panel", selection: $panelTab) {
                ForEach(HomePanelTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .accessibilityHint("Switches between place search and your friend roster")

            switch panelTab {
            case .map:     mapPanel
            case .waiting: friendsPanel
            }
        }
        .padding(.top, Tokens.Spacing.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) { toastView }
        .sensoryFeedback(trigger: isUserIn) { _, isIn in isIn ? .success : nil }
        .sensoryFeedback(.impact, trigger: pingTick)
    }

    /// Existing place-search surface.
    @ViewBuilder
    private var mapPanel: some View {
        searchBar
        categoryChips
        Divider()
        resultsScroll
    }

    /// Floating control to re-show the first-run walkthrough.
    private var infoButton: some View {
        Button { showTutorial = true } label: {
            Image(systemName: "info.circle.fill")
                .font(Tokens.Typography.title2)
                .foregroundStyle(Tokens.Palette.brand)
                .padding(Tokens.Spacing.s3)
                .background(.thinMaterial, in: Circle())
                .tweenElevation(.floating)
        }
        .buttonStyle(.plain)
        .padding(.top, Tokens.Spacing.s2)
        .padding(.trailing, Tokens.Spacing.s4)
        .accessibilityLabel("Help")
        .accessibilityHint("Shows the welcome walkthrough")
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
        if let lastReplyAt, Date().timeIntervalSince(lastReplyAt) < Self.replyFreshness {
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
            Button { activeSheet = .contacts } label: {
                Label("Add Friend", systemImage: "person.badge.plus")
            }
            .buttonStyle(.tweenPrimary())
            .padding(.horizontal)
            .accessibilityHint("Picks someone from your contacts")

            Button { activeSheet = .invite } label: {
                Label("Invite a Friend", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.tweenPrimary(.subtle))
            .padding(.horizontal)
            .accessibilityHint("Shares an invite link to Tween")

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
            TextField("Search places", text: $searchText)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .accessibilityLabel("Search places")
                .onSubmit(commitSearch)
                .onChange(of: searchText) { _, query in
                    if query != selectedCategory?.searchQuery { selectedCategory = nil }
                    searchPlaces(query: query)
                }
            if !searchText.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(Tokens.Spacing.s3)
        .tweenGlass()
        .padding(.horizontal)
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Spacing.s2) {
                ForEach(CategoryPreset.allCases) { preset in
                    let selected = preset == selectedCategory
                    Button { selectCategory(preset) } label: {
                        Label(preset.title, systemImage: preset.icon)
                            .font(Tokens.Typography.subheadline)
                            .padding(.horizontal, Tokens.Spacing.s3)
                            .padding(.vertical, Tokens.Spacing.s2)
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
                presenceControls
                if isSearchActive {
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
                Label("I'm in", systemImage: "location.fill")
                    .symbolEffect(.bounce, value: isUserIn)
            }
            .buttonStyle(.tweenPrimary())
            .disabled(provider.status == .requesting)
            .accessibilityHint("Shares where you are and finds fair places to meet")
        }

        Text(statusText)
            .font(Tokens.Typography.footnote)
            .foregroundStyle(Tokens.Palette.textSecondary)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var resultsList: some View {
        if !rankedSpots.isEmpty {
            ForEach(rankedSpots) { spot in
                RankedResultRow(spot: spot)
                    .contentShape(Rectangle())
                    .onTapGesture { presentDetail(for: spot) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens details and the map for this spot")
                Divider()
            }
        } else if !searchResults.isEmpty {
            ForEach(searchResults, id: \.self) { item in
                ResultRow(name: item.name ?? "Place", address: item.placemark.title)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        focusMap(on: item)
                        activeSheet = .spot(SpotSelection(item: item, ranked: nil))
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens details for this place")
                Divider()
            }
        } else {
            Text("No places found nearby.")
                .font(Tokens.Typography.footnote)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .padding(.top, Tokens.Spacing.s1)
        }
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
            return "You're in. Waiting for your friend to share their spot…"
        }
        return "Tap “I'm in” to share where you are and find fair places to meet."
    }

    // MARK: - Actions

    private func imIn() {
        awaitingImIn = true
        provider.requestOnce()
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
        // Active state lives in the view; refresh the cached coordinate's
        // timestamp so it stays usable while we wait for a peer.
        if let coord = savedCoordinate {
            LocationCache.save(coord)
        }
    }

    // MARK: - Hand-off

    /// Opens the detail card for a ranked result (when it carries a map item)
    /// and animates the map to frame the selection.
    private func presentDetail(for spot: RankedSpot) {
        guard let item = spot.item else { return }
        focusMap(on: item)
        activeSheet = .spot(SpotSelection(item: item, ranked: spot))
    }

    /// Centers the map on a tapped result and drops the sheet to its peek so the
    /// map is visible. Frames self, peer, and the spot together when both
    /// participants are known; otherwise zooms tight on the spot.
    private func focusMap(on item: MKMapItem) {
        if savedCoordinate != nil, peerCoordinate != nil {
            let coords = [savedCoordinate, peerCoordinate, item.placemark.coordinate].compactMap { $0 }
            withAnimation(Tokens.Motion.gentle) { position = Self.cameraPosition(for: coords) }
        } else {
            withAnimation(Tokens.Motion.gentle) {
                position = .region(MKCoordinateRegion(
                    center: item.placemark.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
            }
        }
        withAnimation(Tokens.Motion.snappy) { selectedSheetDetent = .height(120) }
    }

    /// Stages the chosen spot for the extension and bounces to Messages, where
    /// the user taps Tween to pick the draft up.
    private func sendToChat(_ selection: SpotSelection) {
        OutgoingDraftStore.save(OutgoingDraft(
            spotName: selection.name,
            latitude: selection.coordinate.latitude,
            longitude: selection.coordinate.longitude))
        if let url = URL(string: "sms:") {
            UIApplication.shared.open(url)
        }
    }

    private func dismissTutorial() {
        OnboardingFlags.hasSeenOnboarding = true
        showTutorial = false
    }

    // MARK: - Friends

    /// Logs a ping and opens the SMS composer when the friend has a handle the
    /// device can text; otherwise copies the invite and toasts.
    private func pingFriend(_ friend: TweenFriend) {
        PingLog.logPing(for: friend.id)
        pingTick += 1

        if let handle = friend.handle, MFMessageComposeViewController.canSendText() {
            activeSheet = .message(PendingMessage(recipients: [handle], body: Self.inviteText))
        } else {
            UIPasteboard.general.string = Self.inviteText
            showToast("Invite copied for \(friend.name)")
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

    /// The region search is biased toward: the midpoint when both friends are
    /// known, otherwise whichever single point we have. A wide 1.6° span keeps
    /// results relevant without pinning them to one neighborhood.
    private var searchRegion: MKCoordinateRegion {
        let center = midpoint ?? savedCoordinate ?? peerCoordinate ?? Self.defaultCenter
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 1.6, longitudeDelta: 1.6))
    }

    /// Debounced live search driven by typing. Cancels any in-flight query,
    /// waits 300ms (so we don't fire on every keystroke), then runs the search.
    private func searchPlaces(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSearch(trimmed) else { return }

        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await runSearch(trimmed: trimmed)
        }
    }

    /// Runs the search immediately for whatever is typed (keyboard "Search").
    /// Enter means "search now", so this skips the typing debounce entirely.
    private func commitSearch() {
        searchTask?.cancel()
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSearch(trimmed) else { return }

        searchTask = Task { @MainActor in
            await runSearch(trimmed: trimmed)
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
            return false
        }
        return true
    }

    /// Shared body for both the debounced and immediate paths: runs
    /// `MKLocalSearch`, ranks the hits through the fairness engine when both
    /// coordinates are known, and surfaces the results.
    @MainActor
    private func runSearch(trimmed: String) async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.region = searchRegion

        guard let response = try? await MKLocalSearch(request: request).start(),
              !Task.isCancelled else { return }
        let items = response.mapItems

        if let me = savedCoordinate, let peer = peerCoordinate {
            let ranked = await FairnessRanker.rank(
                candidates: items, from: me, and: peer, cap: Self.rankCap)
            guard !Task.isCancelled else { return }
            rankedSpots = ranked
            searchResults = items
        } else {
            rankedSpots = []
            searchResults = items
        }

        isSearchActive = true
        // Lift the sheet off its peek so results are visible.
        if selectedSheetDetent == .height(120) {
            withAnimation(Tokens.Motion.snappy) { selectedSheetDetent = .fraction(0.48) }
        }
    }

    private func clearSearch() {
        searchTask?.cancel()
        searchText = ""
        searchResults = []
        rankedSpots = []
        isSearchActive = false
        selectedCategory = nil
    }

    /// Toggles a preset chip. Re-tapping the active chip clears the search;
    /// setting `searchText` drives the search through the field's `onChange`.
    private func selectCategory(_ preset: CategoryPreset) {
        if selectedCategory == preset {
            clearSearch()
        } else {
            selectedCategory = preset
            searchText = preset.searchQuery
        }
    }

    // MARK: - Peer polling

    private func pollPeer() async {
        while !Task.isCancelled {
            if let peer = LocationCache.loadPeer()?.coordinate, !same(peerCoordinate, peer) {
                peerCoordinate = peer
                reframe()
            }
            // Surface inbound replies stamped by the extension's `didReceive`.
            lastReplyAt = PingLog.lastIncomingReplyAt
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - Geometry

    private var midpoint: CLLocationCoordinate2D? {
        guard let me = savedCoordinate, let peer = peerCoordinate else { return nil }
        return Self.midpoint(me, peer)
    }

    private func reframe() {
        let coords = [savedCoordinate, peerCoordinate, midpoint].compactMap { $0 }
        guard !coords.isEmpty else { return }
        withAnimation(Tokens.Motion.gentle) { position = Self.cameraPosition(for: coords) }
    }

    private func same(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D) -> Bool {
        guard let a else { return false }
        return a.latitude == b.latitude && a.longitude == b.longitude
    }

    /// Average of two coordinates.
    static func midpoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2,
                               longitude: (a.longitude + b.longitude) / 2)
    }

    /// Frames the given coordinates with 20% padding on the span. A single point
    /// (or a degenerate cluster) falls back to a comfortable city-level zoom.
    static func cameraPosition(for coordinates: [CLLocationCoordinate2D]) -> MapCameraPosition {
        guard let first = coordinates.first else {
            return .region(MKCoordinateRegion(
                center: defaultCenter,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))
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
        let latDelta = degenerate ? 0.05 : (maxLat - minLat) * 1.2
        let lonDelta = degenerate ? 0.05 : (maxLon - minLon) * 1.2

        return .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)))
    }
}

#Preview {
    OnboardingView()
}
