import XCTest
import CoreLocation
@testable import TweenApp

/// The local user's saved Home: round-trip, the one-canonical-Home invariant,
/// removal, legacy/forward decode, and the join-origin snapshot rule that
/// stops yesterday's meetup being rewritten by today's move.
final class MyPlacesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Start every test from a clean App Group suite.
        if let defaults = UserDefaults(suiteName: LocationCache.appGroup) {
            for key in defaults.dictionaryRepresentation().keys {
                defaults.removeObject(forKey: key)
            }
        }
        LocationCache.clearAll()
        MyPlaceStore.clear()
    }

    private let blacksburg = CLLocationCoordinate2D(latitude: 37.2296, longitude: -80.4139)
    private let ashburn = CLLocationCoordinate2D(latitude: 39.0438, longitude: -77.4874)

    // MARK: - Create / update / delete

    // 1. Home round-trips with its address and coordinate.
    func testHomeRoundTrips() {
        MyPlaceStore.setHome(coordinate: blacksburg, address: "123 Main St, Blacksburg")
        let home = MyPlaceStore.home()
        XCTAssertEqual(home?.kind, .home)
        XCTAssertEqual(home?.label, "Home")
        XCTAssertEqual(home?.address, "123 Main St, Blacksburg")
        XCTAssertEqual(home?.latitude ?? 0, blacksburg.latitude, accuracy: 0.0001)
        XCTAssertEqual(home?.longitude ?? 0, blacksburg.longitude, accuracy: 0.0001)
    }

    // 2. Saving Home twice REPLACES it — there is exactly one canonical Home,
    //    however many times Save is tapped (spec §27, §20 idempotency).
    func testSecondSaveReplacesRatherThanStacking() {
        MyPlaceStore.setHome(coordinate: blacksburg, address: "Old place")
        let first = MyPlaceStore.home()
        MyPlaceStore.setHome(coordinate: ashburn, address: "New place")

        let homes = MyPlaceStore.load().filter { $0.kind == .home }
        XCTAssertEqual(homes.count, 1)
        XCTAssertEqual(homes.first?.address, "New place")
        XCTAssertEqual(homes.first?.latitude ?? 0, ashburn.latitude, accuracy: 0.0001)
        // The id and creation date survive the edit, so anything holding the
        // id (a pushed detail screen) still resolves afterwards.
        XCTAssertEqual(homes.first?.id, first?.id)
        XCTAssertEqual(homes.first?.createdAt, first?.createdAt)
    }

    // 3. Removing Home leaves nothing behind, and removing twice is a no-op.
    func testRemoveHomeIsIdempotent() {
        MyPlaceStore.setHome(coordinate: blacksburg, address: "123 Main St")
        MyPlaceStore.removeHome()
        XCTAssertNil(MyPlaceStore.home())
        MyPlaceStore.removeHome()
        XCTAssertNil(MyPlaceStore.home())
        XCTAssertTrue(MyPlaceStore.load().isEmpty)
    }

    // 4. Removing a place that doesn't exist doesn't disturb the ones that do.
    func testRemovingUnknownIDKeepsOtherPlaces() {
        MyPlaceStore.setHome(coordinate: blacksburg)
        MyPlaceStore.remove(id: UUID())
        XCTAssertNotNil(MyPlaceStore.home())
    }

    // 5. A non-home place coexists with Home — the model is ready for
    //    Work/School without a schema rewrite (spec §2).
    func testOtherKindsCoexistWithHome() {
        MyPlaceStore.setHome(coordinate: blacksburg, address: "Home St")
        MyPlaceStore.upsert(MyPlace(kind: .work, address: "Office Rd", coordinate: ashburn))
        XCTAssertEqual(MyPlaceStore.load().count, 2)
        XCTAssertEqual(MyPlaceStore.home()?.address, "Home St")
    }

    // 6. `upsert` can't be used to route around the one-Home invariant.
    func testUpsertOfHomeKindStillCollapsesToOne() {
        MyPlaceStore.setHome(coordinate: blacksburg)
        MyPlaceStore.upsert(MyPlace(kind: .home, coordinate: ashburn))
        XCTAssertEqual(MyPlaceStore.load().filter { $0.kind == .home }.count, 1)
    }

    // MARK: - Decoding

    // 7. A blob written by a LATER build (a kind this one has never heard of)
    //    degrades to .custom instead of failing the array decode and wiping
    //    the user's places (spec §25 — never break old persisted objects).
    func testUnknownKindDecodesAsCustomWithoutLosingTheBlob() throws {
        let json = """
        [{"id":"11111111-1111-1111-1111-111111111111","kind":"boat","label":"Marina",
          "latitude":37.2296,"longitude":-80.4139}]
        """
        UserDefaults(suiteName: LocationCache.appGroup)?
            .set(Data(json.utf8), forKey: MyPlaceStore.storageKey)
        let places = MyPlaceStore.load()
        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places.first?.kind, .custom)
        XCTAssertEqual(places.first?.label, "Marina")
    }

    // 8. A blob with no timestamps and no address still decodes — the fields
    //    were added after the shape existed.
    func testMinimalBlobDecodes() throws {
        let json = """
        [{"id":"22222222-2222-2222-2222-222222222222","kind":"home",
          "latitude":39.0438,"longitude":-77.4874}]
        """
        UserDefaults(suiteName: LocationCache.appGroup)?
            .set(Data(json.utf8), forKey: MyPlaceStore.storageKey)
        let home = MyPlaceStore.home()
        XCTAssertNotNil(home)
        XCTAssertNil(home?.address)
        XCTAssertEqual(home?.label, "Home")   // falls back to the kind's label
    }

    // MARK: - Join origin (the snapshot rule)

    // 9. Joining from Home writes the coordinate as a DECLARED location with
    //    a home origin — the same freshness-exempt channel "I'll be at…" uses,
    //    so the movement stream can't overwrite it.
    func testJoinFromHomeIsRecordedAsADeclaredHomeOrigin() {
        let home = MyPlaceStore.setHome(coordinate: blacksburg, address: "123 Main St")
        LocationCache.save(home.coordinate, isActive: true, isManual: true, origin: home.origin)

        XCTAssertEqual(LocationCache.selfOrigin, .home)
        XCTAssertEqual(LocationCache.loadSelf()?.isManual, true)
        XCTAssertTrue(LocationCache.selfOrigin.isDeclared)
        // Declared coordinates are freshness-exempt while active, so the join
        // stays sendable rather than ageing out of the 5-minute window.
        XCTAssertNotNil(LocationCache.freshSelfCoordinate())
    }

    // 10. THE snapshot rule (spec §11): changing Home tomorrow must not
    //     rewrite the coordinate a meetup already joined with.
    func testChangingHomeDoesNotRewriteAnAlreadyJoinedOrigin() {
        let monday = MyPlaceStore.setHome(coordinate: blacksburg, address: "Monday St")
        LocationCache.save(monday.coordinate, isActive: true, isManual: true, origin: monday.origin)

        // Tuesday: they move.
        MyPlaceStore.setHome(coordinate: ashburn, address: "Tuesday Ave")

        let joined = LocationCache.loadSelf()
        XCTAssertEqual(joined?.latitude ?? 0, blacksburg.latitude, accuracy: 0.0001)
        XCTAssertEqual(joined?.longitude ?? 0, blacksburg.longitude, accuracy: 0.0001)
    }

    // 11. Deleting Home mid-flight leaves the joined meetup intact — the
    //     coordinate was copied, not referenced (spec §20, §28).
    func testDeletingHomeLeavesAJoinedMeetupIntact() {
        let home = MyPlaceStore.setHome(coordinate: blacksburg)
        LocationCache.save(home.coordinate, isActive: true, isManual: true, origin: home.origin)
        MyPlaceStore.removeHome()

        XCTAssertNil(MyPlaceStore.home())
        XCTAssertTrue(LocationCache.isActive)
        XCTAssertEqual(LocationCache.loadSelf()?.latitude ?? 0, blacksburg.latitude, accuracy: 0.0001)
        XCTAssertEqual(LocationCache.selfOrigin, .home)
    }

    // 12. A live-GPS join records `.current`, and a bare "I'll be at…" records
    //     `.custom` — the flag and the origin can never disagree.
    func testOriginFollowsProvenanceWhenUnstated() {
        LocationCache.save(blacksburg, isActive: true)
        XCTAssertEqual(LocationCache.selfOrigin, .current)

        LocationCache.save(ashburn, isActive: true, isManual: true)
        XCTAssertEqual(LocationCache.selfOrigin, .custom)
    }

    // 13. A cached blob from BEFORE origins existed still answers the
    //     question, from the older `isManual` bool (spec §25).
    func testPreOriginBlobDerivesItsOrigin() throws {
        let legacy = """
        {"latitude":37.2296,"longitude":-80.4139,
         "timestamp":\(Date().timeIntervalSinceReferenceDate),"isActive":true,"isManual":true}
        """
        UserDefaults(suiteName: LocationCache.appGroup)?
            .set(Data(legacy.utf8), forKey: "tween.cache.self")
        XCTAssertEqual(LocationCache.selfOrigin, .custom)
        XCTAssertTrue(LocationCache.isActive)
    }

    // 14. An origin string from a LATER build doesn't break the blob.
    func testUnknownOriginStringDegradesInsteadOfFailing() {
        XCTAssertEqual(JoinOrigin(storage: "teleporter"), .current)
        XCTAssertEqual(JoinOrigin(storage: nil), .current)
        XCTAssertEqual(JoinOrigin(storage: "home"), .home)
    }

    // 15. Leaving deactivates a home join, exactly like any other declared
    //     location — a stale declaration must not be re-shared later.
    func testLeavingDeactivatesAHomeJoin() {
        let home = MyPlaceStore.setHome(coordinate: blacksburg)
        LocationCache.save(home.coordinate, isActive: true, isManual: true, origin: .home)
        LocationCache.deactivateSelf()

        XCTAssertFalse(LocationCache.isOptedIn)
        XCTAssertNil(LocationCache.freshSelfCoordinate())
    }

    // MARK: - Privacy

    // 16. Nothing that travels carries the address. A participant built from
    //     Home is a bare coordinate and a display label (spec §18).
    func testAParticipantBuiltFromHomeCarriesNoAddress() throws {
        let home = MyPlaceStore.setHome(coordinate: blacksburg, address: "123 Secret Lane, Blacksburg")
        let me = Participant.localForRanking(name: "Hassan", coordinate: home.coordinate)
        let encoded = try JSONEncoder().encode(me)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains("Secret Lane"))
        XCTAssertFalse(json.contains("address"))
    }

    // 17. The saved-participant snapshot a join writes carries no address
    //     either — the roster is coordinates and names.
    func testTheRosterSnapshotCarriesNoAddress() throws {
        let home = MyPlaceStore.setHome(coordinate: blacksburg, address: "123 Secret Lane")
        LocationCache.saveParticipants([
            Participant.localForRanking(name: "Hassan", coordinate: home.coordinate)
        ])
        let raw = UserDefaults(suiteName: LocationCache.appGroup)?
            .data(forKey: "tween.cache.participants")
        let json = String(decoding: raw ?? Data(), as: UTF8.self)
        XCTAssertFalse(json.isEmpty)
        XCTAssertFalse(json.contains("Secret Lane"))
    }

    // 18. Nor does the bubble payload. A TweenState composed from a home join
    //     contains the coordinate and nothing else about the place.
    func testTheOutgoingPayloadCarriesNoAddress() throws {
        let home = MyPlaceStore.setHome(coordinate: blacksburg, address: "123 Secret Lane")
        let state = TweenState(
            text: "I'm in",
            latitude: home.latitude,
            longitude: home.longitude,
            senderName: "Hassan",
            senderID: TweenIdentity.stableID,
            kind: .participant,
            messageType: .invite,
            participants: [Participant.localForRanking(name: "Hassan", coordinate: home.coordinate)])
        let url = try XCTUnwrap(state.encodedURL(scheme: "https", host: "tween.app"))
        XCTAssertFalse(url.absoluteString.contains("Secret"))
        XCTAssertFalse(url.absoluteString.lowercased().contains("lane"))
        // And the origin KIND stays home too — it's local planning state.
        XCTAssertFalse(url.absoluteString.contains("origin"))
    }
}
