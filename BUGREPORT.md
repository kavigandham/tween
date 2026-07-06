# Tween Bug Report — 2026-07-06 triage

Scope: full codebase at `bb62f43`. No fixes applied. Severity order: crash / logic / UI / risk-only. **No crash-severity bugs found.** Bugs whose fix touches `effectiveReceived`, `decodeAndCache`, or the negotiation flow are flagged **[SIGN-OFF]** and will not be fixed without explicit approval.

## LOGIC

**T1 — Old-bubble resurrection**
- `TweenMessages/MessagesViewController.swift:246-258` (decodeAndCache roster replace)
- Symptom: after leaving (or any newer state), tapping an OLDER bubble re-adopts its roster verbatim — the leaver re-appears "in" and re-pinned on that device.
- Severity: logic
- Root cause: every bubble is a canonical roster snapshot with no ordering info, and decode trusts whichever bubble was tapped.
- Fix: needs ordering — a monotonic revision (protocol change to the URL payload) or a device-local "I left" tombstone consulted at decode. **[SIGN-OFF: decodeAndCache + negotiation flow + protocol]** Not additive.
- Blast radius: all decode paths, cross-build bubble compatibility, every roster consumer.

**T2 — Propose/counter/draft paths commit state before send**
- `sendChosenSpot` (MessagesViewController.swift:742-744): roster committed pre-send, no revert on failure.
- `sendCounter` (:866-868 roster; :~893 `LocationCache.clearAgreedMeetup()` + `saveProposed` pre-send): a failed counter erases the local MEETUP SET while peers keep theirs — device divergence.
- `sendDraft` (:~910-918): `OutgoingDraftStore.clear()` + store draft clear + `self.draft = nil` pre-send — a failed send loses the staged spot entirely (user must redo the host-app handoff).
- Severity: logic
- Root cause: same commit-before-delivery family as the July-5 fixed handlers; these three sites were left as-is.
- Fix: move commits/clears into the delivery-gated path (mirror `handleImIn`/`handleImOut`/`sendAgreedPlace`). Edits working methods (NOT the protected trio) using the already-established pattern.
- Blast radius: `sendBubble`'s shared didSend block, `recentlySentSpotName`, draft re-offer flow.

**T3 — First-run "I'm in" dies under the permission alert**
- `MessagesViewController.swift:1091-1105` (`acquireLocation`, 50×100 ms poll) + `LocationProvider.requestOnce`
- Symptom: on a fresh install the location permission alert outlives the 5 s poll (and can resign the extension, cancelling `sendTask`) → first tap always fails "Location unavailable"; second tap works.
- Severity: logic (first-run UX of the primary CTA)
- Root cause: fixed 5 s deadline regardless of `.notDetermined` authorization requiring user interaction.
- Fix: extend the poll deadline (e.g. ~30 s) while `authorizationStatus == .notDetermined` and status is `.requesting`. Small edit inside `acquireLocation` (working method, not the protected trio).
- Blast radius: `handleImIn` + `sendAgreedPlace` share `acquireLocation`; longer spinner if the user ignores the alert.

**T4 — `encodedURL()` hard-fails past 5000 chars**
- `Shared/TweenState.swift:173-175`
- Symptom: large groups / long names silently can't send at all ("Couldn't send the Tween message") because both `p=` and `pj=` are always appended and oversize returns nil.
- Severity: logic (needs ~15+ participants to trigger)
- Root cause: no graceful degradation — dropping `pj=` first would usually fit.
- Fix: retry without `pj=` before returning nil. **[SIGN-OFF: TweenState codec]**
- Blast radius: `MeetupSnapshot.proposedState/agreedState` setters round-trip through `encodedURL` (silently drop oversize states today); URL tests.

**T5 — Compact `p=` decode collapses id → name**
- `Shared/TweenState.swift:199-211`
- Symptom: when `pj=` is absent/undecodable, participants decode with `id == name`, so duplicate display names become one identity — agreement/roster attribution degrades.
- Severity: logic (current builds always emit `pj=`; fires only on mixed/legacy builds)
- Root cause: compact format never carried ids (documented v1 degradation).
- Fix: carry ids in the compact format (protocol change) or accept documented degradation. **[SIGN-OFF: TweenState codec]**
- Blast radius: URL length budget, cross-build decode.

**T6 — `isFullyAgreed` mixed id/name mode (T5-dependent)**
- `Shared/TweenState.swift:93-101`
- Symptom: if participants decoded via `p=` (ids are names) while `agreedIDs` carry UUIDs, `needToAgree` (names) can never be ⊆ `agreed` (UUIDs) → consensus unreachable, meetup never "sets".
- Severity: logic (same trigger as T5)
- Root cause: `useIDs` decides per-message, but the two arrays can be in different namespaces after a lossy decode.
- Fix: only meaningful together with T5. **[SIGN-OFF: TweenState + negotiation]**
- Blast radius: consensus on every device.

