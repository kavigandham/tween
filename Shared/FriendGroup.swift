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

    init(id: UUID = UUID(), name: String, memberIDs: [UUID]) {
        self.id = id
        self.name = name
        self.memberIDs = memberIDs
    }

    /// The group's members resolved against the roster, dropping any friend
    /// that was deleted since the group was made.
    func members(in roster: [TweenFriend]) -> [TweenFriend] {
        memberIDs.compactMap { id in roster.first(where: { $0.id == id }) }
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
