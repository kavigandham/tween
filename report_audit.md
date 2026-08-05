# Post-push audit — 2026-08-05

Read-only audit of the Tween codebase run after `5fddb1b`. Covers the whole
repo, with extra scrutiny on the three most recent commits.

**Two of the three CRITICAL findings were independently re-verified in source
before this report was written** (marked ✅). The rest are the auditing agent's
findings, reported as received and not yet re-checked.

*(Supersedes the 2026-08-02 report; that one's findings were addressed in the
commits between.)*

---

## Verdict

Hard constraints all hold: no `MKMapView` anywhere, no keyboard in
`CompactView`, the 5000-char URL cap is enforced with three-stage degradation,
`rankCap = 5` in the extension, `LocationProvider` is retained, and every App
Group key matches between reader and writer.

The problems cluster in the extension's send paths and the host app's 2-second
poll — the two places with the longest patch history. They produce sticky wrong
state rather than transient glitches.

**Of the four areas flagged for extra scrutiny, two are clean and two have
narrow gaps** (details at the bottom).

---

## CRITICAL

### 1. ✅ Cross-conversation state corruption — chat A's outcome lands in chat B

`TweenMessages/MessagesViewController+Sending.swift` — `handleImOut` (~:133),
`sendAgreedPlace` (~:278), `sendBubble` post-delivery (~:529).

**Re-verified.** `handleImIn` does this correctly: it captures
`let sendKey = conversationKey` before any `await` (`:25`) and guards the commit
with `if self.conversationKey == sendKey` (`:92`), with a comment explaining
why. `handleImOut` and `sendAgreedPlace` do neither — `commitDeliveredLeave`
reads the live `if let conversationKey` ivar, which `willBecomeActive`
re-points during the `await`.

Cancelling `sendTask` doesn't save it: a task already past its last suspension
point runs to completion, and no commit site checks `Task.isCancelled`.

**User-visible:** Tap Agree or "I'm out" in one chat, swipe to another and open
Tween → the second chat shows "It's a plan!" for a place never proposed there,
or silently renders you as out. The leave case does not self-heal — the
tombstone blocks both the snapshot restore and the sticky-agree rule, so that
chat stays broken until the user manually re-taps "I'm in".

**Fix:** copy `handleImIn`'s capture + guard into the three other sites.

### 2. ✅ The host app erases the user's own coordinate every 2 seconds

`TweenApp/OnboardingView+Sync.swift:186-196` vs `TweenApp/OnboardingView.swift:1001-1008`

**Re-verified.** `refreshFromAppGroup` unconditionally reconciles memory down to
the cache (`if !same(savedCoordinate, cachedSelf) { savedCoordinate = cachedSelf }`).
But the location handler only *writes* that cache when `awaitingImIn ||
(isUserIn && !selfIsManual)`. Nothing writes it for a user who hasn't joined a
meetup — the silent-launch behaviour deliberately skips the write, and the poll
was never taught the exception.

**User-visible:** On a fresh install with location granted, the blue dot appears
and vanishes within two seconds, then reappears on the next movement tick,
forever. This is the first thing a new user sees.

**Second-order, same root cause:** `shouldReframe = savedCoordinate == nil`
exists so continuous ticks don't reframe. Since the poll nils it every 2 s,
every tick looks like a first fix — the camera is yanked out of the user's pan
roughly every 35 m of movement, and `position.positionedByUser` resets, silently
disabling "search where you look".

### 3. `isFullyAgreed` decides consensus from one sender's partial roster

`Shared/TweenState.swift:109-117`

`needToAgree` derives from the *payload's* `participants`, but `RosterMerge`'s
own doc comment states the governing invariant: "An inbound bubble is ONE
SENDER'S VIEW of the roster… absence is ignorance, not departure." Receivers
never recompute against their merged roster.

**User-visible:** A, B, C are in; D joins concurrently. C agrees with a payload
carrying `participants=[A,B,C]` → reads as fully agreed. D's phone shows
"Meeting at X" for a spot D never agreed to — and because the state is sticky,
D can't get back to the Agree/Change UI.

Related: on the legacy `senderID == nil` path the computation runs in the *name*
namespace, so two participants named Sam collapse to one.

---

## MAJOR (agent findings, not re-verified)

- **The 24-hour snapshot TTL can never fire** — `MessagesViewController.swift:189-196`.
  `decodeAndCache` runs before the TTL check and re-stamps `updatedAt`, so the
  timestamp is always "now" by the time it's tested.
- **The conversation key rotates when chat membership changes** —
  `ConversationMeetupStore.swift:161-168`. Adding anyone to the group orphans
  the sync state, resetting `lastRevision` to 0 and losing the leave tombstone.
- **Departure gossip can kick out someone who already rejoined** —
  `+Decoding.swift:88-98`.
- **`gossipCap` uses a sorted prefix**, so tombstones past the first 8 are never
  propagated — `RosterMerge.swift:33-41`.
