# AUDIT REPORT — Tween — 2026-09-06

Read-only post-push audit at HEAD `fc1809f` (after `2da3e7e` perf work and `fc1809f` camera-follow fix). No files were modified and no builds were run by the auditors.

**Coverage note.** The orchestrating auditor was cut off by a session rate limit before it could assemble the final report. Four of its seven sub-auditors completed and their findings are consolidated here: (1) OnboardingView core + the two recent commits, (2) OnboardingView feature extensions, SpotDetailCard, ResultRows, (3) Shared codec and stores (TweenState, Participant, ConversationMeetupStore, LocationCache, RosterMerge, all preference stores), (4) FairnessRanker, DeadlinedSearch, LocationProvider, NetworkMonitor, geometry helpers, TweenApp sheets, plists, entitlements, project.yml. **Not covered in this pass:** `TweenMessages/MessagesViewController*.swift` (the extension state machine), `Shared/ExpandedView*.swift` / `Shared/CompactView.swift`, `BubbleImageRenderer.swift`, and a systematic pass over `TweenAppTests/`. Sections 1 and 4 of the brief, and the test-coverage matrix, should be re-run when capacity allows.

## CRITICAL (will crash, corrupt state, or break core flow)

### Codec / revision ordering
- An inbound bubble with an absurdly large `rev` (up to `Int.max`) is stored unconditionally as the conversation's revision floor; the receiver's next `lastRevision + 1` mint traps on integer overflow, in both processes, and the sync key is TTL-exempt so it never heals. Any very large rev also rejects every later legitimate bubble as stale and propagates via floor+1 mints. — `Shared/TweenState.swift:~451`, `Shared/ConversationMeetupStore.swift:~441`, `TweenMessages/MessagesViewController+Decoding.swift:~188`, `TweenApp/OnboardingView+Actions.swift:~371`
  Suggested fix: reject `rev < 0 || rev > floor + 1_000_000` on decode and mint with `addingReportingOverflow`.

- The `pj=` JSON roster path skips coordinate validation (`Participant.init(from:)` never calls `validCoordinate`), so `lat: 200` flows into MKMapSnapshotter / MKDirections / CLLocation — the NSException class the 2026-08-07 audit closed for `lat`/`lon`. — `Shared/TweenState.swift:~402`, `Shared/Participant.swift:~78`
  Suggested fix: filter decoded participants through `validCoordinate`, or fall back to the compact `p=` path when any entry fails.

## MAJOR (wrong behavior, UX broken, data loss risk)

### Identity / consensus
- "Own proposal" detection in the host deep-link path is name-only (`state.senderName == myName`). A friend with your display name has their proposal treated as yours: peer coordinate not saved, reply banner suppressed, Agree/Change sheet never shown, "Waiting for them to agree" toast fires. `senderID` is available on the same line. — `TweenApp/OnboardingView+DeepLinks.swift:~58`
  Suggested fix: `state.senderID == TweenIdentity.stableID || (state.senderID == nil && state.senderName == myName)`.
- The Agree path is not wrapped in `ensureNamed`, so an unnamed user broadcasts the fallback "You" into `agreedNames`, `participants`, and the local roster entry — the "sanitize every name path" regression class. — `TweenApp/OnboardingView+DeepLinks.swift:~279`, `TweenApp/OnboardingView+FriendsPanel.swift:~1369`
  Suggested fix: `sendAgreeReply` → `ensureNamed { performAgreeReply(...) }`, mirroring `pingFriend`/`performPing`.

### Conversation scoping
- `lastActiveConversationKey` is set only by the extension on activation and never cleared in production, yet the host uses it as the sole key for every canonical write (local participant, leave, revision, proposed, agreed, draft binding). Peek chat C's drawer, then send from the host to friend A: A's roster, revision floor and tombstones are filed under C, and a stale leave tombstone under that key dams all global-mirror writes. — `Shared/ConversationMeetupStore.swift:~176`, `TweenApp/OnboardingView+Actions.swift:~434`, `Shared/LocationCache.swift:~127`
  Suggested fix: nil the key when its snapshot is TTL-expired or on cold launch with no live meetup; longer term let host sends choose their key.

