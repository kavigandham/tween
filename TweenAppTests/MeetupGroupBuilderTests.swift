import XCTest
import CoreLocation
@testable import TweenApp

/// Guards the "save this meetup as a group" mapping. The first version of this
/// logic lived inside a SwiftUI View extension where no test could reach it,
/// and shipped three defects (audit 2026-08-04) — each has a test here.
final class MeetupGroupBuilderTests: XCTestCase {
    private func p(_ name: String) -> Participant {
        Participant(id: UUID().uuidString, name: name,
                    coordinate: .init(latitude: 1, longitude: 2))
    }

    func testCreatesAFriendForEachNewParticipant() {
        let result = MeetupGroupBuilder.build(
            participants: [p("Kavi"), p("Maya")], existing: [])
        XCTAssertEqual(result.newFriends.map(\.name), ["Kavi", "Maya"])
        XCTAssertEqual(result.memberIDs.count, 2)
        XCTAssertEqual(result.skipped, 0)
    }

    func testReusesAnExistingFriendInsteadOfDuplicating() {
        let kavi = TweenFriend(name: "Kavi")
        let result = MeetupGroupBuilder.build(
            participants: [p("Kavi"), p("Maya")], existing: [kavi])
        XCTAssertEqual(result.newFriends.map(\.name), ["Maya"])
        XCTAssertEqual(result.memberIDs.first, kavi.id)
        XCTAssertEqual(result.memberIDs.count, 2)
    }

    func testMatchingIgnoresCaseAndDiacritics() {
        let existing = TweenFriend(name: "José")
        let result = MeetupGroupBuilder.build(
            participants: [p("jose")], existing: [existing])
        XCTAssertTrue(result.newFriends.isEmpty, "should reuse, not duplicate")
        XCTAssertEqual(result.memberIDs, [existing.id])
    }

    // MARK: The three defects this exists to prevent

    /// DEFECT 1: the roster snapshot was read once outside the loop, so two
    /// same-named participants both failed the "already a friend?" guard and
    /// both got added.
    func testSameNamedParticipantsDoNotCreateDuplicateFriends() {
        let result = MeetupGroupBuilder.build(
            participants: [p("Kavi"), p("Kavi")], existing: [])
        XCTAssertEqual(result.newFriends.count, 1,
                       "the second Kavi must see the friend the first one created")
        XCTAssertEqual(result.memberIDs.count, 1,
                       "and must not appear twice in the group")
    }

    /// DEFECT 2: raw participant names were stored, but an unnamed sender
    /// travels as the literal fallback ("You") or empty — which every display
    /// surface launders to "Friend". Storing those puts rows in the roster that
    /// identify nobody and can never be told apart.
    func testUnnamedParticipantsAreSkippedNotStoredAsYouOrFriend() {
        let result = MeetupGroupBuilder.build(
            participants: [p("Kavi"), p("You"), p(""), p("  ")], existing: [])
        XCTAssertEqual(result.newFriends.map(\.name), ["Kavi"])
        XCTAssertEqual(result.skipped, 3)
        XCTAssertFalse(result.newFriends.contains { $0.name == "You" })
        XCTAssertFalse(result.newFriends.contains { $0.name == "Friend" })
    }

    /// DEFECT 3: duplicates were mapped back to the FIRST match, so "save these
    /// 2 as a group" produced a 1-member group plus 2 orphan friends. The
    /// member list must stay deduped AND in order.
    func testMemberIDsAreDedupedAndOrderPreserving() {
        let a = TweenFriend(name: "Ann")
        let b = TweenFriend(name: "Bo")
        let result = MeetupGroupBuilder.build(
            participants: [p("Bo"), p("Ann"), p("Bo")], existing: [a, b])
        XCTAssertEqual(result.memberIDs, [b.id, a.id])
    }

    /// The MIXED case: some participants already friends, some new, with a
    /// repeat spanning both. With `existing: []` this assertion is structurally
    /// guaranteed and proves nothing — that version was near-tautological
    /// (audit 2026-08-04).
    func testEveryMemberIDResolvesAcrossExistingAndNewFriends() {
        let ann = TweenFriend(name: "Ann")
        let result = MeetupGroupBuilder.build(
            participants: [p("Ann"), p("Bo"), p("ann"), p("Cy")],
            existing: [ann])

        XCTAssertEqual(result.newFriends.map(\.name), ["Bo", "Cy"])
        XCTAssertEqual(result.memberIDs.count, 3, "Ann must appear once, not twice")
        XCTAssertEqual(result.memberIDs.first, ann.id)

        // Every id must resolve against the roster as it will exist after the
        // new friends are added — a member id with nothing behind it makes a
        // silently smaller group.
        let pool = [ann] + result.newFriends
        for id in result.memberIDs {
            XCTAssertTrue(pool.contains { $0.id == id })
        }
    }
}
