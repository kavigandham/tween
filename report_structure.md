# STRUCTURE AUDIT — Tween — 2026-07-13 (HEAD 6853735)

> **Progress (2026-07-13 evening):** the zero-risk phase is DONE — dead code deleted (`84292c1`), TweenViews split into 4 files (`50ff203`), misplaced types relocated (`c02c649`), plus the 6853735 audit fixes (`0bd87ed`). Largest file is now OnboardingView at 4,139; TweenViews is gone (ExpandedView.swift 1,306 is the biggest Shared file). The RISK PHASE plan below (§Risk work) is the concrete blueprint for what remains.

## RISK WORK — how to reformat the two remaining god files (blueprint)

The Swift ground rules that shape everything here:
- **Extensions in other files cannot see `private` members** → any member referenced across the new file boundary demotes to internal (module-scoped; the extension target's module has 2 files, the app's ~15 — contained exposure).
- **Extensions cannot add stored properties** → every `@State`/`let` stays in the core struct/class declaration. Only methods and computed properties move. This is why the splits are LOW-risk mechanically but non-zero: the diff touches hundreds of `private` keywords, and a typo'd demotion produces a compile error, not silent breakage — the compiler is the safety net.
- **Nested types CAN be declared in extensions in other files** (`extension OnboardingView { enum ActiveSheet {...} }`) — the sheet router enums can move.

### R1 — MessagesViewController.swift (1,672) → 5 files — LOW risk, do first
Cut along the existing MARKs into `extension MessagesViewController` files: `+Decoding` (~285: decodeAndCache, effectiveReceived, shouldAccept plumbing), `+Ranking` (~150), `+Sending` (~450: handleImIn/Out, sendChosenSpot/AgreedPlace/Counter/Draft), `+Delivery` (~180: deliverBubble, recordCanonicalSnapshot, staged-send backstop, maps opening); core keeps State/Lifecycle/Hosting (~600).
**The real win:** while moving `+Decoding`, extract the PURE decision kernels into `Shared/` enums — `AgreementResolution.effectiveState(decoded:stored:localLeft:sameSpot:)` and the snapshot-hint formatter — because the #1 coverage gap is that NO test can reach extension logic, and these kernels (sticky-agreement rule, tombstone gates) are the most audit-bitten logic in the app. Pure functions in Shared = unit-testable from TweenAppTests with zero test-host work.
Verification: full suite + `-HARNESS` UI tests after each file move; one extension smoke test in Messages on device at the end (send/agree/leave once).

### R2 — OnboardingView.swift (4,139) → ~8 files — MEDIUM risk, one extension file per commit
Move order (safest first, each its own commit + suite run):
1. `OnboardingView+Framing.swift` (~300) — pure camera math, few cross-refs.
2. `OnboardingView+DeepLinks.swift` (~220) — handleIncomingURL + openGoogleMapsExternally.
3. `OnboardingView+HandOff.swift` (~240) — sendToChat/compose. Depends on state + framing.
4. `OnboardingView+Sync.swift` (~260) — refreshFromAppGroup/pollPeer. Highest cross-ref density; do after the patterns are proven.
5. `OnboardingView+Search.swift` (~400) — runSearch/resolvePlace/resolveCategory/canSearch.
6. `OnboardingView+FriendsPanel.swift` (~1,070) — the friends/ride UI + logic; biggest but most self-contained.
Core keeps: the ~100 stored `@State` properties, `body`, the sheet router, bottom-sheet UI, DEBUG seeds (~1,600 → later shrinkable via R3).
Directory grouping in the same commits: `TweenApp/Search/`, `TweenApp/Friends/`, `TweenApp/Sheets/` — project.yml globs recurse, zero config.

### R3 — Phase B: `SearchController` extraction — HIGH risk, HIGH reward, do LAST and alone
Today every regression class this app has fought (poll-clobbers-search, rerank races, stuck spinners) exists because search state (`searchText/searchResults/rankedSpots/searchTask/isSearchLoading/searchState`) lives beside meetup state in one struct, and 15+ call sites can touch both. The fix is ownership, not location: an `@Observable final class SearchController` owning that state + `runSearch/rerankCurrentResults/resolvePlace/resolveCategory/clearSearch`, injected into OnboardingView as one `@State private var search = SearchController()`.
- The poll physically CANNOT clear `rankedSpots` anymore — `refreshFromAppGroup` doesn't hold the reference; it calls an explicit, documented `search.meetupDidTearDown()` on the one transition that legitimately resets ranking. The `shouldResetRankingOnLeave` bug class dies structurally.
- Risks: `@State` → observable-class migration changes invalidation timing (SwiftUI re-render granularity), the cancellable-task ownership moves, and DEMO seeds/harness args that reach into search state all need rewiring. This is the one step needing the full device-feedback regression pass (search → rank → add point → leave → search again) on top of the suite.
- Do NOT start R3 until R2 lands and a TestFlight cycle passes on it.

