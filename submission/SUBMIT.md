# Tween 1.0.1 — submission checklist

Generated 2026-08-05. Two things ship together: the **app version** and the
**two in-app purchases**. IAPs submitted with a version go through review with
it; submitted alone they queue separately.

Everything below is a step **you** take in App Store Connect. Nothing here was
submitted automatically.

---

## 0. Two blockers, both spotted in App Store Connect on 2026-08-05

Neither is a code problem. Both stop a submission cold.

- [ ] **Version mismatch.** App Store Connect holds a **1.0** record ("Prepare
      for Submission") but the build is **1.0.1**. A version record only accepts
      builds whose `CFBundleShortVersionString` matches, so build 3 will reach
      TestFlight and then not appear in the build picker for that record.
      **Decided 2026-08-05:** edit the version number on the ASC page from 1.0
      to 1.0.1 — it is editable while the record is still in Prepare for
      Submission, and no rebuild is needed. Do NOT change `project.yml`; that
      would invalidate the build already uploading.

- [ ] **EU trader status (Digital Services Act).** App Store Connect is showing:
      trader status must be provided or apps are removed from the EU App Store.
      It gates submitting new apps and updates. Only an **Admin or Account
      Holder** can set it — if that is not you, this needs someone else first.

Unrelated but worth planning around: **App Store Connect is down for up to two
hours on August 8, 6 a.m. PDT.**

---

## 1. Wait for the build

Pushing to `main` triggers Codemagic (`codemagic.yaml` → `ios-testflight`),
which uploads to TestFlight. It does **not** submit for App Store review — that
is deliberate, and it means the steps below are still yours to do.

- Codemagic build: https://codemagic.io/apps
- Build appears under TestFlight → iOS builds, usually 5–15 min after the
  upload finishes (processing lag is Apple's, not the CI's).

Version **1.0.1**. The **build number is assigned by Codemagic**, not by this
repo: `codemagic.yaml` runs `plutil -replace CFBundleVersion "$BUILD_NUMBER"`
against both Info.plists *after* `xcodegen generate`, so whatever
`CFBundleVersion` says in `project.yml` is overwritten. Select whichever build
TestFlight shows as newest — do not go looking for a specific number, and do not
bother bumping `project.yml` to force one, because it has no effect here.

Note also that `ci_scripts/ci_post_clone.sh` means an **Xcode Cloud** pipeline
exists too, and it does NOT rewrite the build number. If both fire on a push to
`main`, two builds with different `CFBundleVersion`s race to upload. If you see
duplicate builds in TestFlight, that is why.

---

## 2. In-app purchases — do these FIRST

Both must be **Ready to Submit** before you can attach them to the version.
A missing review screenshot is the single most common rejection here.

| Product | ID | Type | Price |
|---|---|---|---|
| Tween Pro Lifetime | `com.kavigandham.TweenApp.pro.lifetime` | Non-Consumable | $9.99 |
| Tween Pro Monthly | `com.kavigandham.TweenApp.pro.monthly` | Auto-Renewable | $1.99/mo |

For **each** product:

- [ ] **Review screenshot** → upload `submission/paywall-review-screenshot.png`
      (in this folder). This is the required "Review Information" screenshot.
- [ ] **Review notes** — paste the text from §5 below.
- [ ] Display name and description filled in.
- [ ] Price tier matches the table above.
- [ ] Status reads **Ready to Submit**.

The monthly also needs, one time only:

- [ ] A **Subscription Group** (e.g. "Tween Pro") with a localised display name.
- [ ] **Subscription privacy policy URL** and **terms of use (EULA) URL** — the
      paywall already links both in-app; App Store Connect wants them again in
      the subscription metadata. Apple rejects auto-renewables missing these.

---

## 3. App version page

- [ ] Select the newest build (see §1 — the number comes from CI, not this repo).
- [ ] Under **In-App Purchases**, attach BOTH products to this version.
      Easy to miss — the section is below the screenshots and collapsed by
      default. If you skip it the app ships with a paywall whose products do
      not exist, and every purchase fails in production.
- [ ] Screenshots for every required device size.
- [ ] Description, keywords, support URL, marketing URL.
- [ ] **What's New** — suggested text in §6.
- [ ] Age rating questionnaire complete.
- [ ] Export compliance: `ITSAppUsesNonExemptEncryption` is already `false` in
      `project.yml`, so this should not prompt. If it does, answer **No**.

---

## 4. Privacy

- [ ] App Privacy → confirm the answers still match. Tween is serverless with
      no accounts: location is used on-device and never collected, and the app
      has no analytics or tracking SDKs.
- [ ] Both targets ship a `PrivacyInfo.xcprivacy` (app + Messages extension).

---

## 5. IAP review notes — paste this

> Tween Pro unlocks planning features for meetups scheduled in advance. Meeting
> right now is free and always will be.
>
> To reach the paywall: open the app, tap the "..." button at the top right of
> the map, choose Settings, then tap "Tween Pro". No prior setup is needed.
>
> The attached screenshot shows that screen: a Free vs Pro comparison and the
> two purchase options (Lifetime $9.99 one-time, Monthly $1.99). Restore
> Purchases is on the same screen.
>
> No account or login is required to test — the app has no server and no sign-in.

---

## 6. What's New — suggested

> Travel modes now work everywhere. Pick driving, transit, or walking and every
> time and every set of directions in the app follows it — including the ones
> your friends see.
>
> Tween Pro adds groups, saved addresses, scheduling ahead, leave-by reminders,
> and calendar sync.

---

## 7. Before you hit Submit

- [ ] Open the TestFlight build on a real device and buy Pro with a sandbox
      account. **This is not covered by any automated test in this repo** — the
      simulator cannot exercise a real StoreKit purchase, so the buy/restore
      round-trip has only ever been verified against the local StoreKit config.
- [ ] Confirm Restore Purchases works on a second device.
- [ ] Send a real iMessage proposal between two physical devices. The Messages
      extension's memory ceiling and delivery path cannot be verified in the
      simulator (see CLAUDE.md hard constraints).
