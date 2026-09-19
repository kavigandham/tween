import XCTest

final class TweenAppUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches the DEBUG screenshot harness and confirms both extension
    /// surfaces render. The labels come from `HarnessView.section(_:)`.
    func testHarnessLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HARNESS"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Compact View"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Expanded View"].waitForExistence(timeout: 5))
    }

    /// A friend's pick lands on the BOARD, not as an "Agree / Change" pair.
    /// The old assertions are the point of the change: "Agree" and "Change"
    /// shared one slot, so choosing somewhere else deleted what you were
    /// disagreeing with. You now vote on it, or add your own alongside it.
    func testIncomingPickOffersVoteAndAddsDraftToBoard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HARNESS", "-HARNESS_PROPOSAL_DRAFT"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Proposal With Draft View"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Hangry Joe's Hot Chicken"].waitForExistence(timeout: 5))
        // The board row carries its own vote affordance...
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Hangry Joe'")).firstMatch
            .waitForExistence(timeout: 5))
        // ...and the host-app hand-off ADDS rather than replacing.
        XCTAssertTrue(app.buttons["Add McDonald's"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add your pick"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Agree"].exists)
        XCTAssertFalse(app.buttons["Send McDonald's instead"].exists)
    }

    /// Your own pick shows as already voted for, and the search categories
    /// stay one tap away behind "Add your pick" (the board owns the panel
    /// while a vote is live, so the rail is disclosed, not removed).
    func testOwnPickShowsAsVotedAndCategoriesStayReachable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HARNESS", "-HARNESS_OWN_PROPOSAL"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Own Proposal View"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Barnes & Noble"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Agree"].exists)

        let addPick = app.buttons["Add your pick"]
        XCTAssertTrue(addPick.waitForExistence(timeout: 5))
        addPick.tap()
        XCTAssertTrue(app.buttons["Coffee"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Food"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Gas"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Study"].waitForExistence(timeout: 5))
    }

    func testSoloUserDoesNotShowEndlessFindingState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HARNESS", "-HARNESS_SOLO_WAITING"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Solo Waiting View"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Waiting for someone else"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Finding fair spots..."].exists)
    }

    func testTwoReadyNoResultsDoesNotShowEndlessFindingState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HARNESS", "-HARNESS_TWO_READY_NO_RESULTS"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Two Ready No Results View"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No fair spots found"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open Tween"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Finding fair spots..."].exists)
    }

    func testMeetupSetDoesNotShowDuplicateStatusCard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HARNESS", "-HARNESS_MEETUP"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Meetup Set View"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["It's a plan"].waitForExistence(timeout: 5))
        // ONE preference-driven maps button now (Settings → Apple/Google),
        // not the old Apple/Google pair.
        XCTAssertTrue(app.staticTexts["Open in Maps"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Apple Maps"].exists)
        XCTAssertFalse(app.staticTexts["Google Maps"].exists)
        XCTAssertFalse(app.staticTexts["Open directions or keep browsing."].exists)
    }

    /// Regression: the Liquid Glass chrome (`.interactive()` on button
    /// LABELS) swallowed taps. The compact toolbar keeps recenter one tap away
    /// and places map style inside the options menu; both must stay hittable.
    func testFloatingMapControlsRespondToTaps() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-SKIP_TUTORIAL"]
        app.launch()

        let optionsButton = app.buttons["Map options"]
        XCTAssertTrue(optionsButton.waitForExistence(timeout: 10))
        optionsButton.tap()
        XCTAssertTrue(app.buttons["Standard"].waitForExistence(timeout: 3),
                      "Tapping map options must expose the style choices")
        app.buttons["Standard"].tap()

        let resetButton = app.buttons["Recenter map"]
        XCTAssertTrue(resetButton.waitForExistence(timeout: 5))
        XCTAssertTrue(resetButton.isHittable)
        resetButton.tap()
    }
}

final class TweenAppUITestsLaunchTests: XCTestCase {
    func testLaunchScreenshot() throws {
        let app = XCUIApplication()
        app.launch()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
