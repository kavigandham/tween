import XCTest
@testable import TweenApp

/// The shared per-participant ETA display (audit F1): the host used to cap drive
/// times at two people. These lock the label logic that host + extension now
/// both render, so a regression to A/B-only would fail here.
final class SpotETADisplayTests: XCTestCase {

    private func spot(_ etas: [(String, TimeInterval)]) -> RankedSpot {
        RankedSpot(
            item: nil,
            etas: etas.enumerated().map { i, pair in
                ParticipantETA(id: "p\(i)", name: pair.0, eta: pair.1, fromRoute: true)
            },
            confidence: 1.0)
    }

    // MARK: chipItems

    func testChipItemsShowsEveryNameForPair() {
        let items = SpotETADisplay.chipItems(for: spot([("Sam", 480), ("Maya", 720)]))
        XCTAssertEqual(items.map(\.0), ["Sam", "Maya"])
        XCTAssertEqual(items.map(\.1), ["8 min", "12 min"])
    }

    func testChipItemsShowsEveryNameForThree() {
        let items = SpotETADisplay.chipItems(for: spot([("Sam", 480), ("Maya", 600), ("Alex", 720)]))
        XCTAssertEqual(items.map(\.0), ["Sam", "Maya", "Alex"])
    }

    func testChipItemsCollapsesToBestTypicalLongForGroups() {
        let items = SpotETADisplay.chipItems(for:
            spot([("A", 300), ("B", 600), ("C", 900), ("D", 1200)]))
        XCTAssertEqual(items.map(\.0), ["Best", "Typical", "Long"])
        XCTAssertEqual(items.first?.1, "5 min")   // bestETA = 300s
        XCTAssertEqual(items.last?.1, "20 min")   // worstETA = 1200s
    }

    func testChipItemsFallsBackToABWhenEtasEmpty() {
        // The legacy 2-person convenience init leaves `etas` populated, so an
        // explicitly empty list is the only A/B path — assert it still decodes.
        let legacy = RankedSpot(item: nil, etas: [], confidence: 1.0)
        let items = SpotETADisplay.chipItems(for: legacy)
        XCTAssertEqual(items.map(\.0), ["A", "B"])
    }

    // MARK: compactLabel

    func testCompactLabelNamesBothForPair() {
        let label = SpotETADisplay.compactLabel(for: spot([("Sam", 480), ("Maya", 720)]))
        XCTAssertEqual(label, "Sam 8 min · Maya 12 min")
    }

    func testCompactLabelSummarizesGroups() {
        let label = SpotETADisplay.compactLabel(for:
            spot([("A", 300), ("B", 600), ("C", 900)]))
        XCTAssertEqual(label, "3 people · 10 min spread")   // spread = 900-300 = 600s
    }

    // MARK: fairnessCaption

    func testFairnessCaptionEvenPair() {
        XCTAssertEqual(SpotETADisplay.fairnessCaption(for: spot([("Sam", 480), ("Maya", 540)])),
                       "Even split")
    }

    func testFairnessCaptionGroup() {
        let caption = SpotETADisplay.fairnessCaption(for:
            spot([("A", 300), ("B", 600), ("C", 900)]))
        XCTAssertTrue(caption.hasPrefix("Fair for 3"), caption)
    }
}
