You are performing a READ-ONLY audit of the Tween iOS codebase. Do NOT modify, create, or delete any files. Do NOT run xcodebuild or any build tools. Output a markdown report to stdout only.

Read CLAUDE.md first for hard constraints. This is a two-target iOS app (TweenApp host + TweenMessages iMessage extension) sharing code via Shared/, communicating through App Group UserDefaults and MSMessage URLs.

## How to work

1. Use Explore subagents to read files in parallel. Do NOT load every file into your main context.
2. Start with these high-risk files in order:
   - TweenMessages/MessagesViewController.swift (the state machine)
   - TweenApp/OnboardingView.swift (the entire host app surface)
   - Shared/TweenViews.swift (extension CompactView + ExpandedView)
   - Shared/TweenState.swift (the URL codec)
   - Shared/ConversationMeetupStore.swift (per-conversation state)
   - Shared/LocationCache.swift (App Group cache)
3. Then scan remaining files: FairnessRanker.swift, Tokens.swift, FriendsPanel.swift, SpotDetailCard.swift, ResultRows.swift, BubbleImageRenderer.swift, Participant.swift, SearchCompleter.swift, LocationProvider.swift, PingLog.swift, TweenFriend.swift, OutgoingDraft.swift, MapLinks.swift, BubbleCaption.swift, UserName.swift, OnboardingFlags.swift, NetworkMonitor.swift, CategoryPreset.swift, ActivityView.swift, RosterMerge.swift.
4. Then scan all test files in TweenAppTests/.
5. Report only genuine problems. If you're under 70% confident something is a real bug, skip it.

## What to check

### 1. State machine integrity (MessagesViewController.swift)

Trace the full flow through these specific methods:
- `willBecomeActive(with:)` — Does it correctly handle conversation switching? Does it clear stale state?
- `decodeAndCache(_:in:)` — Does it correctly parse incoming MSMessage URLs? Does it handle nil selectedMessage? Does it correctly write to ConversationMeetupStore?
- `effectiveReceived(decoded:)` — Does the "agreed meetup is sticky" rule work correctly? Can an old bubble clobber a newer agreed state? Does the revision-based ordering (`TweenState.revision`) correctly reject stale payloads?
- `handleImIn()` — Does `acquireLocation()` reliably return? Does it correctly build the participant list via `nextParticipantList`? Does it correctly send via `deliverBubble`?
- `handleImOut()` — Does it clear ALL relevant state? Does the outgoing `.leave` carry the remaining roster? Does it clear `agreedMeetup` from both ConversationMeetupStore and LocationCache?
- `sendChosenSpot(_:)` — Does it build `.propose` with correct senderCoordinate?
- `sendAgreedPlace(_:)` — Does it correctly append local user to agreedNames/agreedIDs? Does `isFullyAgreed` evaluate correctly before saving terminal state?
- `sendCounter(_:)` — Does it reset agreedNames/agreedIDs? Does it clear the previous agreed meetup?
- `sendDraft()` — Does it pick up OutgoingDraftStore correctly? Does it clear the draft after sending?
- `kickOffRanking()` — Is it capped at `rankCap = 5`? Is the 8-second search timeout enforced? Are tasks cancelled in `willResignActive`?

Look for: infinite loops, stuck states, unreachable code paths, cases where agree/counter/leave don't properly transition.

### 2. Cross-file consistency

**View initializers vs call sites:**
- CompactView and ExpandedView are defined in Shared/TweenViews.swift. They're instantiated in MessagesViewController.swift (via UIHostingController) and in TweenApp/HarnessView.swift. Do ALL call sites pass every required parameter? Are any callbacks nil that shouldn't be?
- SpotDetailCard is defined in TweenApp/SpotDetailCard.swift. It's used in OnboardingView.swift. Do parameters match?
- ResultCard, ResultRow, RankedResultRow, ETAChip, ABDistanceLabel, SuggestionRow are in TweenApp/ResultRows.swift. Verify all call sites match.

