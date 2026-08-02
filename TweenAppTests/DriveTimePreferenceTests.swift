import XCTest
@testable import TweenApp

final class DriveTimePreferenceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: LocationCache.appGroup)?
            .removePersistentDomain(forName: LocationCache.appGroup)
        DriveTimePreference.maxMinutes = nil
    }

    override func tearDown() {
        DriveTimePreference.maxMinutes = nil
        super.tearDown()
    }

    // MARK: Storage

    func testDefaultsToNoPreference() {
        XCTAssertNil(DriveTimePreference.maxMinutes)
        XCTAssertNil(DriveTimePreference.maxSeconds)
    }

    func testRoundTripsThroughAppGroup() {
        DriveTimePreference.maxMinutes = 20
        XCTAssertEqual(DriveTimePreference.maxMinutes, 20)
        XCTAssertEqual(DriveTimePreference.maxSeconds, 1200)
    }

    func testNilClearsThePreference() {
        DriveTimePreference.maxMinutes = 30
        DriveTimePreference.maxMinutes = nil
        XCTAssertNil(DriveTimePreference.maxMinutes)
    }

    // MARK: Penalty

    func testNoPenaltyWithoutAPreference() {
        XCTAssertEqual(DriveTimePreference.penaltyMultiplier(worstETA: 3600), 1)
        XCTAssertFalse(DriveTimePreference.exceedsLimit(worstETA: 3600))
    }

    func testNoPenaltyUnderTheLimit() {
        DriveTimePreference.maxMinutes = 20
        XCTAssertEqual(DriveTimePreference.penaltyMultiplier(worstETA: 900), 1)
        XCTAssertFalse(DriveTimePreference.exceedsLimit(worstETA: 900))
    }

    func testPenaltyRampsInRatherThanCliffEdging() {
        DriveTimePreference.maxMinutes = 20
        // 1 minute over should barely register — a cliff here would rank a
        // 21-minute spot below a 40-minute one, which is the bug this guards.
        let justOver = DriveTimePreference.penaltyMultiplier(worstETA: 21 * 60)
        let wayOver = DriveTimePreference.penaltyMultiplier(worstETA: 40 * 60)
        XCTAssertGreaterThan(justOver, 1)
        XCTAssertLessThan(justOver, 1.2)
        XCTAssertGreaterThan(wayOver, justOver)
    }

    func testPenaltyIsCapped() {
        DriveTimePreference.maxMinutes = 10
        // A 10x-over spot shouldn't produce an unbounded score.
        let extreme = DriveTimePreference.penaltyMultiplier(worstETA: 100 * 60)
        XCTAssertEqual(extreme, 4, accuracy: 0.001)
    }

    // MARK: Ranking is soft, never a filter

    func testOverLimitSpotIsDemotedButStillRanked() {
        DriveTimePreference.maxMinutes = 20
        let near = RankedSpot(item: nil, etaFromA: 18 * 60, etaFromB: 18 * 60, confidence: 1)
        let far = RankedSpot(item: nil, etaFromA: 35 * 60, etaFromB: 35 * 60, confidence: 1)

        XCTAssertLessThan(near.score, far.score, "closer spot should rank first")
        XCTAssertTrue(far.exceedsDriveLimit)
        XCTAssertFalse(near.exceedsDriveLimit)
        // The point of a soft preference: the far spot still HAS a score, so
        // it stays in the list rather than being filtered out.
        XCTAssertGreaterThan(far.score, 0)
    }

    func testPreferenceDoesNotInvertGenuineOrdering() {
        DriveTimePreference.maxMinutes = 20
        // Both over the limit — the closer one must still win.
        let closer = RankedSpot(item: nil, etaFromA: 25 * 60, etaFromB: 25 * 60, confidence: 1)
        let farther = RankedSpot(item: nil, etaFromA: 45 * 60, etaFromB: 45 * 60, confidence: 1)
        XCTAssertLessThan(closer.score, farther.score)
    }
}