### Search / keyboard (includes the two recent commits)
- Return while an autocorrect candidate is pending: UIKit commits the correction (`textDidChange`) then calls `searchBarSearchButtonClicked` in the same turn; `commitSearch` runs, but `.onChange(of: searchText)` fires on the next pass with `suppressNextQueryChange == false`, cancels the search and flips back to `.suggesting`. Autocorrect is deliberately ON. — `TweenApp/SearchCompleter.swift:~92`, `TweenApp/OnboardingView+Search.swift:~112, ~201`
  Suggested fix: defer `parent.onSubmit()` with `DispatchQueue.main.async` (same technique as the responder deferral) so the text-change lands first.
- `2da3e7e` drop-focus rule: the expected-motion window is a fixed 0.7 s from the focus edge, but the first keyboard presentation after a cold launch can exceed that on device (keyboard process spin-up). The keyboard-induced sheet motion is then read as a drag and the field is resigned the moment the keyboard appears. Not reproducible on the simulator (no software keyboard). — `TweenApp/OnboardingView.swift:~870`, `TweenApp/OnboardingView+BottomSheet.swift:~300`
  Suggested fix: arm/extend the window from `UIResponder.keyboardWillChangeFrameNotification`, or only allow the drop once the keyboard is known to be up.

### Sheet presentation
- `presentSpot` assigns `activeSheet = .spot(B)` while `.spot(A)` is presented (bubble tap / `onOpenURL` with a card up) — the iOS 26 dismiss-then-re-present drop the file documents; only the child `spotSubSheet` is disarmed, the new card itself can be lost. — `TweenApp/OnboardingView+FriendsPanel.swift:~1193`, `TweenApp/OnboardingView+DeepLinks.swift:~30`
  Suggested fix: if a spot sheet is up, nil `activeSheet` and park the new presentation in a pending action run from the sheet's `onDismiss` (the `pendingFriendSheetAction` pattern).

### Ranking / entitlement
- MKDirections fan-out is unbounded: one task per capped candidate × one per participant, up to 20 legs (40 when transit fails and each leg re-issues driving) all in flight at once, inviting `MKError.loadingThrottled`, which silently degrades legs to straight-line guesses. — `Shared/FairnessRanker.swift:~219, ~291, ~352`
  Suggested fix: limit concurrency (≈4 in flight) or chunk candidates.
- Two different straight-line driving speeds: the ranker's `fallbackSpeed` 13.4 m/s vs `mode.fallbackMetresPerSecond` 11.5 m/s used by `ResultCard`, which claims to show "the same numbers" — ~14% apart for the same leg. — `Shared/FairnessRanker.swift:~137, ~417`, `TweenApp/ResultRows.swift:~171`, `Shared/MeetupPlan.swift:~48`
  Suggested fix: delete `fallbackSpeed`; use `mode.fallbackMetresPerSecond` everywhere.
- Paywall scenePhase / initial refresh assign `unlocked = await refresh()` unconditionally; StoreKit's payment sheet bounces scenePhase as `buy()` completes, and a propagation-lag `false` flips the sheet back to plan cards and writes `false` into the App Group — the exact case `sawVerifiedPurchase` protects in `restore()`. — `TweenApp/PaywallSheet.swift:~83, ~98`, `Shared/ProEntitlement.swift:~101`
  Suggested fix: `let fresh = await refresh(); if !fresh && sawVerifiedPurchase { return }` in both places.

## MINOR (suboptimal, cleanup, hardening)

### Camera / map (`fc1809f`)
- `shouldReframe` fires on the first live fix regardless of `position.positionedByUser`; on a slow first fix (permission prompt, cold launch) a user who already panned gets yanked. — `TweenApp/OnboardingView.swift:~1102`
  Suggested fix: `if shouldReframe, !position.positionedByUser { reframe() }` (keep `awaitingImIn` unconditional).
- Three animated camera writes per committed search (`frameSearchResults` twice, then `frameResultsWithParticipants`). — `TweenApp/OnboardingView+Search.swift:~733, ~765, ~794`
  Suggested fix: keep only the final framing call.
- `midpointCoordinate` reimplements `MapGeometry.centroid(of:)`. — `TweenApp/OnboardingView+Search.swift:~24`
  Suggested fix: call the shared helper.
- Antimeridian: raw longitude averaging / min-max gives a wrong-side centroid and ~358° span; `padding 1.4` can exceed 180° latitude delta, which MKMapSnapshotter rejects. — `Shared/MapGeometry.swift:~37, ~61`
  Suggested fix: clamp deltas and take the shorter longitude arc.