### R4 — the interactive-map decision (blocks ~200-line deletion in ExpandedView.swift)
`usesStaticMapForCurrentState` is hardcoded `true`, so the sanctioned pan/zoom Map is unreachable. Two honest options: **(a) delete** — snapshotter-only everywhere, CLAUDE.md constraint 1's exception paragraph gets removed, ~200 lines + the `mapDegraded` fallback machinery go; **(b) resurrect** — flip the flag to a real condition, then on-device memory profiling is MANDATORY (the ~120 MB ceiling is the app's hardest constraint and simulator numbers don't count). Recommendation: (a) delete now — nobody has missed it, users pan the HOST app's map, and git preserves the code if pan/zoom ever becomes a priority. Needs your call.


Scope: file layout, file lengths, and a concrete split plan. Correctness findings live in `report_audit.md`; this report is structure only.

## The numbers

**14,051 production lines · 36 production files. The top 3 files hold 7,989 lines — 57% of the codebase.**

| File | Lines | Verdict |
|---|---|---|
| `TweenApp/OnboardingView.swift` | **4,291** | 🔴 God file — 30% of the whole codebase; 213 `private` decls, `body` alone is 309 lines |
| `Shared/TweenViews.swift` | **1,998** | 🔴 Five unrelated top-level types in one file |
| `TweenMessages/MessagesViewController.swift` | **1,700** | 🔴 One class; its Sending section alone is ~780 lines |
| `TweenAppTests/ParticipantCodecTests.swift` | 932 | 🟡 Test file — tolerable, split optional |
| `TweenApp/SpotDetailCard.swift` | 559 | 🟡 Borderline; fine for now |
| `Shared/ConversationMeetupStore.swift` | 492 | 🟢 Cohesive (one store) |
| everything else | ≤ 449 | 🟢 Healthy — the tail is well-factored |

Directory totals: `TweenApp` 6,701 / `Shared` 5,335 / `TweenMessages` 2,015 / tests 2,676. The *directory* layout is sound (Shared dual-target pattern works); the problem is concentration inside three files.

**Why it matters here specifically:** every recent regression cycle touched one of these three files, and the audits repeatedly hit the "fix one site, miss the sibling" pattern — siblings are hard to see when a file is 4,000 lines. Compile times and merge conflicts concentrate there too.

## Misplaced types (free wins, move-only)

| Type | Lives in | Should live in |
|---|---|---|
| `MapGeometry` + `MapMarker` + `formatETA()` | `Shared/TweenViews.swift` | `Shared/MapGeometry.swift` |
| `SearchResultMerger` | `Shared/FairnessRanker.swift` | `Shared/SearchResultMerger.swift` |
| `UserProfile` | `Shared/OnboardingFlags.swift` | `Shared/UserProfile.swift` (or rename file `AppGroupFlags.swift`) |
| `TweenSheetSurface`/`TweenCardSurface`/`TweenGlassControl` | top of `OnboardingView.swift` | `TweenApp/TweenSurfaces.swift` |
| `AddPointSheet` | bottom of `OnboardingView.swift` | `TweenApp/AddPointSheet.swift` |

## Dead code to DELETE before splitting (~355 lines, from prior correctness audits)

- Interactive-map members behind the hardcoded `usesStaticMapForCurrentState = true`: `interactiveMap`, `cameraBounds`, `spotPin`, `mapPosition`, `allMeetupCoords` (~200 lines, `TweenViews.swift`) — needs the pending product decision (delete vs resurrect); deleting also removes two dead best-ref threading sites.
- `ETAChip`, `RankedResultRow`, `ResultRow` (preview-only, ~90 lines, `ResultRows.swift`).
- `insertBubble(for:dismissAfterInsert:)` + deprecated `BubbleImageRenderer.makeImage(selfCoord:peerCoord:)` (~40 lines).
- `LocationProvider.requestOnceIfAuthorized()`, `UserName.clear()`, `OnboardingView.midpoint(_:_:)` (~25 lines).

## Split plans (in execution order — safest first)

### 1. `Shared/TweenViews.swift` 1,998 → 4 files *(zero-risk: cuts along top-level type boundaries, no access-level changes)*

| New file | Contents | ~Lines |
|---|---|---|
| `Shared/MapGeometry.swift` | `MapMarker`, `MapGeometry`, `formatETA` | 75 |
| `Shared/TweenMapSnapshotView.swift` | the snapshotter view + cache | 245 |
| `Shared/CompactView.swift` | `CompactView` | 385 |
| `Shared/ExpandedView.swift` | `ExpandedView` | 1,295 |

