import Foundation

/// Pro: a named set of friends ("the boys", "book club") that turns into an
/// instant fair-spot search — open the group and every member's home base
/// lands on the map as a local `manual:` participant, no live location
/// sharing required. Members reference `TweenFriend.id`; the group stores no
/// coordinates of its own.
struct FriendGroup: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var memberIDs: [UUID]
    /// When the group was first saved. Optional so every group saved before
    /// persistent-group metadata existed decodes unchanged (a synthesized
    /// decoder treats an optional as `decodeIfPresent`); `nil` simply means
    /// "before we started recording it", never a decode failure.
    var createdAt: Date?
    /// The last few meetups started from this group, newest first — what the
    /// detail screen's "Recent Tweens" list renders.
    ///
    /// Deliberately a tiny capped log ON the group rather than a second
    /// meetup store: a Tween IS its iMessage thread, and duplicating meetup
    /// history device-side would be a store with no owner and no TTL. Capped
    /// at `historyLimit`; names only, never coordinates (constraint 6).
    var history: [GroupTween]?

    init(id: UUID = UUID(), name: String, memberIDs: [UUID],
         createdAt: Date? = nil, history: [GroupTween]? = nil) {
        self.id = id
        self.name = name
        self.memberIDs = memberIDs
        self.createdAt = createdAt
        self.history = history
    }

    /// How many past Tweens a group remembers.
    static let historyLimit = 5

    /// A second spot picked within this window counts as the SAME outing
    /// rather than a new one, so changing your mind about the cafe doesn't
    /// fill the list with near-duplicate rows.
    static let sessionWindow: TimeInterval = 6 * 60 * 60

    var recentTweens: [GroupTween] { history ?? [] }

    var lastStartedAt: Date? { recentTweens.first?.startedAt }

    /// The group's members resolved against the roster, dropping any friend
    /// that was deleted since the group was made.
    func members(in roster: [TweenFriend]) -> [TweenFriend] {
        memberIDs.compactMap { id in roster.first(where: { $0.id == id }) }
    }

    /// Membership as an unordered identity — what "is this the same crew?"
    /// actually means. Order and duplicates are presentation details.
    var membershipKey: Set<UUID> { Set(memberIDs) }

    /// True when this group is made of exactly these people. A SUPERSET is
    /// not a match: A,B,C and A,B,C,D are different crews (spec §17).
    func hasSameMembers(as ids: [UUID]) -> Bool { membershipKey == Set(ids) }
}

/// One meetup started from a group: when, and where it landed if a place was
/// ever picked. Names and dates only.
struct GroupTween: Codable, Equatable, Identifiable {
    let id: UUID
    /// The place the group settled on, once one is picked. Nil while the
    /// outing is still "we opened the group and started looking".
    var spotName: String?
    var startedAt: Date

    init(id: UUID = UUID(), spotName: String? = nil, startedAt: Date = Date()) {
        self.id = id
        self.spotName = spotName
        self.startedAt = startedAt
    }

    /// "Cook Out" / "Started a Tween" — never blank.
    var title: String {
        let trimmed = spotName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed! : "Started a Tween"
    }
}

/// Names a group after the people in it, so creating one is a single tap and
/// never a blank text field (spec §15).
///
/// A free function on a caseless enum, in `Shared` and pure, because this is
/// exactly the kind of string logic that rots when it lives in a view: the
/// save-as-group flow shipped three defects that one test would have caught
/// (see `MeetupGroupBuilder`).
enum GroupNaming {
    /// How many names are spelled out before the rest become "+ N".
    static let spelledOut = 2

