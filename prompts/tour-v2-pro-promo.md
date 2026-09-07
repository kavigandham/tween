# Tween — Tour v2 (fake friend + iMessage step) and Pro promotion

Implementation brief. Written 2026-09-06 against `main` at `6f4b671` (the
interactive coach-mark tour). Read `CLAUDE.md` first: its hard constraints
apply to everything below, especially #6 (App Group holds coordinates and
preferences only) and the manual-participant isolation invariant (locally
added points are never broadcast in any payload).

Deliver as three separate commits in this order, each verified on the
simulator before the next: (1) fake friend in the tour, (2) the iMessage
step, (3) Pro promotion. Push after each; the post-push audit runs.

---

## 1. The tour demonstrates the real thing: a fake friend ~20 minutes away

**Problem.** Today the tour's Coffee step searches around the user alone, so
the user never sees what Tween is for: two people, a midpoint, and spots
ranked by *both* travel times. The tour must show that.

**What to build.**

- When the tour reaches the join step (`TourStep.imIn`) and the user's
  coordinate is known — or immediately after the first live fix lands if it
  isn't yet — seed ONE tour-only participant named **"Sam (demo)"** about 20
  minutes' drive from the user. Use `Participant.manual(label:coordinate:)`
  (`Shared/Participant.swift:46`) and append it to `manualParticipants`.
  That array is the sanctioned local-only channel: `refreshFromAppGroup`
  never touches it and no send path reads it (see
  `proposalParticipantsForCurrentContext` in `OnboardingView+HandOff.swift`),
  so the fake friend can never ride into a bubble. Do NOT write it to
  `LocationCache`, `ConversationMeetupStore`, or `FriendRoster`.
- Placement: ~20 min driving ≈ `20 * 60 * TravelMode.driving.fallbackMetresPerSecond`
  metres (`Shared/MeetupPlan.swift`, 11.5 m/s → ~13.8 km) at a fixed bearing
  (pick 45°, north-east) from the user's coordinate. Pure function
  `Self.demoFriendCoordinate(from:)` in `OnboardingView+Tour.swift`, unit
  tested (distance within ±5 %, bearing correct). If the user has no fix at
  all (denied, simulator), fall back to placing the friend relative to the
  map's current centre so the demo still renders — the tour must never
  stall on location.
- The friend must show on the map as a friend pin (`TweenPin(role: .friend,
  initials: "S")`) — `mapLayer` already draws `manualParticipants`. The
  group status bar then lists "You" and "Sam (demo)"; that is the point.
