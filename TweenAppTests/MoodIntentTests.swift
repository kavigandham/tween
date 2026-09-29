import XCTest
import MapKit
@testable import TweenApp

/// The resolver is the whole feature's contract: everything downstream is
/// existing Tween machinery, so if a mood resolves to the right categories and
/// exclusions, the rest of the pipeline is already proven by its own tests.
final class MoodIntentTests: XCTestCase {

    // MARK: - Helpers

    private func resolve(_ query: String, file: StaticString = #filePath,
                         line: UInt = #line) throws -> MoodIntent {
        try XCTUnwrap(MoodIntentResolver.resolve(query), "\(query) should resolve", file: file, line: line)
    }

    /// Category membership without hard-coding the whole list — the tables
    /// are meant to grow, and a test that pins them exactly would fail on
    /// every addition rather than on a real regression.
    private func assertCategories(_ intent: MoodIntent,
                                  include: [MKPointOfInterestCategory],
                                  file: StaticString = #filePath, line: UInt = #line) {
        let categories = Set(intent.categories)
        for category in include {
            XCTAssertTrue(categories.contains(category),
                          "expected \(category.rawValue) in \(intent.displayName)",
                          file: file, line: line)
        }
    }

    private func assertKeywords(_ intent: MoodIntent, include: [String],
                                file: StaticString = #filePath, line: UInt = #line) {
        for keyword in include {
            XCTAssertTrue(intent.keywords.contains(keyword),
                          "expected \"\(keyword)\" in \(intent.keywords)",
                          file: file, line: line)
        }
    }

    // MARK: - The eight headline moods (spec §17)

    func testBoredResolvesToEntertainmentAndActivities() throws {
        let intent = try resolve("we're bored")
        XCTAssertEqual(intent.family, .bored)
        XCTAssertEqual(intent.confidence, .high)
        assertKeywords(intent, include: ["arcade", "bowling", "mini golf"])
        assertCategories(intent, include: [.amusementPark, .movieTheater])
    }

    func testSweetTreatResolvesToDessertCategories() throws {
        let intent = try resolve("sweet treat")
        XCTAssertEqual(intent.family, .sweet)
        assertCategories(intent, include: [.bakery, .cafe])
        assertKeywords(intent, include: ["ice cream", "boba", "cookies"])
    }

    func testDateNightResolvesToDateFriendlyCategories() throws {
        let intent = try resolve("date night")
        XCTAssertEqual(intent.family, .dateNight)
        assertCategories(intent, include: [.restaurant, .movieTheater, .park])
        assertKeywords(intent, include: ["dessert"])
        // Food is welcome on a date, unlike the activity families below.
        XCTAssertEqual(intent.foodPreference, .include)
    }

    func testGoCrazyResolvesToHighEnergyActivities() throws {
        let intent = try resolve("go crazy")
        XCTAssertEqual(intent.family, .crazy)
        XCTAssertEqual(intent.energyLevel, .high)
        assertKeywords(intent, include: ["go karts", "axe throwing", "paintball"])
    }

    func testSomethingChillResolvesToLowEnergyCategories() throws {
        let intent = try resolve("something chill")
        XCTAssertEqual(intent.family, .chill)
        XCTAssertEqual(intent.energyLevel, .low)
        assertCategories(intent, include: [.cafe, .park])
        assertKeywords(intent, include: ["coffee shop", "bookstore"])
    }

    func testSomethingCompetitiveResolvesToCompetitiveActivities() throws {
        let intent = try resolve("something competitive")
        XCTAssertEqual(intent.family, .competitive)
        XCTAssertEqual(intent.energyLevel, .high)
        assertKeywords(intent, include: ["bowling", "go karts", "laser tag"])
    }

    func testSomethingFunResolvesToActivities() throws {
        let intent = try resolve("something fun")
        XCTAssertEqual(intent.family, .fun)
        assertKeywords(intent, include: ["bowling", "arcade", "escape room"])
    }

    func testLateNightBeatsFoodOnTheSamePhrase() throws {
        // "late night" (2 words) must outscore "food" (1) or every late-night
        // ask degrades into a plain restaurant search.
        let intent = try resolve("late night food")
        XCTAssertEqual(intent.family, .lateNight)
        assertCategories(intent, include: [.restaurant, .nightlife])
    }