    /// "Hassan & Shiraaz", "Hassan, Shiraaz & Khanna", "Hassan, Shiraaz + 3".
    ///
    /// Names are laundered through `UserName.peerDisplayName` first, so an
    /// unnamed participant can never write a literal "You" into a group name,
    /// and reduced to first names so the title stays glanceable.
    static func suggested(from names: [String]) -> String {
        let firsts = names
            .map { firstName($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        switch firsts.count {
        case 0:  return "New Group"
        case 1:  return firsts[0]
        case 2:  return "\(firsts[0]) & \(firsts[1])"
        case 3:  return "\(firsts[0]), \(firsts[1]) & \(firsts[2])"
        default:
            let shown = firsts.prefix(spelledOut).joined(separator: ", ")
            return "\(shown) + \(firsts.count - spelledOut)"
        }
    }

    /// The first whitespace-separated token, with a possessive stripped so a
    /// manual point called "Kavi's place" reads as "Kavi" rather than "Kavi's".
    ///
    /// The single implementation — `OnboardingView.firstName` forwards here.
    /// Two copies of a name-laundering rule is precisely how a fallback name
    /// survives at one encoder and not its siblings (name-sanitization
    /// lesson).
    static func firstName(_ raw: String) -> String {
        let sanitised = UserName.peerDisplayName(raw)
        guard let token = sanitised.split(separator: " ").first else { return sanitised }
        var first = String(token)
        for suffix in ["'s", "\u{2019}s"] where first.lowercased().hasSuffix(suffix) {
            first = String(first.dropLast(suffix.count))
        }
        return first.isEmpty ? sanitised : first
    }
}

/// Cross-process group persistence — one atomic JSON blob under a single App
/// Group key, the same torn-read discipline as `FriendRoster`/`LocationCache`.
enum GroupStore {
    static let storageKey = "tween.groups"

    private static var defaults: UserDefaults? { LocationCache.sharedDefaults }

    static func load() -> [FriendGroup] {
        guard let data = defaults?.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([FriendGroup].self, from: data)) ?? []
    }

    static func save(_ groups: [FriendGroup]) {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        defaults?.set(data, forKey: storageKey)
    }

    /// Adds a new group or replaces the one sharing its id.
    static func upsert(_ group: FriendGroup) {
        var groups = load()
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
        save(groups)
    }

    static func delete(id: UUID) {
        save(load().filter { $0.id != id })
    }

    static func clear() {
        defaults?.removeObject(forKey: storageKey)
    }

    static func group(id: UUID) -> FriendGroup? {
        load().first { $0.id == id }
    }

    /// The existing group made of exactly these people, if there is one.
    ///
    /// The duplicate-group guard (spec §17): "save this crew" should reopen
    /// the crew you already saved rather than stack a second identical row.
    /// Strict set equality — A,B,C and A,B,C,D are different crews, and
    /// treating a superset as a match would quietly merge two real groups.
    static func group(matching memberIDs: [UUID]) -> FriendGroup? {
        let key = Set(memberIDs)
        guard !key.isEmpty else { return nil }
        return load().first { $0.membershipKey == key }
    }

    /// Renames in place, keeping id, membership and history. A blank name is
    /// refused rather than written — a group with no name is unreachable in
    /// a list that renders by name.
    static func rename(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var groups = load()
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = trimmed
        save(groups)
    }

    /// Drops one member. Used by the detail screen's "Remove from group";
    /// the friend themselves is untouched (they stay in the roster).
    static func removeMember(_ memberID: UUID, from id: UUID) {
        var groups = load()
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].memberIDs.removeAll { $0 == memberID }
        save(groups)
    }

    /// Records that a meetup was started from this group.
    ///
    /// Idempotent within `FriendGroup.sessionWindow`: reopening the same group
    /// twice in an evening is one outing, not two rows. Returns nothing — a
    /// history write must never be able to fail a user's tap.
    static func noteStarted(id: UUID, at date: Date = Date()) {
        var groups = load()
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        var history = groups[index].recentTweens
        if let latest = history.first,
           date.timeIntervalSince(latest.startedAt) < FriendGroup.sessionWindow {
            return
        }
        history.insert(GroupTween(startedAt: date), at: 0)
        groups[index].history = Array(history.prefix(FriendGroup.historyLimit))
        save(groups)
    }

