import XCTest
import Messages
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
