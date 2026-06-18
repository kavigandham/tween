import UIKit
import SwiftUI
import Messages
import MapKit
import CoreLocation

/// The iMessage extension's principal view controller.
///
/// Hosts SwiftUI (`CompactView` / `ExpandedView`) inside a `UIHostingController`
/// and bridges the Messages lifecycle: it decodes the selected/incoming bubble
/// into a `TweenState`, caches the peer's coordinate, ranks fair spots when
/// expanded, and composes outgoing bubbles. Memory discipline is paramount here
/// — the extension ceiling is ~120 MB — so all background work runs in cancelled
/// `Task`s and ranking is capped at 5.
final class MessagesViewController: MSMessagesAppViewController {

    // MARK: - State

    /// The spot a peer most recently shared with us.
    private var received: TweenState?
    /// Fairness-ranked candidates, populated only while expanded.
    private var rankedSpots: [RankedSpot] = []

    private var rankingTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?

    private let locationProvider = LocationProvider()
    private var sentMessageCount = 0

    private var hosting: UIHostingController<AnyView>?

    /// Default place query for the extension's fair-spot search. There's no
    /// category UI here, so we bias toward an easy, universal meetup spot.
    private static let defaultQuery = "Coffee"

    /// Hard cap for route resolution inside the extension (vs. 8 in the app).
    private static let rankCap = 5

    // MARK: - Lifecycle

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        decodeAndCache(conversation.selectedMessage)
        presentUI(for: presentationStyle)
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        if presentationStyle == .expanded {
            kickOffRanking()
        } else {
            rankingTask?.cancel()
        }
        presentUI(for: presentationStyle)
    }

    override func didReceive(_ message: MSMessage, conversation: MSConversation) {
        super.didReceive(message, conversation: conversation)
        decodeAndCache(message)
        // Phase 05 wires `PingLog.lastIncomingReplyAt = Date()` here once
        // `Shared/PingLog.swift` exists; referencing it now would not compile.
        if presentationStyle == .expanded {
            kickOffRanking()
        }
        presentUI(for: presentationStyle)
    }

    override func willResignActive(with conversation: MSConversation) {
        super.willResignActive(with: conversation)
        // Drop every background task before we're backgrounded.
        rankingTask?.cancel()
        sendTask?.cancel()
    }

    // MARK: - Decoding

    /// Decodes a bubble's payload into `received` and caches the peer coordinate
    /// for later ranking. A message that isn't ours is ignored.
    private func decodeAndCache(_ message: MSMessage?) {
        guard let url = message?.url, let state = TweenState(url: url) else { return }
        received = state
        LocationCache.savePeer(state.coordinate)
    }

    // MARK: - Hosting

    private func presentUI(for style: MSMessagesAppPresentationStyle) {
        let isUserIn = LocationCache.isActive
        let root: AnyView

        switch style {
        case .expanded:
            root = AnyView(
                ExpandedView(
                    received: received,
                    selfCoord: LocationCache.loadSelf()?.coordinate,
                    rankedSpots: rankedSpots,
                    isUserIn: isUserIn,
                    onImIn: { [weak self] in self?.handleImIn() },
                    onSelectSpot: { [weak self] spot in self?.sendChosenSpot(spot) }
                )
            )
        default:
            root = AnyView(
                CompactView(
                    received: received,
                    isUserIn: isUserIn,
                    onImIn: { [weak self] in self?.handleImIn() },
                    onExpand: { [weak self] in self?.requestPresentationStyle(.expanded) }
                )
            )
        }

        embed(root)
    }

    /// Reuses the hosting controller across renders — only the SwiftUI root is
    /// swapped — so re-ranking doesn't tear down and rebuild the view tree.
    private func embed(_ view: AnyView) {
        if let hosting {
            hosting.rootView = view
            return
        }

        let controller = UIHostingController(rootView: view)
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)
        hosting = controller
    }

    // MARK: - Ranking

    /// Searches the midpoint region for candidate spots and ranks them by
    /// fairness, capped at 5. Re-renders the expanded UI when finished.
    private func kickOffRanking() {
        rankingTask?.cancel()

        guard let me = LocationCache.loadSelf()?.coordinate,
              let peer = received?.coordinate ?? LocationCache.loadPeer()?.coordinate else {
            return
        }

        let center = MapGeometry.midpoint(me, peer)
        rankingTask = Task { @MainActor in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = Self.defaultQuery
            request.region = MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 1.6, longitudeDelta: 1.6))

            guard let response = try? await MKLocalSearch(request: request).start(),
                  !Task.isCancelled else { return }

            let ranked = await FairnessRanker.rank(
                candidates: response.mapItems, from: me, and: peer, cap: Self.rankCap)
            guard !Task.isCancelled else { return }

            self.rankedSpots = ranked
            self.presentUI(for: self.presentationStyle)
        }
    }

    // MARK: - Sending

    /// Shares the user's location. Uses a fresh cached fix when one is fresh;
    /// otherwise requests one (without ever prompting) before composing.
    private func handleImIn() {
        sendTask?.cancel()
        sendTask = Task { @MainActor in
            let coordinate: CLLocationCoordinate2D
            if LocationCache.isActive, let cached = LocationCache.loadSelf()?.coordinate {
                coordinate = cached
            } else if let fresh = await acquireLocation() {
                LocationCache.save(fresh)
                coordinate = fresh
            } else {
                return
            }

            let state = TweenState(text: "I'm in", latitude: coordinate.latitude, longitude: coordinate.longitude)
            await insertBubble(for: state)
        }
    }

    /// Shares a specific ranked spot as the proposed meetup place.
    private func sendChosenSpot(_ spot: RankedSpot) {
        guard let item = spot.item else { return }
        let coordinate = item.placemark.coordinate
        let state = TweenState(
            text: item.name ?? "Spot",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude)
        sendBubble(state: state)
    }

    private func sendBubble(state: TweenState) {
        sendTask?.cancel()
        sendTask = Task { @MainActor in await insertBubble(for: state) }
    }

    /// Encodes the state into a bubble, renders its image, and stages it in the
    /// conversation. Staying on the same `MSSession` keeps the thread collapsed
    /// to a single evolving bubble rather than a stack of new ones.
    private func insertBubble(for state: TweenState) async {
        guard let conversation = activeConversation, let url = state.encodedURL() else { return }

        let image = await BubbleImageRenderer.makeImage(
            state: state,
            selfCoord: LocationCache.loadSelf()?.coordinate,
            peerCoord: LocationCache.loadPeer()?.coordinate)
        guard !Task.isCancelled else { return }

        let layout = MSMessageTemplateLayout()
        layout.image = image
        layout.caption = state.text
        layout.subcaption = "Tap to find fair meetup spots"

        let session = conversation.selectedMessage?.session ?? MSSession()
        let message = MSMessage(session: session)
        message.url = url
        message.layout = layout

        conversation.insert(message) { _ in }
        sentMessageCount += 1
    }

    /// Requests a single fix if already authorized (never prompts inside the
    /// extension) and polls the provider for up to ~5s for a result.
    private func acquireLocation() async -> CLLocationCoordinate2D? {
        locationProvider.requestOnceIfAuthorized()
        for _ in 0..<50 {
            if Task.isCancelled { return nil }
            switch locationProvider.status {
            case .got(let coordinate):
                return coordinate
            case .denied, .failed:
                return nil
            default:
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return nil
    }
}
