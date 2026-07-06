# Tween — Handoff for a Fresh Session

## 1. What Tween is

Serverless, iMessage-native meetup coordinator: friends share locations in a chat and the app proposes fair spots to meet by drive time. Two targets — the host app and the Messages extension — share App Group `group.com.kavigandham.tween`; there is no backend.

## 2. Architecture mental model

- `Shared/TweenState.swift` — **the message.** URL payload in `MSMessage.url`: text, coord, sender id/name, `MessageType` (invite/leave/propose/agree/counter), `participants`, `agreedIDs`.
- `Shared/ConversationMeetupStore.swift` — **per-chat memory.** Keyed by `base64(sorted(localID + remoteIDs))`. Holds `MeetupSnapshot` (participants, proposedState, agreedState, pendingDraft). App Group `UserDefaults` backed.
- `Shared/LocationCache.swift` — **local device cache.** Self/peer coord + participants + sticky `agreedMeetup` (URL-encoded terminal state). Same App Group suite. `freshnessWindow = 5 min`.
- `TweenMessages/MessagesViewController.swift` — **the state machine.** Owns `willBecomeActive`/`willTransition`/`didReceive`/`willResignActive`/`didReceiveMemoryWarning`, decoding, ranking, outgoing bubble composition. Hosts SwiftUI via `UIHostingController`.

## 3. Stack

- Swift 5.9, iOS 17+, SwiftUI (`@Observable`, `@State`, `@Bindable`).
- Messages: `MSMessagesAppViewController`, `MSMessage`, `MSConversation`, `MSMessageTemplateLayout`, `MSSession`.
- CoreLocation: `CLLocationManager` via `LocationProvider` (retained stored property).
- MapKit: `MKLocalSearch` (extension + app quick spots), `MKLocalSearchCompleter` (host search), `MKDirections` (fairness ranking), `MKMapSnapshotter` (extension bubbles + static fallback). Host app uses SwiftUI `Map` (interactive) only.
- No third-party deps. No accounts. No backend.

## 4. HARD RULES — never break

1. **Keep diffs minimal, one bug per commit.** The decode core (`effectiveReceived`, `decodeAndCache`) and the `TweenState` URL codec are load-bearing and covered by tests — do not restructure them; prefer additive changes with `nil` defaults.
2. **Delivery is send-with-insert-fallback.** Messages honors `conversation.send()` only right after a detected user tap while the extension is visible (one send per interaction — WWDC17 Direct Send API); our sends run seconds later (location fix, snapshot render). `deliverBubble` therefore falls back to `conversation.insert()` (staged bubble, "tap send to deliver") when direct send throws. Never remove the fallback or add pre-send awaits without re-testing delivery.
3. **State commits are delivery-gated.** `handleImIn` / `handleImOut` / `sendAgreedPlace` commit rosters, activation, and the sticky agreed cache only after `deliverBubble` returns true. A failed send must never leave a device claiming "You're in" / "out" / MEETUP SET. Preserve this ordering in any edit.
4. **AGREE is terminal.** Once `state.isFullyAgreed`, no code path reopens negotiation. Sticky `LocationCache.saveAgreedMeetup` + `ConversationMeetupStore.saveAgreed` enforce this across relaunch. Only `.counter` and `.leave` clear the agreed cache.
5. **`MSMessage.url` ≤ 5000 chars, `https`/`file`/`tween` scheme only.** Coordinates + name + roster only — never route geometry.
6. **`MKMapSnapshotter` only in the extension.** Never `MKMapView`. ~120 MB extension ceiling. Rank cap: 5 in extension, 8 in app. `didReceiveMemoryWarning` swaps to static via `mapDegraded`.
7. **`CLLocationManager` must be retained.** Owned by `LocationProvider`; never construct inline.
8. **Compact view = keyboard height, no first responder, no keyboard, no text input.**
9. **App Group `UserDefaults` is unencrypted.** Coordinates and preferences only. **Atomic single-key JSON writes** (prevents torn reads).

## 5. Verification reality

This Mac has full Xcode 16 installed but `xcode-select` points at CommandLineTools — prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

- Build: `DEVELOPER_DIR=… xcodebuild build -project TweenApp.xcodeproj -scheme TweenApp -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO` → look for `** BUILD SUCCEEDED **`.
- Unit tests: same prefix plus `export PATH="$DEVELOPER_DIR/usr/bin:$PATH"`, then `xcodebuild test … -destination 'platform=iOS Simulator,name=iPhone 16'`. The full 87-test suite ran green on 2026-07-05; if CoreSimulator throws `Mach error -308`, recover with `killall -9 com.apple.CoreSimulator.CoreSimulatorService; simctl shutdown all; simctl erase <udid>; simctl boot <udid>` and retry once before falling back to build-only.
- Simulator cannot verify App Group sharing (built with `CODE_SIGNING_ALLOWED=NO`, entitlements not embedded) or real iMessage delivery — those are **two-device checks** per `TESTING.md`.

**File-existence checks are NOT a gate** — a green `Read` result proves the file exists, not that the change compiles or behaves.

## 6. Directory structure

```
Shared/              Compiled into BOTH targets (not a framework)
  TweenState.swift              — bubble URL payload
  ConversationMeetupStore.swift — per-chat snapshot store
  LocationCache.swift           — device/App-Group coord cache
  Participant.swift             — id/name/coord/needsRide
  TweenViews.swift              — CompactView, ExpandedView, TweenMapSnapshotView, MapGeometry
  TweenPin.swift, Tokens.swift, BubbleCaption.swift, PingLog.swift, OutgoingDraft.swift, ...
TweenApp/            Host app (SwiftUI lifecycle)
  OnboardingView.swift          — full-screen map + sheet + search + friends
  ContentView.swift, FriendsPanel.swift, HarnessView.swift, SpotDetailCard.swift, ...
TweenMessages/       iMessage extension
  MessagesViewController.swift  — state machine
  BubbleImageRenderer.swift     — snapshotter → UIImage for MSMessageTemplateLayout.image
TweenAppTests/       Unit tests
TweenAppUITests/     UI tests
project.yml          XcodeGen source (generates .xcodeproj)
```

