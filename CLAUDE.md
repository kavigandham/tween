# Tween

A serverless, iMessage-native meetup coordinator. Two friends share locations; the app proposes the fairest places to meet by drive time.

## Environment
**No Xcode is available.** Write Swift source files only. Do not attempt to run `xcodebuild`, `xcrun`, `simctl`, or any iOS build tools. The Xcode project is generated from `project.yml` by a collaborator on a Mac.

## Stack
- Swift 5.9+, SwiftUI, iOS 17+ deployment target
- Apple Messages framework (MSMessagesAppViewController, MSMessage, MSConversation)
- CoreLocation, MapKit (MKLocalSearch, MKDirections, MKMapSnapshotter)
- App Group UserDefaults as cross-process IPC
- No server. No accounts. No backend. No third-party dependencies.

## Targets
| Target | Type | Bundle ID |
|--------|------|-----------|
| TweenApp | iOS App (SwiftUI lifecycle) | `com.kavigandham.TweenApp` |
| TweenMessages | Messages Extension | `com.kavigandham.TweenApp.messages` |
| TweenAppTests | Unit Test Bundle | `com.kavigandham.TweenApp.TweenAppTests` |
| TweenAppUITests | UI Test Bundle | `com.kavigandham.TweenApp.TweenAppUITests` |

App Group: `group.com.kavigandham.tween`

## Directory Structure
```
TweenApp/           Host app source
TweenMessages/      iMessage extension source
Shared/             Compiled into BOTH targets (not a framework)
TweenAppTests/      Unit tests
TweenAppUITests/    UI tests
```

Files in `Shared/` must be listed under BOTH `TweenApp` and `TweenMessages` sources in `project.yml`.

## HARD CONSTRAINTS — DO NOT VIOLATE

1. **Extension memory ceiling ~120 MB.** `MKMapSnapshotter` only — NEVER `MKMapView`. Cap ranking at 5 in extension, 8 in app. Cancel all Tasks in `willResignActive`.
   - *Sanctioned exception:* `ExpandedView` uses an interactive SwiftUI `Map` (which is an `MKMapView`) so users can pan/zoom. Held under the ceiling by flat elevation, no annotation materials/pulse, capped camera zoom, and a `didReceiveMemoryWarning` fallback that swaps in `TweenMapSnapshotView`. Needs on-device profiling. `CompactView` + `BubbleImageRenderer` stay snapshotter-only.

2. **`MSMessage.url` ≤ 5000 chars, `https`/`file` scheme only.** Coordinates + spot name only. Never route geometry.

3. **Compact view = keyboard height.** No first responder, no keyboard, no text input.

4. **Location: When-In-Use only.** `NSLocationWhenInUseUsageDescription` in the EXTENSION'S Info.plist. Retain `CLLocationManager`.

5. **No API keys** in code or URLs.

6. **App Group UserDefaults is unencrypted.** Coordinates and preferences only.

7. **`@Observable`**, not `ObservableObject`. `@State` owns, `@Bindable` for two-way.

8. **No server, no accounts, no backend.**

## Conventions
- Atomic single-key JSON writes to App Group (prevents torn reads)
- All styling through `Shared/Tokens.swift`
- Tests reset App Group UserDefaults in `setUp()`
- Conventional commit messages: `feat:`, `fix:`, `test:`, `refactor:`, `chore:`, `polish:`
- After completing a phase, run `git add -A && git commit` with the specified message
