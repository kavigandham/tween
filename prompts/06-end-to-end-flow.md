# Phase 06: End-to-End Flow + Onboarding

## Prior State
- Phase 05 complete. Host app has map, search, ranking, friends, ping log. Extension has full send/receive. 22 tests written.
- Missing: host can't hand off spots to extension, no spot detail card, no onboarding.
- No Xcode — do NOT run build tools. Read CLAUDE.md.

## Objective
Wire the complete meetup flow: pick spot → detail card → "Send to chat" → extension opens with draft → bubble sent. Add first-run onboarding.

## Tasks

### 1. Create `Shared/OutgoingDraft.swift`
`struct OutgoingDraft: Codable, Equatable` with spotName, latitude, longitude, timestamp.

`enum OutgoingDraftStore`: `save(_:)`, `load() -> OutgoingDraft?`, `clear()`. App Group UserDefaults, key `"outgoingDraft"`.

### 2. Spot detail card in OnboardingView
When user taps a result row, show a detail overlay/card:
- Spot name (title), address, ETAChip (if ranked)
- Small map snapshot thumbnail (MKMapSnapshotter at ~200×150)
- **"Send to chat"** primary CTA
- "Open in Apple Maps" / "Open in Google Maps" secondary buttons
- Dismiss button

### 3. "Send to chat" flow
1. `OutgoingDraftStore.save(OutgoingDraft(...))` with spot's name + coordinate
2. Open Messages: `UIApplication.shared.open(URL(string: "sms:")!)`
3. User taps Tween in iMessage drawer → extension picks up draft

### 4. Extension handles drafts
In `MessagesViewController.willBecomeActive`:
- Check `OutgoingDraftStore.load()`. If draft exists → request `.expanded` → show draft in ExpandedView with "Send [name]" CTA.
- On confirm → `sendBubble()` with TweenState from draft → `OutgoingDraftStore.clear()`.

### 5. Onboarding tutorial
`fullScreenCover` shown when `OnboardingFlags.hasSeenOnboarding == false`.
7 cards (scrollable): Welcome, tap I'm in, friend taps I'm in, fair spots appear, pick a spot, it lands in iMessage, that's it. Each: icon area + headline + 1-2 lines body.
Dismiss → `OnboardingFlags.hasSeenOnboarding = true`.
Info button (ℹ️) on main screen to re-show.

### 6. Share/invite sheet
"Invite a friend" action opens `UIActivityViewController` with invite text.

### 7. Offline banner
Banner at top of OnboardingView when `monitor.isOnline == false`. Gates search.

### 8. Unit tests — `TweenAppTests/OutgoingDraftTests.swift`
3 tests: save/load round-trip, clear removes, overwrite replaces. Reset suite in setUp().

## Acceptance Criteria
- [ ] `Shared/OutgoingDraft.swift` exists
- [ ] Spot detail card shows on result tap with "Send to chat" CTA
- [ ] Extension checks for OutgoingDraft on activation
- [ ] Onboarding shows on simulated first launch (flag false)
- [ ] `TweenAppTests/OutgoingDraftTests.swift` with 3 tests
- [ ] Total: 25 test methods
- [ ] No build tool invocations

## Constraints
- Apple Maps deep link: `http://maps.apple.com/?ll=LAT,LON&q=NAME`
- Google Maps deep link: `comgooglemaps://?q=LAT,LON`
- Do NOT add design tokens — Phase 07
- Do NOT run any build tools
- Commit with message: "feat: phase 06 — end-to-end flow with onboarding and hand-off"
