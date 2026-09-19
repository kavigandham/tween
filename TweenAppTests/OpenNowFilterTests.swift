import XCTest
import MapKit
@testable import TweenApp

/// The extension's Open Now filter.
///
/// MapKit exposes no opening-hours data in any API (SDK checked through iOS
/// 26.5), but it DOES honour the phrase "open now" inside
/// `naturalLanguageQuery` server-side — verified against a live index in 2026
/// ("coffee" at 2 AM returns closed cafes; "coffee open now" returns the
/// 24-hour ones). That makes the filter a query-construction concern, which is
/// exactly what these cover; the undocumented server behaviour itself can't be
/// unit-tested, and degrades to "unfiltered results" if Apple ever drops it.
final class OpenNowFilterTests: XCTestCase {

    private func qualified(_ query: String, on: Bool) -> String {
        OpenNowFilter.qualified(query, enabled: on)
    }

    func testFilterAppendsThePhraseTheEngineHonours() {
        XCTAssertEqual(qualified("coffee shop", on: true), "coffee shop open now")
        XCTAssertEqual(qualified("restaurant", on: true), "restaurant open now")
    }

    func testFilterOffLeavesTheQueryAlone() {
        XCTAssertEqual(qualified("coffee shop", on: false), "coffee shop")
    }

    /// "coffee open now open now" is a different (worse) query.
    func testPhraseIsNotDoubledWhenAlreadyPresent() {
        XCTAssertEqual(qualified("coffee open now", on: true), "coffee open now")
        XCTAssertEqual(qualified("Coffee Open Now", on: true), "Coffee Open Now")
    }

    /// Every category the extension offers has a text query for the filter to
    /// ride on — the POI engine takes no query text, so a category without one
    /// would silently fall back to unfiltered results.
    func testEveryCategoryHasATextQueryToQualify() {
        for category in MessagesSearchCategory.allCases {
            XCTAssertFalse(category.mapKitQuery.isEmpty, "\(category) has no text query")
            XCTAssertTrue(qualified(category.mapKitQuery, on: true).hasSuffix("open now"),
                          "\(category) can't carry the hours filter")
        }
    }
}
