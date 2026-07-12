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

    func testChipItemsShowsEveryNameUpToSix() {
        // Device feedback: show each person's OWN time, not Best/Typical/Long.
        let items = SpotETADisplay.chipItems(for:
            spot([("A", 300), ("B", 600), ("C", 900), ("D", 1200)]))
        XCTAssertEqual(items.map(\.0), ["A", "B", "C", "D"])
        XCTAssertEqual(items.first?.1, "5 min")   // 300s
        XCTAssertEqual(items.last?.1, "20 min")   // 1200s
    }

    func testChipItemsCollapsesOnlyForVeryLargeGroups() {
        let big = spot((1...8).map { ("P\($0)", TimeInterval($0 * 120)) })
        let items = SpotETADisplay.chipItems(for: big)
        XCTAssertEqual(items.count, 6)                       // 5 fastest + a count
        XCTAssertEqual(items.last?.0, "+3 more")
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

    func testCompactLabelSummarizesGroupsWithPlainFairness() {
        // No "X min spread" jargon (device feedback) — a plain word instead.
        let label = SpotETADisplay.compactLabel(for:
            spot([("A", 300), ("B", 600), ("C", 900)]))
        XCTAssertEqual(label, "3 people · Fair")   // spread 600s → "Fair"
    }

    // MARK: fairness language (no "spread")

    func testFairnessCaptionIsPlainLanguage() {
        XCTAssertEqual(SpotETADisplay.fairnessCaption(for: spot([("Sam", 480), ("Maya", 540)])),
                       "Everyone drives about the same")
        let uneven = SpotETADisplay.fairnessCaption(for: spot([("A", 120), ("B", 1500)]))
        XCTAssertFalse(uneven.contains("spread"), uneven)
    }

    func testFairnessWordTiers() {
        XCTAssertEqual(SpotETADisplay.fairnessWord(for: spot([("A", 480), ("B", 540)])), "Even")
        XCTAssertEqual(SpotETADisplay.fairnessWord(for: spot([("A", 300), ("B", 900)])), "Fair")
        XCTAssertEqual(SpotETADisplay.fairnessWord(for: spot([("A", 120), ("B", 1500)])), "Uneven")
    }
}
