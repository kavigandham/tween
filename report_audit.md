# AUDIT REPORT — tween — 2026-07-06 (HEAD `201c262`)

*Method: 3 parallel read-only auditors over all Swift sources + config; every CRITICAL/MAJOR claim hand-verified against source before inclusion. Six agent claims rejected on verification (3 false iOS-availability "criticals" — `symbolEffect`/`sensoryFeedback` are iOS 17 APIs, `UnevenRoundedRectangle` is 16.4+; a misread of the documented iOS 26 hand-background-to-system design; a "strong-self-capture leak" in a process-rooted extension VC; an `effectiveReceived` speculation). Note: `CONTEXT.md` referenced by the audit brief does not exist in this repo — CLAUDE.md + HANDOFF.md were used. Where a finding matches DIAGNOSTIC_2026-07-06.md, its W-number is cited; each was re-verified as still open at HEAD.*

## CRITICAL (will crash, corrupt state, or break core flow)

**None found.** All five criticals from the collaborator's diagnostic (D1 https scheme, D2/D3 host commit-on-sent, D4 roster nuke, D5 denied dead-end) were verified **fixed** at HEAD with source evidence (`OnboardingView.swift:~2026, ~1911, ~3117`; `RosterMerge.swift`; `LocationProvider.swift:~62`). No force-unwrap crashes, no availability violations, no MKMapView in the compact/bubble paths.

## MAJOR (wrong behavior, UX broken, data loss risk)

### State machine / sync
- New `.propose` never clears a prior agreement — `saveProposed` clears `agreedState` only for `.counter`, so after a set meetup, a fresh proposal renders next to a stale MEETUP SET (host reads `agreedState` first) — `ConversationMeetupStore.swift:~186` *(W8, verified open)*
  Suggested fix: clear `snapshot.agreedState` for `.propose` too (any new place restarts negotiation).
- Revision guard accepts ties (`revision >= lastRevision`) — two devices minting the same revision concurrently make the outcome tap-order-dependent and can resurrect a leaver group-wide — `MessagesViewController.swift:~315` *(W2, verified open)*
  Suggested fix: tiebreak `(revision, senderID)` lexicographically; keep `>=` only for the same sender.
- Cross-process load→mutate→save on the whole `MeetupSnapshot` blob — host and extension racing can silently drop `lastRevision`/`localUserLeft`/`pendingDraft` (last writer wins the entire snapshot) — `ConversationMeetupStore.swift:~180-240` *(W6, verified open)*
  Suggested fix: split hot fields (revision, tombstones) into their own keys, or re-merge before save.
- 24 h snapshot TTL also wipes the departure tombstone — after a day, tapping an old bubble resurrects a leaver again, undoing the D4 fix cluster *(diagnostic INFO, still open)* — `ConversationMeetupStore.swift` (TTL path)
  Suggested fix: exempt tombstones from the TTL clear (or TTL them separately, much longer).
- Stale self-coordinates embedded in propose/counter/draft rosters — `loadSelf()` consumed without a freshness check in three send paths — `MessagesViewController.swift:~930, ~1081, ~1120` *(W4, partially fixed: explicit joins use fresh fixes)*
  Suggested fix: gate on `LocationCache.isActive` (freshness window) before embedding.
- Draft hand-off has no TTL, rollback, or conversation binding — a cancelled host draft is adopted by whichever conversation opens the extension next — `Shared/OutgoingDraft.swift:~10-26`, `OnboardingView.swift:~2216` *(W7, verified open)*
  Suggested fix: stamp draft with conversation key + created-at; extension ignores foreign/stale drafts.

### SwiftUI / presentation
- Rename-Friend alert is attached to the main sheet's content but triggered from inside the separate Friends sheet — it cannot present while Friends is frontmost; Rename silently no-ops — `OnboardingView.swift:~578` vs the Friends sheet *(W13, verified open — the :574 comment fixed the map-level trap, but Friends became its own sheet in `5898ebc`)*
  Suggested fix: move the `.alert` inside the Friends sheet's view.
- "Searching nearby…" spinner never resolves on completer failure — the failure path only empties results, no failed state, no "no matches" row — `SearchCompleter.swift:~140` *(W16, verified open)*
  Suggested fix: track `.searching/.resolved/.failed`; render an empty/failure row.
- Stale `suppressNextQueryChange` swallows the clear-(x) gesture — armed without an actual text change, leaving ghost results/pins behind an empty field — `OnboardingView.swift:~2331 vs ~2303` *(W15, verified open)*
  Suggested fix: arm only when the programmatic assignment actually changes `searchText`.

