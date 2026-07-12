# AUDIT REPORT — Tween — 2026-07-12 (HEAD f521012, post-push audit of the A→B feature push)

Scope: the three-feature push (`a8aa23d` solo A→B, `9b4fee4` where-I'll-be, `f521012` non-app-user) on the manual-location primitive, plus a regression pass.

**Invariant that HELD (verified):** manual A→B points never reach a send path — `manualParticipants` is read only by display/framing/ranking accessors and never by `scopedFirstRoster`/`saveLocalParticipant`/`proposalParticipantsForCurrentContext`/`nextParticipantList`/`refreshFromAppGroup`. `searchRegion`'s `max()!/min()!` are guarded by `count >= 2` on a non-empty array. `AddPointSheet` is clean (exhaustive sheet switch, `[weak self]` debounce, value-type closures).

The real risk was the **declared self ("I'll be at…")**, whose freshness-exemption I decoupled from the opt-in gate. The audit found — and this pass FIXED — a stale-send cluster.

---

## CRITICAL — FIXED

- **[FIXED] A stale declared self could be sent after leave/reset/cold-launch.** `freshSelfCoordinate()` returned a manual coord regardless of `isActive`, and the self blob is only deactivated (never removed) by `startFreshMeetup`/`deactivateSelf` — so a later send re-shared a possibly days-old "I'll be at…". Fix: the manual branch of `freshSelfCoordinate()` now requires `isActive` (exempt from the 5-min *freshness* window, NOT the opt-in gate) — `LocationCache.swift:82`. Companion: `refreshFromAppGroup` only restores `selfIsManual` when the cached blob is *active*, so a deactivated declaration stops lingering as the self — `OnboardingView.swift:~3384`.

## MAJOR — FIXED

- **[FIXED] `autoJoinForOutgoingMessage` stripped `isManual` on the first send** (`LocationCache.save(...)` defaulted `isManual:false`), after which the poll + a background GPS fix clobbered the declared pin. Now re-saves with `isManual: selfIsManual` — `OnboardingView.swift:~2789`.
- **[FIXED] Extension `handleImIn` respected a *deactivated* declared self** (branched on `isManual` only). Now also requires `LocationCache.isActive`, so after leaving, re-tapping "I'm in" in the chat acquires a fresh GPS fix — `MessagesViewController.swift:873`.
- **[FIXED] Test asserted a `clearAll` path production never runs.** `testResetDeactivatesThenClearsManualSelf` replaced with `testDeactivatedManualSelfIsNotSendable` + `testProductionResetMakesManualSelfUnsendable`, which lock the real reset behavior (`freshSelfCoordinate()==nil` after leave/reset) — `ManualLocationTests.swift`.

## MINOR — FIXED

- **[FIXED] `imIn → setManualSelf` race**: a late GPS `.got` could overwrite the fresh declaration. `setManualSelf` now clears `awaitingImIn`/`pendingLocationAction` — `OnboardingView.swift:~2999`.
- **[FIXED] `frameUserContext` snapped tightly onto you**, ignoring the added A→B point. Now frames you + added points together — `OnboardingView.swift:~3515`.
- **[FIXED] `MapLinks.appleMapsURL` used `http://`** (some clients won't auto-linkify). Now `https://` — `MapLinks.swift:6` (test updated).
- **[FIXED] "You'll be at here"** when the place name isn't persisted after relaunch → "You'll be there" fallback — `OnboardingView.swift:~526`.

## ARCHITECTURE NOTES

- Root cause of the cluster: the manual freshness-exemption was unbounded and decoupled from the `isActive`/opt-in gate the rest of the system uses to answer "may this coordinate travel?". Binding the exemption to `isActive` (freshness-exempt, not active-exempt) collapsed the CRITICAL + two MAJORs. The place NAME is intentionally NOT persisted (App Group holds coords + prefs only) — the pin generalises to "You'll be there" after relaunch.
- Provenance is folded into the single JSON blob (`CachedCoord.isManual`) and written atomically; `setFlag` preserves it on flag flips; pre-provenance blobs decode as GPS. This half of the primitive is solid.

## TEST COVERAGE GAPS (remaining)

- The send-path **isolation invariant** (manual points never in the roster builders) is verified by grep but has no unit test — the builders are `private` on `OnboardingView`. A refactor could re-introduce a leak green.
- The `.got` `keepManual` guard and the extension `handleImIn` manual-respect (host-cache-driven) are exercised only indirectly; no extension-side unit test harness exists.
- Covered now: `Participant.manual` flagging, freshness-vs-active exemption (incl. deactivated/reset non-sendability), pre-provenance decode, `spotBody` maps link, propose/counter subcaption change, https scheme.

## FIX-FIRST PRIORITY LIST

All CRITICAL + MAJOR + MINOR findings from this audit are FIXED in the follow-up commit. Remaining (future): a unit harness for the send-path isolation invariant and the extension manual-respect path.