`Shared/` is listed under BOTH `TweenApp` and `TweenMessages` in `project.yml`.

## 7. Current verified state

- **HEAD:** `ace1ae5` — "fix: keep decoded leave state when snapshot restore runs"
- **Tests:** 87 unit (executed green on the iPhone 16 simulator, 2026-07-05) / 6 UI (not run this session)
- **Group-flow + delivery fix stack (2026-07-05, all built + unit-tested):**
  - `738e588` direct-send rejection falls back to `insert()` — root cause of "I'm in / I'm out don't work" was `7e626d1` switching to gated `conversation.send()`
  - `5fdcc9c` / `2d0dca6` / `b9df404` I'm-in roster, leave clears, and agreement persistence are all delivery-gated (no more false "You're in" / phantom MEETUP SET)
  - `94b3a55` every not-in invite recipient gets the join hero — 3rd+ group member could not join before
  - `a553f26` `Participant.matches(context:)` name fallback gated to legacy id-less entries (+4 tests) — same-named peers (default "You") no longer count as the local user
  - `ace1ae5` tapping a leave bubble shows the "X left" banner instead of clobbering it
- **Leave→map fixes (2026-07-06):**
  - `439c2cb` leaving also clears `received` — the leaver's compact thumbnail + expanded map drew peer pins from `received.participants`, keeping everyone visible after I'm out
  - `dcf6771` `CompactView.markers` legacy branch uses `representsParticipantLocation` — an empty-roster `.leave` no longer pins the leaver's own coordinate as a friend on the receiver
  - Host-app map needed no change: `OnboardingView` polls `LocationCache` every 300 ms and both leave paths already clear it
- **Earlier shipped:** UI overhaul, half-sheet default, map-stays-still snapshot cache, zoom-to-fit, group meetup state with stable IDs (`agreedIDs`, `Participant.id` UUID-first), conversation-scoped state via `ConversationMeetupStore`, Dynamic-Type map controls, native-scale snapshots.
- **Known deferred:** legacy mixed-build payload edges (compact `p=` drops IDs; URL >5000 → nil); first-run permission alert can outlive the 5 s location poll (second tap works); compact roster pill counts from `received` (stale until the peer replies); `usesStaticMapForCurrentState` hardcodes `true` so ExpandedView's interactive `Map` is dead code; a closed extension only learns of updates when its user taps the bubble (serverless reality); **old-bubble resurrection** — after leaving, tapping an OLDER bubble re-decodes its roster verbatim, so the leaver re-appears "in" (and re-pinned) on that device until a newer bubble is tapped; every bubble is a canonical roster snapshot with no ordering info, and a real fix needs a monotonic counter/tombstone in the URL payload (protocol change).

## 8. Known fragile areas

- **Identity fallback to names.** iMessage's per-conversation UUID (`localParticipantIdentifier`) is device-scoped: a peer's roster entry carries a UUID minted on THEIR device, so ID mismatch is normal for peers. Both `Participant.matches(id:name:)` and `matches(_ context:)` are now strict: name fallback only for legacy entries with `id == name` (or contexts without a real UUID — nil, or name-as-id like `OnboardingView.sendAgreeReply`). Loosening either overload reintroduces "Bug #4" (same-named peer counted as the local user). `ParticipantCodecTests` pins the matrix.
- **Delivery ordering.** The tap → `acquireLocation` (≤5 s) → `BubbleImageRenderer.makeImage` (untimed snapshotter) → `send()` pipeline is what makes direct send fail; anything that lengthens it increases fallback frequency. The staged-fallback status string ("Added to the message box — tap send to deliver.") is preserved by guards in `handleImIn`/`handleImOut`/`sendBubble` — don't blindly reset `sendStatusMessage` on `didSend`.
- **App-vs-extension context.** `activeConversation` is nil-able and extension-only. `MessagesViewController.localParticipantID()` falls back to `Self.localParticipantName()` (`UserProfile.displayName ?? UserName.fallback == "You"`). Host-app paths must not assume a UUID exists.
- **Blank extension render.** `embed()` sets `.systemBackground` on both the extension VC and the `UIHostingController`. `retryBlankRenderIfNeeded()` re-runs `presentUI` on the next runloop tick and again at +150 ms if bounds are empty. Do not remove without a proven replacement.
- **Sticky agreed vs. counter/leave.** `effectiveReceived` prefers `ConversationMeetupStore` scoped agreement, then `LocationCache.loadAgreedMeetup`, then overrides `decoded` only when the tap is nil or the same spot (1e-4 deg epsilon). Missing either clear-path (`.counter`, `.leave`) leaves stale MEETUP SET rendering.
- **Snapshot restore gate.** In `willBecomeActive` the store restore runs only when `!decodedIncoming && received == nil` — `decodeAndCache` returns true only when a PEER COORDINATE was saved, so a decoded `.leave` reports false; dropping the `received == nil` gate re-clobbers the "X left" banner.
- **Ranking source-of-truth ambiguity.** `rankingParticipants()` prefers `received.participants` when it has ≥2 and `currentParticipants` has <2; otherwise prefers current, then received, then `ConversationMeetupStore` snapshot. Code that writes `currentParticipants` mid-flight can flip which branch wins.
