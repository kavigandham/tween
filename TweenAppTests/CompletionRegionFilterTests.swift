import XCTest
@testable import TweenApp

final class CompletionRegionFilterTests: XCTestCase {

    private struct Row: RegionFilterableCompletion {
        let title: String
        let subtitle: String
    }

    private let texas = CompletionRegionTokens(administrativeArea: "TX", country: "United States")

    func testKeepsLocalPOI() {
        XCTAssertTrue(CompletionRegionFilter.shouldKeep(
            title: "Heritage Coffee",
            subtitle: "7227 Main St, Suite 600, Frisco, TX 75034, United States",
            tokens: texas))
    }

    func testDropsForeignNameMatch() {
        // "unlimited sushi" completions were Philippine restaurants (probe
        // 2026-07-31) — the exact garbage the dropdown must never show.
        XCTAssertFalse(CompletionRegionFilter.shouldKeep(
            title: "Sushi Unlimited",
            subtitle: "La Guardia, Cebu City, 6000 Cebu, Philippines",
            tokens: texas))
    }

    func testDropsOutOfStateSameCountry() {
        XCTAssertFalse(CompletionRegionFilter.shouldKeep(
            title: "Sushi Taku",
            subtitle: "1904 W Division St, Chicago, IL 60622, United States",
            tokens: texas))
    }

    func testDropsForeignAddressStyleTitleWithEmptySubtitle() {
        // "shushi" suggested Shusha, Azerbaijan with an EMPTY subtitle —
        // address-style titles must still pass the token check.
        XCTAssertFalse(CompletionRegionFilter.shouldKeep(
            title: "Shusha, Azerbaijan", subtitle: "", tokens: texas))
    }

    func testKeepsCategoryStyleRows() {
        XCTAssertTrue(CompletionRegionFilter.shouldKeep(
            title: "Coffee", subtitle: "Search Nearby", tokens: texas))
        XCTAssertTrue(CompletionRegionFilter.shouldKeep(
            title: "Tennis Courts", subtitle: "", tokens: texas))
    }

    func testFallsBackToCountryWhenNoAdministrativeArea() {
        let countryOnly = CompletionRegionTokens(administrativeArea: nil, country: "United States")
        XCTAssertTrue(CompletionRegionFilter.shouldKeep(
            title: "Sushi Taku",
            subtitle: "1904 W Division St, Chicago, IL 60622, United States",
            tokens: countryOnly))
        XCTAssertFalse(CompletionRegionFilter.shouldKeep(
            title: "Sushi Unlimited",
            subtitle: "La Guardia, Cebu City, 6000 Cebu, Philippines",
            tokens: countryOnly))
    }

    func testPassesThroughWithoutTokens() {
        let rows = [Row(title: "Sushi Unlimited", subtitle: "Cebu City, Philippines")]
        XCTAssertEqual(CompletionRegionFilter.filter(rows, tokens: nil).count, 1)
    }

    func testFilterAppliesRowRules() {
        let rows = [
            Row(title: "Heritage Coffee", subtitle: "Frisco, TX 75034, United States"),
            Row(title: "Sushi Unlimited", subtitle: "Cebu City, Philippines"),
        ]
        let kept = CompletionRegionFilter.filter(rows, tokens: texas)
        XCTAssertEqual(kept.map(\.title), ["Heritage Coffee"])
    }
}
