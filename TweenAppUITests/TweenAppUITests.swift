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
