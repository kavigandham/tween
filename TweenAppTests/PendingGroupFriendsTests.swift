import XCTest
@testable import TweenApp

/// The rollback bookkeeping for "save this meetup as a group". Extracted from
/// `@State` specifically so these cases can be asserted — three consecutive
/// defects lived in this logic while it was unreachable from a test.
final class PendingGroupFriendsTests: XCTestCase {
    private let a = UUID(), b = UUID()

    func testStartsDisarmed() {
        XCTAssertFalse(PendingGroupFriends().isArmed)
        XCTAssertTrue(PendingGroupFriends().ids.isEmpty)
    }

    func testArmRecordsIDs() {
        var pending = PendingGroupFriends()
        XCTAssertTrue(pending.arm([a, b]))
        XCTAssertTrue(pending.isArmed)
        XCTAssertEqual(pending.ids, [a, b])
    }

    /// A second tap re-runs the builder against a roster that already contains
    /// the first tap's friends, so it returns none — overwriting here would
    /// wipe the undo record and strand them permanently.
    func testSecondArmIsRefusedNotOverwritten() {
        var pending = PendingGroupFriends()
        pending.arm([a, b])
        XCTAssertFalse(pending.arm([]), "a re-arm must be refused")
        XCTAssertEqual(pending.ids, [a, b], "the original undo record must survive")
    }

    func testCommitForgetsWithoutDeleting() {
        var pending = PendingGroupFriends()
        pending.arm([a, b])
        pending.commit()
        XCTAssertFalse(pending.isArmed)
        XCTAssertTrue(pending.takeForRollback().isEmpty,
                      "a saved group must never roll its friends back")
    }

    func testTakeReturnsIDsAndDisarms() {
        var pending = PendingGroupFriends()
        pending.arm([a, b])
        XCTAssertEqual(pending.takeForRollback(), [a, b])
        XCTAssertFalse(pending.isArmed)
    }

    /// The bug that shipped twice: the record outliving its flow, so a later
    /// unrelated dismissal deleted friends that by then had addresses and
    /// group memberships.
    func testRollbackCannotFireTwice() {
        var pending = PendingGroupFriends()
        pending.arm([a, b])
        _ = pending.takeForRollback()
        XCTAssertTrue(pending.takeForRollback().isEmpty)
    }

    func testCanReArmAfterCommitOrRollback() {
        var pending = PendingGroupFriends()
        pending.arm([a])
        pending.commit()
        XCTAssertTrue(pending.arm([b]), "a finished flow must not block the next one")
        XCTAssertEqual(pending.ids, [b])
    }
}
