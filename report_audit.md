# AUDIT REPORT — tween — 2026-07-07 (HEAD `38d865e`)

*Re-audit of the four fix commits (`9ba5568`, `6014f23`, `9faf78d`, `38d865e`) that worked through the 2026-07-06 report's fix-first list. Same methodology: 3 parallel read-only auditors, every CRITICAL/MAJOR claim hand-verified against source before inclusion (one agent claim rejected this round — the "rename alert re-presents after Save" scenario is impossible: `commitRename`, Cancel, and the binding setter all clear `editorMode`). Toolchain note: HEAD references iOS 26 SDK symbols (`glassEffect`), so the repo now **requires Xcode 26+ to build** — this machine's Xcode 16.2 fails at `OnboardingView.swift:42`, meaning local test execution here is blocked and the 125/125-unit + 6/6-UI green counts are from the collaborator's Xcode 26.5 toolchain.*

## PREVIOUS FINDINGS — VERIFICATION AT `38d865e`

| 07-06 item | Verdict | Evidence |
|---|---|---|
| W8 propose vs stale MEETUP SET | **FIXED (host dual-render)** — with intentional extension asymmetry, see MINOR | `OnboardingView.swift:~1600` `visiblePendingProposal` renders agreement + new suggestion together |
| W2 revision ties | **FIXED** | `ConversationMeetupStore.shouldAcceptInbound(revision:senderID:)` :~411 — at-floor accepted only from the same sender; 7-case tiebreak matrix test |
| 24h TTL wipes tombstones | **FIXED** | sync state moved to its own TTL-exempt `conversationMeetup.sync.<key>` blob; `clear(key:)` :~216 leaves it untouched; tested |
| W6 snapshot RMW races | **FIXED (structural)** | `ConversationSyncState` :~60 — revision floor, sender, `localUserLeft`, `departedKeys` in their own atomic key; snapshot writers can't clobber them; race test green |
| W13 rename alert host | **FIXED** (hand-verified) | alert now inside the Friends sheet's NavigationStack, `OnboardingView.swift:~538`, with explanatory comment |
| W15 suppress-flag arming | **FIXED** | armed only when the programmatic assignment changes `searchText` (:~2523) |
| W16 search failure spinner | **FIXED** | `SearchCompleter.Phase` idle/searching/resolved/failed (:~81); "No matches" / "Search unavailable" rows (`OnboardingView.swift:~764`); lifecycle tests |
| W7 draft TTL/binding | **FIXED** | `OutgoingDraft.conversationKey` + 15-min TTL + `shouldAdopt` (:~53); extension clears foreign/stale drafts; adoption-matrix tests |
| W12 contact PII | **RESOLVED BY DOCUMENTATION** | CLAUDE.md §6 sanctioned exception (2026-07-06); wording matches `TweenFriend.swift` fields exactly |
| W4 stale coords | **PARTIALLY FIXED** → the one remaining MAJOR, below | extension paths gated on `LocationCache.isActive` (`MessagesViewController.swift:~945, ~1103, ~1146`); host paths not |
| W9 host payload revisions | **FIXED** | every composer (incl. `pingFriend` :~2396) stamps `revision` + `senderID`; noted at delivery with sender |
| W11 multi-key torn reads | **FIXED** | `isActive` folded into the `CachedCoord` blob (`LocationCache.swift:~33`); legacy mirror keys kept for downgrade; old-format blobs decode via optional field — migration-safe, tested |
| isRanking not reset | **FIXED** (hand-verified) | `willResignActive` now sets `isRanking = false` with audit-referencing comment |
| panelTab dead state | **FIXED** | property, enum, and all 8 writes deleted; zero dangling references |
| W20 dark-mode contrast | **FIXED** | `Tokens.onBrand` — white on `#008C8C` ≈ 4.1:1 (light), on `#003535` ≈ 13:1 (dark); adopted at button style, chips, Friends circle |
| AX friends circle | **FIXED** | `@ScaledMetric(relativeTo: .caption)` + initials clamping |
| UISearchBar Dynamic Type | **STILL OPEN** | no `preferredFont`/`UIFontMetrics` adoption in the bridge |

**14 of 15 items closed. The sync-layer redesign (separate atomic sync-state key) is the right structural fix, not a patch.**

## CRITICAL (will crash, corrupt state, or break core flow)

**None found.**

## MAJOR (wrong behavior, UX broken, data loss risk)

