# AUDIT REPORT — Tween — 2026-07-31 (post 5371f25; six search findings fixed in bdefb4f)

## CRITICAL (will crash, corrupt state, or break core flow)

### Payload decode / state poisoning
- No coordinate validation on decode: `lat`/`lon`/`slat`/`slon` accept `NaN`, `Inf`, and out-of-range values (`Double.init` parses "nan"/"inf"/"1e308"), and `decodeParticipants` has the same hole. Invalid coordinates flow into `MKCoordinateRegion`/`MKMapSnapshotter`/centroid math and can crash the extension — and because decoded state persists to the App Group snapshot, the crash recurs on every activation. Reachable from any hostile/corrupt bubble URL and from the `tween://` deep-link path — `TweenState.swift:~338-339, ~356-357, ~260-261`, `OnboardingView+DeepLinks.swift`
  Suggested fix: reject the payload in `init?(url:)` unless every coordinate passes `CLLocationCoordinate2DIsValid` and finite-range checks.
- Hostile or corrupt `rev=` (e.g. `Int.max`) permanently bricks a conversation: the decoded revision is stored un-clamped as the TTL-exempt sync floor, every real bubble is then rejected as stale forever, and the next outgoing mint computes floor+1, which overflow-traps (crash) at `Int.max` — `TweenState.swift:~429`, `ConversationMeetupStore.swift:~436-449`, mint sites `MessagesViewController+Decoding.swift:~188`, `OnboardingView+Actions.swift:~306`
  Suggested fix: clamp decoded revisions to a sane band (e.g. 0...1_000_000) at decode and use overflow-checked increment at the mint sites.

## MAJOR (wrong behavior, UX broken, data loss risk)

### Extension state machine (MessagesViewController)
- `searchPOIItems`/`searchItems` still use the `withTaskGroup` timeout race that `DeadlinedSearch`'s own header documents as broken: the group awaits its stalled `MKLocalSearch` child on scope exit, so a geod-throttled request that ignores cancellation blocks the "timeout" path exactly when it matters — the extension spinner can hang forever — `MessagesViewController+Ranking.swift:~119-133, ~149-163`
  Suggested fix: replace both helpers with `DeadlinedSearch.mapItems(for:)`.
- Staged `.propose`/`.counter`/`.invite` commit prematurely: `deliverBubble` defers the revision floor + canonical snapshot only for staged `.leave`/`.agree`; other types run `noteRevision` + `recordCanonicalSnapshot` even when the bubble is only staged in the input field and the user may delete it — local proposed/roster state then shows a proposal no peer ever received (a staged `.counter` also clears the agreed state locally) — `MessagesViewController+Delivery.swift:~81-100`
  Suggested fix: extend the `setPendingStagedSend`/`didStartSending` deferral to all staged message types.
- `commitDeliveredLeave` clears the in-memory draft and global `OutgoingDraftStore` but never calls `ConversationMeetupStore.clearDraft(key:)`, so the per-conversation draft survives the leave and the leaver gets force-expanded over a stale draft on next activation — `MessagesViewController+Sending.swift:~182-220`
  Suggested fix: add `ConversationMeetupStore.clearDraft(key:)` to `commitDeliveredLeave`.
- TTL sweep runs AFTER `decodeAndCache` in `willBecomeActive`, so a >24h-expired roster is first resurrected into the freshly decoded/cached state before the sweep runs — expired meetups leak back into fresh bubbles — `MessagesViewController.swift:~185` (decode) vs `~190-193` (sweep)
  Suggested fix: clear expired snapshots before decoding the selected message.

### Consensus and identity
- `isFullyAgreed` is fragile on the legacy path: with `senderID == nil` and empty `agreedIDs`, consensus is name-based, so two participants sharing a name yield a false-positive "fully agreed" after one of them agrees; mixed-version payloads (nil `senderID` with non-empty `agreedIDs`) compare participant IDs against a proposer *name* and can never complete (false negative), as can a dropped/misaligned `pids=` list — `TweenState.swift:~109-117`
  Suggested fix: dedupe by identity keys and compute consensus on the set-difference of participant keys vs (agreed ∪ proposer).
