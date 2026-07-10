# AUDIT REPORT — Tween — 2026-07-09 (HEAD `bb6740d`)

## CRITICAL (will crash, corrupt state, or break core flow)

No findings at ≥70% confidence. The `bb6740d` delta (two commits, confined to `TweenApp/OnboardingView.swift` + `TweenApp/SpotDetailCard.swift`) introduces no force-unwraps, `as!`, or `try!`; the new async rebuild machinery is cancellation-safe (see Architecture Notes); the deprecated `MKPlacemark(addressDictionary:)` init remains `#if DEBUG`-gated. All other files are byte-identical to `8affc61`, whose no-crash verdict carries forward.

## MAJOR (wrong behavior, UX broken, data loss risk)

### State machine (extension)
- `sendAgreedPlace(_:)` is the only send path that never sets `isSending = true` / `sendStatusMessage` (Task starts at :989 with neither; `handleImIn` :802, `handleImOut` :885, `sendBubble` :1195 all do — re-verified unchanged at this HEAD). The Agree CTA's `.disabled(isSending)` guard (`TweenViews.swift:1913`, whose comment exists precisely for this) therefore never engages: users can double-fire agreements mid-send (duplicate agree bubbles, skewed consensus counting) and get no "Sending…" feedback — `MessagesViewController.swift:~987`
  Suggested fix: set `isSending`/status at task start and clear in defer, mirroring the other three send paths.

### Extension map
- The interactive SwiftUI `Map` is permanently disabled: `usesStaticMapForCurrentState` is still hardcoded `true` (:1249–1251), so the `mapSection` gate always picks the snapshot. `interactiveMap`, `mapPosition`/`cameraBounds`, pin-select camera fly-to, and the `mapDegraded`/`didReceiveMemoryWarning` fallback are all unreachable — the pan/zoom UX that CLAUDE.md's sanctioned exception exists to permit silently ships as a static image — `TweenViews.swift:~1249`
  Suggested fix: run the pending on-device memory profiling and flip the kill-switch, or commit to snapshots and delete the ~150-line dead interactive path plus the now-redundant fallback plumbing.

### Host UI (SwiftUI)
- NEW: every successful "Send to chat" now re-presents the place sheet it just closed. `sendToChat`'s `onSent` (:2430) and the own-proposal deep link (`openedOwnProposal`, :3199–3201) both call `showOwnProposalOnMap` (:3271–3282), whose contract is pin-at-peek + `activeSheet = nil` (:3277) + "Waiting for them to agree" toast (:3281) — but its `selectedResult = item` (:3276) trips the one-tap `.onChange` if-branch (:545–551), which unconditionally presents `activeSheet = .spot(...)`, overriding the nil it set one line earlier. The sender lands back in a full place sheet (fallback layout offering "Send to chat" AGAIN — an invitation to double-propose) with the waiting toast buried beneath it. Introduced at `8affc61` by the one-tap rewiring; not addressed by this HEAD's deselect fix — `OnboardingView.swift:~545/2430/3271`
  Suggested fix: route programmatic waiting-pin selection around the presentation path (an explicit `presentSpot()` intent for user taps, or a consume-once flag `showOwnProposalOnMap` sets that the onChange checks).
- NEW (residue of the prior "orphaned sheet" MAJOR — the selection path is fixed, this path is not): URL-driven proposal sheets still orphan. `handleIncomingURL`'s propose/counter branch presents `.spot` WITHOUT setting `selectedResult` (:3214–3227), so the fully-agreed `.agree` branch's `selectedResult = nil` (:3240) clears an already-nil value — no `.onChange` fires, and the new close-the-sheet logic (:560) never runs. Same for `.leave` (:3258–3267). A user reading a friend's Agree/Change proposal card keeps it up over a finished (or abandoned) negotiation while "Meeting at X — Y is in." (:3248) renders invisibly beneath — `OnboardingView.swift:~3227/3240/3258`
  Suggested fix: in the `.agree`-fully-agreed and `.leave` branches, explicitly dismiss a presented `.spot` whose selection is `incoming`.
- `reframe()` (:3037) runs on every `didChange` refresh (:3014–3015) — Darwin post, 2 s poll tick, scene reactivation — and on every location-fix `onChange` (:694→:713), with no user-gesture guard and no materiality check: any delta (peer coordinate jitter, a `needsRide` flip) recenters the map camera even while the user is panning/zooming — `OnboardingView.swift:~3015/3037`
  Suggested fix: reframe only when the marker set materially changes and never during an active user gesture.
