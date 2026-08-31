# AUDIT REPORT — Tween — 2026-08-31

Scope: `main` @ `843c562`, clean tree. Read-only audit; no files modified, no
build run.

Note: the `CLAUDE.md` injected into the audit session was the **1.1 branch
version** (Google Places, `Secrets.xcconfig`); the actual `main` `CLAUDE.md` at
HEAD has no third-party dependency and no key exception. Audited against the
on-disk `main` version.

Supersedes the 2026-08-05 report of the same name.

---

## FOCUS REVIEW — the PaywallSheet changes in 843c562

**Verdict: directionally correct, safe to ship, but incomplete — the fix does
not reliably do the thing its own comment promises.**

### `restore()` clearing `errorMessage` first — correct and complete

It mirrors `buy()`, placed after `purchasing = true`/`defer` and before
`AppStore.sync()`. Every in-foreground path that can set `unlocked = true` is
`buy()` or `restore()`, and both now clear the error first. The contradiction
named in the commit ("red text under the You-have-Tween-Pro badge") is closed.

### The `@MainActor` annotations — no hazard, but they are no-ops

`SwiftUI.View` is `@MainActor @preconcurrency` in the iOS 17+/26 SDK, and a
struct that states its `View` conformance in its primary declaration infers
that global actor for the whole type. `PaywallSheet` was therefore **already**
fully main-actor-isolated; the five annotations are redundant documentation.

Confirmed by call-site: `reload()` is called *synchronously* from
`unavailableSection`'s Button action and from the `onChange` closure. If the
type were not main-actor-inferred, a synchronous call to a `@MainActor func`
from a nonisolated computed property would be a hard compile error. It builds,
so the inference holds — the same fact that makes the annotations redundant.

No main-thread stall is introduced: `Task.sleep` and `Product.products(for:)`
suspend the actor, they do not block it.

### Two remaining paths that leave the screen contradicting itself

**(a) The scenePhase read races the very update it exists to catch.** The
handler did a *synchronous* read of the cached App Group flag
(`unlocked = ProEntitlement.isUnlocked`). That flag is written by
`ProEntitlement.activate()`'s `Transaction.updates` listener → `await refresh()`
→ `setUnlocked`. On the exact round trip the comment names — leave to the App
Store, redeem an Offer Code, come back — `.active` fires in the same runloop
turn as foregrounding, while `refresh()` is still awaiting
`Transaction.currentEntitlements`. The read very often returns the **old**
value, and there is no second read.

**(b) A grant that lands while the app never leaves the foreground is invisible
to the sheet.** Ask-to-Buy approval arrives on the *parent's* device; the
child's app can be foregrounded the whole time. Same for a purchase made on
another device on the same account. `Transaction.updates` fires and
`syncUnlockedFlag()` posts on `MeetupSync` — but `PaywallSheet` registered no
`MeetupSyncToken` and observed nothing. The `.pending` message stayed on
screen, in destructive red, above a live purchase button, indefinitely.

Both close with one change: hold a `MeetupSyncToken` for the life of the sheet,
and make the scenePhase arm `await ProEntitlement.refresh()` rather than a
synchronous cached read.

> **Resolved in `60d6b7f`** — both applied, plus the two smaller items below.

### Smaller things in the same file

- `.pending` is an informational state rendered in destructive red — it reads
  as a failure. *(Resolved in `60d6b7f`.)*
- `buy()`'s `.verified` arm sets `unlocked = await ProEntitlement.refresh()`
  with no handling for `false`. A verified purchase whose entitlement has not
  propagated silently returns the user to the plan cards with no message at
  all. *(Resolved in `60d6b7f`.)*
- `SettingsSheet.proUnlocked` is the same stale-cache pattern one level up,
  refreshed only on paywall dismissal — not on scenePhase, not on `MeetupSync`.
  The fix was applied to the child, not the sibling. **Still open.**