- Agreed names ship unsanitized: `encodedURL` emits `agreedNames` without `outgoingName()` blanking, so the literal "You" fallback travels on the wire from the agree composers and peers render the wrong agree-er — `TweenState.swift:~196-199`, `MessagesViewController+Sending.swift:~331`, `OnboardingView+DeepLinks.swift:~274` (exactly the known "sanitize every name path" bug class)
  Suggested fix: route `agreedNames` through `outgoingName()` at encode time.
- Own-proposal detection in the host deep-link path compares display names instead of stable identity (`openedOwnProposal` via name equality), so a peer with the same display name is treated as "you", suppressing the agree flow — `OnboardingView+DeepLinks.swift:~48`
  Suggested fix: compare `senderID` against `TweenIdentity.stableID`, falling back to name only when both IDs are absent.

### Views
- Spot-card selection never re-centers the extension snapshot map: `TweenMapSnapshotView`'s `.task(id:)` cache key includes only size + marker coordinates/roles, omitting `focusCoordinate`/`focusYOffsetRatio`, so `snapshotFocus` changes from `ExpandedView+Map.swift` never trigger a re-render — `TweenMapSnapshotView.swift:~43, ~68-75`
  Suggested fix: fold the rounded focus inputs into `cacheKey(for:)`.

### Search overhaul — FIXED post-audit (landed in bdefb4f)
- Rescue ladder ignored cancellation and `DeadlinedSearch` was deaf to task cancellation (a cancelled search kept issuing up to ~4 rungs × 8s of MKLocalSearch churn, compounding geod throttling) — `OnboardingView+Search.swift`, `Shared/DeadlinedSearch.swift` — FIXED (cancellation-aware `DeadlinedSearch` via `withTaskCancellationHandler`, `Task.isCancelled` checks between rungs).
- Committed typed search never left `.suggesting`, so the results loading state never rendered — `OnboardingView+Search.swift` — FIXED (`searchState = .results` in `commitSearch`).
- `CompletionRegionFilter` killed all address suggestions outside the US (admin-area strictness with no country fallback) — `Shared/CompletionRegionFilter.swift` — FIXED (US-scoped admin strictness, country fallback elsewhere).

## MINOR (suboptimal, cleanup, hardening)

### Extension
- Legacy `tween.cache.peer` mirror (`savePeer`) is written from the unfiltered roster, so a departed/filtered participant can persist in the legacy projection — `MessagesViewController+Decoding.swift:~131-139`
  Suggested fix: project the peer mirror from the post-tombstone-filtered roster.
- A cancelled `handleImIn` (backgrounding mid-send) stamps the persistent "Location unavailable" error banner even though nothing failed — `MessagesViewController+Sending.swift:~53-57`
  Suggested fix: guard the failure banner on `!Task.isCancelled` (as the send-failure branch already does).
- `errorStatuses` contains a dead string ("Google Maps isn't installed.") while the live Google Maps failure copy isn't styled as an error — `MessagesViewController.swift:~86-90`
  Suggested fix: replace the dead entry with the live copy.

### Shared state / concurrency
- Inbound `gone=` gossip absorption is unbounded — only outbound gossip enforces `RosterMerge.gossipCap`, so a hostile bubble can flood stored tombstones and crowd out real ones — `RosterMerge.swift` / `ConversationMeetupStore.swift:~402-409`
  Suggested fix: cap `departedKeys` on merge as well as on emit.
- `LocationProvider` `fixWatchdog`/`status` are mutated from CLLocation delegate callbacks and read from async polls without isolation — `Shared/LocationProvider.swift:~75-93`
  Suggested fix: annotate the class `@MainActor`.
- `MeetupSnapshot.proposedState`/`agreedState` setters silently drop state when `encodedURL()` returns nil (oversize) — `ConversationMeetupStore.swift:~96-104`
  Suggested fix: log + preserve the previous URL instead of nil-ing on encode failure.
