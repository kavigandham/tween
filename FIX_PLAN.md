# Tween Fix Plan

Master plan from the 2026-07-06 audit. Each phase is independently shippable, ordered so
nothing in a later phase gets undone by an earlier one. Prompt Claude with
**"do phase N of FIX_PLAN.md"** (one phase per session is ideal). Each phase ends with a
conventional commit as per CLAUDE.md.

**North star:** the host app and the iMessage extension are two windows onto the *same*
meetup. Anything one surface knows, the other shows — instantly. The only hard limit
(serverless design) is that a device can't know about a bubble it has never seen; that
case gets an explicit "tap the latest Tween bubble to sync" affordance, never stale data
presented as fresh.

---

## Phase 1 — Visual fixes: search bar + flushness  (`fix:` / `polish:`)

The "bar inside a bar" and "not flush" reports. All local changes, no logic.

1. **Search field** `OnboardingView.swift:1124-1154` — replace `.tweenGlass()` with an
   opaque inset fill (Apple-Maps style, e.g. `Color(.tertiarySystemFill)` via a new
   `Tokens.Palette.searchField`); one material layer max inside the sheet. Same
   de-glassing for category chips (:1174), quick-spot cards (:1308), distance capsule (:1245).
2. **Name field** `OnboardingView.swift:825-838` — restyle as a form row, not a
   search-bar clone; hide the place-search bar on the Friends tab; stop
   `handleQueryChange` yanking the tab back to `.map` (:2081, :2131).
3. **Top overlays** — replace the contradictory hardcoded insets with safe-area-derived
   placement (`.safeAreaInset(edge: .top)` or one measured inset): 132pt glass (:633),
   64pt magic padding + stale 252×148 frame math (:615-631), 8pt toggle padding (:739-755).
4. **Floating spot card** (:1470) — stop positioning by `sheetPeekHeight - s4` detent
   arithmetic; anchor to the real safe area.
