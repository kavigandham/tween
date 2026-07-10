# AUDIT REPORT — Tween — 2026-07-10 (post-push audit of 9db000b, branch codex/imessage-map-sync)

Scope: adversarial verification of the six mechanisms 9db000b introduced per the c5f966d audit disposition (pending-staged-send marker, `commitStagedSendIfNeeded`, `commitDeliveredAgree`, cancelled-task status guards, cold-open `reframe()`, `appliedEditing` latch, new store tests) plus a regression sweep of the rest of the diff. Read-only; no fixes applied. Working tree verified identical to 9db000b.

## CRITICAL (will crash, corrupt state, or break core flow)

### Pending-staged-send marker (new mechanism)
- **The marker is never set. `setPendingStagedSend` is called with a non-nil type nowhere in production code — only cleared (`MessagesViewController.swift:304, 1003, 1195`) and set in tests. `deliverBubble`'s staged branch (`:1439-1441`), where the design comment says the marker originates ("deliverBubble defers those commits"), contains no `setPendingStagedSend(.leave, …)` call. `commitStagedSendIfNeeded`'s first guard (`:302`) therefore always fails, making the entire commit mechanism — both the `didStartSending` path and the decode backstop — dead code.** — `TweenMessages/MessagesViewController.swift:~1439`, `Shared/ConversationMeetupStore.swift:~360`
  Consequences, in decreasing order of severity:
  1. **Staged `.leave` now never commits, ever — a regression from c5f966d**, which committed inline in `didStartSending`. Staging is the *routine* delivery path (`deliverBubble`'s own comment: direct send "rejection here is expected" because sends run seconds after the tap). So on most leaves: peers receive and apply the departure while this device keeps its roster membership, never sets `localUserLeft`, never clears the agreed meetup/draft/spots, and its next outgoing bubble re-adds it to everyone's meetup. This is the exact split-brain both prior audits targeted, now on the common path instead of the extension-killed edge case.
  2. Staged `.agree`'s deferred commit (`sendAgreedPlace:1164-1166` skips `commitDeliveredAgree` when staged) never runs: `LocationCache.saveAgreedMeetup`, `setActive(true)`, tombstone clear, participant snapshot, and the `received` update are all lost. After tapping send on a staged agree the extension still renders Agree/Change (the "agreer sees MEETUP SET" promise is broken even with the extension alive), and the host never sees this device activate.
  3. The commit-message claims ("staged .leave/.agree bubbles now commit via commitStagedSendIfNeeded from BOTH didStartSending and a decode backstop") are false as shipped; "129 unit tests green" passed because the new tests exercise only the store round-trip, not the wiring.
  Suggested fix: in `deliverBubble`'s `stagedInsert` branch, call `ConversationMeetupStore.setPendingStagedSend(state.messageType, key: conversationKey ?? Self.conversationKey(for: conversation))` (use the conversation-derived key so a nil `conversationKey` ivar can't skip it), and add one integration-shaped test that fails when the setter is absent.

## MAJOR (wrong behavior, UX broken, data loss risk)

### Staged-agree deferral is incoherent even once the marker is wired
- `deliverBubble`'s staged early-return covers **only `.leave`** (`if stagedInsert, state.messageType == .leave`, `:1439`). A staged `.agree` falls through to `noteRevision` + `recordCanonicalSnapshot` (`:1444-1448`) at staging time — which for a fully-agreed state writes `ConversationMeetupStore.saveAgreed`. Two effects: (a) **a deleted staged agree still strands MEETUP SET** — `willBecomeActive`'s snapshot restore (`:196-198`) and `effectiveReceived`'s `agreedCandidate` (`:566-567`) both read the store's `agreedState`, so the terminal state resurrects on next open with no peer ever having seen the bubble — the precise bug the commit message says this fixed; (b) the revision floor is burned for a bubble that may never send, so the peer's genuinely-new bubble minted at the same revision is rejected by the W2 tie-break (different sender at the floor). The half of the deferral that lives in `sendAgreedPlace` (skipping `commitDeliveredAgree`) only defers the `LocationCache`/`received` half. — `TweenMessages/MessagesViewController.swift:~1439`
  Suggested fix: extend the staged early-return to `.agree` (`state.messageType == .leave || state.messageType == .agree`) so the snapshot + floor defer with the rest of the commit.

