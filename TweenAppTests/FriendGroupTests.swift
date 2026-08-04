import XCTest
import CoreLocation
@testable import TweenApp

/// Pro home bases + groups: roster round-trips, legacy decode, the re-pick
/// id/home-base preservation (post-push audit regression), and GroupStore's
/// atomic CRUD.
final class FriendGroupTests: XCTestCase {

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

    // 1. A friend's home base round-trips through the roster.
    func testHomeBaseRoundTrips() {
        let friend = TweenFriend(name: "Kavi")
        FriendRoster.save([friend])
        FriendRoster.addPlace(id: friend.id,
                              label: "Kavi's place",
                              coordinate: CLLocationCoordinate2D(latitude: 37.33, longitude: -121.89))
        let loaded = FriendRoster.load()
        XCTAssertEqual(loaded.first?.homeBase?.latitude, 37.33)
        XCTAssertEqual(loaded.first?.homeBaseLabel, "Kavi's place")

        FriendRoster.clearHomeBase(id: friend.id)
        XCTAssertNil(FriendRoster.load().first?.homeBase)
    }

    // 2. Pre-home-base roster JSON (no new keys) still decodes.
    func testLegacyFriendJSONDecodesWithoutHomeBase() throws {
        let legacy = #"[{"id":"11111111-1111-1111-1111-111111111111","name":"Maya","handle":"555-0102"}]"#
        UserDefaults(suiteName: LocationCache.appGroup)?
            .set(Data(legacy.utf8), forKey: FriendRoster.storageKey)
        let loaded = FriendRoster.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Maya")
        XCTAssertNil(loaded.first?.homeBase)
    }

    // 3. Re-picking the same contact keeps the row's id AND home base — the
    //    id keys ping history, the home base is a Pro declaration (audit).
    func testContactRepickPreservesIdentityAndHomeBase() {
        let original = TweenFriend(name: "Kavi", contactIdentifier: "CN-1", handle: "555-0101")
        FriendRoster.add(original)
        FriendRoster.addPlace(id: original.id,
                              label: "Kavi's place",
                              coordinate: CLLocationCoordinate2D(latitude: 37.33, longitude: -121.89))
        FriendRoster.addPlace(id: original.id,
                              label: "Work",
                              coordinate: CLLocationCoordinate2D(latitude: 37.44, longitude: -121.99))
        // The picker mints a fresh UUID for the same human.
        FriendRoster.add(TweenFriend(name: "Kavi G", contactIdentifier: "CN-1", handle: "555-0101"))

        let loaded = FriendRoster.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, original.id)
        XCTAssertEqual(loaded.first?.name, "Kavi G")
        XCTAssertEqual(loaded.first?.homeBaseLabel, "Kavi's place")
        // EVERY address, not just the one the legacy columns mirror. Re-picking
        // a saved contact used to collapse the list down to one (audit).
        XCTAssertEqual(loaded.first?.places.map(\.label), ["Kavi's place", "Work"])
    }

    // 4. GroupStore upsert replaces by id; delete removes; order stable.
    func testGroupStoreCRUD() {
        let a = FriendGroup(name: "The crew", memberIDs: [UUID(), UUID()])
        let b = FriendGroup(name: "Book club", memberIDs: [UUID()])
        GroupStore.upsert(a)
        GroupStore.upsert(b)
        XCTAssertEqual(GroupStore.load().map(\.name), ["The crew", "Book club"])

        var renamed = a
        renamed.name = "The boys"
        GroupStore.upsert(renamed)
        XCTAssertEqual(GroupStore.load().map(\.name), ["The boys", "Book club"])

        GroupStore.delete(id: a.id)
        XCTAssertEqual(GroupStore.load().map(\.name), ["Book club"])
    }

    // 5. members(in:) resolves against the roster and drops deleted friends.
    func testGroupMembersDropDeletedFriends() {
        let kavi = TweenFriend(name: "Kavi")
        let maya = TweenFriend(name: "Maya")
        FriendRoster.save([kavi, maya])
        let group = FriendGroup(name: "The crew", memberIDs: [kavi.id, maya.id])

        XCTAssertEqual(group.members(in: FriendRoster.load()).map(\.name), ["Kavi", "Maya"])
        FriendRoster.delete(id: maya.id)
        XCTAssertEqual(group.members(in: FriendRoster.load()).map(\.name), ["Kavi"])
    }
}

