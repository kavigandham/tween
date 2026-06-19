import XCTest
import CoreLocation
@testable import TweenApp

final class TweenAppTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Start every test from a clean App Group suite.
        if let defaults = UserDefaults(suiteName: LocationCache.appGroup) {
            for key in defaults.dictionaryRepresentation().keys {
                defaults.removeObject(forKey: key)
            }
        }
        LocationCache.clearAll()
    }

    // 1. TweenState round-trips through encode → decode.
    func testTweenStateRoundTrips() throws {
        let original = TweenState(text: "Blue Bottle", latitude: 37.7749, longitude: -122.4194)
        let url = try XCTUnwrap(original.encodedURL())
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded, original)
    }

    // 2. TweenState encodes with https scheme, ≤ 5000 chars.
    func testTweenStateEncodesHTTPSWithinLimit() throws {
        let state = TweenState(text: "Dolores Park", latitude: 37.7596, longitude: -122.4269)
        let url = try XCTUnwrap(state.encodedURL())
        XCTAssertEqual(url.scheme, "https")
        XCTAssertLessThanOrEqual(url.absoluteString.count, 5000)
    }

    // 3. TweenState round-trips emoji / non-ASCII text.
    func testTweenStateRoundTripsEmoji() throws {
        let original = TweenState(text: "Café ☕️ 東京", latitude: 35.6812, longitude: 139.7671)
        let url = try XCTUnwrap(original.encodedURL())
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded, original)
    }

    // 4. TweenState returns nil for an unrelated URL.
    func testTweenStateRejectsUnrelatedURL() {
        let url = URL(string: "https://example.com/about?foo=bar")!
        XCTAssertNil(TweenState(url: url))
    }

    // 4a. TweenState round-trips a sender name through encode → decode.
    func testTweenStateRoundTripsSenderName() throws {
        let original = TweenState(text: "I'm in", latitude: 37.7749, longitude: -122.4194, senderName: "Alice")
        let url = try XCTUnwrap(original.encodedURL())
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.senderName, "Alice")
    }

    // 4b. A URL without `from` decodes senderName as nil (backward compatibility
    //     with bubbles from builds before the field existed).
    func testTweenStateDecodesMissingSenderAsNil() throws {
        let noName = TweenState(text: "Dolores Park", latitude: 37.7596, longitude: -122.4269)
        let url = try XCTUnwrap(noName.encodedURL())
        XCTAssertFalse(url.absoluteString.contains("from="))
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertNil(decoded.senderName)
    }

    // 5. LocationCache saves and loads the self coordinate.
    func testLocationCacheSavesAndLoadsSelf() throws {
        let coord = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        LocationCache.save(coord)
        let loaded = try XCTUnwrap(LocationCache.loadSelf())
        XCTAssertEqual(loaded.latitude, coord.latitude, accuracy: 1e-9)
        XCTAssertEqual(loaded.longitude, coord.longitude, accuracy: 1e-9)
    }

    // 6. LocationCache saves and loads the peer independently of self.
    func testLocationCacheSavesPeerIndependently() throws {
        let selfCoord = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        let peerCoord = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        LocationCache.save(selfCoord)
        LocationCache.savePeer(peerCoord)

        let loadedSelf = try XCTUnwrap(LocationCache.loadSelf())
        let loadedPeer = try XCTUnwrap(LocationCache.loadPeer())
        XCTAssertEqual(loadedSelf.latitude, selfCoord.latitude, accuracy: 1e-9)
        XCTAssertEqual(loadedPeer.latitude, peerCoord.latitude, accuracy: 1e-9)
        XCTAssertNotEqual(loadedSelf.latitude, loadedPeer.latitude)
    }

    // 7. LocationCache returns nil on a clean suite.
    func testLocationCacheEmptyOnCleanSuite() {
        XCTAssertNil(LocationCache.loadSelf())
        XCTAssertNil(LocationCache.loadPeer())
        XCTAssertFalse(LocationCache.isActive)
    }
}