- `.fullScreenCover(isPresented: $showTutorial)` (:601–603) and `.sheet(item: $activeSheet)` (:604) are attached to the same node: on first run, an incoming `tween://` proposal (`handleIncomingURL` → `activeSheet = .spot`, :3227) cannot present under the active cover, and the friend's proposal is silently dropped — `OnboardingView.swift:~601`
  Suggested fix: queue the pending `SpotSelection` and present it when the tutorial dismisses.

## MINOR (suboptimal, cleanup, hardening)

### One-tap flow residue
- The `suppressPollDetentWrites` gate added to the `.onChange(of: selectedResult)` else-branch (:564) never engages: the flag is set and reset synchronously via `defer` inside `pollRefreshFromAppGroup` (:2884–2885), but SwiftUI runs `onChange` actions in the FOLLOWING view-update pass — by then the defer has already reset the flag to false, so the poll-driven deselect always restores the peek detent despite the comment claiming otherwise. Still shielded in practice (a selection always has the `.spot` modal on top, so the user can't be mid-drag), but the fix this HEAD ships for the prior audit's finding is dead code — `OnboardingView.swift:~564/2884`
  Suggested fix: latch suppression across the update (a flag the onChange consumes and clears) instead of a transient defer-scoped flag.

### Place sheet (new in `bb6740d`)
- The settled-detent rebuild (`.id(detailRebuild)` + `.task(id: detent)` + 450 ms sleep, :167–175) has three rough edges: (a) each rebuild destroys and recreates `MKMapItemDetailViewController`, resetting the detail's internal scroll position — a user who scrolled at `.medium` then expands loses their place; (b) 450 ms is an empirical constant with no tie to the actual sheet spring — on slow devices or non-default motion timing the rebuild can re-pin to a mid-animation size, the exact bug it exists to fix; (c) size changes that arrive WITHOUT a detent change (iPad rotation — `project.yml` doesn't restrict device family and the iPad Info.plist allows landscape) never trigger a rebuild, resurrecting the stuck-at-old-size layout. Additionally `updateUIViewController` (:36–46) reassigns `vc.mapItem = item` on every update, and since `size` is a stored property fed by GeometryReader, updates fire on every frame of an interactive detent drag — `SpotDetailCard.swift:~36/167`
  Suggested fix: key the rebuild on settled geometry (rebuild when `geo.size` stops changing and differs from the built size) and guard the `mapItem` reassignment behind an identity check.
- Tile row gaps: (a) the drive tile's accessible name is its visible label — "12 min" (:260–263) — so VoiceOver announces a bare duration as the button name with the action ("directions") relegated to the hint; (b) the incoming-proposal tile variant (`incoming != nil` + `richDetailItem != nil`, :241–243) is unreachable — the only code that sets `incoming` synthesizes an identifier-less `MKMapItem` (`OnboardingView.swift:3214–3227`), so incoming cards always take the fallback layout and the Agree/Change-plus-tiles combination never renders; (c) the `tel:`/website URL construction is duplicated verbatim between `actionTiles` (:256–258) and the fallback's `contactButtons` (:420–422) — `SpotDetailCard.swift:~241/256`
  Suggested fix: add `.accessibilityLabel("Directions…")` to the drive tile; either resolve incoming coordinates to an identified place or delete the unreachable branch; hoist the URL builders.

### Send paths
- `sendToChat`'s `guard let appURL = state.encodedURL(scheme: "tween", host: "m") else { return }` (:2405) sits above the whole send, so an encode failure also kills the `MFMessageCompose` branch that doesn't use `appURL` — `OnboardingView.swift:~2405`
  Suggested fix: scope the guard to the pasteboard-fallback branch that actually embeds the link.
- The extension's send `catch` blocks write "Couldn't send" / `stagedDeliveryStatus` without checking `Task.isCancelled`, so the `willResignActive` cancel records a false failure that can survive same-conversation reactivation — `MessagesViewController.swift:~812/939`
  Suggested fix: treat `CancellationError` separately; reset transient send status on activation.
- `showToast` spawns an uncancelled 2 s dismissal Task (:2608–2611); a second toast inside the window is truncated by the first one's timer — `OnboardingView.swift:~2606`
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
- `SpotDetailCard.onAgree` wiring silently no-ops when `selection.incoming == nil` (:670–674); correct behavior depends on the button's render condition staying in lockstep with the callback's guard — `OnboardingView.swift:~670`
  Suggested fix: build the Agree/Change callbacks only when `incoming` exists.