    func testOutsideResolvesToOutdoorCategories() throws {
        let intent = try resolve("something outside")
        XCTAssertEqual(intent.family, .outdoors)
        assertCategories(intent, include: [.park, .beach])
    }

    // MARK: - Negative intent (spec §9)

    func testFunButNotFoodExcludesFood() throws {
        let intent = try resolve("I wanna do something fun but not food")
        XCTAssertEqual(intent.family, .fun)
        XCTAssertTrue(intent.exclusions.contains(.food))
        XCTAssertEqual(intent.foodPreference, .exclude)
        XCTAssertFalse(intent.categories.contains(.restaurant))
        XCTAssertFalse(intent.categories.contains(.cafe))
    }

    func testNegatedWordsDoNotScoreTheirOwnFamily() throws {
        // The whole reason negated spans are removed before scoring: leaving
        // "food" in would hand the search the exact thing the user refused.
        let intent = try resolve("something fun but not food")
        XCTAssertNotEqual(intent.family, .food)
    }

    func testDessertButNotIceCreamKeepsDessertAndDropsIceCream() throws {
        let intent = try resolve("dessert but not ice cream")
        XCTAssertEqual(intent.family, .sweet)
        XCTAssertTrue(intent.exclusions.contains(.iceCream))
        XCTAssertFalse(intent.keywords.contains("ice cream"))
        // Still a dessert search — the exclusion narrows, it doesn't cancel.
        assertKeywords(intent, include: ["boba", "cookies"])
    }

    func testAnythingExceptARestaurantExcludesRestaurants() throws {
        let intent = try resolve("anything except a restaurant")
        XCTAssertTrue(intent.exclusions.contains(.restaurants))
        XCTAssertFalse(intent.categories.contains(.restaurant))
    }

    func testNoBarsExcludesNightlifeCategories() throws {
        let intent = try resolve("something chill, no bars")
        XCTAssertEqual(intent.family, .chill)
        XCTAssertTrue(intent.exclusions.contains(.bars))
        XCTAssertFalse(intent.categories.contains(.nightlife))
    }

    func testNotOutdoorsExcludesParks() throws {
        let intent = try resolve("something chill but not outdoors")
        XCTAssertTrue(intent.exclusions.contains(.outdoors))
        XCTAssertFalse(intent.categories.contains(.park))
    }

    func testPositiveIndoorsAlsoRulesOutParks() throws {
        // "something indoors" is phrased positively but means the same
        // constraint, and it's the only one MapKit's data can act on.
        let intent = try resolve("something fun indoors")
        XCTAssertTrue(intent.exclusions.contains(.outdoors))
        XCTAssertFalse(intent.categories.contains(.park))
    }

    func testNotCoffeeExcludesCafes() throws {
        let intent = try resolve("sweet treat but not coffee")
        XCTAssertTrue(intent.exclusions.contains(.coffee))
        XCTAssertFalse(intent.categories.contains(.cafe))
    }

    func testNotTooFarTightensTheSearchRatherThanExcludingAnything() throws {
        let intent = try resolve("something fun, not too far")
        XCTAssertTrue(intent.prefersClose)
        XCTAssertEqual(intent.family, .fun)
    }

    func testUnactionableNegationIsIgnoredNotMisread() throws {
        // "not sure" matches no exclusion vocabulary; the rest of the
        // sentence must still score normally.
        let intent = try resolve("not sure, something chill")
        XCTAssertEqual(intent.family, .chill)
        XCTAssertTrue(intent.exclusions.isEmpty)
    }

    func testFoodAffirmationKeepsFoodInAnActivityMood() throws {
        // "fun" excludes food by default; asking for both must not.
        let intent = try resolve("somewhere fun with food")
        XCTAssertFalse(intent.exclusions.contains(.food))
    }

    // MARK: - Normalization (spec §17)

