# Tween 1.0.5 — submission checklist

Verified against App Store Connect on **2026-10-13** (read-only browse). Supersedes
`SUBMIT.md` / `SUBMIT-1.0.3.md` for anything that contradicts it.

## State of the world, as checked in ASC today

| Thing | State |
|---|---|
| Live version | 1.0.4 (1.0.5 has never shipped) |
| ASC 1.0.5 version record | EXISTS, "Prepare for Submission", **no build attached** |
| TestFlight 1.0.5 builds | 474, 476, 477 — all "Ready to Submit" |
| Screenshots / metadata | copied forward by ASC from 1.0.4 (4 slides @ 1320×2868) |
| What's New | was stale (board-fix only, predates the 1.0.5 features) |
| Review notes | 1.0.3 text carried forward, no Arrival Sync paragraph |
| `Tween Pro` subscription group | **1 subscription only** |
| `com.kavigandham.TweenApp.pro.annual` | **DOES NOT EXIST in ASC** |
| `…pro.monthly` | exists, Approved, priced **$1.99** (code assumes $4.99) |
| `…pro.lifetime` | exists, Approved, still on sale (should be Remove from Sale) |

## The one thing that is not a code problem

The shipped paywall offers a **yearly** plan that App Store Connect cannot sell,
because `…pro.annual` was never created. It degrades softly — `PaywallSheet.show()`
clamps the selection to whatever actually loaded — so monthly renders and is
buyable, and there is no 2.1(b) crash exposure. But the yearly card is absent and
the "Save 50%" line cannot render.

Yearly and the monthly repricing must land **together** (`savingsLine`,
`PaywallSheet.swift`): at $1.99/mo the annualised figure is $23.88, which is
*cheaper* than a $29.99 year, so creating yearly alone makes the headline plan the
worse deal and silently hides the savings line.

Both of those steps are human-only: creating/pricing an IAP is blocked for
automation, and the per-product **review screenshot upload** cannot be automated
at all (ASC rejects programmatic file input — four formats tried, 2026-08-31).

## Done in App Store Connect on 2026-10-13

- **Created `Tween Pro Annual`** — product ID `com.kavigandham.TweenApp.pro.annual`,
  Apple ID 6822410065, 1 year, status *Prepare for Submission*.
  Availability: 1 Year Upfront, **175 countries**. Price **$29.99** US with Apple's
  auto-calculated equivalents. Display name "Tween Pro Yearly", description
  "All of Tween Pro, billed once a year."
- **Monthly repriced $1.99 → $4.99**, scheduled to start **Oct 15, 2026**, 175
  countries, with **existing subscribers' price preserved** (no consent flow, no
  churn risk; analytics showed no active subscribers anyway).
- **`…pro.lifetime` → Remove from Sale** (NOT deleted — the accounts that bought it
  still verify against that product ID and there is no server to re-grant from).

### Still human-only on the annual

1. [ ] **Upload the review screenshot** — `submission/yearly-review-screenshot.png`.
       ASC rejects programmatic file input for screenshots (four formats tried,
       2026-08-31); this is the one step no automation can do, and the product
       cannot reach *Ready to Submit* without it.
2. [ ] **Move the annual to Level 1**, alongside the monthly. It was created at
       Level 2, which makes switching plans a downgrade rather than a crossgrade.
       Group page → Subscriptions → Edit → Edit Level → drag "Tween Pro Annual"
       onto the monthly's row. It is an HTML5 drag, which does not accept
       synthetic events — one real drag.

## Steps

1. [ ] Push the audit fixes to `main` → Xcode Cloud archives → new TestFlight build (**≥ 478**).
2. [ ] 1.0.5 version page → **Build → Add Build** → pick the newest (≥ 478).
3. [ ] Paste What's New from `metadata/whats-new-1.0.5.txt`.
4. [ ] Extend App Review notes with the Arrival Sync / mood search / My Places paragraph (below).
5. [ ] *(optional, decide first)* Create `…pro.annual` $29.99/yr in the Tween Pro group,
       same level as monthly; reprice monthly to $4.99; `…pro.lifetime` → **Remove from
       Sale (never Delete)**; upload the yearly review screenshot
       (`submission/yearly-review-screenshot.png`); attach both products to the submission.
6. [ ] **Add for Review → Submit**.

## Review-notes addition (1.0.5)

> NEW IN 1.0.5 — ARRIVAL SYNC: after a place is agreed, the person leaving first taps
> "I left". Tween measures that one real drive, turns it into an arrival time, and each
> other device works backwards to its own departure time. It is a Pro feature. The
> optional "time to head out" reminder is a LOCAL notification, requested only by the
> standalone app — the Messages extension never asks for notification permission, it
> only arms or cancels a reminder that is already authorised. Nothing is sent to a
> server; there is no server.
>
> MOOD SEARCH: the search field accepts plain language ("we're bored, but not food").
> It is resolved on-device into MapKit point-of-interest categories and keywords. No
> third-party service and no AI service is contacted.
>
> MY PLACES: the user may save their own Home address so "I'm in" can join without
> waiting for GPS. Saved places stay on the device; only the coordinate is copied into
> a meetup at join time, and the address is never placed in a message payload.
