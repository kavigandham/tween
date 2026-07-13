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

    /// The MSSession of the most recent Tween bubble seen in this conversation
    /// (tapped or received live). Reused by outgoing sends when
    /// `selectedMessage` is nil — e.g. the extension was opened from the app
    /// drawer — so replies keep collapsing into one evolving bubble instead of
    /// minting a new session (and a new bubble stack) per send.
    private var lastKnownSession: MSSession?

    private var rankingTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var isRanking = false
    private var isSending = false
    private var sendStatusMessage: String?
    private var recentlySentSpotName: String?
    private var conversationKey: String?

    private let locationProvider = LocationProvider()
    private let networkMonitor = NetworkMonitor()
    private let logger = Logger(subsystem: "com.kavigandham.TweenApp", category: "Messages")

    private var hosting: UIHostingController<AnyView>?

    /// Permanent opaque tile pinned to `self.view.bounds` beneath the hosting
    /// view. If the hosting view ever renders with a zero frame (bounds not
    /// settled), fails to attach, or is transient during a rootView swap, the
    /// user sees this solid `.systemBackground` surface instead of the
    /// Messages-host blank strip. See `docs/ui-research.md` §3 (blank-render
    /// causes) and `.claude/skills/imessage-extension.md`.
    private var fallbackView: UIView?

    /// Set when a memory warning fires while expanded: it tells `ExpandedView` to
    /// shed its live `MKMapView` and fall back to the static snapshot, our last line
    /// of defense against the ~120 MB extension jetsam ceiling. Reset on collapse.
    private var mapDegraded = false

    /// Default place query for the extension's fair-spot search. There's no
    /// category UI here, so we bias toward common, universal meetup spots.
    private static let defaultQuery = "cafe restaurant food"

    /// Status copy set by `deliverBubble` when direct send was rejected and
    /// the bubble was staged in the input field instead. `handleImIn` compares
    /// against it to avoid expanding the extension over the staged bubble the
    /// user still needs to tap send on.
    private static let stagedDeliveryStatus = "Added to the message box — tap send to deliver."

    /// Hard cap for route resolution inside the extension (vs. 8 in the app).
    private static let rankCap = 5
    /// Fetch a slightly larger search pool than we route. MapKit's first few
    /// hits can drift off-axis, so ranking needs nearby alternatives to choose
    /// from without paying route costs for all of them.
    private static let searchPoolSize = 8
    /// iMessage extensions are short-lived; don't let MapKit search leave the
    /// CTA stuck in "Finding fair spots..." if the network or service stalls.
    private static let searchTimeoutNanoseconds: UInt64 = 8_000_000_000

    /// The status strings that mean something FAILED. `sendStatusMessage` is
    /// one channel carrying three kinds of copy (progress, confirmation,
    /// failure); the views style only these as a warning banner so a routine
    /// "Sent X to the chat" never renders with an alarm icon.
    private static let errorStatuses: Set<String> = [
        "Couldn't send the Tween message. Try again.",
        "Location unavailable. Check permission and try again.",
        "Google Maps isn't installed."
    ]

    private var sendStatusIsError: Bool {
        sendStatusMessage.map { Self.errorStatuses.contains($0) } ?? false
    }

    /// Prefix for the cached-state hint. A device only learns of new bubbles
    /// when one is tapped (or while the extension is open) — nobody taps an
    /// "I'm out" bubble, they just read it — so state rendered from the local
    /// snapshot may be behind the conversation. Say so instead of presenting
    /// it as live. Prefix-matched when clearing on a real decode.
    private static let snapshotHintPrefix = "Last update "

    private func snapshotHint(for snapshot: MeetupSnapshot) -> String {
        Self.snapshotHintPrefix + RelativeTime.string(from: snapshot.updatedAt)
            + " — tap the newest Tween bubble to refresh"
    }

    private func clearSnapshotHint() {
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
    private func installFallbackView() {
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
            // A memory-degraded static map is per-conversation — don't carry the
            // fallback into the next chat's fresh render.
            mapDegraded = false
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
            received = snapshot.agreedState ?? snapshot.proposedState
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
            // Collapsing already frees the map (CompactView has none); clear the
            // degrade flag so the next expansion gets the live map back.
            mapDegraded = false
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
    private func commitStagedSendIfNeeded(_ state: TweenState, conversation: MSConversation) {
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
        if message.senderParticipantIdentifier == conversation.localParticipantIdentifier {
            // Own bubble: never decoded as inbound state — but if it's a
            // staged .leave/.agree the user sent AFTER this extension was
            // torn down (didStartSending never fired), this tap is the only
            // proof it went out. Commit it now, or the leaver stays "in" on
            // their own device forever (post-push audit backstop).
            commitStagedSendIfNeeded(state, conversation: conversation)
            return false
        }
        // Revision guard (T1 old-bubble resurrection): every bubble is a
        // canonical roster snapshot, so without ordering, tapping an OLDER
        // bubble re-adopted its stale roster verbatim — a leaver popped back
        // "in". Ignore anything older than the newest revision seen for this
        // chat. Rev-less payloads (older builds, host-app sends) keep the
        // legacy trust-the-tap semantics.
        let revisionKey = conversationKey ?? Self.conversationKey(for: conversation)
        if let revision = state.revision {
            // Older-than-floor bubbles reject; AT the floor only the sender
            // who set it (or any .invite — concurrent joins must union) is
            // accepted — concurrent same-revision place mints by another
            // device don't (W2 tie-break; messageType threads the exception).
            guard ConversationMeetupStore.shouldAcceptInbound(
                revision: revision, senderID: state.senderID,
                messageType: state.messageType, key: revisionKey) else {
                logger.debug("Ignoring stale bubble rev=\(revision, privacy: .public)")
                return false
            }
            ConversationMeetupStore.noteRevision(revision, sender: state.senderID, key: revisionKey)
        }
        received = effectiveReceived(decoded: state)
        logger.debug("Decoded incoming Tween message type=\(state.messageType.rawValue, privacy: .public) participants=\(state.participants.count, privacy: .public) agreed=\(state.agreedNames.count, privacy: .public)")

        // Persist / clear the agreed-meetup cache based on the new state:
        //   - .agree fully agreed → persist (terminal state survives extension restarts)
        //   - .counter → clear (counter restarts negotiation, prior agreement is undone)
        //   - others → leave the cache alone
        if state.messageType == .agree, state.isFullyAgreed {
            LocationCache.saveAgreedMeetup(state)
            if let conversationKey {
                ConversationMeetupStore.saveAgreed(state, key: conversationKey)
            }
        } else if state.messageType == .counter {
            LocationCache.clearAgreedMeetup()
            if let conversationKey {
                ConversationMeetupStore.saveProposed(state, key: conversationKey)
            }
        } else if state.messageType == .leave {
            if state.participants.isEmpty {
                LocationCache.clearAgreedMeetup()
                if let conversationKey {
                    ConversationMeetupStore.clearProposalState(key: conversationKey)
                }
            }
        } else if state.kind == .place, let conversationKey {
            ConversationMeetupStore.saveProposed(state, key: conversationKey)
        }

        // Roster adoption is a MERGE, not a replace (group-session semantics:
        // the conversation is a standing meetup people join and leave freely).
        // The incoming list is one sender's view — treating it as canonical
        // let a leave→rejoin bubble carrying `[me]` wipe the whole group on
        // every device that tapped it. Joins/updates merge additively; only
        // an explicit `.leave` removes (its sender), and departure tombstones
        // keep the removal sticky against rosters from peers who never
        // processed the leave — until that person's own rejoin lifts theirs.
        let senderKeys = RosterMerge.senderKeys(senderID: state.senderID, senderName: state.senderName)
        // Absorb gossiped departures — minus the local user, whose own
        // presence is governed solely by the localUserLeft tombstone.
        let myKeys: Set<String> = [localParticipantID(), Self.localParticipantName()]
        ConversationMeetupStore.noteDeparted(state.departed.filter { !myKeys.contains($0) },
                                             key: revisionKey)
        if state.messageType == .leave {
            ConversationMeetupStore.noteDeparted(senderKeys, key: revisionKey)
        } else {
            ConversationMeetupStore.clearDeparted(senderKeys, key: revisionKey)
        }

        // The local user's own entry after they've left still gets the
        // dedicated tombstone filter: peers who never tapped the leave bubble
        // keep broadcasting this user in their rosters (a bubble is only
        // processed when tapped, and nobody taps "X is out" — they just read
        // it). Without it, any later bubble silently re-adds the leaver.
        var incomingRoster = state.participants
        if ConversationMeetupStore.localUserLeft(key: revisionKey) {
            let myName = Self.localParticipantName()
            let myId = localParticipantID()
            let legacyID = conversation.localParticipantIdentifier.uuidString
            incomingRoster.removeAll { $0.matches(id: myId, name: myName) || $0.id == legacyID }
        }
        if !incomingRoster.isEmpty || state.messageType == .leave {
            let known = currentParticipants.isEmpty ? activeSnapshotParticipants() : currentParticipants
            let merged = RosterMerge.merge(
                local: known,
                incoming: incomingRoster,
                messageType: state.messageType,
                senderKeys: senderKeys,
                departed: ConversationMeetupStore.departedParticipants(key: revisionKey))
            currentParticipants = merged
            LocationCache.saveParticipantSnapshot(merged, localContext: localParticipantContext())
            saveParticipantsForActiveConversation(merged)
        }

        // Legacy single-peer cache: write the most recent NON-LOCAL coordinate
        // so OnboardingView's polling keeps animating. The name comparison MUST
        // use the same fallback the host app uses (UserName.fallback = "You");
        // without it, when UserProfile.displayName is nil, every participant's
        // non-nil name wins the != comparison and the first entry — possibly
        // the LOCAL user — leaks into the peer cache. That was Bug #4.
        let myName = Self.localParticipantName()
        let myId = localParticipantID()
        if let peer = state.participants.first(where: { !$0.matches(id: myId, name: myName) }) {
            LocationCache.savePeer(peer.coordinate, isActive: true)
            logger.debug("Saved peer coordinate lat=\(peer.latitude, privacy: .public) lon=\(peer.longitude, privacy: .public)")
            return true
        } else if !state.participants.isEmpty || state.messageType == .leave {
            LocationCache.setPeerActive(false)
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

    /// The durable identity stamped into every payload this device emits.
    /// Was `activeConversation?.localParticipantIdentifier` — but that UUID is
    /// device-scoped (a peer can never match it) and re-mintable. The stable
    /// install ID survives conversations, renames, and reinstalls of state.
    private func localParticipantID() -> String {
        TweenIdentity.stableID
    }

    /// The conversation-scoped UUID this device stamped into payloads BEFORE
    /// the stable install ID existed. Used only to filter this user's own
    /// legacy roster entries during the transition.
    private func legacyLocalParticipantID() -> String? {
        activeConversation?.localParticipantIdentifier.uuidString
    }

    private static func conversationKey(for conversation: MSConversation) -> String {
        ConversationMeetupStore.conversationKey(
            localID: conversation.localParticipantIdentifier.uuidString,
            remotes: conversation.remoteParticipantIdentifiers.map(\.uuidString))
    }

    /// Mints the next outgoing payload revision for the active conversation.
    /// Deliberately NOT recorded here: the revision is noted by deliverBubble
    /// only once the bubble is actually sent/staged. Recording at mint time
    /// meant every failed or cancelled send burned a revision, and after two
    /// of those the peer's genuinely-new bubbles decoded as "stale" and were
    /// silently dropped. Nil (legacy semantics) when no conversation is known.
    private func nextOutgoingRevision() -> Int? {
        guard let conversationKey else { return nil }
        return ConversationMeetupStore.lastRevision(key: conversationKey) + 1
    }

    private func activeSnapshotParticipants() -> [Participant] {
        guard let conversationKey,
              let snapshot = ConversationMeetupStore.load(key: conversationKey)
        else { return [] }
        return snapshot.participants
    }

    private func saveParticipantsForActiveConversation(_ participants: [Participant]) {
        guard let conversationKey else { return }
        ConversationMeetupStore.saveParticipants(participants, key: conversationKey)
    }

    private func localParticipantContext() -> LocalParticipantContext {
        LocalParticipantContext(id: localParticipantID(),
                                name: Self.localParticipantName())
    }

    private var isLocalUserInCurrentConversation: Bool {
        let context = localParticipantContext()
        let participants = currentParticipants.isEmpty ? activeSnapshotParticipants() : currentParticipants
        return participants.contains(where: { $0.matches(context) })
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
        // Conversation-scoped agreement ONLY when we know which conversation
        // we're in. The device-global LocationCache fallback is reserved for
        // the keyless case — falling back to it whenever the scoped store had
        // no agreement leaked chat A's MEETUP SET into chat B.
        let agreedCandidate: TweenState?
        if let conversationKey {
            agreedCandidate = ConversationMeetupStore.load(key: conversationKey)?.agreedState
        } else {
            agreedCandidate = LocationCache.loadAgreedMeetup()
        }
        guard let agreed = agreedCandidate, agreed.isFullyAgreed else {
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
        a.sameSpot(as: b)   // shared epsilon — see TweenState.sameSpot(as:)
    }

    /// Builds the next outgoing participant list by removing any prior entry
    /// for the local user and appending a fresh one with the current coordinate.
    /// New payloads preserve the iMessage participant UUID, with name fallback
    /// only for legacy bubbles.
    private func nextParticipantList(myCoord: CLLocationCoordinate2D,
                                     conversation: MSConversation?) -> [Participant] {
        let myName = Self.localParticipantName()
        let myId = localParticipantID()
        // Entries this device minted BEFORE the stable install ID existed
        // carry the conversation-scoped UUID; drop those too or the user
        // duplicates themselves the first time they act on an older roster.
        let legacyID = conversation?.localParticipantIdentifier.uuidString
        let scoped = currentParticipants.isEmpty ? activeSnapshotParticipants() : currentParticipants
        let source = scoped.isEmpty ? [] : scoped
        let others = source.filter { !$0.matches(id: myId, name: myName) && $0.id != legacyID }
        let needsRide = source.first(where: { $0.matches(id: myId, name: myName) || $0.id == legacyID })?.needsRide ?? false
        let me = Participant(id: myId, name: myName, coordinate: myCoord, needsRide: needsRide)
        return others + [me]
    }

    private func participantListWithoutMe() -> [Participant] {
        let myName = Self.localParticipantName()
        let myId = localParticipantID()
        let legacyID = legacyLocalParticipantID()
        let scoped = currentParticipants.isEmpty ? activeSnapshotParticipants() : currentParticipants
        let source = scoped.isEmpty ? [] : scoped
        return source.filter { !$0.matches(id: myId, name: myName) && $0.id != legacyID }
    }

    // MARK: - Hosting

    private func presentUI(for style: MSMessagesAppPresentationStyle) {
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
                    useStaticMap: mapDegraded,
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
                    onOpenAppleMaps: { [weak self] state in self?.openAppleMaps(for: state) },
                    onOpenGoogleMaps: { [weak self] state in self?.openGoogleMaps(for: state) },
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

    private func retryBlankRenderIfNeeded() {
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

    // MARK: - Ranking

    /// Searches the centroid region for candidate spots and ranks them by
    /// fairness across every "in" participant. Re-renders the expanded UI
    /// when finished. No-ops while fewer than two participants have shared
    /// their location.
    private func kickOffRanking() {
        rankingTask?.cancel()

        let participants = rankingParticipants()
        guard participants.count >= 2 else {
            isRanking = false
            if !rankedSpots.isEmpty {
                rankedSpots = []
            }
            presentUI(for: presentationStyle)
            return
        }

        isRanking = true
        presentUI(for: presentationStyle)

        let center = MapGeometry.centroid(of: participants)
        // Search radius widens as the group spreads out.
        let span = participants.reduce(0.04) { acc, p in
            let dLat = abs(p.latitude - center.latitude)
            let dLon = abs(p.longitude - center.longitude)
            return max(acc, max(dLat, dLon) * 2.0)
        }
        // recommendedCap scales with group size (10 for two people) — inside
        // the extension the ~120 MB ceiling caps candidates at 5 regardless.
        let cap = min(Self.rankCap, FairnessRanker.recommendedCap(for: participants.count))

        rankingTask = Task { @MainActor in
            let region = MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
            let pool = await Self.searchCandidates(
                query: Self.defaultQuery,
                region: region,
                minimumCount: Self.searchPoolSize,
                timeoutNanoseconds: Self.searchTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            // Hard between-people cut BEFORE ranking: the merged pool can be
            // dominated by a commercial corridor off to one side (the request
            // region is only relevance guidance, and the broadened fallback is
            // unconstrained), and the soft centrality penalty can't rescue a
            // pool that's entirely off-axis (device feedback).
            let candidates = SpotVicinity.filter(pool, participants: participants, minimumCount: 3)
            guard !candidates.isEmpty else {
                self.isRanking = false
                self.rankedSpots = []
                self.presentUI(for: self.presentationStyle)
                return
            }

            let ranked = await FairnessRanker.rank(
                candidates: candidates, participants: participants, cap: cap)
            guard !Task.isCancelled else { return }

            self.rankedSpots = ranked
            self.isRanking = false
            self.presentUI(for: self.presentationStyle)
        }
    }

    private static func searchCandidates(query: String,
                                         region: MKCoordinateRegion,
                                         minimumCount: Int,
                                         timeoutNanoseconds: UInt64) async -> [MKMapItem] {
        let local = await searchItems(query: query,
                                      region: region,
                                      regionRequired: true,
                                      timeoutNanoseconds: timeoutNanoseconds)
        if #available(iOS 18.0, *), local.count < minimumCount {
            let fallback = await searchItems(query: query,
                                             region: region,
                                             regionRequired: false,
                                             timeoutNanoseconds: timeoutNanoseconds)
            return SearchResultMerger.merge(local: local, fallback: fallback, minimumCount: minimumCount)
        }
        return SearchResultMerger.deduped(local)
    }

    private static func searchItems(query: String,
                                    region: MKCoordinateRegion,
                                    regionRequired: Bool,
                                    timeoutNanoseconds: UInt64) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = region
        if regionRequired, #available(iOS 18.0, *) {
            request.regionPriority = .required
        }

        let response = await withTaskGroup(of: MKLocalSearch.Response?.self) { group in
            group.addTask {
                try? await MKLocalSearch(request: request).start()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }

            let response = await group.next() ?? nil
            group.cancelAll()
            return response
        }
        return response?.mapItems ?? []
    }

    private func rankingParticipants() -> [Participant] {
        let myName = Self.localParticipantName()
        var source: [Participant]
        if let received, received.participants.count >= 2, currentParticipants.count < 2 {
            source = received.participants
        } else if !currentParticipants.isEmpty {
            source = currentParticipants
        } else if let received, !received.participants.isEmpty {
            source = received.participants
        } else {
            source = activeSnapshotParticipants()
        }

        if currentParticipants.isEmpty, !source.isEmpty {
            currentParticipants = source
            LocationCache.saveParticipantSnapshot(source, localContext: localParticipantContext())
            saveParticipantsForActiveConversation(source)
        }

        let myId = localParticipantID()
        let rosterSelfCoordinate = source.first(where: { $0.matches(id: myId, name: myName) })?.coordinate
        source = source.filter { !$0.matches(id: myId, name: myName) }
        // Rank with the cached fix only while it's FRESH (isActive = opted
        // in + within the 5-min window); otherwise fall back to the roster
        // entry — the coordinate peers already see — instead of skewing
        // fairness with a stale private cache (audit W4).
        let selfCoordinate = (LocationCache.isActive ? LocationCache.loadSelf()?.coordinate : nil)
            ?? rosterSelfCoordinate
        if isLocalUserInCurrentConversation, let mySelf = selfCoordinate {
            let needsRide = currentParticipants.first(where: { $0.matches(id: myId, name: myName) })?.needsRide
                ?? activeSnapshotParticipants().first(where: { $0.matches(id: myId, name: myName) })?.needsRide
                ?? false
            source.append(Participant(id: myId, name: myName, coordinate: mySelf, needsRide: needsRide))
        }
        return source
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
            if let manual = LocationCache.loadSelf(), manual.isManual == true, LocationCache.isActive {
                // The user declared a future location ("I'll be at…") in the app
                // AND is still active — join with THAT, don't overwrite it with a
                // live GPS fix. A deactivated declaration (after leaving) must NOT
                // be re-shared; fall through to a fresh fix (post-push audit).
                coordinate = manual.coordinate
                logger.debug("Joined with a declared (manual) self location")
            } else if let fresh = await acquireLocation() {
                // Cache the fix but keep the prior active flag — the host app
                // reads LocationCache.isActive as "you're in", so a join must
                // not look successful before the bubble is actually delivered.
                LocationCache.save(fresh, isActive: LocationCache.isActive)
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

            let state = TweenState(
                text: "I'm in",
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                senderName: UserProfile.displayName,
                senderID: self.localParticipantID(),
                kind: .participant,
                messageType: .invite,
                participants: participants,
                revision: self.nextOutgoingRevision()
            )
            logger.debug("Encoding I'm in reply participants=\(participants.count, privacy: .public)")
            let didSend = await sendBubbleNow(for: state)
            if didSend {
                // Commit the join only once the bubble is delivered (or staged):
                // a failed send must not leave this device claiming "You're in".
                // deliverBubble already wrote the conversation-scoped roster via
                // recordCanonicalSnapshot.
                LocationCache.setActive(true)
                self.currentParticipants = participants
                // Tombstone FIRST: LocationCache's global-mirror writes are
                // dammed while it's set (audit at 69a3886) — joining clears
                // it, then the roster write goes through.
                if let conversationKey = self.conversationKey {
                    ConversationMeetupStore.setLocalUserLeft(false, key: conversationKey)
                }
                LocationCache.saveParticipantSnapshot(participants, localContext: localParticipantContext())
            }
            isSending = false
            if didSend {
                // Preserve the insert-fallback's "tap send to deliver" hint —
                // only clear the status when it's still our in-progress copy.
                if sendStatusMessage == "Sharing your location..." { sendStatusMessage = nil }
            } else if !Task.isCancelled {
                // A backgrounding-cancelled task must not stamp a failure
                // banner for a send the user never saw fail (post-push audit).
                sendStatusMessage = "Couldn't send the Tween message. Try again."
            }
            presentUI(for: presentationStyle)

            // Now that we have a fix, surface the fair spots: jump to expanded
            // (which triggers ranking) and also rank directly to cover the case
            // where we're already expanded and no transition fires. Skip the
            // expand when the bubble was only STAGED — expanding would cover
            // the input field holding the bubble the user still has to send.
            if sendStatusMessage != Self.stagedDeliveryStatus {
                requestPresentationStyle(.expanded)
            }
            kickOffRanking()
        }
    }

    /// Removes the local user from the active roster and sends a canonical
    /// `.leave` snapshot so every recipient stops ranking this participant.
    private func handleImOut() {
        sendTask?.cancel()
        sendTask = Task { @MainActor in
            isSending = true
            sendStatusMessage = "Leaving this meetup..."
            presentUI(for: presentationStyle)

            let remainingParticipants = participantListWithoutMe()

            let fallbackCoordinate = LocationCache.loadSelf()?.coordinate
                ?? remainingParticipants.first?.coordinate
                ?? MapGeometry.defaultCenter
            let state = TweenState(
                text: "I'm out",
                latitude: fallbackCoordinate.latitude,
                longitude: fallbackCoordinate.longitude,
                senderName: UserProfile.displayName,
                senderID: self.localParticipantID(),
                kind: .participant,
                messageType: .leave,
                participants: remainingParticipants,
                revision: self.nextOutgoingRevision()
            )
            logger.debug("Encoding I'm out reply participants=\(remainingParticipants.count, privacy: .public)")
            let didSend = await sendBubbleNow(for: state)
            // A direct-send rejection stages the bubble in the input field —
            // the user hasn't actually left until they tap send on it (they
            // can still delete it). Committing the leave here anyway made
            // THIS device believe it left while no peer ever learned, the
            // classic "lingering person on everyone's map" split-brain. The
            // staged commit now waits for didStartSending.
            if didSend, sendStatusMessage != Self.stagedDeliveryStatus {
                commitDeliveredLeave(remaining: remainingParticipants)
            }
            isSending = false
            if didSend {
                // Preserve the insert-fallback's "tap send to deliver" hint —
                // only clear the status when it's still our in-progress copy.
                if sendStatusMessage == "Leaving this meetup..." { sendStatusMessage = nil }
            } else if !Task.isCancelled {
                sendStatusMessage = "Couldn't send the Tween message. Try again."
            }
            presentUI(for: presentationStyle)
        }
    }

    /// The local-state half of a leave. Runs only once the leave bubble was
    /// actually delivered (direct send) or actually sent by the user (staged
    /// bubble → `didStartSending`). Clears EVERYTHING meetup-scoped: after
    /// "I'm out" no roster residue, ranked spots, drafts, or stale map state
    /// may survive on this device (device feedback).
    private func commitDeliveredLeave(remaining: [Participant]) {
        // Keep the REMAINING roster, not [] — the meetup is still live for
        // everyone else (group-session semantics), and wiping it here made
        // the next rejoin broadcast a roster of just [me], erasing the group
        // on every device that tapped it. "Am I in" is answered by
        // membership, not roster emptiness.
        currentParticipants = remaining
        // The scoped snapshot (recordCanonicalSnapshot .leave) keeps the
        // rejoin roster; the un-TTL'd GLOBAL mirrors must not — a roster
        // parked there outlived the snapshot's 24 h window and resurrected
        // the departed peer in the host app (audit at 18c182a).
        LocationCache.clearParticipants()
        LocationCache.setPeerActive(false)
        LocationCache.deactivateSelf()
        LocationCache.clearAgreedMeetup()
        // Tombstone: peers who never tap this leave bubble will keep
        // sending rosters that include this user — decode filters
        // those entries until an explicit rejoin. Any staged-send marker
        // from an earlier abandoned bubble is moot once a real leave lands.
        if let conversationKey {
            ConversationMeetupStore.setLocalUserLeft(true, key: conversationKey)
            ConversationMeetupStore.setPendingStagedSend(nil, key: conversationKey)
        }
        // An in-flight ranking would repopulate the spot list right after
        // this reset; a surviving draft (in-memory or the App-Group
        // hand-off blob) re-offered a pending message after leaving.
        rankingTask?.cancel()
        isRanking = false
        rankedSpots = []
        draft = nil
        OutgoingDraftStore.clear()
        mapDegraded = false
        recentlySentSpotName = nil
        // Drop the decoded meetup too — CompactView's thumbnail and
        // ExpandedView's peer pins render from `received.participants`,
        // so leaving it set kept everyone on the leaver's map. The next
        // activation stays clean via the snapshot-restore gate (the
        // .leave canonical snapshot wiped the store).
        received = nil
    }

    /// Proposes a specific ranked spot to the group. The participants list is
    /// carried forward verbatim so the recipient knows everyone's in.
    private func sendChosenSpot(_ spot: RankedSpot) {
        guard let item = spot.item else { return }
        let coordinate = item.placemark.coordinate
        // Fresh-only (audit W4): a cache older than the 5-min window must
        // not ride into the outgoing roster as if it were current — the
        // roster/currentParticipants fallback below carries the last
        // coordinate peers actually saw instead.
        let mySelf = LocationCache.isActive ? LocationCache.loadSelf()?.coordinate : nil
        // Make sure my own entry is in the participants list before proposing.
        let participants: [Participant]
        if let mySelf {
            participants = nextParticipantList(myCoord: mySelf, conversation: activeConversation)
        } else {
            participants = currentParticipants
        }

        let state = TweenState(
            text: item.name ?? "Spot",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            senderName: UserProfile.displayName,
            senderID: localParticipantID(),
            kind: .place,
            senderCoordinate: mySelf,
            messageType: .propose,
            participants: participants,
            revision: nextOutgoingRevision()
        )
        sendBubble(state: state) { [weak self] in
            guard let self else { return }
            // Commit the roster only on delivery; the conversation-scoped
            // write is covered by recordCanonicalSnapshot (.propose).
            self.currentParticipants = participants
            LocationCache.saveParticipantSnapshot(participants, localContext: localParticipantContext())
        }
    }

    /// Agrees to a previously proposed place. Carries the participants forward
    /// and appends this user's identity to the agreement list; the receiver decides if
    /// that's enough for full consensus via `state.isFullyAgreed`.
    private func sendAgreedPlace(_ proposed: TweenState) {
        // Re-entrancy guard: without it the Agree button stayed enabled for
        // the whole location-fix + send window, and a second tap past the
        // point of no return emitted a second .agree bubble (audit).
        guard !isSending else { return }
        sendTask?.cancel()
        sendTask = Task { @MainActor in
            isSending = true
            sendStatusMessage = "Sending your agreement..."
            presentUI(for: presentationStyle)
            // Same fresh-fix-first policy as handleImIn: never agree with a
            // stale coord that might land you in a worst-case route the
            // ranker would have rejected.
            let senderCoordinate: CLLocationCoordinate2D?
            if let manual = LocationCache.loadSelf(), manual.isManual == true, LocationCache.isActive {
                // Respect a declared "I'll be at…" location — agree with THAT,
                // never overwrite it with a live GPS fix (which would broadcast
                // your CURRENT spot and strip the declaration). Sibling of the
                // handleImIn guard; missing it here was a post-push audit find.
                senderCoordinate = manual.coordinate
            } else if let fresh = await acquireLocation() {
                // Cache the fix but keep the prior active flag — activation
                // (which the host app reads as "you're in") is committed only
                // once the agree bubble is actually delivered
                // (commitDeliveredAgree keys it off senderCoordinate).
                LocationCache.save(fresh, isActive: LocationCache.isActive)
                senderCoordinate = fresh
            } else if LocationCache.isActive, let cached = LocationCache.loadSelf()?.coordinate {
                senderCoordinate = cached
            } else {
                // No fresh fix and the cache is stale/inactive: omit the
                // sender coordinate (bubble drops slat/slon) rather than
                // broadcasting a stale location as current (audit W4).
                senderCoordinate = nil
            }

            let myName = Self.localParticipantName()
            // Build the forward participants list. The proposed bubble's
            // participants are authoritative; refresh my entry's coord.
            var participants = proposed.participants.isEmpty
                ? self.currentParticipants
                : proposed.participants
            if let myCoord = senderCoordinate {
                let myId = self.localParticipantID()
                let legacyID = self.legacyLocalParticipantID()
                participants = participants.filter { !$0.matches(id: myId, name: myName) && $0.id != legacyID }
                let needsRide = proposed.participants.first(where: { $0.matches(id: myId, name: myName) })?.needsRide
                    ?? self.currentParticipants.first(where: { $0.matches(id: myId, name: myName) })?.needsRide
                    ?? LocationCache.loadParticipants().first(where: { $0.matches(id: myId, name: myName) })?.needsRide
                    ?? false
                participants.append(Participant(id: myId, name: myName, coordinate: myCoord, needsRide: needsRide))
            }

            var agreed = proposed.agreedNames
            // Case-insensitive replace-then-append: "hassan" and "Hassan" are
            // the same person, so a case-variant duplicate would inflate the
            // "X of Y agreed" copy — and appending keeps me as
            // `agreedNames.last`, which captions read as the most recent
            // agreer. agreedIDs drive real consensus; this is display-only.
            agreed.removeAll { $0.caseInsensitiveCompare(myName) == .orderedSame }
            agreed.append(myName)
            let myId = self.localParticipantID()
            // Legacy proposals (no senderID) stay in the NAME namespace end to
            // end. The old fallback stamped the AGREER's id as proposer, which
            // excluded the wrong person from consensus (T7) — and appending a
            // UUID to agreedIDs while the roster ids are names made
            // `isFullyAgreed` compare across namespaces and never fire (T6).
            var agreedIDs: [String]
            if proposed.senderID != nil {
                agreedIDs = proposed.agreedIDs
                if !agreedIDs.contains(myId) { agreedIDs.append(myId) }
            } else {
                agreedIDs = []
            }

            // Preserve the original proposer so consensus is calculated
            // against every other participant, not the most recent agreer.
            let state = TweenState(
                text: proposed.text,
                latitude: proposed.latitude,
                longitude: proposed.longitude,
                senderName: proposed.senderName ?? UserProfile.displayName,
                senderID: proposed.senderID,
                kind: .place,
                senderCoordinate: senderCoordinate,
                action: .agree,
                messageType: .agree,
                participants: participants,
                agreedNames: agreed,
                agreedIDs: agreedIDs,
                revision: self.nextOutgoingRevision()
            )
            logger.debug("Agreeing to place \(proposed.text, privacy: .public) agreed=\(agreed.count, privacy: .public)")
            // Don't dismiss after an agree send — instead, lock in the local
            // view as the terminal MEETUP SET so the agreer immediately sees
            // "It's a plan!" with map-app direction choices, rather than being
            // bounced back to the iMessage thread. The receiver gets the same
            // view via didReceive → presentUI.
            let didSend = await sendBubbleNow(for: state)
            // Direct-send rejection stages the bubble — the user hasn't
            // actually agreed until they tap send on it (they can delete it
            // instead). Same deferral as handleImOut: the staged commit
            // waits for didStartSending / the decode backstop, so a deleted
            // staged agree can't leave this device rendering a MEETUP SET
            // no peer ever saw (post-push audit).
            if didSend, sendStatusMessage != Self.stagedDeliveryStatus {
                commitDeliveredAgree(state)
            }
            isSending = false
            if didSend {
                // Preserve the insert-fallback's "tap send to deliver" hint —
                // only clear the status when it's still our in-progress copy.
                if sendStatusMessage == "Sending your agreement..." { sendStatusMessage = nil }
            } else if !Task.isCancelled {
                sendStatusMessage = "Couldn't send the Tween message. Try again."
            }
            self.presentUI(for: self.presentationStyle)
        }
    }

    /// The local-state half of an agree. Runs only once the agree bubble was
    /// actually delivered (direct send) or actually sent by the user (staged
    /// bubble → `commitStagedSendIfNeeded`).
    private func commitDeliveredAgree(_ state: TweenState) {
        // A usable coordinate rode along — agreeing means being in. When no
        // fresh or cached fix existed the bubble omitted slat/slon and this
        // device's opt-in state stays untouched, exactly as before.
        if state.senderCoordinate != nil {
            LocationCache.setActive(true)
        }
        currentParticipants = state.participants
        // Agreeing means being in — clear the leave tombstone (and any
        // stale staged-send marker) BEFORE the roster write: LocationCache's
        // global-mirror writes are dammed while the tombstone is set
        // (audit at 69a3886).
        if let conversationKey {
            ConversationMeetupStore.setLocalUserLeft(false, key: conversationKey)
            ConversationMeetupStore.setPendingStagedSend(nil, key: conversationKey)
        }
        LocationCache.saveParticipantSnapshot(state.participants, localContext: localParticipantContext())
        // Persist the agreement so re-opening the extension (after iOS
        // dispose, or after the user collapses + re-taps) re-renders
        // MEETUP SET instead of the propose's Agree/Change buttons.
        // Gated on real delivery: a rejected or still-staged send must not
        // render MEETUP SET when no bubble ever reached the chat.
        if state.isFullyAgreed {
            LocationCache.saveAgreedMeetup(state)
            if let conversationKey {
                ConversationMeetupStore.saveAgreed(state, key: conversationKey)
            }
        } else if let conversationKey {
            ConversationMeetupStore.saveProposed(state, key: conversationKey)
        }
        received = effectiveReceived(decoded: state)
    }

    /// Counter-proposes a different spot, resetting agreement to zero. The
    /// proposer becomes the local user and the agreedNames list starts empty.
    private func sendCounter(_ spot: RankedSpot) {
        guard let item = spot.item else { return }
        let coordinate = item.placemark.coordinate
        // Fresh-only (audit W4): a cache older than the 5-min window must
        // not ride into the outgoing roster as if it were current — the
        // roster/currentParticipants fallback below carries the last
        // coordinate peers actually saw instead.
        let mySelf = LocationCache.isActive ? LocationCache.loadSelf()?.coordinate : nil
        let participants: [Participant]
        if let mySelf {
            participants = nextParticipantList(myCoord: mySelf, conversation: activeConversation)
        } else {
            participants = currentParticipants
        }

        let state = TweenState(
            text: item.name ?? "Spot",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            senderName: UserProfile.displayName,
            senderID: localParticipantID(),
            kind: .place,
            senderCoordinate: mySelf,
            messageType: .counter,
            participants: participants,
            agreedNames: [],
            revision: nextOutgoingRevision()
        )
        sendBubble(state: state) { [weak self] in
            guard let self else { return }
            self.currentParticipants = participants
            LocationCache.saveParticipantSnapshot(participants, localContext: localParticipantContext())
            // A counter restarts negotiation — any prior agreement is
            // invalidated, so the persisted terminal cache must be cleared
            // too. Cleared only on delivery: a failed counter must not erase
            // this device's MEETUP SET while peers still hold theirs. The
            // conversation-scoped saveProposed (which also drops the scoped
            // agreed state for counters) is covered by recordCanonicalSnapshot.
            LocationCache.clearAgreedMeetup()
        }
    }

    /// Confirms a host-app hand-off: composes the bubble for the staged draft,
    /// clears it so it isn't offered again, and re-renders.
    private func sendDraft() {
        guard let draft else { return }
        // Fresh-only (audit W4): a cache older than the 5-min window must
        // not ride into the outgoing roster as if it were current — the
        // roster/currentParticipants fallback below carries the last
        // coordinate peers actually saw instead.
        let mySelf = LocationCache.isActive ? LocationCache.loadSelf()?.coordinate : nil
        let participants: [Participant]
        if let mySelf {
            participants = nextParticipantList(myCoord: mySelf, conversation: activeConversation)
        } else {
            participants = currentParticipants
        }

        let state = TweenState(
            text: draft.spotName,
            latitude: draft.latitude,
            longitude: draft.longitude,
            senderName: UserProfile.displayName,
            senderID: localParticipantID(),
            kind: .place,
            senderCoordinate: mySelf,
            messageType: .propose,
            participants: participants,
            revision: nextOutgoingRevision()
        )
        sendBubble(state: state) { [weak self] in
            guard let self else { return }
            self.currentParticipants = participants
            LocationCache.saveParticipantSnapshot(participants, localContext: localParticipantContext())
            // The staged hand-off is consumed only once the bubble is
            // delivered — a failed send keeps the draft offered instead of
            // losing it. Store-side draft clearing is covered by
            // recordCanonicalSnapshot (.propose → clearDraft); sendBubble's
            // own didSend block clears self.draft for place sends.
            OutgoingDraftStore.clear()
        }
    }

    /// `onDelivered` runs only after the bubble was actually delivered (or
    /// staged via the insert fallback) — callers park their local-state
    /// commits there so a failed send never leaves this device claiming
    /// something peers didn't receive. Nil default keeps legacy callers as-is.
    private func sendBubble(state: TweenState, onDelivered: (() -> Void)? = nil) {
        // Re-entrancy guard (same as sendAgreedPlace): a second tap during the
        // render + `conversation.send` window would cancel the first task AFTER
        // it already delivered, then send a duplicate bubble. Covers the propose
        // / counter / draft sends that funnel through here.
        guard !isSending else { return }
        sendTask?.cancel()
        sendTask = Task { @MainActor in
            isSending = true
            sendStatusMessage = sendingMessage(for: state)
            presentUI(for: presentationStyle)

            let didSend = await sendBubbleNow(for: state)
            isSending = false
            if didSend {
                onDelivered?()
                if state.kind == .place {
                    recentlySentSpotName = state.text
                    received = nil
                    draft = nil
                    rankedSpots = []
                }
                // Preserve the insert-fallback's "tap send to deliver" hint —
                // only claim "sent" when the status is still our in-progress copy.
                if sendStatusMessage == sendingMessage(for: state) {
                    sendStatusMessage = sentMessage(for: state)
                }
            } else if !Task.isCancelled {
                sendStatusMessage = "Couldn't send the Tween message. Try again."
            }
            presentUI(for: presentationStyle)
        }
    }

    private func sendingMessage(for state: TweenState) -> String {
        switch state.messageType {
        case .propose, .counter:
            return "Sending \(state.text)..."
        case .agree:
            return "Sending your agreement..."
        case .leave:
            return "Leaving this meetup..."
        case .invite:
            return "Sharing your location..."
        }
    }

    private func sentMessage(for state: TweenState) -> String {
        switch state.messageType {
        case .propose, .counter:
            return "Sent \(state.text) to the chat"
        case .agree:
            return "Agreement sent"
        case .leave:
            return "You're out"
        case .invite:
            return "You're in"
        }
    }


    /// Encodes the state into a bubble, renders its image, and sends/stages it
    /// in the conversation. Staying on the same `MSSession` keeps the thread
    /// collapsed to a single evolving bubble rather than a stack of new ones.
    @discardableResult
    private func sendBubbleNow(for state: TweenState) async -> Bool {
        await deliverBubble(for: state, mode: .send)
    }

    @discardableResult
    private func insertBubble(for state: TweenState, dismissAfterInsert: Bool = false) async -> Bool {
        await deliverBubble(for: state, mode: .insert(dismissAfterInsert: dismissAfterInsert))
    }

    private enum BubbleDeliveryMode {
        case send
        case insert(dismissAfterInsert: Bool)
    }

    @discardableResult
    private func deliverBubble(for state: TweenState, mode: BubbleDeliveryMode) async -> Bool {
        guard let conversation = activeConversation else { return false }
        // Key every canonical write below to the conversation this bubble is
        // being sent in, captured NOW — NOT the `conversationKey` ivar, which a
        // mid-send conversation switch (willBecomeActive repoints it) would land
        // this send's roster/revision/tombstones under the wrong chat.
        let deliveryKey = Self.conversationKey(for: conversation)
        // Departure gossip: every outgoing payload carries the tombstones this
        // device holds, so ANY later bubble tap propagates removals — without
        // it, a leave only ever reached whoever tapped the leave bubble itself.
        var outgoing = state
        outgoing.departed = RosterMerge.gossipKeys(
            departed: ConversationMeetupStore.departedParticipants(key: deliveryKey),
            roster: state.participants)
        guard let url = outgoing.encodedURL() else { return false }

        let localName = UserProfile.displayName
        let image = await BubbleImageRenderer.makeImage(
            state: state,
            participants: state.participants,
            localID: localParticipantID(),
            localName: localName)
        guard !Task.isCancelled else { return false }

        let layout = MSMessageTemplateLayout()
        layout.image = image
        BubbleCaption.apply(to: layout, state: state, totalSeats: self.totalConversationParticipants)

        let session = conversation.selectedMessage?.session ?? lastKnownSession ?? MSSession()
        let message = MSMessage(session: session)
        message.url = url
        message.layout = layout

        guard !Task.isCancelled else { return false }
        do {
            var stagedInsert = false
            switch mode {
            case .send:
                do {
                    try await conversation.send(message)
                    logger.debug("Sent outgoing Tween bubble kind=\(state.kind.rawValue, privacy: .public)")
                } catch {
                    // Messages gates direct send on a recent user tap + a visible
                    // extension (one send per detected interaction, WWDC17 Direct
                    // Send API). Our sends run seconds after the tap (location
                    // fix, snapshot render), so a rejection here is expected —
                    // stage the bubble in the input field instead so delivery
                    // never dead-ends. If insert also throws, the outer catch
                    // reports the failure as before.
                    logger.error("Direct send rejected; staging via insert: \(String(describing: error), privacy: .public)")
                    try await conversation.insert(message)
                    sendStatusMessage = Self.stagedDeliveryStatus
                    stagedInsert = true
                }
            case .insert(let dismissAfterInsert):
                try await conversation.insert(message)
                logger.debug("Inserted outgoing Tween bubble kind=\(state.kind.rawValue, privacy: .public)")
                if dismissAfterInsert {
                    dismiss()
                }
            }
            // A staged LEAVE or AGREE hasn't happened yet — the user can
            // still delete the bubble instead of sending it. Defer the
            // revision floor and the canonical snapshot to didStartSending
            // (the marker is the backstop for the extension dying in
            // between — see commitStagedSendIfNeeded) so local state never
            // records a departure or agreement no peer will ever see. Keyed
            // off the conversation parameter, not the ivar, so a nil
            // conversationKey can't silently skip the marker.
            if stagedInsert, state.messageType == .leave || state.messageType == .agree {
                ConversationMeetupStore.setPendingStagedSend(
                    state.messageType, key: deliveryKey)
                return true
            }
            // Any real (non-staged) delivery supersedes a previously staged
            // leave/agree the user abandoned. Without this, an orphaned
            // marker survived e.g. a rejoin at a TIED revision (staging
            // defers the floor bump, so the next mint reuses the number) and
            // a later tap of the old own bubble replayed the stale intent
            // past every guard (audit at b902d4d).
            ConversationMeetupStore.setPendingStagedSend(
                nil, key: deliveryKey)
            // Delivery succeeded — NOW the minted revision becomes the floor
            // for the decode guard (this device's own stale bubbles included).
            if let revision = state.revision {
                ConversationMeetupStore.noteRevision(
                    revision, sender: localParticipantID(), key: deliveryKey)
            }
            recordCanonicalSnapshot(for: state, key: deliveryKey)
            recordPendingInviteIfNeeded(for: state)
            return true
        } catch {
            logger.error("Failed to deliver outgoing Tween bubble: \(String(describing: error), privacy: .public)")
            sendStatusMessage = "Couldn't send the Tween message. Try again."
            return false
        }
    }

    private func recordCanonicalSnapshot(for state: TweenState, key conversationKey: String) {
        switch state.messageType {
        case .invite:
            ConversationMeetupStore.saveParticipants(state.participants, key: conversationKey)
        case .propose, .counter:
            ConversationMeetupStore.saveProposed(state, key: conversationKey)
            ConversationMeetupStore.clearDraft(key: conversationKey)
        case .agree:
            if state.isFullyAgreed {
                ConversationMeetupStore.saveAgreed(state, key: conversationKey)
            } else {
                ConversationMeetupStore.saveProposed(state, key: conversationKey)
            }
        case .leave:
            // Keep the remaining roster — the meetup stays live for everyone
            // else, and a later rejoin must broadcast the full group, not
            // [me]. This device renders as "out" via membership + tombstone.
            ConversationMeetupStore.saveParticipants(state.participants, key: conversationKey)
            if state.participants.isEmpty {
                ConversationMeetupStore.clearProposalState(key: conversationKey)
            }
        }
    }

    private func recordPendingInviteIfNeeded(for state: TweenState) {
        switch state.messageType {
        case .invite, .propose, .counter:
            let pendingCount = max(totalConversationParticipants - state.participants.count, 0)
            guard pendingCount > 0 else { return }
            PingLog.logGenericInvite(count: pendingCount)
        case .agree, .leave:
            return
        }
    }

    /// Requests a single fix and polls the provider for up to ~5s for a result.
    ///
    /// First run only: while the When-In-Use permission alert is on screen
    /// (authorization still .notDetermined), the 5s budget isn't burning —
    /// wait out the alert (up to ~30s) BEFORE starting the fix window, so the
    /// very first "I'm in" doesn't fail just because the user took a moment
    /// to read the prompt. Already-authorized (or denied) users skip this
    /// instantly and get exactly the original behavior.
    private func acquireLocation() async -> CLLocationCoordinate2D? {
        locationProvider.requestOnce()
        var alertTicks = 0
        while locationProvider.authorizationStatus == .notDetermined, alertTicks < 300 {
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(100))
            alertTicks += 1
        }
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

    private func openAppleMaps(for state: TweenState) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: state.coordinate))
        item.name = state.text
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }

    private func openGoogleMaps(for state: TweenState) {
        // iMessage extensions may not open URLs to other apps —
        // extensionContext.open launches the CONTAINING app regardless of the
        // URL (which is why handing it a comgooglemaps:// link opened Tween —
        // device feedback). So open the containing app ON PURPOSE with a
        // handoff deep link; the host decodes it and immediately relaunches
        // into Google Maps (app scheme when installed, web/universal link
        // otherwise). One extra hop, but it always lands in Google Maps.
        guard let handoff = MapLinks.googleMapsHandoffURL(
            name: state.text, coordinate: state.coordinate) else { return }
        extensionContext?.open(handoff) { [weak self] didOpen in
            guard !didOpen else { return }
            DispatchQueue.main.async {
                self?.sendStatusMessage = "Couldn't open Google Maps. Try from the Tween app."
                self?.presentUI(for: self?.presentationStyle ?? .expanded)
            }
        }
    }
}
