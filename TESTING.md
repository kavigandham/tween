# Tween — Manual Test Plan

The device-and-simulator verification plan for the collaborator on a Mac with
Xcode 16+. Automated unit/UI tests run with ⌘U; everything below is the manual
gate that those can't cover (real maps, real iMessage, real devices).

## Setup

```bash
git pull
brew install xcodegen        # first time only
xcodegen generate            # regenerate after every pull
open TweenApp.xcodeproj
```

In Xcode: select an **iPhone 16** simulator unless a step says "physical device."
- ⌘B — build (both `TweenApp` and `TweenMessages` targets must build)
- ⌘U — run the unit + UI test suites (expect all green)

Grant the location permission prompt **While Using the App** the first time it
appears. To re-test the first-run experience, delete the app and reinstall.

---

## Phase 01 — Scaffold & core models
- [ ] `xcodegen generate` succeeds; project opens with all four targets.
- [ ] Both `TweenApp` and `TweenMessages` build with no warnings about missing
      `Shared/` files.
- [ ] ⌘U: unit tests pass (`TweenState` round-trip, `LocationCache` read/write).
- [ ] `TweenState.encodedURL()` produces an `https://tween.app/m?...` URL under
      5000 characters (covered by tests; spot-check in the debugger if curious).

## Phase 02 — Host app map & "I'm in"
- [ ] App launches to the map screen.
- [ ] Tapping **I'm in** triggers the location permission prompt (first run),
      then drops your pin once a fix arrives.
- [ ] Your pin uses the active (checkmark) role after sharing; the map frames it.
- [ ] Force-quit and relaunch within an hour: the cached self coordinate is
      still considered fresh (pin restored, no re-prompt).

## Phase 03 — Search & fairness ranking
- [ ] With a self location set, searching (e.g. "coffee") returns nearby results.
- [ ] Category chips/presets filter the search.
- [ ] When **both** a self and a peer/friend coordinate exist, results are
      ordered by fairness — the spot with the smallest *longer* drive ranks first.
- [ ] A spot whose ETA had to fall back to a straight-line estimate ranks below
      comparable spots with real routes (lower confidence is penalized).
- [ ] Each result row shows the longer drive time in minutes.

## Phase 04 — iMessage extension
- [ ] Open **Messages** → a conversation → the app drawer → **Tween**.
- [ ] **Compact view** appears at keyboard height with **no keyboard / no text
      field / no first responder** (HARD CONSTRAINT 3).
- [ ] Tapping the compact row expands to the full-height view.
- [ ] Expanded view shows a **map snapshot** (never a live `MKMapView`), the
      ranked spot rail, and a primary CTA.
- [ ] Tapping **I'm in** in the extension shares your location.
- [ ] Selecting a spot and sending drops a tappable map **bubble** into the
      thread (rendered by `BubbleImageRenderer`).
- [ ] Memory stays well under the extension ceiling (watch the debug gauge;
      ranking is capped at 5 in the extension).

## Phase 05 — Friends & social
- [ ] Add a friend via the contact picker; the roster persists across relaunch.
- [ ] The ping log records a timestamp when you share/receive; timestamps update.
- [ ] Receiving a shared spot shows the reply banner / received panel.

## Phase 06 — End-to-end flow & onboarding
- [ ] First launch shows the onboarding tutorial; it does not reappear after
      completion (relaunch to confirm).
- [ ] From the host app, **Send to chat** hands a spot off to the extension.
- [ ] The extension shows the handed-off **draft panel** ("Ready to send"); the
      CTA reads **Send <spot name>** and posts the bubble.
- [ ] A received spot can be countered with a different spot.

## Phase 07 — Design polish, animations, accessibility
- [ ] All colors/spacing/typography come from `Tokens` — no stray hard-coded
      hex values; brand navy (#123252 light / #2D618E dark) tints system controls.
- [ ] Pins for self-active and midpoint **pulse**; selection/send fire haptics.
- [ ] VoiceOver: every pin, spot chip, and CTA has a sensible label and hint;
      pin roles are distinguishable by **glyph**, not color alone.
- [ ] Dynamic Type: text scales without clipping the compact row or CTA.
- [ ] Offline (toggle airplane mode): the expanded view shows the offline banner
      instead of a stale ranking.

## Phase 08 — Tests, privacy, TestFlight prep
- [ ] ⌘U: full unit + UI suite passes (30+ tests, incl. `testHarnessLaunch`
      and `testLaunchScreenshot`).
- [ ] Launch the host app with the `-HARNESS` argument (Edit Scheme → Run →
      Arguments → add `-HARNESS`). The harness renders both **Compact View** and
      **Expanded View** with seeded SF + San Jose data.
- [ ] `PrivacyInfo.xcprivacy` is bundled in **both** the app and the extension
      (check the built `.app` / `.appex` resources).
- [ ] A **Release** build succeeds (Product → Scheme → Edit → Run → Release, or
      Archive). Confirm `HarnessView`, the `-HARNESS` check, and the test-only
      `RankedSpot` init are excluded (DEBUG-gated) — Release archive builds clean.
- [ ] App icon: run `python3 scripts/generate_icon.py`, drop the PNG into the
      asset catalog (or use final artwork).
- [ ] `metadata/` files match what you enter in App Store Connect.

---

## Final gate — Two physical iPhones (required before TestFlight)
Simulators cannot reliably send `MSMessage` payloads; this must run on hardware.

1. Install Tween on **both** phones via Xcode (Run on device).
2. Open an iMessage thread between the two phones.
3. **Person A:** Tween in the app drawer → **I'm in**.
4. **Person B:** receives the bubble → tap → **I'm in**.
5. Both see the ranked fair spots.
6. **Person A:** picks a spot → sends the bubble.
7. **Person B:** receives it and can counter with a different spot.
8. Confirm no crash on `willResignActive` (background/foreground each phone mid-flow).

## Reporting issues
For any failure note: the phase, whether it's a **compile error / runtime crash
/ test failure**, and the exact message (screenshot or build-log copy). The dev
can resume from a phase with `./orchestrator.sh <phase-name>`.