- `primaryCTA` returns a bare `EmptyView()` when `canSendSpotFromCurrentPeople && selectedSpot == nil && !isRanking && rankedSpots.isEmpty`, leaving the CTA slot blank — `TweenViews.swift:~1861`
  Suggested fix: render the rank-prompt in that state combination.
- Docs & dead code: three comments still describe a "300 ms" peer poll (:739/:2874/:2984) while `pollPeer` sleeps 2 s (:2868); dead code cluster unchanged — `RankedResultRow` (+ its only consumer `ResultRow`) reachable solely from a `#Preview` (`ResultRows.swift:~160/165/359`), deprecated `BubbleImageRenderer.makeImage(state:selfCoord:peerCoord:)` zero callers (:~89), `FairnessRanker.rank(candidates:from:and:cap:)` unused (:~140), `LocationProvider.requestOnceIfAuthorized` unused (:~76), `Tokens.Radius.pin`/`.pill` unused (:~118) — `OnboardingView.swift`, `ResultRows.swift`, `BubbleImageRenderer.swift`, `FairnessRanker.swift`, `LocationProvider.swift`, `Tokens.swift`
  Suggested fix: update the comments; delete the dead cluster.

## ARCHITECTURE NOTES
- The `bb6740d` delta is two targeted fixes plus one feature, all in the host app. VERIFIED FIXED from the prior report: (1) the programmatic-deselect path now closes the `.spot` sheet (`if case .spot = activeSheet { activeSheet = nil }`, :560) — the orphaned-sheet MAJOR is resolved for selection-driven sheets (URL-driven sheets remain, see MAJOR above); (2) the `-DEMO_SPOT_CARD` hook is repaired — `openDemoSpotSheetIfRequested` (:2067–2072, invoked from `.task` at :760) now presents the sheet the init-time seed can't (initial values never fire `onChange`), and the stale comment was rewritten (:441–445).
- The settled-detent rebuild machinery is cancellation-correct: `.task(id: detent)` cancels the pending sleep on every flip, `try? await Task.sleep` + `guard !Task.isCancelled` handles the cancel cleanly, and the `lastBuiltDetent` guard means rapid medium↔large↔medium flips coalesce to at most one rebuild (a return to the built detent correctly rebuilds nothing). The rebuild token lifecycle is sound — `detailRebuild`/`lastBuiltDetent` live on `SpotDetailCard` outside the `.id` subtree, so an `.id`-triggered task restart hits the `detent == lastBuiltDetent` guard and cannot loop. The design's real weakness is being timer-coupled instead of geometry-coupled (MINOR above).
- Root-cause pattern behind both new MAJORs: the one-tap rewiring made `selectedResult` a control signal ("selection ⟹ present sheet"), so every PROGRAMMATIC write to it — `showOwnProposalOnMap`, future callers — re-enters the presentation path, and every programmatic sheet-present WITHOUT a selection escapes the deselect-closes-sheet fix. An explicit present/dismiss intent function would collapse this whole finding class.
- `OnboardingView.swift` (3,469 lines) is effectively the entire host app. Methods over the 80-line bar: `body` ~260 (:528), `handleIncomingURL` ~157 (:3113), `refreshFromAppGroup` ~127 (:2891). `MessagesViewController.swift` (unchanged): `decodeAndCache` ~121 (:262), `sendAgreedPlace` ~115 (:987), `willBecomeActive` ~83 (:131). `TweenViews.swift` (unchanged): `primaryCTA` ~140 (:1761), `meetupSetView` ~112 (:1305).
- Dual identity namespaces: the extension keys identity to `MSConversation` participant UUIDs, the host to `TweenIdentity.stableID`. They meet in revision tie-breaks and roster merge; consistent per-bubble today, but a standing drift risk (seam documented near `OnboardingView.swift:~3300`).
- Host/extension duplicated logic that can drift: `midpoint` verbatim (`TweenViews.swift:22` vs `OnboardingView.swift:3402`), `initials` verbatim, ETA formatting diverges (`ETAChip.mins` renders 3600 s as "60 min", `formatETA` as "1h 0m" — `ResultRows.swift:90` vs `TweenViews.swift:637`), fairness tint thresholds diverge (3/8 min vs 300/900 s), miles formatting duplicated within `ResultRows.swift` (:152 vs :290), and now phone/web URL builders duplicated within `SpotDetailCard.swift` (:256 vs :420).
- Cross-process persistence is last-writer-wins read-modify-write on the snapshot blob (no cross-process lock). Single-key atomic blobs prevent torn reads, not lost updates; the 2026-07 sync-state split correctly shields the hot fields (revision floor, tombstones) — residual exposure is concurrent participant-list writes.
- Two refresh channels (Darwin notification + 2 s poll) both funnel into `refreshFromAppGroup`; the refresh is idempotent, but every accepted delta triggers a full snapshot decode plus `reframe()` (the mechanism behind the camera MAJOR).
- `MeetupSync`/`MeetupSyncToken` remain correct: every canonical writer in `ConversationMeetupStore`, `LocationCache`, and `OutgoingDraftStore` posts after writing; `deinit` removes the Darwin observer with the same pointer it registered; delivery hops to the main queue.
- App Group key matrix is fully consistent: every key is constant-accessed with no orphaned, unread, or misspelled keys; legacy mirror keys (`tween.cache.self.active`/`peer.active`) are consulted only when a pre-split blob lacks the folded flag. `UserDefaults(suiteName:)` nil is never explicitly checked — silently absorbed by optional chaining everywhere.
- TTL hygiene verified: `clear()` removes snapshot + draft but preserves `ConversationSyncState` by design; `freshSelfCoordinate()`/`isActive` gates every payload-embed and ranking site (host funnel `freshSelfCoordinateForSend`); raw `loadSelf()` appears only in leave-bubble filler coordinates and display paths.

