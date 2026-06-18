# Phase 03: Search + Fairness Ranking

## Prior State
- Phase 02 complete. Host app has OnboardingView with map, "I'm in" flow, TweenPin views, bottom sheet skeleton. 7 tests written.
- No Xcode — do NOT run build tools. Read CLAUDE.md.

## Objective
Add place search with live suggestions, the drive-time fairness ranking engine, result row UI, and category preset chips.

## Tasks

### 1. Create `Shared/FairnessRanker.swift`
`struct RankedSpot: Identifiable` with: `id` (UUID), `item` (MKMapItem), `etaFromA`/`etaFromB` (TimeInterval), `confidence` (Double 0...1). Computed: `worseETA` (max), `fairnessGap` (abs diff), `score` (worseETA - 120 × confidence).

`enum FairnessRanker` with `static func rank(candidates:from:and:cap:) async -> [RankedSpot]`:
- Take first `cap` candidates
- For each: two `MKDirections` requests (from A, from B), automobile transport, concurrently via TaskGroup
- Failed routes: estimate ETA as distance / 13.4 m/s, confidence = 0.5
- Sort by score ascending

Add an `internal` test-only initializer on RankedSpot that accepts raw values without MKMapItem — comment it as `// Test support`.

### 2. Add CategoryPreset enum
Either in OnboardingView or a separate file. Cases: coffee, food, drinks, gas, parks, movies, fitness. Each has a `searchQuery` and `icon` (SF Symbol name).

### 3. Add search state + methods to OnboardingView
**New @State:** `searchText`, `searchResults`, `rankedSpots`, `isSearchActive`, `selectedCategory`, `searchTask`.

**searchPlaces(query:):** Cancel existing task. New task with 300ms debounce (`Task.sleep`). `MKLocalSearch` in the midpoint region (1.6× span if both coords exist). If both coords: rank via FairnessRanker (cap 8). Otherwise: just set searchResults.

**commitSearch():** Calls searchPlaces with current searchText.

### 4. Build search UI in bottom sheet
**Peek (120pt):** Search bar (`TextField`) + horizontal scroll of CategoryPreset capsule chips.
**Medium/Full:** Scrollable result rows below.

### 5. Result row views
**ResultRow:** Icon + spot name (headline) + address (caption).
**ETAChip:** Dual-pill showing "X min | Y min", color-coded by fairness gap (green < 3min, yellow 3–8, orange > 8).
**RankedResultRow:** ResultRow + ETAChip on trailing side.

### 6. FairnessRanker unit tests — `TweenAppTests/FairnessRankerTests.swift`
5 tests using the test-only initializer (no network):
1. worseETA = max(etaA, etaB)
2. fairnessGap = abs(etaA - etaB)
3. score = worseETA - 120 × confidence
4. Lower score ranks first
5. Confidence 0.5 penalizes score vs 1.0

Reset App Group suite in setUp().

## Acceptance Criteria
- [ ] `Shared/FairnessRanker.swift` exists with RankedSpot and rank() method
- [ ] CategoryPreset enum exists with 7 cases
- [ ] OnboardingView updated with search bar, chips, result rows
- [ ] `TweenAppTests/FairnessRankerTests.swift` exists with 5 test methods
- [ ] Total: 12 test methods across test files
- [ ] No build tool invocations

## Constraints
- Do NOT implement spot detail or "Send to chat" — Phase 06
- Do NOT implement friends — Phase 05
- Do NOT add design tokens — Phase 07
- Do NOT run any build tools
- Commit with message: "feat: phase 03 — search + fairness ranking engine"
