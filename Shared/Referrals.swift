import Foundation

/// Refer three friends, get three months of Tween Pro — verified the only
/// way a serverless app can (constraint 8: no server, no accounts).
///
/// A Tween bubble in iMessage can only be sent by someone who has the app
/// installed, so the bubbles ARE the proof of a download:
///
///  1. The first Tween bubble a brand-new user taps — before they have ever
///     sent one — marks its sender as the person who introduced them
///     (`referredBy`). No link, no code, nothing to type.
///  2. For the next 30 days every bubble that new user sends carries the
///     introducer's install id (`ref=` in the payload).
///  3. When the introducer's device decodes a bubble whose `ref` is its own
///     id, that sender counts as one referral — once, however many bubbles
///     they send. Three referrals grant 90 days of Pro; every further three
///     add another 90.
///
/// Everything lives in one atomic App Group blob of install ids and dates
/// (constraint 6: no names, no handles). The grant is honoured by
/// `ProEntitlement.syncUnlockedFlag`, so both processes gate on the same
/// cached flag they already use.
struct ReferralState: Codable, Equatable {
    /// Install id of whoever introduced me to Tween.
    var referredBy: String?
    var referredAt: Date?
    /// Once I have sent a bubble, later senders can no longer become my
    /// introducer — I was already here.
    var hasSentAny = false
    /// Install ids of the people I introduced who then sent a bubble.
    var referrals: [String] = []
    /// Pro via referrals runs until this date.
    var grantedUntil: Date?
    var grantsAwarded = 0
    /// The grant the host last celebrated, so a grant that landed in the
    /// extension is announced exactly once when the app next refreshes.
    var announcedGrantUntil: Date?
}

enum ReferralStore {
    static let key = "tween.referrals"

    // Cached suite — see LocationCache.sharedDefaults.
    private static var defaults: UserDefaults? { LocationCache.sharedDefaults }

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

/// The rules, pure and unit-tested.
enum ReferralPolicy {
    static let required = 3
    static let grantDuration: TimeInterval = 90 * 86_400
    /// How long a new user's bubbles carry their introducer's id.
    static let attributionWindow: TimeInterval = 30 * 86_400

    enum Event: Equatable {
        /// I just learned who introduced me.
        case attributed(to: String)
        /// Someone I introduced sent their first bubble; `count` is my total.
        case referral(count: Int)
        /// A grant landed (or was extended) — Pro until `until`.
        case granted(until: Date)
    }

    /// An inbound bubble from `senderID` that carried `referredBy`.
    static func noteInbound(senderID: String?, referredBy: String?, myID: String,
                            state: inout ReferralState, now: Date = Date()) -> [Event] {
        var events: [Event] = []
        guard let senderID, !senderID.isEmpty, senderID != myID else { return events }
        if state.referredBy == nil, !state.hasSentAny {
            state.referredBy = senderID
            state.referredAt = now
            events.append(.attributed(to: senderID))
        }
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
        guard let id = state.referredBy, let at = state.referredAt,
              now.timeIntervalSince(at) <= attributionWindow else { return nil }
        return id
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

/// Store-backed conveniences used by both processes' send and decode funnels.
enum Referrals {
    /// Decode-side hook. Persists, recomputes the Pro gate on a grant, and
    /// posts so the other process sees the change.
    @discardableResult
    static func noteInbound(_ state: TweenState, myID: String, now: Date = Date()) -> [ReferralPolicy.Event] {
        var stored = ReferralStore.load()
        let events = ReferralPolicy.noteInbound(senderID: state.senderID, referredBy: state.referredBy,
                                                myID: myID, state: &stored, now: now)
        guard !events.isEmpty else { return events }
        ReferralStore.save(stored)
        if events.contains(where: { if case .granted = $0 { return true } else { return false } }) {
            ProEntitlement.syncUnlockedFlag()
        }
        MeetupSync.post()
        return events
    }

    /// Send-side hook: I'm a sender now, so nobody can become my introducer.
    static func noteOutbound() {
        var stored = ReferralStore.load()
        guard !stored.hasSentAny else { return }
        stored.hasSentAny = true
        ReferralStore.save(stored)
    }

    /// What to stamp into an outgoing payload.
    static var outboundReferrer: String? {
        ReferralPolicy.outboundReferrer(ReferralStore.load())
    }
}
