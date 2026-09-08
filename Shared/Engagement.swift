import Foundation

/// A moment worth counting: the user just did the thing Tween is for.
enum EngagementEvent: String, Codable, CaseIterable {
    case imIn
    case sendToChat
    case agreed
}

/// The nudges the engine can ask for. Presenting them is the host's job;
/// the engine only decides WHEN.
enum Nudge: Equatable {
    /// The Tween Pro pop-up (`ProNudgeSheet`).
    case pro
    /// Apple's own review prompt (`requestReview`) — never a custom dialog.
    case review
}

/// Everything the nudge engine remembers, as ONE atomic App Group blob
/// (constraint #6: counts and dates, no PII). The extension may count too;
/// only the host ever shows anything.
struct EngagementState: Codable, Equatable {
    var imInCount = 0
    var sendCount = 0
    var agreedCount = 0
    /// The positive-event count at which the Pro pop-up is next due — nil
    /// until the first roll (product decision 2026-09-08: "a random number
    /// thing from 1–10 on when to do a pop up").
    var proNextAt: Int?
    var proLastShownAt: Date?
    var proDismissals = 0
    var reviewNextAt: Int?
    var reviewLastAskedAt: Date?

    /// "I'm in" taps + spots sent + agreements — the moments that mean the
    /// app just worked for this person.
    var positiveEvents: Int { imInCount + sendCount + agreedCount }

    mutating func count(_ event: EngagementEvent) {
        switch event {
        case .imIn:       imInCount += 1
        case .sendToChat: sendCount += 1
        case .agreed:     agreedCount += 1
        }
    }
}

enum EngagementStore {
    static let key = "tween.engagement"

    // Cached suite — see LocationCache.sharedDefaults.
    private static var defaults: UserDefaults? { LocationCache.sharedDefaults }

    static func load() -> EngagementState {
        guard let data = defaults?.data(forKey: key),
              let state = try? JSONDecoder().decode(EngagementState.self, from: data)
        else { return EngagementState() }
        return state
    }

    static func save(_ state: EngagementState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults?.set(data, forKey: key)
    }

    static func clear() {
        defaults?.removeObject(forKey: key)
    }
}

/// When to show what. Pure — time and randomness are injected — so the
/// thresholds, cooldowns and back-off are unit-tested, not felt out on a
/// phone.
///
/// Both nudges key off the same positive-event count. The Pro pop-up is due
/// at a random count in 1…10, then re-rolls 5–10 events further out each
/// time it shows; it never shows while Pro is unlocked, keeps a 7-day
/// cooldown, and backs off to 30 days once it has been dismissed twice. The
/// review ask is due at a random count in 3…10, re-rolls 10–20 further out,
/// keeps a 60-day cooldown, and yields to the Pro pop-up on the same event
/// (never two asks in one moment). Apple throttles the review prompt on top
/// of this — three per year — so calling it is a request, not a guarantee.
enum NudgePolicy {
    static let proFirstWindow = 1...10
    static let proRepeatWindow = 5...10
    static let reviewFirstWindow = 3...10
    static let reviewRepeatWindow = 10...20
    static let proCooldown: TimeInterval = 7 * 86_400
    static let proBackoffCooldown: TimeInterval = 30 * 86_400
    static let proBackoffAfterDismissals = 2
    static let reviewCooldown: TimeInterval = 60 * 86_400

    /// Counts `event`, arms any threshold that hasn't been rolled yet, and
    /// decides. When it returns a nudge it has ALREADY stamped it shown and
    /// rolled the next threshold — persisting `state` is the caller's job,
    /// and the caller must then actually present it.
    static func record<G: RandomNumberGenerator>(
        _ event: EngagementEvent,
        in state: inout EngagementState,
        proUnlocked: Bool,
        now: Date,
        using rng: inout G
    ) -> Nudge? {
        state.count(event)
        if state.proNextAt == nil {
            state.proNextAt = Int.random(in: proFirstWindow, using: &rng)
        }
        if state.reviewNextAt == nil {
            state.reviewNextAt = Int.random(in: reviewFirstWindow, using: &rng)
        }
        let n = state.positiveEvents
        if !proUnlocked, let due = state.proNextAt, n >= due, proCooldownElapsed(state, now: now) {
            state.proLastShownAt = now
            state.proNextAt = n + Int.random(in: proRepeatWindow, using: &rng)
            return .pro
        }
        if let due = state.reviewNextAt, n >= due, reviewCooldownElapsed(state, now: now) {
            state.reviewLastAskedAt = now
            state.reviewNextAt = n + Int.random(in: reviewRepeatWindow, using: &rng)
            return .review
        }
        return nil
    }

    /// Production entry point: system randomness, wall-clock time.
    static func record(_ event: EngagementEvent,
                       in state: inout EngagementState,
                       proUnlocked: Bool,
                       now: Date = Date()) -> Nudge? {
        var rng = SystemRandomNumberGenerator()
        return record(event, in: &state, proUnlocked: proUnlocked, now: now, using: &rng)
    }

    /// "Not now" on the Pro pop-up. Two of these move it to the long cooldown.
    static func noteProDismissed(in state: inout EngagementState) {
        state.proDismissals += 1
    }

    private static func proCooldownElapsed(_ state: EngagementState, now: Date) -> Bool {
        guard let last = state.proLastShownAt else { return true }
        let cooldown = state.proDismissals >= proBackoffAfterDismissals
            ? proBackoffCooldown : proCooldown
        return now.timeIntervalSince(last) >= cooldown
    }

    private static func reviewCooldownElapsed(_ state: EngagementState, now: Date) -> Bool {
        guard let last = state.reviewLastAskedAt else { return true }
        return now.timeIntervalSince(last) >= reviewCooldown
    }
}
