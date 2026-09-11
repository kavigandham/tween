import Foundation

/// Refer three friends, get three months of Tween Pro — verified the only
/// way a serverless app can (constraint 8: no server, no accounts).
///
/// A Tween bubble in iMessage can only be SENT by someone who has the app
/// installed. So the bubbles are the proof of a download:
///
///  1. **Invite.** You tap Invite and send a Tween invite bubble
///     (`ReferralMessage.invite`). A friend without Tween sees Messages' own
///     "get the app" treatment on it.
///  2. **Joined.** They install, tap your bubble, and Tween on THEIR phone
///     offers one tap: "Tell Hassan you're on Tween". That sends a
///     `ReferralMessage.joined` bubble back — something only an installed
///     copy of Tween can send.
///  3. **Counted.** You tap their bubble; your device counts them once. Any
///     ordinary Tween bubble they send in the next 30 days also carries your
///     install id (`ref=`) and counts the same way, in case they skip step 2.
///
/// Three distinct friends grant 90 days of Pro; every further three stack
/// another 90. Credit happens ONLY where iMessage itself vouches for the
/// sender (the Messages extension's decode of a bubble the local user did
/// not send) — never from a link opened in the host app.
///
/// Everything lives in one atomic App Group blob of install ids, counts and
/// dates (constraint 6: no names, no handles).
struct ReferralState: Codable, Equatable {
    /// When this install first ran the referral code. Only installs younger
    /// than `ReferralPolicy.newUserWindow` can be introduced by anyone.
    var firstSeenAt: Date?
    /// Installed before referrals existed (or already in use when they
    /// arrived): never counts as someone's new user.
    var existingUser = false

    /// Install id of whoever introduced me to Tween.
    var referredBy: String?
    var referredAt: Date?
    /// True when that came from an explicit invite bubble (vs. inferred from
    /// the first Tween bubble I happened to open). An invite outranks an
    /// inference; nothing outranks an invite.
    var referredViaInvite = false
    /// Once I have sent a bubble, an inferred introducer can no longer be
    /// replaced — my first bubble already named them.
    var hasSentAny = false
    /// Introducers I have already told "I'm on Tween", so the prompt goes away.
    var repliedTo: [String] = []

    /// Invite bubbles I have sent (a count — never who).
    var invitesSent = 0
    /// Install ids of the people I introduced who proved an install.
    var referrals: [String] = []
    /// Pro via referrals runs until this date.
    var grantedUntil: Date?
    var grantsAwarded = 0

    /// Referrals the host app has already celebrated, so ones counted in the
    /// extension are announced exactly once on the next refresh.
    var announcedReferralCount = 0
    var announcedGrantUntil: Date?
}

enum ReferralStore {
    static let key = "tween.referrals"

    // Cached suite — see LocationCache.sharedDefaults.
    private static var defaults: UserDefaults? { LocationCache.sharedDefaults }

    static var exists: Bool { defaults?.data(forKey: key) != nil }

    static func load() -> ReferralState {
        guard let data = defaults?.data(forKey: key),
              let state = try? JSONDecoder().decode(ReferralState.self, from: data)
        else { return ReferralState() }
        return state
    }

    static func save(_ state: ReferralState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults?.set(data, forKey: key)
    }

    static func clear() {
        defaults?.removeObject(forKey: key)
    }
}

/// The two referral bubbles. Not a `TweenState`: neither carries a place or a
/// coordinate (constraint 2 — coordinates + spot name only; these carry
/// neither, just install ids and a first name).
struct ReferralMessage: Equatable {
    enum Kind: String {
        /// "Hassan invited you to Tween."
        case invite
        /// "Kavi is on Tween" — the reply that proves the install.
        case joined
    }

    let kind: Kind
    /// The sender's install id.
    let senderID: String
    let senderName: String?
    /// For `.joined`: whose invite this answers.
    let inviterID: String?

    static let path = "/r"

