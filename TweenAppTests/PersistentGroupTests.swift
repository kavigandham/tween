import XCTest
import CoreLocation
@testable import TweenApp

/// Persistent groups: auto-naming, duplicate detection, rename/remove-member,
/// the per-group Tween history, and the migration guarantee that every group
/// saved before any of this existed still decodes and still works.
final class PersistentGroupTests: XCTestCase {

    override func setUp() {
        super.setUp()
        if let defaults = UserDefaults(suiteName: LocationCache.appGroup) {
            for key in defaults.dictionaryRepresentation().keys {
                defaults.removeObject(forKey: key)
            }
        }
        GroupStore.clear()
        FriendRoster.clear()
    }

    // MARK: - Automatic names (spec §15)

    func testTwoNamesJoinWithAnAmpersand() {
        XCTAssertEqual(GroupNaming.suggested(from: ["Hassan", "Shiraaz"]), "Hassan & Shiraaz")
    }

    func testThreeNamesSpellAllThreeOut() {
        XCTAssertEqual(GroupNaming.suggested(from: ["Hassan", "Shiraaz", "Khanna"]),
                       "Hassan, Shiraaz & Khanna")
    }

    func testLargerGroupsCountTheRest() {
        XCTAssertEqual(
            GroupNaming.suggested(from: ["Hassan", "Shiraaz", "Khanna", "Adam", "Omar"]),
            "Hassan, Shiraaz + 3")
    }

    func testOnlyFirstNamesAreUsed() {
        XCTAssertEqual(GroupNaming.suggested(from: ["Hassan Ahmed", "Kavi Gandham"]),
                       "Hassan & Kavi")
    }

    // An unnamed participant travels as "" or a legacy literal "You". Neither
    // may become a group name — the same laundering every display surface
    // applies (name-sanitization lesson).
    func testUnnamedParticipantsNeverWriteYouIntoAGroupName() {
        let name = GroupNaming.suggested(from: ["Hassan", "You"])
        XCTAssertFalse(name.contains("You"))
        XCTAssertEqual(name, "Hassan & Friend")
    }

    func testPossessivePlaceNamesReduceToThePerson() {
        XCTAssertEqual(GroupNaming.suggested(from: ["Kavi's place", "Maya"]), "Kavi & Maya")
    }

    func testEmptyInputStillProducesAUsableName() {
        XCTAssertEqual(GroupNaming.suggested(from: []), "New Group")
    }

    // MARK: - Duplicate detection (spec §17)

    func testTheSameCrewMatchesAnExistingGroup() {
        let a = UUID(), b = UUID(), c = UUID()
        let group = FriendGroup(name: "The Boys", memberIDs: [a, b, c])
        GroupStore.upsert(group)

        // Order is presentation, not identity.
        XCTAssertEqual(GroupStore.group(matching: [c, a, b])?.id, group.id)
    }

