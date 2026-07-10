import Foundation

/// Cross-process change signal for App Group meetup state.
///
/// `UserDefaults.didChangeNotification` does NOT fire across processes, so
/// without this the host app only noticed extension writes on its poll tick.
/// Every canonical writer (`ConversationMeetupStore`, `LocationCache`,
/// `OutgoingDraftStore`) posts a Darwin notification after writing; the host
/// observes and refreshes immediately, keeping its (slower) poll only as a
/// fallback. Darwin notifications carry no payload — pure "something changed".
enum MeetupSync {
    static let notificationName = "com.kavigandham.tween.stateChanged"

    static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil, nil, true)
    }

    /// Registers `handler` (delivered on the main queue) for cross-process
    /// change posts. Observation lasts as long as the returned token lives.
    static func observe(_ handler: @escaping () -> Void) -> MeetupSyncToken {
        MeetupSyncToken(handler: handler)
    }
}

/// Lifetime handle for a `MeetupSync.observe` registration.
final class MeetupSyncToken {
    fileprivate let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let token = Unmanaged<MeetupSyncToken>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { token.handler() }
        }, MeetupSync.notificationName as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(MeetupSync.notificationName as CFString),
            nil)
    }
}

/// TTL-exempt per-conversation sync state: the payload-revision floor (with
/// the sender who set it, for tie-breaking) and the leave tombstones.
///
/// Split out of `MeetupSnapshot` into its OWN storage key (2026-07 audit:
/// W6/W2/TTL findings) so that (a) the 24 h snapshot TTL can clear a dead
/// meetup WITHOUT wiping tombstones — wiping them let any old bubble
/// resurrect a leaver a day later — and (b) the big snapshot mutators in
/// either process can no longer last-writer-wins these hot fields away.
struct ConversationSyncState: Codable, Equatable {
    /// Highest payload revision seen (or delivered) for this conversation.
    var lastRevision: Int? = nil
    /// Identity key of the sender whose bubble set `lastRevision` — the W2
    /// tie-breaker. A same-sender re-tap at the floor revision is accepted;
    /// a DIFFERENT sender at the same revision is a concurrent mint and is
    /// rejected (last-tap-wins made the outcome order-dependent).
    var lastRevisionSender: String? = nil
    /// True after this user said "I'm out" here. See `setLocalUserLeft`.
    var localUserLeft: Bool? = nil
    /// Identity keys of OTHER participants whose `.leave` this device has
    /// processed (or learned via gossip). See `RosterMerge`.
    var departedKeys: [String]? = nil

    var isEmpty: Bool {
        lastRevision == nil && lastRevisionSender == nil
            && localUserLeft == nil && (departedKeys ?? []).isEmpty
    }
}

struct MeetupSnapshot: Codable, Equatable {
    let conversationKey: String
    var participants: [Participant]
    private var proposedStateURL: URL?
    private var agreedStateURL: URL?
    var updatedAt: Date
    // The four fields below are LEGACY-DECODE ONLY. They now live under their
    // own storage keys (`ConversationSyncState`, the draft key) so the 24 h
    // TTL and the whole-blob mutators can't destroy them. They stay declared
    // so old blobs decode; `save` nils them after `loadSync`/`loadDraft`
    // migrate their values out. Do not read them outside the migration path.
    var pendingDraft: OutgoingDraft?
    var lastRevision: Int? = nil
    var localUserLeft: Bool? = nil
    var departedKeys: [String]? = nil

    var proposedState: TweenState? {
        get { proposedStateURL.flatMap(TweenState.init(url:)) }
        set { proposedStateURL = newValue?.encodedURL() }
    }

    var agreedState: TweenState? {
        get { agreedStateURL.flatMap(TweenState.init(url:)) }
        set { agreedStateURL = newValue?.encodedURL() }
    }

    init(conversationKey: String,
         participants: [Participant] = [],
         proposedState: TweenState? = nil,
         agreedState: TweenState? = nil,
         pendingDraft: OutgoingDraft? = nil,
         updatedAt: Date = Date()) {
        self.conversationKey = conversationKey
        self.participants = participants
        self.proposedStateURL = proposedState?.encodedURL()
        self.agreedStateURL = agreedState?.encodedURL()
        self.pendingDraft = pendingDraft
        self.updatedAt = updatedAt
    }
}

enum ConversationMeetupStore {
    private static let storagePrefix = "conversationMeetup."
    // Conversation keys are base64url (no dots), so these prefixed keyspaces
    // can never collide with a real snapshot key.
    private static let syncPrefix = "conversationMeetup.sync."
    private static let draftPrefix = "conversationMeetup.draft."
    private static let lastActiveKey = "conversationMeetup.lastActive"