- `PaywallSheet.supportURL` has no call site.

### `.gitignore`

Correct and sufficient. `Secrets.xcconfig` is **untracked** and has never
appeared in any commit on any branch (`git log --all --` is empty), so the new
rule is not masking an already-committed key. A full secret scan of tracked
files (`AIza…`, `sk-…`, `BEGIN`, `.p8`/`.p12`/`.pem`) came back clean.
Constraint 5 holds.

---

## CRITICAL

### Payload / revision integrity

- A crafted or corrupt `rev=9223372036854775807` passes `shouldAcceptInbound`,
  is stored as the floor, and then **traps on `Int.max + 1` on this device's
  next send in that conversation — permanently**, because the floor lives in
  the TTL-exempt `ConversationSyncState`. Decode is `flatMap(Int.init)` with no
  bound — `TweenState.swift:~452`; mint sites
  `MessagesViewController+Decoding.swift:~188` and
  `OnboardingView+Actions.swift:~371`.
  *Fix:* reject `rev` outside `0...1_000_000_000` on decode and use
  `addingReportingOverflow` at both mint sites.

- A merely **staged** (insert-fallback) `.invite`/`.propose`/`.counter`
  advances the revision floor as if it were delivered, with this device
  recorded as `lastRevisionSender`. The staged deferral is scoped to
  `.leave || .agree` only — `MessagesViewController+Delivery.swift:~81-99`. If
  the user deletes the staged bubble, a peer's genuinely-new bubble minted at
  that revision is rejected forever. Direct send rejection is a routine path
  ("a rejection here is expected"), so this is common, silent, permanent
  divergence.
  *Fix:* extend `setPendingStagedSend` to all message types and defer
  `noteRevision` + `recordCanonicalSnapshot` to `didStartSending`.

### Extension state machine

- Post-`await` commits read the **live** `conversationKey` ivar, so a
  conversation switch mid-send writes the leave tombstone or the agreement into
  the wrong chat — `MessagesViewController+Sending.swift:~174`, `~226`, `~403`,
  `~434`. `handleImIn` already captures `let sendKey = conversationKey` and
  guards; `commitDeliveredLeave` and `commitDeliveredAgree` do not.
  *Fix:* capture `sendKey` before the await, pass it into both commit helpers,
  and bail on `Task.isCancelled`.

### Host app search

- The search field destroys itself on the first keystroke after you send a
  proposal. `searchBar`'s `onChange(of: searchText)` unconditionally nils
  `selectedResult` (`OnboardingView+FriendsPanel.swift:~603`);
  `showOwnProposalOnMap` leaves it non-nil
  (`OnboardingView+DeepLinks.swift:~266`); the non-nil→nil edge forces
  `selectedSheetDetent = .height(70)` (`OnboardingView.swift:~798-804`), which
  swaps `searchBar` out for `meetupPeek` mid-typing and clears focus.
  *Fix:* arm `suppressNextDeselectDetentRestore` before that
  `selectedResult = nil`, or skip the detent restore while `searchFocused`.

---

## MAJOR

### Consensus and identity

- `isFullyAgreed` false-positives on duplicate names: when `senderID == nil`
  and `agreedIDs` is empty, agreement is a `Set`-membership test over names, so
  one "Alex" satisfies two participants named "Alex" —
  `TweenState.swift:~109-117`. With `senderName` also nil the proposer key is
  `""`, which silently marks every blank-named participant as agreed.
- `isFullyAgreed` gets permanently stuck **false** on a mixed roster: `useIDs`
  is chosen from `senderID`/`agreedIDs`, but `needToAgree` maps `$0.id` over
  the roster, so UUID-keyed agreements can never match name-keyed roster
  entries — `TweenState.swift:~112-116`.
