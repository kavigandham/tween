import XCTest
import MapKit
@testable import TweenApp

/// The hard between-people cut on search candidates. MapKit's relevance pulls
/// results toward dense commercial corridors even when the request region is
/// centered on the midpoint (device feedback: two people in a line, every
/// suggested spot off to the right) — this is the filter that guarantees the
/// pool the ranker sees actually sits between the group.
final class SpotVicinityTests: XCTestCase {

    // The reported scenario: two people roughly in a N–S line near Ashburn,
    // ~10 km apart; the off-axis corridor (Chantilly) is ~15+ km from their
    // midpoint and must not be suggested.
    private let north = Participant(
        id: "a", name: "Faaris",
        coordinate: CLLocationCoordinate2D(latitude: 39.05, longitude: -77.49))
    private let south = Participant(
        id: "b", name: "Hassan",
        coordinate: CLLocationCoordinate2D(latitude: 38.97, longitude: -77.54))

    private func item(_ lat: Double, _ lon: Double) -> MKMapItem {
        MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)))
    }

    func testRadiusScalesWithSpread() {
        // ~10 km separation → spread ~5 km → radius 0.75×spread + 2 km ≈ 5.7 km.
        let radius = SpotVicinity.radius(for: [north, south])
        XCTAssertGreaterThan(radius, 4_000)
        XCTAssertLessThan(radius, 8_000)

        // Same-place group floors at 3 km so there's still a usable pool.
        let together = [
            Participant(id: "a", name: "A", coordinate: north.coordinate),
            Participant(id: "b", name: "B", coordinate: north.coordinate)
        ]
        XCTAssertEqual(SpotVicinity.radius(for: together), 3_000, accuracy: 1)
    }

    func testDropsOffAxisCorridorKeepsBetweenSpots() {
        let between1 = item(39.01, -77.51)   // on the line between them
        let between2 = item(39.00, -77.52)
        let between3 = item(39.02, -77.50)
        let corridor1 = item(38.89, -77.43)  // Chantilly-like, ~15 km off-axis
        let corridor2 = item(38.87, -77.42)  // ~17 km

        let kept = SpotVicinity.filter(
            [corridor1, between1, corridor2, between2, between3],
            participants: [north, south], minimumCount: 3)

        XCTAssertEqual(kept.count, 3, "the off-axis corridor spots are cut")
        XCTAssertTrue(kept.allSatisfy { $0.placemark.coordinate.latitude >= 39.0 })
    }

    func testRelaxesWhenBetweenAreaIsSparse() {
        // Only one truly-between spot; two more sit just outside the base
        // radius. Better to relax the cut than return a one-item pool.
        let between = item(39.01, -77.51)
        let fringe1 = item(39.07, -77.46)   // ~7 km from centroid (inside 1.5×)
        let fringe2 = item(38.95, -77.57)   // ~7 km the other way
        let far = item(38.70, -77.20)       // ~40 km — out at every multiplier

        let kept = SpotVicinity.filter(
            [between, fringe1, fringe2, far],
            participants: [north, south], minimumCount: 3)

        XCTAssertEqual(kept.count, 3)
        XCTAssertFalse(kept.contains(far), "relaxation widens the circle, it doesn't open the floodgates")
    }

    func testFallsBackToUnfilteredWhenEverythingIsFar() {
        // A genuinely sparse area: nothing within any multiplier. An empty
        // list helps no one — return the pool and let ranking sort it.
        let far1 = item(38.60, -77.10)
        let far2 = item(39.40, -77.90)
        let kept = SpotVicinity.filter(
            [far1, far2], participants: [north, south], minimumCount: 1)
        XCTAssertEqual(kept.count, 2)
    }

    func testSoloAndEmptyAreNoOps() {
        let spot = item(39.01, -77.51)
        XCTAssertEqual(SpotVicinity.filter([spot], participants: [north], minimumCount: 3).count, 1,
                       "one participant → nothing to be between → untouched")
        XCTAssertTrue(SpotVicinity.filter([], participants: [north, south], minimumCount: 3).isEmpty)
    }
}
