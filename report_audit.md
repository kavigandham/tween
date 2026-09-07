# AUDIT REPORT — Tween — 2026-09-06 (tour)

Read-only audit at HEAD `6f4b671` (main). The previous full report (audit at `3759dac` plus the two hardening fixes in `3ee2b2e`) is in git history at `3ee2b2e:report_audit.md`; this pass re-verifies its CRITICAL/MAJOR items and spends its effort on the new first-run tour: `TweenApp/CoachMarks.swift`, `TweenApp/OnboardingView+Tour.swift`, and the wiring in `OnboardingView.swift`, `+BottomSheet`, `+FriendsPanel`, `+HandOff`, `+Actions`, and `project.pbxproj`. No files modified, no builds or tests run. Findings below the 70 % bar were dropped.

**Re-verification of the prior report.** `git diff --stat 3759dac..HEAD` touches only the eight tour files, `ResultRows.swift` (the `soloMode` fix) and the report. No file hosting a prior CRITICAL or MAJOR changed, and the anchors re-grep in place: bare `Int` rev parse and no `pj=` `validCoordinate`; `state.senderName == myName` (`+DeepLinks.swift:58`); unconditional `unlocked = await ProEntitlement.refresh()` (`PaywallSheet.swift:83, 99`); no `setPeerActive(false)` in the switch block; `fallbackSpeed = 13.4` (`FairnessRanker.swift:137`); synchronous `parent.onSubmit()` (`SearchCompleter.swift:105`); `lastActiveConversationKey = nil` only in the `#if DEBUG` init path; `presentSpot` swap (`+FriendsPanel.swift:~1204`). **All 2 CRITICAL and 9 MAJOR: still present.**

**Post-audit note (2026-09-07):** the tour-specific MAJOR/MINOR items below (denied/offline strand, `.isModal`, `.openSpot`/`.friends` detents, toast z-order, non-branching `coachTarget`, `-DEMO_*` opt-out, Reduce Motion environment) were applied immediately after this report.

## CRITICAL (will crash, corrupt state, or break core flow)

### Codec / revision ordering (carried forward, unchanged)
- Unbounded inbound `rev` → permanent trap on the receiver's next mint — `Shared/TweenState.swift:~451`, `Shared/ConversationMeetupStore.swift:~438-444`
  Suggested fix: bound on decode; mint with `addingReportingOverflow`.
- `pj=` participants skip `validCoordinate` → MapKit NSException class — `Shared/TweenState.swift:~402-404`, `Shared/Participant.swift:~78-84`
  Suggested fix: filter decoded `pj` through `validCoordinate`, fall back to `p=`.

No new CRITICAL in the tour code.

## MAJOR (wrong behavior, UX broken, data loss risk)

### Tour state machine (`tourDidObserveChange`)
- **Location denied / offline strands step 3.** `.imIn` advances on the tap so a denied fix "must not strand the tour" — it strands the NEXT step instead: tap I'm in → `.coffeeChip` → `.denied` arrives → user is NOT in → tap Coffee → `canSearch` has no anchor → `searchState = .idle`, toast under the dim, and `selectedCategory` stays `.coffee` so the next tap on the chip is a deselect. `searchState == .results` is never reached; Skip is the only exit. Offline is the same shape. — `TweenApp/OnboardingView+Tour.swift:~66-75, ~87-89`, `TweenApp/OnboardingView+Search.swift:~838-847, ~281-321` **(applied)**
  Suggested fix: enter `.coffeeChip` only with an anchor and online, else jump to `.friends`; a `.denied`/`.failed` while on `.coffeeChip` skips forward.

### Accessibility
- **`.isModal` on both overlays hides the very control the step asks for.** The trait scopes VoiceOver to the modal's descendants; the spotlit button is a sibling beneath the overlay, so on every performed step VoiceOver can reach only Skip. `UIAccessibility.isReduceMotionEnabled` is also read statically in `body`. — `TweenApp/CoachMarks.swift:~227, ~206` **(applied)**
  Suggested fix: drop `.isModal`; `accessibilitySortPriority` on the callout; announce step changes; `@Environment(\.accessibilityReduceMotion)`.

