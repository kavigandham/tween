import XCTest
import MapKit
@testable import TweenApp

final class SearchResultMergerTests: XCTestCase {
    func testKeepsSameNamedPlacesAtDifferentCoordinates() {
        let first = item(name: "Coffee Shop", latitude: 38.8977, longitude: -77.0365)
        let second = item(name: "Coffee Shop", latitude: 38.9072, longitude: -77.0369)

        let results = SearchResultMerger.deduped([first, second])

        XCTAssertEqual(results.count, 2)
    }

    func testDropsExactDuplicateCoordinateAndName() {
        let first = item(name: "Coffee Shop", latitude: 38.8977, longitude: -77.0365)
        let duplicate = item(name: "Coffee Shop", latitude: 38.8977, longitude: -77.0365)

        let results = SearchResultMerger.deduped([first, duplicate])

        XCTAssertEqual(results.count, 1)
    }

    func testSmallLocalSetMergesFallbackResults() {
        let local = [
            item(name: "Coffee Shop", latitude: 38.8977, longitude: -77.0365),
            item(name: "Coffee Shop", latitude: 38.9072, longitude: -77.0369)
        ]
        let fallback = [
            local[0],
            item(name: "Bakery Cafe", latitude: 38.9150, longitude: -77.0200),
            item(name: "Espresso Bar", latitude: 38.9250, longitude: -77.0300)
        ]

        let results = SearchResultMerger.merge(local: local, fallback: fallback, minimumCount: 8)

        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results.prefix(2).map(\.name), ["Coffee Shop", "Coffee Shop"])
    }

    func testLargeLocalSetDoesNotAddFallbackNoise() {
        let local = (0..<8).map {
            item(name: "Local \($0)", latitude: 38.0 + Double($0) * 0.001, longitude: -77.0)
        }
        let fallback = [item(name: "Far Match", latitude: 40.0, longitude: -73.0)]

        let results = SearchResultMerger.merge(local: local, fallback: fallback, minimumCount: 8)

        XCTAssertEqual(results.map(\.name), local.map(\.name))
    }

    private func item(name: String, latitude: Double, longitude: Double) -> MKMapItem {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }
}
