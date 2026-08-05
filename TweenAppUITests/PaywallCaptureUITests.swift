import XCTest
import StoreKitTest

/// Captures the paywall with REAL product prices, for App Store Connect's
/// "Review Information → Screenshot" field on each in-app purchase.
///
/// RUN THIS FROM XCODE (Cmd-U), not from `xcodebuild test`.
///
/// Getting the local store into the app under test has exactly one working
/// route, after three that don't (all verified 2026-08-05):
///
///  1. `simctl launch` ignores the scheme's StoreKit configuration entirely.
///  2. `SKTestSession` configures the process that CREATES it. A UI test drives
///     the app in a SEPARATE process, so it never reaches it.
///  3. xcodegen silently drops `storeKitConfiguration` from a scheme's `test`
///     action, and hand-adding `StoreKitConfigurationFileReference` to the
///     generated `.xcscheme` didn't help either — `xcodebuild test` still
///     launched the app with no store.
///
/// So headlessly this SKIPS. From Xcode, where the scheme's run configuration
/// applies, it captures the real paywall with real prices. The PNG lands as an
/// XCTest attachment in the .xcresult bundle.
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

        // SKIP, don't fail. Running headlessly the app launches without a local
        // store, and that is an environment limitation, not a defect — a red
        // test for it just trains people to ignore the suite.
        if !loaded {
            throw XCTSkip(
                "No StoreKit products: the app launched without the local store. "
                + "Expected under `xcodebuild test`. Run this from Xcode (Cmd-U), "
                + "or capture by hand with Cmd-R, then ⋯ → Settings → Tween Pro.")
        }
    }
}