**T7 — Legacy-agree proposer mislabel**
- `TweenMessages/MessagesViewController.swift:813` (`senderID: proposed.senderID ?? self.localParticipantID()`)
- Symptom: agreeing to a proposal that carried no `senderID` (pre-group sender) stamps the AGREER as proposer, so consensus is computed against the wrong exclusion set.
- Severity: logic (mixed old/new builds only)
- Root cause: fallback substitutes the wrong identity rather than propagating absence.
- Fix: needs legacy-semantics design (plain removal breaks differently — verified). **[SIGN-OFF: negotiation flow]**
- Blast radius: `isFullyAgreed` everywhere a legacy chain exists.

**T8 — Fairness score inverts confidence below the grace period**
- `Shared/FairnessRanker.swift:43` (`score = (worstETA - 120) / confidence`, ascending)
- Symptom: when every drive is under 2 min, the numerator is negative and dividing by a lower confidence makes it MORE negative — a straight-line guess outranks a real route.
- Severity: logic (hyper-local edge: campus/neighbors)
- Root cause: the confidence divisor assumes a non-negative numerator.
- Fix: `max(worstETA - 120, 0) / confidence` — one line in `RankedSpot.score` (not protected).
- Blast radius: ranking ties at 0 for all sub-2-min spots (falls back to sort stability) — acceptable.

**T9 — Bubble snapshot has no timeout in the send path**
- `TweenMessages/BubbleImageRenderer.swift:47-48` (`snapshotter.start()` untimed)
- Symptom: a network hang stalls the send indefinitely (spinner forever) and burns the direct-send interaction window even when it eventually completes.
- Severity: logic-lite / reliability
- Root cause: `MKMapSnapshotter` has no built-in timeout and the caller doesn't race one.
- Fix: ADDITIVE — race with a timeout task, reusing the pattern of `MessagesViewController.search(_:timeoutNanoseconds:)` (:549-564); on timeout use the existing `fallbackImage`.
- Blast radius: slow networks get fallback bubble art instead of a hang — strictly better.

## UI

