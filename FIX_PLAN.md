# Tween Fix Plan — v2 (post-merge, 2026-07-06)

Rewritten after merging main's fix stack (delivery-gated sends, identity hardening,
T-batches A/B/C — see BUGREPORT.md, HANDOFF.md, TODO_VERIFY.md). Companion docs:
- **BUGREPORT.md** — T1–T22 triage with root causes and sign-off flags
- **TODO_VERIFY.md** — the two-device verification checklist (unchanged, still owed)
- **HANDOFF.md** — architecture + HARD RULES (delivery gating, minimal diffs, protected core)

Prompt Claude with **"do phase N of FIX_PLAN.md"**.

## Done and verified (build green, 88/88 unit tests, simulator screenshots)

- **Phase 1 visual fixes** (this branch): de-nested search bar (opaque `inputFill`
  token, no material-on-material), safe-area-derived map chrome via root
  GeometryReader (replaces 132/64/8pt guesses), floating card anchored to safe
  area, name field restyled as a form row + saved on blur, search bar hidden on
  Friends tab, People tab is one scrolling List, CompactView fits the
  keyboard-height budget, 44pt tap targets, single shared `formatETA`.
- **Merged from main:** send→insert delivery fallback; delivery-gated state commits
  (I'm in / I'm out / agree / propose / counter / draft); strict identity matching
  with legacy-only name fallback (+tests); leave-state map clears; session reuse
  (`lastKnownSession`); Dynamic-Type map controls; debounced completer;
  snapshot/native-scale bubble rendering; fairness clamp; URL guards; name trim.
- **Flow fixes (this branch, post-merge):**
  - Cross-conversation MEETUP SET leak: `effectiveReceived` now uses the global
    agreed cache only when no conversation key exists.
  - 24h TTL on `MeetupSnapshot` — stale meetups no longer resurrect + force-expand.
  - Agree / Change / Send-change buttons disabled while `isSending` (double-fire).
  - `statusIsError` channel: failures render as warning banners, progress/staged
    hints as neutral info banners.
  - Static bubble map draws exactly one gold "the spot" pin.
  - Dead code removed: `imInControl`, `bannerHeadline`/`bannerSubcopy`/
    `bannerAccessibilityLabel`, `proposedPlacePanel`/`panelSubcopy`.
    (T10's interactive-map path deliberately KEPT pending the product decision.)

## Phase V — Device verification (do before more code)

Run TODO_VERIFY.md's checklist on two real devices; App Group + iMessage delivery
cannot be verified in the simulator. Everything below builds on that stack being
confirmed. Add to it: re-verify Phase-1 UI on a small device (SE class) and at
XL Dynamic Type — especially CompactView with a staged-send status line visible.

## Phase 2 — Remaining host-app flow bugs — DONE (2026-07-06)

All landed, build green, 88/88 tests, tutorial + map screenshots verified:
1. ✅ Launch wipe moved to `TweenAppApp.init`, gated on
   `ConversationMeetupStore.hasLiveMeetup(within: snapshotTTL)` — opening the
   app no longer erases an in-flight meetup (TTL constant now shared with the
   extension's activation restore and the host poll's snapshot reads).
2. ✅ `LocationCache.isOptedIn` (presence) split from `isActive` (coordinate
   freshness); the poll no longer flips "I'm in" off after 5 minutes.
3. ✅ Tutorial: Next always advances (demos are optional try-its); labeled Skip.
4. ✅ Contacts: iOS 18 `.limited` treated as access; denied state gets
   "Open Settings"; request state labeled.
5. ✅ Location-less search parks the query, requests a fix, and reruns it
   instead of silently searching Kansas.
6. ✅ `pendingLocationAction` resumes send-to-chat / agree / search when the
   fix arrives (mirrors `pendingNameAction`); cleared with a toast on failure.
7. ✅ `LocationProvider`: 20s fix watchdog (armed only after authorization
   resolves, so permission-alert time never counts) + main-actor mutation hops.

## Phase 3 — Protocol + identity — DONE (2026-07-06, owner signed off)

All landed, build green, 94/94 tests (6 new protocol tests):
- ✅ **Stable install identity** (`TweenIdentity.stableID`, App-Group-minted
  UUID) stamped into every payload/participant/agreedID from both targets —
  device-scoped iMessage UUIDs and name-as-id fallbacks are legacy-decode-only.
- ✅ **T1** — `rev=` monotonic revision on every extension payload; decode
  ignores bubbles older than the newest revision seen per conversation, both
  inbound and self-minted. Rev-less payloads (old builds, host-app composer
  sends) keep trust-the-tap semantics.
- ✅ **T4** — oversize URLs drop `pj=` and retry instead of hard-failing.
- ✅ **T5/T6** — `pids=` carries ids alongside the compact `p=` list, so
  identity survives the pj-less path; old builds ignore the extra param.
- ✅ **T7** — legacy (senderID-less) proposals stay name-namespaced end to end:
  agree no longer stamps the agreer as proposer nor mixes UUID agreedIDs into
  a name-id roster.
- Transition note: rosters minted by PRE-stable-ID builds carry conversation
  UUIDs; extension paths filter them via `legacyLocalParticipantID()`, host
  paths can't (no MSConversation) — an in-flight old-format meetup may need a
  leave/rejoin after upgrading. Self-heals on the next extension bubble.

Still open (product decisions, unchanged): **T21** (leave clears every
receiver's agreed meetup — confirm intent) and **T10** (re-enable the
interactive expanded map after on-device memory profiling).

## Phase 4 — Seamless app ↔ extension — DONE (2026-07-06)

Delivered (build green, 94/94 tests, verified end-to-end by seeding the
simulator's App Group with an extension-written proposal and cold-opening the
app onto the full negotiation card):
- ✅ **MeetupSync** Darwin-notification channel: every canonical App Group
  writer (`ConversationMeetupStore`, `LocationCache`, `OutgoingDraftStore`)
  posts on write; the host observes and refreshes instantly. The 300ms poll
  became a 2s fallback.
- ✅ **Host renders the full negotiation**: in-flight proposals/counters
  surface as a floating card (proposer, spot, agreement progress, A/B
  distances) with "Agree & reply" (routes through the existing composer
  hand-off) or a waiting state, plus the proposal pin on the map. Cold-open
  nudges the sheet to its peek; mid-session arrivals respect the T12
  anti-yank gate.
- ✅ **`composeTweenMessage`**: the five copy-pasted MSMessage-building blocks
  in OnboardingView collapsed into one helper (render → caption → payload
  guard → message).
- Deliberately NOT done: a separate `@Observable MeetupStore` type. With
  instant sync + full-state rendering shipped, the state-ownership extraction
  folds into Phase 5's monolith split where the state has to move anyway —
  extracting it twice would violate the minimal-diff rule.

## Phase 5 — Monolith split

Split OnboardingView (~2,800 lines) into HomeMapScreen / SearchPanel /
FriendsPanel / RidesPanel / MeetupStatusPanel; fold the tutorial cover and
rename/location alerts into the single ActiveSheet presenter (they currently
attach to the covered Map and can silently no-op).

## Notes

- **No third-party UI libraries.** "No third-party dependencies" is a hard
  constraint (CLAUDE.md + HANDOFF §3). docs/ui-research.md is the sanctioned
  substitute: first-party pattern reference for sheets, maps, extension sizing.
- Xcode IS available on this Mac despite CLAUDE.md's note — prefix with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (see HANDOFF §5).
