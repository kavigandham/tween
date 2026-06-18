# Phase 08: Tests + TestFlight Prep

## Prior State
- Phase 07 complete. Full app with design tokens applied, animations, accessibility. 25 tests written.
- No Xcode — do NOT run build tools. Read CLAUDE.md.

## Objective
Add UI test harness, expand test coverage, create privacy manifest, gate debug code, and write App Store metadata.

## Tasks

### 1. UI test harness
**Update `TweenApp/ContentView.swift`:**
```swift
struct ContentView: View {
    var body: some View {
        #if DEBUG
        if CommandLine.arguments.contains("-HARNESS") {
            HarnessView()
        } else {
            OnboardingView()
        }
        #else
        OnboardingView()
        #endif
    }
}
```

**Create `TweenApp/HarnessView.swift`** (wrapped in `#if DEBUG`):
Renders CompactView and ExpandedView side by side with seeded test data (hardcoded SF + San Jose coordinates, a sample TweenState). Lets the collaborator screenshot-verify extension UIs without booting the extension.

### 2. UI test file — `TweenAppUITests/TweenAppUITests.swift`
```swift
import XCTest

final class TweenAppUITests: XCTestCase {
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
```

### 3. Privacy manifest — `TweenApp/PrivacyInfo.xcprivacy`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>CA92.1</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
```
Also create a copy at `TweenMessages/PrivacyInfo.xcprivacy`.

### 4. Gate debug code
Search all Swift files. Wrap in `#if DEBUG`:
- All `print()` / `debugPrint()` calls
- HarnessView and DebugLaunchSeed
- The `-HARNESS` check in ContentView
- Any test-only initializers on RankedSpot

### 5. Update project.yml
Add `PrivacyInfo.xcprivacy` to the sources for both TweenApp and TweenMessages targets. Add `HarnessView.swift` to TweenApp sources.

### 6. App Store metadata — create `metadata/` directory
- `app_name.txt`: "Tween"
- `subtitle.txt`: "Fair meetups in iMessage"
- `description.txt`: ~150 words. Fair meeting spots inside iMessage. Drive-time ranking. No accounts. No servers. Privacy-first.
- `keywords.txt`: "meetup,meeting,halfway,fair,imessage,friends,drive,location,map"
- `privacy_url.txt`: "https://tween.app/privacy"

### 7. App icon placeholder
Create a simple Python or bash script at `scripts/generate_icon.py` that generates a 1024×1024 PNG: teal (#008C8C) background, white "T" centered. The collaborator runs it to produce the icon, or creates one manually.

### 8. Create TESTING.md
Document the manual test plan across all 8 phases for the collaborator to follow when verifying on device.

## Acceptance Criteria
- [ ] `TweenApp/HarnessView.swift` exists, wrapped in `#if DEBUG`
- [ ] `TweenAppUITests/TweenAppUITests.swift` has harness + screenshot tests
- [ ] `PrivacyInfo.xcprivacy` exists in both TweenApp/ and TweenMessages/
- [ ] All `print()` calls wrapped in `#if DEBUG`
- [ ] `metadata/` directory with 5 files
- [ ] `scripts/generate_icon.py` exists
- [ ] `TESTING.md` exists
- [ ] `project.yml` updated with new files
- [ ] Total: 27+ test methods across all test files
- [ ] No build tool invocations

## Constraints
- Do NOT run any build tools
- Do NOT modify app functionality
- Do NOT change bundle identifiers
- Do NOT add third-party SDKs
- Commit with message: "chore: phase 08 — tests, privacy manifest, and TestFlight prep"
