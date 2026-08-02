# AUDIT REPORT — Tween — 2026-08-02

## CRITICAL (will crash, corrupt state, or break core flow)

### Concurrency / timeout machinery
- The 8-second search timeout and FairnessRanker's route deadline are both ineffective: `withTaskGroup` awaits its unfinished children on scope exit, and `MKLocalSearch.start()` / `MKDirections.calculate()` async wrappers are not cancellation-aware, so `group.cancelAll()` after the sleep-child wins does nothing — the group (and the extension's ranking task, and the "Finding fair spots…" spinner) still waits for MapKit, indefinitely on a stall. This is exactly the failure mode `DeadlinedSearch.swift:9-13` documents and solves with a continuation box — but neither the extension (`MessagesViewController+Ranking.swift:~119-131, ~149-161`) nor `FairnessRanker.calculateRoute` (`FairnessRanker.swift:~306-320`) uses it. Hung tasks also accumulate memory inside the ~120 MB extension budget.
  Suggested fix: rebuild both on the `DeadlinedSearch` ContinuationBox + `withTaskCancellationHandler` pattern, calling `.cancel()` on the MapKit request at the deadline.

### Identity
- `TweenIdentity.stableID` mints a NEW UUID on every read when `UserDefaults(suiteName:)` is nil, and has no cross-process lock even when it isn't — host and extension launching concurrently can each mint, and payloads sent in that window carry divergent identities — `UserName.swift:~20-28`. Everything downstream keys off this ID: `Participant.matches`, `RosterMerge`, revision tie-breaking (`lastRevisionSender`), and consensus — a divergent ID duplicates the local user in every roster and silently corrupts agreement counting.
  Suggested fix: memoize into a locked `static let`, and `assertionFailure` in DEBUG when the suite is nil instead of returning an ephemeral UUID.

## MAJOR (wrong behavior, UX broken, data loss risk)

### Extension state machine
- Staged-send commit asymmetry: when direct send is rejected and the bubble is only STAGED via `conversation.insert`, `.leave`/`.agree` correctly defer their commits to `didStartSending` — but `.invite`/`.propose`/`.counter` commit immediately (revision floor bumped, canonical snapshot written at `MessagesViewController+Delivery.swift:~92-100`; `LocationCache.setActive(true)`, tombstone cleared, roster adopted at `MessagesViewController+Sending.swift:~75-96`). A user who deletes the staged bubble leaves this device claiming "You're in" / holding a proposal no peer ever saw — the same split-brain the leave/agree deferral was built to fix.
  Suggested fix: extend the `pendingStagedSend` deferral to all five message types (or at minimum gate `setActive(true)` and `recordCanonicalSnapshot` on non-staged delivery).

### Consensus and roster
- `TweenState.isFullyAgreed` false positive with duplicate names in the legacy name namespace (`senderID == nil`, `agreedIDs` empty): `filter { $0 != proposer }` drops EVERY participant sharing the proposer's name from `needToAgree`, and the name `Set` counts all same-named participants as agreed once one agrees — consensus over-reported and the terminal MEETUP SET persisted — `TweenState.swift:~109-117`.
  Suggested fix: count agreement by roster index/occurrence (multiset) in the name namespace, or require IDs for consensus and treat name-only payloads as never fully agreed.
- `RosterMerge.merge` can hold the same human under two IDs: `sameParticipant` reduces to exact ID equality unless BOTH sides are legacy `id == name`, so an iMessage-UUID entry and a `TweenIdentity.stableID` entry for the same person never match — inflating "N in", fairness ranking, and consensus denominators; `firstIndex(where:)` also never collapses pre-existing duplicates — `RosterMerge.swift:~60-92`.
  Suggested fix: add a normalized-name tiebreak when IDs disagree but names match, and de-duplicate `merged` after the loop.

