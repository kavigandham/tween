# AUDIT REPORT — Tween — 2026-07-09 (HEAD `44a73ae`)

## CRITICAL (will crash, corrupt state, or break core flow)

No findings at ≥70% confidence. No force-unwraps, `as!`, or `try!` exist anywhere in view or shared code; all send/decode paths degrade rather than crash.

## MAJOR (wrong behavior, UX broken, data loss risk)

### State machine (extension)
- `sendAgreedPlace(_:)` is the only send path that never sets `isSending = true` / `sendStatusMessage` (`handleImIn` :802, `handleImOut` :885, `sendBubble` :1195 all do). The Agree CTA's `.disabled(isSending)` guard (`TweenViews.swift:1913`, whose comment exists precisely for this) therefore never engages: users can double-fire agreements mid-send (duplicate agree bubbles, skewed consensus counting) and get no "Sending…" feedback — `MessagesViewController.swift:~988`
  Suggested fix: set `isSending`/status at task start and clear in defer, mirroring the other three send paths.

### Extension map
- The interactive SwiftUI `Map` is permanently disabled: `usesStaticMapForCurrentState` is hardcoded `true`, so the `mapSection` gate always picks the snapshot. `interactiveMap` (:1183–1241), `mapPosition`/`cameraBounds`, pin-select camera fly-to, and the `mapDegraded`/`didReceiveMemoryWarning` fallback are all unreachable — the pan/zoom UX that CLAUDE.md's sanctioned exception exists to permit silently ships as a static image — `TweenViews.swift:~1250`
  Suggested fix: run the pending on-device memory profiling and flip the kill-switch, or commit to snapshots and delete the ~150-line dead interactive path plus the now-redundant fallback plumbing.

### Host UI (SwiftUI)
- `reframe()` runs unconditionally on every `refreshFromAppGroup()` — which fires on every Darwin post, every 2s poll tick, and scene reactivation — recentering the map camera even while the user is panning/zooming — `OnboardingView.swift:~3046`
  Suggested fix: reframe only when the marker set materially changes and never during an active user gesture.
- `pollPeer()`'s session-ended branch clears `selectedResult` directly, bypassing the detent-suppression wrapper every user-initiated clear uses (:~548), so the bottom sheet snaps from the user's drag position to peek mid-gesture — `OnboardingView.swift:~2989`
  Suggested fix: route poll-driven clears through the same suppressed-detent path as user actions.
- `.fullScreenCover(isPresented: $showTutorial)` (:587) and `.sheet(item: $activeSheet)` (:590) are attached to the same node: on first run, an incoming `tween://` proposal (`handleIncomingURL` → `activeSheet = .spot`, :~3236) cannot present under the active cover, and the friend's proposal is silently dropped — `OnboardingView.swift:~587`
  Suggested fix: queue the pending `SpotSelection` and present it when the tutorial dismisses.

## MINOR (suboptimal, cleanup, hardening)

### Send paths
- `sendToChat`'s `guard let appURL = state.encodedURL(scheme: "tween", host: "m") else { return }` sits above the whole send, so an encode failure also kills the `MFMessageCompose` SMS fallback that doesn't need the link — `OnboardingView.swift:~2414`
  Suggested fix: scope the guard to the rich-link branch only.
- The extension's send `catch` blocks write "Couldn't send" / `stagedDeliveryStatus` without checking `Task.isCancelled`, so the `willResignActive` cancel records a false failure that can survive same-conversation reactivation — `MessagesViewController.swift:~812/939`
  Suggested fix: treat `CancellationError` separately; reset transient send status on activation.
- `showToast` schedules a 2s `asyncAfter` dismissal it never cancels; a second toast inside the window is truncated by the first one's timer — `OnboardingView.swift:~2615`
  Suggested fix: cancel/replace the prior dismissal work item.

### Persistence
- `clearDraft` resurrection: `save()`'s `migrateDraftIfNeeded` re-copies a never-migrated legacy inline draft back into the draft key immediately after `clearDraft` removed it, violating its own "must not resurrect" contract. Latent today — every current caller runs a stripping `save()` first — but any future direct call on an unmigrated blob resurrects the draft — `ConversationMeetupStore.swift:~293`
  Suggested fix: strip the inline copy from the blob before removing the draft key (or suppress migration within that save).