- Update the tour copy so the demo is honest:
  - Step 2 (I'm in) body: add "We'll add a demo friend, Sam, about 20
    minutes away so you can see how fair spots work."
  - Step 3 (Coffee) body: "Tap Coffee. Tween searches between you and Sam
    and ranks places by how far each of you travels." The spotlit result
    card now shows "You N min · Sam (demo) M min" — call that out in the
    step-4 copy ("Each card shows everyone's time").
- Teardown: on Finish AND on Skip, remove the demo participant
  (`removeManualPoint`) so it never outlives the tour. Also remove it if the
  user leaves the app mid-tour (`scenePhase` → background) — a demo friend
  must not be sitting in the ranking when they come back an hour later. If
  a real search is on screen when the friend is removed, re-rank
  (`rerankCurrentResults`, which `removeManualPoint` already does).
- Restarting the tour from the menu with a real meetup in progress
  (`isUserIn` with a real peer): do NOT add the demo friend — the real
  friend is a better demo. Gate on `peerCoordinate == nil &&
  additionalParticipants.isEmpty`.

**Verify.** Simulator: reset `tween.onboarding.hasSeen` (recipe in the
memory note `tween-interactive-tour`), launch with `-DEMO_WHERE_ILL_BE`,
run the tour; screenshot the Coffee results with both times on the cards
and the "Sam (demo)" row in the group bar. Then Skip mid-tour and confirm
the pin and the row are gone. Unit test for the coordinate function.

---

## 2. A step that shows the iMessage side and explains the auto-sync

**Problem.** The tour never shows what happens after Send, and new users do
not know the two sides talk to each other automatically.

**What to build.**

- Insert a new step after "Open a spot" (before Friends): **"Send it to the
  chat"**. It is informational (Next button) — do NOT make the user actually
  send during the tour. The card contains an illustration ABOVE the copy:
  a phone-shaped frame showing an iMessage thread with the Tween bubble
  ("Let's meet at Coffeebar" with the map thumbnail) and the friend's
  "Agreed ✓" reply beneath it. Build it as vectors, not a bitmap: reuse
  and extend `MessageBubble` / `MiniMap` from
  `TweenApp/OnboardingTutorial.swift` (currently `private`; lift them into a
  small shared file, e.g. `TweenApp/TutorialVisuals.swift`). The exported
  App Store screenshots in `docs/appstore/upload-set/01-chat.png` and
  `08-imessage.png` are the reference for what the bubble looks like; do
  not embed them (asset weight, and they go stale with every UI change).
- Copy (keep this tone): title "Send it to the chat"; body "Send drops the
  spot into your iMessage. Your friend taps Agree or suggests somewhere
  else, and both of your apps update on their own — no accounts, nothing to
  sign up for. You can also plan straight from the + in any chat."
- The card is taller than the others: make `CoachMarkOverlay`'s callout
  accept an optional `illustration: AnyView?`/`some View` per step, laid out
  above the title with a fixed aspect ratio, and confirm it fits above the
  sheet at the half detent on the smallest supported iPhone (iPhone SE 3rd
  gen at 375×667 pt — test with `-only-testing` on that simulator, or the
  iPhone 17e as the smallest available in this Xcode). If it does not fit,
  the step must raise the sheet to peek first (`setTourStep` already does
  detent choreography).
- Renumber: the tour becomes 8 steps. `TourStep.count` is derived, so only
  the copy "N of 8" changes automatically — check nothing hard-codes 7.

**Verify.** Screenshot of the step on the iPhone 17 Pro and the smallest
simulator in light and dark mode (the tour dims both; the illustration must
read in both). VoiceOver: the illustration gets a one-line
`accessibilityLabel` ("An iMessage conversation showing a Tween spot and a
friend agreeing").

---

## 3. Pro promotion: it exists, nobody sees it

**Problem.** Tween Pro (`Shared/ProEntitlement.swift`: lifetime
`com.kavigandham.TweenApp.pro.lifetime`, monthly `…pro.monthly`) is gated
behind features people only discover by accident: groups, saved home
bases, per-person travel modes, and Plan (arrival time, calendar). The
paywall (`TweenApp/PaywallSheet.swift`) is reached only from those gates
and Settings. Nothing ever *introduces* it.

**What to build — three surfaces, one shared frequency cap.**

1. **Tour step 8, "Tween Pro" (before "You're set").** Informational card
   with a 3-line feature list (Groups · Saved places · Plan ahead) and two
   buttons: "See Tween Pro" (opens `PaywallSheet` via the Friends child
   sheet route the code already uses — `activeSheet = .friends;
   friendsSubSheet = .paywall` is the pattern at
   `OnboardingView+GroupBar.swift:131`, but present it through
   `pendingFriendSheetAction` so it survives the iOS 26 item-swap drop) and
   "Not now" (advances). Skip is still there. If Pro is already unlocked
   (`ProEntitlement.isUnlocked`), omit the step entirely.
2. **Contextual nudge sheet (the "pop up").** A compact, dismissible
   half-height sheet — NOT an alert — shown at most ONCE PER 7 DAYS and never
   twice for the same trigger, on these moments:
   - the first time a search returns with 3+ participants on screen
     (real peers + manual points): "Meeting as a group? Pro saves this
     group so next time is one tap."
   - the first time the user opens a place sheet with a real peer in the
     meetup (not the demo friend): "Want to lock in a time? Pro adds
     arrival times and calendar invites."
   - the third completed meetup (an agreed meetup written to
     `LocationCache.saveAgreedMeetup`, counted in a new App Group flag):
     "You've planned three meetups. Pro is one-time $9.99 or $1.99/month."
   Each nudge has "See Pro" and "Not now". Tapping "Not now" twice on the
   same trigger retires that trigger permanently.
3. **A quiet, persistent affordance:** a small "Pro" pill in the map
   options menu (the ⋯ menu in `OnboardingView+BottomSheet.swift`) and a
   "Tween Pro" row at the top of the Friends sheet when locked. No badge on
   the tab, no red dots.

**Frequency and storage.** One new App Group key,
`tween.pro.nudges` — a JSON blob `{lastShownAt: Date, shownTriggers:
[String], dismissedCounts: [String: Int], completedMeetups: Int}` written
atomically like every other store (single key, `LocationCache.sharedDefaults`,
post `MeetupSync` is NOT needed — the extension never reads it). This is a
preference blob, within constraint #6. A pure `ProNudgePolicy.shouldShow(
trigger:state:now:)` decides, unit tested for: the 7-day cap, per-trigger
once, two dismissals retire, and Pro-unlocked never shows.

**Do not do:** no nudge during the tour other than step 8; no nudge while
a secondary sheet is up or a send is in flight; no nudge in the Messages
extension (memory ceiling, and App Review dislikes upsells in the drawer);
no countdown timers, fake discounts, or "last chance" copy — App Review
guideline 3.1.2 already required the EULA link once; keep the paywall the
only place that states prices, except the third-meetup nudge above.

**Verify.** Unit tests for `ProNudgePolicy`. Simulator with
`-DEMO_PRO_LOCKED`: run the tour to step 8, tap "See Tween Pro", confirm
the paywall presents and dismisses back to the tour's final card. Run
`-DEMO_GROUPS -DEMO_PRO_LOCKED`, open the group, search, and confirm the
group nudge appears once and not again on a second search. With
`-DEMO_PRO_UNLOCKED`, confirm no step 8 and no nudges anywhere.

---

## Definition of done (all three)

- Unit suite green except the two known StoreKit tests (`ProEntitlementTests`
  lifetime/monthly fail in this simulator on every tree).
- `xcodegen generate` re-run and `TweenApp.xcodeproj` committed if files
  were added.
- Every visual verified on the simulator in light and dark; the tour and
  the nudges verified once on a real phone before the TestFlight build is
  called done — the keyboard and the location prompt behave differently
  there.
- No new PII in the App Group; the demo friend never appears in
  `tween.cache.participants` or any `conversationMeetup.*` key (check the
  plist after a tour run).
