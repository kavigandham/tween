import Foundation
import CoreLocation

/// Cross-process coordinate persistence backed by App Group `UserDefaults`.
///
/// Both the host app and the Messages extension read/write the same suite, so
/// every write is a single atomic JSON blob under one key — this prevents torn
/// reads where one process sees a half-updated coordinate.
///
/// App Group `UserDefaults` is unencrypted: store coordinates and timestamps
/// only, never anything sensitive.
enum LocationCache {
    static let appGroup = "group.com.kavigandham.tween"

    private static let selfKey = "tween.cache.self"
    private static let peerKey = "tween.cache.peer"
    private static let selfActiveKey = "tween.cache.self.active"
    private static let peerActiveKey = "tween.cache.peer.active"
    private static let participantsKey = "tween.cache.participants"
    private static let agreedMeetupKey = "tween.cache.agreedMeetup"

    /// How long a cached coordinate is considered usable.
    ///
    /// Was 1 hour, which routinely served stale fixes (last hour's coffee
    /// shop) as the user's "current" location and read like a spoofing bug
    /// to customers. 5 minutes is short enough that a user who's actively
    /// moving (e.g. walking from work to the cafe) is rarely served a wrong
    /// pin, while still long enough that a quick "I'm in" → open-app round
    /// trip doesn't re-fetch unnecessarily.
    static let freshnessWindow: TimeInterval = 5 * 60 // 5 minutes

    /// A single coordinate sample. The whole struct is encoded under one key.
    struct CachedCoord: Codable, Equatable {
        let latitude: Double
        let longitude: Double
        let timestamp: Date
        /// Presence flag folded INTO the blob (audit W11): written as two
        /// separate keys, a cross-process reader between the writes saw a
        /// fresh coordinate with a stale flag (or vice versa), defeating
        /// the freshness logic. Optional so pre-split blobs keep decoding;
        /// nil defers to the legacy bool key.
        var isActive: Bool? = nil
        /// True when this coordinate was DECLARED by the user ("I'll be at…")
        /// rather than measured by GPS. A declared location is not a fix that
        /// goes stale, so it's exempt from the 5-minute freshness window.
        /// Optional so pre-provenance blobs keep decoding (nil = GPS).
        var isManual: Bool? = nil

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    // MARK: - Self

    static func save(_ coordinate: CLLocationCoordinate2D, at date: Date = Date(),
                     isActive: Bool = true, isManual: Bool = false) {
        write(coordinate, at: date, key: selfKey, isActive: isActive, isManual: isManual)
        defaults?.set(isActive, forKey: selfActiveKey)   // legacy mirror
        MeetupSync.post()
    }

    static func loadSelf() -> CachedCoord? {
        read(key: selfKey)
    }

    /// The cached self coordinate ONLY when it's within the freshness
    /// window — i.e. safe to embed in an outgoing bubble as "where I am
    /// now". Nil when the only cached fix is stale (the caller should
    /// request a fresh one) or absent. Independent of opt-in: this answers
    /// "is this coordinate current", not "am I in" (audit W4). Callers must
    /// use this — never a raw `loadSelf()` — when a coordinate is about to
    /// travel in a payload or seed fairness ranking.
    static func freshSelfCoordinate() -> CLLocationCoordinate2D? {
        guard let cached = loadSelf() else { return nil }
        // A user-declared location ("I'll be at…") isn't a GPS fix, so it's
        // exempt from the 5-min freshness window — BUT only while you're still
        // active. Leaving deactivates it (isActive=false); after that it must
        // not be sendable, or a stale declaration could be re-shared on a later
        // send (post-push audit). Freshness-exempt, not opt-in-exempt.
        if cached.isManual == true {
            return (cached.isActive ?? false) ? cached.coordinate : nil
        }
        guard Date().timeIntervalSince(cached.timestamp) <= freshnessWindow else { return nil }
        return cached.coordinate
    }

    static func setActive(_ active: Bool) {
        setFlag(active, blobKey: selfKey, legacyKey: selfActiveKey)
    }

    static func deactivateSelf() {
        setActive(false)
    }

    // MARK: - Peer