## MINOR (suboptimal, cleanup, hardening)

### Marker lifecycle (relevant to the wiring fix, latent today)
- `pendingStaged.<key>` survives both the TTL `clear(key:)` and the documented "full wipe" `clearIncludingSync` (`Shared/ConversationMeetupStore.swift:227-239` remove snapshot/draft/sync keys only). Once the setter exists, a stale marker outliving a hard reset is dangerous: the reset zeroes the revision floor, so tapping any *old* own `.leave` bubble (its revision now ≥ the floor) matches the marker and commits a departure the user never initiated; rev-less legacy own bubbles bypass the floor guard entirely (`commitStagedSendIfNeeded:305` skips when `state.revision == nil`). — `Shared/ConversationMeetupStore.swift:~236`
  Suggested fix: remove the pendingStaged key in `clear(key:)`/`clearIncludingSync` (the marker is meetup-generation-scoped, not sync-scoped), and treat a nil-revision state as stale in `commitStagedSendIfNeeded`.
- The absence of `MeetupSync.post()` in `setPendingStagedSend` is safe as designed: no host-app code reads the marker (verified repo-wide), and during the staged window the meetup state is deliberately uncommitted, so the host correctly renders pre-send state. No action needed; keep the "extension-private" doc comment enforced if the host ever grows a reader.

### NativeSearchBar appliedEditing latch
- The preserved off-window focus edge is only applied on the next `updateUIView`, and nothing fires that on window attach — the edge can sit unapplied until *any* re-render of the sheet re-evaluates the representable. In practice the flows that programmatically focus (450 ms-delayed `focusSearchPanel`, which also changes the detent and forces a re-render) make starvation nearly unreachable, and the failure mode is strictly better than the pre-fix swallowed edge (delayed vs. lost). — `TweenApp/SearchCompleter.swift:~51-62`
  Suggested fix (hardening only): have the Coordinator apply a pending edge from `didMoveToWindow` (custom UISearchBar subclass) or retry once via `DispatchQueue.main.async`.

## VERIFIED CLEAN (focused checks that found no bug)

- **Key collisions:** `conversationMeetup.pendingStaged.<key>` cannot collide with snapshot/sync/draft keyspaces — conversation keys are base64url with no dots (`ConversationMeetupStore.swift:123-124, 154-161`).
- **Backstop reachability:** the own-message commit path is reachable only via `willBecomeActive(selectedMessage:)` (tapping the own bubble); `didReceive` never delivers own messages on the same device — acceptable for a backstop whose primary path is `didStartSending`. Consumed-before-stale-check marker semantics correctly prevent double commits between `didStartSending` and a later own-bubble tap.
- **Commit-vs-restore ordering in `willBecomeActive`:** `decodeAndCache` (and thus the backstop commit) runs at `:181` *before* the snapshot load at `:182`, so the restore reads post-commit state; a committed agree sets `received` non-nil (restore gate skips), a committed leave leaves a cleared proposal state (nothing resurrects). Correct once the marker is wired.
- **`commitDeliveredAgree` setActive semantics:** `state.senderCoordinate != nil` is behaviorally equivalent to the old `activateSelfOnDelivery` — the cached-coordinate branch (`:1085-1086`) requires `LocationCache.isActive` already true, so `setActive(true)` is a no-op there; the nil-coordinate branch stays untouched. `received = effectiveReceived(decoded: state)` is correct from the backstop path (`conversationKey` is assigned at `:158` before `decodeAndCache` runs).
- **Cancelled-task guards:** no genuine failure is silenced. `deliverBubble`'s catch stamps its own failure status (`:1451-1454`); every non-cancellation early-return (`activeConversation` nil, `encodedURL` nil) reaches the tail with `Task.isCancelled == false` and still sets the banner.
- **`onAppear reframe()`:** empty-coords case is a guarded no-op (`OnboardingView.swift:3114`); the agreed-meetup branch centers on the place. It runs at appear time, before any user pan, so it cannot yank a user-held camera; subsequent background writes stay behind the `suppressPollDetentWrites` gate (`:3080`).