### Carried forward, unchanged (still present)
- `ExpandedView` roster from bubble/legacy peer, missing Send CTA on restore — `Shared/ExpandedView.swift:~134-167, ~613`.
- Cross-conversation phantom peer on switch — `TweenMessages/MessagesViewController.swift:~161-180`.
- Own-proposal detection by name only — `TweenApp/OnboardingView+DeepLinks.swift:58`.
- `"You"` fallback in `agreed=` from both processes — `Shared/TweenState.swift:~196-198`, `+Sending.swift:~358-359`.
- `lastActiveConversationKey` never cleared in production — `Shared/ConversationMeetupStore.swift:~172-180`.
- Return-with-autocorrect cancels its own search — `TweenApp/SearchCompleter.swift:105`.
- `.spot → .spot` sheet swap dropped on iOS 26 — `TweenApp/OnboardingView+FriendsPanel.swift:~1204-1215`.
- Unbounded MKDirections fan-out; two straight-line speeds — `Shared/FairnessRanker.swift:~212-232, ~137/~417`.
- Paywall refresh downgrades a just-verified purchase — `TweenApp/PaywallSheet.swift:83, 99`.

## MINOR (suboptimal, cleanup, hardening)

### Tour steps / detents
- `.openSpot` leaves the detent at 0.45; the first card starts ≈210 pt into a ≈230–310 pt viewport with scrolling disabled, so on SE-class phones the spotlit card is below the fold. — `TweenApp/OnboardingView+Tour.swift:~94-108` **(applied: `.openSpot` → `fullDetent`)**
- `.friends` never touches the detent; the spot sheet's dismiss restores PEEK, and with a pending/agreed meetup the peek header swaps to `meetupPeek`, unmounting the Friends button's anchor. — `TweenApp/OnboardingView+FriendsPanel.swift:~743-758` **(applied: lift to 0.45)**
- Restart into `.coffeeChip` with a stale empty Coffee search: the spotlit tap is a deselect, so the step needs two taps. — `TweenApp/OnboardingView+Search.swift:838-841` **(applied: clear `selectedCategory` on entry)**

### Overlay rendering
- `coachTarget(_:)` is a `@ViewBuilder` if/else (`_ConditionalContent`); when the first ranked item changes, the outgoing and incoming first rows flip branches → identity change → both rows torn down and rebuilt, defeating `.equatable()`. The anchor itself is emitted correctly (modifier sits outside the equatable boundary). — `TweenApp/CoachMarks.swift:~138-145` **(applied: single non-branching `anchorPreference`)**
- Dynamic Type: the map-layer callout is bottom-aligned with `fixedSize` texts; at accessibility sizes it grows past the top edge and Skip leaves the screen. — `TweenApp/CoachMarks.swift:~247-261, ~286`
  Suggested fix: bound the card in a `ScrollView` or cap `dynamicTypeSize` on the card.
- The toast overlay is attached BEFORE the coach overlay, so every toast during the tour renders under the dim. — `TweenApp/OnboardingView+BottomSheet.swift:~80-86` **(applied: reordered)**
- The pulse ring's `repeatForever` animation on persistent `@State pulse` can sit static at 1.05 if the ring is removed and re-added within one overlay lifetime; cosmetic. — `TweenApp/CoachMarks.swift:~181, ~209-213` **(applied: ring keyed on step)**

### Tooling
- Only `testFloatingMapControlsRespondToTaps` passes `-SKIP_TUTORIAL`; `testLaunchScreenshot` and the `-DEMO_SPOT_CARD` / `-DEMO_SETTINGS` / `-DEMO_PAYWALL` capture recipes are neither harness nor opted out, so on a fresh simulator they run under the welcome dim. — `TweenApp/OnboardingView.swift:297-299` **(applied: any `-DEMO_*` argument opts out)**

### Carried forward (unchanged; see the prior report for detail)
- Extension staging (`+Delivery.swift:~78-101`, `MessagesViewController.swift:~405-408`, scoped draft survives leave), 24 s search ladder, `errorStatuses` miss, `isActive` vs `isOptedIn`, aged `.leave` coordinate, TTL refresh on open, one-shot offline banner; `TweenMapSnapshotView` renderer scale, `BubbleImageRenderer` cancel, never-firing success haptic, dead `markers(for:)`/`@ScaledMetric`/A-B branches; `shouldReframe` ignores `positionedByUser`; host sheets/actions list; codec/store list. The "Plan sheet / tutorial cover / activeSheet" item shrinks by one — the `fullScreenCover` is gone; the plan-sheet/deep-link half stands. The inert tutorial "I'm out" button stands (`TweenApp/OnboardingTutorial.swift:~430`, still reached from `SettingsSheet.swift:171`).

