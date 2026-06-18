# Phase 04: iMessage Extension + Bubble Rendering

## Prior State
- Phase 03 complete. Host app has map, search, FairnessRanker, result rows, category chips. 12 tests written.
- `TweenMessages/MessagesViewController.swift` is a stub. No extension UI exists yet.
- No Xcode — do NOT run build tools. Read CLAUDE.md — especially memory constraints.

## Objective
Build the full iMessage extension: CompactView, ExpandedView, BubbleImageRenderer, and send/receive message flow.

## Tasks

### 1. Create `Shared/TweenViews.swift`
Lives in Shared/ so the host app can render these in the test harness (Phase 08).

**`TweenMapSnapshotView`:** Takes coordinates + pin descriptors, renders via `MKMapSnapshotter`, caches result in `@State`. Shows gray placeholder while loading.

**`CompactView`:** Keyboard-height. Parameters: `received: TweenState?`, `isUserIn: Bool`, `onImIn`, `onExpand`. Shows small map snapshot (or empty state), "I'm in" button. NO text fields, NO first responder. Entire view tappable to expand.

**`ExpandedView`:** Full-screen. Parameters: `received: TweenState?`, `selfCoord`, `rankedSpots: [RankedSpot]`, `isUserIn: Bool`, `onImIn`, `onSelectSpot: (RankedSpot) -> Void`. Shows large map snapshot, received state panel, horizontal fair-spot chips, primary CTA ("Send [name]" or "I'm in"), offline banner.

### 2. Create `TweenMessages/BubbleImageRenderer.swift`
Fully `static` — no instance state.

**`makeImage(state:selfCoord:peerCoord:) async -> UIImage`:** MKMapSnapshotter at 600×400 @3x. Composites: snapshot + dashed line between endpoints + colored pin halos + 56pt branded footer with spot name. Falls back to `fallbackImage()` on failure.

**`fallbackImage(spotName:) -> UIImage`:** Gradient + grid + abstract pins + spot name. No network needed.

**`composite(snapshot:state:selfCoord:peerCoord:) -> UIImage`:** UIGraphicsImageRenderer composition.

### 3. Implement `MessagesViewController.swift`
Full `MSMessagesAppViewController`:

**State:** `received: TweenState?`, `rankedSpots`, `rankingTask`, `sendTask`, `locationProvider`, `sentMessageCount`.

**Lifecycle:**
- `willBecomeActive`: Decode selectedMessage URL → received. Cache peer coord. Host CompactView or ExpandedView via UIHostingController.
- `willTransition(to:)`: Expanded → `kickOffRanking()`. Compact → cancel task.
- `didReceive`: Decode, cache peer, re-rank if expanded. Stamp `PingLog.lastIncomingReplyAt = Date()`.
- `willResignActive`: Cancel ALL tasks.

**Methods:**
- `kickOffRanking()`: Search midpoint × 1.6 region, rank cap **5**.
- `handleImIn()`: Use cached location or request new, compose TweenState, sendBubble.
- `sendChosenSpot(_ spot:)`: TweenState from spot, sendBubble.
- `sendBubble(state:)`: Encode URL, create MSMessage + MSSession, render bubble image, set MSMessageTemplateLayout, insert into conversation.

### 4. BubbleImageRenderer tests — `TweenAppTests/BubbleImageRendererTests.swift`
2 tests:
1. `fallbackImage` returns non-nil UIImage
2. `fallbackImage` image has 3:2 aspect ratio (600:400)

## Acceptance Criteria
- [ ] `Shared/TweenViews.swift` exists with CompactView, ExpandedView, TweenMapSnapshotView
- [ ] `TweenMessages/BubbleImageRenderer.swift` exists, fully static
- [ ] `TweenMessages/MessagesViewController.swift` implements full lifecycle
- [ ] `TweenAppTests/BubbleImageRendererTests.swift` exists with 2 tests
- [ ] Total: 14 test methods
- [ ] CompactView has NO text fields or first responder usage
- [ ] Extension ranking cap is 5 (not 8)
- [ ] No build tool invocations

## Constraints
- NEVER use `MKMapView` — `MKMapSnapshotter` only
- Compact view: NO keyboard, NO first responder
- Extension ranking cap: **5**
- Cancel ALL tasks in `willResignActive`
- Do NOT implement OutgoingDraft hand-off — Phase 06
- Do NOT run any build tools
- Commit with message: "feat: phase 04 — iMessage extension with bubble rendering"
