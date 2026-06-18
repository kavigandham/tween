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
    /// Default camera focus when there's no cached location yet.
    private static let sanFrancisco = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

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
    @State private var showContactSearch = false
    @State private var lastReplyAt: Date? = PingLog.lastIncomingReplyAt
    @State private var pingTick = 0
    @State private var renameText = ""
    @State private var pendingMessage: PendingMessage?
    @State private var toast: String?

    /// Identifiable wrapper so the SMS composer can be presented via `sheet(item:)`.
    struct PendingMessage: Identifiable {
        let id = UUID()
        let recipients: [String]
        let body: String
    }

    init() {
        let cached = LocationCache.loadSelf()
        _savedCoordinate = State(initialValue: cached?.coordinate)
        _isUserIn = State(initialValue: cached != nil && LocationCache.isActive)
        _position = State(initialValue: Self.cameraPosition(for: [cached?.coordinate ?? Self.sanFrancisco]))
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
        .sheet(isPresented: .constant(true)) {
            sheetContent
                .presentationDetents(
                    [.height(120), .fraction(0.48), .fraction(0.80)],
                    selection: $selectedSheetDetent
                )
                .presentationBackgroundInteraction(.enabled)
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showContactSearch) {
            ContactSearchView { friend in
                FriendRoster.add(friend)
                friends = FriendRoster.load()
                showContactSearch = false
            }
        }
        .sheet(item: $pendingMessage) { pending in
            MessageComposeSheet(recipients: pending.recipients, body: pending.body) {
                pendingMessage = nil
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
            if case let .got(coord) = status {
                LocationCache.save(coord)
                withAnimation(.spring) {
                    savedCoordinate = coord
                    isUserIn = true
                }
                reframe()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Mirror the extension's memory discipline: drop in-flight work when
            // we're no longer foregrounded.
            if phase != .active { searchTask?.cancel() }
        }
        .task { await pollPeer() }
    }

    // MARK: - Bottom sheet

    @ViewBuilder
    private var sheetContent: some View {
        VStack(spacing: 12) {
            replyBanner
            Picker("Panel", selection: $panelTab) {
                ForEach(HomePanelTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            switch panelTab {
            case .map:     mapPanel
            case .waiting: friendsPanel
            }
        }
        .padding(.top, 16)
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

    /// A nudge that the other side just shared a spot, shown across both tabs
    /// while the inbound bubble is still fresh.
    @ViewBuilder
    private var replyBanner: some View {
        if let lastReplyAt, Date().timeIntervalSince(lastReplyAt) < Self.replyFreshness {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                Text("Your friend replied \(RelativeTime.string(from: lastReplyAt))")
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.footnote.weight(.medium))
            .padding(10)
            .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
    }

    // MARK: - Friends panel

    @ViewBuilder
    private var friendsPanel: some View {
        VStack(spacing: 12) {
            Button { showContactSearch = true } label: {
                Label("Add Friend", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deleteFriend(friend)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { startRename(friend) } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.blue)
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
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.8), in: Capsule())
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search places", text: $searchText)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .onSubmit(commitSearch)
                .onChange(of: searchText) { _, query in
                    if query != selectedCategory?.searchQuery { selectedCategory = nil }
                    searchPlaces(query: query)
                }
            if !searchText.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CategoryPreset.allCases) { preset in
                    let selected = preset == selectedCategory
                    Button { selectCategory(preset) } label: {
                        Label(preset.title, systemImage: preset.icon)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.thinMaterial),
                                in: Capsule()
                            )
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    private var resultsScroll: some View {
        ScrollView {
            VStack(spacing: 12) {
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
        } else {
            Button(action: imIn) {
                Label("I'm in", systemImage: "location.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(provider.status == .requesting)
        }

        Text(statusText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var resultsList: some View {
        if !rankedSpots.isEmpty {
            ForEach(rankedSpots) { spot in
                RankedResultRow(spot: spot)
                Divider()
            }
        } else if !searchResults.isEmpty {
            ForEach(searchResults, id: \.self) { item in
                ResultRow(name: item.name ?? "Place", address: item.placemark.title)
                Divider()
            }
        } else {
            Text("No places found nearby.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
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
        provider.requestOnce()
    }

    private func leave() {
        withAnimation(.spring) { isUserIn = false }
        // Active state lives in the view; refresh the cached coordinate's
        // timestamp so it stays usable while we wait for a peer.
        if let coord = savedCoordinate {
            LocationCache.save(coord)
        }
    }

    // MARK: - Friends

    /// Logs a ping and opens the SMS composer when the friend has a handle the
    /// device can text; otherwise copies the invite and toasts.
    private func pingFriend(_ friend: TweenFriend) {
        PingLog.logPing(for: friend.id)
        pingTick += 1

        if let handle = friend.handle, MFMessageComposeViewController.canSendText() {
            pendingMessage = PendingMessage(recipients: [handle], body: Self.inviteText)
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
        withAnimation { toast = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toast = nil }
        }
    }

    // MARK: - Search

    /// The region search is biased toward: the midpoint when both friends are
    /// known, otherwise whichever single point we have. A wide 1.6° span keeps
    /// results relevant without pinning them to one neighborhood.
    private var searchRegion: MKCoordinateRegion {
        let center = midpoint ?? savedCoordinate ?? peerCoordinate ?? Self.sanFrancisco
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 1.6, longitudeDelta: 1.6))
    }

    /// Debounced place search. Cancels any in-flight query, waits 300ms, then
    /// runs `MKLocalSearch`. When both coordinates are known the hits are run
    /// through the fairness engine; otherwise the raw results are shown.
    private func searchPlaces(query: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            rankedSpots = []
            isSearchActive = false
            return
        }

        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

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
                withAnimation { selectedSheetDetent = .fraction(0.48) }
            }
        }
    }

    /// Runs the search for whatever is currently typed (keyboard "Search").
    private func commitSearch() {
        searchPlaces(query: searchText)
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
        withAnimation { position = Self.cameraPosition(for: coords) }
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
                center: sanFrancisco,
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
