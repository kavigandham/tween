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

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    // MARK: - Self

    static func save(_ coordinate: CLLocationCoordinate2D, at date: Date = Date(), isActive: Bool = true) {
        write(coordinate, at: date, key: selfKey)
        defaults?.set(isActive, forKey: selfActiveKey)
    }

    static func loadSelf() -> CachedCoord? {
        read(key: selfKey)
    }

    static func setActive(_ active: Bool) {
        defaults?.set(active, forKey: selfActiveKey)
    }

    static func deactivateSelf() {
        defaults?.set(false, forKey: selfActiveKey)
    }

    // MARK: - Peer

    static func savePeer(_ coordinate: CLLocationCoordinate2D, at date: Date = Date(), isActive: Bool = true) {
        write(coordinate, at: date, key: peerKey)
        defaults?.set(isActive, forKey: peerActiveKey)
    }

    static func loadPeer() -> CachedCoord? {
        read(key: peerKey)
    }

    static func setPeerActive(_ active: Bool) {
        defaults?.set(active, forKey: peerActiveKey)
    }

    static var isPeerActive: Bool {
        guard let cached = loadPeer() else { return false }
        if defaults?.object(forKey: peerActiveKey) != nil,
           defaults?.bool(forKey: peerActiveKey) != true {
            return false
        }
        return Date().timeIntervalSince(cached.timestamp) <= freshnessWindow
    }

    // MARK: - Status

    /// True when self explicitly opted in and the coordinate is fresh.
    static var isActive: Bool {
        guard let cached = loadSelf() else { return false }
        if defaults?.object(forKey: selfActiveKey) != nil,
           defaults?.bool(forKey: selfActiveKey) != true {
            return false
        }
        return Date().timeIntervalSince(cached.timestamp) <= freshnessWindow
    }

    // MARK: - Participants (group-aware roster)
    //
    // The canonical store for the current meetup's participants. Replaces the
    // single-peer model for any code that has been migrated; legacy callers
    // can keep using `loadPeer`/`savePeer` until they're updated.

    static func saveParticipants(_ participants: [Participant]) {
        guard let data = try? JSONEncoder().encode(participants) else { return }
        defaults?.set(data, forKey: participantsKey)
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
    }

    static func loadAgreedMeetup() -> TweenState? {
        guard let raw = defaults?.string(forKey: agreedMeetupKey),
              let url = URL(string: raw) else { return nil }
        return TweenState(url: url)
    }

    static func clearAgreedMeetup() {
        defaults?.removeObject(forKey: agreedMeetupKey)
    }

    // MARK: - Lifecycle

    static func startFreshMeetup() {
        defaults?.set(false, forKey: selfActiveKey)
        defaults?.set(false, forKey: peerActiveKey)
        defaults?.removeObject(forKey: participantsKey)
        defaults?.removeObject(forKey: agreedMeetupKey)
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

    private static func write(_ coordinate: CLLocationCoordinate2D, at date: Date, key: String) {
        let coord = CachedCoord(latitude: coordinate.latitude,
                                longitude: coordinate.longitude,
                                timestamp: date)
        guard let data = try? JSONEncoder().encode(coord) else { return }
        defaults?.set(data, forKey: key)
    }

    private static func read(key: String) -> CachedCoord? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CachedCoord.self, from: data)
    }
}
