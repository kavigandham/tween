# Tween 1.0.3 — submission checklist

Prepared 2026-09-11. Everything below is a step **you** take in App Store
Connect. Nothing here was submitted automatically.

Build: **1.0.3**, pushed to `main` — Xcode Cloud's TestFlight workflow and
Codemagic both build it. Take the **newest 1.0.3 build** in TestFlight → iOS
builds (neither CI publishes release notes, so the build number is the only
marker; newest = this code). The tour was verified end to end on an iPhone 17 Pro
and an **iPad Air 11" (M4)** simulator — App Review last used an iPad Air.

---

## 0. Before you start

- [ ] **Version record.** ASC has a **1.0.2** record in "Prepare for
      Submission" (created 2026-09-03 to drop the preview videos). The build is
      **1.0.3**, and a record only accepts builds whose version matches. On the
      version page, edit the version number **1.0.2 → 1.0.3** (editable while
      unsubmitted). Don't change `project.yml` — the repo already says 1.0.3.
- [ ] **Paid Apps agreement** still **Active** (Business → Agreements). Without
      it StoreKit vends nothing and the paywall can't be reviewed.
- [ ] **Test on a real phone first** (the simulator has no Messages app):
  1. Fresh install → the tour runs start to finish; nothing outside the
     highlighted control responds; Skip works on every card.
  2. Friends → **Invite** → the Messages composer opens with a Tween invite
     bubble. Send it to a second phone that doesn't have Tween.
  3. On the second phone: tap the bubble → App Store → install → tap the bubble
     again → **"Hassan invited you · Tell Hassan"** → tap it.
  4. Back on your phone: tap their bubble → "Kavi is on Tween ✓ — 1 of 3".
     Open Tween → the Friends card reads "1 of 3 joined".
  5. Open directions to Maps three times, come back → the Pro ad appears once.

## 1. Version page

- [ ] **Build:** select the newest 1.0.3 build.
- [ ] **What's New in This Version** (paste):

```
• A guided tour on first launch — it walks you through finding a fair spot, step by step. Replay it any time from the ⋯ menu.
• Invite friends right from Tween. When 3 friends join, you get 3 months of Tween Pro free.
• A cleaner Friends screen.
• Smoother scrolling and dragging, and the map now opens where you are.
```

- [ ] **Review notes** (App Review Information → Notes, paste):

```
Tween works without accounts or a server. To see the core flow: open the app, follow the short tour (or tap Skip), tap a category such as Coffee, and open a result.

Tween Pro is sold through the two in-app purchases attached to this submission (Lifetime and Monthly). The paywall is reachable from the ⋯ menu (Tween Pro) or from Friends → Get Pro.

Referral reward: a user can also earn 3 months of Tween Pro by inviting friends. A friend counts only after they install Tween and send a Tween message back from their own copy — it can't be triggered by a code, a link, or by the user alone, and it grants a time-limited version of the same features the in-app purchases unlock. The in-app purchases remain the way to buy Pro, and the paywall offers them to referral users too.

The app requests an App Store rating only through Apple's standard review prompt.
```

## 2. The one real review risk: the referral reward

Guideline **3.1.1** says apps may not use their own mechanisms to unlock
content or functionality, and **3.2.2** bars rewarding users for taking
"similar actions" (downloading other apps, watching ads). Referral rewards for
digital features do ship on the App Store (cloud storage apps have long given
extra space for invites), and Tween's is earned only by real installs — but a
reviewer can read it as an unlock outside IAP.

If it is rejected under 3.1.1 or 3.2.2, the fastest fix is a **one-line
switch-off, no redesign**: gate the grant in `ProEntitlement.referralGrantUntil`
(return `nil`) and hide the referral card and paywall row, then resubmit. The
invite bubble itself (with its App Store link) is ordinary sharing and can
stay. A compliant replacement for the reward is an Apple **Offer Code** for the
monthly subscription shown at 3 referrals — Apple issues and redeems it.

## 3. Submit

- [ ] Add for Review → Submit. Attach the IAPs only if their status asks for it
      (they were approved with 1.0.1).

## What changed since 1.0.2 (for your reference)

- First-run tour: 11 steps, every screen explained; the spotlight performs the
  step's action and nothing else, the sheet is locked while a step is up, an
  animated hand and a "Tap Coffee ↑" pill name the control, a spinner shows
  while a step works.
- Referrals (invite bubble → "Tell Hassan" reply → counted), Pro via referrals,
  Pro pop-ups (random 1–10 good moments) and a Pro ad on return from Maps,
  Apple's review prompt.
- Friends screen rebuilt; opaque sheet at full height; lag fixes (sheet drag,
  typing, results); map opens on your location.
- Hardening: two crash guards in the message codec (absurd revision numbers,
  impossible coordinates in the roster), stored state survives app updates,
  own-proposal detection by install id.
