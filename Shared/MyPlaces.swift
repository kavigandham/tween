import Foundation
import CoreLocation

/// Where the local user said they are leaving FROM for one meetup.
///
/// The kind is a snapshot taken at join time, stored beside the coordinate in
/// `LocationCache` — not a live reference to a `MyPlace`. Changing (or
/// deleting) Home on Tuesday must not rewrite Monday's meetup, which is why
/// nothing downstream ever re-reads the store to answer "where did they join
/// from"; the coordinate was copied at the moment of the join.
///
/// `.saved` is the forward slot for Work/School/Custom saved places once the
/// UI exposes more than Home; it decodes today so a payload written by a later
/// build doesn't fall over.
enum JoinOrigin: String, Codable, Equatable {
    /// A live GPS fix.
    case current
    /// The user's saved Home.
    case home
    /// Another saved place (Work, School, …). Reserved; V1 exposes Home only.
    case saved
    /// A one-off address the user searched for ("I'll be at…").
    case custom

    /// Unknown strings from a newer build degrade to a declared location
    /// rather than failing the whole cached-coordinate decode.
    init(storage raw: String?) {
        guard let raw, let parsed = JoinOrigin(rawValue: raw) else { self = .current; return }
        self = parsed
    }

    /// True when the coordinate was DECLARED by the user rather than measured.
    /// Declared origins are freshness-exempt and must survive a background GPS
    /// fix — the same contract `LocationCache.CachedCoord.isManual` carries.
    var isDeclared: Bool { self != .current }
}

/// What a saved place means. Only `.home` is offered in V1; the others exist
/// so adding Work/School/Custom later is a UI change, not a schema migration.
enum MyPlaceKind: String, Codable, CaseIterable, Identifiable {
    case home
    case work
    case school
    case custom

    /// The kind IS the identity — there is one Home, one Work, one School.
    /// Lets a picker be driven by `.sheet(item:)` without a wrapper type.
    var id: String { rawValue }

    /// Unknown kinds (written by a later build) read as `.custom` instead of
    /// failing the array decode and wiping the user's places.
    init(storage raw: String?) {
        guard let raw, let parsed = MyPlaceKind(rawValue: raw) else { self = .custom; return }
        self = parsed
    }

    var defaultLabel: String {
        switch self {
        case .home:   return "Home"
        case .work:   return "Work"
        case .school: return "School"
        case .custom: return "Place"
        }
    }

    var symbol: String {
        switch self {
        case .home:   return "house.fill"
        case .work:   return "briefcase.fill"
        case .school: return "book.fill"
        case .custom: return "mappin"
        }
    }
}

