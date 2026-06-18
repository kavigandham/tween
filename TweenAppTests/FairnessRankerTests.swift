import XCTest
@testable import TweenApp

/// Pure, network-free coverage of the fairness math. Every spot is built with
/// the test-only initializer (raw ETAs, no `MKMapItem`), so nothing here touches
/// `MKDirections`.
final class FairnessRankerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Start every test from a clean App Group suite.
        if let defaults = UserDefaults(suiteName: LocationCache.appGroup) {
            for key in defaults.dictionaryRepresentation().keys {
                defaults.removeObject(forKey: key)
            }
        }
        LocationCache.clearAll()
    }

    // 1. worseETA is the larger of the two drives.
    func testWorseETAIsMax() {
        let spot = RankedSpot(etaFromA: 480, etaFromB: 600, confidence: 1.0)
        XCTAssertEqual(spot.worseETA, 600, accuracy: 1e-9)
    }

    // 2. fairnessGap is the absolute difference of the two drives.
    func testFairnessGapIsAbsoluteDifference() {
        let spot = RankedSpot(etaFromA: 600, etaFromB: 480, confidence: 1.0)
        XCTAssertEqual(spot.fairnessGap, 120, accuracy: 1e-9)
        // Order of the legs must not change the gap.
        let swapped = RankedSpot(etaFromA: 480, etaFromB: 600, confidence: 1.0)
        XCTAssertEqual(swapped.fairnessGap, 120, accuracy: 1e-9)
    }

    // 3. score = (worseETA - 120) / confidence.
    func testScoreFormula() {
        let spot = RankedSpot(etaFromA: 480, etaFromB: 600, confidence: 1.0)
        XCTAssertEqual(spot.score, (600 - 120) / 1.0, accuracy: 1e-9)
    }

    // 4. A lower score sorts ahead of a higher one.
    func testLowerScoreRanksFirst() {
        let near = RankedSpot(etaFromA: 300, etaFromB: 360, confidence: 1.0)
        let far = RankedSpot(etaFromA: 900, etaFromB: 960, confidence: 1.0)
        let sorted = [far, near].sorted { $0.score < $1.score }
        XCTAssertEqual(sorted.first?.id, near.id)
        XCTAssertLessThan(near.score, far.score)
    }

    // 5. Lower confidence penalizes the score (ranks the spot worse) for an
    //    otherwise identical trip.
    func testLowConfidencePenalizesScore() {
        let confident = RankedSpot(etaFromA: 480, etaFromB: 600, confidence: 1.0)
        let guessed = RankedSpot(etaFromA: 480, etaFromB: 600, confidence: 0.5)
        XCTAssertGreaterThan(guessed.score, confident.score)
        XCTAssertEqual(guessed.score, confident.score * 2, accuracy: 1e-9)
    }
}