- One empty or dropped participant collapses the **entire** roster to
  name-keyed identity: ids are restored only when `ids.count == decoded.count`,
  but `decodeParticipants` compacts invalid entries while `decodeNames` uses
  `omittingEmptySubsequences: true` — `TweenState.swift:~405-421`. This is the
  upstream cause of the two findings above.
  *Fix:* `omittingEmptySubsequences: false` in `decodeNames`, a placeholder
  (not a drop) in `decodeParticipants`, and match each roster entry with
  `hasAgreed(participantID:name:)` rather than picking one namespace globally.
- Deep-link self-detection compares display names only, ignoring the available
  `senderID` — `OnboardingView+DeepLinks.swift:~58`. A peer sharing your name
  (or both on the "You" default) has their proposal treated as your own.

### Extension state machine

- `locationRefreshTask` is never cancelled by "I'm out", and unconditionally
  writes `isActive: true` up to ~50 s later. The host reads
  `LocationCache.isActive` as "you're in", so the leaver shows as still in.
- `handleImIn` commits the join for a bubble that was only staged:
  `deliverBubble` returns `true` for a staged `.invite`, so `setActive(true)` +
  `setLocalUserLeft(false)` run while the bubble still sits in the input field.
- `decodeAndCache` returns "saved a peer coordinate" but `didSelect` reads it
  as "decoded something". A 1:1 `.leave` decodes fine and returns `false`, so
  the departed peer stays baked into the visible ranking.

### App Group persistence

- The host deep-link writes the peer coordinate **before** the revision guard
  runs — `OnboardingView+DeepLinks.swift:~67-68` vs `~82`. A stale link parks a
  below-floor peer coordinate in the un-TTL'd global cache.
- Host fairness ranking is seeded from a raw, un-freshness-checked
  `LocationCache.loadSelf()` of any age — `OnboardingView+Sync.swift:~242-249`.
  `freshSelfCoordinate()`'s own doc forbids exactly this.
- `saveParticipants`/`saveProposed`/`saveAgreed`/`clearProposalState` are all
  load→mutate→save with no coordination while the host polls and writes the
  same key. `save()` is atomic; the read-modify-write around it is not.

### UI and flows

- **"I'm out" is unreachable in the expanded view for a proposer or an
  already-agreed participant.** `bottomAction` suppresses it whenever
  `isUserIn && received?.kind == .place` on the assumption it lives in the
  action row — true of `agreeChangeRow`, false of `waitingChangeRow`, which is
  precisely the row those users get. `ExpandedView.swift:~744-766`.
- The travel-mode Pro gate sets `activeSheet = .friends` and
  `friendsSubSheet = .paywall` in the same transaction. The child
  `.sheet(item:)` lives inside the `.friends` branch, so its presenter does not
  exist yet; the paywall is dropped and left armed.
- "Send to chat" and "Agree" present the composer into a dismissing presenter.
  If the snapshot render lands inside the ~350 ms dismissal, the tap does
  nothing.
- `ABDistanceLabel` still renders the legacy `"A … · B …"` pair from
  `ranked.etaFromA`/`.etaFromB` — `ResultRows.swift:~27-85`, live at
  `OnboardingView+FriendsPanel.swift:~1410`. For a 3+ person group the host's
  tapped-spot card shows participants [0] and [1] as "A" and "B" and silently
  drops everyone else, while `ResultCard` in the same app and `ExpandedView` in
  the extension both go through `SpotETADisplay` and show all N by real name.

---

## MINOR

- An unparseable `rev=` degrades to legacy accept-all rather than rejection.
- `departedKeys` grows unbounded from the wire and is TTL-exempt;
  `RosterMerge.gossipCap = 8` bounds only the outgoing list.
- The `.invite`-at-floor exception also applies the payload's `gone=` list, so
  it admits removals as well as the additions its comment justifies.
- `save()`'s inline-revision migration calls `noteRevision` with no sender,
  nulling `lastRevisionSender`.