All stay in `Shared/` (dual-target glob). `private` members never cross type boundaries here, so nothing changes but file paths.
*Optional phase 2:* split `ExpandedView` by its MARKs into `ExpandedView+SpotCards` (~160), `+Invitation` (~130), `+Map` (~185), `+SpotList` (~185) — this DOES require demoting cross-file `private` members to internal; do it only if ExpandedView keeps growing.

### 2. `TweenMessages/MessagesViewController.swift` 1,700 → 5 files *(extension files along existing MARKs)*

| New file | Contents | ~Lines |
|---|---|---|
| `MessagesViewController.swift` (trimmed) | State, Lifecycle, Hosting | 640 |
| `MessagesViewController+Decoding.swift` | Decoding + effectiveReceived | 285 |
| `MessagesViewController+Ranking.swift` | Ranking + search helpers | 150 |
| `MessagesViewController+Sending.swift` | handleImIn/Out, sendChosenSpot/Agreed/Counter/Draft | 450 |
| `MessagesViewController+Delivery.swift` | deliverBubble, recordCanonicalSnapshot, maps opening | 180 |

Members referenced across the new files drop `private` (74 total privates; only the cross-file subset changes). Exposure is contained — the extension target has just two files today.
**Testability bonus:** while moving, extract the PURE parts of `effectiveReceived` (sticky-agreement decision) and `snapshotHint` into `Shared/` enums — the #1 test-coverage gap is that no test can reach extension logic; pure Shared helpers fix that without a test-host target.

### 3. `TweenApp/OnboardingView.swift` 4,291 → ~9 files *(the big one — staged)*

**Phase A — mechanical moves (one commit per file, no logic edits):**

| New file | Contents (existing MARK spans) | ~Lines |
|---|---|---|
| `TweenApp/TweenSurfaces.swift` | 3 ViewModifiers (lines 1–84) | 85 |
| `TweenApp/AddPointSheet.swift` | the sheet struct (4,219–4,291) | 75 |
| `OnboardingView+FriendsPanel.swift` | "Friends panel" + "Friends" MARKs | 1,070 |
| `OnboardingView+Search.swift` | "Search" MARK (runSearch, resolvePlace/Category, canSearch…) | 400 |
| `OnboardingView+Sync.swift` | "Peer polling" MARK (refreshFromAppGroup, pollPeer) | 260 |
| `OnboardingView+Framing.swift` | "Geometry" MARK framers/cameras | 300 |
| `OnboardingView+DeepLinks.swift` | handleIncomingURL + openGoogleMapsExternally | 220 |
| `OnboardingView+HandOff.swift` | "Hand-off" MARK (sendToChat, compose sheets) | 240 |
| `OnboardingView.swift` (core) | state + enums + `body` + sheet router + bottom sheet + DEBUG seeds | ~1,000 |

Cross-file members demote `private` → internal (default). That's the honest cost of extension-based splitting in Swift; it's module-internal only.

**Phase B — real decomposition (separate effort, after A settles):**
- Extract a `SearchController` (`@Observable`) owning `searchText/searchResults/rankedSpots/searchTask` + the search funcs — this structurally kills the "poll clobbers search state" bug class the hard way (the poll code physically can't touch search state).
- Extract `BottomSheetView` and the map layer from `body` (309 lines → ~100).
- Candidates only after A proves stable; each changes ownership semantics (`@State` → model object) and needs the full device-feedback regression pass.

## Rules for the whole effort

1. **One move per commit**, `xcodegen generate` after each (all targets use directory globs — no project-file editing), full suite green (175 tests) before the next.
2. **Move commits contain zero logic edits** — diffs should be pure relocation + access-level keywords, so review is mechanical.
3. `Shared/` splits stay in `Shared/` (dual-target compilation is path-based).
4. Delete the dead code FIRST — no point relocating ~355 lines that should not exist.
5. Optional: nest subfolders (`TweenApp/Views/`, `TweenApp/Search/`) — the globs recurse, zero config; do it in the same commits as the moves.

## Expected end state

| | Before | After Phase A |
|---|---|---|
| Largest file | 4,291 | ~1,295 (`ExpandedView.swift`) |
| Files > 1,000 lines | 3 | 2 (ExpandedView, FriendsPanel ext) |
| Files > 500 lines | 5 | 5, all cohesive single-concern |
| Top-3 concentration | 57% | ~25% |

Estimated effort: TweenViews split ~30 min · MessagesViewController ~45 min · OnboardingView Phase A ~2 h, all mechanical and individually shippable. Phase B is a separate, riskier project — recommend doing it only per-subsystem as those areas next need feature work.
