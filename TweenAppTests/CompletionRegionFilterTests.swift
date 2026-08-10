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

    func testNonUSLocaleKeepsLocalAddressesViaCountry() {
        // Outside the US, subtitles usually omit the administrative area
        // entirely ("12 Rue de Rivoli, Paris, France" vs admin
        // "Île-de-France") — requiring the admin match killed every local
        // suggestion (post-push audit M3). Country carries the filter there.
        let paris = CompletionRegionTokens(administrativeArea: "Île-de-France", country: "France")
        XCTAssertTrue(CompletionRegionFilter.shouldKeep(
            title: "Caf\u{00E9} de Flore",
            subtitle: "172 Boulevard Saint-Germain, Paris, France",
            tokens: paris))
        XCTAssertFalse(CompletionRegionFilter.shouldKeep(
            title: "Sushi Unlimited",
            subtitle: "La Guardia, Cebu City, 6000 Cebu, Philippines",
            tokens: paris))
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

    private let virginia = CompletionRegionTokens(administrativeArea: "VA", country: "United States")

    func testKeepsNamedDistantPlaceViaQuery() {
        // Typing a city's name surfaces it from any state — "Sacramento" from
        // Virginia is a deliberate lookup, not far-away garbage.
        XCTAssertTrue(CompletionRegionFilter.shouldKeep(
            title: "Sacramento",
            subtitle: "Sacramento County, CA, United States",
            tokens: virginia, query: "sacramento"))
    }

    func testStillDropsForeignNameCollisionWithQuery() {
        // "shushi" is NOT a prefix of "Shusha", so the name exemption doesn't
        // fire and the region screen still buries the Azerbaijan collision.
        XCTAssertFalse(CompletionRegionFilter.shouldKeep(
            title: "Shusha", subtitle: "Azerbaijan",
            tokens: virginia, query: "shushi"))
    }

    func testEmptyFallbackShowsDistantWhenNothingLocalMatches() {
        // "sacremento" (typo) has no Virginia footprint AND isn't a name-prefix
        // match, so the screen would empty the dropdown — the fallback shows
        // what MapKit found instead of a blank list (device report 2026-08-10).
        let rows = [Row(title: "Sacramento", subtitle: "Sacramento County, CA, United States")]
        let kept = CompletionRegionFilter.filter(rows, tokens: virginia, query: "sacremento")
        XCTAssertEqual(kept.map(\.title), ["Sacramento"])
    }

    func testFallbackHoldsWhenAnyLocalRowSurvives() {
        // With a real local match present, the anti-garbage screen still fires:
        // typing "shushi" keeps the local sushi place and hides Shusha.
        let rows = [
            Row(title: "Sushi Yama", subtitle: "123 King St, Alexandria, VA, United States"),
            Row(title: "Shusha", subtitle: "Azerbaijan"),
        ]
        let kept = CompletionRegionFilter.filter(rows, tokens: virginia, query: "shushi")
        XCTAssertEqual(kept.map(\.title), ["Sushi Yama"])
    }

    func testIsSearchNearbyRecognisesCategoryRow() {
        XCTAssertTrue(CompletionRegionFilter.isSearchNearby(subtitle: "Search Nearby"))
        XCTAssertTrue(CompletionRegionFilter.isSearchNearby(subtitle: " search nearby "))
        XCTAssertFalse(CompletionRegionFilter.isSearchNearby(subtitle: "Alexandria, VA"))
        XCTAssertFalse(CompletionRegionFilter.isSearchNearby(subtitle: ""))
    }
}
