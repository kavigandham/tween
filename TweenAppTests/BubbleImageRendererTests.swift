import XCTest
import UIKit
@testable import TweenApp

/// Network-free coverage of the bubble image renderer's fallback path. Only
/// `fallbackImage` is exercised — `makeImage`/`composite` depend on a live
/// `MKMapSnapshotter`, which we never touch in unit tests.
final class BubbleImageRendererTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Start every test from a clean App Group suite.
        if let defaults = UserDefaults(suiteName: LocationCache.appGroup) {
            for key in defaults.dictionaryRepresentation().keys {
                defaults.removeObject(forKey: key)
            }
        }
        LocationCache.clearAll()
    }

    // 1. fallbackImage always produces a usable, non-empty image.
    func testFallbackImageIsNonNil() {
        let image = BubbleImageRenderer.fallbackImage(spotName: "Blue Bottle Coffee")
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    // 2. fallbackImage renders at the bubble's 3:2 (600×400) aspect ratio.
    func testFallbackImageHas3to2AspectRatio() {
        let image = BubbleImageRenderer.fallbackImage(spotName: "Dolores Park")
        XCTAssertEqual(image.size.width, 600, accuracy: 0.5)
        XCTAssertEqual(image.size.height, 400, accuracy: 0.5)
        XCTAssertEqual(image.size.width / image.size.height, 600.0 / 400.0, accuracy: 0.001)
    }
}