**App Group UserDefaults keys — reader/writer match:**
Every key must be spelled identically between reader and writer. Check these specific keys:
- `tween.cache.self` — written by LocationCache.save(), read by LocationCache.loadSelf()
- `tween.cache.self.active` — written/read as legacy mirror
- `tween.cache.peer` / `tween.cache.peer.active` — legacy projection
- `tween.cache.participants` — written by saveParticipantSnapshot, read by loadParticipants
- `tween.cache.agreedMeetup` — written by saveAgreedMeetup, read by loadAgreedMeetup
- `outgoingDraft` — written by OutgoingDraftStore.save, read by OutgoingDraftStore.load
- `cachedFriends` — written/read by FriendRoster
- `pingLog` / `lastIncomingReplyAt` — written/read by PingLog
- `userName` — written/read by UserProfile/UserName
- `tween.onboarding.hasSeen` — written/read by OnboardingFlags
- ConversationMeetupStore keys (per-conversation, base64-encoded) — verify the key generation in `conversationKey(localID:remotes:)` is consistent between reads and writes
- ConversationSyncState keys — verify they're stored/loaded under the correct conversation-scoped key, separate from MeetupSnapshot

Flag any key that is written but never read, read but never written, or spelled differently between reader and writer.

**MeetupSync (Darwin notifications):**
- Verify every canonical writer (ConversationMeetupStore, LocationCache, OutgoingDraftStore) calls `MeetupSync.post()` after writing
- Verify the host app's observer (`MeetupSyncToken`) correctly triggers `refreshFromAppGroup()`
- Check if `MeetupSyncToken.deinit` properly removes the observer

### 3. SwiftUI view bugs (TweenViews.swift + OnboardingView.swift)

- **Sheet conflicts:** OnboardingView uses `.sheet(item: $activeSheet)` for multiplexed sheets. Are there any OTHER `.sheet` or `.fullScreenCover` modifiers on the same view hierarchy that could conflict?
- **presentationDetents:** Are detent sets static or recomputed on state changes? Does the `selectedSheetDetent` binding get reasserted by the 300ms poll (`pollPeer`), fighting user gestures?
- **Empty view bodies:** Can any view body return nothing/EmptyView under reachable conditions? Check every `if/else` and `switch` in CompactView, ExpandedView, and OnboardingView bodies.
- **Force unwraps:** Find every `!` in view code. Each one is a potential crash. List them with file and approximate line number.
- **SearchState machine in OnboardingView:** The search uses `.idle`, `.suggesting`, `.results` states. Can any transition get stuck? Does `.onSubmit` reliably fire? Does `.onChange(of: searchText)` conflict with `.onSubmit`?
- **Map camera binding:** Does the `position: $mapPosition` binding in the Map view fight with programmatic camera changes? Can the 300ms poll or state refresh cause the camera to jump?

### 4. Extension-specific (MessagesViewController.swift + TweenViews.swift)

- **UIHostingController lifecycle:** Verify `embed()` or equivalent correctly adds the hosting controller as a child VC with frame/autoresizing mask. Is the hosting controller recreated on compact-expanded transitions or reused with a rootView swap?
- **Fallback view:** The `installFallbackView()` adds a permanent opaque background. Verify it's always behind the hosting controller's view (z-order).
- **Task cancellation:** Are ALL Tasks (`rankingTask`, `sendTask`) cancelled in `willResignActive`? Any other async work that could leak?
- **MKMapView usage:** CLAUDE.md allows SwiftUI Map in ExpandedView only. Verify MKMapView is NOT used in CompactView or BubbleImageRenderer. Check `mapDegraded` flag — does `didReceiveMemoryWarning` correctly trigger the snapshot fallback?
- **Ranking cap:** Verify `rankCap = 5` is enforced everywhere in the extension (vs 8 in the app).
- **LocationProvider retention:** Is the `locationProvider` instance variable retained for the extension's lifetime? A local variable would get deallocated and cancel callbacks.
- **`deliverBubble` staged delivery:** When `conversation.insert` is rejected, it stages the bubble in the input field and sets `stagedDeliveryStatus`. Does `handleImIn` correctly check for this to avoid expanding over the staged bubble?

### 5. Consensus and group logic

- **`TweenState.isFullyAgreed`:** Trace the logic. It uses `senderID ?? senderName` for the proposer and `agreedIDs` or `agreedNames` for agreement. Can duplicate names cause a false positive? What if `senderID` is nil and two participants have the same name?
- **Participant identity matching:** `Participant.matches(...)` falls back from ID to name. Find every call site and check if name-based matching can produce false matches.
- **Departure gossip:** `TweenState.departed` carries identity keys of people who left. Is the gossip cap enforced? Can an old bubble's departed list conflict with a newer one?
- **Revision ordering:** `TweenState.revision` is monotonic per conversation. What happens if two participants send at the same revision? Does `ConversationSyncState.lastRevisionSender` correctly break the tie? Is the `.invite`-at-floor concurrent-join exception scoped correctly (accept at floor, reject below)?
- **`saveParticipantSnapshot(...)`:** Does it correctly update the roster AND the legacy peer projection? Can a race between app and extension writes corrupt the participant list?

