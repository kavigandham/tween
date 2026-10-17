# Post-push audit — 2026-09-21

Three consecutive read-only audits of the meetup-board work (`2b45ea9` →
`be47377` → `2b9d25e`/`cd03db6`). Each one found the previous fix incomplete,
so this file records what was found, what was fixed, and what was deliberately
left.

The whole sequence started from a device report: a meetup both friends had
agreed on asked you to pick a place again, the chips said "Friend" while the
rows said "Saad", and "Leaving now" was unreachable.

## Root cause

Participant identity **collapses to the display name** whenever a payload
travels without usable ids — `Participant`'s own documentation says so.
`MeetupPoll.normalized` matched proposers on `id` alone, read a name-keyed
roster as "nobody here proposed any of this", and deleted the board, the
decision and, fatally, bumped `decisionSeq` — which `merged` reads as a
reopen, so the wipe then beat every peer's real lock-in and was persisted by
`savePoll`. Silent, permanent, self-propagating.

## What each round found

**Round 1 (of `2b45ea9`)** — the first fix kept the board when no proposer
resolved against a 2+ roster. That turned the most ordinary departure there is
(three people, one proposed the only place, they leave) into a meetup pinned to
a departed friend's spot, with no board and no "I'm out" to escape it.

**Round 2 (of `be47377`)** — departure tombstones were threaded through the
controller but not `ExpandedView`, which re-merges the selected bubble and
re-normalizes on its own, so the stranding was still fully reachable through
the view; `ensure(focus)` put back the option `normalized` had just dropped;
and `saveAgreed` replaced the scoped board wholesale, after `mergePoll` had
written it.

**Round 3 (of `2b9d25e`/`cd03db6`)** — the guard added in round 2 checked the
wrong identity. `sendBoardUpdate` stamps `senderID: myID`, so on a `.decided`
that is whoever LOCKED IN, not whose place it is: B locks in C's place, C
leaves, and C's place came back as a settled meetup. `belongs` also asked the
roster before the tombstone — and a peer's roster still listing the leaver is
the exact case tombstones exist for. Both the regression test written in round
2 and the fix it covered shared the same blind spot.

## Fixed

- `normalized(participants:departed:)` decides **per option and per vote**, and
  consults the **tombstone first**: the roster names you, or a tombstone says
  you left, or you are unresolvable — and only a tombstone deletes. No default
  argument, so every call site states what it knows.
- `ExpandedView` takes `departed`; `settledOption` resolves the place's OWNER
  from the bubble's own board rather than trusting the sender.
- `ensure(focus)` will not re-add a tombstoned proposer's place (both targets).
- `ConversationMeetupStore.saveAgreed` merges and re-scopes the board instead
  of replacing it; `saveAgreed`/`saveProposed` filter the payload roster
  through this device's tombstones (`stillHere`), which on the host path was
  re-admitting the leaver AND silencing the departure gossip.
- Both host-app `savePoll` sites re-scope after their union.
- `identityKeys` gates a display name on `id == name` (matching
  `RosterMerge.isDeparted`) and skips empty ids; votes match roster ids
  verbatim so an unnamed participant keeps theirs.
- `pids` decodes positionally (`decodeAlignedNames`) and never downgrades a
  usable name-key to `""`.
- `effectiveReceived` and `bottomAction` gate on `isDecided`, not
  `isFullyAgreed` — the latter is false for every poll-era `.decided`, so that
  whole sticky-agreement override had been dead code.

19 regression tests in `TweenAppTests/BoardIdentityRegressionTests.swift`.

## Deliberately NOT fixed

Real, reported more than once, and each one wider than this defect:

- **`agreedState` is never cleared when a peer departs** — only when the roster
  empties. It is what keeps feeding a stale decided bubble to the view; the
  render paths are now scoped, but the stored state is still wrong.
- **`TweenIdentity.stableID` is unstable under a nil App Group suite** — every
  read mints a fresh UUID, which looks like data corruption rather than a
  provisioning failure.
- **`lastActiveConversationKey`'s setter does not post `MeetupSync`**, though it
  scopes nearly every host-side read.
