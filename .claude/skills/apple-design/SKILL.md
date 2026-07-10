---
name: apple-design
description: Apple's fluid-interface design principles (WWDC Designing Fluid Interfaces, Principles of Great Design) — use for ANY UI work in this repo: sheets, gestures, animations, materials, typography, place cards, detents. Examples are web-flavored (source: github.com/emilkowalski/skills); translate to SwiftUI — springs = .spring(response:dampingFraction:), materials = .regularMaterial / glassEffect, drawers = presentationDetents, pointer-down = highlight on touch-down.
---

# Apple Design

How Apple builds interfaces that stop feeling like a computer and start feeling like an extension of you. This knowledge comes from Apple's WWDC design talks — chiefly *Designing Fluid Interfaces* (WWDC 2018) — distilled and translated into the web platform (CSS, Pointer Events, `requestAnimationFrame`, spring libraries like Motion/Framer Motion).

The through-line: **an interface feels alive when motion starts from the current on-screen value, inherits the user's velocity, projects momentum forward, and can be grabbed and reversed at any instant.** Springs are the tool that makes all of this natural, because they are inherently interruptible and velocity-aware.

> SwiftUI translation for this repo: `damping`/`response` map directly to `.spring(response:dampingFraction:)` (Tokens.Motion already defines snappy/gentle/spring). Materials → `.regularMaterial` / `glassEffect` (iOS 26). Drawers → `presentationDetents`. "Respond on pointer-down" → button styles with pressed-state scale (see `tweenPressFeedback`).

## The Core Idea

> "When we align the interface to the way we think and move, something magical happens — it stops feeling like a computer and starts feeling like a seamless extension of us."

An interface is fluid when it behaves like the physical world: things respond instantly, move continuously, carry momentum, resist at boundaries, and can be redirected mid-motion. Everything below is a way to get closer to that.

Apple frames design as serving four human needs: **safety/predictability, understanding, achievement, and joy.** Every rule here serves one of them.

## 1. Response — kill latency

The moment lag appears, the feeling of directness "falls off a cliff." Response is the foundation everything else is built on.

- **Respond on pointer-down, not on release.** Highlight a button the instant it's pressed. Waiting for `click`/touch-up to show feedback feels dead.
- **Be vigilant about every latency.** Audit debounces, artificial timers, transition waits, and the ~300ms tap delay. Anything on the input path that isn't essential is a regression.
- **Feedback must be continuous *during* the interaction, not just at the end.** For a drag, slider, or drawer, update the UI 1:1 with the pointer the whole way through — never animate only when the gesture completes.

```css
/* Feedback lives on the press, and it's instant */
.button:active {
  transform: scale(0.97);
  transition: transform 100ms ease-out;
}
```

## 2. Direct manipulation — 1:1 tracking

> "Touch and content should move together."

When the user drags something, it must stay glued to the finger — and respect the offset from *where they grabbed it*. Snapping to the element's center on grab breaks the illusion immediately.

- Use Pointer Events with `setPointerCapture` so tracking continues even when the pointer leaves the element's bounds.
- Track a short **velocity/position history** (last few `pointermove` events), not just the current point — you'll need velocity at release.

## 3. Interruptibility — the single most important principle

> "The thought and the gesture happen in parallel."

Every animation must be interruptible and redirectable at any moment. A user must be able to grab a moving element mid-flight and reverse it without waiting for the animation to finish. A closing modal the user grabs again should follow the finger — not finish closing first, then reopen.

- **Never lock out input during a transition.**
- **Always animate from the *presentation* (current) value, never the target value.** On interrupt, read the element's live on-screen transform and start the new animation from there. Starting from the logical/target value causes a visible jump.
- **Avoid CSS transitions and `@keyframes` for anything gesture-driven** — they can't be smoothly grabbed and reversed mid-flight. Springs animate from the current value by default, which is exactly what interruption needs.
- **When a gesture reverses, blend velocity — don't hard-cut it.** Replacing one animation with another at a reversal creates a velocity discontinuity, a "brick wall." Spring libraries that carry velocity through a re-target avoid it. (This is what iOS's *additive animations* do natively.)
- **Decompose 2D motion into independent X and Y springs.** A single spring on a 2D distance desyncs when X and Y have different velocities.

## 4. Behavior over animation — use springs

> "Think of animation as a conversation between you and the object, not something prescribed by the interface."

