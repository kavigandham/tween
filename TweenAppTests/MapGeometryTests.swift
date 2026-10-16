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
        XCTAssertEqual(region.center.latitude, MapGeometry.defaultCenter.latitude, accuracy: 1e-9)
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

/// The camera-follow rule for live fixes (device report 2026-09-05: a
/// Blacksburg session, then a cold open in Ashburn drew the dot in Ashburn
/// on a map still framed on Blacksburg).
final class CameraReframeTests: XCTestCase {
    private let blacksburg = CLLocationCoordinate2D(latitude: 37.2296, longitude: -80.4139)
    private let ashburn = CLLocationCoordinate2D(latitude: 39.0438, longitude: -77.4874)

    func testFirstLiveFixReframesEvenOverARestoredCoordinate() {
        // savedCoordinate was restored from disk (Blacksburg); the first live
        // fix of the session is Ashburn — the map must follow it.
        XCTAssertTrue(OnboardingView.shouldReframe(
            forFix: ashburn, previous: blacksburg, hasLiveFix: false, awaitingImIn: false))
    }

    func testNoPreviousCoordinateReframes() {
        XCTAssertTrue(OnboardingView.shouldReframe(
            forFix: ashburn, previous: nil, hasLiveFix: true, awaitingImIn: false))
    }

    func testImInReframes() {
        XCTAssertTrue(OnboardingView.shouldReframe(
            forFix: ashburn, previous: ashburn, hasLiveFix: true, awaitingImIn: true))
    }

    func testMovementTickDoesNotReframe() {
        // ~35 m north: a stream tick while the user pans must not yank the map.
        let nudged = CLLocationCoordinate2D(latitude: ashburn.latitude + 0.0003,
                                            longitude: ashburn.longitude)
        XCTAssertFalse(OnboardingView.shouldReframe(
            forFix: nudged, previous: ashburn, hasLiveFix: true, awaitingImIn: false))
    }

    func testJumpAfterBackgroundedTravelReframes() {
        // Stream was live in Blacksburg, app backgrounded for the drive, first
        // fix on resume is Ashburn: a jump far past reframeJumpDistance.
        XCTAssertTrue(OnboardingView.shouldReframe(
            forFix: ashburn, previous: blacksburg, hasLiveFix: true, awaitingImIn: false))
    }
}

/// The jitter floor on the live dot (lag audit 2026-10-15). The host stream is
/// filter-NONE on purpose, so a stationary phone delivers a fix a second; each
/// one used to write `savedCoordinate` inside a spring and re-run the entire
/// home screen. These pin the rule that decides which deliveries are movement.
final class LiveDotJitterTests: XCTestCase {
    private let ashburn = CLLocationCoordinate2D(latitude: 39.0438, longitude: -77.4874)

    /// ~1.1 m per 0.00001° of latitude.
    private func north(_ metres: Double, of coord: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coord.latitude + metres / 111_320.0,
                               longitude: coord.longitude)
    }

    func testStationaryJitterDoesNotMoveTheDot() {
        // Three metres of GPS noise under a ten-metre accuracy request.
        XCTAssertFalse(OnboardingView.shouldMoveLiveDot(
            toFix: north(3, of: ashburn), previous: ashburn,
            hasLiveFix: true, awaitingImIn: false))
    }

    func testIdenticalFixDoesNotMoveTheDot() {
        XCTAssertFalse(OnboardingView.shouldMoveLiveDot(
            toFix: ashburn, previous: ashburn, hasLiveFix: true, awaitingImIn: false))
    }

    func testRealMovementMovesTheDot() {
        // A few paces — past the floor, well under the reframe jump.
        XCTAssertTrue(OnboardingView.shouldMoveLiveDot(
            toFix: north(12, of: ashburn), previous: ashburn,
            hasLiveFix: true, awaitingImIn: false))
    }

    func testFirstLiveFixAlwaysMovesTheDot() {
        // Restored-from-disk coordinate, first live fix of the session: the
        // dot must land on the real one even if it is a metre away.
        XCTAssertTrue(OnboardingView.shouldMoveLiveDot(
            toFix: north(1, of: ashburn), previous: ashburn,
            hasLiveFix: false, awaitingImIn: false))
    }

    func testImInTakesTheExactFix() {
        // An explicit join must use the fix it was granted, not the one eight
        // metres of silence ago — "I'm in" writes that coordinate to the cache
        // and sends it.
        XCTAssertTrue(OnboardingView.shouldMoveLiveDot(
            toFix: north(1, of: ashburn), previous: ashburn,
            hasLiveFix: true, awaitingImIn: true))
    }

    func testNoPreviousCoordinateMovesTheDot() {
        XCTAssertTrue(OnboardingView.shouldMoveLiveDot(
            toFix: ashburn, previous: nil, hasLiveFix: true, awaitingImIn: false))
    }

    /// The floor must stay under the accuracy the stream asks for, or the dot
    /// would lag behind movement the hardware can actually resolve.
    func testFloorIsBelowRequestedAccuracy() {
        XCTAssertLessThanOrEqual(OnboardingView.liveFixJitterFloor, 10)
        XCTAssertLessThan(OnboardingView.liveFixJitterFloor, OnboardingView.reframeJumpDistance)
    }
}
