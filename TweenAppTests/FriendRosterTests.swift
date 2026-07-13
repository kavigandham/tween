import XCTest
@testable import TweenApp

/// Coverage of the App Group-backed friend roster. Every test starts from a
/// wiped suite so persistence assertions are deterministic.
final class FriendRosterTests: XCTestCase {

    override func setUp() {
        super.setUp()
        if let defaults = UserDefaults(suiteName: LocationCache.appGroup) {
            for key in defaults.dictionaryRepresentation().keys {
                defaults.removeObject(forKey: key)
            }
        }
        FriendRoster.clear()
    }

    // 1. A fresh suite loads an empty roster.
    func testEmptyLoad() {
        XCTAssertTrue(FriendRoster.load().isEmpty)
    }

    // 2. Two adds persist both and preserve insertion order.
    func testAddTwoPreservesOrder() {
        let ada = TweenFriend(name: "Ada")
        let grace = TweenFriend(name: "Grace")
        FriendRoster.add(ada)
        FriendRoster.add(grace)

        let loaded = FriendRoster.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.name), ["Ada", "Grace"])
    }

    func testAddSameContactRefreshesExistingRow() {
        FriendRoster.add(TweenFriend(name: "Ada", contactIdentifier: "contact-1", handle: "555-0100"))
        FriendRoster.add(TweenFriend(name: "Ada Lovelace", contactIdentifier: "contact-1", handle: "(555) 0100"))

        let loaded = FriendRoster.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Ada Lovelace")
        XCTAssertEqual(loaded.first?.handle, "(555) 0100")
    }

    // 3. Renaming keeps the same id (so ping history stays attached).
    func testRenameKeepsID() {
        let friend = TweenFriend(name: "Ada")
        FriendRoster.add(friend)

        FriendRoster.rename(id: friend.id, to: "Ada Lovelace")

        let loaded = FriendRoster.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, friend.id)
        XCTAssertEqual(loaded.first?.name, "Ada Lovelace")
    }

    // 4. Deleting a friend reduces the count and removes the right one.
    func testDeleteReducesCount() {
        let ada = TweenFriend(name: "Ada")
        let grace = TweenFriend(name: "Grace")
        FriendRoster.add(ada)
        FriendRoster.add(grace)

        FriendRoster.delete(id: ada.id)

        let loaded = FriendRoster.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, grace.id)
    }

    // 5. Clearing empties the roster entirely.
    func testClearEmpties() {
        FriendRoster.add(TweenFriend(name: "Ada"))
        FriendRoster.add(TweenFriend(name: "Grace"))

        FriendRoster.clear()

        XCTAssertTrue(FriendRoster.load().isEmpty)
    }
}
