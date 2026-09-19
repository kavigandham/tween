# Repo audit — 2026-09-19 (post-push, vote board)

Scope: the post-vote-board codebase — `MeetupPoll`, the new
`.pick`/`.vote`/`.decided`/`.enroute` codec, the poll-aware host app, and the
extension state machine. Read-only audit; no builds run.

> **Status: the CRITICAL and MAJOR findings below were fixed in `7634cde`,**
> with 8 regression tests (`TweenAppTests/MeetupPollCodecTests.swift`), each of
> which failed before its fix. Build **458 (1.0.4) predates the fixes** and
> must not be submitted. Remaining MINOR items are listed as open.

---

## CRITICAL — fixed in 7634cde

### 1. Votes and the decision indexed a different array than shipped
`encodeOptions` drops any option whose `proposerID` isn't on the roster
(`compactMap` + `guard let proposerIndex`), but `votes` was encoded against the
unfiltered `poll.options` and `dec` was `poll.options.firstIndex(...)`. One
dropped option shifted every later index by one: the receiver either lost a
vote or **assigned it to the wrong place**, and `dec` could move the decision
onto somewhere nobody locked in.

Reachable from three paths that mutate after `normalized(participants:)`:
`sendBoardUpdate` (`board.ensure(focus)`), the host's `sendAgreeReply`
(`proposerID` taken from the opened bubble), and `sendPick` when no fresh
coordinate exists.

**Fix:** one list — `MeetupPoll.encodableOptions(participants:)` — feeds
`opts`, `votes` and `dec` alike.

### 2. `Dictionary(uniqueKeysWithValues:)` traps on a duplicate key (×2)
A runtime **precondition failure**, not a throw.
- `encodeOptions` keys by participant id. `decodeParticipants` sets `id: name`
  and `outgoingName` blanks the "You" fallback, so two unnamed people decode to
  two entries with id `""`.
- `encodeVotes` keys by `PollOption.id`, and `decodeOptions` didn't dedupe a
  rounded content key.

The decoded state is re-encoded on the very next line of the receive path
(`saveProposed` → `MeetupSnapshot.proposedState` setter → `encodedURL()`, and
`LocationCache.saveAgreedMeetup`), so a crafted link crashed **both** processes
— the threat model already hardened for `lat=nan` and `rev=Int.max`.

**Fix:** `uniquingKeysWith:` on both maps; `decodeOptions` dedupes by id.

### 3. A pick couldn't reopen a decision on any other device
`pick` cleared `decidedOptionID` locally, but the wire had no way to say
*cleared* and `merged` was sticky (`incoming ?? result`). Receivers kept their
decision, so `isMeetupSet` stayed true, `hasOpenVote` stayed false, and the new
pick was **invisible** — the only exits were "I'm out" or locking in the stale
place.

**Fix:** a `decisionSeq` generation counter on the decision slot, encoded as
`decs`. Higher generation wins; equal generations break deterministically.

## MAJOR — fixed in 7634cde

- **A stale board could overwrite your own vote** and settle the meetup on it
  (3-person sequence in the original report). `merged` now takes
  `preservingVoteOf:` and re-asserts the local vote.
- **`.decided`/host `.vote` claimed someone else as sender.** `senderID` drives
  the revision floor's tie-break owner, `RosterMerge.clearDeparted` (a vote on a
  departed person's pick resurrected them) and referral attribution — and the
  caption read "Hassan voted for Hey Tea" when Belal voted. Sender is the
  composer now; `agreedIDs` lists everyone but them, satisfying 1.0.3.
- **A staged `.pick` committed as if sent** — consumed the host-app draft and
  cleared the decided meetup for a bubble the user could still delete. `.pick`
  joined the staged-delivery deferral.
- **The last 5000-char ladder rung lost the place** for poll-aware clients
  (`absorbedPoll` no-opped for `.pick`). It now reconstructs the option.
- **The host replaced the board rather than merging it**, discarding anything
  the extension folded in while the composer was open.

## MAJOR — still open

- **A floor-tied `.decided` drops the whole bubble.** `isAdditive` is false for
  `.decided`, so a same-revision cross-sender lock-in is rejected *before* the
  roster merge, `mergePoll`, en-route note and peer-coordinate write. The
  terminal decision losing the tie-break is intended; taking the roster and
  board with it is collateral. Fix would be to apply the tie-break to
  `decidedOptionID` only.

## MINOR — still open

