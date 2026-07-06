import XCTest
import CoreLocation
@testable import TweenApp

/// Group-session roster semantics: rosters merge additively, removal is only
/// ever an explicit `.leave` by its sender, and departure tombstones keep
/// removals sticky against stale rosters until the person's own rejoin.
/// These invariants are what stop one leave→rejoin from erasing the group.
final class RosterMergeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        if let defaults = UserDefaults(suiteName: LocationCache.appGroup) {
            for key in defaults.dictionaryRepresentation().keys {
                defaults.removeObject(forKey: key)
            }
        }
        LocationCache.clearAll()
    }

    private func person(_ id: String, name: String? = nil,
                        lat: Double = 10, lon: Double = 10) -> Participant {
        Participant(id: id, name: name ?? id, latitude: lat, longitude: lon)
    }

    // MARK: - Additive merge

    func testAbsenceFromIncomingRosterDoesNotRemove() {
        // B rejoins after leaving: their bubble carries only [B]. A and C —
        // whom B's device may not know about — must survive the merge.
        // This is the exact D4 scenario that used to wipe the group.
        let local = [person("A"), person("C")]
        let incoming = [person("B")]
        let merged = RosterMerge.merge(local: local, incoming: incoming,
                                       messageType: .invite,
                                       senderKeys: ["B"], departed: [])
        XCTAssertEqual(Set(merged.map(\.id)), ["A", "B", "C"])
    }

    func testIncomingEntryUpdatesLocalCounterpart() {
        let local = [person("A", lat: 1, lon: 1), person("B")]
        let incoming = [person("A", lat: 2, lon: 3)]
        let merged = RosterMerge.merge(local: local, incoming: incoming,
                                       messageType: .invite,
                                       senderKeys: ["A"], departed: [])
        XCTAssertEqual(merged.count, 2)
        let a = merged.first { $0.id == "A" }
        XCTAssertEqual(a?.latitude, 2)
        XCTAssertEqual(a?.longitude, 3)
    }

    // MARK: - Leave removes its sender, and only its sender

    func testLeaveRemovesOnlyTheSender() {
        let local = [person("A"), person("B"), person("C")]
        let merged = RosterMerge.merge(local: local, incoming: [person("A"), person("C")],
                                       messageType: .leave,
                                       senderKeys: ["B"], departed: [])
        XCTAssertEqual(Set(merged.map(\.id)), ["A", "C"])
    }

    func testLegacyNameKeyedLeaveRemovesNameIdentifiedEntry() {
        // Legacy payloads have no senderID; their roster entries carry the
        // name as the id. A name-keyed tombstone must still catch them.
        let local = [person("Alice"), person("Bob")]
        let merged = RosterMerge.merge(local: local, incoming: [],
                                       messageType: .leave,
                                       senderKeys: RosterMerge.senderKeys(senderID: nil, senderName: "Bob"),
                                       departed: [])
        XCTAssertEqual(merged.map(\.id), ["Alice"])
    }

    // MARK: - Departure tombstones

    func testDepartedParticipantInStaleRosterStaysOut() {
        // B left; C never processed the leave and broadcasts a roster that
        // still lists B. B must not be resurrected by C's message.
        let local = [person("A"), person("C")]
        let incoming = [person("A"), person("B"), person("C")]
        let merged = RosterMerge.merge(local: local, incoming: incoming,
                                       messageType: .invite,
                                       senderKeys: ["C"], departed: ["B"])
        XCTAssertEqual(Set(merged.map(\.id)), ["A", "C"])
    }

    func testDepartedSenderOwnRejoinLiftsTombstone() {
        // B left, then taps "I'm in" again. B's own non-leave message is the
        // explicit rejoin — their tombstone must not filter them out of it.
        let local = [person("A")]
        let incoming = [person("A"), person("B")]
        let merged = RosterMerge.merge(local: local, incoming: incoming,
                                       messageType: .invite,
                                       senderKeys: ["B"], departed: ["B"])
        XCTAssertEqual(Set(merged.map(\.id)), ["A", "B"])
    }

    func testSenderKeysPreferStableIDOverName() {
        XCTAssertEqual(RosterMerge.senderKeys(senderID: "uuid-1", senderName: "Alice"), ["uuid-1"])
        XCTAssertEqual(RosterMerge.senderKeys(senderID: nil, senderName: "Alice"), ["Alice"])
        XCTAssertEqual(RosterMerge.senderKeys(senderID: nil, senderName: nil), [])
    }

    // MARK: - Departure gossip

    func testGossipKeysExcludeRosterMembersAndCap() {
        // A rejoined member (back on the roster) must not be gossiped as
        // gone, and the list is capped for the URL budget.
        let departed = Set((1...20).map { "gone-\($0)" } + ["B"])
        let roster = [person("A"), person("B")]
        let keys = RosterMerge.gossipKeys(departed: departed, roster: roster)
        XCTAssertEqual(keys.count, RosterMerge.gossipCap)
        XCTAssertFalse(keys.contains("B"))
    }

    func testDepartedGossipRoundTripsThroughURL() throws {
        let state = TweenState(
            text: "I'm in",
            latitude: 38.84,
            longitude: -77.30,
            senderName: "Alice",
            senderID: "alice-id",
            kind: .participant,
            messageType: .invite,
            participants: [person("alice-id", name: "Alice")],
            revision: 3,
            departed: ["bob-id", "Cara Née O'Neil"]
        )
        let url = try XCTUnwrap(state.encodedURL())
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.departed, ["bob-id", "Cara Née O'Neil"],
                       "Gossiped tombstones must survive the URL round-trip, punctuation included")
        XCTAssertEqual(decoded.revision, 3)
    }

    func testLegacyURLWithoutGossipDecodesEmpty() throws {
        let state = TweenState(text: "I'm in", latitude: 1, longitude: 1,
                               kind: .participant, messageType: .invite)
        let url = try XCTUnwrap(state.encodedURL())
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertTrue(decoded.departed.isEmpty)
    }

    // MARK: - Departed store round-trip

    func testDepartedStoreUnionAndClear() {
        let key = "roster-merge-test"
        XCTAssertTrue(ConversationMeetupStore.departedParticipants(key: key).isEmpty)
        ConversationMeetupStore.noteDeparted(["B"], key: key)
        ConversationMeetupStore.noteDeparted(["C"], key: key)
        XCTAssertEqual(ConversationMeetupStore.departedParticipants(key: key), ["B", "C"])
        // Rejoin lifts only that participant's tombstone.
        ConversationMeetupStore.clearDeparted(["B"], key: key)
        XCTAssertEqual(ConversationMeetupStore.departedParticipants(key: key), ["C"])
        // No-ops must not create snapshots or throw.
        ConversationMeetupStore.noteDeparted([], key: key)
        ConversationMeetupStore.clearDeparted(["missing"], key: key)
        XCTAssertEqual(ConversationMeetupStore.departedParticipants(key: key), ["C"])
    }

    func testDepartedKeysSurviveSnapshotRoundTrip() {
        let key = "roster-merge-persist"
        ConversationMeetupStore.noteDeparted(["B"], key: key)
        ConversationMeetupStore.saveParticipants([person("A")], key: key)
        XCTAssertEqual(ConversationMeetupStore.departedParticipants(key: key), ["B"],
                       "Unrelated snapshot writes must not drop departure tombstones")
    }
}