- `ResultRows` positional "A = You" labeling assumes the self coordinate is always first; wrong when self is absent (manual A→B) — `TweenApp/ResultRows.swift:~62-74`
  Suggested fix: label from the participant model, not position.

### Host app plumbing
- Partial agree via deep link is never persisted: the not-fully-agreed branch updates UI state but skips the ConversationMeetupStore write — `OnboardingView+DeepLinks.swift:~179-204`
  Suggested fix: save the partial-agree proposed state like the extension does.
- `composeTweenMessage` returning nil is a silent no-op at five send sites (user taps send, nothing happens, no feedback) — `OnboardingView+Actions.swift:~237, ~431`, `+DeepLinks.swift:~327`, `+HandOff.swift:~139`, `+FriendsSync.swift:~76`
  Suggested fix: surface a toast on nil compose.
- `showToast` dismiss timer isn't cancelled on re-entry, so an earlier timer dismisses a later toast early — `OnboardingView+FriendsSync.swift:~116-122`
  Suggested fix: store and cancel the dismiss task before re-arming.
- `setNeedsRide` commits App Group state before the composer succeeds, unlike every other send path — `OnboardingView+Actions.swift:~397-401`
  Suggested fix: commit in `onSent`, matching the other sends.
- `appGroupDidChangePublisher` is inert — the `object:` filter never matches cross-instance, so the Darwin token + 2s poll do all the work — `OnboardingView+Sync.swift:~14-19`
  Suggested fix: delete the publisher.

### Views / polish
- Reduce Transparency fallback (`panelSurface`) missing on `meetupSetView` and `invitePromptView` — `ExpandedView+SpotList.swift:~94`, `ExpandedView+Invitation.swift:~101, ~129`
  Suggested fix: apply the same accessibility surface fallback as the other panels.
- Tutorial's "I'm out" demo button is enabled but a no-op in the shipping tutorial — `OnboardingTutorial.swift:~339-342`
  Suggested fix: `.disabled(true)` to match the other demo chrome.
- Two divergent `initials(for:)` implementations (host vs extension avatar drift) — `TweenPin.swift:~117-122` vs `SpotETADisplay.swift:~101-106`
  Suggested fix: unify into one Shared helper.
- Hardcoded avatar fonts (sizes 9/11/15/16) bypass `Tokens.Typography` and don't scale with Dynamic Type — CompactView/ExpandedView/TweenPin
  Suggested fix: add an `avatarInitials` font token.
- `AddPointSheet` `#Preview` renders `OnboardingView` instead of `AddPointSheet` — `AddPointSheet.swift:~79-81`
  Suggested fix: preview the sheet with stub closures.

### Search overhaul — FIXED post-audit (landed in bdefb4f)
- `UITextChecker` ran off-main and `openNowOnly` `@State` was read off-actor; `toggleOpenNow` showed stale unfiltered results during re-search; `SearchCompleter.regionTokensKey` latched before the geocode resolved so failures never retried — all FIXED (`@MainActor` resolvers, results cleared on toggle, key latched on success with in-flight guard).

## ARCHITECTURE NOTES
- Hard constraints verified clean: no `MKMapView`/SwiftUI `Map` anywhere in Shared or TweenMessages; `rankCap` 5 (extension) / 8 (app) enforced; CompactView has no text input/first responder; `@Observable` used throughout; `rankingTask`/`sendTask` cancelled in `willResignActive`; App Group key inventory fully reader/writer matched with no orphans; MeetupSync posts from every canonical writer (pendingStaged and `lastActiveConversationKey` intentionally excepted); `MeetupSyncToken.deinit` removes its observer correctly.
- Duplicated logic between processes is the recurring smell: the extension's search-timeout pattern vs `DeadlinedSearch` (now a live bug), two `initials(for:)`, hardcoded avatar font sizes bypassing `Tokens`, and `UserName` vs `UserProfile` both wrapping the `"userName"` key.
- Method length: `ExpandedView.primaryCTA` (~110 lines) and `meetupSetView` (~103) exceed the 80-line bar; `OnboardingView.swift` remains 900+ lines even after its 10-file split; extension VC logic (effectiveReceived, deliverBubble, TTL sweep) is embedded in the controller and therefore structurally untestable.
- Stale comments claim a "300ms poll" — the actual poll interval is 2s.
- `resolvePlace`'s hint-pass merge is still legitimately reachable from the add-place flow; keep it.