A pre-scripted, fixed-duration animation can't respond to new input. A spring can — new input just changes the target, and the motion stays continuous. Reach for springs for anything a user can touch.

Apple deliberately replaced the physics triplet (mass/stiffness/damping) with two designer-friendly parameters. Think in these:

- **Damping ratio** — controls overshoot. `1.0` = critically damped, no bounce, smooth settle. `< 1.0` = overshoots and oscillates. Lower = bouncier.
- **Response** — how quickly the value reaches the target, in seconds. Lower = snappier. **This is not "duration"** — a spring has no fixed duration; its settle time emerges from the parameters.

**Defaults:**
- Start most UI at **damping `1.0`** (critically damped) — graceful and non-distracting.
- Add bounce (**damping ~`0.8`**) **only when the gesture itself carried momentum** (a flick, a throw, a drag release). Overshoot on a menu that just faded in feels wrong; overshoot on a card you flicked feels right.

**Concrete values Apple ships:**

| Interaction | Damping | Response |
| --- | --- | --- |
| Move / reposition (e.g. PiP) | `1.0` | `0.4` |
| Rotation | `0.8` | `0.4` |
| Drawer / sheet | `0.8` | `0.3` |

## 5. Velocity handoff — the seam between drag and animation

When a gesture ends, the animation must **continue at the finger's exact velocity**, so there's no visible seam between dragging and animating. This is the detail that most separates "fluid" from "fine."

```
relativeVelocity = gestureVelocity / (targetValue − currentValue)
```

## 6. Momentum projection — animate to where the gesture is *going*

> "Take a small input and make a big output."

Don't snap to the nearest boundary from the *release point*. Use velocity to **project the resting position** — exactly like scroll deceleration — then snap to the target nearest that projected point.

```js
// decelerationRate ≈ 0.998 for normal scroll feel; 0.99 for snappier
function project(initialVelocity /* px/s */, decelerationRate = 0.998) {
  return (initialVelocity / 1000) * decelerationRate / (1 - decelerationRate);
}
```

Note: the physics-textbook `v²/(2·decel)` is *not* what Apple ships — use the exponential-decay form above.

## 7. Spatial consistency — symmetric paths, anchored origins

> "If something disappears one way, we expect it to emerge from where it came."

- **Enter and exit along the same path.** A panel that slides in from the right must dismiss to the right.
- **Anchor interactions to their source.** A menu, popover, or sheet should originate from the element that triggered it — set the transform origin to the trigger.
- **Mirror the easing on reversible transitions** so the outbound path matches the return path.

## 8. Hint in the direction of the gesture

Humans predict a final state from a trajectory. Intermediate motion should telegraph where things are going — Control Center modules "grow up and out toward your finger." Make the in-between frames point at the outcome.

## 9. Rubber-banding — soft boundaries

At an edge, resist progressively instead of stopping hard. A hard stop reads as "frozen"; continuous resistance reads as "responsive, but there's nothing more here."

```js
function rubberband(overshoot, dimension, constant = 0.55) {
  return (overshoot * dimension * constant) / (dimension + constant * Math.abs(overshoot));
}
```

## 10. Gesture design details (the "feel" checklist)

- **Tap:** highlight on touch-*down* (instant), commit on touch-*up*. Add ~10px of hysteresis/hit padding, allow cancel-by-dragging-away and back.
- **Drag/swipe:** require a small movement threshold (~10px) before committing to a direction, then track 1:1.
- **Detect all plausible gestures in parallel from the first move**, then confidently cancel the losers once intent is clear.
- **Minimize disambiguation delays.** Double-tap detection unavoidably delays single taps; only pay that cost where double-tap truly exists.

## 11. Frame-level smoothness

- Keep the per-frame positional change below the perception threshold to avoid strobing.
- For very fast motion, a subtle **motion blur / stretch** encodes speed.
- Animate only compositor-friendly properties — `transform` and `opacity`.

## 12. Materials & depth — translucency conveys hierarchy

Apple uses translucent materials as a floating functional layer that brings structure without stealing focus.