    func encodedURL() -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "tween.app"
        components.path = Self.path
        var items = [URLQueryItem(name: "k", value: kind.rawValue),
                     URLQueryItem(name: "fromId", value: senderID)]
        if let senderName, !senderName.isEmpty {
            items.append(URLQueryItem(name: "from", value: String(senderName.prefix(40))))
        }
        if let inviterID {
            items.append(URLQueryItem(name: "ref", value: inviterID))
        }
        components.queryItems = items
        return components.url
    }

    init(kind: Kind, senderID: String, senderName: String?, inviterID: String? = nil) {
        self.kind = kind
        self.senderID = senderID
        self.senderName = senderName
        self.inviterID = inviterID
    }

    /// Refuses anything that isn't exactly one of ours: an install id must be
    /// a UUID, and a `.joined` must name the inviter it answers.
    init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "https" || c.scheme == "file",
              c.path == Self.path,
              let items = c.queryItems,
              let kind = items.first(where: { $0.name == "k" })?.value.flatMap(Kind.init),
              let sender = items.first(where: { $0.name == "fromId" })?.value,
              ReferralPolicy.isInstallID(sender)
        else { return nil }
        let inviter = items.first(where: { $0.name == "ref" })?.value
        if kind == .joined {
            guard let inviter, ReferralPolicy.isInstallID(inviter) else { return nil }
        }
        self.kind = kind
        self.senderID = sender
        self.senderName = items.first(where: { $0.name == "from" })?.value
            .map { String($0.prefix(40)) }
            .flatMap { $0.isEmpty ? nil : $0 }
        self.inviterID = kind == .joined ? inviter : nil
    }
}

/// The rules, pure and unit-tested.
enum ReferralPolicy {
    static let required = 3
    static let grantDuration: TimeInterval = 90 * 86_400
    /// How long a new user's bubbles carry their introducer's id.
    static let attributionWindow: TimeInterval = 30 * 86_400
    /// How long after install someone can still be introduced.
    static let newUserWindow: TimeInterval = 14 * 86_400

    enum Event: Equatable {
        /// I just learned who introduced me.
        case attributed(to: String)
        /// Someone I introduced proved an install; `count` is my total.
        case referral(count: Int)
        /// A grant landed (or was extended) — Pro until `until`.
        case granted(until: Date)
    }

    /// Install ids are UUIDs (`TweenIdentity.stableID`). Anything else — a
    /// name, a legacy per-conversation id, a crafted 4 000-character string —
    /// is refused before it can be stored or echoed into outgoing payloads.
    static func isInstallID(_ value: String?) -> Bool {
        guard let value, value.count == 36 else { return false }
        return UUID(uuidString: value) != nil
    }

    static func canBeIntroduced(_ state: ReferralState, now: Date) -> Bool {
        guard !state.existingUser else { return false }
        guard let first = state.firstSeenAt else { return true }
        return now.timeIntervalSince(first) <= newUserWindow
    }

    /// An inbound bubble from `senderID`. `viaInvite` marks an explicit
    /// invite bubble; `referredBy` is the `ref=` an ordinary bubble or a
    /// `.joined` reply carried.
    static func noteInbound(senderID: String?, referredBy: String?, myID: String,
                            viaInvite: Bool = false,
                            state: inout ReferralState, now: Date = Date()) -> [Event] {
        var events: [Event] = []
        guard let senderID, isInstallID(senderID), senderID != myID else { return events }

        // Who introduced ME.
        if canBeIntroduced(state, now: now) {
            let replaceable = state.referredBy == nil
                || (viaInvite && !state.referredViaInvite && !state.hasSentAny)
            if replaceable, state.referredBy != senderID {
                state.referredBy = senderID
                state.referredAt = now
                state.referredViaInvite = viaInvite
                events.append(.attributed(to: senderID))
            } else if viaInvite, state.referredBy == senderID, !state.referredViaInvite {
                state.referredViaInvite = true
            }
        }

        // Whom I introduced.
        if referredBy == myID, !state.referrals.contains(senderID) {
            state.referrals.append(senderID)
            events.append(.referral(count: state.referrals.count))
            if state.referrals.count % required == 0 {
                // Stack onto an active grant rather than restarting it.
                let base = max(now, state.grantedUntil ?? now)
                let until = base.addingTimeInterval(grantDuration)
                state.grantedUntil = until
                state.grantsAwarded += 1
                events.append(.granted(until: until))
            }
        }
        return events
    }

    /// The id an outgoing bubble should carry, while the window is open.
    static func outboundReferrer(_ state: ReferralState, now: Date = Date()) -> String? {
        guard let id = state.referredBy, isInstallID(id), let at = state.referredAt,
              now.timeIntervalSince(at) <= attributionWindow else { return nil }
        return id
    }

