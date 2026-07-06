# Diagnostic — 2026-07-06 (post-redesign re-audit)

Second full audit, run after all ten July-audit fixes and the Apple-Maps home
surface landed (`5898ebc`). Three independent review passes (hard-constraint
compliance, distributed sync/state, host UI flows) plus a runtime pass.
Every **critical** below was re-verified by hand against the source.

**Runtime pass: clean.** Fresh launch, 68 MB steady-state / 0% CPU, no crash
reports, no app-originated errors or faults in the unified log (only benign
simulator GeoServices/Metal chatter). 96/96 unit tests, 6/6 UI tests green.

**Code pass: the extension's negotiation machinery is solid; the host app's
send paths are the weak spot.** The extension gates every state commit on
`didSend` — the host app doesn't, and that asymmetry produces most of the
criticals.

---

## CRITICAL (fix before device testing — these will burn the two-phone run)

### D1. Host bubbles use `tween://` as the `MSMessage.url` scheme
`TweenApp/OnboardingView.swift:1927` — `composeTweenMessage`, the single
composer behind every host-app send, builds the bubble URL with
`encodedURL(scheme: "tween", host: "m")`. Hard constraint (and Apple's
Messages contract) requires `https`/`file`; the extension path is compliant
(`https://tween.app/m`). Recipients without the app installed, and macOS
Messages, resolve the bubble through the URL — a custom scheme dead-ends.
**Fix:** call `encodedURL()` (https default); keep `tween://` only for the
internal App Group deep-link persistence.

### D2. Host commits "agreed" state before the composer opens — cancel = split-brain
`OnboardingView.swift:2954-2960` writes `saveAgreed`/`saveProposed` *before*
presenting `MessageComposeSheet`; the sheet result handler (:488-496) only
runs `onSent` on success and rolls back nothing on cancel/failure. Cancel the
composer → your device renders MEETUP SET for an agreement the peer never
received. The extension parks the same commits behind `didSend` — mirror that.

### D3. Host `leave()` commits before send, and its payload carries no identity
`OnboardingView.swift:1859-1895` — roster cleared, tombstone set, agreement
wiped *before* compose; compose can return nil or be cancelled → you're
locally "out" with no leave bubble in the chat. The leave state also omits
`senderID` and `revision`, so recipients can't order it against other bubbles.

### D4. Leave→rejoin nukes the roster for the whole group
`TweenMessages/MessagesViewController.swift:864-865, :1271-1275` — leaving
clears the roster to `[]`; a later rejoin (`handleImIn` →
`nextParticipantList` :507-521) builds `[me]` at a fresh top revision, and
recipients' `decodeAndCache` (:353-364) replaces their roster verbatim →
everyone else silently dropped; on their devices `isLocalUserInCurrentConversation`
flips false while the host still says opted-in. **Fix:** union-merge inbound
invite rosters instead of verbatim replace (or preserve "others" across leave).

### D5. Location-denied taps dead-end forever ("Finding you..." spinner)
`Shared/LocationProvider.swift:54-66` — when already denied, `requestOnce()`
sets `.denied → .requesting → .denied` synchronously in one run-loop turn;
SwiftUI coalesces that to *no observable change*, so the `.onChange(of:
provider.status)` in `OnboardingView.swift:537-570` — the only reset for
`awaitingImIn` / `pendingLocationAction` — never fires. "I'm in" spins
forever; parked Agree/Send/search intents never fire (or fire much later on
an unrelated fix). Re-granting in Settings doesn't recover until relaunch
(`LocationProvider.swift:107` only re-requests when status == `.requesting`).
**Fix:** deliver the already-denied result via an async settle (like the
delegate path) and clear parked intents inline on synchronous denial.

---

## WARNING (real bugs, survivable short-term)

**Sync / state**
- **W1. Failed sends burn revisions** (`MessagesViewController.swift:424-429`):
  own revision is recorded before delivery; two failed sends in a row make the
  peer's genuinely-new bubbles decode-reject as stale. Note revision on
  `didSend` only.
