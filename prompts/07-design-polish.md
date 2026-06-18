# Phase 07: Design System + Polish

## Prior State
- Phase 06 complete. All features built. 25 tests written. Styling is ad-hoc throughout.
- No Xcode — do NOT run build tools. Read CLAUDE.md.

## Objective
Create `Tokens.swift` as the single source of truth for all visual design, apply it everywhere, add animations/haptics, and do a full accessibility pass.

## Tasks

### 1. Create `Shared/Tokens.swift`
Complete design system with:

**Palette:** surface, surfaceSecondary, brand (deep teal #008C8C), brandLight, pinSelf (blue), pinSelfActive (green), pinFriend (orange), pinMidpoint (brand), textPrimary/Secondary/Tertiary (semantic label colors), destructive, success, warning, fairnessGood/Okay/Poor.

**Spacing:** s0–s9 on 4pt grid (0, 4, 8, 12, 16, 20, 24, 32, 40, 56).

**Radius:** chip (8), card (12), sheet (24), pin (22), pill (.infinity).

**Typography:** Semantic ramp using `Font.system(.style)` — display, title, headline, body, callout, caption, captionBold. All scale with Dynamic Type.

**Motion:** snappy (0.40s easeInOut), spring (0.48s bounce 0.12), gentle (0.66s easeInOut).

**Elevation:** Shadow struct + floating/sheet/pin presets.

**View modifiers:** `.tweenGlass()` (ultraThinMaterial + card radius), `.tweenElevation()`, `.tweenPressFeedback()` (scale to 0.96 on press).

**Button styles:** `TweenPrimaryButtonStyle` with `.prominent` (filled brand) and `.subtle` (tinted) variants. Capsule shape, press feedback.

### 2. Full codebase sweep
Replace in every Swift file:
- Raw `Color(...)` → `Tokens.Palette.*`
- Raw `.font(.system(size:))` → `Tokens.Typography.*`
- Raw `.padding(NUMBER)` → `Tokens.Spacing.*`
- Raw `.cornerRadius(NUMBER)` → `Tokens.Radius.*`
- Raw `.animation(...)` → `Tokens.Motion.*`
- Raw shadow → `.tweenElevation()`
- Raw button styling → `.buttonStyle(.tweenPrimary(...))`

Files to sweep: OnboardingView, TweenViews (Compact/Expanded), TweenPin, BubbleImageRenderer (UIColor equivalents), all result row / chip / detail views.

### 3. Animations
- "I'm in" icon: `.contentTransition(.symbolEffect(.replace))` + `.sensoryFeedback(.success)`
- Result → detail: `matchedGeometryEffect` morph with `Tokens.Motion.spring` (if feasible, otherwise `.transition(.move(edge: .bottom))`)
- Category chips: `.sensoryFeedback(.selection)`
- Pin appearance: `.transition(.scale.combined(with: .opacity))`
- Send CTA: `.sensoryFeedback(.impact)`

### 4. Symbol effects
- Active self pin: `.symbolEffect(.pulse, isActive: true)`
- Midpoint pin: `.symbolEffect(.pulse, isActive: true)`
- "I'm in" icon: `.symbolEffect(.bounce, value: isUserIn)`

### 5. Accessibility pass
Every interactive element gets `accessibilityLabel` + `accessibilityHint`:
- "I'm in" button, category chips, result rows, ETA chips, friend rows, map pins, tab toggle, send CTA, detail card actions.
- Verify colors aren't the sole differentiator (pins have distinct icons).

### 6. Dark mode
Verify all Palette colors work in both modes. System colors (`.label`, `.systemBackground`) adapt automatically. Check custom RGB colors and provide dark variants if needed.

## Acceptance Criteria
- [ ] `Shared/Tokens.swift` exists with Palette, Spacing, Radius, Typography, Motion, Elevation
- [ ] Zero raw Color values outside Tokens.Palette definitions
- [ ] Zero raw font sizes outside Tokens.Typography
- [ ] Zero raw padding outside Tokens.Spacing
- [ ] Every interactive element has accessibilityLabel + accessibilityHint
- [ ] All 25 tests unchanged
- [ ] No build tool invocations

## Constraints
- Zero behavior changes. Zero new features.
- Do NOT modify test files
- BubbleImageRenderer uses UIKit — use UIColor equivalents there
- Do NOT run any build tools
- Commit with message: "polish: phase 07 — design tokens, animations, haptics, and accessibility"
