import XCTest
import CoreLocation
@testable import TweenApp

/// Arrival Sync's arithmetic and state machine — the half that must be right
/// before any of it touches MapKit, a notification centre or a bubble.
///
/// Every case here is from the spec's own worked examples, so a regression
/// reads as "24 vs 14 no longer gives 10" rather than as an opaque assertion.
final class ArrivalSyncTimingTests: XCTestCase {

    /// Fixed clock. These are pure functions of (`targetArrival`, `travel`,
    /// `now`), so nothing here may depend on wall time.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func arrival(inMinutes minutes: Double) -> Date {
        now.addingTimeInterval(minutes * 60)
    }

    // MARK: - The two headline cases

    func testLongerTripFirstGivesTheOtherPersonSlack() {
        // Hassan 24 min, Shiraaz 14 min → Shiraaz leaves in 10.
        let target = ArrivalSyncTiming.expectedArrival(travelTime: 24 * 60, now: now)
        XCTAssertEqual(target, arrival(inMinutes: 24))
        XCTAssertFalse(ArrivalSyncTiming.shouldLeaveNow(
            targetArrival: target, travelTime: 14 * 60, now: now))
        XCTAssertEqual(ArrivalSyncTiming.leaveInMinutes(
            targetArrival: target, travelTime: 14 * 60, now: now), 10)
        XCTAssertEqual(ArrivalSyncTiming.recommendedDeparture(
            targetArrival: target, travelTime: 14 * 60, now: now), arrival(inMinutes: 10))
    }

    func testShorterTripFirstMeansLeaveNowNotNegativeTime() {
        // Hassan 14 min, Shiraaz 24 min. The naive formula gives -10 minutes;
        // the clamp is the whole point of this case.
        let target = ArrivalSyncTiming.expectedArrival(travelTime: 14 * 60, now: now)
        XCTAssertTrue(ArrivalSyncTiming.shouldLeaveNow(
            targetArrival: target, travelTime: 24 * 60, now: now))
        XCTAssertEqual(ArrivalSyncTiming.delay(
            targetArrival: target, travelTime: 24 * 60, now: now), 0)
        XCTAssertEqual(ArrivalSyncTiming.recommendedDeparture(
            targetArrival: target, travelTime: 24 * 60, now: now), now)
    }

    // MARK: - The tolerance band

    func testEqualTravelTimesMeanLeaveNow() {
        let target = ArrivalSyncTiming.expectedArrival(travelTime: 15 * 60, now: now)
        XCTAssertTrue(ArrivalSyncTiming.shouldLeaveNow(
            targetArrival: target, travelTime: 15 * 60, now: now))
    }

    func testSubMinuteDifferenceMeansLeaveNow() {
        // 15 vs 14.5 → 30 seconds of slack. "Leave in 30 seconds" is not an
        // instruction anyone can act on.
        let target = ArrivalSyncTiming.expectedArrival(travelTime: 15 * 60, now: now)
        XCTAssertEqual(ArrivalSyncTiming.delay(
            targetArrival: target, travelTime: 14.5 * 60, now: now), 30)
        XCTAssertTrue(ArrivalSyncTiming.shouldLeaveNow(
            targetArrival: target, travelTime: 14.5 * 60, now: now))
    }

    func testExactlyAtToleranceIsStillLeaveNow() {
        let target = ArrivalSyncTiming.expectedArrival(travelTime: 16 * 60, now: now)
        // 60 s of slack — the boundary. Inclusive, so the copy never has to
        // render "leave in 1 min" for something indistinguishable from now.
        XCTAssertEqual(ArrivalSyncTiming.delay(
            targetArrival: target, travelTime: 15 * 60, now: now),
                       ArrivalSyncTiming.leaveNowTolerance)
        XCTAssertTrue(ArrivalSyncTiming.shouldLeaveNow(
            targetArrival: target, travelTime: 15 * 60, now: now))
    }

    func testJustBeyondToleranceWaits() {
        let target = ArrivalSyncTiming.expectedArrival(travelTime: 17 * 60, now: now)
        XCTAssertFalse(ArrivalSyncTiming.shouldLeaveNow(
            targetArrival: target, travelTime: 15 * 60, now: now))
        XCTAssertEqual(ArrivalSyncTiming.leaveInMinutes(
            targetArrival: target, travelTime: 15 * 60, now: now), 2)
    }

    func testLargeGap() {
        // 60 vs 10 → leave in 50.
        let target = ArrivalSyncTiming.expectedArrival(travelTime: 60 * 60, now: now)
        XCTAssertEqual(ArrivalSyncTiming.leaveInMinutes(
            targetArrival: target, travelTime: 10 * 60, now: now), 50)
    }

    // MARK: - Invariants

    func testRecommendedDepartureIsNeverBeforeNow() {
        // Sweep well past the target, including a sync whose arrival is long
        // gone — nothing may ever hand the notification layer a past date.
        for minutesPast in stride(from: 0.0, through: 120.0, by: 7.5) {
            let target = now.addingTimeInterval(-minutesPast * 60)
            for travel in [0.0, 60.0, 15 * 60.0, 90 * 60.0] {
                let departure = ArrivalSyncTiming.recommendedDeparture(
                    targetArrival: target, travelTime: travel, now: now)
                XCTAssertGreaterThanOrEqual(departure, now,
                    "target \(minutesPast) min ago, travel \(travel)s produced a past departure")
            }
        }
    }

    func testNegativeTravelTimeIsTreatedAsZero() {
        // Defensive: MapKit has never returned one, but a straight-line
        // fallback fed a bad coordinate could, and it must not push the
        // departure PAST the arrival.
        let target = arrival(inMinutes: 10)
        XCTAssertEqual(ArrivalSyncTiming.recommendedDeparture(
            targetArrival: target, travelTime: -600, now: now), target)
    }

    func testLeaveInMinutesNeverReadsZero() {
        let target = now.addingTimeInterval(ArrivalSyncTiming.leaveNowTolerance + 1)
        XCTAssertEqual(ArrivalSyncTiming.leaveInMinutes(
            targetArrival: target, travelTime: 0, now: now), 1)
    }
}

