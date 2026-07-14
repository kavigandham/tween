# AUDIT REPORT — Tween — 2026-07-13 (full repo at 1aa4712, post-push; fixes landed in the follow-up commit)

> **Addendum (fb3c384):** an adversarial verify of the fix commit `b0f5907` found no MAJORs; its three findings are **FIXED** in `fb3c384`: (1) the displayedItems union let far unranked leftovers drive the final search camera — `frameResults`/`frameResultsWithParticipants` now `prefix(rankCap)` like the other two framers (leftovers stay in the list, not the frame); (2) the three I'm out buttons now carry `.disabled(isSending)` so the new re-entrancy guard doesn't silently swallow taps; (3) `handleImIn`'s delivered-commit now keys the tombstone clear to a `sendKey` captured before the first await and gates in-memory roster adoption on still being in that chat (deliverBubble's deliveryKey pattern). The same pattern for `commitDeliveredLeave`/`commitDeliveredAgree` (adjacent pre-existing, narrow race) is spun off as a dedicated follow-up task. Verified: 174 tests green, corridor framing re-checked in the simulator. No new audit spawned for `fb3c384` per the fixes-only-push precedent — the audit/verify chain for this change-set is closed.

Extra scrutiny on `1aa4712` (SpotVicinity between-people filter, POI category chips, Google Maps trampoline). Zero CRITICAL. The three MAJORs + two MINORs below are **FIXED** in the commit following this report; the rest is triaged.

## COMMIT 1aa4712 SCRUTINY — verified clean
- SpotVicinity math correct (spread = max centroid→participant distance; radius = max(0.75×spread + 2 km, 3 km)); safe on empty inputs; in BOTH targets' Sources; extension interplay sane (pool 8 → filter ≥3 → cap 5).
- Chip branch can't misfire (selectedCategory cleared on divergent keystrokes; suppress latch protects the committed search). All 12 `MKPointOfInterestCategory` values are iOS 13+. `regionPriority` correctly iOS 18-gated.
- Trampoline routing unambiguous both directions: only `tween://maps` decodes as a handoff; meetup payloads are `https://tween.app/m` (and require `t`), `tween://search` is host-checked. Percent-encoding round-trips (now tested incl. emoji). No `canOpenURL` anywhere → no `LSApplicationQueriesSchemes` needed.

## CRITICAL — none

## MAJOR — all FIXED
- **[FIXED] SpotVicinity spec/behavior mismatch.** `filter` never returns empty for non-empty input (relax ×1.5/×2.5 → unfiltered fallback), so (a) the "far typed place doesn't rank" comment was wrong, and (b) when ≥3 in-circle hits existed, the far place the user actually searched was silently DROPPED from the visible list (display swapped entirely to rankedSpots). Fix: `displayedItems` now unions ranked spots + any raw hits the cut (or rank cap) trimmed, as unranked rows below — a searched far place never vanishes; comments rewritten to match real semantics. — `OnboardingView.swift` displayedItems + runSearch comment.
- **[FIXED] "I'm out" double-fire.** `handleImOut` lacked the `!isSending` re-entrancy guard — a second tap during the send window cancelled a delivered leave and emitted a duplicate `.leave`. Guard added (and to `handleImIn` for the same `.invite` race). — `MessagesViewController.swift`.
- **[FIXED] Departed user force-expanded back into MEETUP SET.** Leaving a group that still has members preserves the scoped `agreedState` (by design, for rejoin), but neither the `willBecomeActive` snapshot restore nor `effectiveReceived`'s sticky-agreement injection consulted the leave tombstone — a leaver reopening the extension landed in the terminal "It's a plan!" hero. Both injection points now gate on `ConversationMeetupStore.localUserLeft(key:)`; the roster restore stays (rejoin needs it). — `MessagesViewController.swift`.