5. **Extension CompactView** `Shared/TweenViews.swift:260-390` — active-meetup stack is
   ~264pt fixed height and clips on small devices; tighten to fit keyboard height
   (constraint #3), bump the five hardcoded 42pt buttons to `Tokens.Layout.minTapTarget`.
6. **Token bypass sweep** — hardcoded frames/fonts/colors listed in the audit
   (OnboardingView 44×44s, 200pt width, divider insets; TweenViews size-10 fonts,
   white-opacity stroke; OnboardingTutorial fixed frames) → tokens.
7. **Unify ETA formatting** — `TweenViews.swift:588` truncates, `ResultRows.swift:122`
   rounds; move one formatter into Shared and delete the other.

## Phase 2 — Flow correctness in the extension  (`fix:`)

Kills the "works half the time" class that is actually code (not platform).

1. **Cross-conversation leak** `MessagesViewController.swift:292-310` — remove the global
   `LocationCache.loadAgreedMeetup()` fallback from `effectiveReceived`; conversation-scoped
   store only. Audit every remaining `LocationCache` global read in the extension.
2. **Commit state only after send succeeds** — `handleImIn`/`handleImOut`/`sendAgreedPlace`
   currently write roster/caches *before* `conversation.send`; on failure the device
   disagrees with every peer. Restructure: build → send → on success persist; on failure
   restore prior state + error status.
3. **Don't blank the negotiation after sending** — `sendBubble` sets `received = nil` on
   place sends; keep rendering the just-sent proposal as "waiting for others".
4. **Gate the Agree/Change buttons on `isSending`** `TweenViews.swift:1929-1951`
   (double-fire agreements today).
5. **Split `statusMessage` semantics** — one field is both neutral progress copy and an
   orange warning banner (`TweenViews.swift:752`); separate progress vs error channels.
6. **Snapshot TTL + staleness UX** — `MeetupSnapshot.updatedAt` exists but is never
   checked: expire stale snapshots (e.g. 24h) instead of auto-expanding into an old
   meetup; when rendering from snapshot (not a decoded message), show its age and a
   "tap the latest Tween bubble to sync" hint. Also stop force-expanding on every
   activation just because a snapshot exists.
7. **Interactive map decision** — `usesStaticMapForCurrentState` is hardcoded `true`
   (`TweenViews.swift:1227`), stranding ~200 lines of dead map/selection code. Either
   restore the real heuristic (live Map with the sanctioned memory guards) or delete the
   dead path; no half-state. Also fix: 3 identical gold "fairSpot" pins (:1147-1157),
   dead code blocks (`imInControl`, `proposedPlacePanel`, banner helpers), VoiceOver
   button-merging (:277-279), and remove the `retryBlankRenderIfNeeded` band-aid if the
   root cause (hosting-view sizing) is addressed.

## Phase 3 — Identity revamp: stable IDs  (`refactor:` — the big one)

Root cause of "locations don't add/remove correctly on other people's screens".

1. **Mint one stable per-install identity**: `TweenIdentity` in Shared — a UUID generated
   once, stored in the App Group, plus the display name. Used by BOTH targets.
2. **Payload v2**: participants always serialize `{stableID, name, lat, lon, ride}` in the
   JSON (`pj`) param; keep the legacy `p` param for old builds but NEVER let decoding
   degrade id → name when `pj` is present. `agreedIDs` and `senderID` use stable IDs only.
3. **Matching**: participant identity == stable ID, full stop. Display name is display-only;
   renaming yourself mid-meetup must not orphan/duplicate your entry. Delete every
   `name == myName` fallback (`Participant.matches`, `saveParticipantSnapshot`'s
   first-non-local-name pick, `agreedNames.contains(myName)`, OnboardingView :938/:1085/:2297).
4. **Kill the name-key duplication**: delete `UserProfile` (OnboardingFlags.swift:22),
   fold into `UserName` (trimmed, nil-for-empty semantics); the "You" fallback never
   travels in a payload again — prompt for a name before first send instead.
5. **Consensus**: rewrite `isFullyAgreed`/`hasAgreed`/`missingAgreementNames` on stable
   IDs; remove the mixed useIDs/names logic. Update BubbleCaption accordingly.
6. **Tests**: round-trip payload tests for v2 + legacy, collision tests (two unnamed
   users, two "Hassan"s, self-rename mid-meetup), consensus tests.

## Phase 4 — Seamless app ↔ extension: shared MeetupStore  (`refactor:` + `feat:`)

The interchangeability goal. One source of truth, two renderers.

1. **Extract `MeetupStore`** (`@Observable`, Shared/): owns the conversation-scoped
   `MeetupSnapshot`s, the roster, proposal/agreement state, drafts, and self/peer
   coordinates. All reads/writes go through it; `LocationCache` peer/participants/agreed
   globals become internal legacy shims and then get deleted. Extension's
   `MessagesViewController` and the host app both drive it.
2. **Instant cross-process refresh**: replace the host app's 300ms poll with
   App Group `UserDefaults.didChangeNotification` + Darwin notification post from the
   extension on every write (poll only as fallback). Fixes camera-stomping and the
   per-keystroke resync jank in one move.
3. **Host app renders the full meetup** — not just pins: current proposal card,
   who-agreed status, "MEETUP SET" with directions, leave/join actions — the same states
   ExpandedView shows, driven by the same store. Opening the app after sending in the
   extension shows exactly what the extension showed.
4. **App → extension direction**: keep the draft handoff but make every app-side action
   (propose, agree, I'm-in) stage a conversation-scoped draft + deep-link into Messages;
   remove the 4-5 duplicated MSMessage-building blocks in OnboardingView in favor of one
   Shared `MessageComposer` used by both targets.
5. **Fix host-app lifecycle vandalism**: remove `startFreshMeetup()` from the View init
   (it wipes live meetups on every cold launch); move lifecycle to the App/scene level
   with an "is a meetup live?" check. Separate "user opted in" from the 5-minute
   coordinate-freshness window so "I'm in" stops silently expiring.
6. **Poll/pacing hygiene**: pause background work when `scenePhase != .active`; persist
   the name on submit only.

## Phase 5 — Split the monolith + flow polish  (`refactor:` + `fix:`)

1. **Split `OnboardingView.swift`** (2,771 lines, ~60 @State vars) into: `HomeMapScreen`,
   `SearchPanel`, `FriendsPanel` (exists), `RidesPanel`, `MeetupStatusPanel`; rename the
   file — it is the home screen, not onboarding. State moves to `MeetupStore` (Phase 4).
2. **Presentation coordinator**: fold the tutorial fullScreenCover and the rename/location
   alerts into the single `ActiveSheet` multiplexer (today they attach to the covered Map
   and silently no-op; cold-start deep links get dropped behind the tutorial).
3. **Onboarding/tutorial**: make the demo-tap gate consistent or drop it (swipe/page-dots
   bypass it today); add a real Skip.
4. **Small flow dead-ends**: iOS 18 limited-contacts spinner (FriendsPanel:121-153) +
   "Open Settings" on denied; location-denied search silently centered on Kansas
   (:2061-2076) → gate with an enable-location prompt; resume dropped user intent after a
   location fix arrives (`sendToChat` :1843, `sendAgreeReply` :2623 — mirror the
   `pendingNameAction` pattern); `LocationProvider` watchdog timeout + `@MainActor`.

## Phase 6 — Verification pass  (`test:` / `chore:`)

- Unit tests reset App Group in `setUp()` (convention) covering: store round-trips,
  identity collisions, consensus, snapshot TTL, send-failure rollback.
- On-device checklist for the collaborator with Xcode: extension memory profile
  (live Map decision from Phase 2.7), compact-height on SE + Pro Max + XL Dynamic Type,
  the full 2-device propose→agree→MEETUP SET and join→leave→rejoin flows, app-open-after-
  send parity in both directions.

---

### Suggested prompts

| You say | I do |
|---|---|
| "do phase 1 of FIX_PLAN.md" | search bar + flushness fixes, commit |
| "do phase 2" | extension flow correctness, commit |
| "do phase 3" | stable-ID identity revamp, commit |
| "do phase 4" | shared MeetupStore + seamless app↔extension, commit |
| "do phase 5" | monolith split + onboarding/flow polish, commit |
| "do phase 6" | tests + device checklist handoff |

Phases 1-2 are quick wins and safe to do back-to-back. Phase 3 must land before Phase 4
(the store keys everything on stable IDs). Phase 5 is easiest after 4 because most state
will have moved out of the view already.
