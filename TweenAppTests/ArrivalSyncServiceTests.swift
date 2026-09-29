import XCTest
import CoreLocation
@testable import TweenApp

/// Arrival Sync's orchestration, minus MapKit.
///
/// Everything here is reachable without a route: who a departure measures legs
/// for, what ends a sync, and what the copy says. The route-dependent halves
/// (`initiate`, `receive`) are covered by the timing and state suites, which
/// test the arithmetic they feed on directly — `FairnessRanker` needs a network
/// and a simulator that can route, so asserting on it here would be asserting
/// on the weather.
final class ArrivalSyncServiceTests: XCTestCase {

    private let meetingID = "test-arrival-service"
    private let destination = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        ArrivalSyncStore.clear(key: meetingID)
    }

    override func tearDown() {
        ArrivalSyncStore.clear(key: meetingID)
        super.tearDown()
    }

    private func person(_ id: String, _ name: String) -> Participant {
        Participant(id: id, name: name, latitude: 37.78, longitude: -122.41)
    }

    private func storedSync(name: String = "Blue Bottle",
                            coordinate: CLLocationCoordinate2D? = nil) -> ArrivalSyncState {
        var state = ArrivalSyncState(
            meetingID: meetingID,
            destinationName: name,
            destinationCoordinate: coordinate ?? destination,
            targetArrivalTime: Date().addingTimeInterval(24 * 60),
            initiatedBy: "id-hassan",
            initiatedByName: "Hassan",
            version: 1)
        state.set(ArrivalParticipantState(participantID: "id-hassan", displayName: "Hassan",
                                          departureStatus: .departed, departedAt: Date()))
        state.set(ArrivalParticipantState(participantID: "id-shiraaz", displayName: "Shiraaz",
                                          estimatedTravelTime: 14 * 60))
        ArrivalSyncStore.save(state, key: meetingID)
        return state
    }

    // MARK: - Who a departure measures

    func testMeasurableParticipantsExcludesTheDepartingUser() {
        let people = [person("id-hassan", "Hassan"), person("id-shiraaz", "Shiraaz")]
        let result = ArrivalSyncService.measurableParticipants(
            people, excluding: "id-hassan", departed: [])
        XCTAssertEqual(result.map(\.id), ["id-shiraaz"])
    }

    func testMeasurableParticipantsExcludesManualPoints() {
        // A `manual:` participant is a typed address or a friend without the
        // app — there is no device to remind, so spending a leg on one wastes
        // the budget on a row nobody can act on.
        let people = [person("id-shiraaz", "Shiraaz"),
                      Participant.manual(label: "Mum's house", coordinate: destination)]
        let result = ArrivalSyncService.measurableParticipants(
            people, excluding: "id-hassan", departed: [])
        XCTAssertEqual(result.map(\.id), ["id-shiraaz"])
    }

    // MARK: - What a departure SEEDS
    //
    // Distinct from what it measures: routing is capped and skips anyone
    // already gone, but the state must still describe the whole group.

    /// The initiator's copy of a sync must list a peer who ALREADY left.
    ///
    /// It used to seed only the measurable set, which excludes them — so the
    /// initiator's state disagreed with every receiver's (those build from
    /// the full roster). `receive`'s "a second person left" branch finds a
    /// departing peer by id; with the row missing it fell through and re-aimed
    /// the whole group off that later departure instead of marking them gone.
    func testSeedIncludesPeersWhoAlreadyDepartedSoEveryDeviceAgrees() {
        var state = ArrivalSyncState(
            meetingID: meetingID,
            destinationName: "Blue Bottle",
            destinationCoordinate: destination,
            targetArrivalTime: now.addingTimeInterval(24 * 60),
            initiatedBy: "id-hassan",
            initiatedByName: "Hassan",
            createdAt: now)

        ArrivalSyncService.seed(
            &state,
            participants: [person("id-shiraaz", "Shiraaz"), person("id-khanna", "Khanna")],
            departingID: "id-hassan",
            departed: ["id-khanna"],
            legs: ["id-shiraaz": 14 * 60],
            now: now)

        XCTAssertEqual(state.participant("id-khanna")?.departureStatus, .departed,
                       "a peer who already left must still be listed, as departed")
        XCTAssertNil(state.participant("id-khanna")?.recommendedDepartureTime,
                     "and must never carry a leave time")
        // 24 min target minus a 14 min leg leaves 10 min in hand.
        XCTAssertEqual(state.participant("id-shiraaz")?.departureStatus, .waiting)
        XCTAssertEqual(state.participant("id-shiraaz")?.recommendedDepartureTime,
                       now.addingTimeInterval(10 * 60))
    }

    /// The seed honours the same manual/self exclusions the measure does, so
    /// the two halves cannot drift into describing different rosters.
    func testSeedSkipsManualPointsAndTheDepartingUser() {
        var state = ArrivalSyncState(
            meetingID: meetingID,
            destinationName: "Blue Bottle",
            destinationCoordinate: destination,
            targetArrivalTime: now.addingTimeInterval(24 * 60),
            initiatedBy: "id-hassan",
            initiatedByName: "Hassan",
            createdAt: now)

        ArrivalSyncService.seed(
            &state,
            participants: [person("id-hassan", "Hassan"),
                           person("id-shiraaz", "Shiraaz"),
                           Participant.manual(label: "Mum's house", coordinate: destination)],
            departingID: "id-hassan",
            departed: [],
            legs: [:],
            now: now)

        XCTAssertEqual(state.participants.map(\.participantID), ["id-shiraaz"])
    }

    // MARK: - Who a departure measures (continued)

    func testMeasurableParticipantsExcludesAnyoneWhoAlreadyLeft() {
        let people = [person("id-shiraaz", "Shiraaz"), person("id-khanna", "Khanna")]
        let result = ArrivalSyncService.measurableParticipants(
            people, excluding: "id-hassan", departed: ["id-khanna"])
        XCTAssertEqual(result.map(\.id), ["id-shiraaz"])
    }

    func testMeasurableParticipantsExcludesUnidentifiableEntries() {
        // An empty id is a failed lookup, not a person (the rule
        // `MeetupPoll.identityKeys` applies) — nothing downstream could file
        // a reminder against it.
        let people = [person("", ""), person("id-shiraaz", "Shiraaz")]
        let result = ArrivalSyncService.measurableParticipants(
            people, excluding: "id-hassan", departed: [])
        XCTAssertEqual(result.map(\.id), ["id-shiraaz"])
    }

    func testMeasurableParticipantsIsCapped() {
        // Each leg is an MKDirections round trip, and this code runs inside the
        // extension's ~120 MB ceiling (constraint 1).
        let people = (0..<20).map { person("id-\($0)", "P\($0)") }
        let result = ArrivalSyncService.measurableParticipants(
            people, excluding: "nobody", departed: [])
        XCTAssertEqual(result.count, ArrivalSyncService.maxMeasuredLegs)
    }

    // MARK: - Ending a sync

    func testCancelClearsTheStoredSync() {
        _ = storedSync()
        XCTAssertNotNil(ArrivalSyncStore.load(key: meetingID))
        ArrivalSyncService.cancel(meetingID: meetingID)
        XCTAssertNil(ArrivalSyncStore.load(key: meetingID))
        XCTAssertNil(ArrivalSyncStore.stored(key: meetingID))
    }

    func testCancelOnAMeetupWithNoSyncIsHarmless() {
        ArrivalSyncService.cancel(meetingID: meetingID)
        XCTAssertNil(ArrivalSyncStore.stored(key: meetingID))
    }

    func testCancelStillReachesAnExpiredSync() {
        // The reason `cancel` reads `stored` and not `load`: an expired sync
        // can still own live notification requests, and reading the
        // expiry-filtering accessor would find nothing and cancel nothing.
        var state = storedSync()
        state.targetArrivalTime = Date().addingTimeInterval(-(ArrivalSyncTiming.lifetime + 60))
        ArrivalSyncStore.save(state, key: meetingID)
        ArrivalSyncService.cancel(meetingID: meetingID)
        XCTAssertNil(ArrivalSyncStore.stored(key: meetingID))
    }

    // MARK: - Destination changes

    func testTheSameDestinationDoesNotInvalidate() {
        _ = storedSync()
        XCTAssertFalse(ArrivalSyncService.invalidateIfDestinationChanged(
            meetingID: meetingID, destinationName: "Blue Bottle", destination: destination))
        XCTAssertNotNil(ArrivalSyncStore.load(key: meetingID))
    }

    func testADifferentDestinationInvalidatesAndClears() {
        _ = storedSync()
        let elsewhere = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        XCTAssertTrue(ArrivalSyncService.invalidateIfDestinationChanged(
            meetingID: meetingID, destinationName: "Sightglass", destination: elsewhere))
        // Every departure time in it was subtracted from an arrival measured
        // to the OLD place, so keeping any of it would be telling people to
        // leave at a time that means nothing.
        XCTAssertNil(ArrivalSyncStore.stored(key: meetingID))
    }

    func testReopeningTheBoardInvalidates() {
        // No settled place at all any more.
        _ = storedSync()
        XCTAssertTrue(ArrivalSyncService.invalidateIfDestinationChanged(
            meetingID: meetingID, destinationName: nil, destination: nil))
        XCTAssertNil(ArrivalSyncStore.stored(key: meetingID))
    }

    func testInvalidationIsANoOpWithNoSync() {
        XCTAssertFalse(ArrivalSyncService.invalidateIfDestinationChanged(
            meetingID: meetingID, destinationName: nil, destination: nil))
    }

    // MARK: - This device departing

    func testNotingALocalDepartureMarksItAndDropsTheRecommendation() {
        _ = storedSync()
        let updated = ArrivalSyncService.noteLocalDeparture(
            meetingID: meetingID, localID: "id-shiraaz", now: now)
        let entry = try! XCTUnwrap(updated?.participant("id-shiraaz"))
        XCTAssertEqual(entry.departureStatus, .departed)
        XCTAssertNil(entry.recommendedDepartureTime)
        XCTAssertEqual(entry.departedAt, now)
        // Persisted, not just returned — the next activation must agree.
        XCTAssertEqual(ArrivalSyncStore.load(key: meetingID)?
            .participant("id-shiraaz")?.departureStatus, .departed)
    }

    func testNotingADepartureForSomeoneNotInTheSyncDoesNothing() {
        _ = storedSync()
        XCTAssertNil(ArrivalSyncService.noteLocalDeparture(
            meetingID: meetingID, localID: "id-stranger"))
    }

    func testNotingADepartureWithNoSyncDoesNothing() {
        XCTAssertNil(ArrivalSyncService.noteLocalDeparture(
            meetingID: meetingID, localID: "id-shiraaz"))
    }
}

