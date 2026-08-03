import XCTest
import MapKit
@testable import TweenApp

final class MeetupPlanTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: LocationCache.appGroup)?
            .removePersistentDomain(forName: LocationCache.appGroup)
        ProEntitlement.setUnlocked(true)
    }

    override func tearDown() {
        MeetupPlanStore.clear()
        ProEntitlement.setUnlocked(false)
        super.tearDown()
    }

    // MARK: Modes

    func testDefaultsToDriving() {
        XCTAssertEqual(MeetupPlan.none.mode(for: "anyone"), .driving)
        XCTAssertFalse(MeetupPlan.none.isMixedMode)
    }

    func testSettingDrivingClearsRatherThanStores() {
        var plan = MeetupPlan()
        plan.setMode(.transit, for: "kavi")
        XCTAssertEqual(plan.modes.count, 1)
        plan.setMode(.driving, for: "kavi")
        XCTAssertTrue(plan.modes.isEmpty, "driving is the default; storing it would bloat every plan")
        XCTAssertEqual(plan.mode(for: "kavi"), .driving)
    }

    func testMixedModeDetection() {
        var plan = MeetupPlan()
        XCTAssertFalse(plan.isMixedMode)
        plan.setMode(.walking, for: "me")
        XCTAssertTrue(plan.isMixedMode)
    }

    func testTransportTypeMapping() {
        XCTAssertEqual(TravelMode.driving.transportType, .automobile)
        XCTAssertEqual(TravelMode.transit.transportType, .transit)
        XCTAssertEqual(TravelMode.walking.transportType, .walking)
    }

    func testWalkingFallbackIsSlowerThanDriving() {
        // A walking leg must never inherit a car's speed — that would rank an
        // hour on foot as a fair ten-minute trip.
        XCTAssertLessThan(TravelMode.walking.fallbackMetresPerSecond,
                          TravelMode.transit.fallbackMetresPerSecond)
        XCTAssertLessThan(TravelMode.transit.fallbackMetresPerSecond,
                          TravelMode.driving.fallbackMetresPerSecond)
    }

    /// The constants test above passed even while the straight-line path
    /// ignored TravelMode entirely and used car speed for everyone. This
    /// asserts on the RANKER's output instead, which is what users see.
    func testStraightLineRankingHonoursTravelMode() async {
        var plan = MeetupPlan()
        plan.setMode(.walking, for: "walker")
        MeetupPlanStore.save(plan)

        // Two people the same distance out, one walking. Far enough that no
        // real route is attempted for the estimate path.
        let spot = MKMapItem(placemark: MKPlacemark(
            coordinate: .init(latitude: 37.7749, longitude: -122.4194)))
        let driver = Participant(id: "driver", name: "Driver",
                                 coordinate: .init(latitude: 37.8199, longitude: -122.4783))
        let walker = Participant(id: "walker", name: "Walker",
                                 coordinate: .init(latitude: 37.8199, longitude: -122.4783))

        let ranked = FairnessRanker.estimatedRankings(candidates: [spot],
                                                      participants: [driver, walker])
        guard let etas = ranked.first?.etas, etas.count == 2 else {
            return XCTFail("expected one spot with two legs")
        }
        let driverETA = etas.first { $0.id == "driver" }?.eta ?? 0
        let walkerETA = etas.first { $0.id == "walker" }?.eta ?? 0
        XCTAssertGreaterThan(walkerETA, driverETA * 3,
                             "same distance on foot must estimate far longer than by car")
    }

    /// Guards CRITICAL #3: a mode is keyed by participant id, so the id the
    /// planning sheet writes must be the id the ranker reads.
    ///
    /// Asserts against `Participant.localForRanking` — the factory the host's
    /// ranking roster actually uses. The previous version of this test wrote
    /// and read `stableID` directly, so it would have stayed green through the
    /// exact regression it names (audit 2026-08-02).
    func testPlanModeLookupUsesTheRankersParticipantIDs() {
        var plan = MeetupPlan()
        // The planning sheet writes modes under the local participant id.
        plan.setMode(.transit, for: TweenIdentity.stableID)
        MeetupPlanStore.save(plan)

        // Built exactly the way the ranking roster builds the local user —
        // deliberately with a display name that differs from the id, so an
        // id-vs-name mixup cannot accidentally pass.
        let asRanked = Participant.localForRanking(
            name: "A Display Name That Is Not The ID",
            coordinate: .init(latitude: 1, longitude: 1))

        XCTAssertNotEqual(asRanked.id, asRanked.name,
                          "the ranker's local id must not be the display name")
        XCTAssertEqual(MeetupPlanStore.current.mode(for: asRanked.id), .transit,
                       "a mode set in the plan must resolve for the participant the ranker uses")

        // And assert the PRODUCTION construction, not just the factory —
        // pinning only the factory left this green when the call site was
        // reverted to an inline `Participant(id: myName, ...)`.
        let roster = OnboardingView.buildRankingParticipants(
            selfCoordinate: .init(latitude: 37.78, longitude: -122.41),
            myName: "A Display Name That Is Not The ID",
            peerCoordinate: .init(latitude: 37.80, longitude: -122.43),
            additional: [],
            manual: [])
        guard let local = roster?.first else {
            return XCTFail("expected the local user first in the ranking roster")
        }
        XCTAssertEqual(MeetupPlanStore.current.mode(for: local.id), .transit,
                       "the roster the ranker actually builds must resolve planned modes")
    }

    // MARK: Leave-by

    func testLeaveByIsArrivalMinusTravel() {
        let arrival = Date(timeIntervalSince1970: 10_000)
        let plan = MeetupPlan(arrivalDate: arrival)
        XCTAssertEqual(plan.leaveBy(travelTime: 600), arrival.addingTimeInterval(-600))
    }

    func testLeaveByIsNilWithoutASchedule() {
        XCTAssertNil(MeetupPlan.none.leaveBy(travelTime: 600))
    }

    func testReminderFiresBeforeLeaveTimeByTheBuffer() {
        let arrival = Date(timeIntervalSince1970: 100_000)
        let fire = LeaveByReminder.fireDate(arrivalDate: arrival, travelTime: 900)
        XCTAssertEqual(fire, arrival.addingTimeInterval(-(900 + LeaveByReminder.bufferSeconds)))
    }

    // MARK: Spot scoping

    func testScheduleIsScopedToItsSpot() {
        var plan = MeetupPlan(arrivalDate: Date().addingTimeInterval(3600))
        plan.spotName = "Blue Bottle Coffee"
        MeetupPlanStore.save(plan)

        XCTAssertTrue(MeetupPlanStore.isScheduled(for: "Blue Bottle Coffee"))
        // The badge must not appear on every other card in the list.
        XCTAssertFalse(MeetupPlanStore.isScheduled(for: "Sightglass Coffee"))
    }

    func testUnscheduledPlanIsNotScheduledForAnySpot() {
        var plan = MeetupPlan()
        plan.setMode(.walking, for: "me")
        MeetupPlanStore.save(plan)
        XCTAssertFalse(MeetupPlanStore.isScheduled(for: "Blue Bottle Coffee"))
    }

    // MARK: Persistence

    func testRoundTripsThroughAppGroup() {
        var plan = MeetupPlan(arrivalDate: Date().addingTimeInterval(3600))
        plan.setMode(.transit, for: "kavi")
        MeetupPlanStore.save(plan)

        let loaded = MeetupPlanStore.current
        XCTAssertTrue(loaded.isScheduled)
        XCTAssertEqual(loaded.mode(for: "kavi"), .transit)
    }

    func testPastArrivalIsDroppedButModesSurvive() {
        var plan = MeetupPlan(arrivalDate: Date().addingTimeInterval(-7200))
        plan.setMode(.walking, for: "me")
        MeetupPlanStore.save(plan)

        let loaded = MeetupPlanStore.current
        XCTAssertFalse(loaded.isScheduled, "yesterday's meetup must not skew today's ranking")
        XCTAssertEqual(loaded.mode(for: "me"), .walking)
    }

    // MARK: Pro gating

    func testPlanIsInertWithoutPro() {
        var plan = MeetupPlan(arrivalDate: Date().addingTimeInterval(3600))
        plan.setMode(.transit, for: "kavi")
        MeetupPlanStore.save(plan)

        ProEntitlement.setUnlocked(false)
        let loaded = MeetupPlanStore.current
        XCTAssertFalse(loaded.isScheduled)
        XCTAssertEqual(loaded.mode(for: "kavi"), .driving,
                       "a lapsed subscription must stop the plan skewing ranking")

        // ...and comes back intact on resubscribe rather than being destroyed.
        ProEntitlement.setUnlocked(true)
        XCTAssertEqual(MeetupPlanStore.current.mode(for: "kavi"), .transit)
    }

    // MARK: Calendar attendee formatting

    func testAttendeeFormatting() {
        XCTAssertEqual(CalendarExport.formatted([]), "")
        XCTAssertEqual(CalendarExport.formatted(["Kavi"]), "Kavi")
        XCTAssertEqual(CalendarExport.formatted(["Kavi", "Hassan"]), "Kavi and Hassan")
        XCTAssertEqual(CalendarExport.formatted(["Kavi", "Hassan", "Sam"]),
                       "Kavi, Hassan, and Sam")
    }
}

