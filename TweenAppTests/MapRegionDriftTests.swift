import XCTest
import MapKit
@testable import TweenApp

final class MapRegionDriftTests: XCTestCase {

    private func region(_ lat: Double, _ lon: Double, span: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
    }

    func testSmallNudgeIsNotSignificant() {
        let searched = region(38.85, -77.30, span: 0.3)
        let nudged = region(38.87, -77.32, span: 0.3)
        XCTAssertFalse(MapRegionDrift.isSignificant(from: searched, to: nudged))
    }

    func testPanPastThresholdIsSignificant() {
        let searched = region(38.85, -77.30, span: 0.3)
        // Fairfax → Ashburn-scale move: well past 35% of the span.
        let panned = region(39.04, -77.49, span: 0.3)
        XCTAssertTrue(MapRegionDrift.isSignificant(from: searched, to: panned))
    }

    func testZoomOutRevealsNewArea() {
        let searched = region(38.85, -77.30, span: 0.3)
        let zoomedOut = region(38.85, -77.30, span: 0.6)
        XCTAssertTrue(MapRegionDrift.isSignificant(from: searched, to: zoomedOut))
    }

    func testZoomInPastThresholdIsSignificant() {
        // The "zoom in and more places appear" behavior: a much tighter view
        // deserves a re-search that isn't diluted by the wide pass's cap.
        let searched = region(38.85, -77.30, span: 0.5)
        let zoomedIn = region(38.85, -77.30, span: 0.15)
        XCTAssertTrue(MapRegionDrift.isSignificant(from: searched, to: zoomedIn))
    }

    func testMildZoomInIsNotSignificant() {
        let searched = region(38.85, -77.30, span: 0.3)
        let slightlyIn = region(38.85, -77.30, span: 0.2)
        XCTAssertFalse(MapRegionDrift.isSignificant(from: searched, to: slightlyIn))
    }

    func testClampedSearchRegionBoundsSpan() {
        let continental = OnboardingView.clampedSearchRegion(region(38.85, -77.30, span: 12))
        XCTAssertEqual(continental.span.latitudeDelta, 1.6, accuracy: 0.0001)
        let block = OnboardingView.clampedSearchRegion(region(38.85, -77.30, span: 0.002))
        XCTAssertEqual(block.span.latitudeDelta, 0.05, accuracy: 0.0001)
        let city = OnboardingView.clampedSearchRegion(region(38.85, -77.30, span: 0.4))
        XCTAssertEqual(city.span.latitudeDelta, 0.4, accuracy: 0.0001)
    }
}