### Host app sync and state
- No conversation-switch reset in the host: the extension tears down all in-memory state on a key change (`MessagesViewController.swift:151-176`) but `refreshFromAppGroup` keeps no memory of `lastActiveConversationKey` — after the extension re-points the key, the host paints conversation B's roster under conversation A's `rankedSpots`, `searchResults`, and open `.spot` sheet — `OnboardingView+Sync.swift:~60-268`.
  Suggested fix: track a `lastSeenConversationKey` `@State`; on change clear results, search state, and any open spot sheet.
- `refreshFromAppGroup` updates `peerCoordinate`/`additionalParticipants` but never re-ranks, so every visible "You X min | Sam Y min" chip keeps the OLD participant set's numbers after a friend joins or leaves — `OnboardingView+Sync.swift:~167-182`.
  Suggested fix: kick `rerankCurrentResults()` when the participant set actually changed and results are on screen.
- `searchState == .suggesting` strands the user: the sheet shows only `suggestionsList`, and presence controls / meetup sections live exclusively in the `.idle` branch; the only exits are emptying the field or committing — blurring, collapsing, or tapping away leaves it latched — `OnboardingView+BottomSheet.swift:~69-84`, `OnboardingView+FriendsPanel.swift:~504-512`.
  Suggested fix: drop back to `.idle` when `searchFocused` becomes false with no committed search.
- `.fullScreenCover(showTutorial)` and `.sheet(item: $activeSheet)` hang off the same view, and `mapOptionsButton` does `activeSheet = nil; showTutorial = true` in one transaction (dismiss-then-present, which silently no-ops); first-run tutorial can also collide with `onOpenURL → .spot` — `OnboardingView.swift:~754-757`, `OnboardingView+BottomSheet.swift:~220`.
  Suggested fix: fold the tutorial into `ActiveSheet` or defer the flip one runloop (`Task { @MainActor in … }`).
- `sendToChat` / `sendAgreeReply` / `presentLeaveMessage` assign `activeSheet = .message(...)` directly after an unbounded `BubbleImageRenderer.makeImage` await, without re-checking what's presented — the sheet-item-swap that silently drops on iOS 26, and the exact hazard `presentMessageCompose` exists to guard — `OnboardingView+HandOff.swift:~143`, `OnboardingView+DeepLinks.swift:~329`, `OnboardingView+Actions.swift:~250`.
  Suggested fix: route all three through `presentMessageCompose` and re-check `activeSheet` after the await.
- Poll-driven `activeSheet = nil` (leave-reset branch) escapes the anti-yank detent gate: sheet `onDismiss` → `selectedResult = nil` → detent write, with `suppressNextDeselectDetentRestore` latched only in the agreedMeetup branch — a background tick can yank the sheet mid-drag — `OnboardingView+Sync.swift:~145-147` (vs `~222-224`).
  Suggested fix: latch `suppressNextDeselectDetentRestore` before the leave-reset `activeSheet = nil` too.
- Foreground resume (`scenePhase == .active`) calls `refreshFromAppGroup()` with the gate off, so any change runs `reframe()` — resetting `position.positionedByUser`, silently reverting `searchRegion` to `participantsSearchRegion` and hiding the Search Here pill; returning from Messages throws away the user's framing — `OnboardingView.swift:~957-959` → `OnboardingView+Sync.swift:~264-266`.
  Suggested fix: skip `reframe()` when `positionedByUser && isSearchActive`, or reframe only when the spot itself changed.

### Extension UI
- Spot selection never recenters the map: `TweenMapSnapshotView` re-renders on `cacheKey` (markers + size only); `focusCoordinate`/`focusYOffsetRatio` are excluded, so `snapshotFocus` following `selectedSpot` does nothing — contradicting the documented behavior at `ExpandedView+Map.swift:10-14` — `TweenMapSnapshotView.swift:~43, ~68-75`.
  Suggested fix: fold rounded focus coordinate + offset into `cacheKey` and render the selected spot with a distinct pin role.
