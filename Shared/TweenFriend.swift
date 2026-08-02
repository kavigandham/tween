import Foundation
import CoreLocation

/// A person you can ping to start a meetup. Sourced either from the system
/// contact picker or added ad hoc; `contactIdentifier` ties a row back to a
/// `CNContact` when one exists, and `handle` is the phone/email we'd address an
/// SMS to.
struct TweenFriend: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var contactIdentifier: String?
    var handle: String?
    /// Pro: this friend's declared "home base" — where they usually start
    /// from. LOCAL PLANNING DATA ONLY: it seeds group spot searches as
    /// `manual:` participants (the manual-location isolation applies — never
    /// merged into any outgoing payload) and is never broadcast. Optional
    /// fields so pre-home-base rosters decode unchanged.
    var homeBaseLatitude: Double?
    var homeBaseLongitude: Double?
    var homeBaseLabel: String?

    init(id: UUID = UUID(), name: String, contactIdentifier: String? = nil, handle: String? = nil,
         homeBaseLatitude: Double? = nil, homeBaseLongitude: Double? = nil, homeBaseLabel: String? = nil) {
        self.id = id
        self.name = name
        self.contactIdentifier = contactIdentifier
        self.handle = handle
        self.homeBaseLatitude = homeBaseLatitude
        self.homeBaseLongitude = homeBaseLongitude
        self.homeBaseLabel = homeBaseLabel
    }

    var homeBase: CLLocationCoordinate2D? {
        guard let homeBaseLatitude, let homeBaseLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: homeBaseLatitude, longitude: homeBaseLongitude)
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
    /// the picker, so match stable identifiers/handles before appending. A
    /// re-pick keeps the EXISTING row's id and home base — the id keys the
    /// ping history and the home base is a Pro declaration; both were lost
    /// when the whole struct (with a freshly minted UUID) replaced the row
    /// (post-push audit).
    static func add(_ friend: TweenFriend) {
        var friends = load()
        if let index = friends.firstIndex(where: { $0.representsSamePerson(as: friend) }) {
            let existing = friends[index]
            friends[index] = TweenFriend(
                id: existing.id,
                name: friend.name,
                contactIdentifier: friend.contactIdentifier ?? existing.contactIdentifier,
                handle: friend.handle ?? existing.handle,
                homeBaseLatitude: friend.homeBaseLatitude ?? existing.homeBaseLatitude,
                homeBaseLongitude: friend.homeBaseLongitude ?? existing.homeBaseLongitude,
                homeBaseLabel: friend.homeBaseLabel ?? existing.homeBaseLabel)
            save(friends)
            return
        }
        friends.append(friend)
        save(friends)
    }

    /// Sets (or replaces) a friend's home base in place, keeping the id.
    static func setHomeBase(id: UUID, coordinate: CLLocationCoordinate2D, label: String?) {
        var friends = load()
        guard let index = friends.firstIndex(where: { $0.id == id }) else { return }
        friends[index].homeBaseLatitude = coordinate.latitude
        friends[index].homeBaseLongitude = coordinate.longitude
        friends[index].homeBaseLabel = label
        save(friends)
    }

    static func clearHomeBase(id: UUID) {
        var friends = load()
        guard let index = friends.firstIndex(where: { $0.id == id }) else { return }
        friends[index].homeBaseLatitude = nil
        friends[index].homeBaseLongitude = nil
        friends[index].homeBaseLabel = nil
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
