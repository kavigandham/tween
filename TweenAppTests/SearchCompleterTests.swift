import XCTest
import MapKit
@testable import TweenApp

/// Phase tracking on the suggestion completer (audit W16): the UI must be
/// able to tell "still searching" from "nothing matched" from "MapKit
/// failed" — before `phase` existed, every empty result set rendered the
/// same endless "Searching nearby..." spinner.
final class SearchCompleterTests: XCTestCase {

    func testPhaseLifecycle() {
        let completer = SearchCompleter()
        XCTAssertEqual(completer.phase, .idle)

        completer.update(query: "cafe")
        XCTAssertEqual(completer.phase, .searching)

        completer.completerDidUpdateResults(MKLocalSearchCompleter())
        XCTAssertEqual(completer.phase, .resolved)

        // Wiping the field returns to idle, not a stale resolved/failed.
        completer.update(query: "   ")
        XCTAssertEqual(completer.phase, .idle)
        XCTAssertTrue(completer.results.isEmpty)
    }

    func testFailureMarksFailedAndClearsResults() {
        let completer = SearchCompleter()
        completer.update(query: "cafe")
        completer.completer(MKLocalSearchCompleter(),
                            didFailWithError: NSError(domain: "test", code: 1))
        XCTAssertEqual(completer.phase, .failed)
        XCTAssertTrue(completer.results.isEmpty)
    }

    @MainActor
    func testDebouncedUpdateShowsSearchingImmediately() {
        let completer = SearchCompleter()
        completer.debouncedUpdate(query: "boba")
        // The spinner must be honest during the 300 ms debounce window,
        // before the completer has even seen the query.
        XCTAssertEqual(completer.phase, .searching)
    }
}