### Sheets / alerts
- Plan sheet, tutorial cover and `activeSheet` all hang off the bottom-sheet content; a deep link while the plan sheet or the first-run tutorial is up sets `activeSheet = .spot` from a presenting VC and is silently dropped. — `TweenApp/OnboardingView.swift:~852-906`, `TweenApp/OnboardingView+BottomSheet.swift:~54`
  Suggested fix: guard `handleIncomingURL` — stash the selection and present from the respective `onDismiss` / `dismissTutorial`.
- `ensureNamed` routes the "Your Name" prompt to the root alert while a `.spot` sheet is up (Send from the place card for an unnamed user) — the W13 under-sheet-alert shape. — `TweenApp/OnboardingView+Actions.swift:~97`
  Suggested fix: park `showNamePrompt = true` in a pending action run from the spot sheet's `onDismiss`.
- Overlapping toasts: each `showToast` spawns an unkeyed 2 s task; a second toast within 2 s is cleared by the first timer. — `TweenApp/OnboardingView+FriendsSync.swift:~128`
  Suggested fix: keep the task in `@State`, cancel on re-entry.
- `openGroup` swaps `manualParticipants` without re-ranking; on-screen rankings stay scored against the old set while the group bar shows the new one. — `TweenApp/OnboardingView+FriendsPanel.swift:~242`
  Suggested fix: funnel a `rerankCurrentResults()` through `searchTask` like `addManualPoint`.
- Draft is staged (with a Darwin post) before `composeTweenMessage`; a nil compose returns silently with the draft still armed — the W7 hazard. — `TweenApp/OnboardingView+HandOff.swift:~131`
  Suggested fix: clear the draft and toast in the guard, or save after compose succeeds.
- `ABDistanceLabel` reads legacy positional `etaFromA/etaFromB`; with peer + manual points and no self fix, "A" is the peer's time. — `TweenApp/ResultRows.swift:~67`
  Suggested fix: resolve A by stable id / name like `SpotDetailCard.myDriveETA`, then delete the legacy accessors.

### Codec / stores
- Gossip cap (8) enforced only at the composers; decode accepts unbounded `gone=` and writes it into TTL-exempt sync state. — `Shared/TweenState.swift:~452`, `Shared/ConversationMeetupStore.swift:~404`
  Suggested fix: `.prefix(RosterMerge.gossipCap)` on decode.
- One invalid compact `p=` entry drops all `pids` (count mismatch) and the whole roster falls back to name ids. — `Shared/TweenState.swift:~409`
  Suggested fix: zip ids with entries before filtering.
- `RosterMerge` lets an accepted inbound bubble overwrite the local user's own roster entry (coordinate + `needsRide`), reverting a locally toggled, undelivered ride flag. — `Shared/RosterMerge.swift:~87`
  Suggested fix: never replace the entry matching `localContext` except from own sends.
- Pre-delivery save writes `isActive: LocationCache.isActive` (freshness-gated) instead of `isOptedIn`; a failed send with a >5 min cache leaves the user silently "out". — `TweenMessages/MessagesViewController+Sending.swift:~53, ~324`
  Suggested fix: pass `LocationCache.isOptedIn`.
- `isFullyAgreed` legacy name path loses multiplicity (`Set(agreedNames)`) and treats `senderName == nil` as proposer `""`, excluding unnamed legacy participants. Legacy senders only. — `Shared/TweenState.swift:~111`
  Suggested fix: compare as arrays with counts, or require ids.
- Snapshot TTL is refreshed by the activation-refresh save on every drawer open, so a dead meetup never expires while the user keeps opening Tween in that chat; only the extension deletes expired snapshots. — `Shared/ConversationMeetupStore.swift:~218`, `TweenMessages/MessagesViewController.swift:~284`
  Suggested fix: stamp `updatedAt` only on content changes.
- `conversationMeetup.sync.*` keys accumulate forever (never reaped in production). — `Shared/ConversationMeetupStore.swift:~350`
  Suggested fix: reap sync keys whose snapshot has been gone for a long window.
- `DriveTimePreference` falls back to `.standard` when the App Group suite is nil (invisible to the other process); every other store no-ops silently with no log. — `Shared/DriveTimePreference.swift:~22`, `Shared/LocationCache.swift:~59`
  Suggested fix: make it optional like its siblings; log/assert once in `LocationCache`.