/// The state machine: who gets a departure time, who stops getting one, and
/// when a stored sync stops being the one we are in.
final class ArrivalSyncStateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let meetingID = "test-conversation"
    private let destination = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

    override func setUp() {
        super.setUp()
        ArrivalSyncStore.clear(key: meetingID)
    }

    override func tearDown() {
        ArrivalSyncStore.clear(key: meetingID)
        super.tearDown()
    }

    private func sync(travelTime: TimeInterval = 24 * 60,
                      version: Int = 1,
                      destination overrideDestination: CLLocationCoordinate2D? = nil,
                      name: String = "Blue Bottle") -> ArrivalSyncState {
        var state = ArrivalSyncState(
            meetingID: meetingID,
            destinationName: name,
            destinationCoordinate: overrideDestination ?? destination,
            targetArrivalTime: ArrivalSyncTiming.expectedArrival(travelTime: travelTime, now: now),
            initiatedBy: "id-hassan",
            initiatedByName: "Hassan",
            createdAt: now,
            version: version)
        state.set(ArrivalParticipantState(participantID: "id-hassan", displayName: "Hassan",
                                          estimatedTravelTime: travelTime,
                                          departureStatus: .departed, departedAt: now))
        state.set(ArrivalParticipantState(participantID: "id-shiraaz", displayName: "Shiraaz"))
        return state
    }

    // MARK: - Per-participant application

    func testApplyingATravelTimeProducesAWaitingDeparture() {
        var state = sync()
        state.apply(travelTime: 14 * 60, for: "id-shiraaz", now: now)
        let shiraaz = try! XCTUnwrap(state.participant("id-shiraaz"))
        XCTAssertEqual(shiraaz.departureStatus, .waiting)
        XCTAssertEqual(shiraaz.recommendedDepartureTime, now.addingTimeInterval(10 * 60))
        XCTAssertEqual(shiraaz.estimatedTravelTime, 14 * 60)
    }

    func testApplyingALongerTravelTimeProducesLeaveNow() {
        var state = sync(travelTime: 14 * 60)
        state.apply(travelTime: 24 * 60, for: "id-shiraaz", now: now)
        let shiraaz = try! XCTUnwrap(state.participant("id-shiraaz"))
        XCTAssertEqual(shiraaz.departureStatus, .leaveNow)
        XCTAssertEqual(shiraaz.recommendedDepartureTime, now)
    }

    func testDepartedParticipantGetsNoRecommendation() {
        var state = sync()
        state.markDeparted("id-shiraaz", at: now)
        state.apply(travelTime: 14 * 60, for: "id-shiraaz", now: now)
        let shiraaz = try! XCTUnwrap(state.participant("id-shiraaz"))
        // The whole point: once you've said you left, Tween stops telling you
        // to leave. `apply` refuses rather than every call site remembering to.
        XCTAssertEqual(shiraaz.departureStatus, .departed)
        XCTAssertNil(shiraaz.recommendedDepartureTime)
        XCTAssertEqual(shiraaz.departedAt, now)
    }

    func testMarkingDepartedClearsAnExistingRecommendation() {
        var state = sync()
        state.apply(travelTime: 14 * 60, for: "id-shiraaz", now: now)
        XCTAssertNotNil(state.participant("id-shiraaz")?.recommendedDepartureTime)
        state.markDeparted("id-shiraaz", at: now)
        XCTAssertNil(state.participant("id-shiraaz")?.recommendedDepartureTime)
    }

    func testPendingExcludesEveryoneWhoHasDeparted() {
        var state = sync()
        // The initiator is departed by construction.
        XCTAssertEqual(state.pending.map(\.participantID), ["id-shiraaz"])
        state.markDeparted("id-shiraaz", at: now)
        XCTAssertTrue(state.pending.isEmpty)
    }

    func testThreePeopleEachGetTheirOwnDepartureFromOneTarget() {
        // Hassan left (24 min out). Shiraaz 14 → 10 min; Khanna 19 → 5 min.
        // No pairwise logic anywhere: one target, N independent subtractions.
        var state = sync(travelTime: 24 * 60)
        state.set(ArrivalParticipantState(participantID: "id-khanna", displayName: "Khanna"))
        state.apply(travelTime: 14 * 60, for: "id-shiraaz", now: now)
        state.apply(travelTime: 19 * 60, for: "id-khanna", now: now)
        XCTAssertEqual(ArrivalSyncTiming.leaveInMinutes(
            targetArrival: state.targetArrivalTime,
            travelTime: 14 * 60, now: now), 10)
        XCTAssertEqual(ArrivalSyncTiming.leaveInMinutes(
            targetArrival: state.targetArrivalTime,
            travelTime: 19 * 60, now: now), 5)
        XCTAssertEqual(state.pending.count, 2)
    }

    // MARK: - Event identity and supersession

    func testTheSameEventTwiceHasTheSameEventID() {
        // What makes arming idempotent: a re-delivered bubble produces a
        // byte-identical id, so the notification request REPLACES rather than
        // stacking a second one.
        XCTAssertEqual(sync().eventID, sync().eventID)
    }

    func testADifferentDepartureHasADifferentEventID() {
        XCTAssertNotEqual(sync(travelTime: 24 * 60).eventID,
                          sync(travelTime: 25 * 60).eventID)
    }

    func testARedeliveredEventDoesNotSupersede() {
        let state = sync(version: 4)
        XCTAssertFalse(state.supersedes(by: sync(version: 4)))
    }

    func testANewerRevisionSupersedes() {
        XCTAssertTrue(sync(version: 4).supersedes(by: sync(version: 5)))
    }

    func testAnOlderRevisionDoesNotSupersede() {
        XCTAssertFalse(sync(version: 5).supersedes(by: sync(version: 4)))
    }

    func testADestinationChangeAlwaysSupersedesEvenAtAnOlderRevision() {
        // The group moved the meetup. Every departure time derived from the
        // old target is wrong, so revision ordering must not protect it.
        let elsewhere = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        XCTAssertTrue(sync(version: 9).supersedes(by: sync(version: 1, destination: elsewhere)))
    }

    // MARK: - Destination invalidation

    func testSyncMatchesItsOwnDestination() {
        XCTAssertTrue(sync().matches(destinationName: "Blue Bottle", coordinate: destination))
    }

    func testSyncMatchesTheSamePlaceMeasuredWithFloatNoise() {
        // Two devices' MapKit results differ in the last decimals; 1e-4° is
        // ~11 m, the epsilon the rest of the app already uses for "same spot".
        let jittered = CLLocationCoordinate2D(latitude: destination.latitude + 0.00001,
                                              longitude: destination.longitude - 0.00001)
        XCTAssertTrue(sync().matches(destinationName: "Blue Bottle", coordinate: jittered))
    }

    func testChangingTheDestinationInvalidatesTheSync() {
        let elsewhere = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        XCTAssertFalse(sync().matches(destinationName: "Blue Bottle", coordinate: elsewhere))
        XCTAssertFalse(sync().matches(destinationName: "Sightglass", coordinate: destination))
    }

    // MARK: - Expiry

    func testASyncWhoseArrivalIsLongPastIsExpired() {
        var state = sync()
        state.targetArrivalTime = now.addingTimeInterval(-(ArrivalSyncTiming.lifetime + 60))
        XCTAssertTrue(state.isExpired(now: now))
    }

    func testALongDriveIsNotExpiredMidTrip() {
        // Anchored to arrival, not creation: 80 minutes into a 90-minute drive
        // is still a live sync.
        var state = sync()
        state.targetArrivalTime = now.addingTimeInterval(10 * 60)
        XCTAssertFalse(state.isExpired(now: now))
    }

    // MARK: - Persistence (survives relaunch; it is just a preference)

    func testStoreRoundTrips() {
        var state = sync()
        state.apply(travelTime: 14 * 60, for: "id-shiraaz", now: now)
        ArrivalSyncStore.save(state, key: meetingID)
        let loaded = try! XCTUnwrap(ArrivalSyncStore.load(key: meetingID))
        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.participant("id-shiraaz")?.recommendedDepartureTime,
                       now.addingTimeInterval(10 * 60))
    }

    func testLoadReapsAnExpiredSync() {
        var state = sync()
        state.targetArrivalTime = Date().addingTimeInterval(-(ArrivalSyncTiming.lifetime + 60))
        ArrivalSyncStore.save(state, key: meetingID)
        XCTAssertNil(ArrivalSyncStore.load(key: meetingID))
        // Reaped, not merely filtered — otherwise every later read pays for it
        // and cleanup paths keep finding a blob to cancel.
        XCTAssertNil(ArrivalSyncStore.stored(key: meetingID))
    }

    func testStoredSeesABlobThatLoadWouldFilter() {
        var state = sync()
        state.targetArrivalTime = Date().addingTimeInterval(-(ArrivalSyncTiming.lifetime + 60))
        ArrivalSyncStore.save(state, key: meetingID)
        // `stored` is what a cancel path reads, so it must see the blob before
        // anything reaps it.
        XCTAssertNotNil(ArrivalSyncStore.stored(key: meetingID))
    }

    func testClearingRemovesTheSync() {
        ArrivalSyncStore.save(sync(), key: meetingID)
        ArrivalSyncStore.clear(key: meetingID)
        XCTAssertNil(ArrivalSyncStore.load(key: meetingID))
    }

    func testDecodingToleratesAFieldAddedLater() throws {
        // The MeetupPoll.decisionSeq lesson: a synthesized decode would throw
        // `keyNotFound` on a blob written by an earlier build and discard a
        // live sync. Every field must be optional on the way in.
        let json = """
        {"meetingID":"\(meetingID)","destinationName":"Blue Bottle",
         "destinationLatitude":37.7749,"destinationLongitude":-122.4194,
         "targetArrivalTime":0,"initiatedBy":"id-hassan","initiatedByName":"Hassan",
         "createdAt":0,"participants":[{"participantID":"id-shiraaz","displayName":"Shiraaz"}]}
        """
        let decoded = try JSONDecoder().decode(ArrivalSyncState.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(decoded.version, 0)
        XCTAssertEqual(decoded.participant("id-shiraaz")?.departureStatus, .waiting)
    }
}
