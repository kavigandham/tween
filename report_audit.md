# AUDIT REPORT — Tween — 2026-08-31 (second pass)

**Scope:** read-only static audit of `main` @ `a972895`. Supersedes the earlier
report of the same name. Six parallel readers covered the extension state
machine, the host `OnboardingView` cluster, shared state/persistence, the view
layer, search/ranking/infra, and the test suite.

Constraint 5 verified clean: zero SPM references, zero `GooglePlaces` hits, and
the real key exists only in the untracked working-tree `Secrets.xcconfig`
(`git log --all -- Secrets.xcconfig` is empty).

---

## FOCUS REVIEW — `TweenApp/PaywallSheet.swift`

**Confirmed fixed by `60d6b7f`:** the `MeetupSyncToken` + `await refresh()`
scenePhase pair closes both paths the prior audit named. `messageIsFailure` is
set at all seven `errorMessage` assignments. Every path that sets
`unlocked = true` clears the error first. Every Pro row in the comparison table
maps to a real gate — nothing overclaims.

**Found open, now fixed in `081b685`:**

- **F1 — `restore()` claimed "no purchase found" when it never reached the App
  Store.** `try? await AppStore.sync()` discarded the error, `refresh()` then
  ran against a store sync never populated, and the sheet asserted *"No
  previous purchase found for this App Store account."* Stacked under
  `unavailableSection`'s *"The App Store isn't reachable right now."* that put
  two mutually exclusive statements on one screen — the exact idiom behind the
  2026-08-31 rejection. Now catches the error, returns silently on
  `StoreKitError.userCancelled`, and otherwise says the App Store could not be
  reached.
- **F2 — "Purchase complete — Pro unlocks in a moment" was a dead end.**
  `buy()` had already finished the transaction, so `Transaction.updates` would
  not re-emit; `syncEntitlement()` only re-reads a cache nothing else writes;
  scenePhase cannot fire while the user sits there. The message could persist
  forever above a live buy button. Now starts a bounded 1s/3s/5s
  `refresh()` poll, cancelled on disappear.
- **F3 — the sheet never refreshed the entitlement on open.** `.task` loaded
  products only, and scenePhase cannot fire for a scene already active when a
  sheet is presented, so `unlocked` was purely the cached flag. Now a second
  `.task` runs `await ProEntitlement.refresh()` alongside the product load.

**Still open in this file:**

- **F4 — the token pattern is correct here, leaked one file over.**
  `PaywallSheet`'s `.onDisappear { entitlementToken = nil }` breaks the
  token → handler → View → `@State` box → token cycle. `OnboardingView.swift:1161`
  uses the identical pattern with **no nil-out anywhere**, permanently leaking
  that observer. Benign only because `OnboardingView` is the root and never
  disappears.
- **F5 — `MeetupSyncToken` registers and resolves unretained**
  (`Shared/ConversationMeetupStore.swift:34-40`): a Darwin post racing `deinit`
  is a use-after-free. Narrow, but the paywall is the one caller that creates
  and destroys tokens repeatedly.
- **F6 — `-DEMO_PAYWALL_PRICES` has no launcher repo-wide** and still loads
  real products behind hardcoded `$9.99`/`$1.99` labels — wrong on any
  non-US storefront. DEBUG-only dead weight in the highest-stakes file.
- **F7 — `loadProducts()` writes the failure state with no cancellation
  check**, so a cancelled loader can flash "not available" over a live reload.
- **F8 — `purchasing` shows no spinner**; `AppStore.sync()` can take seconds
  and may prompt for credentials, leaving a dead-looking control.
- **F9 — `supportURL` has no in-app call site.**
- **F10 — `SettingsSheet.proUnlocked` is the same stale-cache pattern one
  level up**, refreshed only on paywall dismissal.
- **F11 — `PaywallSheet` has zero test coverage**, and the only purchase tests
  can silently skip themselves.

---

## CRITICAL

- **Staged (insert-fallback) `.invite`/`.propose`/`.counter` commit local state
  as if delivered.** The `stagedInsert` deferral is scoped to `.leave || .agree`
  only; everything else notes the revision and commits the roster even though
  nothing was sent. Delete the staged bubble and this device believes it is
  "in" while no peer saw it — and the revision floor is burned, so the peer's
  next bubble at that number is rejected forever. The insert path is the
  *expected* one. — `+Delivery.swift:~81-101`, `+Sending.swift:~88-108`