- `save()`'s inline-revision fold calls `noteRevision(inlineRevision, key:)` with no sender; a legacy inline revision above the floor overwrites `lastRevisionSender` with nil, degrading the W2 tie-break to accept-all — `ConversationMeetupStore.swift:~200`
  Suggested fix: pass a sender through the fold, or backfill-only instead of overwriting.
- `MeetupSnapshot.proposedState`/`agreedState` setters and `LocationCache.saveAgreedMeetup` silently drop state when `encodedURL()` returns nil (oversize roster), leaving stale or missing terminal state — `ConversationMeetupStore.swift:~96`, `LocationCache.swift:~201`
  Suggested fix: fall back to a trimmed encoding or surface the failure instead of silently persisting nothing.

### URL codec & consensus
- `init?(url:)` accepts non-finite and out-of-range coordinates (`Double("nan")`/`"inf"` parse; the repo contains zero `CLLocationCoordinate2DIsValid`/`isFinite` guards), so one crafted bubble can poison ranking math and map rendering — `TweenState.swift:~323`
  Suggested fix: guard `isFinite` and lat/lon ranges during decode.
- Departure gossip is capped only at encode (`RosterMerge.gossipKeys` → `prefix(8)`); decode (:415) and `noteDeparted`'s union accept unbounded lists from a crafted URL into TTL-exempt `departedKeys` — `TweenState.swift:~415`
  Suggested fix: apply `gossipCap` on decode too.
- `isFullyAgreed`'s legacy name path (`senderID == nil` and `agreedIDs` empty): duplicate display names collapse — one "Alex" agreeing satisfies both, and a proposer sharing a participant's name excludes that participant from `needToAgree` — `TweenState.swift:~113`
  Suggested fix: refuse full-consensus on the name path when names aren't unique.

### Ranking & connectivity
- The extension's `kickOffRanking()` is not gated on `NetworkMonitor.isOnline` (the host gates both search and ranking): offline, it burns the full 8s timeout and then shows a generic empty state — `MessagesViewController.swift:~686`
  Suggested fix: short-circuit to the offline notice before searching.
- `FairnessRanker.rank` has no `Task.checkCancellation()` between sequential `MKDirections` calls and no per-candidate timeout; a cancelled ranking keeps issuing directions requests — `FairnessRanker.swift:~121`
  Suggested fix: check cancellation per candidate.

### View layer & docs
- `SpotDetailCard.onAgree` wiring silently no-ops when `selection.incoming == nil`; correct behavior depends on the button's render condition staying in lockstep with the callback's guard — `OnboardingView.swift:~651`
  Suggested fix: build the Agree/Change callbacks only when `incoming` exists.
- `primaryCTA` returns a bare `EmptyView()` when `canSendSpotFromCurrentPeople && selectedSpot == nil && !isRanking && rankedSpots.isEmpty`, leaving the CTA slot blank — `TweenViews.swift:~1861`
  Suggested fix: render the rank-prompt in that state combination.
- Three comments still describe a "300ms" peer poll; `pollPeer` actually sleeps 2s — `OnboardingView.swift:~720/2883/2993` vs `:~2871`
  Suggested fix: update the comments (or restore the intended cadence deliberately).
- Dead code cluster: `RankedResultRow` (+ its only consumer `ResultRow`) reachable solely from a `#Preview` (`ResultRows.swift:~160/165/359`); deprecated `BubbleImageRenderer.makeImage(state:selfCoord:peerCoord:)` has zero callers (:~89); `FairnessRanker.rank(candidates:from:and:cap:)` unused (:~140); `LocationProvider.requestOnceIfAuthorized` unused (:~76); `Tokens.Radius.pin`/`.pill` unused (:~118)
  Suggested fix: delete all of it.

