# AUDIT REPORT — Tween — 2026-07-09 (HEAD `8affc61`)

## CRITICAL (will crash, corrupt state, or break core flow)

No findings at ≥70% confidence. No force-unwraps, `as!`, or `try!` exist anywhere in view or shared code; all send/decode paths degrade rather than crash. The `8affc61` diff (one-tap place sheet, `SpotDetailCard` GeometryReader sizing, apple-design skill doc) introduces no crash paths; the deprecated `MKPlacemark(addressDictionary:)` init remains `#if DEBUG`-gated.

## MAJOR (wrong behavior, UX broken, data loss risk)

### State machine (extension)
- `sendAgreedPlace(_:)` is the only send path that never sets `isSending = true` / `sendStatusMessage` (`handleImIn` :802, `handleImOut` :885, `sendBubble` :1195 all do; verified unchanged at this HEAD). The Agree CTA's `.disabled(isSending)` guard (`TweenViews.swift:1913`, whose comment exists precisely for this) therefore never engages: users can double-fire agreements mid-send (duplicate agree bubbles, skewed consensus counting) and get no "Sending…" feedback — `MessagesViewController.swift:~987`
  Suggested fix: set `isSending`/status at task start and clear in defer, mirroring the other three send paths.

### Extension map
- The interactive SwiftUI `Map` is permanently disabled: `usesStaticMapForCurrentState` is still hardcoded `true` (:1249), so the `mapSection` gate always picks the snapshot. `interactiveMap`, `mapPosition`/`cameraBounds` (:1245), pin-select camera fly-to, and the `mapDegraded`/`didReceiveMemoryWarning` fallback are all unreachable — the pan/zoom UX that CLAUDE.md's sanctioned exception exists to permit silently ships as a static image — `TweenViews.swift:~1249`
  Suggested fix: run the pending on-device memory profiling and flip the kill-switch, or commit to snapshots and delete the ~150-line dead interactive path plus the now-redundant fallback plumbing.

### Host UI (SwiftUI)
- Selection↔sheet sync is one-directional after the `8affc61` one-tap rewiring, regressing the "agreement closes the spot UI" behavior. `onDismiss` (:590–595) syncs sheet→selection, but nothing syncs selection→sheet: the background clears of `selectedResult` in `refreshFromAppGroup` (:2960, on any agreed-meetup change) and `handleIncomingURL`'s fully-agreed branch (:3220) now only deselect an invisible pin behind the presented `.spot` modal — the place sheet stays up. At `44a73ae` these same clears dismissed the visible card (`sheetContent` branched on `selectedResult`). The user is left reading an orphaned place sheet while the negotiation moved on, the persistent sheet snaps to peek behind the modal, and the "Meeting at X — Y is in" toast (:3228) renders beneath it, so the agreement lands unseen — `OnboardingView.swift:~590/2960/3220`
  Suggested fix: when a programmatic clear of `selectedResult` fires while `activeSheet` is `.spot`, also set `activeSheet = nil` (i.e., make the deselect path close the sheet it opened).
- `reframe()` (:3017) runs on every `didChange` refresh (:2995) — Darwin post, 2 s poll tick, scene reactivation — and on every location-fix `onChange` (:699), with no user-gesture guard and no materiality check: any delta (peer coordinate jitter, a `needsRide` flip) recenters the map camera even while the user is panning/zooming — `OnboardingView.swift:~2995/3017`
  Suggested fix: reframe only when the marker set materially changes and never during an active user gesture.
- `.fullScreenCover(isPresented: $showTutorial)` (:587) and `.sheet(item: $activeSheet)` (:590) are attached to the same node: on first run, an incoming `tween://` proposal (`handleIncomingURL` → `activeSheet = .spot`, :3207) cannot present under the active cover, and the friend's proposal is silently dropped — `OnboardingView.swift:~587`
  Suggested fix: queue the pending `SpotSelection` and present it when the tutorial dismisses.

## MINOR (suboptimal, cleanup, hardening)