- **A recipient who never joined has no "I'm in" in the expanded view for a
  `.propose`/`.counter` bubble** — but is offered "I'm out" and "Send".
  Reachable in a 3-person group and in 2-person when A proposes from the host
  app. — `Shared/ExpandedView.swift:~548-556, ~610-629, ~710`
- **A `.spot(A)` → `.spot(B)` sheet swap dismisses the sheet it just
  presented**, so an incoming proposal tapped while a place sheet is open never
  appears. — `OnboardingView.swift:855` → `:791`

---

## MAJOR

**Consensus and identity**
- `isFullyAgreed` collapses duplicate identity keys into a `Set` → premature
  "everyone agreed" (`TweenState.swift:113-116`).
- `pids=` restoration is all-or-nothing: one dropped participant collapses the
  whole roster to name-ids and feeds the bug above (`:409-419`).
- `agreedNames` is encoded without `outgoingName()` while participant names are
  blanked, so consensus can never fire on a legacy proposal (`:196-199`).
- `missingAgreementNames` returns raw names — blanked and legacy `"You"` render
  into user copy ("Waiting for , Sam") (`:144`).
- `openedOwnProposal` self-detection is name-only despite `senderID` being
  available (`+DeepLinks.swift:58`).
- The primary peer loses identity in the host ranking roster (`id: "peer"`,
  `name: "Friend"`), and `cycleTravelMode` writes `modes["peer"]` which the
  extension can never resolve (`+Search.swift:574`).

**Payload and state integrity**
- The host deep-link path saves the peer coordinate *before* the revision guard
  (`+DeepLinks.swift:67` vs `:77-88`).
- A group-chat membership change changes `conversationKey` and orphans the
  entire meetup, including the revision floor and tombstones.
- Stale departure gossip re-tombstones someone who already rejoined
  (`RosterMerge.swift:33-41`).
- Every store mutator is an unlocked cross-process read-modify-write; each
  write is atomic, the load→mutate→save around it is not.
- `commitDeliveredLeave`/`commitDeliveredAgree` key their writes off the live
  ivar, not the send's conversation (`+Sending.swift:226, 433, 174`).

**Freshness, errors, offline**
- `.leave` payloads embed a raw `loadSelf()` coordinate with no freshness gate.
- All five host send sites die silently when `encodedURL()` returns nil — no
  toast, no fallback. The extension's single site is the only one that surfaces
  it.
- The extension never gates search/ranking on connectivity, so it burns three
  search passes and ~20 routing legs inside the 120 MB ceiling while the status
  pill says "You're offline".
- A concurrent same-revision bubble is rejected with zero user feedback.
- `handleImIn` does not cancel `locationRefreshTask`, which can clobber the
  roster the send just committed.

**Display correctness**
- `ABDistanceLabel` still renders the legacy positional `etaFromA`/`etaFromB`
  pill, so "You"/"your friend" can be backwards and groups lose everyone past
  #2 (`ResultRows.swift:67,72`).
- Straight-line guesses render identically to routed ETAs everywhere except
  `GroupStatusBar` — `fromRoute` is never read by `SpotETADisplay`.
- `modeUnavailable` is visible only in the extension; the host draws a driving
  number under a transit glyph.
- `CompactView` drops `statusIsError`, so send failures render in routine grey.
- `FriendPlacesList.proUnlocked` defaults to `true` and `GroupEditorSheet`
  omits it, bypassing the Pro gate there.

**Host flow**
- First keystroke after proposing collapses the sheet and drops the keyboard.
- The group bar's paywall arms a child sheet for a presenter that does not
  exist yet (`+GroupBar.swift:130-131, 147-148`).
- `FairnessRanker.rank` fires 16–20 concurrent `MKDirections` requests with no
  limit — the cause of most silent estimate degradation.
- `CalendarExport.add` has no duplicate guard and discards the event id.
- The global staged draft is destroyed by a peek at any other conversation.
- `acquireLocation` can hold `isSending` for ~50 s.
- Reduce Transparency is ignored in both hero panels.

---

## MINOR