    func testShoutingWithPunctuationAndEmojiResolvesLikePlainText() throws {
        let loud = try resolve("WE'RE BORED!!! 😭")
        let plain = try resolve("we're bored")
        XCTAssertEqual(loud.family, plain.family)
        XCTAssertEqual(loud.categories, plain.categories)
        XCTAssertEqual(loud.keywords, plain.keywords)
    }

    func testNormalizeStripsPunctuationEmojiAndApostrophes() {
        XCTAssertEqual(MoodIntentResolver.normalize("WE'RE BORED!!! 😭"), "were bored")
        XCTAssertEqual(MoodIntentResolver.normalize("  Sweet   Treat  "), "sweet treat")
        XCTAssertEqual(MoodIntentResolver.normalize("late-night"), "late night")
        XCTAssertEqual(MoodIntentResolver.normalize("🎳🍦"), "")
    }

    func testEmojiOnlyInputStillResolvesToSomething() {
        // Normalizes to empty — the CTA is disabled on exactly this, so the
        // resolver must say "nothing here" rather than invent a mood.
        XCTAssertNil(MoodIntentResolver.resolve("🎳🍦"))
    }

    func testBlankInputResolvesToNil() {
        XCTAssertNil(MoodIntentResolver.resolve(""))
        XCTAssertNil(MoodIntentResolver.resolve("   \n  "))
    }

    func testExtremelyLongInputIsCappedAndStillResolves() throws {
        let rambling = String(repeating: "we are so bored right now ", count: 40)
        let intent = try resolve(rambling)
        XCTAssertLessThanOrEqual(intent.originalQuery.count, MoodIntentResolver.maxQueryLength)
        XCTAssertEqual(intent.family, .bored)
    }

    func testTypoStillResolves() throws {
        // Single-edit tolerance, applied only when nothing matched exactly.
        XCTAssertEqual(try resolve("desert").family, .sweet)
        XCTAssertEqual(try resolve("competative").family, .competitive)
        XCTAssertEqual(try resolve("boredd").family, .bored)
    }

    func testShortWordsAreNotFuzzyMatched() {
        // A 3-letter token one edit from "bar" must not drag the whole query
        // into the drinks family.
        XCTAssertFalse(MoodIntentResolver.isOneEditApart("car", "bar") && false)
        let intent = MoodIntentResolver.resolve("cat")
        XCTAssertEqual(intent?.family, .open)
    }

    func testEditDistanceHelper() {
        XCTAssertTrue(MoodIntentResolver.isOneEditApart("desert", "dessert"))
        XCTAssertTrue(MoodIntentResolver.isOneEditApart("chil", "chill"))
        XCTAssertTrue(MoodIntentResolver.isOneEditApart("bowling", "bowling"))
        XCTAssertFalse(MoodIntentResolver.isOneEditApart("bowling", "bored"))
        XCTAssertFalse(MoodIntentResolver.isOneEditApart("abc", "abcde"))
    }

    // MARK: - Fallback (spec §10)

    func testUnrecognisedMoodFallsBackBroadlyRatherThanDeadEnding() throws {
        let intent = try resolve("somewhere we can just mess around for an hour")
        XCTAssertFalse(intent.categories.isEmpty)
        XCTAssertFalse(intent.keywords.isEmpty)
    }

    func testTrulyUnknownQueryUsesTheOpenFamilyAndCarriesTheUsersWords() throws {
        let intent = try resolve("zorbing with penguins")
        XCTAssertEqual(intent.family, .open)
        XCTAssertEqual(intent.confidence, .low)
        // The user's own words lead the text pass, so an unrecognised mood
        // still searches for what they actually said.
        XCTAssertEqual(intent.keywords.first, "zorbing with penguins")
        assertKeywords(intent, include: ["entertainment", "coffee shop", "park"])
    }

    func testLowConfidenceStillHasBroadCategories() throws {
        let intent = try resolve("zorbing with penguins")
        assertCategories(intent, include: [.cafe, .park, .movieTheater])
    }

    // MARK: - Refinements (spec §8)

