# Phase 02: Host App — Map + Location

## Prior State
- Phase 01 complete. Directory structure created. Shared/ has TweenState, LocationCache, LocationProvider, NetworkMonitor, OnboardingFlags. Test file has 7 test methods. ContentView is a placeholder.
- No Xcode available — do NOT run any build tools. Read CLAUDE.md.

## Objective
Build the host app's map surface: full-screen MapKit map, "I'm in" location capture, pin views, and a bottom sheet skeleton.

## Tasks

### 1. Create `Shared/TweenPin.swift`
SwiftUI `View` with a `Role` enum: `.selfDot` (blue circle), `.selfActive` (green checkmark), `.friend` (orange square), `.midpoint` (teal star, larger). Each has a colored fill, white SF Symbol, and a halo ring (2pt stroke at 30% opacity). Add `symbolEffect(.pulse)` on `.selfActive` and `.midpoint`.

### 2. Build `TweenApp/OnboardingView.swift`
This is the primary host app view containing:

**State:** `savedCoordinate`, `peerCoordinate`, `isUserIn`, `provider` (LocationProvider), `position` (MapCameraPosition), `monitor` (NetworkMonitor), `selectedSheetDetent`.

**Map:** Full-screen SwiftUI `Map(position:)`. Shows self pin (dot or active based on `isUserIn`), peer pin if present, midpoint pin if both present. Camera starts at cached self location or San Francisco (37.7749, -122.4194) default.

**Bottom sheet:** `.sheet` with `.presentationDetents([.height(120), .fraction(0.48), .fraction(0.80)])`, `.presentationBackgroundInteraction(.enabled)`, `.presentationDragIndicator(.visible)`. Content: "I'm in" button + placeholder text. Starts at `.height(120)`.

**"I'm in" flow:** Tap → `provider.requestOnce()` → on success → `LocationCache.save(coord, isActive: true)` → pin animates to green checkmark → `.sensoryFeedback(.success)`.

**Leave flow:** Secondary button resets `isUserIn` and calls `LocationCache.save(coord, isActive: false)`.

**Poll task:** `.task { }` that reads `LocationCache.loadPeer()` every ~1s. When peer appears, update `peerCoordinate` and reframe camera.

### 3. Midpoint + camera helpers
Midpoint: average lat/lon of two coordinates.
Camera framing: given array of coordinates, return `MapCameraPosition` with 20% padding on span.

### 4. Update ContentView
Replace placeholder with `OnboardingView()`.

## Acceptance Criteria
- [ ] `Shared/TweenPin.swift` exists with Role enum and 4 pin styles
- [ ] `TweenApp/OnboardingView.swift` exists with map, sheet, "I'm in" flow
- [ ] All prior Shared/ files unchanged
- [ ] All prior test file unchanged
- [ ] No build tool invocations

## Constraints
- Do NOT implement search, ranking, or results — Phase 03
- Do NOT implement friends — Phase 05
- Do NOT add design tokens — Phase 07
- Do NOT run any build tools
- Commit with message: "feat: phase 02 — host app map with I'm-in flow and pin views"
