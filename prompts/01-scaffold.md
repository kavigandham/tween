# Phase 01: Scaffold + Core Data Layer

## Prior State
- Empty directory with: `CLAUDE.md`, `orchestrator.sh`, `prompts/`, `project.yml`, and a `.git` repo.
- No Swift files exist yet. No Xcode is available — do NOT run xcodebuild, xcrun, or simctl.
- Read CLAUDE.md before doing anything.

## Objective
Create the full directory structure, entitlements, and core data models. After this phase, all Shared/ models are implemented and 7 unit tests are written.

## Tasks

### 1. Create directory structure
```
TweenApp/
├── TweenApp/
│   ├── TweenAppApp.swift
│   ├── ContentView.swift
│   └── Info.plist
├── TweenMessages/
│   ├── MessagesViewController.swift
│   └── Info.plist
├── Shared/
│   ├── TweenState.swift
│   ├── LocationCache.swift
│   ├── LocationProvider.swift
│   ├── NetworkMonitor.swift
│   └── OnboardingFlags.swift
├── TweenAppTests/
│   └── TweenAppTests.swift
├── TweenAppUITests/
│   └── TweenAppUITests.swift
├── TweenApp.entitlements
└── TweenMessages.entitlements
```

### 2. Entitlements files
Both `TweenApp.entitlements` and `TweenMessages.entitlements`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.kavigandham.tween</string>
    </array>
</dict>
</plist>
```

### 3. Info.plist files
**`TweenApp/Info.plist`:** Standard iOS app plist. Must include `NSLocationWhenInUseUsageDescription`.

**`TweenMessages/Info.plist`:** Must include:
```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Tween uses your location once to share where you are for a meetup.</string>
<key>NSExtension</key>
<dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.message-payload-provider</string>
    <key>NSExtensionPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).MessagesViewController</string>
</dict>
```

### 4. `Shared/TweenState.swift` — URL codec for iMessage bubbles
```swift
import Foundation
import CoreLocation

struct TweenState: Equatable {
    let text: String
    let latitude: Double
    let longitude: Double
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    func encodedURL() -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "tween.app"
        components.path = "/m"
        components.queryItems = [
            URLQueryItem(name: "t", value: text),
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lon", value: String(longitude))
        ]
        guard let url = components.url, url.absoluteString.count <= 5000 else { return nil }
        return url
    }
    
    init(text: String, latitude: Double, longitude: Double) {
        self.text = text; self.latitude = latitude; self.longitude = longitude
    }
    
    init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "https" || c.scheme == "file",
              let items = c.queryItems,
              let t = items.first(where: { $0.name == "t" })?.value,
              let lat = items.first(where: { $0.name == "lat" })?.value.flatMap(Double.init),
              let lon = items.first(where: { $0.name == "lon" })?.value.flatMap(Double.init),
              url.absoluteString.count <= 5000
        else { return nil }
        self.text = t; self.latitude = lat; self.longitude = lon
    }
}
```

### 5. `Shared/LocationCache.swift` — App Group coordinate persistence
Atomic single-key JSON writes for self and peer coordinates. Include `save()`, `loadSelf()`, `savePeer()`, `loadPeer()`, `isActive` property, and `clearAll()`. Use the CachedCoord pattern (lat, lon, timestamp in a single Codable struct per key).

### 6. `Shared/LocationProvider.swift` — CLLocationManager wrapper
`@Observable final class` with Status enum (idle/requesting/denied/got/failed). One-shot `requestOnce()` and `requestOnceIfAuthorized()` methods. Retains CLLocationManager. Uses delegate pattern.

### 7. `Shared/NetworkMonitor.swift` — NWPathMonitor wrapper
`@Observable final class` with `isOnline: Bool`, defaulting to `true`. Uses `NWPathMonitor`.

### 8. `Shared/OnboardingFlags.swift`
`enum OnboardingFlags` with `hasSeenOnboarding: Bool` in App Group UserDefaults.

### 9. Minimal app entry point
**`TweenApp/TweenAppApp.swift`:** `@main` struct, `WindowGroup { ContentView() }`.
**`TweenApp/ContentView.swift`:** Shows `Text("Tween")` placeholder.

### 10. Minimal extension stub
**`TweenMessages/MessagesViewController.swift`:** `MSMessagesAppViewController` subclass with just `viewDidLoad`.

### 11. Unit tests — `TweenAppTests/TweenAppTests.swift`
Write 7 test methods:
1. TweenState round-trips through encode → decode
2. TweenState encodes with https scheme, ≤ 5000 chars
3. TweenState round-trips emoji/non-ASCII text
4. TweenState returns nil for unrelated URL
5. LocationCache saves and loads self coordinate
6. LocationCache saves and loads peer independently
7. LocationCache returns nil on clean suite

Reset App Group UserDefaults in `setUp()`.

### 12. UI test stub — `TweenAppUITests/TweenAppUITests.swift`
Empty test class, placeholder for Phase 08.

## Acceptance Criteria
- [ ] All directories exist: `TweenApp/`, `TweenMessages/`, `Shared/`, `TweenAppTests/`, `TweenAppUITests/`
- [ ] Both `.entitlements` files exist with App Group
- [ ] Both `Info.plist` files exist with required keys
- [ ] 5 Shared/ Swift files exist and are non-empty
- [ ] Test file exists with 7 test methods
- [ ] `project.yml` is present (already existed, do not modify it)
- [ ] All Swift files have correct `import` statements

## Constraints
- Do NOT run xcodebuild, xcrun, simctl, or any build tools — they are not available
- Do NOT create a .xcodeproj — the collaborator generates it from project.yml
- Do NOT add any UI beyond minimal stubs
- Commit with message: "feat: phase 01 — scaffold project with core data layer"