- `lastActiveConversationKey` is never cleared in production.
- The TTL sweep runs *after* the decode that resurrects and re-stamps the
  expired snapshot, so it can never fire on a chat where a bubble decodes
  first; it also only ever touches the active conversation.
- `effectiveReceived` is applied against the pre-update store.
- `TweenIdentity.stableID` is a computed getter that mints-and-writes with no
  lock, across two processes — a first-touch race can mint two UUIDs.
- `UserProfile.displayNameKey` and `UserName.storageKey` are two independent
  constants for the same `"userName"` key, with divergent write semantics.
- `appGroupDidChangePublisher` filters on a freshly constructed
  `UserDefaults(suiteName:)`, which is not the instance that posts.
- `MeetupSyncToken` is retained by a cycle in `OnboardingView` (token → handler
  → captured View copy → its State box → token), so `deinit` never runs and the
  Darwin observer is never removed.
- `PingLog.lastIncomingReplyAt` and `lastActiveConversationKey` are the only
  cross-process writers that never call `MeetupSync.post()`.
- `UserDefaults(suiteName:)` returning nil is never checked anywhere.
- Precise coordinates are logged with `privacy: .public`, including a **peer's**
  lat/lon, at three sites. Mitigating: `.debug` is not persisted by default.
- Overlapping toasts truncate each other; a location-denied user gets a
  dead-end "try again" toast instead of the Settings hint.
- Every solo search kicks the user out of Map mode (the gate reads
  `rankedSpots.isEmpty`, but solo searches populate `soloRanked`).

### Extension memory (constraint 1)

- **No `didReceiveMemoryWarning` override exists anywhere in the repo.**
  Defensible (snapshotter is the only path), but the 24 MB
  `TweenMapSnapshotView` image cache has no explicit purge hook.
- `BubbleImageRenderer` renders at `scale = 3` on a fixed 600×400 (~8.6 MB
  bitmap) while `TweenMapSnapshotView` deliberately caps at
  `min(displayScale, 2)` for exactly this reason.
- `DeadlinedSearch`'s deadline blocks are `asyncAfter` and never cancelled, so
  each retains its `MKDirections`/`MKLocalSearch` for the full 8–10 s past
  completion — up to 20 concurrent in a ranking pass.
- ~805 lines of host-only `Shared/` code compile into the extension via the
  directory glob.
- The 8 s search deadline is per-pass, not overall: up to three chained passes,
  so "Finding fair spots…" can spin ~24 s.

### Convention drift

- 14 `.font(.system(size:))` sites outside `Tokens.swift`, plus hardcoded
  `UIColor(red:…)` in `BubbleImageRenderer`. Fixed-point sizes also do not
  scale with Dynamic Type.
- Poll-cadence comments say "300 ms" in four places; `pollPeer` sleeps 2 s.
- ~25 files carry copied-forward unused imports from the file splits.

---

## ARCHITECTURE NOTES

