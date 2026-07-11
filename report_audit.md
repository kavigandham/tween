# AUDIT REPORT — Tween — 2026-07-10 (post-push audit of 42fdc68)

Scope: adversarial verification of the three device-feedback fixes in 42fdc68 — the membership gate on peer projection, the results-drag smoothness work (LazyVStack / scrollDisabled / lighter card shadows), and the TweenPin redesign — plus a sweep of the rest of the 5-file diff. Read-only; no fixes applied.

## CRITICAL (will crash, corrupt state, or break core flow)

*None found in this diff.*

## MAJOR (wrong behavior, UX broken, data loss risk)

### Membership gate — the legitimate "not yet a member" flow is caught in the net
- The new gate (`localIsMember = roster.contains { $0.matches(localContext) } || LocationCache.isOptedIn`) nils `peerCoordinate` for a recipient who hasn't joined yet — but that is exactly the state a pinged friend is in when the OTHER side replies first. The reply banner explicitly requires `peerCoordinate != nil` (`OnboardingView.swift:~1070`), so "Your friend replied N min ago" no longer shows until the local user joins — the nudge existed precisely to prompt joining. The `peerDistanceText` chip (`:~2072`) and dual-ETA preview ranking also vanish for not-yet-members. — `TweenApp/OnboardingView.swift:~2987`
  Suggested fix: gate on the per-conversation leave tombstone (`ConversationMeetupStore.localUserLeft(key:)`) rather than on membership/opt-in, so "left" hides peers but "not yet joined" keeps the inbound preview.
- Worse, `handleIncomingURL` still sets `peerCoordinate` directly (`:~3226-3229`; roster-merge projection at `:~3281`), and `LocationCache.savePeer` fires `MeetupSync.post()` — so the very next refresh runs the gate and nils it again. For a non-member tapping a fresh invite, the framed-both camera and peer state now appear for one beat and then flicker away. — `TweenApp/OnboardingView.swift:~3226`
  Suggested fix: same tombstone-based gate; fresh inbound URL state from a non-departed conversation must survive the refresh.

### Leave via the extension leaves stale dual-ETA chips in the app
- `rankedSpots = []` was added only to `commitLeaveLocally` — the app-side leave. When the user leaves from the iMessage extension and returns to the host app with a results list open, `refreshFromAppGroup` nils the peer projections and flips `isUserIn` but never touches `rankedSpots`, so the open results keep showing "You X min | Sam Y min" chips scored against the meetup just left — the exact device-feedback bug, surviving on the other leave path. — `TweenApp/OnboardingView.swift:~3057`
  Suggested fix: clear `rankedSpots` inside `refreshFromAppGroup` when the gate transitions to false.

