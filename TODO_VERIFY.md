# Tween — Verification & Remaining Work (Stage 3 handoff)

Written 2026-07-06. Everything below is **code-complete and committed**; none of it is device-verified. This is the honest "what's actually confirmed vs. what you must build and screenshot" list. No Xcode on the authoring machine — the CLI here builds (`** BUILD SUCCEEDED **`) and runs the 88-test unit suite green, but cannot verify iMessage delivery, App Group cross-process sharing, memory, or on-device UI.

## What's confirmed here
- `xcodebuild build` (app + extension, iOS Simulator) succeeds.
- 88/88 unit tests pass on the iPhone 16 simulator (83 original + 5 added: 4 Participant `matches`, 1 fairness clamp).
- Each fix traced against its BUGREPORT root cause; Batches A & B passed an adversarial sub-agent diff review, Batch C was self-reviewed (the review agent hit a spend limit).

## What Madhav must build + screenshot to CLOSE each bug

Run on **two real devices** (App Group + iMessage delivery are device-only). For each: build both targets, `xcodegen generate` first if project.yml changed (it didn't this pass).

### Delivery & state (the July-5 stack + Batch A)
- [ ] **First-run "I'm in"** (fresh install, delete app first): tap I'm in, read the permission prompt slowly, allow → the bubble should still send on that first tap (T3). If it fails on first tap and works on second, the alert is *resigning* the extension — tell me; that needs a resume-on-activate path (BUGREPORT T3 / review F2, not fixed).
- [ ] **Direct-send rejection → staged fallback**: when a send is rejected (fires often — sends run seconds after the tap), confirm the bubble lands in the input field with "Added to the message box — tap send to deliver.", and that tapping send clears the hint (T13 `didStartSending`).
- [ ] **Rapid I'm in → I'm out**: no false "You're in", no divergence between the two devices.
- [ ] **Counter on a failed send** (T2): counter a proposal; if the send fails/stages then you delete the staged bubble, your local MEETUP SET must NOT have been erased.
- [ ] **Draft hand-off on a failed send** (T2): host app → Send to chat → if the extension send fails, the draft must still be offered (not lost).

### Maps on leave (last session's fixes)
- [ ] **DM leave**: user 1 out → user 1's map empty; user 2 (tap bubble) sees "user 1 left" + only their own pin.
- [ ] **4-person leave**: leaver's map empty; the other three drop only the leaver.
- [ ] **Empty-roster leave**: receiver's compact thumbnail shows NO phantom pin of the person who left (T-leave / dcf6771).

### Group join (Batch B + July-5)
- [ ] **3rd person joins**: tapping an invite that already has 2 people shows the "I'm in" join hero (not a dead spot-list).
- [ ] **Live roster pill** (T11): right after you join, the compact pill shows the correct count *immediately* (not lagging until the peer replies).
- [ ] **Same-name devices** (T16, Bug-#4 family): two devices both named "You" (or duplicate names) — confirm you are not shown "You're in" before joining, and peer pins are correct.

### UI polish (Batch B)
- [ ] **Panel-tab self-jump** (T12): while dragging the sheet / on the waiting tab, have the peer send an agreement — the tab must NOT yank to Map mid-interaction.
- [ ] **Compact height** (review note): with the new launcher status line at large Dynamic Type on a small device (SE), confirm the bottom button row isn't clipped.

### Fairness & bubbles (Batch A)
- [ ] **Hyper-local ranking** (T8): all participants within ~2 min of the spots — confirm real-route spots still rank above straight-line guesses (no inversion).
- [ ] **Offline/slow network bubble** (T9): on a stalled connection, the bubble should fall back to offline art within ~8s instead of spinning forever.

### Sessions (Batch C)
- [ ] **Drawer-opened send** (T15): open Tween from the app drawer (not by tapping a bubble) and send — it should collapse into the existing conversation bubble, not stack a new one.

## Deferred — NOT fixed, need your decision (from BUGREPORT.md)

**Require your sign-off (touch protected core / protocol):**
- **T1 — Old-bubble resurrection**: after leaving, tapping an *older* bubble re-adopts its roster (leaver reappears) until a newer bubble is tapped. Needs a monotonic revision or tombstone in the URL payload — a protocol change. *This is the most user-visible remaining correctness gap.*
- **T4 — `encodedURL` >5000 chars hard-fails**: large groups can't send at all. Fix = drop `pj=` and retry. Touches the TweenState codec.
- **T5/T6 — compact `p=` decode collapses id→name** → mixed id/name consensus can become unreachable. Only bites mixed/legacy builds. Codec + negotiation.
- **T7 — legacy-agree proposer mislabel**: agreeing to a pre-group proposal stamps the wrong proposer. Negotiation flow.
- **T21 — leave clears every receiver's agreed meetup**: if 1 of 4 leaves after agreement, the other 3 lose MEETUP SET locally. May be intended; confirm the product intent.

**Product decision:**
- **T10 — interactive expanded map is dead code** (`usesStaticMapForCurrentState` hardcoded `true`). Re-enabling brings `MKMapView` back under the 120 MB extension ceiling — needs on-device memory profiling before flipping.

**Known platform limits (not bugs):**
- A closed extension only learns of updates when its user taps the bubble (serverless; no push).
- First-run permission alert timing (T3) — see the first checkbox above.

## If a device test fails
Note which checkbox and the observed vs. expected behavior. The BUGREPORT.md at repo root has each bug's file:line and root cause; HANDOFF.md §7-8 has the fix stack and fragile areas.