## ARCHITECTURE NOTES
- The staged-send commit now has three code sites that must stay in lockstep (deliverBubble's defer set, `commitStagedSendIfNeeded`'s switch, and the two per-type `commitDelivered*` methods); the `.leave`-only early-return vs. the leave+agree switch is exactly the drift this shape invites — consider a single `deferredCommitTypes: Set<MessageType>` constant consulted by both.
- The marker doc comment's safety argument ("deleting the staged bubble leaves the marker set — harmless, because commits are gated on the revision floor") is only true while `clear`/hard resets can't regress the floor below an old bubble's revision; see MINOR above.
- The staged `.invite` join (`handleImIn:~900`) still commits at staging time — previously dispositioned as accepted; it now stands as the lone staged type with stage-time commit semantics, worth a comment cross-referencing the leave/agree deferral.

## LEGACY DEBT INVENTORY
- `etaFromA`/`etaFromB` legacy accessors still drive `ETAChip` and `driveLabel` — `TweenApp/SpotDetailCard.swift:287, 342, 539` (unchanged by 9db000b).
- `legacyLocalParticipantID()` filtering persists at `MessagesViewController.swift:503, 618, 1103`; `commitStagedSendIfNeeded` (like the c5f966d inline commit before it) never consults it, so a bubble staged by a pre-stable-ID build would fail the marker's messageType match only if types differ — benign but undocumented.

## TEST COVERAGE GAPS
- **No test exercises the production wiring of the staged-send mechanism** — the two new store tests (`ParticipantCodecTests.swift:696-716`, assertions themselves correct, setUp properly wipes the suite) pass with the setter entirely absent from production code, which is precisely how the CRITICAL shipped green. A `commitStagedSendIfNeeded`-level test (marker set → commit applies; marker absent → no-op; stale revision → skip) is the missing tripwire; the store-only halves are testable without `MSConversation`.
- Revision-floor guard behavior for nil-revision staged states — untested.
- Marker survival across `clear(key:)`/`clearIncludingSync` (currently surviving, arguably wrongly) — untested and unasserted either way.
- Staged-agree stage-time `saveAgreed` leak (MAJOR above) — untested.

## FIX-FIRST PRIORITY LIST
1. Set the marker: `setPendingStagedSend(state.messageType, key:)` in `deliverBubble`'s `stagedInsert` branch, keyed off the conversation parameter — without this, staged leaves never commit and 9db000b is a net regression from c5f966d — `MessagesViewController.swift:~1439`.
2. Extend the staged early-return to `.agree` so `recordCanonicalSnapshot`/`noteRevision` defer with the rest of the agree commit — `MessagesViewController.swift:~1439`.
3. Add a wiring-level test for `commitStagedSendIfNeeded` (and a staged-path test asserting no `agreedState` is persisted at staging time) so a dead mechanism can't ship green again — `TweenAppTests/`.
4. Clear the pendingStaged key in `clear(key:)`/`clearIncludingSync`, and reject nil-revision states in `commitStagedSendIfNeeded` — `Shared/ConversationMeetupStore.swift:~227`, `MessagesViewController.swift:~305`.
5. (Hardening) Apply a pending focus edge on window attach in `NativeSearchBar` — `TweenApp/SearchCompleter.swift:~51`.

---

*Disposition (same session): items 1, 2, and 4 implemented in the follow-up commit — the marker is now set in `deliverBubble`'s staged branch (conversation-derived key), the staged early-return covers `.leave` and `.agree` (deferring `noteRevision`/`recordCanonicalSnapshot` for both), `clear(key:)` (and via it `clearIncludingSync`) drops the marker, and `commitStagedSendIfNeeded` rejects rev-less states outright. Item 3 partially closed: store-level test asserts the marker dies with `clear`/`clearIncludingSync`; a true wiring-level test needs a TweenMessages test target (tracked as a known gap — the extension is unreachable from `@testable import TweenApp`). Item 5 deferred as hardening (failure mode is delayed-not-lost focus). Root cause of the CRITICAL: a three-edit batch failed mid-session on a stale file-read check and only two edits were re-applied — wiring was grep-verified end-to-end before this follow-up push.*
