import XCTest
@testable import TweenApp

final class SpotCategoryMarkTests: XCTestCase {
    func testCoffeeShopsGetACup() {
        for name in ["Blue Bottle Coffee", "Philz Coffee", "Sightglass Roasters",
                     "Starbucks", "The Daily Café"] {
            XCTAssertEqual(SpotCategoryMark.forName(name).systemImage,
                           "cup.and.saucer.fill", name)
        }
    }

    func testRestaurantsGetCutlery() {
        for name in ["Hangry Joe's Hot Chicken", "Joe's Pizza", "Shake Shack",
                     "Chipotle Mexican Grill"] {
            XCTAssertEqual(SpotCategoryMark.forName(name).systemImage, "fork.knife", name)
        }
    }

    func testGasStationsGetAPump() {
        for name in ["Shell", "Wawa", "Sheetz"] {
            XCTAssertEqual(SpotCategoryMark.forName(name).systemImage, "fuelpump.fill", name)
        }
    }

    func testStoresGetABag() {
        for name in ["Walmart Supercenter", "Target", "Trader Joe's"] {
            XCTAssertEqual(SpotCategoryMark.forName(name).systemImage, "bag.fill", name)
        }
    }

    func testNarrowKeywordsBeatBroadOnes() {
        // "Ice cream" must not fall through to the restaurant table, and a
        // sports bar is a bar, not a gym — ordering in the table is the thing
        // under test here.
        XCTAssertEqual(SpotCategoryMark.forName("Molly Moon's Ice Cream").systemImage,
                       "birthday.cake.fill")
        XCTAssertEqual(SpotCategoryMark.forName("The Sports Bar").systemImage,
                       "wineglass.fill")
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(SpotCategoryMark.forName("BLUE BOTTLE COFFEE").systemImage,
                       "cup.and.saucer.fill")
    }

    func testUnknownPlacesFallBackToAPin() {
        for name in ["43110 Baltusrol Terr", "", "Zzyzx"] {
            XCTAssertEqual(SpotCategoryMark.forName(name).systemImage,
                           SpotCategoryMark.fallback.systemImage, name)
        }
    }
}