- **Multi-post ordering** in `LocationCache.saveParticipantSnapshot` and
  `ConversationMeetupStore.save` — observers wake on partial state.
- **`saveAgreed` merges with `preservingVoteOf: nil`** on a peer-inbound path.
  No worse than the wholesale replace it replaced, but not yet right.
- **The 5000-char ladder drops departure gossip one rung above the board.** Its
  "propagation, not correctness" comment no longer holds now that a missing
  tombstone means an option is KEPT.
- **Two unnamed participants share one vote slot** (`id == ""`), so one vote can
  read as unanimous. Needs a legacy payload with no usable `pids`.

## The lesson

Three rounds, three incomplete fixes, one shape: **a fix applied at one site
while a sibling site rebuilt the same state.** The test written alongside each
fix encoded that fix's own assumption, so the suite went green on all three.
What actually caught them was reading for *every place the board is rebuilt* —
not running the tests.

---

# Post-push audit — 2026-10-13 (the 1.0.5 submission diff)

Independent read-only audit of `fd58dbf..2afc21d` — the security/protocol
hardening, the Pro repackaging, the shortened tour, and the lag/UI work. It
found **two submission blockers, both in the new code**, and four MAJORs worth
fixing. All six are now fixed; what follows is the record.

## The two blockers

1. **A paywall row a free user could walk past.** `comparisonRows` sold "Saved
   places — yours and theirs" as Pro while three ungated doors remained: the
   origin picker's Home row, its Set-Home row, and the extension's "from Home"
   button (which has `isProUnlocked` in scope and never read it). Gating one of
   two doors makes a gate decorative; this one had direct App Review exposure.
   All three are gated now, and the row names what is actually gated.

2. **`maxEncodedNameLength = 90` truncated ordinary non-Latin place names.**
   `participantNameAllowed` is ASCII-only, so a 90-character ENCODED budget is
   ~10 CJK graphemes. The bound was introduced to stop a 32-entry roster of
   emoji names blowing the 5000-char ceiling — but it was applied to `t` and to
   every `PollOption.name` as well, which appear ONCE. Japanese, Chinese, Thai,
   Russian, Greek and Arabic place names were being cut mid-name on every
   message while the sender's own screen showed the full name: a visible
   regression against 1.0.4 in every non-Latin market. Place names now have
   their own budget (`maxEncodedPlaceNameLength = 540`); roster names keep 90.

## The others