- **W2. Global revision counter, ties accepted** (:315 `>=`): concurrent mints
  from two senders collide; outcome is tap-order-dependent and can resurrect a
  leaver group-wide (tombstone only protects the leaver's own device).
- **W3. Host `tween://` deep-link path skips the revision guard and tombstone
  filter** (`OnboardingView.swift:2776-2801`) — opening an old link resurrects
  a stale roster. Apply the same gating as `decodeAndCache`.
- **W4. Stale-coordinate laundering**: `LocationCache.save` re-stamps
  `timestamp: Date()` (`Shared/LocationCache.swift:49`);
  `autoJoinForOutgoingMessage` / `setNeedsRide` feed it coords of any age with
  `isActive: true`, defeating the 5-min freshness window. Extension send paths
  (`MessagesViewController.swift:899, :950, :1050, :1089`) also embed
  `loadSelf()` ungated.
- **W5. `setNeedsRide` silently rejoins a left user**
  (`OnboardingView.swift:1949-1959`) — clears the tombstone via
  `saveLocalParticipant`.
- **W6. Cross-process read-modify-write on the snapshot blob**
  (`Shared/ConversationMeetupStore.swift:159-239`): each write is atomic but
  load→mutate→save from both processes last-writer-wins the whole snapshot
  (can lose `lastRevision`/`localUserLeft`/`pendingDraft`).
- **W7. Draft handoff has no rollback/TTL/conversation binding**
  (`OnboardingView.swift:2108-2111`, `MessagesViewController.swift:219-227`):
  cancelled host drafts are adopted by whichever conversation opens next.
- **W8. New proposal doesn't clear a stale agreement**
  (`ConversationMeetupStore.swift:179-187` clears only for `.counter`) — host
  shows old MEETUP SET while the extension shows the new proposal.
- **W9. Host payloads never carry revisions** (sendToChat, agree, leave,
  ride) — decoded as legacy "trust the tap" forever.

**Constraints**
- **W10. Extension ranking cap is 10, not the mandated 5**
  (`MessagesViewController.swift:669` uses `FairnessRanker.recommendedCap`,
  which returns 10 for 2 people; the declared `rankCap = 5` at :81 is dead).
  Clamp with `min(rankCap, recommendedCap)`.
- **W11. Multi-key App Group writes of related state**
  (`LocationCache.swift:49-53, :71-75, :145-152, :197-203`): coord blob and
  active flag written as two keys — a cross-process reader between the writes
  sees fresh coord + stale flag. Fold the flag/timestamp into the blob.
- **W12. Contact PII in the unencrypted App Group**
  (`Shared/TweenFriend.swift:26-46`): roster persists name + CNContact ID +
  phone/email handle; constraint says coordinates and preferences only.
  Store the CN identifier and re-fetch handles at compose time, or document
  the exception.

**UI**
- **W13. Rename Friend alert can't present** — attached to the sheet host
  that is already presenting the Friends sheet (`OnboardingView.swift:522-527`
  vs :935-938). Move the alert inside the Friends sheet.
- **W14. Toasts render behind the Friends sheet** (:656, :1211-1225) — "no
  phone number", "ride ready", "tap I'm in first" are invisible; buttons look
  like no-ops. Overlay toasts on the topmost presented surface.
- **W15. Stale `suppressNextQueryChange` swallows the clear (x) gesture**
  (:2331-2335, :2494-2503 vs :2303-2306): arming the flag without an actual
  text change leaves ghost results/pins behind an empty field. Only arm when
  the assignment changes `searchText`.
- **W16. "Searching nearby..." spinner never resolves on completer failure**
  (`SearchCompleter.swift` failure path just empties results). Track a
  resolved/failed flag; render a "no matches" row.
- **W17. Gated search leaves the category chip lit with zero results**
  (`selectCategory` sets the chip before `canSearch` fails; failure path never
  clears it).
- **W18. Ranking truncation orphans the selection** (:2429-2455): list shrinks
  from ~25 raw hits to the ranked 8 mid-read; a selection past the cap keeps
  its floating card but loses its pin. Re-validate `selectedResult` against
  `displayedItems`.
- **W19. First-launch location prompt fires on top of the tutorial** (:598 →
  :1854-1857). Kick the initial request from `dismissTutorial` instead.
- **W20. Dark-mode contrast on brand fills fails WCAG** (white on #29C7C7 ≈
  2.1:1) — Friends circle, I'm-in CTA, selected chips, Send buttons. Use a
  near-black foreground on dark-mode brand (Apple does the equivalent).

## INFO / cleanup
- The sanctioned interactive expanded map is entirely dead code right now:
  `usesStaticMapForCurrentState` is hardcoded `true`
  (`Shared/TweenViews.swift:1193-1195`), so the fallback machinery is
  unreachable and result-row "fly the map" taps silently no-op. Matches the
  standing T10 decision — re-enable after device profiling or delete.
- `panelTab`/`HomePanelTab` is write-only dead state after the tabs removal —
  safe to delete (8 write sites, zero reads).
- Bridged `UISearchBar` doesn't adopt Dynamic Type; 44pt Friends circle
  overflows at AX text sizes.
- `tween://search` deep link doesn't dismiss an open Friends sheet before
  focusing the field; contacts-picker Cancel exits to the map instead of back
  to Friends.
- Identity: no detection for duplicated `stableID` after backup-restore
  (peer classified as "self", consensus unreachable). Edge case; detect own
  ID arriving from a remote sender and re-mint.
- Extension: `isRanking` isn't reset in `willResignActive` (stuck "Finding
  fair spots" possible on reactivation); 24h TTL clear also wipes the
  tombstone (old-bubble taps resurrect).

## Verified solid
Extension commit-on-delivery discipline; revision guard against stale bubble
taps; tombstone filtering on the leaver's device; conversation-scoping of
received state; single-key atomic JSON writes (per key); Darwin-notification
lifecycle; task cancellation in `willResignActive`; snapshotter-only compact
bubble path (8s timeouts); When-In-Use-only location with retained manager;
no keyboard anywhere in the extension; no API keys, no network calls, no
third-party code; `@Observable` throughout; `NativeSearchBar` bridge (no
focus loops, clean dismissal); detent choreography; `project.yml` compiles
all Shared files into both targets.

## Recommended order
1. D1 (one-line scheme fix) → D2/D3 (host commit-on-`.sent`, mirrors the
   extension pattern) → D5 (async denied settle) → D4 (roster union-merge).
2. W1/W9 (revision hygiene) and W10 (rank cap) — small, high-leverage.
3. UI warnings W13-W20 as a polish pass.
4. Then the two-phone TODO_VERIFY.md run — D1-D4 all directly affect what
   that run would test, which is why they're worth fixing first.