- Send-failure status is invisible from the invite and meetup-set heroes: `statusPill` only renders inside `browseLayout`, and `invitePromptView` reads `statusMessage` only while `isSending` — a failed "I'm in" reverts the button with no error shown — `ExpandedView.swift:~278-282`, `ExpandedView+Invitation.swift:~109`.
  Suggested fix: hoist the `statusPill` overlay to `ExpandedView.body`.
- No `didReceiveMemoryWarning` handler anywhere in the extension and `TweenMapSnapshotView.image` is a retained `@State` `UIImage` with no shed path — in a process with a hard ~120 MB ceiling there is no response to pressure short of jetsam; `HANDOFF.md:29` still claims a `mapDegraded` flag that no longer exists.
  Suggested fix: add a `didReceiveMemoryWarning` override that cancels tasks and nils cached snapshots; delete the stale doc claims.

### ETA correctness
- `SpotDetailCard.myDriveETA` assumes `etas[0]` is the local user; the host only puts self first when a self coordinate exists, and the extension appends self LAST — with a peer + manual point and no self fix, the Directions tile shows a friend's drive time as yours and `fetchETAIfNeeded` bails — `SpotDetailCard.swift:~386-389`; same assumption in `RankedSpot.etaFromA/etaFromB` consumed by `ABDistanceLabel` (`ResultRows.swift:67,72`).
  Suggested fix: match by identity (`etas.first { $0.id == TweenIdentity.stableID }` with name fallback); ordering is not a contract.

### Accessibility / layout
- Extension surfaces overflow their fixed budgets at large Dynamic Type: `CompactView` stacks ~136 pt + status into the keyboard-height strip with no `minimumScaleFactor` and clips silently (`CompactView.swift:~33, ~48-113`); `browsePanel` is a `safeAreaInset` with no height ceiling and `@ScaledMetric` cards that starve the map at accessibility sizes (`ExpandedView.swift:~305-338`).
  Suggested fix: `minimumScaleFactor` / drop secondary rows past `.accessibilityLarge`; clamp or scroll the panel.

## MINOR (suboptimal, cleanup, hardening)

