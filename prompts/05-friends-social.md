# Phase 05: Friends + Social Layer

## Prior State
- Phase 04 complete. Full extension with CompactView, ExpandedView, BubbleImageRenderer. 14 tests written.
- OnboardingView has bottom sheet with search + results. No friends panel yet.
- No Xcode — do NOT run build tools. Read CLAUDE.md.

## Objective
Add friend roster, contact picker, per-friend ping log with relative timestamps, and a second tab in the bottom sheet.

## Tasks

### 1. Create `Shared/TweenFriend.swift`
`struct TweenFriend: Identifiable, Codable, Equatable` with id (UUID), name, optional contactIdentifier, optional handle.

`enum FriendRoster` with static methods: `load() -> [TweenFriend]`, `save(_:)`, `add(_:)`, `delete(id:)`, `rename(id:to:)`, `clear()`. All persist to App Group UserDefaults under key `"cachedFriends"`.

### 2. Create `Shared/PingLog.swift`
`enum PingLog`: `logPing(for friendID:)`, `lastPing(for:) -> Date?`. Stores `[String: Date]` dict under key `"pingLog"`.

`lastIncomingReplyAt: Date?` — get/set on App Group suite, key `"lastIncomingReplyAt"`.

`enum RelativeTime`: `static func string(from date:) -> String` — returns "just now" / "Xm ago" / "Xh ago" / "yesterday" / "Xd ago".

### 3. Add friends panel to OnboardingView
New state: `panelTab` (HomePanelTab: .map/.waiting), `friends`, `editorMode` (FriendEditor), `showContactSearch`, `lastReplyAt`, `pingTick`.

**Tab bar:** Segmented control at top of sheet. `.map` = search (existing). `.waiting` = friends.

**Friends panel:** Friend list with name, last ping relative time, swipe to rename/delete. "Add Friend" button → contact search sheet. Tap friend → stage SMS ping via `MFMessageComposeViewController` (or clipboard toast if no handle).

**Reply banner:** Across top of sheet (both tabs) when `PingLog.lastIncomingReplyAt < 1h ago`.

### 4. Contact search sheet
Modal that requests `CNContactStore` auth, searches by name, shows rows with name + phone/email. Tapping adds TweenFriend to roster.

### 5. Wire ping log
Tap friend → `PingLog.logPing(for:)` → increment `pingTick` → open SMS compose.

### 6. Extension: stamp reply
In `MessagesViewController.didReceive`, add `PingLog.lastIncomingReplyAt = Date()`.

### 7. Unit tests
**`TweenAppTests/FriendRosterTests.swift`** (5 tests): empty load, add two + ordering, rename keeps ID, delete reduces count, clear empties.

**`TweenAppTests/PingLogTests.swift`** (3 tests): log + retrieve within 1s tolerance, two friends independent, lastIncomingReplyAt round-trips.

Reset App Group suite in setUp() for both.

## Acceptance Criteria
- [ ] `Shared/TweenFriend.swift` and `Shared/PingLog.swift` exist
- [ ] OnboardingView has tab toggle between Search and Friends
- [ ] `TweenAppTests/FriendRosterTests.swift` with 5 tests
- [ ] `TweenAppTests/PingLogTests.swift` with 3 tests
- [ ] Total: 22 test methods
- [ ] No build tool invocations

## Constraints
- Do NOT implement onboarding tutorial — Phase 06
- Do NOT implement host→extension hand-off — Phase 06
- Do NOT add design tokens — Phase 07
- Do NOT run any build tools
- Commit with message: "feat: phase 05 — friend roster with ping log and contact picker"
