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
        XCTAssertTrue(app.buttons["Search in Tween"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Finding fair spots..."].exists)
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