// MARK: - Labelled addresses (2026-08-04)

final class FriendPlacesTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: LocationCache.appGroup)?
            .removePersistentDomain(forName: LocationCache.appGroup)
    }

    private func coord(_ lat: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: -122)
    }

    func testAddsSeveralLabelledAddresses() {
        let friend = TweenFriend(name: "Kavi")
        FriendRoster.save([friend])
        FriendRoster.addPlace(id: friend.id, label: "Home", coordinate: coord(37.1))
        FriendRoster.addPlace(id: friend.id, label: "Work", coordinate: coord(37.2))

        let loaded = FriendRoster.load().first
        XCTAssertEqual(loaded?.places.map(\.label), ["Home", "Work"])
    }

    /// Re-using a label replaces that address rather than stacking a second
    /// "Home" the user can't tell apart.
    func testSameLabelReplacesRatherThanDuplicates() {
        let friend = TweenFriend(name: "Kavi")
        FriendRoster.save([friend])
        FriendRoster.addPlace(id: friend.id, label: "Home", coordinate: coord(37.1))
        FriendRoster.addPlace(id: friend.id, label: "home", coordinate: coord(37.9))

        let places = FriendRoster.load().first?.places ?? []
        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places.first?.latitude ?? 0, 37.9, accuracy: 0.001)
    }

    /// Groups need ONE point per person; Home is what people mean by "where
    /// they start from".
    func testGroupsPreferHomeOverOtherAddresses() {
        let friend = TweenFriend(name: "Kavi")
        FriendRoster.save([friend])
        FriendRoster.addPlace(id: friend.id, label: "Work", coordinate: coord(37.2))
        FriendRoster.addPlace(id: friend.id, label: "Home", coordinate: coord(37.1))

        let loaded = FriendRoster.load().first
        XCTAssertEqual(loaded?.primaryPlace?.label, "Home")
        XCTAssertEqual(loaded?.homeBase?.latitude ?? 0, 37.1, accuracy: 0.001)
    }

    /// A roster written before labelled places has only the old columns; it
    /// must still surface as one address rather than none.
    func testLegacyHomeBaseSurfacesAsAPlace() {
        let legacy = TweenFriend(name: "Maya",
                                 homeBaseLatitude: 37.5, homeBaseLongitude: -122,
                                 homeBaseLabel: "Maya's place")
        XCTAssertEqual(legacy.places.map(\.label), ["Maya's place"])
        XCTAssertEqual(legacy.primaryPlace?.latitude ?? 0, 37.5, accuracy: 0.001)
    }

    /// The id a view captured has to be the id the next read produces.
    /// Synthesizing the migrated place with a fresh `UUID()` per read meant
    /// `removePlace` never matched, so an upgrading user's first swipe-to-delete
    /// silently did nothing and the row stayed put (audit 2026-08-04).
    func testMigratedLegacyPlaceHasAStableIDAndCanBeDeleted() {
        let legacy = TweenFriend(name: "Maya",
                                 homeBaseLatitude: 37.5, homeBaseLongitude: -122,
                                 homeBaseLabel: "Maya's place")
        FriendRoster.save([legacy])

        let firstRead = FriendRoster.load().first?.places.first?.id
        let secondRead = FriendRoster.load().first?.places.first?.id
        XCTAssertEqual(firstRead, secondRead)

        FriendRoster.removePlace(id: legacy.id, placeID: firstRead!)
        let loaded = FriendRoster.load().first
        XCTAssertTrue(loaded?.places.isEmpty ?? false)
        XCTAssertNil(loaded?.homeBase)
    }

    func testRemovingTheLastPlaceLeavesNoHomeBase() {
        let friend = TweenFriend(name: "Kavi")
        FriendRoster.save([friend])
        FriendRoster.addPlace(id: friend.id, label: "Home", coordinate: coord(37.1))
        let placeID = FriendRoster.load().first?.places.first?.id
        FriendRoster.removePlace(id: friend.id, placeID: placeID!)

        let loaded = FriendRoster.load().first
        XCTAssertTrue(loaded?.places.isEmpty ?? false)
        XCTAssertNil(loaded?.homeBase)
    }
}