3. **`normalized`'s empty-roster rule was too loose.** `departed.isEmpty ? self
   : .empty` does not distinguish "everyone left" from "not hydrated" — it
   distinguishes "this device holds any tombstone at all", which is the normal
   PERMANENT state of every group after one person leaves. After the 24h
   snapshot sweep, opening the drawer from the app icon re-merged against an
   empty roster and persisted `.empty` over a live meetup. The rule is now
   "every proposer and voter on this board is tombstoned".

4. **`maxRevisionJump` write-muted anyone far behind.** Refusing to advance the
   floor past +1000 meant a lurker in a 1200-bubble conversation kept a floor
   of 0, minted rev 1 forever, and had every send silently rejected by the
   whole group. The advance is now CLAMPED rather than refused, so an honest
   gap closes over the next few bubbles and an absurd value still cannot
   become the floor.

5. **`PollOption`'s synthesized `Codable` decode bypassed its bounding init**,
   so a board persisted by an older build kept a different `id` than the same
   option off the wire — and `merged`'s re-pick rule read that as "same
   proposer, different place" and dropped the option with its votes.

6. **Three doc comments asserted the opposite of their code** after the
   tie-break and Pro changes. In this codebase that is how the next round of
   incomplete fixes starts, so they are fixed rather than left.

Also: the roster cap was applied before validation (32 junk records emptied a
roster), `decodeAlignedNames` had no bound where its sibling did, the tour's
"N of M" skipped an ordinal for Pro users, and `ChatIllustration` was dead.

## Known and NOT fixed in 1.0.5

**`agreedState` is still last-write-wins.** The board (`MeetupPoll`) is
CRDT-shaped with deterministic tie-breaks, but every render path prefers
`snapshot.agreedState` / `LocationCache.agreedMeetup`, which `saveAgreed`
overwrites wholesale with the inbound state. So two concurrent lock-ins now
converge in the POLL and still diverge on the terminal screen — the devices
swap places rather than agreeing. This is not a regression (both devices
diverged before the change too, by rejecting each other), and
`report_audit.md` already listed `agreedState` under "Deliberately NOT fixed"
in September. But until `agreedState` is DERIVED from the merged board rather
than stored beside it, every convergence fix in `MeetupPoll` is half a fix.
That is the next piece of protocol work, and it wants its own change.

---

# Post-push audit — 2026-10-16 (the three lag commits, 6d49eda..8ced25d)

Read-only audit of the whole tree with the three performance commits called
out for extra scrutiny, since they were the newest and least-reviewed code.
42,331 lines across TweenApp/, TweenMessages/, Shared/ and TweenAppTests/.

**Hard constraints verified clean:** no `MKMapView` anywhere (snapshotter only,
all three extension surfaces); extension `rankCap = min(5, recommendedCap)`; no
first responder in `Shared/` or `TweenMessages/`; When-In-Use only in both
Info.plists; zero `ObservableObject`; no API keys; `CLLocationManager`
retained; `Shared/` globbed into both targets; all four extension Tasks
cancelled in `willResignActive`; App Group keys have no reader/writer drift;
`PaywallSheet.comparisonRows` is a truthful mirror of the real `ProEntitlement`
gates.

## Fixed immediately (it was mine, from 8ced25d)

**`FairnessRanker.rank`'s `onSpot` callback had no cancellation guard, so a
superseded search wrote into the live list.** My commit message claimed
`merging` would ignore a stale spot; that was wrong. `RankedSpot.id` is
content-derived (`name@lat,lon`), so two overlapping searches mint identical
ids and the stale spot REPLACES a live row. Worse, a cancelled rank does not
stop producing spots — `eta` resumes its legs with nil and falls back to a
straight-line estimate, so the dead rank drains faster than the live one.
Every re-rank trigger cancels and immediately re-ranks the same results, so
the common case was half-confidence guesses, computed against the OLD
participant set, landing on top of routed answers with no re-sort to clear
them.

Verified empirically: with the guard removed, a cancelled rank reported 3
spots in 0.13 s. `ProgressiveRankCancellationTests` fails without the fix and
passes with it.

## Everything else from this audit is still open

The full finding list is below, unchanged from the audit. Nothing else here
has been acted on yet.

## CRITICAL (remaining)

### Wire codec
- **`fromId` is bounded by grapheme count only, never by encoded length** — `Shared/TweenState.swift:345` (encode), `:847` (decode). `participantNameAllowed` is ASCII-only, so 64 graphemes of emoji is ~4500 encoded chars: it arrives inside the 5000 ceiling, is persisted as the roster/tombstone key, and then every re-encode exceeds 5000 → `encodedURL()` returns nil → sends fail forever and the stored proposal/agreement is silently nil'd. `fromId` is on no rung of the eight-rung size ladder. Same failure class the 2026-10-13 audit closed for `t`/`from`/`p`, one field over.
  Fix: `Self.boundedKey(senderID)` on encode, `.map(Self.boundedKey)` on decode, add a `fromId` ladder rung.

### Error handling
- **Every host send dies silently when `encodedURL()` returns nil** — `+HandOff.swift:137`/`:150`, `+Actions.swift:432`/`:639`, `+DeepLinks.swift:441`, `+ArrivalSync.swift:276`, `+FriendsSync.swift:76`. All six are bare `guard … else { return }`: no toast, no log. The extension handles this at a single funnel; the host has no equivalent despite `showToast` being on the same struct. Combined with `fromId`, one emoji-id peer makes every host send button permanently dead with zero feedback.
  Fix: have `composeTweenMessage` surface the failure and toast at each site.

### Extension state machine
- **Three send paths broadcast — then persist — an empty roster** — `MessagesViewController+Sending.swift:334`, `:432`, `:567`. `sendPick`, `sendBoardUpdate` and `sendLeavingNow` fall back to the bare `currentParticipants` ivar while every sibling helper uses the snapshot fallback. On an activation where nothing decoded, the bubble ships `p=` empty and the commit writes `saveParticipantSnapshot([])` — the conversation's roster is destroyed on that device.
  Fix: use `pollParticipants()` at all three sites.
- **A conversation switch mid-send lands the leave tombstone on the wrong chat** — `+Sending.swift:189`, damage at `:271`/`:281`, `:519`-`:532`, `:671`. `handleImIn` captures `sendKey` before any `await`; `handleImOut`, `sendBoardUpdate` and `sendLeavingNow` do not, and `commitDeliveredLeave` reads the live ivar.
  Fix: capture the key before the first `await` in all three.

### Consensus
- **The host's incoming-decided path overwrites the local user's own vote** — `Shared/ConversationMeetupStore.swift:400`. `saveAgreed` merges with no `preservingVoteOf`. The extension escapes only because `mergePoll(…, from: .peer)` rewrites afterwards.
  Fix: add a `localID:` parameter and thread `TweenIdentity.stableID` from the host call sites.
- **The host's `tween://` decode never merges the inbound vote board** — `+DeepLinks.swift:~203-221`. The `.propose/.counter/.pick/.vote` branch calls only `saveProposed`, which never touches `snapshot.poll`. A peer's pick or vote opened through the app is dropped, and `sendAgreeReply` then rebroadcasts a board missing everyone else's options.
  Fix: mirror the extension — `savePoll(MeetupPoll.merged(...).normalized(...))` in that branch.