    static func savePeer(_ coordinate: CLLocationCoordinate2D, at date: Date = Date(), isActive: Bool = true) {
        guard !activeMeetupDeparted else {
            setPeerActive(false)
            return
        }
        write(coordinate, at: date, key: peerKey, isActive: isActive)
        defaults?.set(isActive, forKey: peerActiveKey)   // legacy mirror
        MeetupSync.post()
    }

    /// True when the local user has LEFT the active conversation's meetup.
    /// The global mirrors (participants blob + single-peer projection) are
    /// projections of a LIVE membership — a departed conversation's roster
    /// must never be parked here: this store has no TTL, so it outlives the
    /// scoped snapshot's 24 h window and resurrected departed peers in the
    /// host UI. One dam for every writer — per-call-site gates kept leaking
    /// (the host's decode path got one, the extension's did not; audit at
    /// 69a3886). Rejoin paths clear the tombstone BEFORE writing the roster.
    private static var activeMeetupDeparted: Bool {
        guard let key = ConversationMeetupStore.lastActiveConversationKey else { return false }
        return ConversationMeetupStore.localUserLeft(key: key)
    }

    static func loadPeer() -> CachedCoord? {
        read(key: peerKey)
    }

    static func setPeerActive(_ active: Bool) {
        setFlag(active, blobKey: peerKey, legacyKey: peerActiveKey)
    }

    static var isPeerActive: Bool {
        guard let cached = loadPeer() else { return false }
        if let flag = cached.isActive {
            guard flag else { return false }
        } else if defaults?.object(forKey: peerActiveKey) != nil,
                  defaults?.bool(forKey: peerActiveKey) != true {
            return false   // pre-split blob: legacy bool key decides
        }
        return Date().timeIntervalSince(cached.timestamp) <= freshnessWindow
    }

    // MARK: - Status

    /// True when the user has explicitly said "I'm in" and hasn't left. Unlike
    /// `isActive` this ignores coordinate freshness: presence is a user
    /// decision that only "I'm out" (or a meetup reset) reverses. Freshness
    /// still gates whether the cached COORDINATE is reusable — use `isActive`
    /// for that.
    static var isOptedIn: Bool {
        if let flag = loadSelf()?.isActive { return flag }
        return defaults?.bool(forKey: selfActiveKey) ?? false
    }

    /// True when self explicitly opted in and the coordinate is fresh.
    static var isActive: Bool {
        guard let cached = loadSelf() else { return false }
        if let flag = cached.isActive {
            guard flag else { return false }
        } else if defaults?.object(forKey: selfActiveKey) != nil,
                  defaults?.bool(forKey: selfActiveKey) != true {
            return false   // pre-split blob: legacy bool key decides
        }
        // A declared location ("I'll be at…") stays active without a fresh GPS
        // fix; only measured coordinates age out of the freshness window.
        if cached.isManual == true { return true }
        return Date().timeIntervalSince(cached.timestamp) <= freshnessWindow
    }

    // MARK: - Participants (group-aware roster)
    //
    // The canonical store for the current meetup's participants. Replaces the
    // single-peer model for any code that has been migrated; legacy callers
    // can keep using `loadPeer`/`savePeer` until they're updated.

    static func saveParticipants(_ participants: [Participant]) {
        guard !activeMeetupDeparted else {
            // Self-heal: scrub residue instead of merely refusing, so any
            // post-leave write path leaves the mirrors clean.
            clearParticipants()
            return
        }
        guard let data = try? JSONEncoder().encode(participants) else { return }
        defaults?.set(data, forKey: participantsKey)
        MeetupSync.post()
    }

    /// Saves the canonical roster and keeps the legacy single-peer projection
    /// in sync for screens that still read `loadPeer` / `isPeerActive`.
    static func saveParticipantSnapshot(_ participants: [Participant], localName: String) {
        saveParticipants(participants)
        if let firstRemote = participants.first(where: { $0.name != localName }) {
            savePeer(firstRemote.coordinate, isActive: true)
        } else {
            setPeerActive(false)
        }
    }