### Concurrency and lifetime
- `MeetupSyncToken` registers `Unmanaged.passUnretained(self)` as the Darwin observer; a notification in flight during dealloc dereferences a freed object (narrow window — sole holder lives for the app's life) — `ConversationMeetupStore.swift:~35-40`.
  Suggested fix: `passRetained` + balanced release in deinit, or a global keyed handler table.
- `LocationProvider` writes `status = .requesting` on the caller's thread and mutates `fixWatchdog` from CoreLocation delegate callbacks, the watchdog task, and `requestFix` without synchronization — `LocationProvider.swift:~45, ~55, ~77-89`.
  Suggested fix: annotate the class `@MainActor` (route everything through `settle`).
- `BubbleImageRenderer` resolves dynamic `UIColor`s (`.cgColor`) off the main actor on the cooperative pool — trait resolution is unspecified off-main, so bubble footers/pins always render light-mode — `BubbleImageRenderer.swift:~30, ~92, ~148`.
  Suggested fix: pre-resolve with `.resolvedColor(with:)` on the main actor before rendering.
- `TweenMapSnapshotView`: failed renders keep the previous marker set's image indefinitely (fallback drawn only `if image == nil`), `retryAttempt` never resets after `maxRetries`, and the unstructured deadline `Task` outlives abandoned renders holding a snapshotter up to 6 s — `TweenMapSnapshotView.swift:~19, ~131-134, ~146-148`.
  Suggested fix: reset retry state and clear the image on `cacheKey` change; structure the deadline like `BubbleImageRenderer`.

### Persistence and data hygiene
- `FriendRoster.add` overwrites a re-picked contact with a freshly minted `TweenFriend.id`, orphaning its `pingLog` entry (which nothing ever prunes — `PingLog.clear()` is test-only), so history is lost and the log grows unboundedly — `TweenFriend.swift:~46-55`, `PingLog.swift:~79-87`.
  Suggested fix: preserve the existing id in `add`; prune log keys not present in the roster on save.
- `ConversationSyncState.departedKeys` is unioned forever with no cap and is deliberately TTL-exempt — long-lived group threads accumulate tombstones indefinitely (only the *gossip* is capped at 8) — `ConversationMeetupStore.swift:~402-408`.
  Suggested fix: cap the persisted set (e.g. newest 64) or timestamp-and-age entries.
- Every App Group accessor optional-chains a nil suite silently; two degrade into wrong answers: `PingLog.lastGenericInviteCount` returns a phantom `1`, and `OnboardingFlags` re-shows the tutorial every launch — `PingLog.swift:~57-60`, `OnboardingFlags.swift:~14-15`.
  Suggested fix: one shared suite accessor with a DEBUG `assertionFailure` when nil.
- `decodeAndCache`'s legacy peer projection filters `matches(id:name:)` but not the pre-stable-ID conversation-scoped UUID (`$0.id == legacyID`) that `nextParticipantList` does filter — an old roster entry of *yourself* can be cached as "the peer" — `MessagesViewController+Decoding.swift:~133` (vs `~282`).
  Suggested fix: apply the same `legacyID` exclusion in the peer-projection filter.
- `RosterMerge` treats a `.leave` with empty `senderKeys` (nil senderID *and* name) as an ordinary additive payload — the leaver is removed from nobody's roster, silently — `RosterMerge.swift:~47-51, ~81-83`.
  Suggested fix: refuse (and log) a `.leave` with no sender identity at the call sites.
- `FairnessRanker` math hardening: the public `RankedSpot` init accepts `confidence: 0` → NaN score → arbitrary sort (`FairnessRanker.swift:~45-47`), and `recommendedCap`'s floor of 3 breaks the documented `maxTotalRouteCalls = 20` invariant for 7+ participants (`~99, ~107-110`).
  Suggested fix: clamp confidence in the initializer; make the floor conditional on the route-call product.

### Host app UX and search
- Two clear paths, two end states: the (x)-button empty branch doesn't reset `openNowOnly`, `searchViewMode`, or `searchFocused`, unlike `clearSearch()` — the Open Now chip stays lit with no results — `OnboardingView+Search.swift:~92-103` vs `~603-618`.
  Suggested fix: have the empty branch call `clearSearch()`.
- Searching offline is a silent no-op — `canSearch` clears state and returns false with no toast, and both passive surfaces are hidden at the peek detent — `OnboardingView+Search.swift:~207-213`.
  Suggested fix: toast "You're offline — reconnect to search".
- `ensureNamed`'s name-prompt alert hangs off the same view presenting `.sheet(item:)`; `sendToChat`/`setManualSelf` reach it from *inside* presented sheets, surviving only because `dismiss()` happens to precede it — an unmitigated dismiss-vs-present race — `OnboardingView+Actions.swift:~63-75`.
  Suggested fix: switch over every non-nil `activeSheet` case or defer the prompt one runloop after dismiss.
- `SearchCompleter` has no stale-query guard: a late delegate callback for the previous fragment repopulates cleared suggestions and flips `.idle` to "No nearby matches" — `SearchCompleter.swift:~152-158, ~224-227`.
  Suggested fix: record the issued fragment and drop non-matching callbacks.

### Extension performance
- Extension view bodies do synchronous App Group I/O: `UserDefaults(suiteName:)` construction + a fresh `JSONDecoder` per read, invoked from computed view properties (~20 round-trips per body pass on the legacy path), and `presentUI` swaps `rootView` on every state change — `CompactView.swift:~321`, `ExpandedView.swift:~123, ~159-160`, `ExpandedView+Map.swift:~48`, `LocationCache.swift:~54, ~302-305`.
  Suggested fix: hoist reads into inputs passed from `MessagesViewController`.
- Snapshots render at native `UIScreen.main.scale` (@3x ≈ 9-10 MB transient per render in a 120 MB budget; `UIScreen.main` is deprecated in extensions) — `TweenMapSnapshotView.swift:~124`.
  Suggested fix: `min(scale, 2)` for the extension's large canvas; read scale from the trait collection.

## ARCHITECTURE NOTES
- `TweenAppTests` can only reach code compiled into `TweenApp` — all five `MessagesViewController*.swift` files (~1,750 lines: the entire state machine, `effectiveReceived`, `deliverBubble`, staged commits) are structurally untestable. Extracting the decode/commit/consensus logic into a `Shared/` type would make the highest-risk code in the repo testable.
- `MeetupSnapshot` mutation is read-modify-write over one blob with last-writer-wins across two processes; the 2026-07 split of sync state (revision floor, tombstones) into its own key protects the hot fields, but `participants`/`proposedState` can still lose a concurrent update. Also, `MeetupSnapshot.proposedState/agreedState` round-trip through `encodedURL()` — a >5000-char state (giant group) is silently dropped by the setter, and `clearIncludingSync` posts the Darwin notification before the sync key is removed (observers can read half-cleared state).
- The "300 ms poll" is actually 2 s (`OnboardingView+Sync.swift:28`) while five comments and the whole `suppressPollDetentWrites` rationale say 300 ms — anyone reasoning about drag-fight windows from the comments is off ~7×.
- God methods: `OnboardingView.body` 369 lines (`OnboardingView.swift:643`), `handleIncomingURL` 211 (`+DeepLinks.swift:27`), `refreshFromAppGroup` 209 (`+Sync.swift:60`); six more exceed 80 (`HarnessView.body`, `OnboardingView.init`, `runSearch`, `openDemoSpotSheetIfRequested`, `mapLayer`, `sendToChat`). All ten `OnboardingView*` files share a copy-pasted 8-import header, mostly unused per file.
- Duplicated taxonomy/logic: `MessagesSearchCategory` (`ExpandedView.swift:6-49`) duplicates `CategoryPreset`; two `initials(for:)` with different empty-name behavior (`TweenPin.swift:118` vs `SpotETADisplay.swift:101`) render the same person differently across processes; two near-identical button styles (`Tokens.swift:254` vs `ResultRows.swift:~250`).
- Positive verifications: no MKMapView/SwiftUI Map, text input, or first responder anywhere in extension surfaces (constraints 1 and 3 hold); rank caps (5 extension / ≤8 app) hold everywhere; `rankingTask`/`sendTask` cancelled in `willResignActive`; TTL clear preserves sync state; `locationProvider` retained; fallback view correctly at z-index 0; zero force unwraps in `Shared/` and `TweenMessages/`; app/extension call sites match all view initializers.

## LEGACY DEBT INVENTORY
- `RankedSpot.etaFromA` / `etaFromB` (`FairnessRanker.swift:62-63`) — still consumed by `ABDistanceLabel` (`ResultRows.swift:67,72`); index-position semantics are the root of the MAJOR ETA finding. No `worseETA`/`fairnessGap` references remain.
- Legacy single-peer projection — `tween.cache.peer` + `savePeer`/`loadPeer`/`isPeerActive` still load-bearing for the host poll; dual-written legacy mirror bools `tween.cache.self.active`/`tween.cache.peer.active` on every save.
- "Slice 6" migration comment (`MessagesViewController+Decoding.swift:~18-19`) — the promised host-app migration off the single-peer key never happened.
- `saveParticipantSnapshot(_:localName:)` name-only overload — production caller is only the DEBUG harness (`OnboardingView.swift:421`); the context-aware overload is used everywhere else.
- Legacy `kind`/`action` URL params still emitted alongside `type=`; legacy compact `p=` decodes collapse id→name, sustaining the dual ID namespace that `RosterMerge`/`isFullyAgreed` must straddle.
- `legacyLocalParticipantID()` conversation-UUID filtering (`+Decoding.swift:170-172`, `nextParticipantList`, `sendAgreedPlace`) — transition code, applied inconsistently (see MINOR peer-projection finding).
- `MeetupSnapshot`'s four legacy-decode-only inline fields + `loadSync`/`migrateDraftIfNeeded` rescue paths.
- Dead: `Participant.isManual` (misleading comment — the claimed send-path filter doesn't exist), `UserName.save`/`loadOrFallback` (tests only; `userName` key has two owners and the real writer doesn't trim), `TweenPin.animated`, `MapGeometry.midpoint`, `BubbleImageRenderer.fallbackImage`, `ExpandedView.canSendSpotFromCurrentPeople`, and 9 unreferenced `Tokens` members.

## TEST COVERAGE GAPS
- Entire extension state machine unreachable from tests: `willBecomeActive`, `decodeAndCache`, `effectiveReceived` sticky rule, `deliverBubble` staged path, `commitStagedSendIfNeeded`, `acquireLocation` (needs extraction to `Shared/` first).
- Snapshot TTL expiry decision never tested — no test ages `updatedAt`; all five production expiry gates uncovered.
- MeetupSync Darwin post/observe: zero test references.
- Departure gossip end-to-end loop (outgoing `departed` population + receive-side `noteDeparted`) untested; units covered.
- `isFullyAgreed` name-only path with duplicate names (the exact MAJOR bug above), both-nil sender, and `agreedIDs`-only `useIDs` branch untested.
- `Participant.matches(id:name:)` overload has zero tests; empty-string names and two legacy same-named participants untested.
- URL codec boundaries: the terminal oversize `return nil` (`TweenState.swift:222`) and the decode-side 5000 guard never fire; no unicode/adversarial participant-codec tests.
- `freshSelfCoordinate` well covered; missing the 4:59/5:01 boundary and the peer-side freshness gate.
- Hygiene: 10 of 21 files skip the App Group reset convention (currently benign); `SearchCompleterTests`/UI map test hit live services; five assertions can never fail (notably `testStableIDMintsOnceAndPersists` proves memoization, not persistence — it would pass through the CRITICAL identity bug).

## FIX-FIRST PRIORITY LIST
1. Replace the broken `withTaskGroup` deadline pattern in `MessagesViewController+Ranking` and `FairnessRanker.calculateRoute` with the existing `DeadlinedSearch` continuation-box pattern (CRITICAL — hangs the extension's core flow).
2. Harden `TweenIdentity.stableID`: locked memoization + loud nil-suite failure (CRITICAL — silent identity corruption cascades through roster, revisions, consensus).
3. Extend the staged-send deferral to `.invite`/`.propose`/`.counter` in `deliverBubble`/`handleImIn` (split-brain "You're in" from a deleted bubble).
4. Fix consensus identity: multiset name counting in `isFullyAgreed` + cross-namespace matching in `RosterMerge.merge` (false MEETUP SET, duplicated humans).
5. Add host-side conversation-switch detection and teardown in `refreshFromAppGroup`, and re-rank when the participant set changes (stale rosters and ETAs are the host's most-visible wrong data).
6. Route the three direct `activeSheet = .message(...)` assignments through `presentMessageCompose`, and resolve the `.fullScreenCover`/`.sheet` same-view conflict (dropped presentations on iOS 26).
7. Fix `myDriveETA`/`etaFromA/B` to match by identity instead of array position.
8. Un-strand `searchState == .suggesting` on focus loss, and close the poll-detent yank hole (`suppressNextDeselectDetentRestore` in the leave-reset branch).
9. Include `focusCoordinate` in the snapshot `cacheKey` and surface the send-failure status pill from every ExpandedView layout.
10. Add `didReceiveMemoryWarning` shedding in the extension; cap snapshot scale at @2x.
11. Preserve `TweenFriend.id` in `FriendRoster.add` and prune `pingLog`; cap `departedKeys`.
12. Extract the decode/commit/consensus core into `Shared/` and add the missing tests (TTL expiry, staged delivery, sticky-agreed rule, duplicate-name consensus) so items 3-5 stay fixed.
