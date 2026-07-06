import Foundation

struct MeetupSnapshot: Codable, Equatable {
    let conversationKey: String
    var participants: [Participant]
    private var proposedStateURL: URL?
    private var agreedStateURL: URL?
    var pendingDraft: OutgoingDraft?
    var updatedAt: Date

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
    }

    static func clear(key: String) {
        defaults?.removeObject(forKey: storageKey(for: key))
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

    private static func storageKey(for key: String) -> String {
        storagePrefix + key
    }
}
