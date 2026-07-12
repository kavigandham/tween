# AUDIT REPORT — Tween — 2026-07-12 (HEAD 470b721, post-push audit of the 3 device-feedback fixes)

Fixes audited: quality colours ranked vs the best option, local idea-match search (`regionPriority = .required`), and the extension solo-waiting dedupe. The 2-person flow (host list card, place sheet, extension spot cards, drive-balance) was threaded correctly and it compiles — but the audit hit the **"fixed one site, missed a sibling"** pattern again on two paths.

> **Status after this audit:** the two MAJOR + one MINOR findings are **FIXED** (commit `1e185e9`, following 470b721). Verdict was "not a hard blocker for the common 2-person flow, but fix before relying on group meetups or suggestion taps" — done.

## CRITICAL — none

## MAJOR — FIXED

- **[FIXED] Extension map-pin label + spot-card/pin a11y labels omitted `bestWorstETA` → every 3+ pin read a constant "Fair".** `compactLabel` calls `qualityWord` for 3+ participants; with no reference the delta was `worstETA − worstETA = 0`, so a genuinely far group spot's pin mislabelled itself "Fair" — the exact bug class the commit fixes, missed at three siblings (`TweenViews.swift:1113`/`:1519`/`:1540`). Threaded the existing `spotBestWorstETA` (`TweenViews.swift:1143`) into all three. 2-person pins were never affected (they return names+times).
- **[FIXED] `.required` search dead-ended a distant unique place to zero results.** A typed exact name, or a tapped `SearchCompleter` suggestion outside `searchRegion`, resolved under `.required`, matched nothing local, and landed on "No fair spots found" — a dead-end that didn't exist pre-commit. `resolvePlace` now runs the `.required` local pass first and, only if it's empty, falls back to the region-as-hint search (`OnboardingView.swift:3075`), so idea-match stays local but a distant name-match still resolves. Chosen over constraining the completer because it also covers the typed-name case (audit NOTE C).

## MINOR — FIXED

- **[FIXED] A lone spot's detail strip read uniformly green even when lopsided**, contradicting the `fairnessCaption` ("A longer drive for some than others") directly below it (`SpotDetailCard.swift:290`). A single spot has no better option to rank against, so `nil` `bestWorstETA` now judges it by its own evenness (`fairnessSpread` → "Even"/"Fair"/"Uneven", same tiers as the caption) instead of defaulting to green — `SpotETADisplay.qualityColor/qualityWord`.

## NOTES (verified, no action)

- `RankedResultRow` / `SpotETASummaryPill` render a `nil`-default reference, but `RankedResultRow` is used ONLY in a `#Preview` (`ResultRows.swift:394`) — not production. With the new `nil → evenness` fallback it degrades to a spread-based tint rather than constant green anyway.
- `.required` tradeoff is now bounded by the fallback: a search still prefers local idea-matches; only when NOTHING local matches does a distant name-match surface.
- Extension category search (`MessagesViewController.swift:775`, fixed category term) intentionally keeps region as a bias only — no far name-match risk, not touched.
- Rename completeness clean: `grep fairnessColor|fairnessWord` → zero refs across app/extension/tests; `fairnessCaption` retained, single-spot/spread-based. Tests updated to the new semantics.
- `panelEmptyState` / `primaryCTA` dedupe safe across every (isUserIn × hasSpots × waiting) combination — the `isUserIn` CTA→`EmptyView` branch is only reachable when `panelEmptyState` renders the status card, so no blank panel. "You're in" is reached only in the pure solo-waiting substate.

## STILL OPEN (carried from prior audits — future, not regressions)

- Extension-send test harness (`sendAgreedPlace`/`handleImIn` are untested).
- Extract the snapshot region math into a pure `MapGeometry` helper for unit testing.
- Centralise outgoing-self-coordinate resolution across the four send paths.
- `isBest` reference-equality (`rankedSpots.first?.id == spot.id`) is fine now that it keys on `RankedSpot.id`.
