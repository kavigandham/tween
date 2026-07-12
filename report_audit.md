# AUDIT REPORT — Tween — 2026-07-12 (full repo audit, post-push of d0d9a64)

Read-only full-repo audit per `prompts/repo_audit.md`, extra scrutiny on the just-pushed `470b721` + `1e185e9`. No source modified during the audit.

> **Separately found + FIXED (`bd55de7`, not from this audit):** a device-feedback bug where a solo A→B search's ranking was wiped ~2 s after landing — `refreshFromAppGroup`'s `localLeft` branch cleared `rankedSpots` on every poll tick while a conversation's leave tombstone lingered. Now gated on `shouldResetRankingOnLeave(localLeft:hasLivePeerState:)` (clear only on the peer-teardown tick). Unit-tested + simulator-verified via `-DEMO_SOLO_AFTER_LEAVE`.

## EXTRA-SCRUTINY VERDICT (470b721 + 1e185e9) — CLEAN, one caveat
- `qualityColor`/`qualityWord`/`qualityMetric` correct; color and word bucket on the same metric (nil → `fairnessSpread`; non-nil → `worstETA − bestWorstETA`). No stale `fairnessColor`/`fairnessWord` refs.
- Every production multi-spot render site threads the correct `rankedSpots.map(\.worstETA).min()`. The only nil-passing caller besides single-spot `SpotDetailCard` is `RankedResultRow` — `#Preview`-only.
- `resolvePlace` two-pass search: no loop / no double-count; local match returns the `.required` result immediately (no "Sushi Unlimited" regression); iOS 17 collapses to one search; callers handle empty without dead-ending.
- Solo-waiting dedupe: no blank/broken panel in any (isUserIn × hasSpots × waiting) state.
- **Caveat:** two of the three `spotBestWorstETA` sites `1e185e9` threaded (`spotPin` text + a11y, `TweenViews.swift:1519/1540`) live in the DEAD interactive-map path (see MAJOR), so that portion has no runtime effect today. The fix itself is correct.

## CRITICAL — none
No ≥70%-confidence crash/corruption path. Extension state machine + URL codec are heavily hardened (revision floors, tombstones, staged-delivery deferral, delivery-gated commits).

## MAJOR
- **Conversation switch cancels `rankingTask` but not `sendTask`, never resets `isSending`** — `MessagesViewController.swift:~161`. An in-flight send completing after the switch commits roster/revision under the NEW conversation's key; a stuck `isSending` disables CTAs. Fix: `sendTask?.cancel()` + `isSending = false` in the switch block.
- **Interactive `ExpandedView` Map is unreachable** — `usesStaticMapForCurrentState` hardcoded `true` (`TweenViews.swift:1507`), so the sanctioned pan/zoom map, `cameraBounds`, `spotPin`, `mapPosition` fly-to are all dead. No constraint violated (snapshotter-only is safest for 120 MB), but a documented feature is silently off + dead code. Fix: delete the interactive-map members or restore a real per-state condition.
- **`AddPointSheet.pick` runs a bare `Task {}` (no `@MainActor`)** that mutates OnboardingView `@State` (`manualParticipants`, `savedCoordinate`, `isUserIn`, `position`) + `dismiss()` off-main after `await resolvePlace` — `OnboardingView.swift:~4046`. Fix: `Task { @MainActor in … }`.
- **Search cancellation leaves `isSearchLoading` stuck true** — `runSearch`'s `guard !Task.isCancelled` returns before `isSearchLoading = false` (`~3190`); the scenePhase handler cancels the task, so a backgrounded/superseded search leaves the spinner up until the next keystroke. Fix: reset in the cancellation guard / scenePhase handler.