## ARCHITECTURE NOTES
- `OnboardingView.swift` (3,478 lines) is effectively the entire host app. Methods over the 80-line bar: `body` ~238, `handleIncomingURL` ~157 (:3122), `refreshFromAppGroup` ~127 (:2900). `MessagesViewController.swift`: `decodeAndCache` ~121 (:262), `sendAgreedPlace` ~115 (:988), `willBecomeActive` ~83 (:131). `TweenViews.swift`: `primaryCTA` ~140 (:1760), `meetupSetView` ~112 (:1305).
- Dual identity namespaces: the extension keys identity to `MSConversation` participant UUIDs, the host to `TweenIdentity.stableID`. They meet in revision tie-breaks and roster merge; consistent per-bubble today, but a standing drift risk (seam documented at `OnboardingView.swift:~3330`).
- Host/extension duplicated logic that can drift: `midpoint` verbatim (`TweenViews.swift:22` vs `OnboardingView.swift:3411`), `initials` verbatim (`TweenViews.swift:1714` vs `OnboardingView.swift:~1450`), ETA formatting diverges (`ETAChip.mins` renders 3600s as "60 min", `formatETA` as "1h 0m" — `ResultRows.swift:90` vs `TweenViews.swift:637`), fairness tint thresholds diverge (3/8 min vs 300/900 s), miles formatting duplicated within `ResultRows.swift` (:152 vs :290).
- Cross-process persistence is last-writer-wins read-modify-write on the snapshot blob (no cross-process lock). Single-key atomic blobs prevent torn reads, not lost updates; the 2026-07 sync-state split correctly shields the hot fields (revision floor, tombstones) — residual exposure is concurrent participant-list writes.
- Two refresh channels (Darwin notification + 2s poll) both funnel into `refreshFromAppGroup`; the refresh is idempotent, but every post triggers a full snapshot decode plus `reframe()` (the mechanism behind the camera MAJOR).
- `MeetupSync`/`MeetupSyncToken` are implemented correctly: every canonical writer in `ConversationMeetupStore`, `LocationCache`, and `OutgoingDraftStore` posts after writing; `deinit` removes the Darwin observer with the same pointer it registered; delivery hops to the main queue.
- App Group key matrix is fully consistent: every key is constant-accessed with no orphaned, unread, or misspelled keys; legacy mirror keys (`tween.cache.self.active`/`peer.active`) are consulted only when a pre-split blob lacks the folded flag. `UserDefaults(suiteName:)` nil is never explicitly checked — silently absorbed by optional chaining everywhere.
- TTL hygiene verified: `clear()` removes snapshot + draft but preserves `ConversationSyncState` by design; `freshSelfCoordinate()`/`isActive` (which embeds the 5-minute freshness check) gates every payload-embed and ranking site; raw `loadSelf()` appears only in leave-bubble filler coordinates and display paths.
- SpotDetailCard at `44a73ae` is sound: `MKMapItemDetailViewController` and `MKMapItem.identifier` both gated behind `#available(iOS 18)` with an iOS 17/no-identifier fallback, correct `Coordinator`/delegate wiring, a single close affordance, and a properly `#if DEBUG` + launch-argument-gated demo hook. Host-target only; no keyboard, server, or API-key constraint impact.

## LEGACY DEBT INVENTORY
- `etaFromA`/`etaFromB` (decl `FairnessRanker.swift:62–63`): `TweenViews.swift:1292/1602/2050/2051`; `ResultRows.swift:55/56/58/70/74/83/137/142/168/246/359–361`; `SpotDetailCard.swift:160/332`; `FairnessRankerTests`, `MapGeometryTests:46–54`.
- `worseETA` (`FairnessRanker.swift:64`): tests only (`FairnessRankerTests:23`, `MapGeometryTests:47`) — no production callers.
- `fairnessGap` (`FairnessRanker.swift:65`): tests only (`FairnessRankerTests:29/32`, `MapGeometryTests:48`) — no production callers.
- Two-person DEBUG `RankedSpot` init (`FairnessRanker.swift:~83`): `SpotDetailCard` `#Preview:332` + tests.
- Deprecated `BubbleImageRenderer.makeImage(state:selfCoord:peerCoord:)` (`BubbleImageRenderer.swift:~89`): zero callers.
- "Slice" migration comments: `FairnessRanker.swift:59/68/138`, `MessagesViewController.swift:310`, `OnboardingView.swift:~3289`.
- `UserName` (`UserName.swift:31`) and `UserProfile` (`OnboardingFlags.swift:22`) both wrap the same `"userName"` key — two abstractions, one datum.
- `MeetupSnapshot` legacy-decode-only inline fields (`ConversationMeetupStore.swift:91–94`) plus their lazy-migration helpers.
- Legacy single-peer projection: `tween.cache.peer`/`.active` and `self.active` mirrors written on every save (`LocationCache.swift:57/91`), read only for pre-split blobs; name-based `saveParticipantSnapshot(localName:)` still called at `OnboardingView.swift:~410` (harness) and `:~2230`.
- `TweenState` still emits legacy `kind`/`action` params for pre-group clients (deliberate compatibility, revisit when the fleet upgrades).

