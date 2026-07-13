import XCTest
import MapKit
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

    // 5b. Below the 2-minute grace the numerator clamps at 0 — a low-confidence
    //     guess must never rank ABOVE a real route just because dividing a
    //     negative numerator by a smaller confidence made it more negative.
    func testSubGraceSpotDoesNotRewardLowConfidence() {
        let confident = RankedSpot(etaFromA: 60, etaFromB: 90, confidence: 1.0)
        let guessed = RankedSpot(etaFromA: 60, etaFromB: 90, confidence: 0.5)
        XCTAssertEqual(confident.score, 0, accuracy: 1e-9)
        XCTAssertEqual(guessed.score, 0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(confident.score, guessed.score)
    }

    // MARK: - N-person scoring

    private func etas(_ pairs: [(String, TimeInterval)]) -> [ParticipantETA] {
        pairs.map { ParticipantETA(id: $0.0, name: $0.0, eta: $0.1, fromRoute: true) }
    }

    // worstETA is the max across N participants, not just 2.
    func testWorstETAAcrossThreeParticipants() {
        let spot = RankedSpot(
            item: nil,
            etas: etas([("A", 300), ("B", 480), ("C", 900)]),
            confidence: 1.0
        )
        XCTAssertEqual(spot.worstETA, 900, accuracy: 1e-9)
        XCTAssertEqual(spot.bestETA, 300, accuracy: 1e-9)
        XCTAssertEqual(spot.fairnessSpread, 600, accuracy: 1e-9)
    }

    // A spot where everyone drives roughly equal beats a spot with one big outlier.
    func testFairSpotRanksAheadOfOutlierSpot() {
        let fair = RankedSpot(
            item: nil,
            etas: etas([("A", 480), ("B", 540), ("C", 600)]),
            confidence: 1.0
        )
        let outlier = RankedSpot(
            item: nil,
            etas: etas([("A", 300), ("B", 360), ("C", 1200)]),
            confidence: 1.0
        )
        XCTAssertLessThan(fair.score, outlier.score)
    }

    func testWorstETAAcrossFiveParticipants() {
        let spot = RankedSpot(
            item: nil,
            etas: etas([("A", 300), ("B", 360), ("C", 420), ("D", 480), ("E", 720)]),
            confidence: 1.0
        )
        XCTAssertEqual(spot.worstETA, 720, accuracy: 1e-9)
    }

    // Legacy 2-person init still produces a spot whose etas array has both legs.
    func testLegacyTwoPersonInitPopulatesETAs() {
        let spot = RankedSpot(etaFromA: 480, etaFromB: 600, confidence: 1.0)
        XCTAssertEqual(spot.etas.count, 2)
        XCTAssertEqual(spot.etas[0].eta, 480, accuracy: 1e-9)
        XCTAssertEqual(spot.etas[1].eta, 600, accuracy: 1e-9)
        XCTAssertEqual(spot.worstETA, 600, accuracy: 1e-9)
    }

    // MARK: - Centroid

    func testCentroidOfTwoEqualsMidpoint() {
        let a = CLLocationCoordinate2D(latitude: 38.84, longitude: -77.30)
        let b = CLLocationCoordinate2D(latitude: 38.90, longitude: -77.35)
        let centroid = MapGeometry.centroid(of: [a, b])
        let midpoint = MapGeometry.midpoint(a, b)
        XCTAssertEqual(centroid.latitude, midpoint.latitude, accuracy: 1e-9)
        XCTAssertEqual(centroid.longitude, midpoint.longitude, accuracy: 1e-9)
    }

    func testCentroidOfThreeAveragesAllThree() {
        let coords = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 30, longitude: 60),
            CLLocationCoordinate2D(latitude: 60, longitude: 120)
        ]
        let centroid = MapGeometry.centroid(of: coords)
        XCTAssertEqual(centroid.latitude, 30, accuracy: 1e-9)
        XCTAssertEqual(centroid.longitude, 60, accuracy: 1e-9)
    }

    func testCentroidOfEmptyFallsBackToDefault() {
        let centroid = MapGeometry.centroid(of: [CLLocationCoordinate2D]())
        XCTAssertEqual(centroid.latitude, MapGeometry.defaultCenter.latitude, accuracy: 1e-9)
        XCTAssertEqual(centroid.longitude, MapGeometry.defaultCenter.longitude, accuracy: 1e-9)
    }

    func testCentroidOfParticipantsUsesCoordinates() {
        let participants = [
            Participant(id: "A", name: "A", latitude: 38.0, longitude: -77.0),
            Participant(id: "B", name: "B", latitude: 39.0, longitude: -78.0)
        ]
        let centroid = MapGeometry.centroid(of: participants)
        XCTAssertEqual(centroid.latitude, 38.5, accuracy: 1e-9)
        XCTAssertEqual(centroid.longitude, -77.5, accuracy: 1e-9)
    }

    // MARK: - Cap scaling

    func testRecommendedCapShrinksAsParticipantsGrow() {
        XCTAssertEqual(FairnessRanker.recommendedCap(for: 2), 10)
        XCTAssertEqual(FairnessRanker.recommendedCap(for: 3), 6)
        XCTAssertEqual(FairnessRanker.recommendedCap(for: 5), 4)
        XCTAssertEqual(FairnessRanker.recommendedCap(for: 10), 3)
        // Floor of 3 even for very large groups.
        XCTAssertEqual(FairnessRanker.recommendedCap(for: 50), 3)
    }

    // MARK: - Midpoint bias

    func testRankedScorePrefersMidpointWhenRoutesTie() {
        let participants = [
            Participant(id: "A", name: "A", latitude: 39.0, longitude: -77.55),
            Participant(id: "B", name: "B", latitude: 39.0, longitude: -77.35)
        ]
        let midpoint = mapItem(name: "Central Cafe", latitude: 39.0, longitude: -77.45)
        let offToSide = mapItem(name: "Side Cafe", latitude: 39.0, longitude: -77.25)
        let centralSpot = RankedSpot(
            item: midpoint,
            etas: etas([("A", 900), ("B", 900)]),
            confidence: 1.0)
        let sideSpot = RankedSpot(
            item: offToSide,
            etas: etas([("A", 900), ("B", 900)]),
            confidence: 1.0)

        XCTAssertEqual(centralSpot.score, sideSpot.score, accuracy: 1e-9)
        XCTAssertLessThan(
            FairnessRanker.rankedScore(centralSpot, participants: participants),
            FairnessRanker.rankedScore(sideSpot, participants: participants))
    }

    private func mapItem(name: String, latitude: Double, longitude: Double) -> MKMapItem {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }
}

// MapGeometry is in the host app target via the Shared/ source folder; XCTest
// needs CoreLocation for CLLocationCoordinate2D.
import CoreLocation
