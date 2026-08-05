import XCTest
import StoreKitTest

/// Captures the paywall with REAL product prices, for App Store Connect's
/// "Review Information → Screenshot" field on each in-app purchase.
///
/// Why a UI test and not `simctl`: `TweenPro.storekit` is attached to the
/// scheme's *run* action, and only an Xcode run applies it. `simctl launch`
/// ignores it entirely, so a scripted capture renders "The App Store isn't
/// reachable right now" where the prices belong — useless as a review asset.
/// `SKTestSession` enables the same local store programmatically, so the
/// capture works headlessly and can be re-run whenever prices change.
///
/// Run it with:
///   xcodebuild test -project TweenApp.xcodeproj -scheme TweenApp \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
///     -only-testing:TweenAppUITests/PaywallCaptureUITests
///
/// The PNG lands as an XCTest attachment in the .xcresult bundle; the test
/// prints the exact `xcrun xcresulttool` line to pull it out.
final class PaywallCaptureUITests: XCTestCase {

    func testCapturePaywallForAppReview() throws {
        let session = try SKTestSession(configurationFileNamed: "TweenPro")
        session.disableDialogs = true
        session.clearTransactions()
        // Locked, so the paywall shows the two products rather than the
        // "You have Tween Pro" badge.
        session.resetToDefaultState()

        let app = XCUIApplication()
        app.launchArguments = ["-DEMO_PRO_LOCKED", "-DEMO_SETTINGS", "-DEMO_PAYWALL"]
        app.launch()

        // The paywall's own heading — it opens itself 0.7 s after Settings
        // settles (SettingsSheet's -DEMO_PAYWALL hook).
        XCTAssertTrue(app.staticTexts["Plan meetups ahead"].waitForExistence(timeout: 20),
                      "Paywall never appeared")

        // Wait for StoreKit to hand back products. Until it does, the sheet
        // shows a spinner or the unreachable message, and a capture is useless.
        let lifetime = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'lifetime'")).firstMatch
        let loaded = lifetime.waitForExistence(timeout: 30)

        // Capture unconditionally — a failed capture is far more useful to
        // look at than a bare assertion message.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "paywall-review-screenshot"
        shot.lifetime = .keepAlways
        add(shot)

        if !loaded {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "element-tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
        XCTAssertTrue(loaded, "Products never loaded — SKTestSession did not attach")
    }
}