## MINOR
- `mapDegraded` not reset on conversation switch — bleeds a degraded static map into the next chat (`MessagesViewController.swift:~161`).
- `sendChosenSpot`/`sendCounter`/`sendDraft` lack the `guard !isSending` guard `sendAgreedPlace` has — a double-tap can emit two place bubbles (`~1047/~1245/~1289`).
- `decodeAndCache` advances the revision floor under `revisionKey` but persists the scoped snapshot only when the `conversationKey` ivar is non-nil — a nil-ivar decode could bump the floor while dropping the snapshot (`~382`).
- `FairnessRanker` route calls (`MKDirections.calculate()`, `FairnessRanker.swift:195`) have no timeout; one stalled leg keeps `rank()` pending + the spinner up. Only `MKLocalSearch` has the 8 s timeout.
- `LocationProvider.locationManagerDidChangeAuthorization` mutates `status` directly, bypassing the `settle()` main-actor hop (`~116`).
- `.fullScreenCover($showTutorial)` + `.sheet(item:$activeSheet)` on the same view — Help button no-ops the tutorial while any sheet is open (`~693`).
- `(x)`-clear path doesn't reset `searchViewMode` — a prior `.map` mode persists into the next search (`~2974`).
- `TweenState.isFullyAgreed` legacy name-only path can false-positive with duplicate display names (`TweenState.swift:109`); new builds stamp unique `senderID`, so legacy/rev-less bubbles only.
- Stale comments say "300 ms poll" where `pollPeer` sleeps 2 s (`~848/~3288/~3463`).

## ARCHITECTURE NOTES
- God files: `OnboardingView.swift` 4061 lines (`body ~301`, `refreshFromAppGroup ~198`, `handleIncomingURL ~192`); `TweenViews.swift` 2011; `MessagesViewController.swift` 1595.
- Duplicated rank-cap derivation (app `count>=3 ? recommendedCap : 8` vs extension `min(5, recommendedCap)`) — consider one `FairnessRanker.cap(for:ceiling:)`.
- Two `saveParticipantSnapshot` overloads; the name-only one still called from `OnboardingView.swift:442` (`localName:"You"`).
- Verified clean: all App Group keys have matching reader/writer via shared constants (no orphans); every canonical writer posts `MeetupSync`; `MeetupSyncToken.deinit` removes the observer; TTL clear preserves `ConversationSyncState`; no force-unwrap crash paths.

## LEGACY DEBT
- `etaFromA`/`etaFromB` still called: `SpotETADisplay.swift:20/38`, `ResultRows.swift:137/142`, `SpotDetailCard.swift:348`.
- Dead code to remove: `insertBubble(for:dismissAfterInsert:)` (`MessagesViewController.swift:1397`, zero callers); `interactiveMap`/`cameraBounds`/`spotPin`/`allMeetupCoords`/`mapPosition` (dead behind the static-map flag); `ETAChip` + `RankedResultRow` (`#Preview`-only); `LocationProvider.requestOnceIfAuthorized()`; `UserName.clear()`; `OnboardingView.midpoint(_:_:)`.

## TEST COVERAGE GAPS
- `ConversationMeetupStore` TTL age-expiry boundary; `effectiveReceived` sticky rule; `MeetupSync` post/observe; `SpotETADisplay.qualityColor` (only `qualityWord` covered); `resolvePlace` two-pass fallback; `deliverBubble` staged-delivery UI path; `handleImIn`/`handleImOut`/`sendAgreedPlace`/`sendCounter`; `OnboardingFlags`; `isFullyAgreed` duplicate-name legacy path.
- Covered (no gap): revision tie-break, departure gossip + cap, `freshSelfCoordinate` window incl. manual exemption, `Participant.matches` edges, `isFullyAgreed` via IDs, URL round-trip + ≤5000 cap.

## FIX-FIRST PRIORITY LIST
1. Cancel `sendTask` + reset `isSending` on conversation switch (cross-chat contamination + stuck CTAs).
2. Decide the interactive map: delete the dead `Map`/`cameraBounds`/`spotPin`, or restore a real `usesStaticMapForCurrentState` condition.
3. `AddPointSheet.pick` post-await mutations → `@MainActor`.
4. Reset `isSearchLoading` on search cancellation.
5. `!isSending` re-entrancy guard on `sendChosenSpot`/`sendCounter`/`sendDraft`.
6. Per-leg timeout on `FairnessRanker` route calls.
7. Tests: `effectiveReceived` sticky-rule, TTL expiry, `MeetupSync`, `qualityColor`.
8. Delete dead code (list above).
9. Harden `isFullyAgreed` duplicate-name legacy path.
