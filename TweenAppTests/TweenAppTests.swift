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
        XCTAssertTrue(decoded.representsParticipantLocation)
    }

    // 4b. A URL without `from` decodes senderName as nil (backward compatibility
    //     with bubbles from builds before the field existed).
    func testTweenStateDecodesMissingSenderAsNil() throws {
        let noName = TweenState(text: "Dolores Park", latitude: 37.7596, longitude: -122.4269)
        let url = try XCTUnwrap(noName.encodedURL())
        XCTAssertFalse(url.absoluteString.contains("from="))
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertNil(decoded.senderName)
        XCTAssertEqual(decoded.kind, .place)
        XCTAssertFalse(decoded.representsParticipantLocation)
    }

    func testTweenStateRoundTripsExplicitKind() throws {
        let participant = TweenState(
            text: "Joining from campus",
            latitude: 38.9897,
            longitude: -76.9378,
            senderName: "Khanna",
            kind: .participant)
        let participantURL = try XCTUnwrap(participant.encodedURL())
        XCTAssertEqual(try XCTUnwrap(TweenState(url: participantURL)).kind, .participant)

        let place = TweenState(
            text: "Michael's Cafe",
            latitude: 39.2904,
            longitude: -76.6122,
            senderName: "Hassan",
            kind: .place)
        let placeURL = try XCTUnwrap(place.encodedURL())
        XCTAssertEqual(try XCTUnwrap(TweenState(url: placeURL)).kind, .place)
    }

    func testPlaceInviteCanCarrySenderCoordinate() throws {
        let sender = CLLocationCoordinate2D(latitude: 39.0438, longitude: -77.4874)
        let place = TweenState(
            text: "Michael's Cafe",
            latitude: 39.2904,
            longitude: -76.6122,
            senderName: "Kavi",
            kind: .place,
            senderCoordinate: sender)

        let decoded = try XCTUnwrap(TweenState(url: try XCTUnwrap(place.encodedURL())))

        XCTAssertEqual(decoded.kind, .place)
        XCTAssertEqual(decoded.coordinate.latitude, 39.2904, accuracy: 1e-9)
        let participantCoordinate = try XCTUnwrap(decoded.participantCoordinate)
        XCTAssertEqual(participantCoordinate.latitude, sender.latitude, accuracy: 1e-9)
        XCTAssertEqual(participantCoordinate.longitude, sender.longitude, accuracy: 1e-9)
    }

    func testPlaceAgreementRoundTripsAction() throws {
        let state = TweenState(
            text: "Michael's Cafe",
            latitude: 39.2904,
            longitude: -76.6122,
            senderName: "Hassan",
            kind: .place,
            senderCoordinate: CLLocationCoordinate2D(latitude: 39.0438, longitude: -77.4874),
            action: .agree)

        let decoded = try XCTUnwrap(TweenState(url: try XCTUnwrap(state.encodedURL())))

        XCTAssertEqual(decoded.text, "Michael's Cafe")
        XCTAssertEqual(decoded.kind, .place)
        XCTAssertEqual(decoded.action, .agree)
        XCTAssertNotNil(decoded.participantCoordinate)
    }

    func testTweenStateDecodesCustomSchemeForPlainMessageLinks() throws {
        let state = TweenState(text: "I'm in", latitude: 38.9072, longitude: -77.0369, kind: .participant)
        let url = try XCTUnwrap(state.encodedURL(scheme: "tween", host: "m"))
        let decoded = try XCTUnwrap(TweenState(url: url))

        XCTAssertEqual(decoded.kind, .participant)
        XCTAssertEqual(try XCTUnwrap(decoded.participantCoordinate).latitude, 38.9072, accuracy: 1e-9)
    }

    // 5. LocationCache saves and loads the self coordinate.
    func testLocationCacheSavesAndLoadsSelf() throws {
        let coord = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        LocationCache.save(coord)
        let loaded = try XCTUnwrap(LocationCache.loadSelf())
        XCTAssertEqual(loaded.latitude, coord.latitude, accuracy: 1e-9)
        XCTAssertEqual(loaded.longitude, coord.longitude, accuracy: 1e-9)
        XCTAssertTrue(LocationCache.isActive)
    }

    func testLocationCacheDeactivateSelfPreservesCoordinateButClearsActive() throws {
        let coord = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        LocationCache.save(coord)
        LocationCache.deactivateSelf()

        let loaded = try XCTUnwrap(LocationCache.loadSelf())
        XCTAssertEqual(loaded.latitude, coord.latitude, accuracy: 1e-9)
        XCTAssertFalse(LocationCache.isActive)
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
        XCTAssertTrue(LocationCache.isPeerActive)
    }

    func testLocationCacheCanDeactivatePeer() throws {
        let peerCoord = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        LocationCache.savePeer(peerCoord)
        LocationCache.setPeerActive(false)

        let loadedPeer = try XCTUnwrap(LocationCache.loadPeer())
        XCTAssertEqual(loadedPeer.latitude, peerCoord.latitude, accuracy: 1e-9)
        XCTAssertFalse(LocationCache.isPeerActive)
    }

    func testPinRolesUseRequestedColorSystem() {
        XCTAssertEqual(TweenPin.Role.selfDot.accessibilityName, "Your location")
        XCTAssertEqual(TweenPin.Role.friend.accessibilityName, "Your friend's location")
        XCTAssertEqual(TweenPin.Role.fairSpot.accessibilityName, "Best fair meetup spot")
        XCTAssertEqual(TweenPin.Role.closestToUser.accessibilityName, "Place closest to you")
    }

    // 7. LocationCache returns nil on a clean suite.
    func testLocationCacheEmptyOnCleanSuite() {
        XCTAssertNil(LocationCache.loadSelf())
        XCTAssertNil(LocationCache.loadPeer())
        XCTAssertFalse(LocationCache.isActive)
    }
}
