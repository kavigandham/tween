# AUDIT REPORT — Tween — 2026-09-06

Read-only audit at HEAD `3759dac` (main). Covers the areas the `fc1809f` report could not — the extension state machine (`TweenMessages/MessagesViewController*.swift`), the extension views (`Shared/ExpandedView*.swift`, `Shared/CompactView.swift`), `BubbleImageRenderer` / `TweenMapSnapshotView`, and a full pass over `TweenAppTests/` — then re-verifies every CRITICAL/MAJOR from the previous report against the current tree, and reviews the six commits since `fc1809f` (`3a0726c`, `f8a162d`, `6d39717`, `d3d7483`, `2b74aa2`, `3759dac`). No files were modified; no builds or tests were run. Findings below the 70 % bar were dropped.

**Re-verification summary of the previous report:** both CRITICALs still hold; of the MAJORs, one is FIXED by `d3d7483` (0.7 s keyboard window), one is half-mitigated (M2's `participants` half is sanitised, the `agreedNames` half is not — and the extension has the same hole), M7's magnitude is smaller than stated (≈16–24 concurrent legs, not 40); everything else still holds at the line numbers given below.

**Post-audit note (same day):** the two MINOR hardening items on the recent commits — `allowsHitTesting(!isMinimalDetent)` on the collapsed sheet block and the `soloMode` input in `ResultCard ==` — plus the stale "hidden at 0.90" comment were applied immediately after this report.

## CRITICAL (will crash, corrupt state, or break core flow)

### Codec / revision ordering
- Inbound `rev` is parsed with bare `Int.init` and stored unconditionally as the conversation's revision floor; the next mint is an unchecked `lastRevision + 1` in both processes, so a bubble carrying `rev=9223372036854775807` traps the receiver's next send forever (sync key is TTL-exempt, `clear(key:)` keeps it by design). — `Shared/TweenState.swift:~451`, `Shared/ConversationMeetupStore.swift:~438-444, ~236-248`, `TweenMessages/MessagesViewController+Decoding.swift:~188`, `TweenApp/OnboardingView+Actions.swift:~371`
  Suggested fix: reject `rev < 0 || rev > floor + 1_000_000` on decode; mint with `addingReportingOverflow`.
- `pj=` (the preferred decode path, tried before `p=`) never runs `validCoordinate`: `Participant.init(from:)` decodes raw `Double`s, and nothing downstream (RosterMerge, FairnessRanker, MKPlacemark/MKDirections, CLLocation centroid) re-validates, so `lat: 200` reaches MapKit's NSException class the 2026-08-07 hardening closed for `lat`/`lon`. — `Shared/TweenState.swift:~402-404, ~282-285`, `Shared/Participant.swift:~78-84`
  Suggested fix: filter decoded `pj` participants through `validCoordinate`, falling back to `p=` when any entry fails.

## MAJOR (wrong behavior, UX broken, data loss risk)

### Extension state machine / views
- `ExpandedView` derives its roster from the bubble (`received.participants`) or the device-global 5-minute legacy peer blob, never from the controller's `currentParticipants`. On a snapshot restore with no `selectedMessage` (drawer open at the invite stage — `.invite` stores participants but no `proposedState`, so `received == nil`) the controller ranks 2+ people and fills `rankedSpots`, but the view's `otherParticipants == []` → `coordinateParticipantCount == 1` → `canSendSpotFromCurrentPeople == false` → `primaryCTA` lands on `else if isUserIn { EmptyView() }`. Rows render and select, but there is no Send button. `refreshLocationIfUserIsIn` repairs the peer blob only if a fresh fix lands; a manual "I'll be at…" location, a denied/slow fix, or the first seconds after open leave it broken. The restore branch also never calls `saveParticipantSnapshot`. — `Shared/ExpandedView.swift:~134-167, ~207-215, ~613`, `TweenMessages/MessagesViewController.swift:~204-213`
  Suggested fix: pass `currentParticipants` into `ExpandedView` (CompactView already receives a count) and prefer it in `otherParticipants`; at minimum `saveParticipantSnapshot(snapshot.participants, …)` in the restore branch.
- Cross-conversation phantom "Friend": the `switchedConversation` block clears `received`/`currentParticipants` but not `LocationCache.setPeerActive(false)`, and `ExpandedView.legacyPeerCoord` reads the device-global peer blob whenever `received == nil`, so within 5 minutes of a decode in chat A, chat B's expanded view plots chat A's friend on the map and in the roster strip. — `TweenMessages/MessagesViewController.swift:~161-180`, `Shared/ExpandedView.swift:~161-167`
  Suggested fix: `LocationCache.setPeerActive(false)` in the switch block, or drop the `isPeerActive` fallback and trust only `received`/the controller roster.

### Identity / consensus
- Own-proposal detection in the host deep-link path is name-only (`state.senderName == myName`); a friend with your display name has their proposal treated as yours (no peer save, no Agree/Change sheet, wrong toast). `senderID`/`TweenIdentity.stableID` are in scope on the same lines. Aggravated by `outgoingName` blanking "You", so an unnamed user's own proposal never matches. — `TweenApp/OnboardingView+DeepLinks.swift:~58`
  Suggested fix: `state.senderID == TweenIdentity.stableID || (state.senderID == nil && state.senderName == myName)`.
- The literal `"You"` fallback ships in `agreed=` from BOTH processes: `encodeNames(agreedNames)` has no `outgoingName` sanitisation, the host's `sendAgreeReply`/`agreeToPendingProposal` never call `ensureNamed`, and the extension's `sendAgreedPlace` appends `Self.localParticipantName()` ("You") with no way to prompt. Peers' captions/"waiting for" lists then show "You". (`participants` entries ARE sanitised — that half of the old finding is fixed.) — `TweenApp/OnboardingView+DeepLinks.swift:~279-293`, `TweenApp/OnboardingView+FriendsPanel.swift:~1369-1379`, `TweenMessages/MessagesViewController+Sending.swift:~290, ~358-359`, `Shared/TweenState.swift:~196-198`
  Suggested fix: sanitise in `encodeNames` for the `agreed=` item (drop/blank `UserName.fallback`; consensus already rides on `agreedIDs`), and wrap the host Agree path in `ensureNamed`.

### Conversation scoping
- `lastActiveConversationKey` is written only by the extension on activation (`MessagesViewController.swift:~159`) and never cleared in production (only `#if DEBUG` demo paths), yet the host keys every canonical write on it (local participant, leave, revision mint, proposed/agreed, draft binding, `activeMeetupDeparted` dam, `hasLiveMeetup`). Peek chat C's drawer, then send from the host to friend A: A's roster, floor and tombstones are filed under C. — `Shared/ConversationMeetupStore.swift:~172-180`, `TweenApp/OnboardingView+Actions.swift:~265, ~321, ~370, ~434`, `Shared/LocationCache.swift:~126-129`
  Suggested fix: nil the key when its snapshot is TTL-expired / on cold launch with no live meetup; longer term let host sends pick their key.

### Search / sheets (host)
- Return while an autocorrect candidate is pending: UIKit commits the correction (`textDidChange` → binding write) then calls `searchBarSearchButtonClicked` → `commitSearch`, which never arms `suppressNextQueryChange`; on the next pass `.onChange(of: searchText)` → `handleQueryChange` cancels the just-started `searchTask`, empties results and flips back to `.suggesting`. — `TweenApp/SearchCompleter.swift:~94-108`, `TweenApp/OnboardingView+Search.swift:~115-143, ~201-234`, `TweenApp/OnboardingView+FriendsPanel.swift:~598-605`
  Suggested fix: defer `parent.onSubmit()` with `DispatchQueue.main.async` so the text change lands first, or arm the suppression flag in `commitSearch`.
- `presentSpot` swaps `activeSheet = .spot(B)` while `.spot(A)` is presented; the code comment acknowledges iOS 26 drops the dismiss-then-re-present silently but only disarms the child `spotSubSheet`. Callers include the bubble-tap/`onOpenURL` path with a card already up. — `TweenApp/OnboardingView+FriendsPanel.swift:~1196-1207`, `TweenApp/OnboardingView+DeepLinks.swift:~183`
  Suggested fix: nil `activeSheet` and park the new selection in a pending action run from the sheet's `onDismiss` (the `pendingFriendSheetAction` pattern).

### Ranking / entitlement
- MKDirections fan-out is unbounded — `rank` opens a task per capped candidate and `rankOne` a nested task per participant with no semaphore/chunking: 16 legs for the host 2-person case (`rankCap = 8`), ≈20 for ≥3 people (`recommendedCap`, growing 3×n past 7 people), ≤20 in the extension, plus a sequential driving retry per failed transit leg — inviting `MKError.loadingThrottled`, which silently degrades legs to straight-line guesses. — `Shared/FairnessRanker.swift:~212-232, ~290-317, ~359-373`
  Suggested fix: bound in-flight legs (≈4) with a chunked task group.
- Two straight-line driving speeds: ranker `fallbackSpeed = 13.4` m/s vs `TravelMode.driving.fallbackMetresPerSecond = 11.5` used by `ResultCard`'s "~" estimate and `MeetupPlan` — ~17 % apart for "the same numbers". — `Shared/FairnessRanker.swift:~137, ~417`, `Shared/MeetupPlan.swift:~46-49`, `TweenApp/ResultRows.swift:~170-171`
  Suggested fix: delete `fallbackSpeed`; use `mode.fallbackMetresPerSecond` everywhere.
- Paywall `.task` and `.onChange(of: scenePhase)` assign `unlocked = await ProEntitlement.refresh()` unconditionally; `refresh()` writes `setUnlocked(false)` to the App Group whenever `currentEntitlements` has no verified match, and `sawVerifiedPurchase` is consulted only in `restore()`. A scenePhase bounce as the StoreKit sheet closes can downgrade a purchase that just verified. — `TweenApp/PaywallSheet.swift:~83, ~91-96, ~710`, `Shared/ProEntitlement.swift:~85-102`
  Suggested fix: `let fresh = await refresh(); if !fresh && (purchasing || sawVerifiedPurchase) { return }` in both places.

## MINOR (suboptimal, cleanup, hardening)

### Extension state machine
- Staged (insert-fallback) `.invite`/`.propose`/`.counter` commit local state immediately — floor bump, canonical snapshot, `setActive(true)`, tombstone clear, roster adoption — while only `.leave`/`.agree` defer to `didStartSending`. Deleting the staged invite leaves this device "in" and ranking with a roster no peer holds (self-heals on the next delivered send). — `TweenMessages/MessagesViewController+Delivery.swift:~78-101`, `TweenMessages/MessagesViewController+Sending.swift:~88-107`
  Suggested fix: extend the `pendingStagedSend` deferral to every staged message type.
- `commitStagedSendIfNeeded` rejects a staged leave/agree whose revision is below the floor — but the floor also advances when the user taps a peer's NEWER bubble after the staged bubble was actually sent (the natural reading order). The leave then never commits locally: peers removed the user, this device keeps them "in", and gossip can't fix it because decode filters the local user out of `departed`. — `TweenMessages/MessagesViewController.swift:~405-408`, `TweenMessages/MessagesViewController+Decoding.swift:~91-93`
  Suggested fix: compare against the floor recorded WHEN the bubble was staged (store it with the marker), not the live floor.
- The conversation-scoped draft survives a leave from either arm (`commitDeliveredLeave` clears the in-memory draft and the global blob; the host's leave clears the global blob) — `willBecomeActive` re-adopts it via `loadDraft(key:)`, force-expands into a "Send X" CTA the comment says must not survive a leave, and `hasLiveMeetup` counts it as live for 24 h. — `TweenMessages/MessagesViewController+Sending.swift:~236-237`, `TweenApp/OnboardingView+Actions.swift:~352`, `TweenMessages/MessagesViewController.swift:~233`, `Shared/ConversationMeetupStore.swift:~152-156`
  Suggested fix: `ConversationMeetupStore.clearDraft(key:)` in both leave arms.
- `searchCandidates` runs up to three sequential searches each with the 8 s deadline (POI, region-required text, iOS 18 unconstrained text) — a 24 s "Finding fair spots…" worst case against the documented 8 s. — `TweenMessages/MessagesViewController+Ranking.swift:~115-141`
  Suggested fix: share one deadline across the ladder.
- `"Couldn't open Google Maps. Try from the Tween app."` is not in `errorStatuses`, so the failure renders as a plain status line, not the warning banner. — `TweenMessages/MessagesViewController.swift:~90-94`, `TweenMessages/MessagesViewController+Delivery.swift:~219`
- Pre-delivery cache write uses `isActive: LocationCache.isActive` (freshness-gated) instead of `isOptedIn`; a failed send with a >5 min cache silently stamps the user "out". — `TweenMessages/MessagesViewController+Sending.swift:~53-54, ~324-325`
- `.leave` carries the raw cached self coordinate of any age. — `TweenMessages/MessagesViewController+Sending.swift:~152`, `TweenApp/OnboardingView+Actions.swift:~246`
- Snapshot TTL is refreshed on every drawer open (activation location refresh → `saveParticipants` → `save` stamps `updatedAt`), so a dead meetup never expires while the user keeps opening Tween there. — `TweenMessages/MessagesViewController.swift:~282-287`, `Shared/ConversationMeetupStore.swift:~217-218`
- Extension offline banner is a one-time snapshot of `isOnline` at `presentUI`. — `TweenMessages/MessagesViewController.swift:~457`

### Extension views / renderers
- `TweenMapSnapshotView.draw` composites with a default-format `UIGraphicsImageRenderer` (screen scale, 3× on device) although the snapshot was capped at 2×: every cached image is 2.25× the intended bytes, the 24 MB cache holds ~3 maps instead of ~7, and the compositing transient is larger than the comment claims. — `Shared/TweenMapSnapshotView.swift:~167, ~208`
  Suggested fix: `format.scale = snapshot.image.scale`.
- `BubbleImageRenderer.snapshot` timeout child skips `snapshotter.cancel()` when the outer task is cancelled (`Task.sleep` throws → `!Task.isCancelled` false), so `withTaskGroup` blocks until the callback-bridged `start()` finishes on its own. — `TweenMessages/BubbleImageRenderer.swift:~62-72`
  Suggested fix: cancel unconditionally (a finished snapshotter ignores it).
- `.sensoryFeedback(.success, trigger: isMeetupSet)` sits inside `meetupSetView`, which only exists while `isMeetupSet == true`; the trigger never transitions, so the "It's a plan!" haptic never fires. — `Shared/ExpandedView+SpotList.swift:~112`
- Dead code: `CompactView.markers(for:)` (and its `MapKit` import), `@ScaledMetric spotCardWidth/spotCardHeight`, and the `etas.isEmpty` A/B branches in `SpotETADisplay.chipItems`/`compactLabel` (unreachable — the legacy init already synthesises A/B legs). — `Shared/CompactView.swift:~292-322`, `Shared/ExpandedView.swift:~119-120`, `Shared/SpotETADisplay.swift:~19-20, ~37-38`

### Recent host commits (`6d39717`, `2b74aa2`, `d3d7483`, `3759dac`)
- Collapsed-at-peek block: `.frame(maxHeight: 0)` proposes 0 to a VStack whose fixed-height children (the chips' horizontal ScrollView ≈ 44 pt, Divider, any banners) don't compress, so the child overflows centred — half above the zero frame, into the header's bottom edge. `.clipped()` is drawing-only in SwiftUI and `.opacity(0)` is not documented to remove a subtree from hit testing; nothing sets `allowsHitTesting(false)`. VoiceOver (`accessibilityHidden`), keyboard/first-responder (`NativeSearchBar` is in the header; nothing focusable below) and scrolling (both ScrollViews get a 0 proposal) are fine. — `TweenApp/OnboardingView+BottomSheet.swift:~46-55`
  Suggested fix: add `.allowsHitTesting(!isMinimalDetent)` to the collapsed container. **(Applied.)**
- `ResultCard ==` omits the local travel mode read inside `myETAString` for the solo case (`MeetupPlanStore.current.mode(for:)`), so a mode change from the place sheet leaves the "~N min" estimate stale until `soloETA` lands and forces a re-render. Everything else the card draws (item identity, `etas` incl. `modeUnavailable`, `confidence`, coarse user coordinate, `isBest`, `bestWorstETA`, `soloETA`) is compared; `RankedSpot.id` is deterministic so `rankedMatch`'s per-pass estimated spots compare equal; closures captured by a skipped body read `@State` through the storage box, not a stale copy. `GroupStatusBar ==` over `members` covers all drawn fields. — `TweenApp/ResultRows.swift:~163-171, ~305-322`
  Suggested fix: pass the mode in as a stored input (`let soloMode: TravelMode`) and compare it. **(Applied.)**
- Stale comment: "hidden at 0.90" after `3759dac` moved the top detent to `.large`. — `TweenApp/OnboardingView+BottomSheet.swift:~353` **(Applied.)**
- `shouldReframe` ignores `position.positionedByUser` — a slow first fix yanks a user who already panned. — `TweenApp/OnboardingView.swift:~40-50, ~1103-1105`, `TweenApp/OnboardingView+Framing.swift:~14-29`

### Host sheets / actions (still standing from the previous report)
- Plan sheet / tutorial cover / `activeSheet` all hang off the bottom-sheet content; a deep link while either is up sets `.spot` from a presenting VC and is dropped. — `TweenApp/OnboardingView.swift:~860-915`, `TweenApp/OnboardingView+BottomSheet.swift:~73`
- `ensureNamed` routes the name alert to the root while a `.spot` sheet is up. — `TweenApp/OnboardingView+Actions.swift:~97-108`
- Overlapping toasts (unkeyed 2 s tasks). — `TweenApp/OnboardingView+FriendsSync.swift:~128`
- `openGroup` swaps `manualParticipants` without re-ranking. — `TweenApp/OnboardingView+FriendsPanel.swift:~242`
- Draft staged (with a Darwin post) before `composeTweenMessage`; nil compose leaves it armed. — `TweenApp/OnboardingView+HandOff.swift:~131`
- `ABDistanceLabel` reads positional `etaFromA/etaFromB`. — `TweenApp/ResultRows.swift:~67-73`
- Three animated camera writes per committed search; `midpointCoordinate` duplicates `MapGeometry.centroid`. — `TweenApp/OnboardingView+Search.swift:~24, ~733-794`

### Codec / stores (still standing)
- Gossip cap (8) enforced only at composers; decode writes unbounded `gone=` into TTL-exempt sync state. — `Shared/TweenState.swift:~452`, `Shared/ConversationMeetupStore.swift:~404`
- One invalid compact `p=` entry drops all `pids` (count mismatch). — `Shared/TweenState.swift:~409`
- `RosterMerge` lets an accepted inbound bubble overwrite the local user's own entry (coordinate + `needsRide`). — `Shared/RosterMerge.swift:~87`
- `isFullyAgreed` legacy name path: `filter { $0 != proposer }` drops EVERY participant sharing the proposer's name, so `[Hassan(proposer), Hassan, Carol]` + `agreed: [Carol]` is "fully agreed". Legacy (rev-less/ID-less) senders only. — `Shared/TweenState.swift:~109-117`
- `conversationMeetup.sync.*` keys accumulate forever. — `Shared/ConversationMeetupStore.swift:~236-258`
- `DriveTimePreference` falls back to `.standard` when the suite is nil; siblings no-op silently. — `Shared/DriveTimePreference.swift:~22`
- `DeadlinedSearch` conflates timeout and zero results; the rescue ladder can run ~96 s. — `Shared/DeadlinedSearch.swift:~107`, `TweenApp/OnboardingView+Search.swift:~323, ~366`
- Non-deterministic ranking ties; antimeridian centroid/span; `SpotCategoryMark` substring matching; calendar attendees by raw id; inert tutorial "I'm out"; silent `AddPointSheet` dismiss; stale "300 ms" comments. — `Shared/FairnessRanker.swift:~226`, `Shared/MapGeometry.swift:~37-61`, `Shared/SpotCategoryMark.swift:~93`, `TweenApp/PlanMeetupSheet.swift:~259`, `TweenApp/OnboardingTutorial.swift:~430`, `TweenApp/AddPointSheet.swift:~69`, `TweenApp/OnboardingView+Sync.swift:~36, ~296`

## ARCHITECTURE NOTES
- **Extension state machine (brief §1) traced and sound in the main paths:** `willBecomeActive` resets per-chat state on a key switch (incl. cancelling `sendTask`/`rankingTask` and dropping `lastKnownSession`); `decodeAndCache` skips own bubbles (with the staged-commit backstop), applies the W2 tie-break with the `.invite`-at-floor exception scoped to `==` only, merges rosters additively with tombstones, and writes partial agrees as `proposedState` (via the `kind == .place` arm); `effectiveReceived` is conversation-scoped when a key exists and falls back to the global cache only keyless; `handleImIn`/`handleImOut`/`sendAgreedPlace`/`sendBubble` all carry re-entrancy guards, cancellation checks around the only send await, and defer leave/agree commits for staged inserts; `kickOffRanking` caps at `min(5, recommendedCap)` up front; `willResignActive` cancels all three tasks. No MKMapView/`Map` anywhere in the extension; all snapshots via `MKMapSnapshotter` with a bounded NSCache; `locationProvider` is a retained `let`; fallback tile inserted at index 0 under the hosting view; hosting controller reused with a `rootView` swap.
- **Recent commits:** `6d39717` — Equatable conformances are correct for what the views draw (one omitted input noted above); keeping the sheet content mounted at peek is sound apart from the hit-testing hardening. `d3d7483` — resolves the 0.7 s keyboard-window finding: `keyboardWillChangeFrame` re-arms `expectMotion()` so a slow cold keyboard's sheet shift is no longer read as a drag; side effects nil (`expectMotion` is idempotent, fires for any app keyboard incl. the name alert, which is harmless). `2b74aa2` — one VStack container + spacing 0 at peek fixes the Group-forwarded-frame overflow; correct. `3759dac` — no remaining `.fraction(0.90)` comparisons or writes (`scrollDisabled` gate, pill visibility, harness/demo initial detents, results expand all go through `fullDetent`); `.large` is a distinct `PresentationDetent` case so equality is exact; behavioural delta is the intended glass→opaque morph, with `interactiveDismissDisabled()` still preventing pull-down dismissal at `.large`. `f8a162d`/`3a0726c` — version/report only.
- **God members:** `OnboardingView.body` ≈ 500 lines, `init` ≈ 160, `mapLayer` ≈ 100, `presentSearchResults` ≈ 103; `ExpandedView.primaryCTA` 104 lines (`Shared/ExpandedView.swift:~530-633`, a 6-way chain worth splitting); `MessagesViewController.willBecomeActive` 103 lines (`:153-255`); `deliverBubble` 88 (`+Delivery.swift:21-108`); `handleImIn` 120 (`+Sending.swift:16-135`); `sendAgreedPlace` 128 (`:289-416`).
- **Duplicated logic:** `isMeetupSet`/`isInvitePrompt` gates duplicated verbatim in `+Ranking.swift:26-27` and `ExpandedView.swift:~181-193`; participant-list building (host `buildRankingParticipants` vs extension `rankingParticipants()`); centroid (three copies); region framing; default-centre literal; straight-line ETA (two speeds). `formatETA` is single-sourced.
- `ExpandedView` reads `UserProfile.displayName` and `LocationCache` in computed properties on every render; identity should come from the controller (see the two extension MAJORs).
- Unused imports across the `OnboardingView*` files (`MessageUI` ×4, `Combine` ×3, assorted `MapKit`/`Messages`/`UIKit`/`os`); `GroupStatusBar.swift` imports MapKit unused; `CompactView.swift` MapKit unused once `markers(for:)` goes.
- Dead code: `FairnessRanker.rank(candidates:from:and:cap:)`, `MapGeometry.midpoint`, `CalendarExport.swift:25-27` unreachable `else`, dead defaults in `GroupEditorSheet`, wrong-view `#Preview` in `AddPointSheet`.
- The brief's file list is stale (`TweenViews.swift`, `ResultRow`/`RankedResultRow`/`ETAChip`, 300 ms poll); audited what exists.

## LEGACY DEBT INVENTORY
- `RankedSpot.etaFromA` / `etaFromB` / `worseETA` / `fairnessGap` — `Shared/FairnessRanker.swift:~96-107`, 2-person init `:~111`, DEBUG init `:~124-129`. Production callers: `Shared/SpotETADisplay.swift:~19-20, ~37-38` (unreachable A/B fallback), `TweenApp/ResultRows.swift:~67, ~72` (`ABDistanceLabel`, live via `+FriendsPanel.swift:~1325, ~1414`). Previews: `Shared/ExpandedView.swift:~818-819`, `TweenApp/SpotDetailCard.swift:~728`. Tests: `FairnessRankerTests`, `DriveTimePreferenceTests`, `MapGeometryTests`, `SpotETADisplayTests` (the last pins the A/B placeholder — see coverage).
- `FairnessRanker.rank(candidates:from:and:cap:)` `:~238-251` — zero callers.
- "Slice" comments: `Shared/FairnessRanker.swift:~101, ~110` (Slice 5), `:~238` (Slice 3/6); `TweenMessages/MessagesViewController+Decoding.swift:~19` (Slice 6 — its "we replace, not merge" doc is wrong; the code merges).
- `LocationCache.saveParticipantSnapshot(_:localName:)` `:~197` — harness + tests only; `loadPeer`/`isPeerActive`/`savePeer` single-peer projection and the `tween.cache.*.active` mirror keys — readers `Shared/ExpandedView.swift:~165-166`, `TweenApp/OnboardingView+Sync.swift:~145`, writers `+Decoding.swift:~134, ~138, ~145`.
- `MessagesViewController.legacyLocalParticipantID()` and the `$0.id == legacyID` filters (`+Decoding.swift:~109-110, ~279-283, ~291-294`, `+Sending.swift:~343-344`) — conversation-UUID transition shims.
- `MeetupSnapshot.pendingDraft/lastRevision/localUserLeft/departedKeys` `:~91-94` and the `loadSync`/`migrateDraftIfNeeded` rescue paths — legacy-decode shims.
- `TweenState.participantCoordinate` legacy peer fallback — `+Decoding.swift:~144-147`.
- `tween.pro.redeemedCode` — reap-only. No `@available(*, deprecated)` in the repo.

## TEST COVERAGE GAPS
Structural: `project.yml` compiles only `TweenMessages/BubbleImageRenderer.swift` into the `TweenApp` target, so every `MessagesViewController*.swift` file is unreachable from the unit bundle — the whole extension state machine (brief §1/§4) has zero coverage by construction.
- `effectiveReceived` sticky rule — NONE.
- `deliverBubble` staged-delivery path and `commitStagedSendIfNeeded` — NONE (only the store primitive `setPendingStagedSend`, `ParticipantCodecTests:~696-717`).
- MeetupSync Darwin posting/observing (`Shared/ConversationMeetupStore.swift:~11-49`) — NONE.
- Snapshot TTL expiration — PARTIAL: `clear(key:)` keeps sync state (`testTTLClearKeepsRevisionFloorAndTombstones` `:~674-694`), but no test ages `updatedAt` past `snapshotTTL`; the age comparisons at the five call sites are untested.
- Revision tie-break and `.invite`-at-floor — COVERED (`testRevisionTieBreakMatrix` `:~788-815`, `testConcurrentInviteAcceptedAtFloorButNotBelow` `:~822-845`).
- Departure gossip — PARTIAL: composer cap and URL round-trip covered (`RosterMergeTests:~105-141`); the oversize `gone=` drop, decode-side (un)capping, and both consumers (`+Decoding.swift:~92-95`, `+DeepLinks.swift:~97-100`) untested.
- `freshSelfCoordinate` vs `loadSelf` — COVERED (`ParticipantCodecTests:~890-916`, `ManualLocationTests:~36-69`); boundary `<=` and `isPeerActive` freshness untested.
- `Participant.matches` name fallback — COVERED (`ParticipantCodecTests:~448-484`, `NameIntegrityTests:~75-82`); `id==name==""` edge untested.
- `isFullyAgreed` with duplicate names — ID path only (`:~234-254`); the legacy name path has the bug above and no test.
- `rev` bounds/overflow — NONE (only value 7 round-trips). `pj=` coordinate validation — NONE (and no such validation exists).
- `ResultCard ==` / `GroupStatusBar ==` (`6d39717`) — NONE; `coarse()` is pure and testable.
- `DeadlinedSearch` timeout vs zero results — NONE. `FairnessRanker.rank` routed path, transit fallback behaviour, `mostCentral`, the 5-vs-8 cap constants — NONE.
- `OutgoingDraftStore`, `RosterMerge`, `conversationKey`, `shouldReframe` — COVERED.
- Hygiene: `MapGeometryTests` reads `DriveTimePreference` through `RankedSpot.score` with no App Group reset (latent order dependence on `DriveTimePreferenceTests.tearDown`); `ProEntitlementTests` has no `tearDown`, and `testCancelledRefreshLeavesAnExistingUnlockAlone` (`:~60-67`) races `task.cancel()` against the refresh — passes on scheduling, not on the guard; the four StoreKit tests fail on the untouched tree (per the commit message); `SearchCompleterTests.testPhaseLifecycle` kicks off a live `MKLocalSearchCompleter` request.
- Tests pinning wrong behaviour: `SpotETADisplayTests.testChipItemsFallsBackToABWhenEtasEmpty` (`:~47-53`) asserts the "A 0 min / B 0 min" placeholder; `FairnessRankerTests.testScoreFormula` (`:~36-40`) documents a formula without the `penaltyMultiplier` term and passes only because `setUp` wiped the preference; `GroupStatusBarTests.testLegacyNameKeyedETAStillResolves` (`:~84-94`) would stay green through the same-name ETA mis-attribution in `groupMembers` (`+GroupBar.swift:~33-34`).

## FIX-FIRST PRIORITY LIST
1. Bound `rev` on decode and mint with overflow checking (CRITICAL; permanent, cross-process, unrecoverable).
2. Validate `pj=` participant coordinates (CRITICAL; MapKit NSException from a crafted or corrupted link).
3. Feed the controller's `currentParticipants` into `ExpandedView` and clear the peer projection on conversation switch (MAJOR ×2; missing Send CTA and cross-chat phantom pin — the extension's core flow).
4. Sanitise `agreed=` at the encoder and wrap the host Agree path in `ensureNamed` (MAJOR; "You" leaks from both processes).
5. Own-proposal detection by `senderID` (MAJOR).
6. Defer `onSubmit` in `NativeSearchBar` (MAJOR; Return-with-autocorrect cancels its own search on device).
7. Clear or rescope `lastActiveConversationKey` (MAJOR; cross-chat state bleed).
8. Guard the `.spot → .spot` sheet swap with a pending action (MAJOR).
9. Guard the paywall's scenePhase/initial refresh (MAJOR; downgrades a real purchase).
10. Bound MKDirections concurrency and unify the straight-line speed (MAJOR).
11. Extension staging batch: defer all staged message types, compare staged commits against the floor at staging time, clear the scoped draft on leave (MINOR ×3; all split-brain-adjacent).
12. ~~`allowsHitTesting(!isMinimalDetent)` on the collapsed sheet block and the `soloMode` input in `ResultCard ==`~~ (applied the same day).
13. `TweenMapSnapshotView` renderer scale, `BubbleImageRenderer` unconditional cancel, the never-firing success haptic (MINOR; extension memory + polish).
14. Make the extension state machine testable (move `MessagesViewController*` logic behind a target-neutral type or add it to the test-visible target) and add the `rev`/`pj`/legacy-`isFullyAgreed`/TTL-age tests.