## MAJOR

- **A tie offers no tie-break control** — `ExpandedView+Poll.swift:145`, `MeetupPoll.swift:146`. `voteActionRow` gates the only `onLockIn` call site on `board.leader`, which is nil on a tie. In the 1-1 two-person tie the panel says "someone has to break it" and renders no button.
- **`modesChanged` is a self-comparison and can never be true** — `PlanMeetupSheet.swift:207`, `:230`. Switching travel mode then Save does not cancel the old leave-by reminder.
- **Two `Button`s in one `List` row — the documented dead-tap trap** — `GroupEditorSheet.swift:95`, `:143`. Needs a sim check; if it reproduces, group creation is unusable.
- **The progressive fill costs ~8 whole-screen passes during the wait** — `+Search.swift:669`/`787`. Each merge writes `rankedSpots`, which `mapLayer`, the group bar and `resultsList` all read. Measured in release a pass is cheap, but this is the same pattern 6d49eda removed, reintroduced.
  Fix: give `rankedSpots` the `SearchFieldText` treatment, or coalesce merges behind one frame.
- **A stale `suppressNextQueryChange` latch can swallow the next keystroke** — `+FriendsPanel.swift:997-1014`, `+Search.swift:163`. When the search row is unmounted (`meetupPeek`), the programmatic write lands before `onChange` installs its baseline, leaving the latch armed. Pre-existing, now a file away from the latch.
- **`clearDraft` resurrects the draft it just deleted** — `ConversationMeetupStore.swift:427`, `:437`.
- **`.enroute` missing from the staged-delivery deferral list** — `+Delivery.swift:85-89`, `+Sending.swift:661-682`. A rejected departure still runs `noteEnRoute` and cancels its own reminder.
- **"From Home" persists the declared location before the send succeeds** — `+Sending.swift:76-78`.
- **The `.leave` bubble embeds a raw `loadSelf()` coordinate** — `+Sending.swift:196`. No freshness gate, no `isActive` gate.
- **Arrival Sync origins bypass the freshness window at four sites** — `+Sending.swift:562`, `+Decoding.swift:318`, `+ArrivalSync.swift:62`, `:87`. That origin drives `tt`/`arr` on the wire and the armed reminder.
- **`proposerName` mis-attributes any name-keyed option to the bubble sender** — `ExpandedView.swift:344-352`.
- **Unconditional display-name fallback can hand a peer's vote to the local user and block them from voting** — `ExpandedView.swift:345`, `:356`, `+Poll.swift:92`.
- **`Participant.matches` false-matches two empty ids** — `Participant.swift:88`.
- **The board has no option cap and no one-option-per-proposer enforcement** — `MeetupPoll.swift:532`, `:413-421`. One crafted `opts=` persists a 500-row board.
- **`pids` identity restoration is skipped wholesale for an over-length roster** — `TweenState.swift:907`. A 33+ record `p=` collapses the roster to name-keyed identity while the board stays id-keyed.