/// One address the LOCAL user has saved for themselves — "Home" today.
///
/// PRIVATE PLANNING DATA. This is the owner's own record and it never leaves
/// the device: no encoder puts a `MyPlace` (or its `address`) into an
/// `MSMessage` payload, a group, or a participant. Joining from one copies the
/// COORDINATE only, exactly like the declared "I'll be at…" primitive it
/// generalises — see `JoinOrigin` for the snapshot rule.
///
/// Mirrors `FriendPlace` deliberately: a friend's saved address and your own
/// are the same shape, and two subtly different place models is how the
/// group editor ended up with an address writer that appended instead of
/// replacing (audit 2026-08-04).
struct MyPlace: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var kind: MyPlaceKind
    /// What the user calls it. Seeded from `kind.defaultLabel`.
    var label: String
    /// A human-readable address for the owner's own screens. Nil when the
    /// picker couldn't produce one — the coordinate is what matters.
    var address: String?
    var latitude: Double
    var longitude: Double
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         kind: MyPlaceKind = .home,
         label: String? = nil,
         address: String? = nil,
         coordinate: CLLocationCoordinate2D,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = (trimmed?.isEmpty == false ? trimmed : nil) ?? kind.defaultLabel
        self.address = MyPlace.normalized(address)
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The origin kind a join from this place records.
    var origin: JoinOrigin { kind == .home ? .home : .saved }

    static func normalized(_ address: String?) -> String? {
        guard let value = address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    // Hand-rolled so a blob written before any of these fields existed — or by
    // a later build with a kind this one has never heard of — still decodes.
    enum CodingKeys: String, CodingKey {
        case id, kind, label, address, latitude, longitude, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = MyPlaceKind(storage: try container.decodeIfPresent(String.self, forKey: .kind))
        let storedLabel = try container.decodeIfPresent(String.self, forKey: .label)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        label = storedLabel?.isEmpty == false ? storedLabel! : kind.defaultLabel
        address = MyPlace.normalized(try container.decodeIfPresent(String.self, forKey: .address))
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        let now = Date()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(address, forKey: .address)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// The local user's own saved places, persisted as ONE atomic JSON blob under
/// a single App Group key — the same torn-read discipline as `FriendRoster`,
/// `GroupStore` and `LocationCache`.
///
/// Constraint 6 (the App Group suite is unencrypted) sanctions the friend
/// roster's names and addresses; this is the same class of data for the owner
/// themselves, recorded as an exception in CLAUDE.md (2026-09-21). Nothing
/// here is broadcast, logged, or attached to a meetup: see `MyPlace`.
enum MyPlaceStore {
    static let storageKey = "tween.myPlaces"

    // Cached suite (lag audit 2026-09-05) — see LocationCache.sharedDefaults.
    private static var defaults: UserDefaults? { LocationCache.sharedDefaults }

    static func load() -> [MyPlace] {
        guard let data = defaults?.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([MyPlace].self, from: data)) ?? []
    }

    static func save(_ places: [MyPlace]) {
        guard let data = try? JSONEncoder().encode(places) else { return }
        defaults?.set(data, forKey: storageKey)
    }

    /// The one canonical Home, or nil. When a legacy/duplicated blob somehow
    /// holds two, the most recently updated one wins rather than "whichever
    /// happened to be first" — a silent tie-break that would change on every
    /// rewrite.
    static func home() -> MyPlace? {
        load()
            .filter { $0.kind == .home }
            .max { $0.updatedAt < $1.updatedAt }
    }

    static func place(id: UUID) -> MyPlace? {
        load().first { $0.id == id }
    }

    /// Creates or REPLACES Home. Idempotent by construction: there is exactly
    /// one `.home` row afterwards, whatever the blob held before, so a double
    /// tap on Save can't leave two homes behind.
    ///
    /// Keeps the existing row's `id` and `createdAt` so anything holding the
    /// id (a pushed detail screen) still resolves after an edit — the same
    /// identity-preservation rule `FriendRoster.add` learned the hard way.
    @discardableResult
    static func setHome(coordinate: CLLocationCoordinate2D,
                        address: String? = nil,
                        label: String? = nil,
                        now: Date = Date()) -> MyPlace {
        var places = load()
        let existing = places.filter { $0.kind == .home }.max { $0.updatedAt < $1.updatedAt }
        let place = MyPlace(id: existing?.id ?? UUID(),
                            kind: .home,
                            label: label ?? existing?.label,
                            address: address,
                            coordinate: coordinate,
                            createdAt: existing?.createdAt ?? now,
                            updatedAt: now)
        places.removeAll { $0.kind == .home }
        places.insert(place, at: 0)
        save(places)
        return place
    }

    /// Adds or replaces a place by id. For `.home` this defers to `setHome`
    /// so the one-canonical-Home invariant can't be routed around.
    static func upsert(_ place: MyPlace) {
        guard place.kind != .home else {
            setHome(coordinate: place.coordinate, address: place.address,
                    label: place.label, now: place.updatedAt)
            return
        }
        var places = load()
        if let index = places.firstIndex(where: { $0.id == place.id }) {
            places[index] = place
        } else {
            places.append(place)
        }
        save(places)
    }

    /// Removing a place is local only: meetups already carry their own copied
    /// coordinates, so nothing in flight changes. Idempotent — removing an id
    /// that is already gone is a no-op, not a crash.
    static func remove(id: UUID) {
        let places = load()
        guard places.contains(where: { $0.id == id }) else { return }
        save(places.filter { $0.id != id })
    }

    static func removeHome() {
        let places = load()
        guard places.contains(where: { $0.kind == .home }) else { return }
        save(places.filter { $0.kind != .home })
    }

    static func clear() {
        defaults?.removeObject(forKey: storageKey)
    }
}