`appGroupDidChangePublisher` is inert (object-identity filter against a fresh
suite; the notification does not cross processes anyway). Six App Group stores
missed the cached-suite fix. `DriveTimePreference` falls back to `.standard`.
`StoreKit` is linked into the extension purely because `ProEntitlement.swift`
lives in `Shared/`. No `didReceiveMemoryWarning` anywhere. `noteRevision` with
a nil sender blanks `lastRevisionSender`. `lastActiveConversationKey` is never
cleared and posts no sync. `PingLog.lastIncomingReplyAt` crosses processes with
no post. No cap on decoded `gone=`. `TweenIdentity.stableID` is an
unsynchronized read-mint-write across two processes. `userName` has two writers
with different validation. `hasAgreed` compares names case-sensitively while
the composer normalizes case-insensitively. `LocationProvider` mutates
`@Observable` state off-main with no ordering guarantee. `DeadlinedSearch` uses
a non-cancellable `asyncAfter`. `BubbleImageRenderer.snapshot` uses the
`withTaskGroup` race the codebase banned. `SearchQueryRewriter` strips real name
tokens ("new york pizza" → "york pizza"). `RankedSpot.stableID` can collide.
Plus toast leaks, styling drift, and stale "300 ms poll" comments.

---

## ARCHITECTURE NOTES

- **Force-unwrap posture is excellent**: five `!` in production Swift, all
  provably safe. Zero `try!`, `as!`, `fatalError`, IUOs. No reachable crash risk.
- **The extension is untestable by construction** — only
  `BubbleImageRenderer.swift` is compiled into the app target, so ~1,900 lines
  of state machine are unreachable from any test. Every CRITICAL lives there.
- `OnboardingView.body` is **482 lines**; all three sheet findings live inside
  it. Sixteen other declarations exceed 80 lines.
- Six independent participant-list builders that disagree; geometry duplicated
  with different constants between host and extension.
- **CI never runs the tests** — `codemagic.yaml` builds and uploads without
  `xcodebuild test`. Combined with the paywall's zero coverage and
  self-skipping purchase tests, nothing guards the IAP path.
- All eight hard constraints verified compliant.

---

## TEST COVERAGE GAPS

Covered well: revision tie-breaking, departure gossip cap, `freshSelfCoordinate`,
`Participant.matches`. Not covered: snapshot TTL expiry (nothing ages
`updatedAt`), `effectiveReceived`, `deliverBubble` staged delivery, MeetupSync
post/observe (14 sites, zero tests), `isFullyAgreed`'s legacy duplicate-name
path (untested **and** buggy), and `PaywallSheet` entirely.

`ProEntitlementTests.swift:57` turns any `buyProduct` failure into `XCTSkip`,
and `PaywallCaptureUITests.swift:59` skips under `xcodebuild test` — CI can be
green with zero purchase coverage. `testRefreshWithoutPurchaseClearsStaleUnlock`
is vacuous (`_ = try startSession()` releases the session before `refresh()`).
`TweenAppUITests.testLaunchScreenshot` asserts nothing.

---

## FIX-FIRST PRIORITY LIST

1. ~~`restore()` must not claim "no purchase found" when sync threw~~ — **done
   in `081b685`.**
2. ~~Give the "unlocks in a moment" branch a self-driven retry~~ — **done.**
3. **Extend the staged-insert deferral to `.invite`/`.propose`/`.counter`** —
   silent split-brain plus a burned revision floor on the expected path.
4. **Add "I'm in" for a not-in recipient of `.propose`/`.counter`.**
5. **Fix the `.spot → .spot` sheet-swap dismissal.**
6. **Fix `isFullyAgreed`'s duplicate-name collapse** and the `pids=`
   all-or-nothing fallback feeding it.
7. **Migrate `ABDistanceLabel` to `SpotETADisplay`.**
8. **Surface `encodedURL()` failures at all five host send sites.**
9. ~~Add `refresh()` to `PaywallSheet`'s `.task`~~ — **done.** Still open:
   restructure both `MeetupSyncToken` holders so the handler never captures a
   `View`.
10. **Gate extension search/ranking on `isOnline`.**
11. **Cancel `locationRefreshTask` in the send paths**; pass the delivery key
    into the commit helpers.
12. **Thread `fromRoute` through `SpotETADisplay`.**
13. **Bound `FairnessRanker`'s concurrent routing legs to ~4–6.**
14. **Make the purchase-test skip explicit-opt-out and add `PaywallSheet`
    coverage** — and run the suite in CI at all.
15. **Extract the extension's decision functions into `Shared/`** so the state
    machine becomes testable. Nothing else stays fixed without it.


---

# THIRD PASS — `main` @ `1d10577` (2026-08-31 evening)

`git diff --stat a972895..1d10577 -- '*.swift'` touches **one file**
(`PaywallSheet.swift`), so every finding above outside that file still stands.