Abbreviated for the cap: the locked travel-mode paywall never presents (`+GroupBar.swift:136`/`153`/`180`); `presentSpot` from `handleIncomingURL` swaps `activeSheet` while another sheet is up; `.sheet(item: $planSheet)` sits at the same level as `.sheet(item: $activeSheet)`; host-composed bubbles omit `localID` so the sender's own pin is never "You"; `sendAgreeReply`'s legacy name-namespace guard is dead code; `AddPointSheet`'s resolve task outlives Cancel; `board` is recomputed on 20+ reads per render pass.

## MINOR

Full list retained from the audit: `agreed` budget mismatch across the wire (`TweenState.swift:688` vs `:944`); `departedKeys` has no cumulative cap; `activeConversationBoard()` reads the poll without the TTL gate; `DriveTimePreference` falls back to `UserDefaults.standard`; `sortedByFairness` uses an unstable sort while the progressive fill rests on one re-sort; `RankedSpot.stableID` is weaker than `SearchResultMerger.identity`; `SpotETADisplay` ignores `fromRoute` so a guess looks like a routed answer; peers' Arrival Sync legs carry no provenance; `receive` seeds empty-id participants; three `TweenMapSnapshotView` issues (retry budget, unstructured deadline Task, stale image); a `sensoryFeedback` that can never fire; `groupProgress` can read "3 of 2 agreed"; the tour is 7 cards not 5+1; `SpotCategoryMark` bypasses Tokens; `"userName"` has two owners; the App Group publisher filter degrades to "any object" if the suite is nil; overlapping toasts clobber each other; four App Group mutators never post `MeetupSync`; Contacts permission state is never re-read; three force-unwrapped URLs on the App Review-critical Terms/Privacy links; every force-expanding extension activation runs the MapKit search twice; `didReceive` doesn't clear `rankedSpots`; `sendReferralReply` returns silently and doesn't cancel first; `decodeAndCache` mixes two keys for one conversation; `LocationProvider` mutates state off-main at three sites; `SpotDetailCard.votes` is computed and never read; pervasive unused imports; `ExpandedView+SpotCards`/`+SpotList` file names are swapped.

## ARCHITECTURE NOTES

**The three god methods.** `refreshFromAppGroup` ~317 lines (`+Sync.swift:79`), `handleIncomingURL` ~299 (`+DeepLinks.swift:30` — the dropped-board CRITICAL hides inside it), `TweenState.encodedURL` 200 / `init?(url:)` 195. `OnboardingView.body` is 626 lines. Also over 80: `sendAgreeReply` 122, `sendToChat` 119, `meetupSetView` 118, `presentSearchResults` 111, `initials(for:)` 111, `decodeAndCache` 230, `willBecomeActive` 175, `handleImIn` 145, `sendLeavingNow` 142, `GroupEditorSheet.body` 155, `SettingsSheet.body` 132.

**The pattern behind four of the CRITICALs: a fix applied at one site and not its siblings.** `handleImIn` captures `sendKey`, three siblings don't. Three helpers use the snapshot fallback, three senders don't. The extension merges every decode through `mergePoll`, the host doesn't. The extension handles `encodedURL() == nil` at one funnel, the host nowhere. This is the project's own "sanitize every name path" lesson recurring structurally — a shared funnel for each would make the asymmetry impossible rather than reviewable.

**Cross-process read-modify-write.** Every `save*` wrapper plus `ReferralStore.mutate`, `GroupStore`, `FriendRoster`, `MyPlaceStore`, `EngagementStore` does load → mutate → set. The single-key JSON convention prevents a torn read, not a lost update. Highest stakes: the referral ledger gates Pro and is written by both processes.

## LEGACY DEBT INVENTORY