/// The notification layer's contracts that do not need a granted
/// authorization: identifier stability (which is what makes duplicate events
/// harmless) and the copy.
final class ArrivalSyncNotifierTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Idempotence

    func testTheSameEventProducesTheSameNotificationIdentifier() {
        // This IS the duplicate-notification guarantee: `add` replaces a
        // pending request with a matching identifier, so re-delivering an
        // event re-arms one reminder instead of stacking a second. Nothing
        // has to remember which events it has seen.
        let first = ArrivalSyncNotifier.reminderIdentifier(meetingID: "m1", participantID: "p1")
        let second = ArrivalSyncNotifier.reminderIdentifier(meetingID: "m1", participantID: "p1")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "arrival-sync-m1-p1")
    }

    func testDifferentPeopleAndMeetupsGetDifferentIdentifiers() {
        let a = ArrivalSyncNotifier.reminderIdentifier(meetingID: "m1", participantID: "p1")
        let b = ArrivalSyncNotifier.reminderIdentifier(meetingID: "m1", participantID: "p2")
        let c = ArrivalSyncNotifier.reminderIdentifier(meetingID: "m2", participantID: "p1")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testTheDepartureNoticeHasItsOwnIdentifierSpace() {
        // Must not collide with the reminder: they are armed at the same
        // moment for the same meetup, and a shared identifier would have the
        // "on the way" notice silently evict the "time to go" it just set.
        XCTAssertNotEqual(
            ArrivalSyncNotifier.reminderIdentifier(meetingID: "m1", participantID: "p1"),
            ArrivalSyncNotifier.departureIdentifier(meetingID: "m1", departingID: "p1"))
    }

    func testTheReminderIdentifierNeverCollidesWithTheLeaveByReminder() {
        // `LeaveByReminder` owns exactly one identifier and can be armed for a
        // scheduled meetup at the same time as an Arrival Sync.
        XCTAssertNotEqual(
            ArrivalSyncNotifier.reminderIdentifier(meetingID: "m1", participantID: "p1"),
            LeaveByReminder.identifier)
    }

    func testSchedulingRefusesAPastDeparture() async {
        // A non-positive interval is refused by the trigger, and rounding it
        // up to a second would fire "time to go" the instant the bubble was
        // opened — duplicating the immediate notice the caller already posted.
        let fired = await ArrivalSyncNotifier.scheduleReminder(
            meetingID: "m1", participantID: "p1",
            departingName: "Hassan", spotName: "Blue Bottle",
            departure: now.addingTimeInterval(-60), now: now)
        XCTAssertNil(fired)
    }

    // MARK: - Copy

    func testTimeToGoCopyMatchesTheSpec() {
        XCTAssertEqual(ArrivalSyncNotifier.timeToGoTitle(), "Time to go 🚗")
        XCTAssertEqual(ArrivalSyncNotifier.timeToGoBody(departingName: "Hassan"),
                       "Leave now to arrive around the same time as Hassan.")
    }

    func testDepartureTitlesNameThePersonAndNeverSuggestTracking() {
        XCTAssertEqual(ArrivalSyncNotifier.onTheWayTitle(departingName: "Hassan"),
                       "Hassan is on the way 🚗")
        XCTAssertEqual(ArrivalSyncNotifier.justLeftTitle(departingName: "Hassan"),
                       "Hassan just left 🚗")
        // The wording rule: ETA, departure, arrival, leave time — never
        // language that implies Tween is watching anyone move.
        for copy in [ArrivalSyncNotifier.onTheWayTitle(departingName: "Hassan"),
                     ArrivalSyncNotifier.justLeftTitle(departingName: "Hassan"),
                     ArrivalSyncNotifier.timeToGoBody(departingName: "Hassan"),
                     ArrivalSyncNotifier.tellThemPrompt(departingName: "Hassan")] {
            for banned in ["track", "Track", "location", "Location", "GPS"] {
                XCTAssertFalse(copy.contains(banned), "\"\(copy)\" contains \(banned)")
            }
        }
    }

    func testTheDepartureNoticeAsksTheReaderToReciprocate() {
        XCTAssertEqual(ArrivalSyncNotifier.tellThemPrompt(departingName: "Hassan"),
                       "Tap to tell Hassan when you leave.")
    }

    // MARK: - Leave lines

    private func sync(travelTime: TimeInterval) -> ArrivalSyncState {
        ArrivalSyncState(meetingID: "m1",
                         destinationName: "Blue Bottle",
                         destinationCoordinate: CLLocationCoordinate2D(latitude: 1, longitude: 1),
                         targetArrivalTime: ArrivalSyncTiming.expectedArrival(
                            travelTime: travelTime, now: now),
                         initiatedBy: "id-hassan",
                         initiatedByName: "Hassan",
                         createdAt: now)
    }

    func testLeaveLineNamesTheMinutes() {
        let entry = ArrivalParticipantState(participantID: "p", displayName: "Shiraaz",
                                            estimatedTravelTime: 14 * 60)
        XCTAssertEqual(
            ArrivalSyncNotifier.leaveLine(for: entry,
                                          targetArrival: sync(travelTime: 24 * 60).targetArrivalTime,
                                          now: now),
            "Shiraaz in 10 min")
    }

    func testLeaveLineSaysNowInsideTheTolerance() {
        let entry = ArrivalParticipantState(participantID: "p", displayName: "Shiraaz",
                                            estimatedTravelTime: 14.5 * 60)
        XCTAssertEqual(
            ArrivalSyncNotifier.leaveLine(for: entry,
                                          targetArrival: sync(travelTime: 15 * 60).targetArrivalTime,
                                          now: now),
            "Shiraaz should leave now")
    }

    func testLeaveLineIsNilForSomeoneWhoAlreadyLeft() {
        let entry = ArrivalParticipantState(participantID: "p", displayName: "Shiraaz",
                                            estimatedTravelTime: 14 * 60,
                                            departureStatus: .departed)
        XCTAssertNil(ArrivalSyncNotifier.leaveLine(
            for: entry, targetArrival: sync(travelTime: 24 * 60).targetArrivalTime, now: now))
    }

    func testLeaveLineIsNilWithoutAMeasuredLeg() {
        let entry = ArrivalParticipantState(participantID: "p", displayName: "Shiraaz")
        XCTAssertNil(ArrivalSyncNotifier.leaveLine(
            for: entry, targetArrival: sync(travelTime: 24 * 60).targetArrivalTime, now: now))
    }

    // MARK: - The departed banner

    func testDepartureStatusWithoutASyncIsJustTheETA() {
        XCTAssertEqual(ArrivalSyncNotifier.departureStatus(sync: nil, seconds: 24 * 60, now: now),
                       "On your way — about 24 min")
    }

    func testDepartureStatusNamesOnePersonsLeaveTime() {
        var state = sync(travelTime: 24 * 60)
        state.set(ArrivalParticipantState(participantID: "id-hassan", displayName: "Hassan",
                                          departureStatus: .departed))
        state.set(ArrivalParticipantState(participantID: "id-shiraaz", displayName: "Shiraaz",
                                          estimatedTravelTime: 14 * 60))
        XCTAssertEqual(
            ArrivalSyncNotifier.departureStatus(sync: state, seconds: 24 * 60, now: now),
            "On your way — about 24 min · Shiraaz in 10 min")
    }

    func testDepartureStatusListsAGroup() {
        var state = sync(travelTime: 24 * 60)
        state.set(ArrivalParticipantState(participantID: "id-hassan", displayName: "Hassan",
                                          departureStatus: .departed))
        state.set(ArrivalParticipantState(participantID: "id-shiraaz", displayName: "Shiraaz",
                                          estimatedTravelTime: 14 * 60))
        state.set(ArrivalParticipantState(participantID: "id-khanna", displayName: "Khanna",
                                          estimatedTravelTime: 19 * 60))
        XCTAssertEqual(
            ArrivalSyncNotifier.departureStatus(sync: state, seconds: 24 * 60, now: now),
            "On your way — about 24 min · leave: Shiraaz in 10 min, Khanna in 5 min")
    }

    func testDepartureStatusIgnoresPeopleWhoHaveAlreadyLeft() {
        var state = sync(travelTime: 24 * 60)
        state.set(ArrivalParticipantState(participantID: "id-hassan", displayName: "Hassan",
                                          departureStatus: .departed))
        state.set(ArrivalParticipantState(participantID: "id-shiraaz", displayName: "Shiraaz",
                                          estimatedTravelTime: 14 * 60,
                                          departureStatus: .departed))
        XCTAssertEqual(
            ArrivalSyncNotifier.departureStatus(sync: state, seconds: 24 * 60, now: now),
            "On your way — about 24 min")
    }
}