### One-tap flow residue (new in `8affc61`)
- The `.onChange(of: selectedResult)` else-branch writes `selectedSheetDetent` (:552–554) with no `suppressPollDetentWrites` gate — the self-jump gate (docs/ui-research.md §1) that `refreshFromAppGroup` carefully applies (:2968/:2987) is bypassed when the poll clears the selection. Currently shielded because a selection always has the `.spot` modal on top (the user can't be mid-drag), but it's a latent re-break for any future selection-clear without a modal — `OnboardingView.swift:~552`
  Suggested fix: gate the onChange detent write on `suppressPollDetentWrites` like every other background-driven write.
- The `-DEMO_SPOT_CARD` hook regressed: it seeds `_selectedResult` as an initial value (:454), but the place sheet now only opens from `.onChange(of: selectedResult)` (:549), which never fires for initial state — the flag now shows just a preselected pin at peek, no sheet, defeating the hook's purpose (real-place-data screenshot verification, commit `44a73ae`). Its comment (:441 "renders the in-sheet spot card") describes the deleted `spotCardSheet` — `OnboardingView.swift:~441/454`
  Suggested fix: present `activeSheet = .spot(...)` from the demo branch (e.g. in `.onAppear`) and update the comment.

### Send paths
- `sendToChat`'s `guard let appURL = state.encodedURL(scheme: "tween", host: "m") else { return }` (:2385) sits above the whole send, so an encode failure also kills the `MFMessageCompose` branch that doesn't use `appURL` — `OnboardingView.swift:~2385`
  Suggested fix: scope the guard to the pasteboard-fallback branch that actually embeds the link.
- The extension's send `catch` blocks write "Couldn't send" / `stagedDeliveryStatus` without checking `Task.isCancelled`, so the `willResignActive` cancel records a false failure that can survive same-conversation reactivation — `MessagesViewController.swift:~812/939`
  Suggested fix: treat `CancellationError` separately; reset transient send status on activation.
- `showToast` spawns an uncancelled 2 s dismissal Task; a second toast inside the window is truncated by the first one's timer — `OnboardingView.swift:~2586`
  Suggested fix: cancel/replace the prior dismissal task.

### Persistence
- `clearDraft` resurrection: `save()`'s `migrateDraftIfNeeded` re-copies a never-migrated legacy inline draft back into the draft key immediately after `clearDraft` removed it, violating its own "must not resurrect" contract. Latent today — every current caller runs a stripping `save()` first — but any future direct call on an unmigrated blob resurrects the draft — `ConversationMeetupStore.swift:~293`
  Suggested fix: strip the inline copy from the blob before removing the draft key (or suppress migration within that save).
- `save()`'s inline-revision fold calls `noteRevision(inlineRevision, key:)` with no sender; a legacy inline revision above the floor overwrites `lastRevisionSender` with nil, degrading the W2 tie-break to accept-all — `ConversationMeetupStore.swift:~200`
  Suggested fix: pass a sender through the fold, or backfill-only instead of overwriting.
- `MeetupSnapshot.proposedState`/`agreedState` setters and `LocationCache.saveAgreedMeetup` silently drop state when `encodedURL()` returns nil (oversize roster), leaving stale or missing terminal state — `ConversationMeetupStore.swift:~96`, `LocationCache.swift:~201`
  Suggested fix: fall back to a trimmed encoding or surface the failure instead of silently persisting nothing.

### URL codec & consensus
- `init?(url:)` accepts non-finite and out-of-range coordinates (`Double("nan")`/`"inf"` parse; zero `CLLocationCoordinate2DIsValid`/`isFinite` guards repo-wide), and departure gossip is capped only at encode (`RosterMerge.gossipKeys` → `prefix(8)`) — decode (:415) and `noteDeparted`'s union accept unbounded lists into TTL-exempt `departedKeys`. One crafted bubble can poison ranking math, map rendering, and the tombstone store — `TweenState.swift:~323/415`
  Suggested fix: guard `isFinite` + lat/lon ranges on decode and apply `gossipCap` decode-side too.
- `isFullyAgreed`'s legacy name path (`senderID == nil` and `agreedIDs` empty): duplicate display names collapse — one "Alex" agreeing satisfies both, and a proposer sharing a participant's name excludes that participant from `needToAgree` — `TweenState.swift:~113`
  Suggested fix: refuse full-consensus on the name path when names aren't unique.

### Ranking & connectivity
- The extension's `kickOffRanking()` (:686) is not gated on `NetworkMonitor.isOnline` (the host gates both search and ranking): offline, it burns the full 8 s timeout then shows a generic empty state. Compounding, `FairnessRanker.rank` has no `Task.checkCancellation()` between sequential `MKDirections` calls and no per-candidate timeout, so a cancelled ranking keeps issuing directions requests — `MessagesViewController.swift:~686`, `FairnessRanker.swift:~121`
  Suggested fix: short-circuit to the offline notice before searching; check cancellation per candidate.

### View layer & docs
- `SpotDetailCard.onAgree` wiring silently no-ops when `selection.incoming == nil` (:656–660); correct behavior depends on the button's render condition staying in lockstep with the callback's guard — `OnboardingView.swift:~656`
  Suggested fix: build the Agree/Change callbacks only when `incoming` exists.
- `primaryCTA` returns a bare `EmptyView()` when `canSendSpotFromCurrentPeople && selectedSpot == nil && !isRanking && rankedSpots.isEmpty`, leaving the CTA slot blank — `TweenViews.swift:~1861`
  Suggested fix: render the rank-prompt in that state combination.
- Three comments still describe a "300 ms" peer poll (:725/:2854/:2964); `pollPeer` actually sleeps 2 s (:2848) — `OnboardingView.swift`
  Suggested fix: update the comments (or restore the intended cadence deliberately).
- Dead code cluster: `RankedResultRow` (+ its only consumer `ResultRow`) reachable solely from a `#Preview` (`ResultRows.swift:~160/165/359`); deprecated `BubbleImageRenderer.makeImage(state:selfCoord:peerCoord:)` has zero callers (:~89); `FairnessRanker.rank(candidates:from:and:cap:)` unused (:~140); `LocationProvider.requestOnceIfAuthorized` unused (:~76); `Tokens.Radius.pin`/`.pill` unused (:~118)
  Suggested fix: delete all of it.

## ARCHITECTURE NOTES
- The `8affc61` diff itself is a net simplification and mostly sound: the intermediate spot card, `isSpotCardActive`, and `spotCardDetent` are cleanly deleted (no dangling references), and the persistent sheet's detent set is static again (`[peek, .fraction(0.45), .fraction(0.90)]`, :570) — eliminating the prior dynamically-recomputed-detents risk. The `SpotDetailCard` GeometryReader fix (:119–123) correctly hands the hosted `MapItemDetailView` a concrete size per detent with intentional bottom-safe-area bleed; detents `[.medium, .large]` (:128) are set on the sheet content. The one real defect is the one-directional selection↔sheet sync (MAJOR above). `.claude/skills/apple-design/SKILL.md` is documentation only — no target membership, no code impact.
- Prior MAJOR "pollPeer's `selectedResult` clear snaps the sheet mid-gesture" is downgraded, not fixed: the ungated detent write still fires (via the `.onChange` else-branch), but the redesign makes a selection always carry the `.spot` modal on top, so the user can no longer be dragging the persistent sheet when it lands (see the two one-tap MINORs).
- `OnboardingView.swift` (3,449 lines) is effectively the entire host app. Methods over the 80-line bar: `body` ~230 (:526), `handleIncomingURL` ~157 (:3093), `refreshFromAppGroup` ~127 (:2871). `MessagesViewController.swift`: `decodeAndCache` ~121 (:262), `sendAgreedPlace` ~115 (:987), `willBecomeActive` ~83 (:131). `TweenViews.swift`: `primaryCTA` ~140 (:1761), `meetupSetView` ~112 (:1305).
- Dual identity namespaces: the extension keys identity to `MSConversation` participant UUIDs, the host to `TweenIdentity.stableID`. They meet in revision tie-breaks and roster merge; consistent per-bubble today, but a standing drift risk (seam documented near `OnboardingView.swift:~3300`).
- Host/extension duplicated logic that can drift: `midpoint` verbatim (`TweenViews.swift:22` vs `OnboardingView.swift:3008`), `initials` verbatim, ETA formatting diverges (`ETAChip.mins` renders 3600 s as "60 min", `formatETA` as "1h 0m" — `ResultRows.swift:90` vs `TweenViews.swift:637`), fairness tint thresholds diverge (3/8 min vs 300/900 s), miles formatting duplicated within `ResultRows.swift` (:152 vs :290).
- Cross-process persistence is last-writer-wins read-modify-write on the snapshot blob (no cross-process lock). Single-key atomic blobs prevent torn reads, not lost updates; the 2026-07 sync-state split correctly shields the hot fields (revision floor, tombstones) — residual exposure is concurrent participant-list writes.
- Two refresh channels (Darwin notification + 2 s poll) both funnel into `refreshFromAppGroup`; the refresh is idempotent, but every accepted delta triggers a full snapshot decode plus `reframe()` (the mechanism behind the camera MAJOR).
- `MeetupSync`/`MeetupSyncToken` remain correct: every canonical writer in `ConversationMeetupStore`, `LocationCache`, and `OutgoingDraftStore` posts after writing; `deinit` removes the Darwin observer with the same pointer it registered; delivery hops to the main queue.
- App Group key matrix is fully consistent: every key is constant-accessed with no orphaned, unread, or misspelled keys; legacy mirror keys (`tween.cache.self.active`/`peer.active`) are consulted only when a pre-split blob lacks the folded flag. `UserDefaults(suiteName:)` nil is never explicitly checked — silently absorbed by optional chaining everywhere.
- TTL hygiene verified: `clear()` removes snapshot + draft but preserves `ConversationSyncState` by design; `freshSelfCoordinate()`/`isActive` gates every payload-embed and ranking site (host funnel `freshSelfCoordinateForSend`, :2434); raw `loadSelf()` appears only in leave-bubble filler coordinates and display paths.

## LEGACY DEBT INVENTORY
- `etaFromA`/`etaFromB` (decl `FairnessRanker.swift:62–63`): `TweenViews.swift:1292/1602/2050/2051`; `ResultRows.swift:55/56/58/70/74/83/137/142/168/246/359–361`; `SpotDetailCard.swift:169/341`; `FairnessRankerTests`, `MapGeometryTests:46–54`.
- `worseETA` (`FairnessRanker.swift:64`): tests only (`FairnessRankerTests:23`, `MapGeometryTests:47`) — no production callers.
- `fairnessGap` (`FairnessRanker.swift:65`): tests only (`FairnessRankerTests:29/32`, `MapGeometryTests:48`) — no production callers.
- Two-person DEBUG `RankedSpot` init (`FairnessRanker.swift:~83`): `SpotDetailCard` `#Preview:341` + tests.
- Deprecated `BubbleImageRenderer.makeImage(state:selfCoord:peerCoord:)` (`BubbleImageRenderer.swift:~89`): zero callers.
- "Slice" migration comments: `FairnessRanker.swift:59/68/138`, `MessagesViewController.swift:310`, `OnboardingView.swift:3266`.
- `UserName` (`UserName.swift:31`) and `UserProfile` (`OnboardingFlags.swift:22`) both wrap the same `"userName"` key — two abstractions, one datum.
- `MeetupSnapshot` legacy-decode-only inline fields (`ConversationMeetupStore.swift:91–94`) plus their lazy-migration helpers.
- Legacy single-peer projection: `tween.cache.peer`/`.active` and `self.active` mirrors written on every save (`LocationCache.swift:57/91`), read only for pre-split blobs. Name-based `saveParticipantSnapshot(localName:)` (`LocationCache.swift:152`) is down to a single production caller — the DEBUG harness (`OnboardingView.swift:409`); all live paths use the `localContext:` overload (correction to the prior report, which listed a second call site).
- `TweenState` still emits legacy `kind`/`action` params for pre-group clients (deliberate compatibility, revisit when the fleet upgrades).

## TEST COVERAGE GAPS
(Tests unchanged since `44a73ae`; carried forward.)
- `MessagesViewController.swift` is structurally untestable (the unit target `@testable import`s TweenApp only): `effectiveReceived` sticky-agreement rule and the `deliverBubble` staged-delivery path are both untested; `LocationCache.loadAgreedMeetup` has zero test references.
- `ConversationMeetupStore` snapshot TTL: no test ages `updatedAt` past 24 h (only `clear()` mechanics are covered).
- `MeetupSync` Darwin post/observe: no tests.
- `TweenState` codec hardening untested: NaN/non-numeric coordinates, >5000-char encode-nil (`TweenState.swift:222`) and decode-side rejection (:325).
- `isFullyAgreed` duplicate-name coverage exists for the ID path only; the legacy name path (MINOR finding above) is untested.
- Zero-coverage files: `OnboardingFlags`, `BubbleCaption`, `NetworkMonitor`, `LocationProvider`, `Tokens`, `ResultRows`, `SpotDetailCard`, `FriendsPanel`, `CategoryPreset`, `OnboardingTutorial`. The new one-tap selection→sheet flow (including the `onDismiss` deselect) has no UI-test coverage, and the `-DEMO_SPOT_CARD` hook it broke is referenced by no test.
- Well covered (for the record): revision tie-breaking including `lastRevisionSender` and the invite-at-floor exception (`ParticipantCodecTests:~676–800`), departure gossip + cap (`RosterMergeTests`), `freshSelfCoordinate` vs `loadSelf`, `Participant.matches` edge cases, `OutgoingDraft.shouldAdopt`.
- Quality: `testLaunchScreenshot` asserts nothing; `testStableIDMintsOnceAndPersists` cannot prove cross-run persistence (setUp wipes the suite); UI tests are harness-driven except `testFloatingMapControlsRespondToTaps`. No skipped/sleeping/disabled tests; setUp App-Group-reset convention holds.

## FIX-FIRST PRIORITY LIST
1. Set `isSending` in `sendAgreedPlace` (`MessagesViewController.swift:~987`) — double-fire protection and feedback in the consensus-critical path.
2. Make the programmatic `selectedResult` clears also close the presented `.spot` sheet (`OnboardingView.swift:~590/2960/3220`) — restores the "agreement closes the spot UI" behavior the one-tap rewiring regressed.
3. Decide the interactive-map kill-switch (`TweenViews.swift:~1249`): profile on device, then re-enable or delete the dead path and fallback plumbing.
4. Gate `reframe()` (`OnboardingView.swift:~2995/3017`) so background refreshes stop yanking the camera mid-gesture.
5. Queue `handleIncomingURL`'s proposal sheet behind the first-run tutorial cover (`OnboardingView.swift:~587`).
6. Gate the `.onChange(of: selectedResult)` detent write on `suppressPollDetentWrites` and repair the `-DEMO_SPOT_CARD` hook (`OnboardingView.swift:~552/441`).
7. Scope `sendToChat`'s `encodedURL` guard to the branch that embeds the link (`OnboardingView.swift:~2385`).
8. Separate cancellation from failure in extension send tasks and reset `stagedDeliveryStatus` on activation (`MessagesViewController.swift:~812/939`).
9. Harden `TweenState` decode: finite/range coordinate guards and a decode-side gossip cap (`TweenState.swift:~323/415`).
10. Fix `clearDraft` strip-before-remove ordering and thread a sender through `save()`'s `noteRevision` fold (`ConversationMeetupStore.swift:~200/293`).
11. Gate extension ranking on connectivity and add per-candidate cancellation to `FairnessRanker` (`MessagesViewController.swift:~686`, `FairnessRanker.swift:~121`).
12. Close the guarding test gaps: snapshot TTL expiry, `MeetupSync`, codec hardening, the one-tap selection→sheet flow; extract `effectiveReceived` into `Shared/` to make the sticky rule testable.
13. Debt sweep: delete the dead-code cluster, unify the duplicated midpoint/initials/ETA/fairness helpers into `Shared/`, collapse `UserName`/`UserProfile`.
