import XCTest
import UIKit
import CoreLocation
@testable import TweenApp

/// The rasterized pins (extension snapshots + the iMessage bubble image) must
/// carry the same identity the live map shows. These render real images and
/// assert on pixels — the bug they lock down was invisible to every existing
/// test because a bare circle and an avatar are both "an image".
final class PinRenderTests: XCTestCase {

    /// Renders one pin on a transparent canvas.
    private func render(role: TweenPin.Role, initials: String? = nil,
                        needsRide: Bool = false, diameter: CGFloat = 38) -> UIImage {
        let size = CGSize(width: 80, height: 80)
        return UIGraphicsImageRenderer(size: size).image { context in
            PinRenderer.draw(role: role, initials: initials, needsRide: needsRide,
                             at: CGPoint(x: 40, y: 40), diameter: diameter,
                             in: context.cgContext)
        }
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard let cg = image.cgImage else { return (0, 0, 0, 0) }
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: -CGFloat(x), y: -CGFloat(image.size.height - CGFloat(y)),
                                 width: image.size.width, height: image.size.height))
        return (data[0], data[1], data[2], data[3])
    }

    // 1. A friend pin paints its initials in white at the center — the whole
    //    point of the avatar family. A bare colored circle (the old behavior)
    //    leaves the center fully saturated orange with no white.
    func testFriendPinDrawsInitials() {
        let withInitials = render(role: .friend, initials: "KG")
        let center = pixel(withInitials, x: 40, y: 40)
        XCTAssertGreaterThan(Int(center.r), 200, "initials glyph should be near-white")
        XCTAssertGreaterThan(Int(center.g), 200, "initials glyph should be near-white")
        XCTAssertGreaterThan(Int(center.b), 200, "initials glyph should be near-white")
    }

    // 2. The self pin renders Apple's location dot — a BLUE core, never orange.
    func testSelfPinIsBlueLocationDot() {
        let image = render(role: .selfActive)
        let center = pixel(image, x: 40, y: 40)
        XCTAssertGreaterThan(Int(center.b), Int(center.r), "self dot core must be blue")
        XCTAssertGreaterThan(Int(center.a), 200, "self dot core must be opaque")
    }

    // 3. Every role renders something visible at its center (no blank pins).
    func testAllRolesRenderVisiblePixels() {
        let roles: [TweenPin.Role] = [.selfDot, .selfActive, .friend, .rideNeeded,
                                      .fairSpot, .midpoint, .closestToUser, .result]
        for role in roles {
            let center = pixel(render(role: role), x: 40, y: 40)
            XCTAssertGreaterThan(Int(center.a), 128, "\(role) rendered nothing at its center")
        }
    }

    // 4. Two different people produce visibly different pins — identity, not
    //    interchangeable blobs.
    func testDifferentInitialsProduceDifferentPins() {
        let a = render(role: .friend, initials: "KG").pngData()
        let b = render(role: .friend, initials: "MW").pngData()
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a, b, "pins for different people must not be identical")
    }

    // 5. The bubble image still renders at its documented size with real
    //    participants flowing through the new pin path.
    func testBubbleImageRendersWithParticipantPins() {
        let state = TweenState(text: "Blue Bottle", latitude: 37.78, longitude: -122.41, kind: .place)
        let participants = [
            Participant(id: "me", name: "Hassan", coordinate: CLLocationCoordinate2D(latitude: 37.79, longitude: -122.42)),
            Participant(id: "kavi", name: "Kavi Gandham", coordinate: CLLocationCoordinate2D(latitude: 37.33, longitude: -121.88))
        ]
        let image = BubbleImageRenderer.fallbackImage(state: state, participants: participants,
                                                      localID: "me", localName: "Hassan")
        // 600×400 at the renderer's documented bubble aspect.
        XCTAssertEqual(image.size.width / image.size.height, 1.5, accuracy: 0.01)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertNotNil(image.pngData())
    }
}