## LEGACY DEBT INVENTORY
- `LocationCache` legacy mirrors `tween.cache.peer` / `tween.cache.peer.active` / `tween.cache.self.active` — still written from extension decode (`savePeer`, unfiltered roster) and read by legacy host paths.
- `MeetupSnapshot` legacy-decode fields (`pendingDraft`, `lastRevision`, `localUserLeft`, `departedKeys`) — migration-only by design; correctly nil-ed after `loadSync`/`loadDraft` migrate.
- `UserName` vs `UserProfile` — duplicate accessors over the same `"userName"` key (UserProfile setter also skips trimming on write).
- Wire-compat params `kind=`/`action=`/compact `p=`+`pids=` — deliberate backward compatibility, keep.
- Dead code: `worseETA`, `fairnessGap`, `FairnessRanker` two-person adapter (no callers); Tokens API `tweenGlass(radius:)`, `Radius.pill`, `Radius.pin`, `Typography.heroIcon`; dead string in `errorStatuses`; `focusSearchPanel` alias; `spotBody`'s unused coordinate param; inert `appGroupDidChangePublisher`.

## TEST COVERAGE GAPS
- Zero coverage: `DeadlinedSearch` (timeout-wins, search-wins, cancellation, double-resume), `LocationProvider`, `NetworkMonitor`, `OnboardingFlags`, `UserProfile`.
- Extension VC files entirely untested and structurally untestable in-place: `effectiveReceived` sticky-agreed rule, `deliverBubble` staged-delivery path, TTL sweep ordering, `acquireLocation` — extract to testable Shared types.
- Untested consensus edges: snapshot TTL age-based gating, departure-gossip absorption cap, `TweenState.isFullyAgreed` with duplicate names / nil senderID.
- Untested host paths: `handleIncomingURL`, `refreshFromAppGroup` transition-tick gating, `resolveMeetupPlaces` ladder ordering, `openNowQualified`, MeetupSync post/observe round-trip.
- Test-quality: MapGeometry/FairnessRanker duplication; `SearchQueryRewriter` tests are locale-dependent (UITextChecker); one SearchCompleter test hits real network; UI launch test asserts nothing.

## FIX-FIRST PRIORITY LIST
1. Validate coordinates in `TweenState.init?(url:)` / `decodeParticipants` (CRITICAL — recurring extension crash from one bad bubble).
2. Clamp decoded `rev=` and overflow-check the floor+1 mint (CRITICAL — permanent conversation brick).
3. Move the TTL sweep before `decodeAndCache` in `willBecomeActive` (expired-roster resurrection).
4. Defer staged `.propose`/`.counter`/`.invite` commits to `didStartSending` like `.leave`/`.agree`.
5. Add `ConversationMeetupStore.clearDraft(key:)` to `commitDeliveredLeave`.
6. Replace the extension's `searchPOIItems`/`searchItems` task-group race with `DeadlinedSearch`.
7. Harden `isFullyAgreed` (identity-set consensus) and sanitize `agreedNames` through `outgoingName()`.
8. Switch `openedOwnProposal` to stable-ID comparison in `OnboardingView+DeepLinks.swift`.
9. Add focus inputs to `TweenMapSnapshotView.cacheKey` so spot selection re-centers the extension map.
10. ~~Land the six post-audit search fixes~~ — DONE (bdefb4f).
11. Persist the partial-agree deep-link path and surface `composeTweenMessage` nil failures.
12. Backfill tests for the consensus/revision/TTL/DeadlinedSearch gaps above.
