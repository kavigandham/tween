# AUDIT REPORT — Tween — 2026-07-10 (post-push audit of b902d4d, branch codex/imessage-map-sync)

Scope: adversarial re-verification of the staged-send-marker fix (the CRITICAL from the 9db000b audit) — full staged-leave/agree lifecycle traces through the code as it now stands, the new rev-less guard, marker key derivation, the agree-deferral behavior change, marker lifetime vs. `clear` paths, and the rest of the 4-file diff. Read-only; working tree verified identical to b902d4d (HEAD).

**Headline: the shipped fix is real.** The marker is now set (`MessagesViewController.swift:1450`), the guard chain in `commitStagedSendIfNeeded` (`:300-329`) is reachable, the primary (`didStartSending:282`) and backstop (`decodeAndCache:370`) commit paths both work, double commits are prevented (marker consumed at `:304` before any early-return), and the 9db000b CRITICAL and MAJOR are correctly closed. But the marker's *lifetime* still has a hole the doc comment papers over.

## CRITICAL (will crash, corrupt state, or break core flow)

None found.

## MAJOR (wrong behavior, UX broken, data loss risk)

### Orphaned staged-send marker + revision tie ⇒ own-bubble tap replays a superseded leave/agree locally
- The marker doc comment claims it is "cleared by any later real commit" (`Shared/ConversationMeetupStore.swift:363`), but only `commitDeliveredLeave` (`:1009`) and `commitDeliveredAgree` (`:1201`) clear it. `handleImIn`'s join commit (`:902-915`), `sendChosenSpot`/`sendCounter`/`sendDraft`'s delivered commits, and `deliverBubble`'s direct-send success path (`:1454-1461`) all leave a stale marker in place. Combined with the fact that a staged send *defers* the floor bump, the floor guard at `:314` (`revision < lastRevision`, no tie-break) fails to protect in this concrete sequence: floor F; user taps "I'm out" → leave minted rev F+1, staged, marker=`.leave`, floor still F; extension dies; user taps send (peers apply the leave at F+1; no `didStartSending` reaches the dead extension); user reopens Tween from the drawer (selectedMessage nil → backstop never fires; device still renders "in") and taps "I'm in" → the rejoin invite mints rev F+1 *again* (floor never advanced), direct-sends, and notes floor=F+1/sender=me — peers accept it as a same-sender tie and re-add the user, so everyone converges on "in"; marker is still `.leave`. Now any tap of the old own leave bubble (rev F+1) passes every guard — marker type matches, F+1 is not `< F+1` — and `commitStagedSendIfNeeded` replays the departure: tombstone set, self deactivated, agreed meetup cleared, roster snapshot without me — while every peer believes I'm in, and no bubble was sent. The mirror-image staged-agree variant (agree sent-while-dead → counter direct-sent at the tied revision → tap the old agree bubble → local MEETUP SET over the live counter) works the same way. — `TweenMessages/MessagesViewController.swift:~314, ~912, ~1456`
  Suggested fix: clear the marker on *every* successful non-staged delivery in `deliverBubble` (one `setPendingStagedSend(nil, key:)` beside the `noteRevision` at `:1456-1459`) — any later real send supersedes the staged intent, which also makes the doc comment true.

## MINOR (suboptimal, cleanup, hardening)

### Marker read path prefers the ivar; set path deliberately doesn't
- `deliverBubble` sets the marker keyed off the conversation parameter precisely so "a nil conversationKey can't silently skip the marker" (`:1447-1451`), but `commitStagedSendIfNeeded` reads via `conversationKey ?? Self.conversationKey(for: conversation)` (`:301`). If the two ever diverge — realistically only when the thread's participant set changes between staging and sending, which rotates the roster-derived key — the read misses and the commit is dropped, plus the marker is orphaned under a key that `clear(key:)` (only ever invoked with the *current* key, `:187`) will never touch. The whole store shares this roster-keyed design so the blast radius is a general known property, but the read/set asymmetry is gratuitous. — `TweenMessages/MessagesViewController.swift:~301`
  Suggested fix: read with `Self.conversationKey(for: conversation)` first (or exclusively), matching the set site.

### `clearIncludingSync` can resurrect sync state from a legacy blob (pre-existing)
- It removes the sync key *before* delegating to `clear(key:)`, whose "rescue never-migrated legacy sync fields" `loadSync` (`:229`) then sees no sync key, migrates any inline `lastRevision`/`localUserLeft`/`departedKeys` out of the still-present legacy snapshot blob, and re-creates the sync key it was supposed to wipe. Only reachable with pre-split-format blobs, and the method has no production callers (tests only) — but it inverts the documented "full wipe" contract. Not introduced by b902d4d. — `Shared/ConversationMeetupStore.swift:~241-244`
  Suggested fix: remove the sync key *after* `clear(key:)` returns.

## VERIFIED CLEAN (focused checks answering the audit questions)