## LEGACY DEBT INVENTORY
- `etaFromA`/`etaFromB` (decl `FairnessRanker.swift:62–63`): `TweenViews.swift:1292/1602/2050/2051`; `ResultRows.swift:55/56/58/70/74/83/137/142/168/246/359–361`; `SpotDetailCard.swift:233/288/485` — note `bb6740d` ADDS a production call site (`driveLabel`, :288, hard-codes the "etaFromA = my leg" assumption); `FairnessRankerTests`, `MapGeometryTests:46–54`.
- `worseETA` (`FairnessRanker.swift:64`): tests only (`FairnessRankerTests:23`, `MapGeometryTests:47`) — no production callers.
- `fairnessGap` (`FairnessRanker.swift:65`): tests only (`FairnessRankerTests:29/32`, `MapGeometryTests:48`) — no production callers.
- Two-person `RankedSpot` convenience init: the `SpotDetailCard` `#Preview` (:485) resolves to the NON-DEBUG two-person init (`FairnessRanker.swift:69`, has `item:` param) — correction to the prior inventory, which attributed it to the `#if DEBUG` init at :83 (different signature; tests-only).
- Deprecated `BubbleImageRenderer.makeImage(state:selfCoord:peerCoord:)` (`BubbleImageRenderer.swift:~89`): zero callers.
- "Slice" migration comments: `FairnessRanker.swift:59/68/138`, `MessagesViewController.swift:310`, `OnboardingView.swift:3286`.
- `UserName` (`UserName.swift:31`) and `UserProfile` (`OnboardingFlags.swift:22`) both wrap the same `"userName"` key — two abstractions, one datum.
- `MeetupSnapshot` legacy-decode-only inline fields (`ConversationMeetupStore.swift:91–94`) plus their lazy-migration helpers.
- Legacy single-peer projection: `tween.cache.peer`/`.active` and `self.active` mirrors written on every save (`LocationCache.swift:57/91`), read only for pre-split blobs. Name-based `saveParticipantSnapshot(localName:)` (`LocationCache.swift:152`) remains down to a single production caller — the DEBUG harness (`OnboardingView.swift:409`); all live paths use the `localContext:` overload.
- `TweenState` still emits legacy `kind`/`action` params for pre-group clients (deliberate compatibility, revisit when the fleet upgrades).