- `.leave` carries the leaver's raw cached coordinate of any age. — `TweenMessages/MessagesViewController+Sending.swift:~152`, `TweenApp/OnboardingView+Actions.swift:~246`
  Suggested fix: send the map default centre; nothing pins a leave.

### Ranking / search / location
- `DeadlinedSearch` returns `[]` for both timeout and zero results, so the rescue ladder runs every rewrite rung (each up to 8 s) on a throttled search; worst case ~96 s of "Finding places…" with no overall budget. — `Shared/DeadlinedSearch.swift:~107`, `TweenApp/OnboardingView+Search.swift:~323, ~366`
  Suggested fix: return a `timedOut` flag and pass a shared deadline (~15 s) through the ladder.
- Ranking ties are non-deterministic (completion order, then score only), so the list can reorder between the estimated and routed passes. — `Shared/FairnessRanker.swift:~226`
  Suggested fix: secondary sort key.
- `LocationProvider` mutates `fixWatchdog` / `awaitingFirstFreshFix` from the delegate thread while the main actor writes them; theoretical since a main-created manager delivers on main. — `Shared/LocationProvider.swift:~268, ~340`
  Suggested fix: mark the class `@MainActor` or hop the whole delegate body.
- Extension offline banner is a one-time snapshot of `isOnline` at `presentUI`. — `TweenMessages/MessagesViewController.swift:~457`
  Suggested fix: `withObservationTracking` on `isOnline`.
- `SpotCategoryMark` substring matching without word boundaries ("inn" → Dinner Club gets the hotel glyph). — `Shared/SpotCategoryMark.swift:~93`
  Suggested fix: tokenise and match whole words.
- Calendar attendees filtered by raw id equality that the same file says is unsafe for legacy payloads. — `TweenApp/PlanMeetupSheet.swift:~259`
  Suggested fix: reuse the `matches` predicate.
- Inert "I'm out" button in the tutorial announces as a button and does nothing. — `TweenApp/OnboardingTutorial.swift:~430`
- `AddPointSheet` dismisses silently when a picked place doesn't resolve. — `TweenApp/AddPointSheet.swift:~69`
- Stale "300 ms" poll comments (poll is 2 s). — `TweenApp/OnboardingView.swift:~1207`, `TweenApp/OnboardingView+Sync.swift:~36, ~296`

## ARCHITECTURE NOTES
- `OnboardingView.swift`: `body` ≈ 499 lines, `init()` ≈ 159, `mapLayer` ≈ 99 — all over the 80-line bar. `presentSearchResults` ≈ 103. Extract the secondary-sheet switch and the DEBUG demo seeds.
- Unused imports across the `OnboardingView*` files (`MessageUI` in all four, `Combine` in three, plus `MapKit`/`CoreLocation`/`Messages`/`UIKit`/`os` in `+BottomSheet`, `Messages`/`UIKit` in `+Framing`, `MapKit`/`Messages`/`UIKit` in `+Sync`); `GroupStatusBar.swift` imports MapKit unused.
- Dead code: `FairnessRanker.rank(candidates:from:and:cap:)` (zero callers), `MapGeometry.midpoint` (zero callers), `CalendarExport.swift:25-27` unreachable `else` at iOS 17 target, dead property defaults in `GroupEditorSheet`, `AddPointSheet` `#Preview` previews the wrong view.
- Duplicated logic: participant-list building (app `buildRankingParticipants` vs extension `rankingParticipants()`), centroid (three copies), region framing (`MapGeometry.region` vs `participantsSearchRegion`), default-centre literal (three copies), straight-line ETA (two speeds). `formatETA` is single-sourced.
- `PlanMeetupSheet` decodes `MeetupPlanStore.current` three times at init.
- Styling bypassing `Tokens` in `GroupStatusBar`, `OnboardingTutorial`, `FriendsPanel` (documented Maps-parity colours in `SpotCategoryMark` excepted).
- The brief's file list is stale: `Shared/TweenViews.swift` no longer exists (views live in `ExpandedView*.swift` / `CompactView.swift`); `ResultRow`, `RankedResultRow`, `ETAChip` do not exist (the chip family is `SpotETAStrip`/`SpotETAChip`); the poll is 2 s, not 300 ms.
- The two recent commits were checked specifically: `2da3e7e`'s edge tracker, once-per-pass marker roles, cached suites and responder deferral are consistent and idempotent (findings above are the keyboard-timing window and the pre-existing Return/autocorrect race it makes more visible); `fc1809f`'s `shouldReframe` is a pure static with five unit cases (finding: `positionedByUser` not consulted).