- **Lifecycle (a), extension alive:** stage → marker set under conversation-derived key → user taps send → `didStartSending:281-283` decodes the message URL → `commitStagedSendIfNeeded` consumes the marker, floor-checks, `noteRevision` + `recordCanonicalSnapshot` + `commitDeliveredLeave/Agree`. Direct sends never set the marker, and `didStartSending` fires for them too — the type-matched marker guard correctly no-ops, so no double commit.
- **Lifecycle (b), extension killed:** own-bubble tap → `willBecomeActive` sets `conversationKey` (`:158`) *before* `decodeAndCache` (`:181`) → own-message branch (`:364-371`) runs the backstop commit; the snapshot restore at `:182-208` therefore reads post-commit state (a committed leave leaves `received == nil` and a wiped proposal; a committed agree resurfaces via `effectiveReceived`). Commit-before-TTL ordering is also right: the backstop's `recordCanonicalSnapshot` refreshes `updatedAt`, so the TTL check at `:186` can't wipe a just-committed generation. A second tap of the same bubble finds the marker consumed — no double.
- **Lifecycle (c), deleted staged bubble:** marker persists (by design), but with the bubble gone there is no rev-tied own bubble to tap; older own leave/agree bubbles sit at or below a floor that later commits advance past, and the at-floor replay of an *already-committed* own agree is idempotent with stored state. The dangerous non-idempotent variants all require the sent-while-dead + tied-revision ordering reported as MAJOR above.
- **Rev-less guard: safe.** `nextOutgoingRevision` (`:525-528`) returns nil only when the `conversationKey` ivar is nil; the ivar is assigned at the top of `willBecomeActive` (`:158`), which the Messages lifecycle guarantees precedes any UI interaction, and nothing ever nils it. Every bubble `handleImOut`/`sendAgreedPlace` mints therefore carries a revision, and `TweenState`'s codec round-trips it. The guard only rejects genuinely foreign rev-less bubbles — the intended semantics.
- **Staged-agree deferral: nothing depended on the stage-time writes.** After staging, `sendAgreedPlace:1170` skips `commitDeliveredAgree`, `received` stays on the proposal, the snapshot keeps `proposedState`/nil `agreedState`, so `willBecomeActive` restore and `effectiveReceived`'s `agreedCandidate` both correctly render the pre-send Agree/Change state with the "tap send" hint; `handleImIn`'s expand-suppression check is status-based, unaffected. Re-tapping Agree just restages and overwrites the marker with the same type.
- **`clear` during a live staged window: acceptable.** `clear(key:)` has exactly one production caller — the 24h TTL in `willBecomeActive:187`. A staged bubble idle >24h belongs to a meetup generation the TTL is simultaneously erasing everywhere, so dropping its pending commit is the correct aging-out. Host-app writers only call `clearProposalState`, which never touches the marker.
- **Store test:** `testPendingStagedSendDiesWithTheMeetupGeneration` is correct and suite `setUp` wipes the whole App Group domain, so no cross-test leakage. The rest of the diff is doc-comment and report_audit.md churn — no behavior.

## ARCHITECTURE NOTES
- The marker's guard stack now has three legs (type match, rev-less reject, floor `<` check) but the floor leg is structurally weaker than `shouldAcceptInbound` — it has no sender/tie handling, and staged sends are *guaranteed* to produce revision ties with any subsequent same-device mint because staging defers the floor. If the MAJOR fix lands (clear marker on any delivery), the tie case becomes unreachable and the `<` check is fine as-is; otherwise the check should mirror the W2 tie-break.
- The sent-while-dead + never-tapped case still never commits locally (device stays "in" after a leave peers applied) — inherent to the backstop design, previously dispositioned as accepted; the rejoin flow self-heals it, which is exactly why the orphaned marker in that flow (MAJOR) is worth closing.
- The staged `.invite` (`handleImIn`) remains the lone staged type committing at stage time — previously dispositioned as accepted; still uncommented at the call site.

## LEGACY DEBT INVENTORY
- Unchanged from the 9db000b report: `etaFromA`/`etaFromB` accessors in `TweenApp/SpotDetailCard.swift:287, 342, 539`; `legacyLocalParticipantID()` filtering at `MessagesViewController.swift:509, 1109-1110` (still unconsulted by `commitStagedSendIfNeeded` — benign, type-match gated).

## TEST COVERAGE GAPS
- The wiring-level gap stands as dispositioned: `commitStagedSendIfNeeded`, `deliverBubble`'s staged branch, and the backstop live in the TweenMessages target, unreachable from `@testable import TweenApp` — the store tests cannot catch a future regression that unwires the setter again, nor the rev-less/tie guard behavior.
- The MAJOR's orphaned-marker sequence (marker survives an invite/propose/counter commit; tied-revision own-bubble replay) — untested and untestable at store level alone; the marker-clear half (once added to `deliverBubble`) *is* store-assertable.
- `clearIncludingSync` legacy-blob resurrection — untested (would fail today).

## FIX-FIRST PRIORITY LIST
1. Clear the pending-staged marker on every successful non-staged delivery in `deliverBubble` (beside `:1456-1459`) so an abandoned/orphaned marker cannot outlive a superseding send and replay a tied-revision leave/agree from an own-bubble tap — `MessagesViewController.swift:~1456`.
2. Read the marker with the conversation-derived key (drop the ivar preference) in `commitStagedSendIfNeeded` to match the set site — `MessagesViewController.swift:~301`.
3. Reorder `clearIncludingSync` to remove the sync key after `clear(key:)` — `Shared/ConversationMeetupStore.swift:~241`.
4. (Carried) Stand up a minimal TweenMessages-reachable test seam for the staged-commit wiring; until then the store-level marker-clear assertion from fix 1 is the cheapest tripwire — `TweenAppTests/`.

---

*Disposition (same session): items 1–3 implemented in the follow-up commit — `deliverBubble` clears the marker (conversation-derived key) on every successful non-staged delivery, making "cleared by any later real commit" true and the tied-revision replay unreachable; `commitStagedSendIfNeeded` reads exclusively via the conversation-derived key; `clearIncludingSync` removes the sync key after `clear(key:)` (with a regression test seeding a legacy inline-sync blob). Item 4 (TweenMessages test target seam) remains the standing gap, carried on the debt list.*
