# AUDIT + EXTENSION UI REDESIGN PLAN — Tween — 2026-07-11 (HEAD `22fda2e`)

Driven by device feedback from the two-phone runs. Read-only audit: every claim below was verified against source at `22fda2e` with file:line evidence. Part 3 is written as executable phase-prompts — run them as **"do Phase A/B/C of report_audit.md"**.

The feedback, verbatim themes:
1. *"Groups of 2+ don't show distance per person in the app, only 2 people (but the extension does)."*
2. *"If someone doesn't name themselves it just says You."*
3. *"No more midpoint star please."*
4. *"Extension is beyond clunky… cramped and ugly… mock up a new extension UI… map is compact and all, show everyone distance/time."*
5. *"Fix the size of the icons on map — in the extension with the small map it gets so cluttered with big icons."*

---

## PART 1 — AUDIT: root causes, verified

### F1 — Host app caps drive times at 2 people · MAJOR
The ranking pipeline already computes **N-person ETAs with names** (`OnboardingView.swift:2893-2904` builds the full participant list → `FairnessRanker.rank` fills `RankedSpot.etas` per participant, `FairnessRanker.swift:154-181`). The gap is 100% render-side — four host surfaces still read the legacy 2-person accessors:

| Surface | Site | Today |
|---|---|---|
| Result list row | `ResultRows.swift:168` | `ETAChip(etaFromA:etaFromB:)` — hardcoded A/B pill |
| Result card | `ResultRows.swift:246` | same chip |
| Place-sheet header | `SpotDetailCard.swift:287` | same chip |
| Directions tile | `SpotDetailCard.swift:342` | shows **only your** time (`etaFromA`) |

The extension already owns the N-aware donors to reuse: `etaChipItems` (`TweenViews.swift:1604`), `driveBalanceStrip` (`:1637`), `compactETALabel` (`:1293`).

### F2 — Unnamed users broadcast as "You" · MAJOR
`UserName.fallback == "You"` (`UserName.swift:33`) is **encoded into payload rosters**, not just rendered locally: every extension send path names the local participant `Self.localParticipantName()` = `displayName ?? "You"` (`MessagesViewController.swift:498`, used at `:610, :625, :818, :1110`), and ~16 host compose paths do the same (`OnboardingView.swift:1805…3497`). Every peer device then renders that person as literally "You" in ETA chips, roster avatars ("Y"), readiness chips, and bubble captions ("You is in!").
**Bonus bug found while tracing:** `OnboardingView.swift:1261` and `:1408` decide `isLocal` by raw string compare against `displayName ?? "You"` — so a **remote** participant named "You" is misclassified as the local user on other devices (the identity-matching hardening from July 6 used IDs; these two sites regressed to names).

### F3 — Midpoint star · remove 3 render sites, keep the math
**Remove (visible star):**
- `OnboardingView.swift:510-513` — host map `Annotation("Midpoint", …) { TweenPin(role: .midpoint) }`
- `TweenViews.swift:1161` — extension static-snapshot marker (centroid pin)
- `TweenViews.swift:1210-1211` — interactive-map annotation (dead code behind the static-only switch; delete anyway)
- Cleanup: `.midpoint` role + glyph + a11y label + diameter arm (`TweenPin.swift:22, 33, 46, 60, 68, 124`), `pinMidpoint` tokens (`Tokens.swift:61, 88`), any Role tests referencing it, and the `midpoint` computed property (`OnboardingView.swift:3182-3188`) **if** its only consumer is the annotation.
**Keep (invisible math — search centering depends on it):** `MapGeometry.centroid/midpoint` (`TweenViews.swift:22-39`), ranking search center (`MessagesViewController.swift:763`), host search-region bias (`OnboardingView.swift:2724-2729`). Tutorial copy "Coffee near the midpoint" (`OnboardingView.swift:107`) can stay — it describes the search, not the pin.