    /// Names the outing after the place that was picked. Updates the current
    /// session's row when there is one, so "we looked, then picked Cook Out"
    /// is a single entry rather than two.
    static func noteSpot(_ spotName: String, for id: UUID, at date: Date = Date()) {
        let trimmed = spotName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var groups = load()
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        var history = groups[index].recentTweens
        if var latest = history.first,
           date.timeIntervalSince(latest.startedAt) < FriendGroup.sessionWindow {
            latest.spotName = trimmed
            history[0] = latest
        } else {
            history.insert(GroupTween(spotName: trimmed, startedAt: date), at: 0)
        }
        groups[index].history = Array(history.prefix(FriendGroup.historyLimit))
        save(groups)
    }
}

/// Turns the people already in a meetup into a saveable group.
///
/// A pure function on purpose: the first version of this lived inside a SwiftUI
/// View extension where no test could reach it, and it shipped three defects
/// that a single test would have caught (audit 2026-08-04) —
///
///   1. it used the RAW participant name, while every display surface launders
///      names through `UserName.peerDisplayName`. An unnamed sender travels as
///      literally "You" (or ""), so the roster gained friends named "You";
///   2. it read the roster once, outside the loop, so two same-named people
///      both failed the "already a friend?" guard and both got added;
///   3. it then mapped every duplicate back to the FIRST match, so "save these
///      2 as a group" produced a 1-member group plus 2 orphan friends.
enum MeetupGroupBuilder {
    struct Result: Equatable {
        /// Friends that must be created before the group can reference them.
        var newFriends: [TweenFriend] = []
        /// Member ids for the group, deduped and order-preserving.
        var memberIDs: [UUID] = []
        /// Participants dropped because their name couldn't identify anyone.
        var skipped: Int = 0
    }

    /// Case- and diacritic-insensitive, matching how `FriendRoster` treats
    /// names elsewhere.
    static func sameName(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    static func build(participants: [Participant],
                      existing: [TweenFriend]) -> Result {
        var result = Result()
        // Grows as we go, so the second same-named participant sees the friend
        // the first one created instead of adding a duplicate.
        var pool = existing

        for participant in participants {
            let name = UserName.peerDisplayName(participant.name)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // `peerDisplayName` maps "" and "You" to the generic "Friend",
            // which identifies nobody: saving two of them puts two
            // indistinguishable rows in the roster, and the next lookup can't
            // tell them apart. Drop them and report the count instead.
            guard !name.isEmpty, name != UserName.peerDisplayName("") else {
                result.skipped += 1
                continue
            }

            if let match = pool.first(where: { sameName($0.name, name) }) {
                if !result.memberIDs.contains(match.id) {
                    result.memberIDs.append(match.id)
                }
                continue
            }

            let friend = TweenFriend(name: name)
            pool.append(friend)
            result.newFriends.append(friend)
            result.memberIDs.append(friend.id)
        }
        return result
    }
}

/// The undo record for friends created speculatively by "save this meetup as a
/// group": they must exist for the editor to show them, but must not survive
/// the user backing out.
///
/// A plain value type with no SwiftUI in it, because the last three defects in
/// this feature were all in view-layer state that no test could reach — a bare
/// `@State var [UUID]` that could be double-armed, cleared on one dismissal
/// route but not another, and read after its flow was gone. The pure mapping
/// beside it (`MeetupGroupBuilder`) has had no such trouble. Same treatment:
///
///     arm(_:)            once — a second call is refused, not overwritten
///     commit()           the group was saved; forget them, don't delete
///     takeForRollback()  hand back the ids AND disarm, so it cannot fire twice
struct PendingGroupFriends: Equatable {
    private(set) var ids: [UUID] = []

    var isArmed: Bool { !ids.isEmpty }

    /// Records friends to undo. Returns false when already armed — a second
    /// tap re-runs the builder against a roster that now contains the first
    /// tap's friends, so it yields nothing and would otherwise WIPE the undo
    /// record, stranding them permanently.
    @discardableResult
    mutating func arm(_ newIDs: [UUID]) -> Bool {
        guard !isArmed else { return false }
        ids = newIDs
        return true
    }

    /// The group was saved: these friends are keepers.
    mutating func commit() { ids = [] }

    /// Ids to delete, disarming in the same step so a later dismissal of an
    /// unrelated sheet can't delete them a second time.
    mutating func takeForRollback() -> [UUID] {
        defer { ids = [] }
        return ids
    }
}
