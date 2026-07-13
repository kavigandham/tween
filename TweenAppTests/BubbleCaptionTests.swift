import XCTest
import Messages
import CoreLocation
@testable import TweenApp

/// Audit F2 follow-up: agreedNames is encoded without the outgoingName() blank,
/// so an un-named agreer travels as the literal "You". BubbleCaption is the last
/// place a peer reads it — it must render "Friend agrees…", never "You agrees…".
final class BubbleCaptionTests: XCTestCase {

    private func participant(_ id: String, _ name: String) -> Participant {
        Participant(id: id, name: name, latitude: 37.7, longitude: -122.4)
    }

    func testPartialAgreeSanitisesUnnamedAgreer() {
        // Sam proposed; only the un-named "You" has agreed, Alex hasn't → the
        // partial-agree (agreer) caption branch.
        let state = TweenState(
            text: "Blue Bottle",
            latitude: 37.7, longitude: -122.4,
            senderName: "Sam",
            kind: .place,
            messageType: .agree,
            participants: [participant("sam", "Sam"),
                           participant("me", "You"),
                           participant("alex", "Alex")],
            agreedNames: ["You"])
        XCTAssertFalse(state.isFullyAgreed)

        let layout = MSMessageTemplateLayout()
        BubbleCaption.apply(to: layout, state: state, totalSeats: 3)
        let caption = layout.caption ?? ""
        XCTAssertFalse(caption.contains("You agrees"), "must not leak the fallback: \(caption)")
        XCTAssertTrue(caption.contains("Friend agrees"), caption)
    }

    // MARK: Message body copy

    func testSpotBodyDoesNotExposeRawMapsLink() {
        let body = OnboardingView.spotBody(
            prefix: "Let's meet at", name: "Blue Bottle",
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194))
        XCTAssertEqual(body, "Let's meet at Blue Bottle.")
        XCTAssertFalse(body.contains("maps.apple.com"), body)
    }

    func testProposeSubcaptionIsNotABareTapPrompt() {
        let state = TweenState(text: "Blue Bottle", latitude: 37.7, longitude: -122.4,
                               senderName: "Sam", kind: .place, messageType: .propose,
                               participants: [participant("sam", "Sam")])
        let layout = MSMessageTemplateLayout()
        BubbleCaption.apply(to: layout, state: state, totalSeats: 2)
        XCTAssertNotEqual(layout.subcaption, "Tap to see the route")
        XCTAssertEqual(layout.subcaption, "A fair spot to meet")
    }

    func testNamedAgreerIsUntouched() {
        let state = TweenState(
            text: "Blue Bottle",
            latitude: 37.7, longitude: -122.4,
            senderName: "Sam",
            kind: .place,
            messageType: .agree,
            participants: [participant("sam", "Sam"),
                           participant("maya", "Maya"),
                           participant("alex", "Alex")],
            agreedNames: ["Maya"])
        let layout = MSMessageTemplateLayout()
        BubbleCaption.apply(to: layout, state: state, totalSeats: 3)
        XCTAssertTrue((layout.caption ?? "").contains("Maya agrees"), layout.caption ?? "")
    }
}