## TEST COVERAGE GAPS
(Tests verified byte-identical since `44a73ae` — `git diff --stat 44a73ae..bb6740d -- TweenAppTests TweenAppUITests` is empty; all gaps carry forward, plus new delta gaps.)
- NEW: the entire `bb6740d` delta ships untested — the settled-detent rebuild machinery, the action-tile row (tel: construction, missing-phone/website layouts), the deselect-closes-sheet path, and the post-send `showOwnProposalOnMap` flow (both new MAJORs would have been caught by a UI test asserting no sheet after send). The `-DEMO_SPOT_SHEET_GROW`, `-DEMO_SPOT_SHEET_LARGE`, and repaired `-DEMO_SPOT_CARD` hooks are referenced by no test.
- `MessagesViewController.swift` is structurally untestable (the unit target `@testable import`s TweenApp only): `effectiveReceived` sticky-agreement rule and the `deliverBubble` staged-delivery path are both untested; `LocationCache.loadAgreedMeetup` has zero test references.
- `ConversationMeetupStore` snapshot TTL: no test ages `updatedAt` past 24 h (only `clear()` mechanics are covered).
- `MeetupSync` Darwin post/observe: no tests.
- `TweenState` codec hardening untested: NaN/non-numeric coordinates, >5000-char encode-nil (`TweenState.swift:222`) and decode-side rejection (:325).
- `isFullyAgreed` duplicate-name coverage exists for the ID path only; the legacy name path (MINOR finding above) is untested.
- Zero-coverage files: `OnboardingFlags`, `BubbleCaption`, `NetworkMonitor`, `LocationProvider`, `Tokens`, `ResultRows`, `SpotDetailCard`, `FriendsPanel`, `CategoryPreset`, `OnboardingTutorial`.
- Well covered (for the record): revision tie-breaking including `lastRevisionSender` and the invite-at-floor exception (`ParticipantCodecTests:~676–800`), departure gossip + cap (`RosterMergeTests`), `freshSelfCoordinate` vs `loadSelf`, `Participant.matches` edge cases, `OutgoingDraft.shouldAdopt`.
- Quality: `testLaunchScreenshot` asserts nothing; `testStableIDMintsOnceAndPersists` cannot prove cross-run persistence (setUp wipes the suite); UI tests are harness-driven except `testFloatingMapControlsRespondToTaps`. No skipped/sleeping/disabled tests; setUp App-Group-reset convention holds.

## FIX-FIRST PRIORITY LIST
1. Set `isSending` in `sendAgreedPlace` (`MessagesViewController.swift:~987`) — double-fire protection and feedback in the consensus-critical path.
2. Stop the one-tap `.onChange` from presenting on PROGRAMMATIC selection writes (`OnboardingView.swift:~545/3271`) — kills the post-send sheet re-presentation and the own-link regression in the app's primary propose flow.
3. Close URL-driven `.spot` sheets in `handleIncomingURL`'s fully-agreed and `.leave` branches (`OnboardingView.swift:~3240/3258`) — completes the orphaned-sheet fix this HEAD started.
4. Decide the interactive-map kill-switch (`TweenViews.swift:~1249`): profile on device, then re-enable or delete the dead path and fallback plumbing.
5. Gate `reframe()` (`OnboardingView.swift:~3015/3037`) so background refreshes stop yanking the camera mid-gesture.
6. Queue `handleIncomingURL`'s proposal sheet behind the first-run tutorial cover (`OnboardingView.swift:~601`).
7. Make the deselect-path suppression actually reach the `onChange` (replace the defer-scoped flag with a consumed latch, `OnboardingView.swift:~564/2884`).
8. Re-key the place-sheet rebuild on settled geometry and identity-guard the `mapItem` reassignment (`SpotDetailCard.swift:~36/167`); fix the drive tile's accessibility label and resolve-or-delete the unreachable incoming-tiles branch (:241–263).
9. Scope `sendToChat`'s `encodedURL` guard to the branch that embeds the link (`OnboardingView.swift:~2405`).
10. Separate cancellation from failure in extension send tasks and reset `stagedDeliveryStatus` on activation (`MessagesViewController.swift:~812/939`).
11. Harden `TweenState` decode: finite/range coordinate guards and a decode-side gossip cap (`TweenState.swift:~323/415`).
12. Fix `clearDraft` strip-before-remove ordering and thread a sender through `save()`'s `noteRevision` fold (`ConversationMeetupStore.swift:~200/293`).
13. Gate extension ranking on connectivity and add per-candidate cancellation to `FairnessRanker` (`MessagesViewController.swift:~686`, `FairnessRanker.swift:~121`).
14. Close the guarding test gaps: a UI test on the send→waiting-pin flow (would have caught #2), snapshot TTL expiry, `MeetupSync`, codec hardening; extract `effectiveReceived` into `Shared/` to make the sticky rule testable.
15. Debt sweep: delete the dead-code cluster, unify the duplicated midpoint/initials/ETA/fairness/URL-builder helpers, collapse `UserName`/`UserProfile`.