- **Same-revision concurrent proposals diverge permanently** —
  `ConversationMeetupStore.swift:476-486`. Two people pick a spot in the same
  beat; each sees a different agreed place.
- **A post-agreement `.invite` knocks everyone out of MEETUP SET** —
  `+Decoding.swift:253-257`. A late friend tapping "I'm in" restarts a finished
  negotiation, and subsequent taps send `.propose` instead of `.counter`.
- **A departed peer is resurrected from the stale `agreedState` roster** —
  `+Decoding.swift:69-75`. `CompactView` and `ExpandedView` then disagree about
  the count at the same moment.
- **`acquireLocation()` can block a send ~35 s** — `+Delivery.swift:153-173`.
  The watchdog fires at 60 s, twice the window.
- **The 8 s search timeout bounds each search, not the ladder** —
  `+Ranking.swift:87-108`. Worst case ~34 s of spinner.
- **The snapshot timeout is disarmed by the cancellation it exists to survive** —
  `BubbleImageRenderer.swift:74-76`. `TweenMapSnapshotView.swift:135` does the
  same thing correctly; the two disagree.
- **`didReceiveMemoryWarning` / `mapDegraded` do not exist** despite
  `HANDOFF.md` documenting them. Zero repo-wide hits.
- **The snapshot map never re-centers on selection** —
  `TweenMapSnapshotView.swift:43,68-75`. `focusCoordinate` isn't in the
  `.task(id:)` key. A failed re-render also keeps showing the previous region.
- **Two `.sheet` modifiers on the same presenter** — `OnboardingView.swift:801`
  and `+BottomSheet.swift:51`. The exact collision the `ActiveSheet`
  consolidation exists to prevent.

---

## Focus-area verdicts

**Status pill move (`ExpandedView`) — CLEAN.** Single render site on `body`,
one caller, no overlap in either hero state. All three layouts are
`mapSection` + a bottom `safeAreaInset`, so the top overlay lands on the map
exactly as intended.

**`FriendRoster.addPlace` / `removePlace` — CLEAN**, including the legacy
`savedPlaces == nil` migration path. The synthesized place borrows the friend's
id so a migrated row's delete matches; `removePlace` correctly nils all three
legacy columns when the list empties. Well covered by `FriendPlacesTests`.

**`pendingFriendSheetAction` — one real gap.** It's the only armed-state slot
not disarmed in the `activeSheet` `onDismiss`, alongside `spotSubSheet`,
`pendingGroupFriends`, and `friendsSubSheet` — each of which was added there
after a shipped bug. If the parent sheet is torn down inside the ~0.35 s
dismiss window, the parked ping survives and fires against a stale friend later
in the session. Narrow window; one-line fix.

**`GroupEditorSheet.navigationDestination` — works, two notes.** The
justifying comment describes a SwiftUI rebuild that doesn't actually happen (it
works for a different reason — `FriendPlacesList` updates its own `places`
directly). And the `if let friend` has no `else`, so a roster decode failure
would push a blank screen instead of popping.

---

## Commit-specific checks

- **`5fddb1b` (legal URLs)** — no `kavigandham/tween` URL survives anywhere.
  `metadata/privacy_url.txt`, `docs/privacy.md`, `docs/app-store.md`, and
  `PaywallSheet.privacyURL` all agree. `PaywallSheet.supportURL` is declared and
  never referenced in code — parked for the store listing; worth a note saying
  so.
- **`4b7e5d7` (screenshot harness)** — no `#if DEBUG` leak into release.
  `HarnessShotView`'s `ExpandedView` call passes all six non-defaulted
  parameters in correct memberwise order.
- **`03bd8e8` (six defects)** — all six fixes verified present and correct.

---

## Fix-first order

1. Capture and guard `sendKey` in `handleImOut`, `sendAgreedPlace`, and
   `sendBubble`'s post-delivery block.
2. Stop `refreshFromAppGroup` nilling `savedCoordinate` when the cache is empty
   by design — fixes the blinking pin *and* the camera yank in one change.
3. Recompute `isFullyAgreed` against the receiver's merged roster.
4. Move the TTL sweep above `decodeAndCache`.
5. Split `$planSheet` off the shared presenter.
6. Add `pendingFriendSheetAction = nil` to the `activeSheet` `onDismiss`.
7. Fix `BubbleImageRenderer`'s deadline to use an unstructured `Task {}`.
8. Add `focusCoordinate` to `TweenMapSnapshotView.cacheKey`; clear `image` and
   reset `retryAttempt` on key change.

## Test coverage gap worth naming

`project.yml:96-105` — `TweenAppTests` depends on `TweenApp`, which sources only
`BubbleImageRenderer.swift` from the extension. **The entire state machine is
unreachable from tests.** Every CRITICAL above lives in code no test can call.

Two existing tests are vacuous: `MeetupPlanTests.swift:288-294` and `:298-305`
construct a `ParticipantETA` and assert its own values back, touching no
production logic — one of them is named for the transit-fabrication fix and
doesn't exercise it.