## Verification of the three fixes — and one regression they introduced

- **F1 (`restore()`) — correct, was incomplete.** `StoreKitError.userCancelled`
  is the right case. But the two-sentence contradiction was still reachable:
  products failing and `AppStore.sync()` succeeding are independent, so
  "The App Store isn't reachable right now." could still sit above
  "No previous purchase found." *Fixed in `d97499c`: a successful sync now
  re-loads products.* The non-cancel branch also collapsed every other
  `StoreKitError` into a connectivity claim.
- **F2 (`awaitEntitlement`) — no leak, no double-run, but the dead end returned
  after 9 seconds.** All four writers are `@MainActor`, and the poll only ever
  writes `true`, so no race. After the third failed poll the optimistic message
  became permanent again over a live buy button. *Fixed in `d97499c`: terminal
  branch plus a cancellation check between sleep and write.*
- **F3 (open `.task`) — introduced a CRITICAL.** `ProEntitlement.refresh()` is
  a *writer*: it drains `Transaction.currentEntitlements` and then calls
  `setUnlocked(...)` unconditionally. That sequence is **non-throwing**, so
  cancellation ends the loop rather than throwing and the function falls
  through with a partial read and `unlocked == false`, stamping both Pro keys
  false — cross-process, and the extension can never recompute. Binding
  `refresh()` to a sheet's `.task` made it the first cancellable caller, so
  opening the paywall and dismissing it inside that window could revoke a
  paying customer's Pro. *Fixed in `d97499c`:
  `guard !Task.isCancelled else { return isUnlocked }` before the write.*
  The same `.task` also stomped `-DEMO_PRO_UNLOCKED`, because the demo guard
  lived only in `activate()`. *Fixed: hoisted to `ProEntitlement.isDemoPinned`
  and honoured by both.*

## Also fixed in `d97499c`

- `buy()`'s catch-all claimed **"Nothing was charged"** — `purchase()` can throw
  after the App Store took payment, so StoreKit gives no basis for that. Now
  hedges to "If you were charged, tap Restore Purchases," and a thrown
  `userCancelled` returns silently.

## Still open — highest value first

1. **`metadata/keywords.txt` still lists `imessage`, and `description.txt`
   still says "iMessage app drawer" / "Works right inside iMessage"** — both
   untouched since 2026-06-18, i.e. never revisited after the 5.2.5 rejection.
   The description also still sells a two-person product in an app that ships
   named groups.
2. **`CFBundleVersion` in `project.yml` is `3`; ASC already holds 407.** Only
   `codemagic.yaml` rewrites it, so any Xcode Organizer or Xcode Cloud archive
   uploads build 3 and is rejected as not-higher.
3. **Constraint 6 is not clean, and the prior pass's "all eight constraints
   compliant" is not supportable.** `SpotLibrary` persists 20 recents + 50
   favorites — name, street address, coordinates, phone, website and a
   `lastUsedAt` timestamp — unencrypted in the App Group with no expiry and no
   clear control; `MeetupPlan` persists spot name + arrival time. Neither is a
   coordinate or a preference, neither is in the sanctioned exception list, and
   `report_audit_pro.md` (2026-08-02) already logged the `MeetupPlan` half as
   OPEN pending a product decision. Sanction them in CLAUDE.md with a TTL, or
   stop persisting names and addresses — but stop claiming blanket compliance.
4. **The extension can serve Pro indefinitely after a refund** — nothing in
   `TweenMessages/` calls `activate()`/`refresh()`, so the cached flag is its
   only input. Stamp a `verifiedAt` beside it.
5. **A locked user can delete saved addresses** — a Pro-sold feature, no
   `proUnlocked` check on the swipe action (`FriendPlacesSheet.swift:110-114`).
6. **`modesChanged` is structurally always `false`** — `previousModes` is read
   out of the same `plan` that `save()` never mutates, so the documented
   reminder invalidation never fires. Changing an armed reminder's time also
   silently deletes it with no replacement.
7. **`notifyLeaveNow` removes the pending request before adding and swallows
   the error** — the exact ordering `schedule()` documents as a bug 60 lines
   above.
8. **CI still never runs the tests** — 314 test functions, zero executed before
   a TestFlight upload.
9. `ProEntitlementTests.setUp` wipes the entire shared App Group suite, and
   `testMonthlySubscriptionUnlocksPro` never asserts the App Group write.
10. Then everything in the second-pass list above, unchanged.
