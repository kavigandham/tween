# AUDIT REPORT — Tween — 2026-07-10 (post-push audit of c5f966d, branch codex/imessage-map-sync)

Scope: the mechanisms newly introduced in c5f966d (staged-leave deferral, `MapItemDetailHostController`, sheet/search interaction changes, reframe gating, edge-triggered search focus, button restyle) plus the cherry-picked 690bef3. Read-only; no fixes applied.

## CRITICAL (will crash, corrupt state, or break core flow)

*None found.* The staged-leave deferral, the UIKit detail container (child-VC add/remove is correctly paired, delegate is weak, off-window snapshot failure is guarded), and the button restyle (all `Variant` cases and `Tokens.Radius`/`Motion.quick` tokens exist; every call site matches) are structurally sound.

## MAJOR (wrong behavior, UX broken, data loss risk)

### Staged-leave deferral (new mechanism)
- The deferred leave commit is **missed entirely if `didStartSending` never arrives**. `deliverBubble` returns early for a staged `.leave` (no revision note, no canonical snapshot, no `commitDeliveredLeave`), and the only commit point is `didStartSending` — which is delivered only while the extension process is alive. A staged bubble can sit in the input field indefinitely; if the user dismisses the app drawer (extension deactivated, then terminated by iOS) and taps send later, peers receive and apply the leave while this device never learns it left. There is no backstop: `decodeAndCache` filters own messages (`senderParticipantIdentifier != localParticipantIdentifier`, ~line 330), so tapping their own leave bubble can never commit it, and no `didCancelSending`/reconciliation path exists. Device stays "in", tombstone unset, and its next outgoing roster re-adds it to everyone else's meetup — the split-brain the fix meant to kill, in mirror image. — `TweenMessages/MessagesViewController.swift:~271, ~1382`
  Suggested fix: persist a "pending staged leave" blob (state + revision) to the App Group at staging time; on next `willBecomeActive`, if it exists, either commit-and-clear when the input field can no longer hold it, or special-case own `.leave` in `decodeAndCache` as a commit backstop.
- The `didStartSending` leave commit has **no revision-floor guard, so a stale staged leave regresses canonical state**. Between staging and the eventual send, the floor can advance (peer bubble decoded via `didReceive`/`willBecomeActive` calls `noteRevision`). When the old staged leave is finally sent: peers reject it (`revision < floor` in `shouldAcceptInbound`), but locally `recordCanonicalSnapshot(for: state)` unconditionally overwrites the newer roster and clears the current proposal (`saveParticipants` + `clearProposalState`) with the pre-stale remaining list, and `commitDeliveredLeave` puts this device "out" — local out / peers still-in split-brain plus canonical-roster rollback (`noteRevision` itself is safely monotonic; the snapshot write is not). — `TweenMessages/MessagesViewController.swift:~284-293`
  Suggested fix: gate the commit on `state.revision >= ConversationMeetupStore.lastRevision(key:)` (skip the snapshot write and warn when stale), mirroring `shouldAcceptInbound`.

### Staged-delivery consistency (adjacent to the fixed mechanism)
- **A staged `.agree` still commits terminal state at staging time — the exact class of bug the leave deferral fixed.** In `sendAgreedPlace`, `didSend == true` includes the insert-fallback staged case, and the commit block persists `LocationCache.saveAgreedMeetup`, `ConversationMeetupStore.saveAgreed`, `setActive(true)`, and renders MEETUP SET — while the user can still delete the staged bubble (there is no `didCancelSending` override to roll back). The code's own comment claims "Gated on delivery: a rejected send must not render MEETUP SET… when no bubble ever left the device," but a staged bubble hasn't left the device either. A deleted staged agree leaves this device permanently showing an agreed meetup no peer ever saw (until snapshot TTL). — `TweenMessages/MessagesViewController.swift:~1118-1142` (same pattern, deliberately per its comment, for the staged join at ~860)
  Suggested fix: apply the same deferral pattern — for a staged `.agree`, defer the `saveAgreedMeetup`/`saveAgreed`/`received` commit to `didStartSending` (the decode-the-sent-message plumbing added for leave generalizes directly).

## MINOR (suboptimal, cleanup, hardening)

### Reframe gating (OnboardingView)
- Cold-open camera framing can be starved by the new gate. The code's own `.onAppear` comment (~line 792) notes the poll task's first tick "often runs before this" — that suppressed tick now consumes the initial App-Group load with `reframe()` gated off (`if didChange, !suppressPollDetentWrites`), and `.onAppear`'s ungated `refreshFromAppGroup()` then sees `didChange == false` and never reframes. The self-fix path (`provider.status` onChange → `reframe()`, ~line 740) usually rescues it, but with location denied/slow, restored peer pins sit off-camera; the initial `position` only frames the cached self coordinate (`init`, ~line 469). The detent nudge got an explicit onAppear escape hatch for exactly this ordering; the camera didn't. — `TweenApp/OnboardingView.swift:~3074, ~788`
  Suggested fix: call `reframe()` unconditionally in `.onAppear` after the refresh, mirroring the explicit detent nudge.

