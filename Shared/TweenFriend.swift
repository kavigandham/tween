import Foundation

/// A person you can ping to start a meetup. Sourced either from the system
/// contact picker or added ad hoc; `contactIdentifier` ties a row back to a
/// `CNContact` when one exists, and `handle` is the phone/email we'd address an
/// SMS to.
struct TweenFriend: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var contactIdentifier: String?
    var handle: String?

    init(id: UUID = UUID(), name: String, contactIdentifier: String? = nil, handle: String? = nil) {
        self.id = id
        self.name = name
        self.contactIdentifier = contactIdentifier
        self.handle = handle
    }
}

/// Cross-process roster persistence backed by App Group `UserDefaults`.
///
/// The whole roster is encoded as one JSON blob under a single key, mirroring
/// `LocationCache`'s atomic-write discipline so the host app and extension never
/// observe a torn list. Names and handles are the only data stored here; the
/// suite is unencrypted.
enum FriendRoster {
    static let storageKey = "cachedFriends"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: LocationCache.appGroup)
    }

    static func load() -> [TweenFriend] {
        guard let data = defaults?.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([TweenFriend].self, from: data)) ?? []
    }

    static func save(_ friends: [TweenFriend]) {
        guard let data = try? JSONEncoder().encode(friends) else { return }
        defaults?.set(data, forKey: storageKey)
    }

    /// Adds or refreshes a friend. Contacts can be selected more than once from
    /// the picker, so match stable identifiers/handles before appending.
    static func add(_ friend: TweenFriend) {
        var friends = load()
        if let index = friends.firstIndex(where: { $0.representsSamePerson(as: friend) }) {
            friends[index] = friend
            save(friends)
            return
        }
        friends.append(friend)
        save(friends)
    }

    static func delete(id: UUID) {
        save(load().filter { $0.id != id })
    }

    /// Renames a friend in place, keeping its `id` (and thus its ping history).
    static func rename(id: UUID, to name: String) {
        var friends = load()
        guard let index = friends.firstIndex(where: { $0.id == id }) else { return }
        friends[index].name = name
        save(friends)
    }

    static func clear() {
        defaults?.removeObject(forKey: storageKey)
    }
}

private extension TweenFriend {
    func representsSamePerson(as other: TweenFriend) -> Bool {
        if let contactIdentifier,
           let otherIdentifier = other.contactIdentifier,
           contactIdentifier == otherIdentifier {
            return true
        }
        if let handle = normalizedHandle,
           let otherHandle = other.normalizedHandle,
           handle == otherHandle {
            return true
        }
        return id == other.id
    }

    var normalizedHandle: String? {
        handle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isWhitespace && $0 != "-" && $0 != "(" && $0 != ")" }
            .lowercased()
    }
}