    /// Context-aware variant: filters the legacy peer projection with
    /// `Participant.matches(_:)` (ID-first; name fallback only for legacy
    /// id-less entries) so colliding display names — e.g. two devices both
    /// defaulting to "You" — can't select the wrong entry as "the peer" or
    /// wrongly deactivate it. The name-only overload above remains for
    /// callers without a participant context.
    static func saveParticipantSnapshot(_ participants: [Participant], localContext: LocalParticipantContext) {
        saveParticipants(participants)
        if let firstRemote = participants.first(where: { !$0.matches(localContext) }) {
            savePeer(firstRemote.coordinate, isActive: true)
        } else {
            setPeerActive(false)
        }
    }

    static func loadParticipants() -> [Participant] {
        guard let data = defaults?.data(forKey: participantsKey),
              let list = try? JSONDecoder().decode([Participant].self, from: data)
        else { return [] }
        return list
    }

    static func clearParticipants() {
        defaults?.removeObject(forKey: participantsKey)
        MeetupSync.post()
    }

    // MARK: - Agreed meetup (terminal state of a negotiation)
    //
    // Once both sides have agreed on a spot, that agreement needs to persist
    // across extension launches — otherwise re-opening the extension by
    // tapping the older propose bubble would re-render the Agree/Change UI
    // and let the user "agree again", which is the v1 customer report:
    // "When both agreed, it didnt give a directions page, it gave back the
    // agree or change page."
    //
    // Serialised via TweenState's URL encoder so we don't have to make
    // TweenState Codable — the URL roundtrip is already covered by tests.

    static func saveAgreedMeetup(_ state: TweenState) {
        guard let url = state.encodedURL(scheme: "tween", host: "m") else { return }
        defaults?.set(url.absoluteString, forKey: agreedMeetupKey)
        MeetupSync.post()
    }

    static func loadAgreedMeetup() -> TweenState? {
        guard let raw = defaults?.string(forKey: agreedMeetupKey),
              let url = URL(string: raw) else { return nil }
        return TweenState(url: url)
    }

    static func clearAgreedMeetup() {
        defaults?.removeObject(forKey: agreedMeetupKey)
        MeetupSync.post()
    }

    // MARK: - Lifecycle

    static func startFreshMeetup() {
        setFlag(false, blobKey: selfKey, legacyKey: selfActiveKey)
        setFlag(false, blobKey: peerKey, legacyKey: peerActiveKey)
        defaults?.removeObject(forKey: participantsKey)
        defaults?.removeObject(forKey: agreedMeetupKey)
        MeetupSync.post()
    }

    static func clearAll() {
        defaults?.removeObject(forKey: selfKey)
        defaults?.removeObject(forKey: peerKey)
        defaults?.removeObject(forKey: selfActiveKey)
        defaults?.removeObject(forKey: peerActiveKey)
        defaults?.removeObject(forKey: participantsKey)
        defaults?.removeObject(forKey: agreedMeetupKey)
    }

    // MARK: - Atomic single-key codec

    private static func write(_ coordinate: CLLocationCoordinate2D, at date: Date,
                              key: String, isActive: Bool, isManual: Bool = false) {
        let coord = CachedCoord(latitude: coordinate.latitude,
                                longitude: coordinate.longitude,
                                timestamp: date,
                                isActive: isActive,
                                isManual: isManual)
        guard let data = try? JSONEncoder().encode(coord) else { return }
        defaults?.set(data, forKey: key)
    }

    /// Flag flips are a read-modify-write of the blob (one atomic set), with
    /// the legacy bool key mirrored for downgrade safety and for the
    /// no-blob-yet case (a flag set before any coordinate exists).
    private static func setFlag(_ active: Bool, blobKey: String, legacyKey: String) {
        if var cached = read(key: blobKey) {
            cached.isActive = active
            if let data = try? JSONEncoder().encode(cached) {
                defaults?.set(data, forKey: blobKey)
            }
        }
        defaults?.set(active, forKey: legacyKey)
        MeetupSync.post()
    }

    private static func read(key: String) -> CachedCoord? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CachedCoord.self, from: data)
    }
}

// MARK: - Place library

/// A lightweight, Codable snapshot of a MapKit place. `MKMapItem` itself is
/// not Codable, so Recents and Favorites persist the customer-facing metadata
/// needed to rebuild an immediate detail card without waiting on the network.
struct StoredSpot: Codable, Equatable, Identifiable {
    let name: String
    let address: String?
    let latitude: Double
    let longitude: Double
    let phoneNumber: String?
    let websiteURLString: String?
    let lastUsedAt: Date