### Global `isOptedIn` escape hatch can resurrect the stale peer cross-conversation
- `LocationCache.isOptedIn` is a single global flag, while the roster is scoped per `lastActiveConversationKey`. Opted in for conversation A, then opening the extension on conversation B (where the user previously left; B's snapshot deliberately keeps the remaining friends — D4) makes the host app project B's departed friend as `peerCoordinate` again: `localIsMember` passes via the A-scoped flag against a B-scoped roster. The per-conversation truth (`ConversationMeetupStore.localUserLeft(key:)`) exists and is already consulted elsewhere in this file but not here. — `TweenApp/OnboardingView.swift:~2987`
  Suggested fix: consolidate the gate on the tombstone.

### TweenPin — SELF needing a ride renders as a friend avatar
- Both self-pin call sites choose `.rideNeeded` for the local user, and the redesigned `.rideNeeded` renders the *people-avatar* family: a `pinFriend`-filled circle with a generic `person.fill` glyph plus a car badge. Toggling "I need a ride" now swaps your blue location dot for a pin visually identical to a friend's avatar — the redesign's own family taxonomy ("You = location dot; People = avatars") is violated, and on a group map the user can no longer find themselves. — `Shared/TweenPin.swift:~106,134-137`
  Suggested fix: render self+ride as the selfDot with the car badge (badge as an orthogonal overlay, not a role family switch).

## MINOR (suboptimal, cleanup, hardening)

### `scrollDisabled` below the top detent strands content on shorter devices
- At `.fraction(0.45)` the idle stack (I'm-in/Leave button + status + discovery rows ≈ 450+ pt) exceeds the visible slice on smaller phones, and it previously scrolled; now the bottom "Recent Spots" rows are unreachable until the user drags to 0.90. Also kills VoiceOver's three-finger scroll at non-top detents. — `TweenApp/OnboardingView.swift:~1557`
  Suggested fix: disable scrolling only for the heavy `.results` state (the state the fix targeted).

### Comment claims avatar parity with the bubble renderer that doesn't exist
- `TweenPin.initials(for:)` says it's shared "so the host map, extension map, and bubble renderer agree on avatars", but `BubbleImageRenderer.drawMarker` still rasterizes the legacy halo-dot style and takes no initials — bubble images and live maps now speak two different pin languages. — `Shared/TweenPin.swift:~86`
  Suggested fix: either port the avatar/dot families to `drawMarker` or correct the comment.

### Legacy-peer fallback avatar shows a bare "F"
- The `localIsMember`-but-empty-roster branch keeps `newPeerName = "Friend"`, and the map call site derives initials from it, so the legacy single-peer path draws an avatar lettered "F" as if "Friend" were a name. — `TweenApp/OnboardingView.swift:~2998,490`
  Suggested fix: pass nil initials when the name is the "Friend" placeholder so the person-glyph fallback renders.

## VERIFIED CLEAN (focused checks)

- `didChange` diffing repaints correctly when the gate nils projections; poll path skipping `reframe()` is the pre-existing documented self-jump gate.
- All downstream peer consumers (`runSearch`, `midpoint`, `peerDistanceText`, framing helpers, `searchRegion`) degrade sanely to self-only mid-session.
- `pendingProposal` and proposal cards come from `scopedSnapshot.proposedState`, not the gated projections — they still surface for a not-yet-joined recipient.
- TweenPin call sites compile-consistent; no dangling `pulses`/halo references; `TweenAppTests` Role accessibility assertions unchanged; `initials(for:)` edge cases (empty/emoji/multi-word) safe.
- LazyVStack conversion has no eager-layout dependencies; `compositingGroup` preserves accessibility children and tap targets; `Shadow.card` properly wired.
- `searchViewMode == .map` (sheet at peek) and `.suggesting` (separate ScrollView) unaffected by the scroll gate; `.fraction(0.90)` equality matches the declared detent set exactly.

## ARCHITECTURE NOTES
- The projection gate encodes membership as `roster ∨ global-flag` while the system's actual source of truth for "I left HERE" is the per-conversation `localUserLeft` tombstone — three of the four MAJOR findings are consequences of that mismatch.
- `avatar` hardcodes `pinFriend`, demoting `Role.fill` for person roles to badge-tint duty — `fill` is now a semi-live API whose meaning differs per role family.

## LEGACY DEBT INVENTORY
- Unchanged: `etaFromA`/`etaFromB` accessors in `SpotDetailCard.swift:287, 342, 539`; the legacy single-peer projection (`loadPeer`/`isPeerActive`) is still the fallback and is still written on every `saveParticipantSnapshot` — including by `commitLeaveLocally`, which marks the *departed* friend's coord peer-active (masked by the gate).

## TEST COVERAGE GAPS
- No test exercises the projection gate (member→non-member flip, opt-in escape hatch, ping-recipient flow).
- `TweenPin.initials(for:)` zero coverage; `rankedSpots` reset on leave untested on either path; Role accessibility test covers 4 of 8 roles.

## FIX-FIRST PRIORITY LIST
1. Rebase the projection gate on `ConversationMeetupStore.localUserLeft(key:)` — restores not-yet-joined previews and closes the cross-conversation hole — `OnboardingView.swift:~2987`.
2. Clear `rankedSpots` in `refreshFromAppGroup` when the gate flips, covering extension-side leaves — `OnboardingView.swift:~3057`.
3. Self+needs-ride renders as selfDot + car badge overlay — `TweenPin.swift`, both call sites.
4. Scope `scrollDisabled` to the results state — `OnboardingView.swift:~1557`.
5. Suppress the "F" placeholder initial; fix the drawMarker parity comment — `OnboardingView.swift:~490`, `TweenPin.swift:~86`.

---

*Disposition (same session): items 1–5 all implemented in the follow-up commit — the gate now keys exclusively on the per-conversation `localUserLeft` tombstone (not-yet-joined recipients keep the reply banner/framed pins; conversation A's opt-in can't resurrect conversation B's departed roster; the handleIncomingURL set→refresh-nil flicker is gone because a non-departed conversation passes the gate); `refreshFromAppGroup` clears `rankedSpots` whenever the tombstone hides peers (extension-side leave now resets an open results list); `TweenPin` gained an orthogonal `needsRide` badge so self stays in the location-dot family (call sites updated in both targets, `.rideNeeded` role kept for compatibility); `scrollDisabled` scoped to `searchState == .results`; the "Friend" placeholder passes nil initials; the initials doc comment no longer claims bubble-renderer parity. Added tests: all 8 Role accessibility names + `TweenPin.initials` edge cases.*

---

*Disposition of the 2b894b0 audit (same session): all five fix-first items implemented in the follow-up commit — the pin's accessibility label announces ", needs a ride" whenever the badge shows (no duplicate for the legacy `.rideNeeded` role); `handleIncomingURL`'s direct `peerCoordinate`/`savePeer` writes and merged-roster projection are gated on the same tombstone the refresh gate reads (departed-user flicker closed); the projection gate is provenance-matched (`scopedSnapshot != nil`) so a drawer-peek at a long-left thread can't blank a different meetup's peers loaded from the global fallback; a nil-key leave neutralizes the legacy global mirrors (`clearParticipants` + `setPeerActive(false)`) since the gate defaults open where no tombstone can be written; and the tombstone clear also dismisses an open `.spot` sheet that carries captured ranked ETAs (solo sheets with `ranked == nil` survive).*
