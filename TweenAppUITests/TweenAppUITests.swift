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

    func testProposalDraftShowsAgreeBeforeDraftSend() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HARNESS", "-HARNESS_PROPOSAL_DRAFT"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Proposal With Draft View"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Hangry Joe's Hot Chicken"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Agree"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Change"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Send McDonald's instead"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.buttons["Browse spots"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Finding fair spots..."].exists)
    }

    func testMeetupSetDoesNotShowDuplicateStatusCard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HARNESS", "-HARNESS_MEETUP"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Meetup Set View"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["It's a plan"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Apple Maps"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Open directions or keep browsing."].exists)
    }

    /// Regression: the Liquid Glass chrome (`.interactive()` on button
    /// LABELS) swallowed taps — reset-map and the map-style picker went
    /// completely dead on device. Expanding the style picker is observable
    /// (the per-style option buttons appear), so it proves taps land.
    func testFloatingMapControlsRespondToTaps() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-SKIP_TUTORIAL"]
        app.launch()

        let styleButton = app.buttons["Map style"]
        XCTAssertTrue(styleButton.waitForExistence(timeout: 10))
        styleButton.tap()
        XCTAssertTrue(app.buttons["Standard"].waitForExistence(timeout: 3),
                      "Tapping the style control must expand the picker options")
        app.buttons["Standard"].tap()

        let resetButton = app.buttons["Reset map"]
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