### App Group persistence
- Contact PII (name + CNContact ID + phone/email handle) persisted in the unencrypted App Group — violates the "coordinates and preferences only" hard constraint — `Shared/TweenFriend.swift:~7-46` *(W12, verified open)*
  Suggested fix: store only the CN identifier; re-fetch display name/handle at compose time (or document the sanctioned exception in CLAUDE.md).
- Coordinate blob and its active flag written as two separate keys — a cross-process reader between the writes sees fresh coord + stale flag (or vice versa), defeating the 5-min freshness logic — `LocationCache.swift:~49-53, ~71-75`; same pattern `PingLog.swift:~62-65` *(W11, verified open)*
  Suggested fix: fold `isActive` into the `CachedCoord` JSON blob — one atomic write.

## MINOR (suboptimal, cleanup, hardening)

### Extension lifecycle
- `willResignActive` cancels `rankingTask`/`sendTask` but never resets `isRanking` — reactivating mid-rank can show a stuck "Finding fair spots…" until the next ranking kick — `MessagesViewController.swift:~276-282` *(verified open)*
  Suggested fix: add `isRanking = false` beside `isSending = false`.

### Dead code / accessibility
- `panelTab`/`HomePanelTab` is write-only dead state after the tabs removal — 8 write sites, zero reads — `OnboardingView.swift:~178, ~388, ~2749, ~2773, ~3032` *(verified: never read)*
  Suggested fix: delete the property, enum, and all assignments.
- Dark-mode brand fill fails WCAG (white on `#29C7C7` ≈ 2.1:1) on CTAs, chips, and the Friends circle — `Shared/Tokens.swift:~33` *(W20, verified open)*
  Suggested fix: near-black foreground on the dark-mode brand color.
- Bridged `UISearchBar` doesn't adopt Dynamic Type; 44 pt Friends circle overflows at AX sizes — `OnboardingView.swift:~1279`
  Suggested fix: set the search field font from `UIFont.preferredFont`; test at AX3+.

## ARCHITECTURE NOTES
- **Files over 1500 lines:** `OnboardingView.swift` (3226) and `TweenViews.swift` (2001); `MessagesViewController.swift` is 1396 and rising. Only four methods exceed 100 lines (`refreshFromAppGroup` ~127, `handleIncomingURL` ~152, `decodeAndCache` ~114, `sendAgreedPlace` ~112) — each is a genuinely dense orchestrator, but all four sit on the highest-risk paths and deserve tests before any refactor.
- **The mechanical sweeps came back clean** — every View initializer matches every call site (params/order/defaults); all Compact/ExpandedView callbacks are wired in `presentUI`; the App Group key inventory (13 keys) shows no spelling mismatches, no write-only/read-only orphans; `project.yml`/Info.plists/entitlements are consistent, all Shared files in both targets.
- **The host app now mirrors the extension's commit-on-delivery discipline** (D2/D3 fixes) — the two send stacks are intentionally parallel implementations; future changes must be applied to both (a known duplication cost, documented in FIX_PLAN).
- The sanctioned interactive expanded map remains deliberately dead (`usesStaticMapForCurrentState` hardcoded `true`, `TweenViews.swift:~1193`) pending the T10 on-device memory decision — result-row "fly the map" taps silently no-op until then.
- Host sends still lack payload revisions on some paths (W9) — leave now carries `revision`+`senderID`, but not all four host composers were verifiable in this pass; worth a 10-minute sweep.
- The extension's negotiation core (revision guard, tombstones, gossip, delivery gating, conversation scoping) verified solid at HEAD — matching the collaborator's own "verified solid" list.

## FIX-FIRST PRIORITY LIST
1. **W8 — clear `agreedState` on new `.propose`** (`ConversationMeetupStore.swift:~186`) — one line; stale MEETUP SET beside a live proposal is the worst remaining core-flow wrongness.
2. **W2 — break revision ties with `(revision, senderID)`** (`MessagesViewController.swift:~315`) — closes the last leaver-resurrection vector.
3. **TTL/tombstone interaction** — exempt tombstones from the 24 h clear, or D4 re-breaks after a day.
4. **W13 — move the Rename alert into the Friends sheet** — a fully dead feature, 5-line fix.
5. **W6 — protect `lastRevision`/`localUserLeft` from snapshot last-writer-wins** — the enabler behind several resurrection paths.
6. **W16 + W15 — search failure state + clear-gesture fix** — the two most user-visible search papercuts.
7. **W7 — conversation-bind + TTL the outgoing draft.**
8. **W12 — reduce TweenFriend to CN identifier only** (constraint compliance).
9. **`isRanking = false` in `willResignActive`.**
10. **W11 — fold active flags into the coord blobs.**
11. **W20 + Dynamic Type + `panelTab` deletion** — polish pass.
