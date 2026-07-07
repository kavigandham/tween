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
    /// The conversation this draft was staged FOR (the host app's
    /// last-active key). The extension refuses to adopt a draft bound to a
    /// different conversation — without this, a draft staged for chat A was
    /// adopted by whichever chat happened to open the extension next
    /// (audit W7). Optional: nil means "unknown" (legacy drafts, or the
    /// host app before any extension activation) and adopts anywhere.
    let conversationKey: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(spotName: String, latitude: Double, longitude: Double,
         timestamp: Date = Date(), conversationKey: String? = nil) {
        self.spotName = spotName
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.conversationKey = conversationKey
    }
}

/// Cross-process hand-off for a pending spot, backed by the App Group suite.
///
/// Like the rest of the cache, the whole struct is written as one atomic JSON
/// blob under a single key so the extension never sees a torn read.
enum OutgoingDraftStore {
    static let storageKey = "outgoingDraft"

    /// How long a staged draft stays adoptable. The hand-off is an
    /// app-switch measured in seconds; a draft older than this is debris
    /// from an abandoned flow, not intent — force-expanding the extension
    /// over it days later read as a haunting (audit W7).
    static let handoffTTL: TimeInterval = 15 * 60

    /// Whether the extension, active in `conversationKey`, should adopt a
    /// staged draft: it must be fresh, and bound to this conversation (or
    /// to none — legacy drafts and pre-activation stages carry no key).
    static func shouldAdopt(_ draft: OutgoingDraft,
                            conversationKey: String,
                            now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(draft.timestamp) <= handoffTTL else { return false }
        guard let bound = draft.conversationKey else { return true }
        return bound == conversationKey
    }

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