## ARCHITECTURE NOTES
- **Tour transitions traced** (`+Tour.swift`): welcome → Start → `.imIn` advances on `awaitingImIn || isUserIn` (name-prompt Cancel leaves the step armed, not stranded) → `.coffeeChip` on `.results && !isSearchLoading` (empty results skip to `.friends`) → `.openSpot` on `activeSheet == .spot` → `.friends` on `.friends` → `.mapControls` (peek) → `.done` → `finishTour`. The only strands were the denied/offline MAJOR and the two detent MINORs; Skip is on every card.
- **Even-odd spotlight**: `Path(rect)` + rounded hole with `FillStyle(eoFill: true)` and `contentShape(_, eoFill: true)` — the hole is excluded from drawing and hit testing; `onTapGesture {}` makes the dim consume taps. The callout is a later ZStack child, so its buttons sit above the shape. The two-layer split is correct. The 8 pt halo passes taps to what lies within 8 pt of the target (the Open Now chip is 8 pt from Coffee — cosmetic, below bar).
- **`ignoresSafeArea` / anchors**: `geo[anchor]` resolves into the GeometryReader's own space, which is the overlay's frame, so the safe-area expansion cannot misalign. iPhone is portrait-locked; iPad (`TARGETED_DEVICE_FAMILY = "1,2"`) is a shipping surface where the bottom-attached-sheet assumption is unverified.
- **Perf**: the home body does NOT read `topGlobalY`; reads occur solely in `SearchHerePillOverlay` and `CoachMarkOverlay.body`, and the latter only while `step != nil`.
- **Flags**: `hasSeenOnboarding` is written only in `finishTour` (Skip and Finish); a kill mid-tour restarts at welcome with `advanceTour` skipping completed steps. `-SKIP_TUTORIAL` and the harness opt-out are honoured; `showTutorial` is now `tourStep == .welcome`, equivalent to the old `dismissTutorial` contract.
- **Equatable boundary**: `.coachTarget` wraps `EquatableView`, so the anchor is published regardless of the skipped body — correct.
- **pbxproj**: `CoachMarks.swift` and `OnboardingView+Tour.swift` each have exactly one `PBXBuildFile` in the `TweenApp` target only.
- **`fullScreenCover` removal**: `OnboardingTutorialView(onDone:)` still compiles from `SettingsSheet.swift:171`; the deck no longer writes `hasSeenOnboarding`, which the tour owns.

## LEGACY DEBT INVENTORY
- Unchanged from the prior report (no legacy accessor, `Slice` comment, projection key or shim was touched): `RankedSpot.etaFromA/etaFromB/worseETA/fairnessGap` (+ `ABDistanceLabel`, `SpotETADisplay` A/B fallback), `FairnessRanker.rank(candidates:from:and:cap:)`, Slice 3/5/6 comments, `saveParticipantSnapshot(_:localName:)` + `tween.cache.*.active` mirrors, `legacyLocalParticipantID()` filters, `MeetupSnapshot` legacy fields, `participantCoordinate` fallback, `tween.pro.redeemedCode`.
- New: `OnboardingTutorialView` is now Settings-only ("Tween guide" in the map menu launches the tour); `dismissTutorial` is gone cleanly.

## TEST COVERAGE GAPS
- Tour: `TourStep` is pure and testable; the transition logic reads `@State` and is untestable without lifting the transition table into a value type (same shape as the extension-state-machine gap). `CoachTargetKey.reduce` and `SpotlightShape.path` are testable in isolation.
- Prior gaps stand: extension state machine unreachable from the unit bundle; `effectiveReceived`, staged delivery, Darwin sync, TTL ageing, gossip decode cap, legacy `isFullyAgreed`, `rev`/`pj` bounds, `ResultCard ==`/`GroupStatusBar ==`, `DeadlinedSearch`, `FairnessRanker.rank` routed path; the three tests pinning wrong behaviour; `MapGeometryTests`/`ProEntitlementTests` hygiene.

## FIX-FIRST PRIORITY LIST
1. Bound `rev` on decode and mint with overflow checking (CRITICAL, carried).
2. Validate `pj=` participant coordinates (CRITICAL, carried).
3. ~~Tour: route denied/failed/offline away from `.coffeeChip`~~ (applied 2026-09-07).
4. ~~Tour: remove `.isModal`, sort priority + announcement~~ (applied 2026-09-07).
5. `ExpandedView` roster from the controller + `setPeerActive(false)` on switch (MAJOR ×2, carried).
6. Sanitise `agreed=` / `ensureNamed` on the host Agree path; own-proposal detection by `senderID` (MAJOR ×2, carried).
7. Defer `onSubmit` in `NativeSearchBar`; guard the `.spot → .spot` swap; rescope `lastActiveConversationKey` (MAJOR ×3, carried).
8. Guard the paywall refresh; bound MKDirections concurrency and unify the straight-line speed (MAJOR ×2, carried).
9. ~~Tour detents and toast z-order~~ (applied 2026-09-07).
10. Dynamic-Type-safe callout (MINOR, open); ~~non-branching `coachTarget`~~ (applied).
11. Extension staging batch + snapshot/renderer items (MINOR, carried).
12. Add `TourStep` unit tests and lift the transition table into a testable value type alongside the extension state machine (coverage).
