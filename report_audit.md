# AUDIT REPORT — Tween — 2026-07-12 (HEAD deca838, post-push audit of Phase A+B)

Read-only audit fanned out over the six high-risk files plus the rest of `Shared/`,
`TweenApp/`, and the tests. Recently-changed areas (ExpandedView rebuild,
SpotETADisplay, `outgoingName`/`peerDisplayName` sanitization, `.midpoint` removal,
TweenPin.Context) were verified line-by-line.

Headline: the ETAChip→Spot* migration, `.midpoint`/`pinMidpoint` removal, revision
tie-break, departure gossip, and the TTL/sync-state split are all correct and
consistent — no dangling references, all pin-role switches exhaustive, all migrated
call sites match. Regressions clustered around the name-sanitization work (F2) and
the rebuilt ExpandedView.

> **Status after this audit:** the CRITICAL and both MAJOR name-sanitization
> findings are **FIXED** (commit following deca838); the interactive-map finding is
> the standing T10 decision; the rest are triaged below.

---

## CRITICAL — RESOLVED

- **[FIXED] Stray `@ViewBuilder` on `snapshotFocus`** (a non-View computed property).
  This was a transient mid-Phase-C state the audit caught; the committed code moved
  `@ViewBuilder` back onto `mapSection`. Build + full suite green. — `Shared/TweenViews.swift`

## MAJOR

- **[FIXED] "You" leaked into the agree bubble caption.** `sendAgreedPlace` appends
  `myName` (= "You" for un-named users) to `agreedNames`, encoded via `encodeNames`
  which — unlike `encodeParticipants` — does not apply `outgoingName()`, so
  `BubbleCaption` rendered "You agrees to …". Fixed by sanitizing the agreer through
  `UserName.peerDisplayName` in BubbleCaption (catches both wire-"You" and empty);
  2 new BubbleCaptionTests. — `Shared/BubbleCaption.swift:48`
- **[FIXED] Unnamed peer double-counted in the host roster ("2 in" for one peer).**
  `activeParticipantsForDisplay` gated the legacy peer append on
  `$0.name == peerDisplayName` — since F2 that compares "Friend" against the raw
  ""/"You" roster entry, never matches, and appended a synthetic peer. Fixed:
  identity-based guard (`!contains { !isLocalParticipant($0) }`), real id, and the
  self-sort now uses `isLocalParticipant`. — `TweenApp/OnboardingView.swift:2008`
- **[DEFERRED — T10] The sanctioned interactive `Map` path is unreachable.**
  `usesStaticMapForCurrentState` is hardcoded `true`, so `interactiveMap`/`spotPin`/
  `cameraBounds` and the `mapDegraded`/`useStaticMap`/`didReceiveMemoryWarning`
  degrade machinery are dead. This satisfies HARD CONSTRAINT #1 more strictly than
  documented but contradicts the CLAUDE.md sanctioned-exception text. Decision
  pending on-device memory profiling; if kept, delete the dead live-map code and
  update CLAUDE.md. — `Shared/TweenViews.swift:1446`

## MINOR (triaged — not yet applied)

- `SearchCompleter.update(query:)` doesn't cancel a pending debounce task, so a
  keystroke debounced ~300 ms earlier can fire after a clear. — `TweenApp/SearchCompleter.swift:133`
- `LocationCache.clearAll()` omits `MeetupSync.post()` (test-only caller today). — `Shared/LocationCache.swift:250`
- `RankedSpot.score` divides by `confidence` with no floor → NaN/Inf for
  `confidence == 0` (public/DEBUG inits only), which breaks the sort's strict-weak
  ordering. — `Shared/FairnessRanker.swift:45`
- `FairnessRanker.rank` traps on negative `cap` (`prefix(cap)`); unreachable with
  current callers. — `Shared/FairnessRanker.swift:119`
- `fullScreenCover` (tutorial) and `sheet(item:)` share one anchor — an `onOpenURL`
  place sheet during first-run tutorial is dropped/deferred. — `TweenApp/OnboardingView.swift:637`
- Extension `Task` closures capture `self` strongly (all `@MainActor`, stored,
  cancelled in `willResignActive` — bounded). — `TweenMessages/MessagesViewController.swift`
- `handleImIn`/`handleImOut` lack the `!isSending` re-entrancy guard `sendAgreedPlace`
  has (roster merge dedupes, so low impact). — `TweenMessages/MessagesViewController.swift:860`

## ARCHITECTURE NOTES

- God methods (>80 lines): OnboardingView `body` (~284), `handleIncomingURL` (~192),
  `refreshFromAppGroup` (~186); MessagesViewController `sendAgreedPlace` (~112);
  TweenViews `primaryCTA` (~139, a 9-way if/else cascade — the most fragile part of
  the rebuilt view; a computed CTA-state enum would help).
- Cross-process last-writer-wins on the snapshot blob is the residual concurrency
  exposure (mitigated by the sync-state split; revision is monotonic-max, flags
  idempotent).
- Extension is unit-untested: no test target imports `TweenMessages`, so
  `effectiveReceived`/`deliverBubble`/activation logic have zero coverage.

## LEGACY DEBT INVENTORY

- Legacy 2-person accessors `etaFromA`/`etaFromB`/`worseETA`/`fairnessGap` + the
  2-person `RankedSpot` init still in use (compat shim): read by SpotETADisplay,
  ResultRows, SpotDetailCard. Marked for "Slice 5/6" removal.
- Dead `ETAChip` struct — zero call sites after the migration. — `TweenApp/ResultRows.swift:~54`
- `RankedResultRow` used only by its own `#Preview`.
- Redundant memory-degrade machinery (`mapDegraded`/`useStaticMap`) — no-ops while
  ExpandedView is always static.

## TEST COVERAGE GAPS

Well-covered: TweenState codec, `Participant.matches` (incl. remote-"You"),
ConversationMeetupStore (TTL/revision/tombstones/migration), RosterMerge, LocationCache
freshness, FairnessRanker scoring, `outgoingName`, `peerDisplayName`, and now
BubbleCaption agreer sanitization.

Still thin: `effectiveReceived` sticky rule, `deliverBubble` staged delivery,
`MeetupSync.post()` observation, SpotETADisplay drive-balance track math
(`position`/`spreadStart`/`spreadWidth`), `isFullyAgreed` positive duplicate-name case,
host send/agree/leave flows.

## FIX-FIRST PRIORITY LIST

1. ~~Verify `snapshotFocus` compiles~~ — FIXED.
2. ~~Stop the "You" leak in agree captions~~ — FIXED (BubbleCaption sanitize + tests).
3. ~~Fix the unnamed-peer double-count~~ — FIXED (identity-based dedup).
4. Decide the interactive map (T10) — remove dead code + update CLAUDE.md, or restore.
5. `SearchCompleter.update(query:)` cancels its debounce task.
6. Harden `FairnessRanker` (confidence floor, `prefix(max(cap,0))`); add
   `MeetupSync.post()` to `clearAll()`.
7. Backfill unit tests for `effectiveReceived`, `deliverBubble` staging, and the
   SpotETADisplay track math.