### Edge-triggered search focus (SearchCompleter)
- `appliedEditing` latches a true-edge even when the action is skipped: `context.coordinator.appliedEditing = isEditing` runs before the `bar.window != nil` check, so a programmatic `isEditing = true` that lands while the bar is off-window (first `updateUIView` after `makeUIView` runs before window attach) silently consumes the edge — the keyboard never appears until focus toggles false→true again. Currently reachable only in narrow flows (all present focus paths are user-tap or 450 ms-delayed), but it's a one-line desync trap for any future focus caller. — `TweenApp/SearchCompleter.swift:~50-53`
  Suggested fix: don't update `appliedEditing` on a true-edge that was skipped for `window == nil` (latch only when applied).

### Send-status races (extension)
- The cancelled-task tail newly copied into `sendAgreedPlace` writes a spurious failure: `willResignActive` cancels `sendTask` mid-await; the continuation still runs the tail (`didSend == false` → `sendStatusMessage = "Couldn't send the Tween message. Try again."`), and reactivation in the *same* conversation never clears `sendStatusMessage` (only conversation switches do, ~line 166) — user reopens to a stale error for a send they never failed. Pre-existing in `handleImIn`/`handleImOut`; this commit extended the pattern. — `TweenMessages/MessagesViewController.swift:~1144-1151`
  Suggested fix: `guard !Task.isCancelled` before writing the failure status (all three send tails).

### Leave reset completeness (verified, no bug — noted for the record)
- `commitDeliveredLeave`'s resets check out: the per-conversation draft is cleared via `recordCanonicalSnapshot(.leave)` → `clearProposalState` → `clearDraft`, both leave paths hit it, and the host's `commitLeaveLocally` mirrors it (including the new `pendingProposal`/`OutgoingDraftStore` clears). The `sendStatusMessage != stagedDeliveryStatus` check in `handleImOut` cannot race stale status because the method overwrites the status at entry and everything is MainActor-serial.

## ARCHITECTURE NOTES
- The leave commit now has two authorities (`handleImOut` direct path, `didStartSending` staged path) sharing `commitDeliveredLeave` — good factoring — but host (`commitLeaveLocally`) and extension (`commitDeliveredLeave`) still implement the same leave semantics separately with subtle drift risk (host notes the revision pre-send via `noteOutgoingRevision`; extension defers it).
- `MapItemDetailHostController` is correct child-VC containment (add/constrain/didMove, willMove/remove on rebuild, weak delegate re-wired through `didSet`); concurrent rebuilds mid-fade stack snapshots benignly. `updateItem`'s `!==` identity check is right for the stable `mapItem` instance SwiftUI passes.
- The `presentationContentInteraction(.resizes)` + `scrollDismissesKeyboard(.interactively)` + collapse-drops-focus trio is internally consistent; the new detent onChange cannot fight `focusSearchPanel()` (focus raises the detent *away* from peek before the drop condition can fire).
- `didStartSending` now runs `presentUI` on every outgoing send regardless of state change — harmless churn, but it's the third unconditional `presentUI` in the lifecycle path.

## LEGACY DEBT INVENTORY
- `etaFromA`/`etaFromB` legacy accessors still drive `ETAChip(etaFromA:etaFromB:)` and `driveLabel` in `TweenApp/SpotDetailCard.swift:~287, ~342` (labels assume "my leg" is A).
- `legacyLocalParticipantID()` filtering persists in `sendAgreedPlace` (`MessagesViewController.swift:~1064`); the `didStartSending` leave commit's `senderID == localParticipantID()` check silently skips leaves staged by a pre-stable-ID build.

## TEST COVERAGE GAPS
- Staged-leave deferral end-to-end: `deliverBubble` early-return, `didStartSending` decode-and-commit, and `commitDeliveredLeave` resets — zero coverage (nothing in TweenAppTests references any of it; the view controller is untested generally, but the revision/snapshot halves are testable via `ConversationMeetupStore`).
- Stale-revision staged leave vs `noteRevision`/`shouldAcceptInbound` floor (the MAJOR #2 scenario) — untested.
- `NativeSearchBar` edge-trigger coordinator state (`appliedEditing`) — untested (SearchCompleterTests covers only the completer).
- `MapItemDetailHostController` rebuild/child-VC lifecycle — untested (acceptable; UIKit-bound).
- 690bef3/project.yml `GENERATE_INFOPLIST_FILE` for test targets — consistent with the pbxproj; no issue.

## FIX-FIRST PRIORITY LIST
1. Backstop the staged-leave commit for the extension-terminated case (persisted pending-leave marker + own-`.leave` decode backstop) — `MessagesViewController.swift`.
2. Revision-floor guard on the `didStartSending` leave commit so a stale staged leave can't roll back canonical roster/proposal state — `MessagesViewController.swift:~284`.
3. Extend the staged-commit deferral to `.agree` (and reconsider the staged join), or implement `didCancelSending` rollback — `MessagesViewController.swift:~1118`.
4. Unconditional `reframe()` in `.onAppear` to close the cold-open camera starvation — `OnboardingView.swift:~788`.
5. `Task.isCancelled` guard before failure-status writes in the three send tails — `MessagesViewController.swift`.
6. Latch `appliedEditing` only when the focus action was actually applied — `SearchCompleter.swift:~50`.

---

*Disposition (same session): items 1–6 all implemented in the follow-up commit — pending-staged-send marker in `ConversationMeetupStore` + `commitStagedSendIfNeeded` (marker- and revision-floor-gated, shared by `didStartSending` and the own-bubble decode backstop), staged `.agree` deferral via `commitDeliveredAgree`, cold-open `reframe()`, cancelled-task status guards, applied-only focus latch, plus store-level tests for the marker.*
