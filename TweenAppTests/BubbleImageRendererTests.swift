import XCTest
import UIKit
import CoreLocation
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

    func testMapSnapshotFallbackImageIsNonNil() {
        let markers = [
            MapMarker(coordinate: CLLocationCoordinate2D(latitude: 32.08, longitude: -81.10), role: .selfActive),
            MapMarker(coordinate: CLLocationCoordinate2D(latitude: 32.10, longitude: -81.08), role: .friend),
            MapMarker(coordinate: CLLocationCoordinate2D(latitude: 32.09, longitude: -81.09), role: .fairSpot)
        ]

        let image = TweenMapSnapshotView.fallbackImage(markers: markers, size: CGSize(width: 320, height: 220))

        XCTAssertEqual(image.size.width, 320, accuracy: 0.5)
        XCTAssertEqual(image.size.height, 220, accuracy: 0.5)
    }

    // The bubble footer must carry a useful line even for non-app-users — the
    // "I'm out" image used to leave it empty (device feedback: wasted space).
    func testFooterHeadlineIsUsefulPerState() {
        let leave = TweenState(text: "", latitude: 0, longitude: 0,
                               senderName: "Hassan", kind: .participant, messageType: .leave)
        XCTAssertEqual(BubbleImageRenderer.footerHeadline(for: leave), "Hassan is out")

        let unnamedLeave = TweenState(text: "", latitude: 0, longitude: 0,
                                      kind: .participant, messageType: .leave)
        XCTAssertEqual(BubbleImageRenderer.footerHeadline(for: unnamedLeave), "Friend is out")

        let invite = TweenState(text: "", latitude: 0, longitude: 0,
                                kind: .participant, messageType: .invite)
        XCTAssertFalse(BubbleImageRenderer.footerHeadline(for: invite).isEmpty)

        let propose = TweenState(text: "Blue Bottle", latitude: 0, longitude: 0,
                                 kind: .place, messageType: .propose)
        XCTAssertEqual(BubbleImageRenderer.footerHeadline(for: propose), "Blue Bottle")

        let counter = TweenState(text: "Joe's", latitude: 0, longitude: 0,
                                 kind: .place, messageType: .counter)
        XCTAssertEqual(BubbleImageRenderer.footerHeadline(for: counter), "Joe's")

        // Fully-agreed → "Meeting at X" (Sam proposed, Alex agreed → consensus).
        let agreed = TweenState(text: "Blue Bottle", latitude: 0, longitude: 0,
                                senderName: "Sam", kind: .place, messageType: .agree,
                                participants: [participant("sam", "Sam"), participant("alex", "Alex")],
                                agreedNames: ["Alex"])
        XCTAssertTrue(agreed.isFullyAgreed)
        XCTAssertEqual(BubbleImageRenderer.footerHeadline(for: agreed), "Meeting at Blue Bottle")
    }

    private func participant(_ id: String, _ name: String) -> Participant {
        Participant(id: id, name: name, latitude: 0, longitude: 0)
    }
}
