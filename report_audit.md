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