## LEGACY DEBT INVENTORY
- `RankedSpot.etaFromA` / `etaFromB` / `worseETA` / `fairnessGap` — `Shared/FairnessRanker.swift:104-107`, 2-person init :111, DEBUG init :125. Production callers: `Shared/SpotETADisplay.swift:20,38` (empty-`etas` fallback), `TweenApp/ResultRows.swift:67,72` (`ABDistanceLabel`, live via `+FriendsPanel.swift:1325,1414`). Previews: `Shared/ExpandedView.swift:818-819`, `TweenApp/SpotDetailCard.swift:728`. Tests: `FairnessRankerTests`, `DriveTimePreferenceTests`, `MapGeometryTests`.
- `FairnessRanker.rank(candidates:from:and:cap:)` :240-251 — zero callers.
- "Slice" comments: `Shared/FairnessRanker.swift:101,110` (Slice 5), `:238` (Slice 3/6), `TweenMessages/MessagesViewController+Decoding.swift:19` (Slice 6; its "we replace, not merge" doc is now wrong).
- `LocationCache.saveParticipantSnapshot(_:localName:)` :197 — harness + tests only.
- `MeetupSnapshot.pendingDraft/lastRevision/localUserLeft/departedKeys` :91-94 — legacy-decode shims.
- `tween.cache.*.active` mirror keys and the `loadPeer`/`isPeerActive` single-peer projection (readers `ExpandedView.swift:166`, `OnboardingView+Sync.swift:145`).
- `tween.pro.redeemedCode` — reap-only by design.
- No `@available(*, deprecated)` in the repo.

## TEST COVERAGE GAPS
Not systematically audited this pass (the tests sub-auditor did not complete). Observed from the file-level passes:
- ConversationSyncState revision tie-breaking and the `.invite`-at-floor exception — not seen covered.
- Departure gossip propagation and the decode-side cap — no decode-side test (cap only exists at composers).
- `effectiveReceived` sticky rule and `deliverBubble` staged delivery — extension state machine not audited.
- MeetupSync posting/observing — no test.
- `isFullyAgreed` with duplicate names — covered for the ID path (`ParticipantCodecTests:234-254`), not for the legacy name path.
- `conversationKey` — covered (`ParticipantCodecTests:395-402`).
- `shouldReframe` — covered (`CameraReframeTests`, 5 cases).
- `rev` bounds / overflow — no test.
- `pj=` coordinate validation — no test.

## FIX-FIRST PRIORITY LIST
1. Bound `rev` on decode and mint with overflow checking (CRITICAL; permanent, cross-process, unrecoverable).
2. Validate `pj=` participant coordinates (CRITICAL; NSException from MapKit).
3. Own-proposal detection by `senderID` (MAJOR; wrong flow for name collisions).
4. Wrap the Agree path in `ensureNamed` (MAJOR; "You" leaks into payloads).
5. Defer `onSubmit` in the search bar so Return with autocorrect doesn't cancel its own search (MAJOR; common on device).
6. Arm the drop-focus window from the keyboard notification instead of a 0.7 s timer (MAJOR; guards the just-shipped `2da3e7e` on slow first keyboard).
7. Guard the `.spot → .spot` sheet swap with a pending action (MAJOR).
8. Clear or rescope `lastActiveConversationKey` (MAJOR; cross-chat state bleed).
9. Guard the paywall's scenePhase/initial refresh with `sawVerifiedPurchase` (MAJOR; downgrades a real purchase).
10. Limit MKDirections concurrency and unify the straight-line speed (MAJOR).
11. `positionedByUser` guard on the first-fix reframe (MINOR; polish on `fc1809f`).
12. Toast task keying, `openGroup` re-rank, draft-clear on nil compose, single camera framing per search (MINOR batch).
13. Re-run the uncovered sections: extension state machine, ExpandedView/CompactView, BubbleImageRenderer, and the test matrix.
