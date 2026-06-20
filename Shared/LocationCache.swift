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

    /// How long a cached coordinate is considered usable.
    static let freshnessWindow: TimeInterval = 60 * 60 // 1 hour

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

    static func save(_ coordinate: CLLocationCoordinate2D, at date: Date = Date()) {
        write(coordinate, at: date, key: selfKey)
    }

    static func loadSelf() -> CachedCoord? {
        read(key: selfKey)
    }

    // MARK: - Peer

    static func savePeer(_ coordinate: CLLocationCoordinate2D, at date: Date = Date()) {
        write(coordinate, at: date, key: peerKey)
    }

    static func loadPeer() -> CachedCoord? {
        read(key: peerKey)
    }

    // MARK: - Status

    /// True when a self coordinate exists and is within the freshness window.
    static var isActive: Bool {
        guard let cached = loadSelf() else { return false }
        return Date().timeIntervalSince(cached.timestamp) <= freshnessWindow
    }

    // MARK: - Lifecycle

    static func clearAll() {
        defaults?.removeObject(forKey: selfKey)
        defaults?.removeObject(forKey: peerKey)
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
