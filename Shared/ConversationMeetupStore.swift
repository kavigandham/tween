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

struct MeetupSnapshot: Codable, Equatable {
    let conversationKey: String
    var participants: [Participant]
    private var proposedStateURL: URL?
    private var agreedStateURL: URL?
    var pendingDraft: OutgoingDraft?
    var updatedAt: Date
    /// Highest payload revision seen (or emitted) for this conversation.
    /// Optional so snapshots written by older builds keep decoding.
    var lastRevision: Int? = nil
    /// True after this user said "I'm out" here. Peers who never tapped the
    /// leave bubble keep broadcasting this user in their canonical rosters;
    /// this tombstone stops those stale rosters from re-adopting the local
    /// user as "in". Cleared by an explicit "I'm in" / agree.
    var localUserLeft: Bool? = nil
    /// Identity keys (stable install IDs, or names for legacy payloads) of
    /// OTHER participants whose `.leave` this device has processed. Rosters
    /// broadcast by peers who never saw the leave keep listing them;
    /// `RosterMerge` filters against this set so a departure sticks until
    /// that person's own explicit rejoin. Device-local; never serialised
    /// into payload URLs. Optional so older snapshots keep decoding.
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
        guard let key = lastActiveConversationKey,
              let snapshot = load(key: key),
              Date().timeIntervalSince(snapshot.updatedAt) <= ttl
        else { return false }
        return !snapshot.participants.isEmpty
            || snapshot.proposedState != nil
            || snapshot.agreedState != nil
            || snapshot.pendingDraft != nil
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
        var updated = snapshot
        updated.updatedAt = Date()
        guard let data = try? JSONEncoder().encode(updated) else { return }
        defaults?.set(data, forKey: storageKey(for: key ?? snapshot.conversationKey))
        MeetupSync.post()
    }

    static func clear(key: String) {
        defaults?.removeObject(forKey: storageKey(for: key))
        MeetupSync.post()
    }

    static func clearTransientState(key: String) {
        var snapshot = load(key: key) ?? MeetupSnapshot(conversationKey: key)
        snapshot.pendingDraft = nil
        save(snapshot, key: key)
    }

    static func clearProposalState(key: String) {
        var snapshot = load(key: key) ?? MeetupSnapshot(conversationKey: key)
        snapshot.proposedState = nil
        snapshot.agreedState = nil
        snapshot.pendingDraft = nil
        save(snapshot, key: key)
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

    static func saveDraft(_ draft: OutgoingDraft, key: String) {
        var snapshot = load(key: key) ?? MeetupSnapshot(conversationKey: key)
        snapshot.pendingDraft = draft
        save(snapshot, key: key)
    }

    static func clearDraft(key: String) {
        var snapshot = load(key: key) ?? MeetupSnapshot(conversationKey: key)
        snapshot.pendingDraft = nil
        save(snapshot, key: key)
    }

    // MARK: - Leave tombstone

    static func localUserLeft(key: String) -> Bool {
        load(key: key)?.localUserLeft ?? false
    }

    static func setLocalUserLeft(_ left: Bool, key: String) {
        var snapshot = load(key: key) ?? MeetupSnapshot(conversationKey: key)
        guard (snapshot.localUserLeft ?? false) != left else { return }
        snapshot.localUserLeft = left
        save(snapshot, key: key)
    }

    // MARK: - Departure tombstones (other participants)

    static func departedParticipants(key: String) -> Set<String> {
        Set(load(key: key)?.departedKeys ?? [])
    }

    /// Records that the participants behind `keys` left this conversation.
    static func noteDeparted(_ keys: [String], key: String) {
        guard !keys.isEmpty else { return }
        var snapshot = load(key: key) ?? MeetupSnapshot(conversationKey: key)
        let updated = Set(snapshot.departedKeys ?? []).union(keys)
        guard updated != Set(snapshot.departedKeys ?? []) else { return }
        snapshot.departedKeys = updated.sorted()
        save(snapshot, key: key)
    }

    /// Lifts departure tombstones — a participant's own rejoin message.
    static func clearDeparted(_ keys: [String], key: String) {
        guard !keys.isEmpty, var current = load(key: key)?.departedKeys, !current.isEmpty else { return }
        current.removeAll(where: Set(keys).contains)
        var snapshot = load(key: key) ?? MeetupSnapshot(conversationKey: key)
        guard Set(current) != Set(snapshot.departedKeys ?? []) else { return }
        snapshot.departedKeys = current
        save(snapshot, key: key)
    }

    // MARK: - Payload revisions

    static func lastRevision(key: String) -> Int {
        load(key: key)?.lastRevision ?? 0
    }

    /// Records the highest payload revision seen for this conversation. Both
    /// directions go through here: decode notes inbound revisions, compose
    /// notes the ones this device mints — so a bubble older than either can
    /// never re-adopt a stale roster.
    static func noteRevision(_ revision: Int, key: String) {
        var snapshot = load(key: key) ?? MeetupSnapshot(conversationKey: key)
        guard revision > (snapshot.lastRevision ?? 0) else { return }
        snapshot.lastRevision = revision
        save(snapshot, key: key)
    }

    private static func storageKey(for key: String) -> String {
        storagePrefix + key
    }
}