### F4 — Extension "cramped and ugly" · quantified
`ExpandedView` (`TweenViews.swift:806-836`) stacks up to **five chrome bands** around two content zones: offline banner (~48pt) + status banner (~48pt) + `meetupStatusCard` (~120pt: eyebrow/title/subtitle/readiness chips) + a hardcoded **60/40 map/list split** (`:825-827`) + CTA footer (~88pt: `primaryCTA` + `bottomAction`). On a smaller phone that's ~300pt of chrome before content. The chrome also **repeats itself** — status card says "Ready to pick a spot", the CTA says "Pick a spot to send", the list implies the same. Per-person visibility degrades exactly where groups need it: names collapse to "Best/Typical/Long" at 4+ (`:1604-1617`) and pins collapse to "N people · X spread" at 3+ (`:1301`). 16 distinct UI states inventoried (invite hero, meetup-set hero, propose/counter/partial-agree ×2, place ×2, draft, ranking, waiting-coords, offline, leave, launcher, no-coords invite, agreed-place) — the redesign matrix in Part 2 covers all of them.

### F5 — Pins too big for the small map · confirmed
`TweenPin` role sizes: avatars 38pt (+2.5pt stroke, 17pt ride badge), spot pins 42pt, midpoint 28 (`TweenPin.swift:64-73, 156-180`); snapshot markers draw at a flat 0.7× with a 1.6× halo (`TweenViews.swift:293-306`). There is **no context-aware scale** — the extension's ~60%-height static map draws host-sized furniture, hence the clutter.

### Constraints that bind any fix (do not violate)
- Extension map stays **static-only** (`usesStaticMapForCurrentState = true`, `TweenViews.swift:1254` — deliberate T10 memory decision; the redesign must work with `MKMapSnapshotter` snapshots).
- ~120 MB extension ceiling; compact view = keyboard height, no first responder; negotiation core (`decodeAndCache`/`effectiveReceived`/revision-tombstone sync) untouched.
- 20 UI-test strings + HarnessView scenarios pin current copy ("Agree", "Change", "Finding fair spots...", "It's a plan", "Waiting for someone else", "Browse spots", "Open directions or keep browsing.", "Send McDonald's instead", harness section names…) — any phase that changes copy/layout updates `TweenAppUITests` + `HarnessView` **in the same commit**.
- Keep: `formatETA`, `MapGeometry.region`, snapshot caching/retry/timeout in `TweenMapSnapshotView`, `Tokens` spacing/type/motion, `statusIsError` banner channel.

---

## PART 2 — EXTENSION REDESIGN SPEC

