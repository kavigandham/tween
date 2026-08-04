import Foundation
import CoreLocation

/// One saved address for a friend — "Home", "Work", or anything they type.
///
/// LOCAL PLANNING DATA ONLY, same contract as the single home base it
/// generalises: it seeds group searches as a `manual:` participant and is
/// never merged into an outgoing payload.
struct FriendPlace: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    /// What the user calls it. Free text, seeded from the presets below.
    var label: String
    var latitude: Double
    var longitude: Double

    init(id: UUID = UUID(), label: String, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.label = label
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Offered first when adding; the user can type anything instead.
    static let presetLabels = ["Home", "Work", "School", "Gym"]

    /// Home wins when a friend has several and nothing else says otherwise —
    /// it's the one people mean by "where they usually start from".
    static func preferred(from places: [FriendPlace]) -> FriendPlace? {
        places.first { $0.label.compare("Home", options: .caseInsensitive) == .orderedSame }
            ?? places.first
    }
}

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
    /// Every saved address for this friend — Home, Work, wherever. Optional so
    /// rosters written before labelled places decode unchanged; `places`
    /// migrates the legacy single home base in on read.
    var savedPlaces: [FriendPlace]?

    init(id: UUID = UUID(), name: String, contactIdentifier: String? = nil, handle: String? = nil,
         homeBaseLatitude: Double? = nil, homeBaseLongitude: Double? = nil, homeBaseLabel: String? = nil,
         savedPlaces: [FriendPlace]? = nil) {
        self.id = id
        self.name = name
        self.contactIdentifier = contactIdentifier
        self.handle = handle
        self.homeBaseLatitude = homeBaseLatitude
        self.homeBaseLongitude = homeBaseLongitude
        self.homeBaseLabel = homeBaseLabel
        self.savedPlaces = savedPlaces
    }

    /// Addresses for this friend, oldest schema included.
    ///
    /// A roster written before labelled places has only the single home base;
    /// surfacing it here (rather than migrating on write) means an older build
    /// reading the same App Group still finds what it expects, and nothing has
    /// to be rewritten on upgrade.
    var places: [FriendPlace] {
        if let savedPlaces, !savedPlaces.isEmpty { return savedPlaces }
        guard let homeBase else { return [] }
        return [FriendPlace(label: homeBaseLabel ?? "Home", coordinate: homeBase)]
    }

    /// The one a group search uses when it needs a single point for this
    /// person.
    var primaryPlace: FriendPlace? { FriendPlace.preferred(from: places) }

    var homeBase: CLLocationCoordinate2D? {
        if let primary = savedPlaces.flatMap(FriendPlace.preferred) { return primary.coordinate }
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
        addPlace(id: id, label: label ?? "Home", coordinate: coordinate)
    }

    /// Adds a labelled address. Re-using a label replaces that address rather
    /// than stacking a second "Home".
    static func addPlace(id: UUID, label: String, coordinate: CLLocationCoordinate2D) {
        var friends = load()
        guard let index = friends.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Address" : trimmed
        var places = friends[index].places
        if let existing = places.firstIndex(where: {
            $0.label.compare(name, options: .caseInsensitive) == .orderedSame
        }) {
            places[existing] = FriendPlace(id: places[existing].id, label: name, coordinate: coordinate)
        } else {
            places.append(FriendPlace(label: name, coordinate: coordinate))
        }
        friends[index].savedPlaces = places
        // Keep the legacy fields in step so an older build — or the extension
        // mid-upgrade — still finds a home base where it expects one.
        if let primary = FriendPlace.preferred(from: places) {
            friends[index].homeBaseLatitude = primary.latitude
            friends[index].homeBaseLongitude = primary.longitude
            friends[index].homeBaseLabel = primary.label
        }
        save(friends)
    }

    static func removePlace(id: UUID, placeID: UUID) {
        var friends = load()
        guard let index = friends.firstIndex(where: { $0.id == id }) else { return }
        var places = friends[index].places
        places.removeAll { $0.id == placeID }
        friends[index].savedPlaces = places
        if let primary = FriendPlace.preferred(from: places) {
            friends[index].homeBaseLatitude = primary.latitude
            friends[index].homeBaseLongitude = primary.longitude
            friends[index].homeBaseLabel = primary.label
        } else {
            friends[index].homeBaseLatitude = nil
            friends[index].homeBaseLongitude = nil
            friends[index].homeBaseLabel = nil
        }
        save(friends)
    }

    /// Removes every saved address for this friend.
    ///
    /// Must clear `savedPlaces` as well as the legacy fields: `homeBase` now
    /// prefers the places list, so nilling only the old columns left the
    /// address standing and the friend still looked located (caught by
    /// testHomeBaseRoundTrips, 2026-08-04).
    static func clearHomeBase(id: UUID) {
        var friends = load()
        guard let index = friends.firstIndex(where: { $0.id == id }) else { return }
        friends[index].savedPlaces = []
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