    /// Whether to show "Tell <inviter> you're on Tween": introduced by an
    /// invite and not yet answered.
    static func owesReply(_ state: ReferralState) -> String? {
        guard state.referredViaInvite, let inviter = state.referredBy,
              !state.repliedTo.contains(inviter) else { return nil }
        return inviter
    }

    static func grantActive(_ state: ReferralState, now: Date = Date()) -> Bool {
        state.grantedUntil.map { $0 > now } ?? false
    }

    /// Referrals toward the NEXT grant, 0…required. Shows `required` (a full
    /// bar) while a grant is active and no new cycle has started.
    static func progress(_ state: ReferralState, now: Date = Date()) -> Int {
        let remainder = state.referrals.count % required
        if remainder == 0, state.grantsAwarded > 0, grantActive(state, now: now) { return required }
        return remainder
    }
}

/// Store-backed conveniences used by both processes.
enum Referrals {
    /// First run of the referral code on this install. An install that was
    /// already in use (a name, the tour, a location, any engagement) is an
    /// existing user and can never be counted as someone's new one — without
    /// this, every upgraded 1.0.x user was "introduced" by the next friend
    /// bubble they tapped (audit 2026-09-11). Idempotent; cheap after the
    /// first call.
    static func bootstrapIfNeeded(now: Date = Date()) {
        guard !ReferralStore.exists else { return }
        let priorUse = UserProfile.displayName != nil
            || OnboardingFlags.hasSeenOnboarding
            || LocationCache.loadSelf() != nil
            || EngagementStore.load().positiveEvents > 0
            || !FriendRoster.load().isEmpty
        ReferralStore.save(ReferralState(firstSeenAt: now, existingUser: priorUse))
    }

    /// Decode-side hook for an ordinary Tween bubble. EXTENSION ONLY — that
    /// is where iMessage vouches the sender is someone else.
    @discardableResult
    static func noteInbound(_ state: TweenState, myID: String, now: Date = Date()) -> [ReferralPolicy.Event] {
        apply { stored in
            ReferralPolicy.noteInbound(senderID: state.senderID, referredBy: state.referredBy,
                                       myID: myID, state: &stored, now: now)
        }
    }

    /// Decode-side hook for an invite or joined bubble. EXTENSION ONLY.
    @discardableResult
    static func noteInbound(_ message: ReferralMessage, myID: String, now: Date = Date()) -> [ReferralPolicy.Event] {
        apply { stored in
            ReferralPolicy.noteInbound(senderID: message.senderID, referredBy: message.inviterID,
                                       myID: myID, viaInvite: message.kind == .invite,
                                       state: &stored, now: now)
        }
    }

    /// Call AFTER a Tween bubble actually went out.
    static func noteOutbound() {
        mutate { if !$0.hasSentAny { $0.hasSentAny = true } }
    }

    /// Call AFTER an invite bubble actually went out.
    static func noteInviteSent() {
        mutate { $0.invitesSent += 1; $0.hasSentAny = true }
        MeetupSync.post()
    }

    /// Call AFTER the "I'm on Tween" reply actually went out.
    static func noteReplied(to inviterID: String) {
        mutate {
            if !$0.repliedTo.contains(inviterID) { $0.repliedTo.append(inviterID) }
            $0.hasSentAny = true
        }
    }

    /// What to stamp into an outgoing payload.
    static var outboundReferrer: String? {
        ReferralPolicy.outboundReferrer(ReferralStore.load())
    }

    private static func mutate(_ change: (inout ReferralState) -> Void) {
        var stored = ReferralStore.load()
        let before = stored
        change(&stored)
        if stored != before { ReferralStore.save(stored) }
    }

    private static func apply(_ decide: (inout ReferralState) -> [ReferralPolicy.Event]) -> [ReferralPolicy.Event] {
        var stored = ReferralStore.load()
        let events = decide(&stored)
        guard !events.isEmpty else { return events }
        ReferralStore.save(stored)
        if events.contains(where: { if case .granted = $0 { return true } else { return false } }) {
            ProEntitlement.syncUnlockedFlag()   // posts MeetupSync on a change
        } else {
            MeetupSync.post()
        }
        return events
    }
}
