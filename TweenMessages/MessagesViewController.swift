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
    var received: TweenState?
    /// A spot the host app staged for us to send, picked up on activation.
    var draft: OutgoingDraft?
    /// Fairness-ranked candidates, populated only while expanded.
    var rankedSpots: [RankedSpot] = []

    /// Everyone who's currently "in" for this meetup, derived from the most
    /// recent message we've seen. Persists across renders so an outgoing send
    /// can append the local user without losing prior participants.
    var currentParticipants: [Participant] = []
    /// Total seats in this iMessage conversation (you + remote participants).
    /// Used by Compact/ExpandedView for "X of Y ready" copy. Available only
    /// while the extension is active.
    var totalConversationParticipants: Int = 1

    /// The MSSession of the most recent Tween bubble seen in this conversation
    /// (tapped or received live). Reused by outgoing sends when
    /// `selectedMessage` is nil — e.g. the extension was opened from the app
    /// drawer — so replies keep collapsing into one evolving bubble instead of
    /// minting a new session (and a new bubble stack) per send.
    var lastKnownSession: MSSession?

    var rankingTask: Task<Void, Never>?
    var sendTask: Task<Void, Never>?
    var isRanking = false
    var isSending = false
    var sendStatusMessage: String?
    var recentlySentSpotName: String?
    var conversationKey: String?

    let locationProvider = LocationProvider()
    let networkMonitor = NetworkMonitor()
    let logger = Logger(subsystem: "com.kavigandham.TweenApp", category: "Messages")

    var hosting: UIHostingController<AnyView>?

    /// Permanent opaque tile pinned to `self.view.bounds` beneath the hosting
    /// view. If the hosting view ever renders with a zero frame (bounds not
    /// settled), fails to attach, or is transient during a rootView swap, the
    /// user sees this solid `.systemBackground` surface instead of the
    /// Messages-host blank strip. See `docs/ui-research.md` §3 (blank-render
    /// causes) and `.claude/skills/imessage-extension.md`.
    var fallbackView: UIView?

    /// Default place query for the extension's fair-spot search. There's no
    /// category UI here, so we bias toward common, universal meetup spots.
    static let defaultQuery = "cafe restaurant food"

    /// Status copy set by `deliverBubble` when direct send was rejected and
    /// the bubble was staged in the input field instead. `handleImIn` compares
    /// against it to avoid expanding the extension over the staged bubble the
    /// user still needs to tap send on.
    static let stagedDeliveryStatus = "Added to the message box — tap send to deliver."

    /// Hard cap for route resolution inside the extension (vs. 8 in the app).
    static let rankCap = 5
    /// Fetch a slightly larger search pool than we route. MapKit's first few
    /// hits can drift off-axis, so ranking needs nearby alternatives to choose
    /// from without paying route costs for all of them.
    static let searchPoolSize = 8
    /// iMessage extensions are short-lived; don't let MapKit search leave the
    /// CTA stuck in "Finding fair spots..." if the network or service stalls.
    static let searchTimeoutNanoseconds: UInt64 = 8_000_000_000

    /// The status strings that mean something FAILED. `sendStatusMessage` is
    /// one channel carrying three kinds of copy (progress, confirmation,
    /// failure); the views style only these as a warning banner so a routine
    /// "Sent X to the chat" never renders with an alarm icon.
    static let errorStatuses: Set<String> = [
        "Couldn't send the Tween message. Try again.",
        "Location unavailable. Check permission and try again.",
        "Google Maps isn't installed."
    ]

    var sendStatusIsError: Bool {
        sendStatusMessage.map { Self.errorStatuses.contains($0) } ?? false
    }

    /// Prefix for the cached-state hint. A device only learns of new bubbles
    /// when one is tapped (or while the extension is open) — nobody taps an
    /// "I'm out" bubble, they just read it — so state rendered from the local
    /// snapshot may be behind the conversation. Say so instead of presenting
    /// it as live. Prefix-matched when clearing on a real decode.
    static let snapshotHintPrefix = "Last update "

    func snapshotHint(for snapshot: MeetupSnapshot) -> String {
        Self.snapshotHintPrefix + RelativeTime.string(from: snapshot.updatedAt)
            + " — tap the newest Tween bubble to refresh"
    }

    func clearSnapshotHint() {
        if sendStatusMessage?.hasPrefix(Self.snapshotHintPrefix) == true {
            sendStatusMessage = nil
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // Paint the extension's own view opaque at load time — before any
        // presentUI() call can fail, arrive late, or briefly race a rootView
        // swap. `embed()` already sets `.systemBackground` on `self.view` when
        // it first attaches the hosting controller, but that only fires once
        // presentUI() is reached; a very early lifecycle call (or a re-entry
        // during willBecomeActive) can otherwise expose the Messages host
        // paint underneath. See `docs/ui-research.md` §3.
        view.backgroundColor = .systemBackground
        installFallbackView()
    }

    /// Adds a permanent opaque tile beneath any future hosting view. Inserted
    /// at index 0 so subsequent `addSubview(hosting.view)` calls always sit
    /// on top of it (subview order = z-order, and `embed()` may run before or
    /// after this depending on when the view is first loaded).
    func installFallbackView() {
        guard fallbackView == nil else { return }
        let fallback = UIView()
        fallback.translatesAutoresizingMaskIntoConstraints = false
        fallback.backgroundColor = .systemBackground
        fallback.isUserInteractionEnabled = false
        view.insertSubview(fallback, at: 0)
        NSLayoutConstraint.activate([
            fallback.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fallback.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fallback.topAnchor.constraint(equalTo: view.topAnchor),
            fallback.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        fallbackView = fallback
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        let key = Self.conversationKey(for: conversation)
        let switchedConversation = conversationKey != key
            || ConversationMeetupStore.lastActiveConversationKey != key
        conversationKey = key
        ConversationMeetupStore.lastActiveConversationKey = key

        if switchedConversation {
            received = nil
            draft = nil
            rankedSpots = []
            currentParticipants = []
            sendStatusMessage = nil
            recentlySentSpotName = nil
            isRanking = false
            rankingTask?.cancel()
            // An in-flight send belongs to the chat it started in — abandon it so
            // its post-await status/roster commit can't bleed into (or block) this
            // one, and clear the stuck `isSending` that would disable this chat's
            // CTAs. The canonical snapshot it may still write is keyed to its OWN
            // conversation (deliverBubble captures the key), so state stays correct.
            sendTask?.cancel()
            isSending = false
            // Sessions are per-conversation; never reuse one across chats.
            lastKnownSession = nil
        }
        if let session = conversation.selectedMessage?.session {
            lastKnownSession = session
        }
        // Number of seats in the iMessage thread. The local participant always
        // counts as 1; remoteParticipantIdentifiers covers everyone else.
        totalConversationParticipants = 1 + conversation.remoteParticipantIdentifiers.count
        presentUI(for: presentationStyle)

        let decodedIncoming = decodeAndCache(conversation.selectedMessage, in: conversation)
        var snapshot = ConversationMeetupStore.load(key: key)
        // Expire stale per-chat snapshots. Without a TTL, a meetup negotiated
        // days ago resurrects (and force-expands the extension) every time the
        // user opens Tween in that chat, presenting old state as current.
        if let stale = snapshot, Date().timeIntervalSince(stale.updatedAt) > ConversationMeetupStore.snapshotTTL {
            ConversationMeetupStore.clear(key: key)
            snapshot = nil
        }
        // decodeAndCache returns true only when a PEER COORDINATE was saved, so
        // a decoded message with no non-local participant (e.g. a .leave) still
        // reports false. Gate the snapshot restore on `received == nil` so it
        // only fills in when nothing decoded (drawer open, own bubble) instead
        // of clobbering a just-decoded state — the leave-clears empty the
        // snapshot, which erased the "X left" banner.
        if !decodedIncoming, received == nil, let snapshot {
            currentParticipants = snapshot.participants
            // A user who left this meetup must NOT be restored into its agreed/
            // proposed UI (the snapshot deliberately keeps the group's state
            // alive for a rejoin — D4 — but this device renders as "out").
            // Without the tombstone gate, a leaver reopening the extension was
            // force-expanded straight back into MEETUP SET (post-push audit).
            received = ConversationMeetupStore.localUserLeft(key: key)
                ? nil
                : snapshot.agreedState ?? snapshot.proposedState
            // Cached state, not a live decode — surface its age so a newer
            // unprocessed bubble (someone's leave, a counter) isn't mistaken
            // for absent.
            if received != nil || !snapshot.participants.isEmpty,
               sendStatusMessage == nil {
                sendStatusMessage = snapshotHint(for: snapshot)
            }
        } else if decodedIncoming {
            clearSnapshotHint()
        }
        // Apply the agreed-meetup override even when no message decoded
        // (e.g. selectedMessage was the local user's own bubble, which
        // decodeAndCache skips). Lets the terminal MEETUP SET survive
        // extension re-launches initiated by tapping any bubble, including
        // the agree bubble itself when it was sent by this device.
        received = effectiveReceived(decoded: received)
        // Jump to expanded when there's something to act on: a spot the host app
        // staged for us, or an incoming invite to respond to (so the invitation
        // banner and auto-ranked spots are front and center).
        draft = ConversationMeetupStore.loadDraft(key: key)
        if draft == nil, let globalDraft = OutgoingDraftStore.load() {
            // Adopt only drafts staged for THIS conversation (or unbound
            // legacy ones) that are still fresh; a foreign or stale draft is
            // consumed either way so it can't haunt the next chat (W7).
            if OutgoingDraftStore.shouldAdopt(globalDraft, conversationKey: key) {
                draft = globalDraft
                ConversationMeetupStore.saveDraft(globalDraft, key: key)
            }
            OutgoingDraftStore.clear()
        }
        if draft != nil || received != nil {
            requestPresentationStyle(.expanded)
            kickOffRanking()
        }
        presentUI(for: presentationStyle)
        retryBlankRenderIfNeeded()
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        if presentationStyle == .expanded {
            kickOffRanking()
        } else {
            rankingTask?.cancel()
            isRanking = false
        }
        presentUI(for: presentationStyle)
    }

    override func didReceive(_ message: MSMessage, conversation: MSConversation) {
        super.didReceive(message, conversation: conversation)
        if let session = message.session {
            lastKnownSession = session
        }
        let savedPeer = decodeAndCache(message, in: conversation)
        recentlySentSpotName = nil
        // A live inbound bubble supersedes any "cached state" hint.
        clearSnapshotHint()
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

    override func didStartSending(_ message: MSMessage, conversation: MSConversation) {
        super.didStartSending(message, conversation: conversation)
        // The user tapped send on a staged (insert-fallback) bubble — the
        // "tap send to deliver" hint has served its purpose.
        if sendStatusMessage == Self.stagedDeliveryStatus {
            sendStatusMessage = nil
        }
        // A staged leave/agree commits only NOW: this is the moment the user
        // actually sent it (deliverBubble deferred the revision floor and
        // canonical snapshot for staged sends).
        if let url = message.url, let state = TweenState(url: url) {
            commitStagedSendIfNeeded(state, conversation: conversation)
        }
        presentUI(for: presentationStyle)
    }

    /// Commits a previously STAGED `.leave`/`.agree` now that it verifiably
    /// went out — from `didStartSending` (user tapped send while the
    /// extension was alive) or from the decode backstop in `decodeAndCache`
    /// (extension was killed in between; the tapped own bubble proves
    /// delivery). Decoding the sent message rather than relying on an ivar
    /// keeps the commit correct across extension relaunches. Gated on:
    ///   * the pending marker — only bubbles deliverBubble actually staged
    ///     commit here (the direct-send path never sets it, so an already
    ///     committed send can't re-enter);
    ///   * the revision floor — a stale staged bubble (the floor advanced
    ///     while it sat in the input field) is rejected by every peer via
    ///     shouldAcceptInbound, so committing it locally would roll back
    ///     canonical roster/proposal state peers no longer hold.
    func commitStagedSendIfNeeded(_ state: TweenState, conversation: MSConversation) {
        // Conversation-derived key, matching the SET site in deliverBubble —
        // preferring the ivar here could miss a marker set moments earlier
        // under a key derived from a changed participant set.
        let key = Self.conversationKey(for: conversation)
        guard let pending = ConversationMeetupStore.pendingStagedSend(key: key),
              pending == state.messageType else { return }
        ConversationMeetupStore.setPendingStagedSend(nil, key: key)
        // Every bubble THIS mechanism stages carries a revision (staging
        // happens after willBecomeActive set the conversation key), so a
        // rev-less state here is some older bubble that merely matches the
        // marker's type — without a floor to check it against, committing
        // it could replay an ancient departure. Treat it as stale.
        guard let revision = state.revision else {
            logger.debug("Skipping rev-less staged \(state.messageType.rawValue, privacy: .public)")
            return
        }
        if revision < ConversationMeetupStore.lastRevision(key: key) {
            logger.debug("Skipping stale staged \(state.messageType.rawValue, privacy: .public) rev=\(revision, privacy: .public)")
            return
        }
        ConversationMeetupStore.noteRevision(
            revision, sender: localParticipantID(), key: key)
        recordCanonicalSnapshot(for: state, key: key)
        switch state.messageType {
        case .leave:
            commitDeliveredLeave(remaining: state.participants)
        case .agree:
            commitDeliveredAgree(state)
        default:
            break
        }
    }

    override func willResignActive(with conversation: MSConversation) {
        super.willResignActive(with: conversation)
        // Drop every background task before we're backgrounded.
        rankingTask?.cancel()
        sendTask?.cancel()
        isSending = false
        // The cancelled task can't run its own reset — without this,
        // reactivating mid-rank shows a stuck "Finding fair spots...".
        isRanking = false
    }

    // MARK: - Hosting

    func presentUI(for style: MSMessagesAppPresentationStyle) {
        let isUserIn = isLocalUserInCurrentConversation
        logger.debug("presentUI style=\(String(describing: style), privacy: .public) hasReceived=\(self.received != nil, privacy: .public) isActive=\(isUserIn, privacy: .public)")
        let root: AnyView

        switch style {
        case .expanded:
            root = AnyView(
                ExpandedView(
                    received: received,
                    selfCoord: isUserIn ? LocationCache.loadSelf()?.coordinate : nil,
                    rankedSpots: rankedSpots,
                    isUserIn: isUserIn,
                    totalSeats: totalConversationParticipants,
                    isRanking: isRanking,
                    isOnline: networkMonitor.isOnline,
                    draft: draft,
                    localParticipantID: localParticipantID(),
                    recentlySentSpotName: recentlySentSpotName,
                    onImIn: { [weak self] in self?.handleImIn() },
                    onImOut: { [weak self] in self?.handleImOut() },
                    onSelectSpot: { [weak self] spot in
                        if self?.received?.kind == .place {
                            self?.sendCounter(spot)
                        } else {
                            self?.sendChosenSpot(spot)
                        }
                    },
                    onAgreePlace: { [weak self] state in self?.sendAgreedPlace(state) },
                    onSendDraft: { [weak self] in self?.sendDraft() },
                    onOpenFullApp: { [weak self] in self?.openFullAppSearch() },
                    onOpenInMaps: { [weak self] state in self?.openInPreferredMaps(for: state) },
                    isSending: isSending,
                    statusMessage: sendStatusMessage,
                    statusIsError: sendStatusIsError
                )
            )
        default:
            root = AnyView(
                CompactView(
                    received: received,
                    isUserIn: isUserIn,
                    localParticipantID: localParticipantID(),
                    currentParticipantCount: currentParticipants.isEmpty ? nil : currentParticipants.count,
                    isSending: isSending,
                    statusMessage: sendStatusMessage,
                    onImIn: { [weak self] in self?.handleImIn() },
                    onImOut: { [weak self] in self?.handleImOut() },
                    onExpand: { [weak self] in self?.requestPresentationStyle(.expanded) }
                )
            )
        }

        embed(root)
    }

    /// Reuses the hosting controller across renders — only the SwiftUI root is
    /// swapped — so re-ranking doesn't tear down and rebuild the view tree.
    func embed(_ rootView: AnyView) {
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

    func retryBlankRenderIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentUI(for: self.presentationStyle)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let hostBounds = self.hosting?.view.bounds ?? .zero
            if hostBounds.isEmpty || self.view.bounds.isEmpty {
                self.presentUI(for: self.presentationStyle)
                self.view.setNeedsLayout()
                self.view.layoutIfNeeded()
            }
        }
    }

}