**T10 — Interactive expanded map is dead code**
- `Shared/TweenViews.swift:1234-1236` (`usesStaticMapForCurrentState` hardcoded `true`)
- Symptom: ExpandedView ALWAYS renders the static snapshot; the sanctioned pan/zoom `Map` (and its camera/selection code) never runs.
- Severity: UI (feature silently disabled)
- Root cause: leftover kill-switch from memory-pressure debugging.
- Fix: return `false` (or remove the override) so `useStaticMap`/`mapDegraded` governs again — one line, BUT re-enables `MKMapView` in the extension. **[PRODUCT DECISION: needs on-device memory profiling per CLAUDE.md constraint #1]**
- Blast radius: extension memory ceiling (~120 MB) — the reason the switch exists.

**T11 — Compact pills read stale sources**
- `Shared/TweenViews.swift:359-361` (roster count from `received?.participants.count`) and :410-412 (launcher pill "1 in"/"0 in" from `isUserIn` alone)
- Symptom: after you join, the count still shows the peer's last roster (excludes you) until they reply; launcher never shows real group size.
- Severity: UI
- Root cause: views only see the decoded inbound state, not the controller's `currentParticipants`.
- Fix: ADDITIVE — new optional `currentParticipantCount: Int? = nil` prop on CompactView, passed from `presentUI`; pills prefer it when non-nil.
- Blast radius: none (nil default preserves today's rendering).

**T12 — Poll-driven panel-tab jump lacks the self-jump gate**
- `TweenApp/OnboardingView.swift:2438-2447`
- Symptom: when an agreed meetup arrives via the 300 ms App-Group poll, `panelTab = .map` fires ungated (verified: on state CHANGE, not every tick) — can yank the tab mid-interaction; the adjacent detent write IS gated by `suppressPollDetentWrites`.
- Severity: UI
- Root cause: the self-jump gate was applied to the detent binding but not the tab binding beside it.
- Fix: ADDITIVE — mirror the `suppressPollDetentWrites` gate (or an equivalent) around the `panelTab` write.
- Blast radius: agreed-arrival no longer force-switches the tab during poll refreshes; user-initiated refresh paths keep the nudge.

**T13 — Insert-fallback hint invisible in compact; expand covers the staged bubble**
- `Shared/TweenViews.swift` launcherState (no status line) + `MessagesViewController.swift:674` (`requestPresentationStyle(.expanded)` after fallback)
- Symptom: after a staged (fallback) send from compact, the "Added to the message box — tap send to deliver." hint doesn't render in launcher state, and the I'm-in path expands the extension over the very input field holding the staged bubble.
- Severity: UI-cosmetic
- Root cause: launcherState predates statusMessage; the expand call predates the fallback.
- Fix: ADDITIVE — render `statusMessage` in launcherState when present; skip the expand when the status equals the staged-hint copy.
- Blast radius: none beyond the two paths.

**T14 — Case-variant agreement duplicates in captions**
- `MessagesViewController.swift:800-801` (`!agreed.contains(myName)`, case-sensitive) + `Shared/BubbleCaption.swift:46` (`have` from whichever array)
- Symptom: "hassan" and "Hassan" both land in `agreedNames`, inflating "X of Y agreed" copy (IDs drive real consensus, so counts only).
- Severity: UI
- Root cause: case-sensitive name dedup; caption count source can diverge from the ID list.
- Fix: case-insensitive contains in `sendAgreedPlace`; caption prefers `agreedIDs.count` when non-empty (it already does — keep arrays in lockstep instead).
- Blast radius: caption copy only.

## RISK-ONLY

**T15 — Drawer-opened sends mint new MSSessions**
- `MessagesViewController.swift:1017` (`conversation.selectedMessage?.session ?? MSSession()`)
- Symptom: opening from the app drawer (or replying right after `didReceive` without tapping a bubble) starts a NEW session per send → bubble stacking, more stale bubbles to tap (feeds T1).
- Root cause: only the tapped bubble's session is reused.
- Fix: ADDITIVE — retain `lastKnownSession: MSSession?` captured in `didReceive` and `willBecomeActive` (from `conversation.selectedMessage` / incoming message — both OUTSIDE decodeAndCache), preferred before minting a new session.
- Blast radius: session/threading semantics of outgoing bubbles.

**T16 — Legacy peer projection is name-only**
- `Shared/LocationCache.swift:115-122` (`first(where: { $0.name != localName })`)
- Symptom: with colliding/default names the legacy single-peer cache picks the wrong entry or deactivates the peer (Bug-#4 family residual affecting host-app polling surfaces).
- Root cause: snapshot API only receives `localName`, no id.
- Fix: ADDITIVE — new overload taking a `LocalParticipantContext`, filtering via `matches(id:name:)`; old overload delegates; call sites migrate gradually.
- Blast radius: host-app peer pin/name surfaces.

**T17 — Four unguarded `encodedURL()` assignments in the host app**
- `TweenApp/OnboardingView.swift:1728, 1799, 2058, 2748` (vs the guarded 1914)
- Symptom: an oversize payload silently produces `message.url = nil` — the MFMessageCompose bubble sends without a payload and the recipient's extension decodes nothing.
- Root cause: inconsistent guard usage (only `sendToChat` checks).
- Fix: ADDITIVE — guard-and-bail (or fall back to plain text) at the four sites.
- Blast radius: none; behavior only changes in the already-broken oversize case.

**T18 — `UserProfile.displayName` untrimmed**
- `Shared/OnboardingFlags.swift:29-32`
- Symptom: a whitespace-only saved name becomes a real " " senderName/participant name (unlike `UserName.load()`, which trims to nil).
- Fix: trim-and-nil in the getter, mirroring `UserName.load()`.
- Blast radius: senders with whitespace names fall back to "You" semantics — intended.

**T19 — `@Observable` mutated via `DispatchQueue.main.async`**
- `Shared/NetworkMonitor.swift:18-19`
- Symptom: none today; violates strict-concurrency expectations (future Swift 6 hazard).
- Fix: hop via `Task { @MainActor in ... }` or annotate.
- Blast radius: none.

**T20 — Fallback bubble image indexes participants fragilely**
- `TweenMessages/BubbleImageRenderer.swift:~180-195`
- Symptom: none today (entry guard filters the empty case); indexing assumes non-empty in a helper that doesn't own the guarantee.
- Fix: local guard/`prefix` in the fallback renderer.
- Blast radius: none.

**T21 — Leave tears down every receiver's agreed meetup [DESIGN]**
- `MessagesViewController.swift:237-241` (decodeAndCache `.leave` → clearAgreedMeetup + clearProposalState)
- Symptom: if 1 of 4 leaves after full agreement, the other 3 lose their MEETUP SET locally.
- Root cause: documented invariant ("only `.counter` and `.leave` clear the agreed cache") — possibly intended, possibly too aggressive for groups.
- Fix: none proposed; listed for a product decision. **[SIGN-OFF: decodeAndCache + negotiation]** if changed.

**T22 — Agree path reorders the roster**
- `MessagesViewController.swift:790-798` (filter + append moves the agreer to the tail)
- Symptom: participant order changes across bubbles (identity is id-based, so cosmetic today).
- Fix: replace-in-place if ever needed.
- Blast radius: none known.

## Sign-off summary
- **[SIGN-OFF] required (protected core / negotiation / protocol):** T1, T4, T5, T6, T7, T21
- **[PRODUCT DECISION]:** T10 (re-enable interactive map vs memory ceiling)
- **Fixable additively or via small unprotected-method edits:** T2, T3, T8, T9, T11, T12, T13, T14, T15, T16, T17, T18, T19, T20, T22

## Suggested batches for Stage 2 (Madhav picks)
- Batch A (logic, no sign-off): T2, T3, T8, T9
- Batch B (UI, no sign-off): T11, T12, T13, T14
- Batch C (risk-only hardening): T15, T16, T17, T18, T19, T20
- Deferred pending sign-off/decision: T1, T4–T7, T10, T21
