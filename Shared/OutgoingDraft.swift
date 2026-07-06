import Foundation
import CoreLocation

/// A spot the host app has staged to hand off to the Messages extension.
///
/// The host app can't insert a bubble itself, so when the user taps "Send to
/// chat" we persist their chosen spot here and bounce them to Messages. The
/// extension picks the draft up on activation, confirms it, and composes the
/// bubble — then clears the draft.
struct OutgoingDraft: Codable, Equatable {
    let spotName: String
    let latitude: Double
    let longitude: Double
    let timestamp: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(spotName: String, latitude: Double, longitude: Double, timestamp: Date = Date()) {
        self.spotName = spotName
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
    }
}

/// Cross-process hand-off for a pending spot, backed by the App Group suite.
///
/// Like the rest of the cache, the whole struct is written as one atomic JSON
/// blob under a single key so the extension never sees a torn read.
enum OutgoingDraftStore {
    static let storageKey = "outgoingDraft"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: LocationCache.appGroup)
    }

    static func save(_ draft: OutgoingDraft) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults?.set(data, forKey: storageKey)
        MeetupSync.post()
    }

    static func load() -> OutgoingDraft? {
        guard let data = defaults?.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(OutgoingDraft.self, from: data)
    }

    static func clear() {
        defaults?.removeObject(forKey: storageKey)
        MeetupSync.post()
    }
}