### 6. App Group persistence

- **Torn reads:** Every write should be a single atomic JSON blob under one key. Check if any write involves multiple keys where a reader between the two writes sees inconsistent state. The CachedCoord `isActive` flag was folded INTO the blob to fix this — verify it's consistently used.
- **Snapshot TTL:** `ConversationMeetupStore.snapshotTTL` (24h). Verify expired snapshots are cleared in `willBecomeActive` and that clearing doesn't wipe `ConversationSyncState` (which should survive TTL).
- **Freshness window:** `LocationCache.freshnessWindow` is 5 minutes. Verify `freshSelfCoordinate()` is used (not raw `loadSelf()`) when a coordinate is about to be embedded in a payload or used for ranking.
- **`lastActiveConversationKey`:** Used by the host app to know which conversation the extension was last in. Can it go stale? Is it cleared appropriately?

### 7. Concurrency and threading

- **@MainActor compliance:** Any UI state mutation from async code must be on the main actor. Check every `Task { }` block and completion handler in MessagesViewController and OnboardingView for missing @MainActor or DispatchQueue.main.
- **Strong self capture:** Check every closure/Task in MessagesViewController for strong self capture without `[weak self]` — the extension is short-lived and leaking memory is critical here.
- **Race between poll and decode:** OnboardingView polls App Group every 300ms via `pollPeer`. Can a poll read race with a ConversationMeetupStore write from the extension? Is this protected?

### 8. Architecture smells

- **God files:** For OnboardingView.swift, TweenViews.swift, and MessagesViewController.swift, identify the top 3 methods by line count and flag any method over 80 lines.
- **Dead code:** Find methods never called, @State never read, imports never used, `#if DEBUG` blocks that are empty.
- **Legacy debt:** List every `etaFromA`/`etaFromB`/`worseETA`/`fairnessGap` legacy accessor still called and where. List every deprecated method still referenced. List every "Slice 5" migration comment.
- **Duplicated logic:** Check if the host app and extension implement the same logic differently (building participant lists, computing midpoints, formatting ETAs). Flag duplication.

### 9. Error handling gaps

For each scenario, trace what actually happens:
- Location permission denied — does every code path handle it?
- Location request times out in the extension — does `acquireLocation()` surface the failure?
- MKLocalSearch returns zero results — what does the UI show?
- MKDirections fails for ALL candidates — does ranking degrade gracefully?
- `MSMessage.insert` fails — what does the user see?
- Network down (`NetworkMonitor.isOnline == false`) — is search gated? Is ranking gated?
- `TweenState.encodedURL()` returns nil (URL too long) — is this handled at every send site?
- `ConversationMeetupStore.load` returns nil — does the extension fall back correctly?
- `UserDefaults(suiteName:)` returns nil (entitlement wrong) — is this ever checked?

### 10. Test coverage gaps

Read all test files in TweenAppTests/. For each source file, note whether it has coverage. Flag these specific untested areas:
- ConversationMeetupStore snapshot TTL expiration
- ConversationSyncState revision tie-breaking
- Departure gossip propagation and cap enforcement
- `effectiveReceived` sticky rule logic
- `deliverBubble` staged-delivery path
- MeetupSync Darwin notification posting/observing
- `freshSelfCoordinate` vs raw `loadSelf` behavior
- `Participant.matches(...)` name-fallback edge cases
- `TweenState.isFullyAgreed` with duplicate names

## Output format

```
# AUDIT REPORT — Tween — [date]

## CRITICAL (will crash, corrupt state, or break core flow)

### [Category]
- [description] — `FileName.swift:~lineNumber`
  Suggested fix: [one-line description]

## MAJOR (wrong behavior, UX broken, data loss risk)

### [Category]
- [description] — `FileName.swift:~lineNumber`
  Suggested fix: [one-line description]

## MINOR (suboptimal, cleanup, hardening)

### [Category]
- [description] — `FileName.swift:~lineNumber`
  Suggested fix: [one-line description]

## ARCHITECTURE NOTES
- [observation]

## LEGACY DEBT INVENTORY
- [each legacy accessor/method still in use, with call sites]

## TEST COVERAGE GAPS
- [each untested area]

## FIX-FIRST PRIORITY LIST
1. [most important]
2. [second]
...
```

Cap at 15 findings per category. Skip files with no issues. End with the prioritized fix list.

Do NOT apply any fixes. Report only.