- `effectiveReceived`'s sticky rule gates on `isFullyAgreed`, which is
  hard-false for `.decided`/`.enroute`, so the rule is inert for poll-era
  decisions (harmless — the board's `decidedOptionID` carries the state).
- `ensure()` can re-admit an option whose proposer isn't on the roster being
  encoded against (now harmless, since `encodableOptions` filters it out).
- The host composes a board for `lastActiveConversationKey` but lets the user
  pick any thread in `MFMessageComposeViewController`.
- `voteProgress` uses `max(participants.count, votes.count)`, which can report
  "2 of 3 voted" in a two-person chat.
- `handleIncomingURL` (~250 lines) duplicates `decodeAndCache`'s
  revision/tombstone/roster logic and has already drifted once.

## Architecture notes

- **Constraint 1 (extension memory) holds.** `MKMapView` appears only in
  comments; every extension surface renders through `TweenMapSnapshotView` /
  `BubbleImageRenderer` with `MKMapSnapshotter`. `rankCap = 5` is applied at
  both `mostCentral` and `rank`, the 8s `DeadlinedSearch` budget is enforced,
  and `willResignActive` cancels all three tasks. Every `presentUI` closure
  captures `[weak self]`.
- **Constraint 2 (5000-char ceiling)** is enforced on encode and re-checked on
  decode.
- **App Group keys**: every key has a matching reader and writer with identical
  spelling, including the new `tween.enroute.<key>`. `MeetupSync.post()` is
  called by every canonical writer except `setPendingStagedSend` (documented as
  intentional), and `MeetupSyncToken.deinit` removes its Darwin observer.

## Test coverage gaps still open

- `decodeAndCache` / `commitDeliveredBoard` / `mergePoll` /
  `commitStagedSendIfNeeded` are untested end to end — the extension state
  machine has no test-target coverage at all.
- Degradation ladder below `pj` (the `gone` rung).
- `MeetupSync` Darwin post/observe; snapshot TTL expiry in `willBecomeActive`.


---

# Root cause of the seven-round sequence (pass 7, 2026-09-19)

Pass 7 verified `4ce65ab` **clean** — the first fix in the sequence with no
defect of its own. It also named why there were seven rounds.

## The activation sequence is structurally untestable

`MessagesViewController` lives in the `TweenMessages` target. `TweenAppTests`
depends on `TweenApp`, whose sources are `TweenApp` + `Shared` + exactly one
hoisted extension file (`TweenMessages/BubbleImageRenderer.swift`, hoisted for
precisely this reason — see the comment in `project.yml`).

So `decodeAndCache`, `commitStagedSendIfNeeded`, `mergePoll`,
`recordCanonicalSnapshot` and `willBecomeActive` cannot be reached from any
test. **All six defects were found by reading. None by a test.**

## Rounds 3–6 were one defect in four costumes

Not six unrelated bugs. Rounds 1–2 were codec defects (index misalignment,
`Dictionary` traps, `Codable` `keyNotFound`) and have stopped recurring.
Rounds 3, 4, 5 and 6 are all: *there are two copies of the board, and
correctness depends on the order in which they are read and merged inside a
60-line imperative sequence.* Each fix relocated a statement, and each
relocation created the conditions for the next.

`willBecomeActive` now carries ~45 lines of comment defending the position of
~10 lines of code. That ratio is the diagnostic.

## Recommended: Phase 0 (no wire change), then per-entry sequences in 1.1

**Phase 0 — 1.0.5, ~1 day, no payload change:**
1. Make the restore MERGE rather than assign. `received` and
   `currentParticipants` are assigned from a re-read, clobbering what the
   decode just computed — that is the bug *shape* of round 6, independent of
   where the load sits.
2. Extract the sequence into a pure function in `Shared/` —
   `ActivationResolver.resolve(stored:decoded:inMemory:leftTombstone:now:)`.
   **Highest-leverage change available**: it makes the activation testable for
   the first time, via a `project.yml` edit of the shape that already exists
   for `BubbleImageRenderer.swift`. Rounds 4, 5 and 6 would each have been a
   ten-line unit test.
3. Residuals: re-check the TTL on the restore's read; decide whether
   `clear(key:)` should spare `pendingStagedKey` (a >24 h staged send
   currently can never commit — same window, same shape as round 6).
4. Ship the still-open MAJOR: apply the revision floor's tie-break to
   `decidedOptionID` only, not the whole bubble.

**Phase 1 — 1.1:** stamp each `PollOption` and each vote with the `rev` of the
bubble that created it; merge becomes per-key max-seq. Then DELETE
`preservingVoteOf`, `BoardSource`, `iHoldMyOwnPick`, `decisionSeq` and the
`.pick`-reopen inference — ~80 lines of code and ~120 of justifying comment.

Cost: ~40 chars on a five-person board, <1% of the 5000 ceiling.

**Two hard constraints for Phase 1, both with precedent in this repo:**
- **Never change `opts` record arity.** Build 458 enforces `parts.count == 4`;
  a fifth field decodes every option to nil on 458–470. Parallel params only.
- **`PollOption` needs a hand-written tolerant `init(from:)` before gaining a
  stored property.** Synthesized `Codable` ignores defaults — this is exactly
  what `42faf94` fixed on `MeetupPoll`, and it would recur at larger scale.

Default a missing entry-seq to the bubble's own `rev`, and builds 458–470
converge correctly without knowing the field exists. 1.0.3 predates the poll.

**Verdict: restructure, staged — not "keep patching".** The patches were
converging on reachability, not correctness.