### State machine / sync
- Host coordinate-freshness laundering — `autoJoinForOutgoingMessage()` takes a cached coordinate of ANY age (`savedCoordinate ?? loadSelf()`, no freshness gate) and re-saves it with `isActive: true`, re-stamping the timestamp — a stale coordinate becomes "fresh" and defeats the 5-minute window the extension paths now honor. Three downstream host sites then embed ungated `loadSelf()` coords into payloads: `sendAgreeReply` (~3157), `pingFriend` (~2381), `setNeedsRide → presentRideStatusMessage` (~2113) — `TweenApp/OnboardingView.swift:~2324-2331` *(W4, host half still open; extension half verified fixed)*
  Suggested fix: in `autoJoinForOutgoingMessage`, only reuse the cached coord when `LocationCache.isActive` (else park the action and `requestOnce()`, the pattern already used when no coord exists), and preserve the original timestamp on re-save; gate the three `loadSelf()` sites on `isActive`.

## MINOR (suboptimal, cleanup, hardening)

- Pre-migration `save()` double-load window — between the `loadSync()` migration read and the second snapshot load (:~183-190), a concurrent extension write can be clobbered; bounded to the first launch after the update × concurrent write — `ConversationMeetupStore.swift:~179-214`
  Suggested fix: single `load()` before migration; compare against that one snapshot.
- W8 surface divergence — host dual-renders [set meetup + new suggestion]; the extension's `effectiveReceived` still resolves to one state, so the two surfaces can show different things for the same conversation (documented owner decision; on record) — `MessagesViewController.swift:~513` vs `OnboardingView.swift:~1600`
  Suggested fix: none required; if it confuses testers, render a "meetup set" chip on the extension's proposal view.
- `setFlag()` writes the blob then the legacy mirror key non-atomically — readers prefer the blob so impact is bounded to pre-split data windows — `LocationCache.swift:~237-246`
  Suggested fix: accept until the legacy mirrors are retired; then delete both writes.
- Bridged `UISearchBar` still doesn't adopt Dynamic Type — `OnboardingView.swift:~1279` *(carried from 07-06)*
  Suggested fix: `searchBar.searchTextField.font = .preferredFont(forTextStyle: .body)` + `adjustsFontForContentSizeCategory = true`.

## ARCHITECTURE NOTES
- **The repo now requires Xcode 26+ to build.** `glassEffect` and related iOS 26 SDK symbols are referenced directly (runtime-gated correctly with `#available(iOS 26.0, *)`, but older SDKs lack the symbols entirely — Xcode 16.2 fails at `OnboardingView.swift:42`). CLAUDE.md documents Xcode 26.5. If anyone needs to build on an older toolchain, wrap the glass paths in `#if compiler(>=6.2)` (or equivalent SDK check) with the pre-glass fallback as the else-branch.
- **`TweenApp.xcodeproj` is now tracked in git** alongside the `xcodegen` workflow — regeneration will churn the tracked file; a known, documented cost, but pick one source of truth eventually.
- The sync-state redesign (per-conversation `conversationMeetup.sync.` atomic blob, TTL-exempt, sender-attributed revision floor) is a genuine architecture improvement — it closed W2/W6/TTL in one move and is well-tested (tiebreak matrix, TTL survival, race structure).
- Test discipline notably improved: every fix in this batch landed with pinning tests (new `SearchCompleterTests`, +177 lines of ParticipantCodec sync tests, +67 RosterMerge draft/adoption tests). Collaborator-reported: 125/125 unit, 6/6 UI.
- File sizes: `OnboardingView.swift` 3302, `TweenViews.swift` 2001, `MessagesViewController.swift` 1430 — all still monoliths; unchanged advice: split only with tests in place.
- Verification rigor this round: one agent claim rejected (rename-alert state trap — all dismissal paths verified to clear `editorMode`); the W4 host findings were confirmed by hand before inclusion.

## FIX-FIRST PRIORITY LIST
1. **W4 host half — stop the coordinate laundering** (`autoJoinForOutgoingMessage` + the three ungated `loadSelf()` sites): gate on `LocationCache.isActive`, park-and-request otherwise, preserve timestamps on re-save.
2. **Pre-migration `save()` single-load** — one-line hardening of the migration window.
3. **UISearchBar Dynamic Type** — the last open item from the 07-06 list.
4. *(Optional, only if older-toolchain contributors matter)* `#if compiler` guard around the Liquid Glass paths so Xcode 16 can still build the repo.
5. Then the two-phone TODO_VERIFY.md run — with 14/15 audit items closed and the sync layer redesigned, the device pass is the real remaining gate.
