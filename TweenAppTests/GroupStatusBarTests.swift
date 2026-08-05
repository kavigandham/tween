import XCTest
import CoreLocation
import MapKit
@testable import TweenApp

/// The group bar's derivation. These assert on `OnboardingView.groupMembers`,
/// the ACTUAL production function the view calls — not a reimplementation of
/// it. The travel-mode bug shipped precisely because every surface that
/// displayed a mode was inside a view body no test could reach.
final class GroupStatusBarTests: XCTestCase {

    private let localID = "local-1"
    private let localName = "Hassan"

    private func participant(_ id: String, _ name: String,
                             needsRide: Bool = false) -> Participant {
        Participant(id: id, name: name,
                    coordinate: .init(latitude: 37.3, longitude: -121.8),
                    needsRide: needsRide)
    }

    private func spot(_ etas: [ParticipantETA]) -> RankedSpot {
        RankedSpot(item: nil, etas: etas, confidence: 1)
    }

    // 1. The local user is labelled "You" and flagged, peers are not.
    func testLocalUserIsIdentifiedAndLabelled() {
        let members = OnboardingView.groupMembers(
            participants: [participant(localID, localName), participant("p2", "Hamza")],
            focused: nil, plan: MeetupPlan(),
            localID: localID, localName: localName)

        XCTAssertEqual(members.map(\.label), ["You", "Hamza"])
        XCTAssertEqual(members.map(\.isLocal), [true, false])
    }

    // 2. Each person's mode comes from the plan, keyed by THEIR id — the whole
    //    point of the bar. Missing means driving.
    func testModesArePerParticipant() {
        var plan = MeetupPlan()
        plan.setMode(.walking, for: localID)
        plan.setMode(.transit, for: "p2")

        let members = OnboardingView.groupMembers(
            participants: [participant(localID, localName),
                           participant("p2", "Hamza"),
                           participant("p3", "Adam")],
            focused: nil, plan: plan,
            localID: localID, localName: localName)

        XCTAssertEqual(members.map(\.mode), [.walking, .transit, .driving])
    }

    // 3. No ranking yet → no invented time. A fabricated number is the exact
    //    failure this bar exists to make impossible.
    func testNoFocusedSpotYieldsNoTimeRatherThanAGuess() {
        let members = OnboardingView.groupMembers(
            participants: [participant(localID, localName)],
            focused: nil, plan: MeetupPlan(),
            localID: localID, localName: localName)

        XCTAssertNil(members[0].eta)
        XCTAssertFalse(members[0].fromRoute)
    }

    // 4. ETAs match by participant id, not by list position — a roster in a
    //    different order must not transfer one person's time to another.
    func testETAsMatchByIDNotByPosition() {
        let focused = spot([
            ParticipantETA(id: "p2", name: "Hamza", eta: 120, fromRoute: true),
            ParticipantETA(id: localID, name: localName, eta: 600, fromRoute: true),
        ])
        let members = OnboardingView.groupMembers(
            participants: [participant(localID, localName), participant("p2", "Hamza")],
            focused: focused, plan: MeetupPlan(),
            localID: localID, localName: localName)

        XCTAssertEqual(members[0].eta, 600)   // You
        XCTAssertEqual(members[1].eta, 120)   // Hamza
    }

    // 5. A legacy payload carries `id == name`; the bar must still find the
    //    time rather than showing a dash next to a real person.
    func testLegacyNameKeyedETAStillResolves() {
        let focused = spot([
            ParticipantETA(id: "Hamza", name: "Hamza", eta: 300, fromRoute: true)
        ])
        let members = OnboardingView.groupMembers(
            participants: [participant("some-other-id", "Hamza")],
            focused: focused, plan: MeetupPlan(),
            localID: localID, localName: localName)

        XCTAssertEqual(members[0].eta, 300)
    }

    // 6. The "this is a driving number under a transit icon" caveat has to
    //    survive into the row, or the bar repeats the bug it was built to fix.
    func testModeUnavailableCaveatIsCarried() {
        let focused = spot([
            ParticipantETA(id: localID, name: localName, eta: 900,
                           fromRoute: true, modeUnavailable: true)
        ])
        var plan = MeetupPlan()
        plan.setMode(.transit, for: localID)

        let members = OnboardingView.groupMembers(
            participants: [participant(localID, localName)],
            focused: focused, plan: plan,
            localID: localID, localName: localName)

        XCTAssertTrue(members[0].modeUnavailable)
        XCTAssertEqual(members[0].mode, .transit)
    }

    // 7. needsRide rides through, so the bar can show it at a glance.
    func testNeedsRideIsCarried() {
        let members = OnboardingView.groupMembers(
            participants: [participant("p2", "Hamza", needsRide: true)],
            focused: nil, plan: MeetupPlan(),
            localID: localID, localName: localName)

        XCTAssertTrue(members[0].needsRide)
    }

    // 8. First names only — the panel is a few characters wide, and a full
    //    "Belal Elmeswari" pushes the time (the thing you're reading) off it.
    func testLabelsUseFirstNamesOnly() {
        XCTAssertEqual(
            OnboardingView.shortLabels(for: ["Belal Elmeswari", "Hamza Rasheed"]),
            ["Belal", "Hamza"])
    }

    // 9. A possessive from a manual point reads as the person, not the place.
    func testPossessivePlaceNameBecomesTheName() {
        XCTAssertEqual(OnboardingView.shortLabels(for: ["Kavi's place"]), ["Kavi"])
    }

    // 10. Two people sharing a first name each gain an initial — and ONLY then.
    func testSharedFirstNameGainsAnInitial() {
        XCTAssertEqual(
            OnboardingView.shortLabels(for: ["Hamza Rasheed", "Hamza Elmeswari", "Adam Cole"]),
            ["Hamza R.", "Hamza E.", "Adam"])
    }

    // 11. Same first name AND same initial falls back to full names: two rows
    //     that read identically are worse than two long ones.
    func testIdenticalInitialsFallBackToFullNames() {
        XCTAssertEqual(
            OnboardingView.shortLabels(for: ["Sam Rivera", "Sam Ruiz"]),
            ["Sam Rivera", "Sam Ruiz"])
    }

    // 12. A one-word duplicate has no initial to add, so it keeps its name
    //     rather than rendering as "Sam ." — the crash-adjacent formatting bug.
    func testDuplicateSingleWordNamesDoNotProduceADanglingDot() {
        let labels = OnboardingView.shortLabels(for: ["Sam", "Sam"])
        XCTAssertFalse(labels.contains { $0.hasSuffix(" .") })
        XCTAssertEqual(labels, ["Sam", "Sam"])
    }

    // 13. The cycle covers all three and returns to the start.
    func testModeCycleIsClosed() {
        XCTAssertEqual(OnboardingView.nextMode(after: .driving), .transit)
        XCTAssertEqual(OnboardingView.nextMode(after: .transit), .walking)
        XCTAssertEqual(OnboardingView.nextMode(after: .walking), .driving)
    }
}