Dead: `FairnessRanker.rank(candidates:from:and:cap:)` (doc claims callers that don't exist), `FriendGroup.hasSameMembers(as:)`, `MyPlaceStore.place(id:)`, `CompactView.markers(for:)` + its `localParticipantID` param, `ExpandedView.spotCardWidth`/`spotCardHeight`, `TweenPin.animated`, `PaywallSheet.supportURL`, `MoodFamily.symbol`, `MoodIntent.energyLevel`/`foodPreference`, `MoodEnergy`, `sendAgreeReply`'s `agreed`/`agreedIDs` locals, two `_ = x` statements silencing their own locals. Test-only: `RankedSpot.worseETA`/`fairnessGap`, `UserName.loadOrFallback()`. Live but wrong: `ABDistanceLabel`'s two-of-N "A"/"B" capsule shows only participants[0] and [1] in a 3+ group. Inert: `ArrivalSyncService.reapply(event:)` (`_ = event`, three call sites thread it). Out of date: CLAUDE.md constraint 6's exception list omits `ArrivalSyncStore` (names + destination) and `EnRouteLog.Mark` (name).

## TEST COVERAGE GAPS

**The structural gap:** `project.yml:103-115` — `TweenAppTests` depends only on `TweenApp`, so **2,628 lines of the extension state machine are compiled into no test target**, and four of the CRITICALs live there. `MeetupPollCodecTests.swift:599-611` admits it: "Every defect in this seven-round sequence was found by reading; none by a test." Extracting the activation sequence and the send funnel into `Shared/` is the highest-leverage test investment in the repo.

The recent work: `shouldMoveLiveDot` is well covered (7 tests). `merging` has 4 tests, now joined by the cancellation pair. `SearchFieldText`/`SearchFieldRow`/`suppressNextQueryChange` have **zero** — including the W15 latch rule, one character from regressing. `rankedLookup`/`soloLookup`/`rankedTable`/`displayedItems`/`ResultCard.==` have **zero**, and two are static and pure.

Beyond that, in priority order: `encodedURL()` returning nil is never asserted anywhere and ladder rungs 3-7 are unpinned; snapshot-TTL expiry is untestable (five sites read `Date()` with no injectable clock); `isFullyAgreed` with duplicate or blank names; no test ties `comparisonRows` to `ProEntitlement` despite the CLAUDE.md rule; `Participant.matches` with `id == name` and with two empty ids; hostile `votes=`/`pids` indices; the gossip cap at the wire; the 5:00 freshness boundary; the tour's step count.

**Defects in the tests themselves:** two tautologies (`MoodIntentTests.swift:233`, `:447`); an unbounded `while` that already hung the suite once (`ReferralTests.swift:171-173`); `BoardIdentityRegressionTests` has no `setUp` yet writes TTL-exempt tombstones; two incompatible App Group reset idioms across 18 classes, one of which the suite itself documents as unreliable; **23 uses of `try! XCTUnwrap`**; wall-clock dependence in `EnRouteTests`, `PingLogTests`, `ArrivalSyncServiceTests`; tests that assert the memberwise initializer or `UserDefaults` overwrite semantics rather than production behaviour; a UI test that asserts nothing.

## FIX-FIRST PRIORITY LIST

1. ~~Cancellation guard on `onSpot`~~ — **done, with a regression test verified to fail without it.**
2. Bound `fromId` by encoded length and add its ladder rung.
3. Give the host a send-failure channel (without it, #2 is an invisible dead button).
4. Use `pollParticipants()` in the three extension senders.
5. Capture `sendKey` before the first `await` in `handleImOut`/`sendBoardUpdate`/`sendLeavingNow`.
6. Thread `localID` into `saveAgreed`, and merge the board in the host's `.pick`/`.vote` decode.
7. Offer tie-break lock-in on `standings.first`.
8. Fix `modesChanged`; sim-check the `GroupEditorSheet` two-button row.
9. Move `rankedSpots` out of `OnboardingView`'s `@State` read path.
10. Add `.enroute` to the staged-delivery deferral list; move the "From Home" write inside `if didSend`.
11. Route the four Arrival Sync origins and the `.leave` coordinate through `freshSelfCoordinate()`.
12. Test hygiene sweep.
13. Structural: extract the extension's activation sequence and send funnel into `Shared/`.


---

# Follow-up audit — 2026-10-17 (788848c..c41c811, the batched progressive fill)

Scoped to the two newest commits. Verdict: the batching itself is correct —
it cannot lose a spot (`rank` returns the complete set regardless of what was
reported, and `completeRankings` republishes everything), cannot reorder or
duplicate rows, and both cancellation guards survived the refactor. What it
lost was COVERAGE, and that was the real finding.

## Fixed immediately

**Batching silently disarmed the regression test protecting bedaa12's
cancellation guard.** The 0.4 s report window is longer than a cancelled rank
takes to drain (measured 0.13 s), so a cancelled rank finished entirely inside
the first window and reported nothing whether or not the guard existed.
Verified: with the guard deleted, both cancellation tests passed. The CRITICAL
fixed the day before was protected by two tests that could not fail — the
project's own documented trap, where the test written alongside a fix encodes
that fix's assumption.

`rank` now takes an injectable `reportInterval` (tests pass 0, restoring
per-spot reporting), and with that the test fails again without the guard —
"a superseded rank reported 3 spots into the live list" — and passes with it.

Also fixed in the same pass:
- `testAnUncancelledRankStillReportsEverySpot` asserted `reported <= count`,
  which `0` satisfies — it no longer asserted its own name. It now records
  spot IDS and asserts the fill actually fired, that every reported id is one
  the ranking returned, and that none was reported twice.
- `lastReport` started at `Date()`, delaying the first answer by a whole
  window and discarding a window's worth of landed spots on the two paths that
  cancel WITHOUT re-ranking (typing over a live result list; backgrounding).
  It now starts at `.distantPast`, so the first arrival reports immediately.
- `rank`'s doc comment still described the removed per-spot `onSpot` shape and
  promised "one row at a time" — the exact drift 788848c was written to stop.
- The single-spot `merging` had become production-dead, carrying the invariant
  paragraph on an overload nothing called. The batch form now folds through
  it, so one definition of "in place" serves both and the documented rule sits
  on code that runs.

## Still open from this audit

- `testTheReportIntervalIsShortEnoughToSeeButLongEnoughToBatch` asserts
  literals against literals — it pins policy but exercises no behaviour. Not a
  defect; noted so nobody mistakes it for coverage.

Everything in the 2026-10-16 audit above remains open and unactioned, with its
own prioritised list.


# Follow-up audit — 2026-10-17 (010ce48)

Functionally clean: `reportInterval` leaks into no production call site (all
seven use the default), `.distantPast` can add at most one report and never
reports an empty batch, and the `reduce` fold is behaviour-preserving at
immaterial cost. One real finding, fixed, plus one coverage gap, closed.

**The rewritten doc comment contradicted its own commit.** It said "at the
shipping 0.4 s a cancelled rank drains entirely inside the first window, so a
test written against the default passes whether the guard is there or not" —
true of the `Date()` anchor it replaced, false the moment `.distantPast`
landed in the same commit, because the first arrival clears any finite window.
Measured both ways: guard deleted at the default interval reports 1 spot (the
test fails); guard deleted at interval 0 reports 3. So `.distantPast` is what
makes the guard observable, and the injected interval only sharpens the
signal. Both comments now say that. Same doc-drift class as the commit before
it, against a sibling hunk of itself.

Also: `onSpots` is a DELTA since the last report, not a running total — the
wording invited a future caller to assign rather than merge.

**Coverage gap closed.** Both callback tests pass `reportInterval: 0`, which
bypasses the gate entirely, so the accumulate-then-flush behaviour had no test
at all. The gate is now a pure `batchIsDue(now:lastReport:interval:)` with
`ProgressiveBatchGateTests`: the first arrival always reports, an answer
inside the window waits, past the window reports, interval 0 always reports,
and a run of six arrivals collapses to batches [1, 3, 2] with every arrival
either reported or still pending.

One lesson from writing those: the first version asserted the EXACT window
boundary and failed — `Date` is a `Double`, so `addingTimeInterval(-0.4)`
round-trips to 0.39999999999999997 and `>=` is false. The test was asserting
floating-point luck; it now tests past the boundary and says why.

Still open: `testTheReportIntervalIsShortEnoughToSeeButLongEnoughToBatch`
asserts literals against literals (noted, not a defect). Everything in the two
audits above remains open and unactioned.
