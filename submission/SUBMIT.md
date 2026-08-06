# Tween 1.0.1 (build 3) — submission checklist

Generated 2026-08-05. Two things ship together: the **app version** and the
**two in-app purchases**. IAPs submitted with a version go through review with
it; submitted alone they queue separately.

Everything below is a step **you** take in App Store Connect. Nothing here was
submitted automatically.

---

## 0. Wait for the build

Pushing to `main` triggers Codemagic (`codemagic.yaml` → `ios-testflight`),
which uploads to TestFlight. It does **not** submit for App Store review — that
is deliberate, and it means the steps below are still yours to do.

- Codemagic build: https://codemagic.io/apps
- Build appears under TestFlight → iOS builds, usually 5–15 min after the
  upload finishes (processing lag is Apple's, not the CI's).

Version **1.0.1**, build **3**. Build 2 was never tagged in git, so if App Store
Connect already shows a build 3, bump `CFBundleVersion` in `project.yml` (BOTH
targets — app and extension must match), run `xcodegen generate`, and push again.

---

## 1. In-app purchases — do these FIRST

Both must be **Ready to Submit** before you can attach them to the version.
A missing review screenshot is the single most common rejection here.

| Product | ID | Type | Price |
|---|---|---|---|
| Tween Pro Lifetime | `com.kavigandham.TweenApp.pro.lifetime` | Non-Consumable | $9.99 |
| Tween Pro Monthly | `com.kavigandham.TweenApp.pro.monthly` | Auto-Renewable | $1.99/mo |

For **each** product:

- [ ] **Review screenshot** → upload `submission/paywall-review-screenshot.png`
      (in this folder). This is the required "Review Information" screenshot.
- [ ] **Review notes** — paste the text from §4 below.
- [ ] Display name and description filled in.
- [ ] Price tier matches the table above.
- [ ] Status reads **Ready to Submit**.

The monthly also needs, one time only:

- [ ] A **Subscription Group** (e.g. "Tween Pro") with a localised display name.
- [ ] **Subscription privacy policy URL** and **terms of use (EULA) URL** — the
      paywall already links both in-app; App Store Connect wants them again in
      the subscription metadata. Apple rejects auto-renewables missing these.

---

## 2. App version page

- [ ] Select build **3**.
- [ ] Under **In-App Purchases**, attach BOTH products to this version.
      Easy to miss — the section is below the screenshots and collapsed by
      default. If you skip it the app ships with a paywall whose products do
      not exist, and every purchase fails in production.
- [ ] Screenshots for every required device size.
- [ ] Description, keywords, support URL, marketing URL.
- [ ] **What's New** — suggested text in §5.
- [ ] Age rating questionnaire complete.
- [ ] Export compliance: `ITSAppUsesNonExemptEncryption` is already `false` in
      `project.yml`, so this should not prompt. If it does, answer **No**.

---

## 3. Privacy

- [ ] App Privacy → confirm the answers still match. Tween is serverless with
      no accounts: location is used on-device and never collected, and the app
      has no analytics or tracking SDKs.
- [ ] Both targets ship a `PrivacyInfo.xcprivacy` (app + Messages extension).

---

## 4. IAP review notes — paste this

> Tween Pro unlocks planning features for meetups scheduled in advance. Meeting
> right now is free and always will be.
>
> To reach the paywall: open the app, tap the avatar in the top right of the
> search sheet to open Friends, then tap any group under "Groups". Groups are a
> Pro feature, so the Tween Pro screen appears.
>
> The attached screenshot shows that screen: a Free vs Pro comparison and the
> two purchase options (Lifetime $9.99 one-time, Monthly $1.99). Restore
> Purchases is on the same screen.
>
> No account or login is required to test — the app has no server and no sign-in.

---

## 5. What's New — suggested

> Travel modes now work everywhere. Pick driving, transit, or walking and every
> time and every set of directions in the app follows it — including the ones
> your friends see.
>
> Tween Pro adds groups, saved addresses, scheduling ahead, leave-by reminders,
> and calendar sync.

---

## 6. Before you hit Submit

- [ ] Open the TestFlight build on a real device and buy Pro with a sandbox
      account. **This is not covered by any automated test in this repo** — the
      simulator cannot exercise a real StoreKit purchase, so the buy/restore
      round-trip has only ever been verified against the local StoreKit config.
- [ ] Confirm Restore Purchases works on a second device.
- [ ] Send a real iMessage proposal between two physical devices. The Messages
      extension's memory ceiling and delivery path cannot be verified in the
      simulator (see CLAUDE.md hard constraints).
