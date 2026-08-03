# Audit report — Tween Pro features — 2026-08-02

Scope: `eb66833` (Pro redeem codes), `b615a8d` (the four paywall features), `6a36a3a`.
Read-only audit; every finding below was verified against the code before any fix.

Kept separate from `report_audit.md`, which holds an earlier whole-codebase audit.

Status key: **FIXED** in `156b724` · **OPEN** (not yet addressed)

---

## Critical

| # | Finding | Status |
|---|---------|--------|
| 1 | `onPlan` swapped `activeSheet` from *inside* the presented spot sheet — the dismiss-then-re-present that silently drops on iOS 26. The Plan button did nothing on device. | **FIXED** — child sheet (`spotSubSheet`) owned by the spot card, mirroring `friendsSubSheet`. |
| 2 | Locked-user paywall route set `friendsSubSheet = .paywall`, but that `.sheet(item:)` is attached inside the `.friends` arm — so it presented **nothing**, and left the paywall armed to ambush the Friends panel later. | **FIXED** — paywall is now a `SpotSubSheet` case. |
| 3 | Travel modes keyed by `TweenIdentity.stableID`, but `searchRankingParticipants` built the local user as `Participant(id: myName)`. The namespaces never met, so every leg fell back to driving and "Any way you travel" was inert in the app. | **FIXED** — ranker identifies the local user by stable id. |

## Major

| # | Finding | Status |
|---|---------|--------|
| 4 | `estimatedSpot` ignored `TravelMode`, so every straight-line estimate used car speed — and those estimates are what the UI shows first and what out-of-budget candidates keep forever. | **FIXED** |
| 5 | Saving a plan re-ranked nothing; changes only landed on the next search, so the feature looked broken. | **FIXED** — `onSaved` → `rerankCurrentResults()`. |
| 6 | `LeaveByReminder.cancel()` had zero callers: un-scheduling or moving the time left the old notification armed. | **FIXED** — cancelled in `save()`. |
| 7 | Plan was global but presented per-spot: every card read "Planned", and a reminder for one spot replaced another's. | **FIXED** — `MeetupPlan.spotName` + `MeetupPlanStore.isScheduled(for:)`. |
| 8 | Extension linked EventKit + UserNotifications for code it can never run, under a ~120 MB ceiling. | **FIXED** — moved out of `Shared/`; verified with `otool` that the appex links neither. |
| 9 | `MeetupPlanStore.current` read once **per leg** inside the rank task group (2 suite lookups + JSON decode each); also meant legs computed against different plans if edited mid-rank. | **FIXED** — read once per spot. |
| 10 | Failed transit lookup fabricates a transit ETA at 6.5 m/s; "no transit in this region" is indistinguishable from a timeout, and nothing in the UI marks the row as an estimate. | **OPEN** |
| 11 | `PlanMeetupSheet` can list the local user twice when a roster entry carries `id == name` (legacy payload decode); it matches on id only, where every other call site uses `Participant.matches`. | **OPEN** |

## Minor / open

- `UNCalendarNotificationTrigger` uses minute granularity — a fire date <60 s out rounds into the past and never fires, while `schedule()` still reports success. `UNTimeIntervalNotificationTrigger` is the right primitive.
- Trigger components carry no `timeZone`, so a timezone change between scheduling and firing shifts the reminder.
- Dead branch: deployment target is iOS 17, so the pre-17 `requestAccess(to:)` path is unreachable — and would crash for want of `NSCalendarsFullAccessUsageDescription` if reached.
- `TravelMode.driving.fallbackMetresPerSecond` (11.5) is dead; `estimatedETA` uses `fallbackSpeed` (13.4) for driving. Its doc comment claims otherwise.
- `RankedSpot.score` hits UserDefaults on every access, twice per comparison across three sorts (~500+ lookups per search), and the comparator can change mid-sort — a strict-weak-ordering hazard.
- `-DEMO_PRO_LOCKED` can no longer force a locked state on a device with a redeemed code. DEBUG-only, but it will break Pro-locked screenshot runs.
- `scheduleReminder`/`addToCalendar` persist the plan before acting, so Cancel doesn't undo.
- `MeetupPlan.modes` never prunes departed participant ids.
- A plan up to an hour past survives the staleness filter, so `DatePicker(in: Date()...)` can open outside its own range.
- `store.defaultCalendarForNewEvents` isn't nil-checked; failure surfaces as a generic message.

## Constraint compliance (CLAUDE.md)

| # | Constraint | Verdict |
|---|---|---|
| 1 | Extension ≤ ~120 MB, snapshotter only | **Now clean.** No new map surfaces; caps untouched (5 ext / 8 app); EventKit + UserNotifications no longer linked; plan read hoisted off the per-leg path. |
| 2 | `MSMessage.url` ≤ 5000, coords + name | **Clean.** `MeetupPlan` is never encoded into `TweenState`. Transit deliberately uses `calculateETA`, so no route geometry is ever fetched. |
| 3 | Compact view = keyboard height, no text input | **Clean.** The redeem field is host-app only. |
| 4 | When-In-Use only | **Clean.** No new location APIs. |
| 5 | No API keys | **Clean.** SHA-256 digests; plaintext codes appear only in comments and tests, neither of which reaches the binary. |
| 6 | App Group = coordinates + preferences | **Watch — OPEN.** `MeetupPlan.modes` is keyed by participant id, and on the legacy `id == name` decode path those keys are display names — PII outside the sanctioned `FriendRoster`/`GroupStore` exception. |
| 7 | `@Observable` not `ObservableObject` | **Clean.** |
| 8 | No server/accounts | **Clean.** Redemption, notifications and calendar writes are all on-device. |

## Test quality

Fixed in `156b724`:
- `testRedemptionIsCaseAndSeparatorInsensitive` only exercised `isValid` — would have passed with `redeem()` broken. Now drives `redeem()`.
- `testPurchaseAndRedemptionAreIndependent` never combined the two sources. Now asserts each alone holds the gate open and only both-absent locks.
- Added a ranker-level travel-mode test (the constants-only test passed while the bug was live) and one pinning the participant-id namespace — which would have caught Critical #3.

Still uncovered: `LeaveByReminder.schedule`, `CalendarExport.add`, `MeetupPlanStore`'s 1-hour grace boundary.

Global-state hygiene is acceptable but fragile: both suites wipe the App Group domain in `setUp` per the CLAUDE.md convention, but `MeetupPlanTests` sets `ProEntitlement.setUnlocked(true)` there, so a trap mid-test leaks an unlocked flag into whatever class runs next.

## Security note

The redeem scheme is what its header comment claims. `normalize()` is safe — uppercasing plus alphanumeric filtering can only widen the set of inputs mapping to a published digest, never mint an unpublished one. There is no bypass; `redeem()` is the only writer and it is digest-gated. The real weakness is disclosed by design: `tween.pro.unlocked` is a plaintext bool in an unencrypted App Group, and two short human-memorable codes are offline-brute-forceable with no rate limit. That is a consequence of having no server, not a defect.

## Not yet verified anywhere

Transit and predicted-traffic ETAs cannot be exercised in this simulator (no CoreLocation), and transit coverage is regional. The code paths are confirmed; the numbers are not. Same for the notification and calendar permission prompts. These need a real device before the feature is trusted.
