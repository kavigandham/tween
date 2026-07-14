# STRUCTURE AUDIT — Tween — 2026-07-13 (HEAD 6853735)

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
