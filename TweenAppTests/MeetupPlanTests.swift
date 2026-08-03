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

    /// Guards CRITICAL #3 from the audit: a mode is keyed by participant id, so
    /// the id the planning sheet writes must be the id the ranker reads.
    func testPlanModeLookupUsesTheRankersParticipantIDs() {
        var plan = MeetupPlan()
        plan.setMode(.transit, for: TweenIdentity.stableID)
        MeetupPlanStore.save(plan)

        // The host app's ranking roster identifies the local user this way.
        let localAsRanked = Participant(id: TweenIdentity.stableID,
                                        name: "Whatever Display Name",
                                        coordinate: .init(latitude: 1, longitude: 1))
        XCTAssertEqual(MeetupPlanStore.current.mode(for: localAsRanked.id), .transit,
                       "modes keyed by stableID must resolve for the ranker's local participant")
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