## TEST COVERAGE GAPS
- `MessagesViewController.swift` is structurally untestable (the unit target `@testable import`s TweenApp only): `effectiveReceived` sticky-agreement rule and the `deliverBubble` staged-delivery path are both untested; `LocationCache.loadAgreedMeetup` has zero test references.
- `ConversationMeetupStore` snapshot TTL: no test ages `updatedAt` past 24h (only `clear()` mechanics are covered).
- `MeetupSync` Darwin post/observe: no tests.
- `TweenState` codec hardening untested: NaN/non-numeric coordinates, >5000-char encode-nil (`TweenState.swift:222`) and decode-side rejection (:325).
- `isFullyAgreed` duplicate-name coverage exists for the ID path only; the legacy name path (MINOR finding above) is untested.
- Zero-coverage files: `OnboardingFlags`, `BubbleCaption`, `NetworkMonitor`, `LocationProvider`, `Tokens`, `ResultRows`, `SpotDetailCard`, `FriendsPanel`, `CategoryPreset`, `OnboardingTutorial`.
- Well covered (for the record): revision tie-breaking including `lastRevisionSender` and the invite-at-floor exception (`ParticipantCodecTests:~676–800`), departure gossip + cap (`RosterMergeTests`), `freshSelfCoordinate` vs `loadSelf`, `Participant.matches` edge cases, `OutgoingDraft.shouldAdopt`.
- Quality: `testLaunchScreenshot` asserts nothing; `testStableIDMintsOnceAndPersists` cannot prove cross-run persistence (setUp wipes the suite); UI tests are harness-driven except `testFloatingMapControlsRespondToTaps`. No skipped/sleeping/disabled tests; setUp App-Group-reset convention holds (the two omitting classes touch no App Group state).

## FIX-FIRST PRIORITY LIST
1. Set `isSending` in `sendAgreedPlace` (`MessagesViewController.swift:~988`) — double-fire protection and feedback in the consensus-critical path.
2. Decide the interactive-map kill-switch (`TweenViews.swift:~1250`): profile on device, then re-enable or delete the dead path and fallback plumbing.
3. Gate `reframe()` (`OnboardingView.swift:~3046`) so background refreshes stop yanking the camera mid-gesture.
4. Route `pollPeer`'s `selectedResult` clear through detent suppression (`OnboardingView.swift:~2989`).
5. Queue `handleIncomingURL`'s proposal sheet behind the first-run tutorial cover (`OnboardingView.swift:~587`).
6. Scope `sendToChat`'s `encodedURL` guard to the rich-link branch so the SMS fallback survives (`OnboardingView.swift:~2414`).
7. Separate cancellation from failure in extension send tasks and reset `stagedDeliveryStatus` on activation (`MessagesViewController.swift:~812/939`).
8. Harden `TweenState` decode: finite/range coordinate guards and a decode-side gossip cap (`TweenState.swift:~323/415`).
9. Fix `clearDraft` strip-before-remove ordering and thread a sender through `save()`'s `noteRevision` fold (`ConversationMeetupStore.swift:~200/293`).
10. Gate extension ranking on connectivity and add per-candidate cancellation to `FairnessRanker` (`MessagesViewController.swift:~686`, `FairnessRanker.swift:~121`).
11. Close the guarding test gaps: snapshot TTL expiry, `MeetupSync`, codec hardening; extract `effectiveReceived` into `Shared/` to make the sticky rule testable.
12. Debt sweep: delete the dead-code cluster, unify the duplicated midpoint/initials/ETA/fairness helpers into `Shared/`, collapse `UserName`/`UserProfile`.
