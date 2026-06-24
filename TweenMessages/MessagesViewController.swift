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

    /// Everyone who's currently "in" for this meetup, derived from the most
    /// recent message we've seen. Persists across renders so an outgoing send
    /// can append the local user without losing prior participants.
    private var currentParticipants: [Participant] = []
    /// Total seats in this iMessage conversation (you + remote participants).
    /// Used by Compact/ExpandedView for "X of Y ready" copy. Available only
    /// while the extension is active.
    private var totalConversationParticipants: Int = 1

    private var rankingTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var isSending = false
    private var sendStatusMessage: String?

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
        // Number of seats in the iMessage thread. The local participant always
        // counts as 1; remoteParticipantIdentifiers covers everyone else.
        totalConversationParticipants = 1 + conversation.remoteParticipantIdentifiers.count
        _ = decodeAndCache(conversation.selectedMessage, in: conversation)
        // Apply the agreed-meetup override even when no message decoded
        // (e.g. selectedMessage was the local user's own bubble, which
        // decodeAndCache skips). Lets the terminal MEETUP SET survive
        // extension re-launches initiated by tapping any bubble, including
        // the agree bubble itself when it was sent by this device.
        received = effectiveReceived(decoded: received)
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
        isSending = false
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

    /// Decodes a bubble's payload into `received` and refreshes the cached
    /// participant roster + agreement state from the message.
    ///
    /// Each received bubble carries the full participant list, so the most
    /// recent message is the canonical snapshot — we replace, not merge. The
    /// single-peer cache key is still written so legacy host-app code paths
    /// keep working until Slice 6 migrates them.
    @discardableResult
    private func decodeAndCache(_ message: MSMessage?, in conversation: MSConversation) -> Bool {
        guard let message, let url = message.url, let state = TweenState(url: url) else { return false }
        guard message.senderParticipantIdentifier != conversation.localParticipantIdentifier else { return false }
        received = effectiveReceived(decoded: state)
        logger.debug("Decoded incoming Tween message type=\(state.messageType.rawValue, privacy: .public) participants=\(state.participants.count, privacy: .public) agreed=\(state.agreedNames.count, privacy: .public)")

        // Persist / clear the agreed-meetup cache based on the new state:
        //   - .agree fully agreed → persist (terminal state survives extension restarts)
        //   - .counter → clear (counter restarts negotiation, prior agreement is undone)
        //   - others → leave the cache alone
        if state.messageType == .agree, state.isFullyAgreed {
            LocationCache.saveAgreedMeetup(state)
        } else if state.messageType == .counter {
            LocationCache.clearAgreedMeetup()
        }

        // Roster snapshot: trust the incoming list verbatim.
        if !state.participants.isEmpty {
            currentParticipants = state.participants
            LocationCache.saveParticipants(state.participants)
        }

        // Legacy single-peer cache: write the most recent NON-LOCAL coordinate
        // so OnboardingView's polling keeps animating. The name comparison MUST
        // use the same fallback the host app uses (UserName.fallback = "You");
        // without it, when UserProfile.displayName is nil, every participant's
        // non-nil name wins the != comparison and the first entry — possibly
        // the LOCAL user — leaks into the peer cache. That was Bug #4.
        let myName = Self.localParticipantName()
        if let peer = state.participants.first(where: { $0.name != myName }) {
            LocationCache.savePeer(peer.coordinate, isActive: true)
            logger.debug("Saved peer coordinate lat=\(peer.latitude, privacy: .public) lon=\(peer.longitude, privacy: .public)")
            return true
        }
        // Legacy fallback for pre-group bubbles where participants[] is empty.
        // We trust state.participantCoordinate here because the sender filtered
        // out their own message via senderParticipantIdentifier (guard above) —
        // so this coord IS the remote user's.
        if state.participants.isEmpty, let peerCoord = state.participantCoordinate {
            LocationCache.savePeer(peerCoord, isActive: true)
            return true
        }
        logger.debug("Incoming message had no non-local participant; peer cache untouched")
        return false
    }

    /// The local user's display name, with the same fallback the host app
    /// uses. Centralised so every name-based filter agrees on what counts as
    /// "me" — drifting between call sites was the root of Bug #4.
    static func localParticipantName() -> String {
        UserProfile.displayName ?? UserName.fallback
    }

    // MARK: - Effective received state
    //
    // The bubble the user tapped (`conversation.selectedMessage`) tells us
    // what THEY were looking at, but the SOURCE OF TRUTH for the meetup is
    // the most recent agreement — which lives in App Group via
    // LocationCache.{save,load}AgreedMeetup. If they tap an old propose
    // after agreeing, we still want to show MEETUP SET, not Agree/Change.

    /// Resolves the effective `received` state for rendering, applying the
    /// "agreed meetup is sticky" rule on top of whatever decodeAndCache
    /// produced. The decoded value still drives peer/participant cache writes
    /// (those happen inside decodeAndCache); this only changes what
    /// ExpandedView is handed.
    private func effectiveReceived(decoded: TweenState?) -> TweenState? {
        guard let agreed = LocationCache.loadAgreedMeetup(), agreed.isFullyAgreed else {
            return decoded
        }
        // Nothing selected — show the agreement so the user lands on the
        // terminal state regardless of which bubble iOS happens to pick.
        guard let decoded else { return agreed }
        // User tapped the propose/counter that led to this agreement — show
        // MEETUP SET (sameSpot match means it's literally the bubble that
        // was agreed to).
        if decoded.kind == .place, Self.sameSpot(decoded, agreed) {
            return agreed
        }
        // Different spot, an invite, etc. — trust the user's tap.
        return decoded
    }

    /// Two TweenStates point at the "same" spot when their coordinates match
    /// within a tight epsilon. 1e-4 degrees is ~11 m at the equator — well
    /// inside any GPS jitter, well outside any float-roundtrip noise from
    /// `coordinateString`'s %.6f formatting.
    private static func sameSpot(_ a: TweenState, _ b: TweenState) -> Bool {
        abs(a.latitude  - b.latitude)  < 1e-4 &&
        abs(a.longitude - b.longitude) < 1e-4
    }

    /// Opens Apple Maps with driving directions to the agreed-upon spot.
    /// Uses the `maps://` custom URL scheme — Apple's canonical Apple Maps
    /// scheme that always launches Apple Maps from extension context. The
    /// http://maps.apple.com universal-link form relies on iOS' UL resolution
    /// which can fall through to "open the containing app" instead of Maps
    /// from inside an MSMessagesAppViewController — the bug the customer
    /// reported. `maps://` removes that branch entirely.
    ///
    /// MKMapItem.openInMaps is not an option from an extension because it
    /// calls UIApplication.shared.open under the hood, which extensions
    /// can't access.
    private func openDirections(for state: TweenState) {
        let q = state.text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Spot"
        let urlString = "maps://?daddr=\(state.latitude),\(state.longitude)&q=\(q)&dirflg=d"
        guard let url = URL(string: urlString) else { return }
        extensionContext?.open(url) { [weak self] success in
            if !success {
                self?.logger.error("Failed to open Apple Maps for directions")
            }
        }
    }

    /// Builds the next outgoing participant list by removing any prior entry
    /// for the local user (matched by name) and appending a fresh one with the
    /// current coordinate. Cross-message identity is by name because the
    /// conversation-scoped UUID can't be carried inside the URL.
    private func nextParticipantList(myCoord: CLLocationCoordinate2D,
                                     conversation: MSConversation?) -> [Participant] {
        let myName = Self.localParticipantName()
        let myId = conversation?.localParticipantIdentifier.uuidString ?? myName
        let others = currentParticipants.filter { $0.name != myName }
        let me = Participant(id: myId, name: myName, coordinate: myCoord)
        return others + [me]
    }

    // MARK: - Hosting

    private func presentUI(for style: MSMessagesAppPresentationStyle) {
        let isUserIn = LocationCache.isActive
        logger.debug("presentUI style=\(String(describing: style), privacy: .public) hasReceived=\(self.received != nil, privacy: .public) isActive=\(isUserIn, privacy: .public)")
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
                    onSelectSpot: { [weak self] spot in
                        if self?.received?.kind == .place {
                            self?.sendCounter(spot)
                        } else {
                            self?.sendChosenSpot(spot)
                        }
                    },
                    onAgreePlace: { [weak self] state in self?.sendAgreedPlace(state) },
                    onSendDraft: { [weak self] in self?.sendDraft() },
                    onGetDirections: { [weak self] state in self?.openDirections(for: state) },
                    onOpenFullApp: { [weak self] in self?.openFullAppSearch() },
                    isSending: isSending,
                    statusMessage: sendStatusMessage
                )
            )
        default:
            root = AnyView(
                CompactView(
                    received: received,
                    isUserIn: isUserIn,
                    isSending: isSending,
                    statusMessage: sendStatusMessage,
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

        // Anchor the hosting view (and the extension VC's own view) to an
        // opaque system surface. Without this the SwiftUI content renders
        // transparently and can read as a "blank strip" against whatever
        // backdrop iMessage paints in the keyboard area.
        self.view.backgroundColor = .systemBackground
        controller.view.backgroundColor = .systemBackground

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

    /// Searches the centroid region for candidate spots and ranks them by
    /// fairness across every "in" participant. Re-renders the expanded UI
    /// when finished. No-ops while fewer than two participants have shared
    /// their location.
    private func kickOffRanking() {
        rankingTask?.cancel()

        // Build the ranking participants array: my cached coord plus everyone
        // else in currentParticipants (filtered to avoid duplicating me).
        let myName = Self.localParticipantName()
        let others = currentParticipants.filter { $0.name != myName }
        var participants = others
        if let mySelf = LocationCache.loadSelf()?.coordinate {
            let myId = activeConversation?.localParticipantIdentifier.uuidString ?? myName
            participants.append(Participant(id: myId, name: myName, coordinate: mySelf))
        }
        guard participants.count >= 2 else { return }

        let center = MapGeometry.centroid(of: participants)
        // Search radius widens as the group spreads out.
        let span = participants.reduce(0.04) { acc, p in
            let dLat = abs(p.latitude - center.latitude)
            let dLon = abs(p.longitude - center.longitude)
            return max(acc, max(dLat, dLon) * 2.0)
        }
        let cap = FairnessRanker.recommendedCap(for: participants.count)

        rankingTask = Task { @MainActor in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = Self.defaultQuery
            request.region = MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))

            guard let response = try? await MKLocalSearch(request: request).start(),
                  !Task.isCancelled else { return }

            let ranked = await FairnessRanker.rank(
                candidates: response.mapItems, participants: participants, cap: cap)
            guard !Task.isCancelled else { return }

            self.rankedSpots = ranked
            self.presentUI(for: self.presentationStyle)
        }
    }

    // MARK: - Sending

    /// Shares the user's location. Uses a fresh cached fix when one is fresh;
    /// otherwise requests one before composing. Sent as an `.invite` bubble
    /// carrying the full participant roster so any recipient can reconstruct
    /// who's in.
    private func handleImIn() {
        sendTask?.cancel()
        sendTask = Task { @MainActor in
            isSending = true
            sendStatusMessage = "Sharing your location..."
            presentUI(for: presentationStyle)

            // Force a fresh fix on every explicit "I'm in" so the bubble
            // carries the user's CURRENT location, not whatever happened to
            // be in the cache (which could be ~5 min old). The cache is only
            // the fallback when CoreLocation can't deliver a fresh fix in
            // time — and even then we'll have warned the user via the status.
            let coordinate: CLLocationCoordinate2D
            if let fresh = await acquireLocation() {
                LocationCache.save(fresh, isActive: true)
                coordinate = fresh
            } else if LocationCache.isActive, let cached = LocationCache.loadSelf()?.coordinate {
                coordinate = cached
                logger.debug("Used cached self coord (fresh fix unavailable)")
            } else {
                isSending = false
                sendStatusMessage = "Location unavailable. Check permission and try again."
                presentUI(for: presentationStyle)
                return
            }

            let participants = self.nextParticipantList(myCoord: coordinate,
                                                       conversation: self.activeConversation)
            self.currentParticipants = participants
            LocationCache.saveParticipants(participants)

            let state = TweenState(
                text: "I'm in",
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                senderName: UserProfile.displayName,
                kind: .participant,
                messageType: .invite,
                participants: participants
            )
            logger.debug("Encoding I'm in reply participants=\(participants.count, privacy: .public)")
            let didSend = await insertBubble(for: state, dismissAfterInsert: true)
            isSending = false
            sendStatusMessage = didSend ? nil : "Couldn't send the Tween message. Try again."
            presentUI(for: presentationStyle)

            // Now that we have a fix, surface the fair spots: jump to expanded
            // (which triggers ranking) and also rank directly to cover the case
            // where we're already expanded and no transition fires.
            requestPresentationStyle(.expanded)
            kickOffRanking()
        }
    }

    /// Proposes a specific ranked spot to the group. The participants list is
    /// carried forward verbatim so the recipient knows everyone's in.
    private func sendChosenSpot(_ spot: RankedSpot) {
        guard let item = spot.item else { return }
        let coordinate = item.placemark.coordinate
        let mySelf = LocationCache.loadSelf()?.coordinate
        // Make sure my own entry is in the participants list before proposing.
        let participants: [Participant]
        if let mySelf {
            participants = nextParticipantList(myCoord: mySelf, conversation: activeConversation)
        } else {
            participants = currentParticipants
        }
        currentParticipants = participants
        LocationCache.saveParticipants(participants)

        let state = TweenState(
            text: item.name ?? "Spot",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            senderName: UserProfile.displayName,
            kind: .place,
            senderCoordinate: mySelf,
            messageType: .propose,
            participants: participants
        )
        sendBubble(state: state)
    }

    /// Agrees to a previously proposed place. Carries the participants forward
    /// and appends this user's name to `agreedNames`; the receiver decides if
    /// that's enough for full consensus via `state.isFullyAgreed`.
    private func sendAgreedPlace(_ proposed: TweenState) {
        sendTask?.cancel()
        sendTask = Task { @MainActor in
            // Same fresh-fix-first policy as handleImIn: never agree with a
            // stale coord that might land you in a worst-case route the
            // ranker would have rejected.
            let senderCoordinate: CLLocationCoordinate2D?
            if let fresh = await acquireLocation() {
                LocationCache.save(fresh, isActive: true)
                senderCoordinate = fresh
            } else if LocationCache.isActive, let cached = LocationCache.loadSelf()?.coordinate {
                senderCoordinate = cached
            } else {
                senderCoordinate = LocationCache.loadSelf()?.coordinate
            }

            let myName = Self.localParticipantName()
            // Build the forward participants list. The proposed bubble's
            // participants are authoritative; refresh my entry's coord.
            var participants = proposed.participants.isEmpty
                ? self.currentParticipants
                : proposed.participants
            if let myCoord = senderCoordinate {
                participants = participants.filter { $0.name != myName }
                let myId = self.activeConversation?.localParticipantIdentifier.uuidString ?? myName
                participants.append(Participant(id: myId, name: myName, coordinate: myCoord))
            }
            self.currentParticipants = participants
            LocationCache.saveParticipants(participants)

            var agreed = proposed.agreedNames
            if !agreed.contains(myName) { agreed.append(myName) }

            // Preserve the ORIGINAL proposer's name in senderName so the
            // receiving end's `isFullyAgreed` (which derives the proposer
            // from senderName) computes correctly. The agreer's identity
            // travels in agreedNames — last entry is the most recent agreer.
            let state = TweenState(
                text: proposed.text,
                latitude: proposed.latitude,
                longitude: proposed.longitude,
                senderName: proposed.senderName ?? UserProfile.displayName,
                kind: .place,
                senderCoordinate: senderCoordinate,
                action: .agree,
                messageType: .agree,
                participants: participants,
                agreedNames: agreed
            )
            logger.debug("Agreeing to place \(proposed.text, privacy: .public) agreed=\(agreed.count, privacy: .public)")
            // Don't dismiss after an agree send — instead, lock in the local
            // view as the terminal MEETUP SET so the agreer immediately sees
            // "It's a plan!" with Get Directions, rather than being bounced
            // back to the iMessage thread. The receiver gets the same view
            // via didReceive → presentUI.
            await insertBubble(for: state, dismissAfterInsert: false)
            // Persist the agreement so re-opening the extension (after iOS
            // dispose, or after the user collapses + re-taps) re-renders
            // MEETUP SET instead of the propose's Agree/Change buttons.
            if state.isFullyAgreed {
                LocationCache.saveAgreedMeetup(state)
            }
            self.received = self.effectiveReceived(decoded: state)
            self.presentUI(for: self.presentationStyle)
        }
    }

    /// Counter-proposes a different spot, resetting agreement to zero. The
    /// proposer becomes the local user and the agreedNames list starts empty.
    private func sendCounter(_ spot: RankedSpot) {
        guard let item = spot.item else { return }
        let coordinate = item.placemark.coordinate
        let mySelf = LocationCache.loadSelf()?.coordinate
        let participants: [Participant]
        if let mySelf {
            participants = nextParticipantList(myCoord: mySelf, conversation: activeConversation)
        } else {
            participants = currentParticipants
        }
        currentParticipants = participants
        LocationCache.saveParticipants(participants)

        let state = TweenState(
            text: item.name ?? "Spot",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            senderName: UserProfile.displayName,
            kind: .place,
            senderCoordinate: mySelf,
            messageType: .counter,
            participants: participants,
            agreedNames: []
        )
        // A counter restarts negotiation — any prior agreement is invalidated,
        // so the persisted terminal cache must be cleared too. Otherwise the
        // user could agree, then counter, then re-open the extension and see
        // MEETUP SET for the OLD agreed spot via the sticky cache.
        LocationCache.clearAgreedMeetup()
        sendBubble(state: state)
    }

    /// Confirms a host-app hand-off: composes the bubble for the staged draft,
    /// clears it so it isn't offered again, and re-renders.
    private func sendDraft() {
        guard let draft else { return }
        let mySelf = LocationCache.loadSelf()?.coordinate
        let participants: [Participant]
        if let mySelf {
            participants = nextParticipantList(myCoord: mySelf, conversation: activeConversation)
        } else {
            participants = currentParticipants
        }
        currentParticipants = participants
        LocationCache.saveParticipants(participants)

        let state = TweenState(
            text: draft.spotName,
            latitude: draft.latitude,
            longitude: draft.longitude,
            senderName: UserProfile.displayName,
            kind: .place,
            senderCoordinate: mySelf,
            messageType: .propose,
            participants: participants
        )
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
    @discardableResult
    private func insertBubble(for state: TweenState, dismissAfterInsert: Bool = false) async -> Bool {
        guard let conversation = activeConversation, let url = state.encodedURL() else { return false }

        let localName = UserProfile.displayName
        let image = await BubbleImageRenderer.makeImage(
            state: state,
            participants: state.participants,
            localName: localName)
        guard !Task.isCancelled else { return false }

        let layout = MSMessageTemplateLayout()
        layout.image = image
        BubbleCaption.apply(to: layout, state: state, totalSeats: self.totalConversationParticipants)

        let session = conversation.selectedMessage?.session ?? MSSession()
        let message = MSMessage(session: session)
        message.url = url
        message.layout = layout

        guard !Task.isCancelled else { return false }
        do {
            try await conversation.insert(message)
            logger.debug("Inserted outgoing Tween bubble kind=\(state.kind.rawValue, privacy: .public)")
            if dismissAfterInsert {
                dismiss()
            }
            return true
        } catch {
            logger.error("Failed to insert outgoing Tween bubble: \(String(describing: error), privacy: .public)")
            sendStatusMessage = "Couldn't send the Tween message. Try again."
            // Swallow errors in the extension context; insertion can fail if the
            // conversation is no longer active or the extension is backgrounding.
            return false
        }
    }

    /// Requests a single fix and polls the provider for up to ~5s for a result.
    private func acquireLocation() async -> CLLocationCoordinate2D? {
        locationProvider.requestOnce()
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

    private func openFullAppSearch() {
        guard let url = URL(string: "tween://search") else { return }
        extensionContext?.open(url, completionHandler: nil)
    }
}
