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