Design language (from the repo's `apple-design` skill): full-bleed content with translucent floating chrome instead of stacked opaque bands; one primary action per state; simplicity ≠ minimalism — show the common path, tuck the rest one level down; springs (`Tokens.Motion`) + touch-down feedback (`tweenPressFeedback`); Dynamic Type and reduce-motion/transparency respected.

### The shape: one map, one panel

Today: `[banner][banner][status card][map 60%][list 40%][CTA][CTA]` — five seams.
New: **map is the canvas; everything else floats on it in exactly two layers.**

```
┌─────────────────────────────────────┐
│ ◦ status pill (slim, material)      │   ← replaces offline+status banners AND
│                                     │     the 120pt status card: one line,
│                                     │     "Sam picked Blue Bottle" / "You're
│              MAP                    │     offline" (error tint via statusIsError)
│         (full bleed,                │
│        static snapshot,             │   ← pins at compact scale (below);
│         compact pins)               │     NO midpoint star
│                                     │
│  ┌───────────────────────────────┐  │
│  │ ●●●○  Sam, Maya, Alex +1     │  │   ← roster strip: avatar dots + names,
│  │───────────────────────────────│  │     replaces readiness chips
│  │ ◂ ┌─────────┐ ┌─────────┐ ▸  │  │
│  │   │Blue Bottl│ │Joe’s Chik│   │  │   ← horizontally scrolling SPOT CARDS
│  │   │ ★ fair   │ │          │   │  │     (replaces the vertical 40% list —
│  │   │ You  8m  │ │ You  6m  │   │  │     horizontal reads better in a short
│  │   │ Sam 12m  │ │ Sam 15m  │   │  │     canvas; snap paging, selection
│  │   │ Maya 10m │ │ Maya 11m │   │  │     re-focuses the snapshot)
│  │   │ +1 ▾ 4m ⇄│ │ +1 ▾ 9m ⇄│   │  │   ← EVERY person listed: initial-dot +
│  │   └─────────┘ └─────────┘    │  │     name + time, 3 visible + "+N ▾"
│  │───────────────────────────────│  │     expands; spread "⇄ 4m" is a chip,
│  │      [ Send Blue Bottle ]     │  │     never a REPLACEMENT for names
│  └───────────────────────────────┘  │   ← ONE contextual CTA (state-driven);
└─────────────────────────────────────┘     secondary action lives as a text
                                             button inside the panel header
```

- **The panel** is one `.regularMaterial` surface (bottom-anchored, `Tokens.Radius.sheet` top corners) with three fixed zones: roster strip · card rail · CTA. It absorbs the status card, the list, `primaryCTA`, and `bottomAction`. Vertical budget ≈ 44 (roster) + ~148 (cards) + 56 (CTA) + paddings ≈ **270pt of panel over ~100% map**, vs today's ~300pt chrome + 40% list squeezing a 60% map band.
- **Status pill** top-center over the map: one line, info vs error tint from the existing `statusIsError` channel; offline collapses into it. Disappears when there's nothing to say (most states).
- **Spot cards** (~150×148pt): name + fair badge (replaces the star ranking affordance), then per-person rows — `initial-dot name time` for up to 3, `+N ▾` expands the card taller in place (spring), spread shown as a trailing `⇄ Xm` chip. Card tap = select (snapshot re-focuses via the existing `focusCoordinate` param); CTA becomes "Send <name>".
- **Per-person everywhere:** `etaChipItems` reworked to never drop names (returns all N; the VIEW decides how many rows fit); map pin chips become number-only badges "8·12·15" (or "n people" at 5+) to cut clutter; `driveBalanceStrip` moves inside the expanded card state.
- **Hero states stay heroes:** `invitePromptView` and `meetupSetView` already use the map+sheet shape — restyle to the same panel materials/typography, no structural change. Their CTAs are already singular.
- **CompactView:** structure stays (it was just fixed to fit the keyboard-height budget); adopt the roster avatar strip in place of the count pill and the same card typography. No text input, ever.

### State → panel matrix (all 16 states land in one of 4 panel configurations)

| Panel config | States |
|---|---|
| **Hero** (full-panel variant) | invite prompt · meetup set |
| **Browse** (roster + cards + CTA) | invite-with-coords · propose · counter · partial-agree(needs me: CTA=Agree, secondary=Change) · partial-agree(waiting: pill="Waiting for Maya", CTA=Send change) · place-not-agreed · draft (CTA=Send <draft>) |
| **Waiting** (roster + placeholder rail + CTA) | launcher/no-bubble (CTA=I'm in) · invite-no-coords (CTA=I'm in) · ranking ("Finding fair spots…" shimmer cards) · waiting-for-coordinates · leave ("Sam left" pill) |
| **Terminal-place** (roster + single card + map CTAs) | agreed place (Apple/Google Maps tiles) |
| + status pill overlays | offline · send status/staged/error (any config) |

### Compact pin scale (F5) — `TweenPin.Context`

Add a render context (additive enum, default `.regular` = today's sizes):

| Element | `.regular` (host) | `.compact` (extension map + snapshots) |
|---|---|---|
| Avatar circle | 38pt / 2.5pt stroke | **24pt / 1.5pt stroke** |
| Ride badge | 17pt | 12pt |
| Spot pin | 42pt | **28pt** |
| Result pin | 32pt | 22pt |
| Snapshot halo | 1.6× dot | **none** (flat dot + rim only) |
| Pin ETA chip font | 10pt | 9pt, numbers-only badge |

`drawMarker`/`staticMarkers`/bubble renderer take the context; `BubbleImageRenderer` keeps `.regular` (bubble images are large) — only the in-extension snapshot goes `.compact`.

### Naming fix (F2) — never ship the fallback
1. **Gate the first send on a name** — one-time inline prompt ("What should friends call you?") in the host (name field already exists in onboarding — make it blocking before first compose) and a matching single-field prompt in the extension before the first "I'm in" (pre-filled from `UserProfile.displayName`; note: compact view stays input-free — the prompt lives in the **expanded** flow only, and the extension can also fall back to deferring to the host app via the existing `tween://` hand-off if keyboard-in-extension is deemed risky).
2. **Stop encoding the fallback:** payload composers send the real name or **empty** — never the literal "You".
3. **Receiver-side sanitization** (old bubbles): render empty/literal-"You" peer names as "Friend" + generic avatar glyph (the `TweenPin.initials` path already has a person-glyph fallback).
4. **Fix the two `isLocal` string-compares** (`OnboardingView.swift:1261, :1408`) to identity-based checks (`Participant.matches(LocalParticipantContext)` / `TweenIdentity.stableID`) — a remote "You" must never classify as local.

---

## PART 3 — EXECUTION PHASES (prompt-ready)

### Phase A — correctness, ships independently of the redesign
1. **Host N-person ETAs:** replace the four legacy render sites (`ResultRows.swift:168, 246`; `SpotDetailCard.swift:287, 342`) with an `etas`-driven row component (port `etaChipItems` + `driveBalanceStrip` out of `ExpandedView` into a shared view so host and extension render times identically). Directions tile shows your time + "fair for N" subtitle. Keep the legacy accessors for old call sites until deleted; do NOT touch ranking.
2. **Midpoint star removal:** the 3 render sites + role/token/a11y/tests cleanup per the F3 lists; verify search centering (centroid math) untouched; screenshot host + extension maps.
3. **Name integrity:** the 4-step F2 fix (gate, stop encoding, sanitize, identity-based isLocal). Add tests: payload never contains literal fallback; receiver renders legacy "You" as "Friend"; isLocal via ID.
4. **Compact pin context:** additive `TweenPin.Context` per the F5 table; adopt `.compact` in the extension's `staticMarkers`/`drawMarker` only.
Each item = its own commit; build + full unit suite green per commit (Xcode 26.5); update any pinned test strings touched.

### Phase B — the extension redesign
Rebuild `ExpandedView` to the Part-2 shape: full-bleed `TweenMapSnapshotView` (keep caching/focusCoordinate), status pill, single material panel (roster strip / horizontal snap-paging spot cards with per-person rows and in-place expansion / one contextual CTA), hero states restyled not restructured, CompactView roster strip. Cover every row of the state matrix; update `HarnessView` scenarios + `TweenAppUITests` strings in the same commits; keep `statusIsError`, `formatETA`, `Tokens` as the only styling sources. Static-only map constraint stands (T10) — no `MKMapView`.

### Phase C — polish
Springs (`Tokens.Motion`, damping 1.0 default, ~0.8 only on gesture-momentum), touch-down feedback on every tappable, card-selection snapshot refocus animation, haptics on send/agree only, Dynamic Type pass (panel grows with text, cards wrap), `accessibilityReduceMotion`/`ReduceTransparency` variants, dark-mode contrast re-check with `onBrand`, device screenshots per TESTING.md (2-, 3-, and 5-person groups; the 5-person card expansion; unnamed-user legacy bubble).

### Guardrails (all phases)
Static snapshot only in the extension map (T10 stands) · ~120 MB ceiling (no new live map, no material stacking on material) · compact = keyboard height, zero first responder · negotiation/sync core untouched (`decodeAndCache`, `effectiveReceived`, revision/tombstone/gossip) · `xcodegen generate` after file adds · build + 6/6 UI + full unit suite green before each push · two-device pass before calling any phase done.

### Fix-first order
**A1 (host per-person times)** and **A3 (naming)** are the two user-facing correctness bugs — ship first. **A2 (star)** and **A4 (pin scale)** are quick visual wins. Then **B** lands the redesign in one review-able unit, **C** polishes.