- **Build nav/toolbars/sheets as translucent layers** with content scrolling underneath — not opaque bars.
- **Material weight encodes hierarchy:** darker/heavier materials separate structural regions; lighter materials draw attention to interactive elements. **Never stack a light translucent surface on another** — legibility collapses.
- **Bigger surfaces should read as thicker:** stronger blur + a deeper shadow than small chips.
- **Dim to focus, separate to keep flow.** A modal task pairs the surface with a dimming scrim. A parallel, non-blocking panel uses translucency without a scrim.
- **Vibrancy keeps text legible over changing backgrounds.** Over blurred surfaces, use higher-contrast, slightly heavier weight text.
- **Scroll edge effects, not hard dividers.** Fade a small blur/gradient mask where content meets floating chrome.
- **Materialize, don't just fade.** For glass surfaces, animate blur radius and scale together on enter/exit.

## 13. Multimodal feedback — motion + sound + haptics

1. **Causality** — obvious what caused the feedback; trigger on the actual causal event.
2. **Harmony** — visual, sound, haptic on the **same frame**.
3. **Utility** — reserve haptics/sound for meaningful moments (success, error, commit, snap). Over-feedback trains users to ignore all of it.

## 14. Reduced motion & accessibility

- **`prefers-reduced-motion`** — replace slides/springs/parallax with short opacity cross-fades. Drop elastic/overshoot.
- **`prefers-reduced-transparency`** — make translucent surfaces frostier/solid.
- **`prefers-contrast: more`** — near-solid backgrounds with a defined border.
- Avoid full-viewport moving backgrounds, slow looping oscillations, abrupt brightness jumps. (SwiftUI: `@Environment(\.accessibilityReduceMotion)` / `\.accessibilityReduceTransparency`.)

## 15. Typography — optical sizing, tracking, leading

- **Tracking is size-specific.** Large display text wants *negative* tracking; small text slightly *positive*. Tighten headings, leave body near `0`.
- **Leading tracks size inversely.** Tight on large headings, looser on body copy.
- **Build hierarchy from weight + size + leading as a set.** Emphasize with weight.
- **Respect the user's text-size setting** (Dynamic Type). Scale layout *with* the text.
- **Default to the platform's system font.** It ships optical sizing and legibility tuning.

## 16. Design foundations — the eight principles

1. **Purpose.** Make with intention; decide what *not* to build.
2. **Agency.** Keep people in control; easy undo for slips; confirmation only for genuinely destructive actions.
3. **Responsibility.** Act in the user's interest — privacy at the right moment, anticipate misuse.
4. **Familiarity.** Build on what people know; things that look the same must behave the same. Only break a familiar pattern if you can prove it's better.
5. **Flexibility.** Design for contexts, devices, the full range of abilities; let people personalize when no single layout fits.
6. **Simplicity — not minimalism.** Strip the unnecessary so the core purpose shines; show the common path first, advanced options one level deeper.
7. **Craft.** Every spacing, timing, and alignment value is a deliberate choice you can defend.
8. **Delight.** The result of getting the other seven right, not confetti on top.

Tactical rules:
- **Feedback comes in four kinds:** status, completion, warning, error. Validate inline, not on submit.
- **Wayfinding.** Every screen answers: Where am I? Where can I go? What's there? How do I get out? Never trap the user.
- **Grouping & mapping.** Place a control near what it affects. If you need a label to explain a control, the mapping is weak.
- **Direct, specific labels beat safe generic ones.**

## 17. Process

- **Prototype interactively** — an interactive demo is worth "a million static designs."
- **Design interaction and visuals together.** Motion is not a layer added after the pixels.
- **Test with real people in real context**; review motion frame-by-frame.

## Quick Reference

| Need | Technique | Concrete value |
| --- | --- | --- |
| Default UI spring | Critically damped, no overshoot | `damping 1.0`, `response 0.3–0.4` |
| Momentum / flick spring | Under-damped, slight bounce | `damping ~0.8`, `response 0.3–0.4` |
| Gesture → spring velocity | Hand off release velocity | `gestureVelocity / (target − current)` |
| Flick landing point | Project momentum | `current + (v/1000)·d/(1−d)`, `d ≈ 0.998` |
| Interrupt cleanly | Start from presentation (live) value | read the on-screen transform |
| Reversible transition | Mirror the easing curve | inverse control points |
| 1:1 drag | Track with grab offset | respect where they grabbed |
| Feedback | On pointer-down, continuous | never only at the end |
| Boundary | Rubber-band, don't hard-stop | progressive resistance |
| Translucent chrome | Material layer | content scrolls under |
| Type tracking | Size-specific, never fixed | tighten large text (`-0.02em`), body near `0` |
| Reduced motion | Cross-fade, not slide/spring | respect the system setting |