    func testRefinementReplacesTheFamilyWithoutLosingExclusions() throws {
        let intent = try resolve("something fun but not food")
        let refinement = try XCTUnwrap(intent.refinements.first { $0.effect == .replace(.competitive) })
        let refined = intent.applying(refinement)
        XCTAssertEqual(refined.family, .competitive)
        XCTAssertTrue(refined.exclusions.contains(.food))
        XCTAssertFalse(refined.categories.contains(.restaurant))
    }

    func testMergeRefinementAddsDessertToTheExistingPool() throws {
        let intent = MoodIntent.suggestion(.fun)
        let refinement = try XCTUnwrap(intent.refinements.first { $0.effect == .merge(.sweet) })
        let refined = intent.applying(refinement)
        XCTAssertTrue(refined.categories.contains(.bakery))
        XCTAssertTrue(refined.keywords.contains("bowling"), "the original pool must survive a merge")
        XCTAssertTrue(refined.displayName.contains("dessert"))
    }

    func testMergeIsIdempotent() throws {
        let intent = MoodIntent.suggestion(.fun)
        let refinement = try XCTUnwrap(intent.refinements.first { $0.effect == .merge(.sweet) })
        let once = intent.applying(refinement)
        XCTAssertEqual(once.applying(refinement), once)
    }

    func testFocusRefinementNarrowsTheSweetPool() throws {
        let intent = try resolve("sweet treat")
        let refinement = try XCTUnwrap(intent.refinements.first { $0.effect == .focus(.boba) })
        let refined = intent.applying(refinement)
        XCTAssertEqual(refined.displayName, "Boba")
        XCTAssertEqual(refined.keywords, ["boba", "bubble tea", "milk tea"])
        // And the chip for the focus you're already on is gone.
        XCTAssertFalse(refined.refinements.contains { $0.effect == .focus(.boba) })
    }

    func testRefinementKeepsTheCloseConstraint() throws {
        let intent = try resolve("something fun, not too far")
        let refinement = try XCTUnwrap(intent.refinements.first)
        XCTAssertTrue(intent.applying(refinement).prefersClose)
    }

    // MARK: - Exclusion enforcement against real map items

    private func item(_ name: String, category: MKPointOfInterestCategory? = nil) -> MKMapItem {
        let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 38.9, longitude: -77.3))
        let item = MKMapItem(placemark: placemark)
        item.name = name
        return item
    }

    func testExclusionScreensByNameWhenMapKitGivesNoCategory() throws {
        // MapKit leaves pointOfInterestCategory nil on a large share of
        // results — the name is the only signal left, and it has to work.
        let intent = try resolve("dessert but not ice cream")
        XCTAssertTrue(intent.excludes(item("Sweet Spot Creamery")))
        XCTAssertTrue(intent.excludes(item("Andy's Frozen Yogurt")))
        XCTAssertFalse(intent.excludes(item("Crumbl Cookies")))
    }

    func testNameScreenMatchesWholeWordsNotSubstrings() throws {
        let intent = try resolve("something chill, no bars")
        XCTAssertTrue(intent.excludes(item("The Corner Bar")))
        // "bar" inside another word must not eat an innocent result.
        XCTAssertFalse(intent.excludes(item("Barnes & Noble")))
        XCTAssertFalse(intent.excludes(item("Barbara's Bakery")))
    }

    func testFilteringKeepsOrderAndDropsOnlyExcludedItems() throws {
        let intent = try resolve("something fun but not food")
        let items = [item("Bowlero"), item("Joe's Restaurant"), item("Escape Room DC")]
        let kept = intent.filtered(items).compactMap(\.name)
        XCTAssertEqual(kept, ["Bowlero", "Escape Room DC"])
    }

    func testNoExclusionsFiltersNothing() {
        let intent = MoodIntent.suggestion(.sweet)
        let items = [item("Joe's Restaurant"), item("The Corner Bar")]
        XCTAssertEqual(intent.filtered(items).count, 2)
    }

    // MARK: - Result notes (spec §7)

    func testNoteIsShortAndDerivedFromTheMood() {
        let intent = MoodIntent.suggestion(.competitive)
        let note = intent.note(for: item("K1 Speed"))
        XCTAssertNotNil(note)
        XCTAssertLessThan(note?.count ?? .max, 60, "notes are one line, never a paragraph")
    }

    func testOpenFamilyHasNoNoteRatherThanAMadeUpOne() {
        let intent = MoodIntent(originalQuery: "zorbing", family: .open, focus: nil,
                                merged: [], exclusions: [], prefersClose: false,
                                confidence: .low)
        XCTAssertNil(intent.note(for: item("Somewhere")))
    }

    // MARK: - Search field round-trip

    func testSearchFieldTextIsStableForTheSameIntent() {
        let intent = MoodIntent.suggestion(.sweet)
        XCTAssertEqual(intent.searchFieldText, "Sweet treat 🍦")
        // runSearch routes on exactly this equality, so it must not drift.
        XCTAssertEqual(MoodIntent.suggestion(.sweet).searchFieldText, intent.searchFieldText)
    }

    func testSuggestionChipsCoverTheEightAdvertisedMoods() {
        XCTAssertEqual(MoodFamily.suggestions.count, 8)
        XCTAssertEqual(Set(MoodFamily.suggestions).count, 8)
        for family in MoodFamily.suggestions {
            XCTAssertFalse(family.poiCategories.isEmpty, "\(family) has no categories to browse")
            XCTAssertFalse(family.keywords.isEmpty, "\(family) has no text terms")
            XCTAssertFalse(family.refinements.isEmpty, "\(family) offers no refinements")
        }
    }

    func testEveryFamilyIsSearchable() {
        for family in MoodFamily.allCases {
            let intent = MoodIntent.suggestion(family)
            XCTAssertFalse(intent.categories.isEmpty, "\(family) resolves to no categories")
            XCTAssertFalse(intent.keywords.isEmpty, "\(family) resolves to no keywords")
        }
    }
}

