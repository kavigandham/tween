# AUDIT REPORT — Tween — 2026-07-12 (HEAD ce5442e, post-push audit of the 3 device-feedback fixes)

The three fixes in ce5442e (fairness colors, spot-in-context snapshot geometry, bubble footer) are **sound** — call sites consistent, tokens exist, `footerHeadline` is exhaustive over all five `MessageType` cases and sanitises the leave sender via `UserName.peerDisplayName`, and the new snapshot math is **NaN-safe** (coordinates guaranteed non-empty; single/degenerate points floor to a min span; the center bias keeps every point in frame — verified algebraically). The genuine problems were in adjacent recently-churned code — the "fix one encoder, miss the siblings" pattern again.

> **Status after this audit:** the three MAJOR + one MINOR findings are **FIXED** (commit following ce5442e). Notes/test-gaps triaged below.

## CRITICAL — none

## MAJOR — FIXED

- **[FIXED] `sendAgreedPlace` broadcast a live GPS fix over a declared "I'll be at…" location and stripped `isManual`.** `handleImIn` guards this (`isManual && isActive → use declared coord`); the agree path did not — it unconditionally `acquireLocation()` + `save(fresh, isManual:false)`, broadcasting your CURRENT spot as `senderCoordinate` and corrupting the cache for later sends. Added the same guard at the top of coordinate resolution — `MessagesViewController.swift:~1101`.
- **[FIXED] Manual-point re-rank ran in an untracked, uncancellable `Task` with no cancellation guard**, so a slower older ranking could finish last and stomp a newer one (and the map/list then showed spots for a stale participant set). `addManualPoint`/`removeManualPoint` now funnel through `searchTask` (so a committed search or rapid add/remove cancels the prior re-rank) and `rerankCurrentResults` guards `!Task.isCancelled` before assigning `rankedSpots` — `OnboardingView.swift:~3110`/`~3133`.
- **[FIXED] `canSearch` accepted only a GPS/peer anchor**, so a GPS-denied user doing a pure manual A→B search got nagged for location even though `searchRegion` already centers on their manual points. Now also accepts `!manualParticipants.isEmpty` — `OnboardingView.swift:~3052`.

## MINOR — FIXED

- **[FIXED] Fairness-tinted time text on the extension card row had no capsule backing** (bare yellow "Fair" on a light surface → low contrast in light mode). Added the same `tint.opacity(0.16)` capsule the host chip uses — `TweenViews.swift:~1174`.

## ARCHITECTURE NOTES

- **`isBest` reference-equality is fragile.** `rankedSpots.first?.item == item` works only because `displayedItems` reuses the same `MKMapItem` references; a refactor that rebuilds items would silently break the "Best" badge. Consider keying on `RankedSpot.id`. — `OnboardingView.swift:1834`, `TweenViews.swift:1119`.
- **Outgoing-self-coordinate resolution is duplicated across four send paths** (`handleImIn`, `sendAgreedPlace`, `sendCounter`, `sendChosenSpot`/`sendDraft`); exactly one had drifted (the MAJOR above). Centralising into a single `resolveOutgoingSelfCoordinate()` that honours the manual/freshness/opt-in rules would kill the whole class of bug.
- LocationCache manual gating is otherwise consistent (freshness-exempt but opt-in-gated; `setFlag` preserves `isManual`; a deactivated declaration is non-sendable).

## TEST COVERAGE GAPS

- **No test exercises the extension send paths** (`sendAgreedPlace`/`handleImIn`) — nothing imports `MessagesViewController`; the `sendAgreedPlace` clobber slipped through because of it. A declared+active agree keeping `isManual` + sending the declared coord would catch it.
- **The snapshot focus-branch geometry has no unit test** — it's inside a private `View.render`. Extracting the region computation into a pure `MapGeometry` helper would make the single-point / everyone-in-frame invariants testable.
- `footerHeadline` now covers `.leave`/`.invite`/`.propose`/`.counter`/`.agree` (added this pass). `rerankCurrentResults` cancellation/ordering still untested.

## FIX-FIRST PRIORITY LIST

1. ~~`sendAgreedPlace` declared-location clobber~~ — FIXED.
2. ~~Untracked/uncancelled manual re-rank race~~ — FIXED (searchTask + `!Task.isCancelled`).
3. ~~`canSearch` blocks GPS-free manual A→B~~ — FIXED.
4. ~~Yellow "Fair" time contrast~~ — FIXED (capsule backing).
5. Future: extension-send test harness; extract the snapshot region math for testing; centralise outgoing-self-coordinate resolution.