- **The extension's five `MessagesViewController+*.swift` files (~1,800 lines)
  are structurally untestable.** `TweenAppTests` depends only on `TweenApp`.
  `project.yml:26` already demonstrates the workaround
  (`BubbleImageRenderer.swift` was pulled into the app target "so TweenAppTests
  can cover it") — applied to one file out of six. Every CRITICAL above sits in
  that untestable region.
- **Six independent participant-list builders, no shared helper**, and they
  disagree at runtime. The host's ranking roster names the peer `"Friend"`
  while the host's display roster names them properly, so the app's own spot
  cards show "Friend 21 min" beside a panel showing the real name. The
  extension pair is authoritative — only it does identity dedup, legacy-UUID
  pruning, `needsRide` preservation, and self-coordinate freshness gating.
- **The host app never calls `MapGeometry.centroid`.** It reimplements the
  midpoint inline and computes a different search region than the extension, so
  the app and the extension can rank a genuinely different set of spots for the
  identical roster.
- **The extension applies `FairnessRanker.mostCentral` before routing; the host
  does not.** The extension's own comment says skipping it "quietly dropped
  fairer spots (audit 2026-08-08)" — the host still has that shape.
- Four presentations share one node in `OnboardingView`. Mutually exclusive
  today by convention only; nothing enforces it.
- God methods: `OnboardingView.body` **481 lines**, `refreshFromAppGroup`
  **274**, `handleIncomingURL` **226**, `decodeAndCache` **134**,
  `sendAgreedPlace` **132**, `handleImIn` **123**, `init()` **150**.
- Verified clean and worth protecting: exactly **two** force unwraps in the
  entire audited surface, both guarded; zero `try!`/`as!`; zero
  `TODO`/`FIXME`/`HACK`; the App Group suite name appears exactly once in
  Swift; `MKMapView` appears nowhere; the compact view contains no
  `TextField`/`FocusState`/`becomeFirstResponder`; all three stored extension
  tasks are cancelled in `willResignActive`.

---

## LEGACY DEBT INVENTORY

| Symbol | Declared | Still reached by |
|---|---|---|
| `RankedSpot.etaFromA` / `.etaFromB` | `FairnessRanker.swift:104-105` | **`ResultRows.swift:67,72` (live production)**; else previews/tests |
| `worseETA` / `fairnessGap` | `FairnessRanker.swift:106-107` | tests only — and they pin the shim, not `worstETA`/`fairnessSpread` |
| 2-person `RankedSpot.init(…etaFromA:etaFromB:…)` | `FairnessRanker.swift:111` | tests + previews only |
| `FairnessRanker.rank(candidates:from:and:cap:)` | `FairnessRanker.swift:240` | **nobody** — its doc names `autoRank`, which does not exist |
| "Slice 5" markers | `FairnessRanker.swift:101`, `:110` | migrations never done |

- `@available(*, deprecated)`: **zero occurrences repo-wide.** The legacy
  surface is marked only in prose, which is why `ResultRows.swift:67` survived.
- Dead code: `ConversationMeetupStore.clearTransientState(key:)`,
  `CompactView.markers(for:)`, `Tokens.tweenGlass(radius:)`,
  `TweenCardSurface`, `PaywallSheet.supportURL`, `LocationCache.clearAll`.
- `ProEntitlement.retiredRedeemedKey` is a deliberate one-way reaper —
  correct, not debt.
- Stale docs: `README.md` and `FRIEND_SETUP.md` point at a nonexistent
  `./orchestrator.sh` (repo ships `orchestrator.ps1`); `BUGREPORT.md`,
  `DIAGNOSTIC_2026-07-06.md`, `HANDOFF.md`, `report_structure.md` all reference
  the deleted `TweenViews.swift`; `report_audit_pro.md` documents the retired
  redeem-code feature.
- `Secrets.xcconfig` is **inert on `main`**: `project.yml` has no `configFiles:`
  entry and no Swift code reads `GOOGLE_PLACES_API_KEY`. The `.gitignore` rule
  is the only artifact of the 1.1 work on this branch.

---

## TEST COVERAGE GAPS

314 unit tests across 30 files, 100% XCTest. Strongest: `FairnessRanker`,
`TweenState`, `ConversationMeetupStore`, `RosterMerge`, `Participant`,
`MeetupPlan`.

- **ConversationMeetupStore TTL expiry** — PARTIAL. `clear()` preserving the
  floor/tombstones is tested; **no test ever ages a snapshot past
  `snapshotTTL`**.
- **Revision tie-breaking** — TESTED thoroughly, including the
  `.invite`-at-floor exception.
- **Departure gossip** — PARTIAL. Cap and roster exclusion tested; the
  propagation wiring is not.
- **`effectiveReceived` sticky rule** — NOT TESTED (target-unreachable).
- **`deliverBubble` staged delivery** — NOT TESTED (target-unreachable). Two of
  the four CRITICALs live here.
- **MeetupSync post/observe** — NOT TESTED. 13 post sites and the
  `CFNotificationCenter` observer/deinit entirely uncovered.
- **`freshSelfCoordinate` vs `loadSelf`** — TESTED well.
- **`Participant.matches` name fallback** — TESTED well, five cases.
- **`isFullyAgreed` with duplicate names** — TESTED for the ID path; the
  inverse (duplicate names, `senderID == nil`, empty `agreedIDs`) is not —
  exactly the MAJOR false-positive above.
- **`encodedURL()` size limit** — PARTIAL. The `pj=` drop is tested; the
  `gone=` drop and the final `return nil` are not.
- **`PaywallSheet`** — ZERO coverage. `ProEntitlementTests` covers
  `Shared/ProEntitlement.swift` only, and only four things.

Hygiene:

- `ProEntitlementTests.swift:57` — `XCTSkip` inside the `buy()` helper means
  the two purchase tests **silently pass as skipped** whenever
  `SKTestSession.buyProduct` is refused. Under `xcodebuild test` only tests 1
  and 4 are likely load-bearing.
- `refreshUntilUnlocked()` polls `sleep(100 ms) × 20` — the most flake-prone
  construct in the suite.
- 16 of 30 files have no `setUp()` and do not reset App Group defaults. None
  currently touches App Group state, so there is no live order dependency — but
  they are one `LocationCache.save` away from one.
- `MeetupPlanTests` sets `ProEntitlement.setUnlocked(true)` in `setUp` and
  relies on `tearDown` to clear it.

---

## FIX-FIRST PRIORITY LIST

1. **Clamp the revision on decode and use overflow-safe mint.** A single
   hostile or corrupt bubble permanently crashes every subsequent send in that
   conversation. Cheapest fix, worst outcome.
2. **Defer `noteRevision` for every staged bubble, not just `.leave`/`.agree`,**
   and **gate `handleImIn`'s join commit on the staged status.** Same root
   cause — "staged" treated as "delivered" — producing permanent, silent
   divergence on a routine path.
3. **Capture `sendKey` before the await in `handleImOut`/`sendAgreedPlace`.**
   Writing a leave tombstone into the wrong chat is unrecoverable without a TTL
   expiry.
4. **Cancel `locationRefreshTask` in `commitDeliveredLeave`.** One line; stops
   a leaver being re-marked active.
5. **Fix the two `isFullyAgreed` bugs and the `p=`/`pids=` misalignment that
   feeds them.** Consensus firing early — or never — is the product's core
   promise.
6. **Restore "I'm out" for proposers and already-agreed participants.**
7. **Stop the search field self-destructing after a proposal.**
8. ~~Finish the paywall fix~~ — **done in `60d6b7f`**. Still open: apply the
   same treatment to `SettingsSheet.proUnlocked`.
9. **Move `savePeer` below the revision guard in the deep-link path**, and
   compare `senderID` before `senderName` for `openedOwnProposal`.
10. **Delete `ABDistanceLabel`'s `ranked:` branch** so the host stops dropping
    participants 3+ and stops disagreeing with its own results list.
11. **Add `TweenMessages/MessagesViewController*.swift` to the `TweenApp`
    target sources**, the way `BubbleImageRenderer.swift` already is.
    Everything in items 1–4 is currently unreachable from any test.
12. **Gate the host's ranking seed on freshness** and **apply `mostCentral`
    before routing on the host**, so app and extension rank the same way.
13. **Fix the two dropped presentations** (Pro-gate double-present;
    composer-into-dismissing-presenter).
14. **Move the TTL sweep above `decodeAndCache`** so it can actually fire, and
    **move `effectiveReceived` below the store writes**.
15. **Housekeeping**: drop `privacy: .public` from the three coordinate log
    sites; cap `departedKeys`; delete the dead symbols; mark the A/B accessors
    `@available(*, deprecated)` so the next reach for them warns; retire the
    stale root docs.