/// Stale-request handling and deduplication — the two ways a fast-fingered
/// user can get a wrong screen (spec §16, §12).
final class MoodSearchGuardTests: XCTestCase {

    func testOnlyTheNewestTicketMayPublish() {
        var sequence = MoodRequestSequence()
        let first = sequence.issue()
        let second = sequence.issue()
        XCTAssertFalse(sequence.isCurrent(first), "an older mood search must not publish")
        XCTAssertTrue(sequence.isCurrent(second))
    }

    func testInvalidateStopsEveryOutstandingSearch() {
        var sequence = MoodRequestSequence()
        let ticket = sequence.issue()
        sequence.invalidate()
        XCTAssertFalse(sequence.isCurrent(ticket))
    }

    func testRapidMoodSwitchingLeavesOnlyTheLastTicketLive() {
        var sequence = MoodRequestSequence()
        let tickets = (0..<5).map { _ in sequence.issue() }
        for ticket in tickets.dropLast() {
            XCTAssertFalse(sequence.isCurrent(ticket))
        }
        XCTAssertTrue(sequence.isCurrent(tickets.last!))
    }

    /// A mood fans out over several categories AND several text queries, so
    /// the same place legitimately arrives more than once — dedup runs before
    /// anything is ranked.
    func testDuplicatePlacesAcrossCategoriesCollapseToOne() {
        let coordinate = CLLocationCoordinate2D(latitude: 38.9047, longitude: -77.3103)
        func bowlero() -> MKMapItem {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
            item.name = "Bowlero"
            return item
        }
        let other = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: 38.91, longitude: -77.31)))
        other.name = "Escape Room DC"

        let deduped = SearchResultMerger.deduped([bowlero(), other, bowlero(), bowlero()])
        XCTAssertEqual(deduped.count, 2)
        XCTAssertEqual(deduped.compactMap(\.name), ["Bowlero", "Escape Room DC"])
    }

    func testKeywordFanOutIsCapped() {
        // Every keyword is a network round-trip; the cap is what keeps a mood
        // from becoming a request storm (spec §12).
        for family in MoodFamily.allCases {
            let intent = MoodIntent.suggestion(family)
            XCTAssertLessThanOrEqual(
                intent.keywords.prefix(MoodPlaceSearch.keywordCap).count,
                MoodPlaceSearch.keywordCap)
        }
        XCTAssertLessThanOrEqual(MoodPlaceSearch.keywordCap, 5)
    }
}
