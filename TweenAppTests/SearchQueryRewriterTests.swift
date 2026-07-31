import XCTest
@testable import TweenApp

final class SearchQueryRewriterTests: XCTestCase {

    // MARK: - Qualifier stripping

    func testStripsLeadingQualifier() {
        XCTAssertEqual(SearchQueryRewriter.strippedQualifiers(from: "unlimited sushi"), "sushi")
    }

    func testStripsMultiWordQualifier() {
        XCTAssertEqual(SearchQueryRewriter.strippedQualifiers(from: "late night food"), "food")
    }

    func testStripsHyphenatedQualifier() {
        XCTAssertEqual(SearchQueryRewriter.strippedQualifiers(from: "kid-friendly restaurant"), "restaurant")
    }

    func testStripsStackedQualifiers() {
        XCTAssertEqual(SearchQueryRewriter.strippedQualifiers(from: "best cheap eats near me"), "eats")
    }

    func testReturnsNilWhenNothingToStrip() {
        XCTAssertNil(SearchQueryRewriter.strippedQualifiers(from: "sushi"))
    }

    func testReturnsNilWhenOnlyQualifiers() {
        XCTAssertNil(SearchQueryRewriter.strippedQualifiers(from: "best cheap"))
    }

    // MARK: - Spell correction

    func testCorrectsObviousTypo() {
        let corrected = SearchQueryRewriter.spellCorrected("convenicne store")
        XCTAssertNotNil(corrected)
        XCTAssertNotEqual(corrected?.lowercased(), "convenicne store")
    }

    func testLeavesCorrectSpellingAlone() {
        XCTAssertNil(SearchQueryRewriter.spellCorrected("coffee"))
    }

    // MARK: - Rewrite ladder

    func testRewritesNeverContainOriginal() {
        let rewrites = SearchQueryRewriter.rewrites(for: "unlimited sushi")
        XCTAssertFalse(rewrites.contains { $0.caseInsensitiveCompare("unlimited sushi") == .orderedSame })
        XCTAssertEqual(rewrites.first, "sushi")
    }

    func testRewritesEmptyForPlainKnownQuery() {
        XCTAssertTrue(SearchQueryRewriter.rewrites(for: "coffee").isEmpty)
    }

    func testRewritesAreDeduplicated() {
        let rewrites = SearchQueryRewriter.rewrites(for: "best sushi")
        XCTAssertEqual(rewrites, ["sushi"])
    }
}
