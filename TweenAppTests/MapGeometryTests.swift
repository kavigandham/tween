import XCTest
import CoreLocation
import MapKit
@testable import TweenApp

/// Pure-geometry coverage for the framing math (`MapGeometry`) and the fairness
/// scoring properties on `RankedSpot`. No MapKit network calls — all synchronous.
final class MapGeometryTests: XCTestCase {

    private let sf = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    private let sj = CLLocationCoordinate2D(latitude: 37.3382, longitude: -121.8863)

    // 1. Midpoint is the component-wise average of two coordinates.
    func testMidpointAveragesCoordinates() {
        let mid = MapGeometry.midpoint(sf, sj)
        XCTAssertEqual(mid.latitude, (sf.latitude + sj.latitude) / 2, accuracy: 1e-9)
        XCTAssertEqual(mid.longitude, (sf.longitude + sj.longitude) / 2, accuracy: 1e-9)
    }

    // 2. An empty coordinate list falls back to a bounded neighborhood region.
    func testRegionFallsBackOnEmptyInput() {
        let region = MapGeometry.region(for: [])
        XCTAssertEqual(region.center.latitude, MapGeometry.sanFrancisco.latitude, accuracy: 1e-9)
        XCTAssertEqual(region.span.latitudeDelta, 0.05, accuracy: 1e-9)
        XCTAssertEqual(region.span.longitudeDelta, 0.05, accuracy: 1e-9)
    }

    // 3. A single point gets a minimum span, never a degenerate zero-zoom.
    func testRegionEnforcesMinimumSpanForSinglePoint() {
        let region = MapGeometry.region(for: [sf], minSpan: 0.02)
        XCTAssertGreaterThanOrEqual(region.span.latitudeDelta, 0.02)
        XCTAssertGreaterThanOrEqual(region.span.longitudeDelta, 0.02)
        XCTAssertEqual(region.center.latitude, sf.latitude, accuracy: 1e-9)
    }

    // 4. Two distant points are framed at their center with padded span.
    func testRegionFramesTwoPointsWithPadding() {
        let region = MapGeometry.region(for: [sf, sj], padding: 1.4)
        XCTAssertEqual(region.center.latitude, (sf.latitude + sj.latitude) / 2, accuracy: 1e-6)
        // The padded span exceeds the raw latitude difference.
        XCTAssertGreaterThan(region.span.latitudeDelta, abs(sf.latitude - sj.latitude))
    }

    // 5. worseETA / fairnessGap report the harder drive and the imbalance.
    func testRankedSpotWorseAndGap() {
        let spot = RankedSpot(etaFromA: 600, etaFromB: 900, confidence: 1.0)
        XCTAssertEqual(spot.worseETA, 900, accuracy: 1e-9)
        XCTAssertEqual(spot.fairnessGap, 300, accuracy: 1e-9)
    }

    // 6. Low confidence inflates the ranking score, pushing guesses down.
    func testRankedSpotScorePenalizesLowConfidence() {
        let sure = RankedSpot(etaFromA: 600, etaFromB: 600, confidence: 1.0)
        let guess = RankedSpot(etaFromA: 600, etaFromB: 600, confidence: 0.5)
        XCTAssertGreaterThan(guess.score, sure.score)
    }
}
