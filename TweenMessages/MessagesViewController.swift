import UIKit
import SwiftUI
import Messages
import MapKit
import CoreLocation
import os

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
    /// A spot the host app staged for us to send, picked up on activation.
    private var draft: OutgoingDraft?
    /// Fairness-ranked candidates, populated only while expanded.
    private var rankedSpots: [RankedSpot] = []

    private var rankingTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?

    private let locationProvider = LocationProvider()
    private let networkMonitor = NetworkMonitor()
    private let logger = Logger(subsystem: "com.kavigandham.TweenApp", category: "Messages")

    private var hosting: UIHostingController<AnyView>?

    /// Set when a memory warning fires while expanded: it tells `ExpandedView` to
    /// shed its live `MKMapView` and fall back to the static snapshot, our last line
    /// of defense against the ~120 MB extension jetsam ceiling. Reset on collapse.
    private var mapDegraded = false

    /// Default place query for the extension's fair-spot search. There's no
    /// category UI here, so we bias toward common, universal meetup spots.
    private static let defaultQuery = "cafe restaurant food"

    /// Hard cap for route resolution inside the extension (vs. 8 in the app).
    private static let rankCap = 5

    // MARK: - Lifecycle

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        _ = decodeAndCache(conversation.selectedMessage, in: conversation)
        // Jump to expanded when there's something to act on: a spot the host app
        // staged for us, or an incoming invite to respond to (so the invitation
        // banner and auto-ranked spots are front and center).
        draft = OutgoingDraftStore.load()
        if draft != nil || received != nil {
            requestPresentationStyle(.expanded)
        }
        presentUI(for: presentationStyle)
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        if presentationStyle == .expanded {
            kickOffRanking()
        } else {
            rankingTask?.cancel()
            // Collapsing already frees the map (CompactView has none); clear the
            // degrade flag so the next expansion gets the live map back.
            mapDegraded = false
        }
        presentUI(for: presentationStyle)
    }

    override func didReceive(_ message: MSMessage, conversation: MSConversation) {
        super.didReceive(message, conversation: conversation)
        let savedPeer = decodeAndCache(message, in: conversation)
        // Stamp the inbound bubble so the host app can surface a "they replied"
        // banner across its sheet, but only once the peer coordinate is usable.
        if savedPeer {
            PingLog.lastIncomingReplyAt = Date()
        }
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

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // We're near the extension's memory ceiling. Shed the live MKMapView by
        // re-rendering ExpandedView with the static snapshot fallback. No-op if we
        // already degraded or aren't showing the map.
        guard presentationStyle == .expanded, !mapDegraded else { return }
        mapDegraded = true
        presentUI(for: presentationStyle)
    }

    // MARK: - Decoding

    /// Decodes a bubble's payload into `received` and caches the peer coordinate
    /// only when the payload represents a participant. Place bubbles also carry a
    /// coordinate, but treating that as the peer would corrupt midpoint/ranking.
    @discardableResult
    private func decodeAndCache(_ message: MSMessage?, in conversation: MSConversation) -> Bool {
        guard let message, let url = message.url, let state = TweenState(url: url) else { return false }
        guard message.senderParticipantIdentifier != conversation.localParticipantIdentifier else { return false }
        received = state
        logger.debug("Decoded incoming Tween message kind=\(state.kind.rawValue, privacy: .public) lat=\(state.latitude, privacy: .public) lon=\(state.longitude, privacy: .public)")
        if let peer = state.participantCoordinate {
            LocationCache.savePeer(peer, isActive: true)
            logger.debug("Saved peer coordinate lat=\(peer.latitude, privacy: .public) lon=\(peer.longitude, privacy: .public)")
            return true
        }
        logger.debug("Incoming message did not include a peer coordinate")
        return false
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
                    isOnline: networkMonitor.isOnline,
                    useStaticMap: mapDegraded,
                    draft: draft,
                    onImIn: { [weak self] in self?.handleImIn() },
                    onSelectSpot: { [weak self] spot in self?.sendChosenSpot(spot) },
                    onAgreePlace: { [weak self] state in self?.sendAgreedPlace(state) },
                    onSendDraft: { [weak self] in self?.sendDraft() }
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
    private func embed(_ rootView: AnyView) {
        if let hosting {
            hosting.rootView = rootView
            return
        }

        let controller = UIHostingController(rootView: rootView)
        addChild(controller)

        controller.view.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(controller.view)

        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
        ])

        controller.didMove(toParent: self)
        hosting = controller
    }

    // MARK: - Ranking

    /// Searches the midpoint region for candidate spots and ranks them by
    /// fairness, capped at 5. Re-renders the expanded UI when finished.
    private func kickOffRanking() {
        rankingTask?.cancel()

        let receivedPeer = received?.participantCoordinate
        guard let me = LocationCache.loadSelf()?.coordinate,
              let peer = receivedPeer ?? (LocationCache.isPeerActive ? LocationCache.loadPeer()?.coordinate : nil) else {
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

            let state = TweenState(
                text: "I'm in",
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                senderName: UserProfile.displayName,
                kind: .participant)
            logger.debug("Encoding I'm in reply lat=\(coordinate.latitude, privacy: .public) lon=\(coordinate.longitude, privacy: .public)")
            await insertBubble(for: state, dismissAfterInsert: true)

            // Now that we have a fix, surface the fair spots: jump to expanded
            // (which triggers ranking) and also rank directly to cover the case
            // where we're already expanded and no transition fires.
            requestPresentationStyle(.expanded)
            kickOffRanking()
        }
    }

    /// Shares a specific ranked spot as the proposed meetup place.
    private func sendChosenSpot(_ spot: RankedSpot) {
        guard let item = spot.item else { return }
        let coordinate = item.placemark.coordinate
        let state = TweenState(
            text: item.name ?? "Spot",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            senderName: UserProfile.displayName,
            kind: .place,
            senderCoordinate: LocationCache.loadSelf()?.coordinate)
        sendBubble(state: state)
    }

    /// Replies that this user agrees to the proposed place while attaching their
    /// real coordinate, so the sender's app can show both pings and the distance.
    private func sendAgreedPlace(_ proposed: TweenState) {
        sendTask?.cancel()
        sendTask = Task { @MainActor in
            let senderCoordinate: CLLocationCoordinate2D?
            if LocationCache.isActive, let cached = LocationCache.loadSelf()?.coordinate {
                senderCoordinate = cached
            } else if let fresh = await acquireLocation() {
                LocationCache.save(fresh)
                senderCoordinate = fresh
            } else {
                senderCoordinate = LocationCache.loadSelf()?.coordinate
            }

            let state = TweenState(
                text: proposed.text,
                latitude: proposed.latitude,
                longitude: proposed.longitude,
                senderName: UserProfile.displayName,
                kind: .place,
                senderCoordinate: senderCoordinate,
                action: .agree)
            logger.debug("Agreeing to place \(proposed.text, privacy: .public) senderCoordPresent=\(senderCoordinate != nil, privacy: .public)")
            await insertBubble(for: state, dismissAfterInsert: true)
        }
    }

    /// Confirms a host-app hand-off: composes the bubble for the staged draft,
    /// clears it so it isn't offered again, and re-renders.
    private func sendDraft() {
        guard let draft else { return }
        let state = TweenState(
            text: draft.spotName,
            latitude: draft.latitude,
            longitude: draft.longitude,
            senderName: UserProfile.displayName,
            kind: .place,
            senderCoordinate: LocationCache.loadSelf()?.coordinate)
        OutgoingDraftStore.clear()
        self.draft = nil
        sendBubble(state: state)
        presentUI(for: presentationStyle)
    }

    private func sendBubble(state: TweenState) {
        sendTask?.cancel()
        sendTask = Task { @MainActor in await insertBubble(for: state, dismissAfterInsert: true) }
    }

    /// Encodes the state into a bubble, renders its image, and stages it in the
    /// conversation. Staying on the same `MSSession` keeps the thread collapsed
    /// to a single evolving bubble rather than a stack of new ones.
    private func insertBubble(for state: TweenState, dismissAfterInsert: Bool = false) async {
        guard let conversation = activeConversation, let url = state.encodedURL() else { return }

        let image = await BubbleImageRenderer.makeImage(
            state: state,
            selfCoord: LocationCache.loadSelf()?.coordinate,
            peerCoord: LocationCache.isPeerActive ? LocationCache.loadPeer()?.coordinate : nil)
        guard !Task.isCancelled else { return }

        let layout = MSMessageTemplateLayout()
        layout.image = image
        let name = state.senderName ?? "Someone"
        if state.kind == .participant {
            layout.caption = "\(name) wants to meet up!"
            layout.subcaption = "Tap to find a fair spot"
        } else if state.action == .agree {
            layout.caption = "\(name) agreed to meet at \(state.text)"
            layout.subcaption = "Tap to see both pings"
        } else {
            layout.caption = state.text
            layout.subcaption = "Tap to find a fair spot"
        }

        let session = conversation.selectedMessage?.session ?? MSSession()
        let message = MSMessage(session: session)
        message.url = url
        message.layout = layout

        guard !Task.isCancelled else { return }
        do {
            try await conversation.insert(message)
            logger.debug("Inserted outgoing Tween bubble kind=\(state.kind.rawValue, privacy: .public)")
            if dismissAfterInsert {
                dismiss()
            }
        } catch {
            logger.error("Failed to insert outgoing Tween bubble: \(String(describing: error), privacy: .public)")
            // Swallow errors in the extension context; insertion can fail if the
            // conversation is no longer active or the extension is backgrounding.
        }
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