    func testASupersetIsADifferentCrew() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        GroupStore.upsert(FriendGroup(name: "The Boys", memberIDs: [a, b, c]))
        XCTAssertNil(GroupStore.group(matching: [a, b, c, d]))
        XCTAssertNil(GroupStore.group(matching: [a, b]))
    }

    func testAnEmptyMembershipMatchesNothing() {
        GroupStore.upsert(FriendGroup(name: "The Boys", memberIDs: [UUID(), UUID()]))
        XCTAssertNil(GroupStore.group(matching: []))
    }

    // MARK: - Membership (spec §16)

    func testRenameKeepsIdentityMembershipAndHistory() {
        let a = UUID(), b = UUID()
        let group = FriendGroup(name: "Old", memberIDs: [a, b],
                                createdAt: Date(),
                                history: [GroupTween(spotName: "Cook Out")])
        GroupStore.upsert(group)
        GroupStore.rename(id: group.id, to: "Roommates")

        let loaded = GroupStore.group(id: group.id)
        XCTAssertEqual(loaded?.name, "Roommates")
        XCTAssertEqual(loaded?.memberIDs, [a, b])
        XCTAssertEqual(loaded?.recentTweens.first?.spotName, "Cook Out")
    }

    func testABlankRenameIsRefusedRatherThanWritten() {
        let group = FriendGroup(name: "The Boys", memberIDs: [UUID()])
        GroupStore.upsert(group)
        GroupStore.rename(id: group.id, to: "   ")
        XCTAssertEqual(GroupStore.group(id: group.id)?.name, "The Boys")
    }

    func testRemovingAMemberLeavesTheFriendInTheRoster() {
        let friend = TweenFriend(name: "Kavi")
        FriendRoster.save([friend])
        let group = FriendGroup(name: "The Boys", memberIDs: [friend.id, UUID()])
        GroupStore.upsert(group)

        GroupStore.removeMember(friend.id, from: group.id)

        XCTAssertFalse(GroupStore.group(id: group.id)?.memberIDs.contains(friend.id) ?? true)
        XCTAssertEqual(FriendRoster.load().count, 1)
    }

    func testDeletingAGroupLeavesTheFriendsAlone() {
        let friend = TweenFriend(name: "Kavi")
        FriendRoster.save([friend])
        let group = FriendGroup(name: "The Boys", memberIDs: [friend.id])
        GroupStore.upsert(group)

        GroupStore.delete(id: group.id)

        XCTAssertNil(GroupStore.group(id: group.id))
        XCTAssertEqual(FriendRoster.load().count, 1)
    }

    func testMembersResolveAgainstTheRosterAndSkipDeletedFriends() {
        let kavi = TweenFriend(name: "Kavi")
        FriendRoster.save([kavi])
        let group = FriendGroup(name: "The Boys", memberIDs: [kavi.id, UUID()])
        XCTAssertEqual(group.members(in: FriendRoster.load()).map(\.name), ["Kavi"])
    }

    // MARK: - History

    func testStartingATweenRecordsIt() {
        let group = FriendGroup(name: "The Boys", memberIDs: [UUID()])
        GroupStore.upsert(group)
        let now = Date()
        GroupStore.noteStarted(id: group.id, at: now)

        XCTAssertEqual(GroupStore.group(id: group.id)?.recentTweens.count, 1)
        XCTAssertEqual(GroupStore.group(id: group.id)?.lastStartedAt, now)
    }

    // Reopening the same group twice in an evening is ONE outing. Without
    // this, every tap of Start would add a row.
    func testReopeningWithinTheSessionWindowDoesNotAddASecondRow() {
        let group = FriendGroup(name: "The Boys", memberIDs: [UUID()])
        GroupStore.upsert(group)
        let now = Date()
        GroupStore.noteStarted(id: group.id, at: now)
        GroupStore.noteStarted(id: group.id, at: now.addingTimeInterval(60))
        XCTAssertEqual(GroupStore.group(id: group.id)?.recentTweens.count, 1)
    }

    func testANewDayIsANewOuting() {
        let group = FriendGroup(name: "The Boys", memberIDs: [UUID()])
        GroupStore.upsert(group)
        let now = Date()
        GroupStore.noteStarted(id: group.id, at: now.addingTimeInterval(-24 * 60 * 60))
        GroupStore.noteStarted(id: group.id, at: now)
        XCTAssertEqual(GroupStore.group(id: group.id)?.recentTweens.count, 2)
    }

    func testPickingASpotNamesTheCurrentOutingRatherThanAddingOne() {
        let group = FriendGroup(name: "The Boys", memberIDs: [UUID()])
        GroupStore.upsert(group)
        let now = Date()
        GroupStore.noteStarted(id: group.id, at: now)
        GroupStore.noteSpot("Cook Out", for: group.id, at: now.addingTimeInterval(300))

        let history = GroupStore.group(id: group.id)?.recentTweens ?? []
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.spotName, "Cook Out")
    }

    func testHistoryIsCapped() {
        let group = FriendGroup(name: "The Boys", memberIDs: [UUID()])
        GroupStore.upsert(group)
        let now = Date()
        for day in 0..<(FriendGroup.historyLimit + 4) {
            GroupStore.noteStarted(id: group.id,
                                   at: now.addingTimeInterval(TimeInterval(day) * 24 * 60 * 60))
        }
        XCTAssertEqual(GroupStore.group(id: group.id)?.recentTweens.count,
                       FriendGroup.historyLimit)
    }

    func testAnOutingWithNoSpotStillHasATitle() {
        XCTAssertEqual(GroupTween().title, "Started a Tween")
        XCTAssertEqual(GroupTween(spotName: "  ").title, "Started a Tween")
        XCTAssertEqual(GroupTween(spotName: "Cook Out").title, "Cook Out")
    }

    // Writes against a group that was deleted mid-flow must be no-ops, never
    // resurrections (spec §28).
    func testHistoryWritesForAMissingGroupDoNothing() {
        let ghost = UUID()
        GroupStore.noteStarted(id: ghost)
        GroupStore.noteSpot("Cook Out", for: ghost)
        GroupStore.rename(id: ghost, to: "Zombie")
        GroupStore.removeMember(UUID(), from: ghost)
        XCTAssertTrue(GroupStore.load().isEmpty)
    }

    // MARK: - Migration (spec §25)

    // A group saved before persistent-group metadata existed — id, name and
    // members only — must decode, resolve members, and be usable.
    func testLegacyGroupJSONDecodesAndStaysUsable() {
        let legacy = """
        [{"id":"33333333-3333-3333-3333-333333333333","name":"the boys",
          "memberIDs":["44444444-4444-4444-4444-444444444444"]}]
        """
        UserDefaults(suiteName: LocationCache.appGroup)?
            .set(Data(legacy.utf8), forKey: GroupStore.storageKey)

        let groups = GroupStore.load()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "the boys")
        XCTAssertNil(groups.first?.createdAt)
        XCTAssertTrue(groups.first?.recentTweens.isEmpty ?? false)

        // …and it can be renamed and given history without being rebuilt.
        let id = try! XCTUnwrap(groups.first?.id)
        GroupStore.rename(id: id, to: "The Boys")
        GroupStore.noteStarted(id: id)
        XCTAssertEqual(GroupStore.group(id: id)?.name, "The Boys")
        XCTAssertEqual(GroupStore.group(id: id)?.recentTweens.count, 1)
    }

    // Duplicate detection must see legacy groups too, or "save this crew"
    // would create a second copy of every group made before this shipped.
    func testDuplicateDetectionSeesLegacyGroups() {
        let member = UUID()
        let legacy = """
        [{"id":"55555555-5555-5555-5555-555555555555","name":"the boys",
          "memberIDs":["\(member.uuidString)"]}]
        """
        UserDefaults(suiteName: LocationCache.appGroup)?
            .set(Data(legacy.utf8), forKey: GroupStore.storageKey)
        XCTAssertEqual(GroupStore.group(matching: [member])?.name, "the boys")
    }

    // MARK: - Save-as-group, end to end

    // The builder still does its job, and the name it produces is the one the
    // editor opens with — so creating a group from a meetup is one decision,
    // not two (spec §14/§15).
    func testAMeetupCrewBecomesANamedGroupWithoutTyping() {
        let participants = [
            Participant(id: "p1", name: "Shiraaz", latitude: 37.3, longitude: -121.8),
            Participant(id: "p2", name: "Khanna", latitude: 37.4, longitude: -121.9)
        ]
        let plan = MeetupGroupBuilder.build(participants: participants, existing: [])
        XCTAssertEqual(plan.memberIDs.count, 2)
        for friend in plan.newFriends { FriendRoster.add(friend) }

        let roster = FriendRoster.load()
        let name = GroupNaming.suggested(from: plan.memberIDs.compactMap { id in
            roster.first { $0.id == id }?.name
        })
        XCTAssertEqual(name, "Shiraaz & Khanna")

        GroupStore.upsert(FriendGroup(name: name, memberIDs: plan.memberIDs, createdAt: Date()))

        // Saving the SAME crew again finds the existing group rather than
        // making a second one.
        XCTAssertEqual(GroupStore.group(matching: plan.memberIDs)?.name, name)
        XCTAssertEqual(GroupStore.load().count, 1)
    }

    // A one-person meetup can't become a group, and doesn't crash trying.
    func testASinglePersonMeetupProducesNoGroup() {
        let plan = MeetupGroupBuilder.build(
            participants: [Participant(id: "p1", name: "Shiraaz", latitude: 37.3, longitude: -121.8)],
            existing: [])
        XCTAssertEqual(plan.memberIDs.count, 1)
        XCTAssertNil(GroupStore.group(matching: plan.memberIDs))
    }
}
