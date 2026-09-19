import XCTest
@testable import TweenApp

/// "Leaving now" — the ETA that rides with it, and the local log of who said it.
final class EnRouteTests: XCTestCase {

    private let key = "test-conversation"

    override func setUp() {
        super.setUp()
        EnRouteLog.clear(key: key)
    }

    override func tearDown() {
        EnRouteLog.clear(key: key)
        super.tearDown()
    }

    func testMarkCountsDownFromWhenItWasSent() {
        let fiveMinutesAgo = Date().addingTimeInterval(-300)
        let mark = EnRouteLog.Mark(participantID: "id-belal", name: "Belal",
                                   etaSeconds: 720, sentAt: fiveMinutesAgo)
        // 12 min out, 5 min ago → ~7 left. A mark that kept claiming its
        // original 12 would be worse than no mark at all.
        let remaining = try! XCTUnwrap(mark.remainingSeconds)
        XCTAssertEqual(Double(remaining), 420, accuracy: 5)
        XCTAssertEqual(mark.summary, "7 min away")
    }

    func testMarkClampsAtArrival() {
        let mark = EnRouteLog.Mark(participantID: "id-belal", name: "Belal",
                                   etaSeconds: 60, sentAt: Date().addingTimeInterval(-600))
        XCTAssertEqual(mark.remainingSeconds, 0)
        XCTAssertEqual(mark.summary, "Arriving now")
    }

    func testMarkWithoutAnETAStillReadsSensibly() {
        let mark = EnRouteLog.Mark(participantID: "id-belal", name: "Belal",
                                   etaSeconds: nil, sentAt: Date())
        XCTAssertNil(mark.remainingSeconds)
        XCTAssertEqual(mark.summary, "On the way")
    }

    func testOnePersonHasOneMarkAndTheLatestWins() {
        EnRouteLog.note(.init(participantID: "id-belal", name: "Belal",
                              etaSeconds: 900, sentAt: Date().addingTimeInterval(-120)),
                        key: key)
        EnRouteLog.note(.init(participantID: "id-belal", name: "Belal",
                              etaSeconds: 300, sentAt: Date()),
                        key: key)

        let marks = EnRouteLog.marks(key: key)
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks.first?.etaSeconds, 300, "a re-send is an UPDATED ETA, not a second departure")
    }

    /// A "leaving now" from this morning tells you nothing at dinner.
    func testStaleMarksAgeOut() {
        EnRouteLog.note(.init(participantID: "id-old", name: "Kavi", etaSeconds: 600,
                              sentAt: Date().addingTimeInterval(-EnRouteLog.ttl - 60)),
                        key: key)
        EnRouteLog.note(.init(participantID: "id-new", name: "Belal", etaSeconds: 600,
                              sentAt: Date()),
                        key: key)

        XCTAssertEqual(EnRouteLog.marks(key: key).map(\.participantID), ["id-new"])
    }

    func testMarksAreScopedToTheirConversation() {
        EnRouteLog.note(.init(participantID: "id-belal", name: "Belal",
                              etaSeconds: 600, sentAt: Date()), key: key)
        XCTAssertTrue(EnRouteLog.marks(key: "some-other-chat").isEmpty)
        EnRouteLog.clear(key: "some-other-chat")
    }

    // MARK: - Caption

    func testCaptionSaysHowFarOutAndWhen() {
        let state = TweenState(text: "Philz Coffee", latitude: 37.44, longitude: -122.14,
                               senderName: "Belal", senderID: "id-belal",
                               kind: .place, messageType: .enroute,
                               etaSeconds: 900)
        let line = BubbleCaption.etaLine(state: state)
        XCTAssertTrue(line.contains("15 min"), line)
        XCTAssertTrue(line.contains("arriving"), line)
    }

    func testCaptionDegradesWithoutAnETA() {
        let state = TweenState(text: "Philz Coffee", latitude: 37.44, longitude: -122.14,
                               senderName: "Belal", senderID: "id-belal",
                               kind: .place, messageType: .enroute)
        XCTAssertEqual(BubbleCaption.etaLine(state: state), "On the way to Philz Coffee")
    }
}