    /// How long a per-conversation snapshot stays trustworthy. Meetups are
    /// same-day plans; anything older renders as stale state, not a live
    /// negotiation. Shared by the extension (activation restore) and the host
    /// app (launch reset + poll reads) so both surfaces age out together.
    static let snapshotTTL: TimeInterval = 24 * 60 * 60

    /// True when the most recently active conversation has meetup state fresh
    /// within `ttl` — a roster, a proposal/agreement, or a pending draft. The
    /// host app checks this before wiping caches on cold launch.
    static func hasLiveMeetup(within ttl: TimeInterval) -> Bool {
        guard let key = lastActiveConversationKey else { return false }
        if let snapshot = load(key: key),
           Date().timeIntervalSince(snapshot.updatedAt) <= ttl,
           !snapshot.participants.isEmpty
               || snapshot.proposedState != nil
               || snapshot.agreedState != nil {
            return true
        }
        return loadDraft(key: key) != nil
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: LocationCache.appGroup)
    }

    static func conversationKey(localID: String, remotes: [String]) -> String {
        let raw = ([localID] + remotes).sorted().joined(separator: "|")
        let encoded = Data(raw.utf8).base64EncodedString()
        return encoded
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    static var lastActiveConversationKey: String? {
        get { defaults?.string(forKey: lastActiveKey) }
        set {
            if let newValue {
                defaults?.set(newValue, forKey: lastActiveKey)
            } else {
                defaults?.removeObject(forKey: lastActiveKey)
            }
        }
    }

    static func load(key: String) -> MeetupSnapshot? {
        guard let data = defaults?.data(forKey: storageKey(for: key)) else { return nil }
        return try? JSONDecoder().decode(MeetupSnapshot.self, from: data)
    }

    static func save(_ snapshot: MeetupSnapshot, key: String? = nil) {
        let storage = key ?? snapshot.conversationKey
        // Read the current snapshot ONCE, up front. The migration helpers
        // below only touch the sync/draft keys — never the snapshot key — so
        // this value stays valid throughout, and reusing it (instead of a
        // second `load()` after migration) closes the window where a
        // concurrent write between two loads could be compared against.
        let stored = load(key: storage)
        // Migrate the TTL-exempt fields (and any inline draft) out BEFORE the
        // legacy inline copies are stripped below — else the only copy dies.
        _ = loadSync(key: storage)
        migrateDraftIfNeeded(key: storage)
        // A caller may still hand us a snapshot with inline values — fold
        // those into the split keys rather than dropping them. Only values
        // that DIFFER from the stored blob count: identical ones are the
        // stale legacy copies (already migrated above), and re-applying
        // them would resurrect exactly the state the caller moved past.
        if let inlineDraft = snapshot.pendingDraft, inlineDraft != stored?.pendingDraft {
            saveDraft(inlineDraft, key: storage)
        }
        if let inlineRevision = snapshot.lastRevision, inlineRevision != stored?.lastRevision {
            noteRevision(inlineRevision, key: storage)
        }
        if snapshot.localUserLeft == true, stored?.localUserLeft != true {
            setLocalUserLeft(true, key: storage)
        }
        if let inlineDeparted = snapshot.departedKeys, inlineDeparted != stored?.departedKeys {
            noteDeparted(inlineDeparted, key: storage)
        }
        var updated = snapshot
        updated.updatedAt = Date()
        // Legacy inline fields live under their own keys now; nil them so a
        // stale inline value can never shadow the canonical copy.
        updated.lastRevision = nil
        updated.localUserLeft = nil
        updated.departedKeys = nil
        updated.pendingDraft = nil
        guard let data = try? JSONEncoder().encode(updated) else { return }
        defaults?.set(data, forKey: storageKey(for: storage))
        MeetupSync.post()
    }

    /// TTL/expiry clear: removes the meetup snapshot and any pending draft
    /// but — BY DESIGN — keeps the sync state (revision floor + tombstones).
    /// Wiping tombstones with the TTL meant a leaver resurrected a day later
    /// from any old bubble; the revision floor only ever blocks stale
    /// bubbles (composers mint floor+1 from this same store), so keeping it
    /// indefinitely costs nothing.
    static func clear(key: String) {
        // Rescue never-migrated legacy sync fields before the blob vanishes.
        _ = loadSync(key: key)
        defaults?.removeObject(forKey: storageKey(for: key))
        defaults?.removeObject(forKey: draftKey(for: key))
        MeetupSync.post()
    }

    /// The full wipe, sync state included — for tests and hard resets only.
    static func clearIncludingSync(key: String) {
        defaults?.removeObject(forKey: syncKey(for: key))
        clear(key: key)
    }

    static func clearTransientState(key: String) {
        clearDraft(key: key)
    }

    static func clearProposalState(key: String) {
        var snapshot = load(key: key) ?? MeetupSnapshot(conversationKey: key)
        snapshot.proposedState = nil
        snapshot.agreedState = nil
        save(snapshot, key: key)
        clearDraft(key: key)
    }

    static func saveParticipants(_ participants: [Participant], key: String) {
        var snapshot = load(key: key) ?? MeetupSnapshot(conversationKey: key)
        snapshot.participants = participants
        save(snapshot, key: key)
    }

    static func saveProposed(_ state: TweenState, key: String) {
        var snapshot = load(key: key) ?? MeetupSnapshot(conversationKey: key)
        snapshot.participants = state.participants
        snapshot.proposedState = state
        if state.messageType == .counter {
            snapshot.agreedState = nil
        }
        save(snapshot, key: key)
    }

    static func saveAgreed(_ state: TweenState, key: String) {
        var snapshot = load(key: key) ?? MeetupSnapshot(conversationKey: key)
        snapshot.participants = state.participants
        snapshot.proposedState = state
        if state.isFullyAgreed {
            snapshot.agreedState = state
        }
        save(snapshot, key: key)
    }

    // MARK: - Pending draft (own key; cleared with the TTL, never with sync)

    static func loadDraft(key: String) -> OutgoingDraft? {
        migrateDraftIfNeeded(key: key)
        guard let data = defaults?.data(forKey: draftKey(for: key)) else { return nil }
        return try? JSONDecoder().decode(OutgoingDraft.self, from: data)
    }

    static func saveDraft(_ draft: OutgoingDraft, key: String) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults?.set(data, forKey: draftKey(for: key))
        MeetupSync.post()
    }

    static func clearDraft(key: String) {
        defaults?.removeObject(forKey: draftKey(for: key))
        // A never-migrated legacy inline draft must not resurrect on the
        // next load — strip it from the old blob too (save nils it).
        if let legacy = load(key: key), legacy.pendingDraft != nil {
            save(legacy, key: key)
        }
        MeetupSync.post()
    }

    private static func migrateDraftIfNeeded(key: String) {
        guard defaults?.data(forKey: draftKey(for: key)) == nil,
              let legacyDraft = load(key: key)?.pendingDraft,
              let data = try? JSONEncoder().encode(legacyDraft)
        else { return }
        defaults?.set(data, forKey: draftKey(for: key))
    }

    // MARK: - Sync state (TTL-exempt: revision floor + tombstones)

    /// Loads the sync blob, lazily migrating the legacy inline snapshot
    /// fields the first time a conversation is touched by this build.
    /// Presence of the sync key is the migration marker.
    private static func loadSync(key: String) -> ConversationSyncState {
        if let data = defaults?.data(forKey: syncKey(for: key)),
           let state = try? JSONDecoder().decode(ConversationSyncState.self, from: data) {
            return state
        }
        guard let legacy = load(key: key) else { return ConversationSyncState() }
        let migrated = ConversationSyncState(
            lastRevision: legacy.lastRevision,
            localUserLeft: legacy.localUserLeft,
            departedKeys: legacy.departedKeys)
        if !migrated.isEmpty { saveSync(migrated, key: key) }
        return migrated
    }

    private static func saveSync(_ state: ConversationSyncState, key: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults?.set(data, forKey: syncKey(for: key))
        MeetupSync.post()
    }

    // MARK: - Leave tombstone

    static func localUserLeft(key: String) -> Bool {
        loadSync(key: key).localUserLeft ?? false
    }

    static func setLocalUserLeft(_ left: Bool, key: String) {
        var sync = loadSync(key: key)
        guard (sync.localUserLeft ?? false) != left else { return }
        sync.localUserLeft = left
        saveSync(sync, key: key)
    }

    // MARK: - Pending staged sends (extension bookkeeping)

    /// Marks a `.leave`/`.agree` bubble that was STAGED in the input field
    /// but not yet sent by the user. `deliverBubble` defers those commits to
    /// `didStartSending`; if the extension dies before the user taps send,
    /// this marker lets the next decode of the (by then sent) own bubble
    /// commit as a backstop. The user deleting the staged bubble instead
    /// leaves the marker set — harmless, because commits are additionally
    /// gated on the revision floor and cleared by any later real commit.
    /// Extension-private bookkeeping the host never renders, so no
    /// MeetupSync post.
    static func setPendingStagedSend(_ type: TweenState.MessageType?, key: String) {
        let storage = pendingStagedKey(for: key)
        if let type {
            defaults?.set(type.rawValue, forKey: storage)
        } else {
            defaults?.removeObject(forKey: storage)
        }
    }

    static func pendingStagedSend(key: String) -> TweenState.MessageType? {
        defaults?.string(forKey: pendingStagedKey(for: key))
            .flatMap(TweenState.MessageType.init(rawValue:))
    }

    private static func pendingStagedKey(for key: String) -> String {
        "conversationMeetup.pendingStaged.\(key)"
    }

    // MARK: - Departure tombstones (other participants)

    static func departedParticipants(key: String) -> Set<String> {
        Set(loadSync(key: key).departedKeys ?? [])
    }

    /// Records that the participants behind `keys` left this conversation.
    static func noteDeparted(_ keys: [String], key: String) {
        guard !keys.isEmpty else { return }
        var sync = loadSync(key: key)
        let updated = Set(sync.departedKeys ?? []).union(keys)
        guard updated != Set(sync.departedKeys ?? []) else { return }
        sync.departedKeys = updated.sorted()
        saveSync(sync, key: key)
    }

    /// Lifts departure tombstones — a participant's own rejoin message.
    static func clearDeparted(_ keys: [String], key: String) {
        guard !keys.isEmpty else { return }
        var sync = loadSync(key: key)
        guard var current = sync.departedKeys, !current.isEmpty else { return }
        current.removeAll(where: Set(keys).contains)
        guard Set(current) != Set(sync.departedKeys ?? []) else { return }
        sync.departedKeys = current
        saveSync(sync, key: key)
    }

    // MARK: - Payload revisions

    static func lastRevision(key: String) -> Int {
        loadSync(key: key).lastRevision ?? 0
    }

    static func lastRevisionSender(key: String) -> String? {
        loadSync(key: key).lastRevisionSender
    }

    /// Records the highest payload revision seen for this conversation, and
    /// who set it. Both directions go through here: decode notes inbound
    /// revisions, delivery notes the ones this device mints — so a bubble
    /// older than either can never re-adopt a stale roster.
    static func noteRevision(_ revision: Int, sender: String? = nil, key: String) {
        var sync = loadSync(key: key)
        let floor = sync.lastRevision ?? 0
        if revision > floor {
            sync.lastRevision = revision
            sync.lastRevisionSender = sender
            saveSync(sync, key: key)
        } else if revision == floor, sync.lastRevisionSender == nil, sender != nil {
            // Backfill the sender on a pre-migration floor so future ties
            // stop falling into the legacy accept-all row.
            sync.lastRevisionSender = sender
            saveSync(sync, key: key)
        }
    }

    /// W2 tie-break: whether an inbound payload should be adopted.
    ///
    ///   nil revision      → accept (legacy trust-the-tap, unchanged)
    ///   above the floor   → accept · below → reject (blocks stale bubbles
    ///                       AND leaver resurrection — a tombstone can only
    ///                       be acquired via a bubble minted after the leave,
    ///                       which sits above any pre-leave revision)
    ///   AT the floor      → accept for the sender who set it (re-taps of the
    ///                       same bubble keep working), for a floor that
    ///                       predates sender tracking, OR for an `.invite`.
    ///
    /// The `.invite` exception fixes the concurrent-join bug: when two people
    /// tap "I'm in" before either sees the other, both mint revision 1 from
    /// an empty floor, so each device would otherwise REJECT the other's
    /// invite as a same-revision cross-sender mint — the rosters never union,
    /// ranking never starts, and later agreement counting diverges. An invite
    /// only ADDS its sender to the roster (RosterMerge is additive) and
    /// carries no place, so admitting it at the tie is safe. The exception is
    /// deliberately scoped to `revision == floor` only: a `revision < floor`
    /// invite from a departed sender must still be rejected, because
    /// RosterMerge treats an invite as a rejoin and would lift that sender's
    /// tombstone — so the below-floor reject is what actually blocks
    /// resurrection here, and must stay strict. `.propose`/`.counter`/
    /// `.agree`/`.leave` keep the strict tie-break so a concurrent place edit
    /// can't be laundered by tap order.
    static func shouldAcceptInbound(revision: Int?, senderID: String?,
                                    messageType: TweenState.MessageType = .propose,
                                    key: String) -> Bool {
        guard let revision else { return true }
        let sync = loadSync(key: key)
        let floor = sync.lastRevision ?? 0
        if revision > floor { return true }
        if revision < floor { return false }
        guard let floorSender = sync.lastRevisionSender else { return true }
        return senderID == floorSender || messageType == .invite
    }

    private static func storageKey(for key: String) -> String {
        storagePrefix + key
    }

    private static func syncKey(for key: String) -> String {
        syncPrefix + key
    }

    private static func draftKey(for key: String) -> String {
        draftPrefix + key
    }
}