    var id: String {
        let normalizedName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return String(format: "%@|%.5f|%.5f", normalizedName, latitude, longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func used(at date: Date) -> StoredSpot {
        StoredSpot(
            name: name,
            address: address,
            latitude: latitude,
            longitude: longitude,
            phoneNumber: phoneNumber,
            websiteURLString: websiteURLString,
            lastUsedAt: date)
    }
}

/// Persistent Recents and Favorites shared by the host app and its Messages
/// extension. Writes replace one complete JSON value, matching LocationCache's
/// cross-process atomicity guarantees.
enum SpotLibrary {
    private static let recentKey = "tween.places.recents"
    private static let favoritesKey = "tween.places.favorites"
    static let recentLimit = 20
    static let favoritesLimit = 50

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: LocationCache.appGroup)
    }

    static func loadRecents() -> [StoredSpot] {
        load(key: recentKey)
    }

    static func loadFavorites() -> [StoredSpot] {
        load(key: favoritesKey)
    }

    /// Adds a place to the front of Recents, or promotes an existing place.
    /// The newest snapshot wins so a later MapKit result can enrich an older
    /// coordinate-only meetup with an address, phone number, or website.
    @discardableResult
    static func recordRecent(_ spot: StoredSpot, at date: Date = Date()) -> [StoredSpot] {
        let loaded = loadRecents()
        let existing = loaded.first { $0.id == spot.id }
        let merged = StoredSpot(
            name: spot.name,
            address: nonEmpty(spot.address) ?? existing?.address,
            latitude: spot.latitude,
            longitude: spot.longitude,
            phoneNumber: nonEmpty(spot.phoneNumber) ?? existing?.phoneNumber,
            websiteURLString: nonEmpty(spot.websiteURLString) ?? existing?.websiteURLString,
            lastUsedAt: date)
        var spots = loaded.filter { $0.id != spot.id }
        spots.insert(merged, at: 0)
        spots = Array(spots.prefix(recentLimit))
        save(spots, key: recentKey)
        return spots
    }

    /// Toggles a place in Favorites and returns the complete updated list.
    /// Favorites are ordered by the most recent save, like Apple Maps.
    @discardableResult
    static func toggleFavorite(_ spot: StoredSpot, at date: Date = Date()) -> [StoredSpot] {
        var spots = loadFavorites()
        if spots.contains(where: { $0.id == spot.id }) {
            spots.removeAll { $0.id == spot.id }
        } else {
            spots.removeAll { $0.id == spot.id }
            spots.insert(spot.used(at: date), at: 0)
            spots = Array(spots.prefix(favoritesLimit))
        }
        save(spots, key: favoritesKey)
        return spots
    }

    static func isFavorite(_ spot: StoredSpot) -> Bool {
        loadFavorites().contains { $0.id == spot.id }
    }

    /// Finds the richest saved snapshot for a coordinate-backed meetup.
    /// Favor exact place identity first, then tolerate a tiny coordinate drift
    /// from URL serialization while still requiring the same normalized name.
    static func matching(name: String, coordinate: CLLocationCoordinate2D) -> StoredSpot? {
        let probe = StoredSpot(
            name: name,
            address: nil,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            phoneNumber: nil,
            websiteURLString: nil,
            lastUsedAt: .distantPast)
        let candidates = loadFavorites() + loadRecents()
        if let exact = candidates.first(where: { $0.id == probe.id }) {
            return exact
        }
        return candidates.first {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                && abs($0.latitude - coordinate.latitude) < 0.0002
                && abs($0.longitude - coordinate.longitude) < 0.0002
        }
    }

    private static func load(key: String) -> [StoredSpot] {
        guard let data = defaults?.data(forKey: key),
              let spots = try? JSONDecoder().decode([StoredSpot].self, from: data)
        else { return [] }
        return spots.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    private static func save(_ spots: [StoredSpot], key: String) {
        guard let data = try? JSONEncoder().encode(spots) else { return }
        defaults?.set(data, forKey: key)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
