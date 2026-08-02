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
        FriendRoster.setHomeBase(id: friend.id,
                                 coordinate: CLLocationCoordinate2D(latitude: 37.33, longitude: -121.89),
                                 label: "Kavi's place")
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
        FriendRoster.setHomeBase(id: original.id,
                                 coordinate: CLLocationCoordinate2D(latitude: 37.33, longitude: -121.89),
                                 label: "Kavi's place")
        // The picker mints a fresh UUID for the same human.
        FriendRoster.add(TweenFriend(name: "Kavi G", contactIdentifier: "CN-1", handle: "555-0101"))

        let loaded = FriendRoster.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, original.id)
        XCTAssertEqual(loaded.first?.name, "Kavi G")
        XCTAssertEqual(loaded.first?.homeBaseLabel, "Kavi's place")
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