// MARK: - Plan coordinate + reopen (added after the 2026-08-03 audit)

final class MeetupPlanCoordinateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: LocationCache.appGroup)?
            .removePersistentDomain(forName: LocationCache.appGroup)
        ProEntitlement.setUnlocked(true)
    }

    override func tearDown() {
        MeetupPlanStore.clear()
        ProEntitlement.setUnlocked(false)
        super.tearDown()
    }

    func testSpotCoordinateRoundTrips() {
        var plan = MeetupPlan(arrivalDate: Date().addingTimeInterval(3600))
        plan.setSpot(name: "Blue Bottle", coordinate: .init(latitude: 37.7749, longitude: -122.4194))
        MeetupPlanStore.save(plan)

        let loaded = MeetupPlanStore.current
        XCTAssertEqual(loaded.spotName, "Blue Bottle")
        XCTAssertEqual(loaded.coordinate?.latitude ?? 0, 37.7749, accuracy: 0.00001)
        XCTAssertEqual(loaded.coordinate?.longitude ?? 0, -122.4194, accuracy: 0.00001)
    }

    /// Plans saved before the coordinate field existed decode with nil rather
    /// than a fabricated location — the refresher and calendar export must be
    /// able to tell "unknown" from "somewhere in Kansas".
    func testPlanWithoutCoordinateDecodesAsNilNotAFallback() {
        var plan = MeetupPlan(arrivalDate: Date().addingTimeInterval(3600))
        plan.spotName = "Somewhere"
        MeetupPlanStore.save(plan)
        XCTAssertNil(MeetupPlanStore.current.coordinate)
    }

    func testClearingASpotClearsItsCoordinate() {
        var plan = MeetupPlan(arrivalDate: Date().addingTimeInterval(3600))
        plan.setSpot(name: "Blue Bottle", coordinate: .init(latitude: 1, longitude: 2))
        plan.setSpot(name: nil, coordinate: nil)
        XCTAssertNil(plan.spotName)
        XCTAssertNil(plan.coordinate)
    }

    /// The refresher bails when the plan changed mid-flight; equality is what
    /// that guard is built on, so it has to actually notice a moved arrival.
    func testPlanEqualityDetectsAMovedArrival() {
        let base = MeetupPlan(arrivalDate: Date(timeIntervalSince1970: 1000),
                              spotName: "A")
        let moved = MeetupPlan(arrivalDate: Date(timeIntervalSince1970: 2000),
                               spotName: "A")
        XCTAssertNotEqual(base, moved)
    }

    func testLeaveNowThresholdIsPastWhenTravelExceedsRemainingTime() {
        // 10 minutes out, a 60-minute drive: the leave-by time is already past,
        // which is the branch that must notify instead of silently no-op.
        let arrival = Date().addingTimeInterval(10 * 60)
        let fire = LeaveByReminder.fireDate(arrivalDate: arrival, travelTime: 60 * 60)
        XCTAssertLessThan(fire, Date())
    }
}