## MINOR — two FIXED, rest triaged
- **[FIXED] `resolveCategory` POI region unclamped** — far-apart groups exceeded `MKLocalPointsOfInterestRequest.maxRadius`, erroring the request and silently downgrading chips to the text engine. Now clamps radius to the API max around the midpoint. — `OnboardingView.swift`.
- **[FIXED] `handleImIn` tail ran on failed/cancelled sends** (force-expand + re-rank of whatever chat is now active). Gated on `didSend && !Task.isCancelled`. Also **[FIXED]**: `addManualPoint`/`removeManualPoint` cancel a mid-flight search without clearing `isSearchLoading` → stuck spinner; cleared at the cancel site.
- Harness/launch hooks (`-HARNESS_HOST_*`, `-START_AT_PEEK`, `-SKIP_TUTORIAL`) not `#if DEBUG`-gated — ship in release (low risk; launch args need a dev connection). — `OnboardingView.swift:~96/~263`.
- `FairnessRanker.recommendedCap` floors at 3 → `cap × participants` can exceed `maxTotalRouteCalls = 20` at 7+ people (legs degrade to straight-line under throttle). — `FairnessRanker.swift:107`.
- `UserProfile.displayName` setter writes `userName` unsanitized (UserName.save trims/rejects empty) — two writers, one key. — `OnboardingFlags.swift:37`.
- `FriendRoster.delete` never prunes `pingLog` → orphaned entries accumulate. — `TweenFriend.swift:57`.
- Several app surfaces render `senderName` raw instead of `UserName.peerDisplayName` (legacy "You" payloads show "You" in cards). — `BubbleCaption.swift:14`, `TweenViews.swift:641/1235/1262/1308`, `OnboardingView.swift:1956/3920/3953`, `SpotDetailCard.swift:384`.
- `saveParticipantSnapshot` writes roster + legacy peer projection as two `defaults.set` calls — transiently inconsistent cross-process (self-heals). — `LocationCache.swift:191`.
- `lastActiveConversationKey` never cleared — can dam global peer writes via a stale conversation's tombstone until the next activation. — `ConversationMeetupStore.swift:163`.
- `TweenState(url:)` validates scheme but not host — tighten now that `tween://maps` routing relies on host discrimination. — `TweenState.swift:333`.
- Test hygiene: the suite wipes the REAL App Group in `setUp` (running tests on a device with the app installed destroys live state) — point tests at an isolated suite. `SearchCompleterTests` fires a live network request.

## ARCHITECTURE NOTES
- God files: `OnboardingView.swift` 4,235 (body 309, handleIncomingURL 210, refreshFromAppGroup 209), `TweenViews.swift` 2,011, `MessagesViewController.swift` 1,657.
- Rank-cap derivation duplicated app vs extension (numerically equivalent); `SearchResultMerger` misplaced in FairnessRanker.swift; distance/ETA formatting duplicated (ResultCard vs ABDistanceLabel vs SpotDetailCard.driveLabel).
- View-layer contracts clean: all call sites pass required params; no force unwraps in view code; CompactView keyboard-free; snapshotter-only in CompactView/BubbleImageRenderer.

## LEGACY DEBT (carried)
- `etaFromA/etaFromB` callers render participants[0]/[1] only (`SpotETADisplay.swift:20/38`, `ResultRows.swift`, `SpotDetailCard.swift:348`); legacy 2-person rank adapter; deprecated `BubbleImageRenderer.makeImage(selfCoord:peerCoord:)` (zero callers); dead UI code (`ETAChip`, `RankedResultRow`, interactive-map members behind the hardcoded static flag, `insertBubble`, `requestOnceIfAuthorized`, `UserName.clear`, `OnboardingView.midpoint`, `LocationCache.clearAll`); legacy peer-projection keys dual-written; name-only `saveParticipantSnapshot` overload still called (`OnboardingView.swift:442`).

## TEST COVERAGE GAPS
- Extension-target logic unreachable by the unit suite (no target imports MessagesViewController) — `effectiveReceived` sticky rule + the new tombstone gates, staged-delivery path, `MeetupSync`, TTL age-out boundary all untested.
- New-surface gaps now partially closed: CategoryPreset mappings ✔ (added), decodeHandoff negatives + emoji ✔ (added); SpotVicinity ×2.5 tier still never the deciding tier in a test.
- Still uncovered: `LocationCache.agreedMeetup` trio, `LocationProvider`, `NetworkMonitor`, `OnboardingFlags`, `SpotETADisplay.qualityColor`.

## CARRIED (unchanged from prior audits)
- Dead interactive map (`usesStaticMapForCurrentState` hardcoded true) — decision pending.
- `isFullyAgreed` legacy name-only path duplicate-name false positive (legacy payloads only).
- First-run tutorial cover can swallow an incoming `tween://` proposal sheet (Help-button direction fixed earlier; cold-open direction open).
- `UserDefaults(suiteName:)` nil (bad entitlement) undetected — `TweenIdentity.stableID` would mint per-call UUIDs.
- Stale "300 ms poll" comments (poll sleeps 2 s).

## FIX-FIRST PRIORITY LIST
1. ~~SpotVicinity spec/display mismatch~~ — **FIXED** (displayedItems union + honest comments).
2. ~~"I'm out"/"I'm in" double-fire guards~~ — **FIXED**.
3. ~~Departed-user MEETUP SET restore~~ — **FIXED** (tombstone gates at both injection points).
4. ~~POI region clamp~~ / ~~handleImIn tail~~ / ~~manual-point stuck spinner~~ — **FIXED**.
5. Isolated App Group suite for tests (stop wiping real device state).
6. Extension-logic test harness (effectiveReceived + tombstone gates are now load-bearing and untested).
7. Hygiene batch: #if DEBUG harness args, peerDisplayName sweep, PingLog prune, displayName sanitize, route-call bound, lastActiveConversationKey lifecycle, TweenState host validation.
8. Carried decisions: interactive map delete-or-restore; isFullyAgreed name-path hardening; god-file split.
