import XCTest
import MapKit
@testable import TweenApp

final class SearchIntentTests: XCTestCase {

    func testCategoryShapedQueryRoutes() {
        XCTAssertEqual(SearchIntent.poiCategories(for: "coffee"), [.cafe, .bakery])
        XCTAssertEqual(SearchIntent.poiCategories(for: "Pharmacy"), [.pharmacy])
        XCTAssertEqual(SearchIntent.poiCategories(for: "convenience store"), [.foodMarket])
    }

    func testSportsQueriesRouteOnModernOS() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("iOS 18 category taxonomy") }
        XCTAssertEqual(SearchIntent.poiCategories(for: "tennis courts"), [.tennis])
        XCTAssertEqual(SearchIntent.poiCategories(for: "Mini Golf"), [.miniGolf])
        XCTAssertEqual(SearchIntent.poiCategories(for: "bowling"), [.bowling])
    }

    func testContainmentDoesNotRoute() {
        // "vegan breakfast" contains no whole-query category match — routing
        // it to .restaurant would flood the attribute results the text
        // engine resolves well.
        XCTAssertTrue(SearchIntent.poiCategories(for: "vegan breakfast").isEmpty)
        XCTAssertTrue(SearchIntent.poiCategories(for: "sushi").isEmpty)
        XCTAssertTrue(SearchIntent.poiCategories(for: "halal food").isEmpty)
    }

    func testNormalizationHandlesCaseHyphensAndSpacing() {
        XCTAssertEqual(SearchIntent.poiCategories(for: "  Grocery   Store "), [.foodMarket])
    }
}
