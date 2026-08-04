# App Store metadata — Tween

Everything here is written to match what the app actually does. No feature is
claimed that isn't shipped — the paywall's five Pro features are all implemented
as of 2026-08-03.

---

## Name (30 char max)

```
Tween: Meet in the Middle
```
*24 chars.*

Alternate, if the above is taken:
```
Tween — Meet Halfway
```

## Subtitle (30 char max)

```
Fair meetup spots in iMessage
```
*29 chars.*

Alternates:
- `Find the fair place to meet` (27)
- `Halfway spots, right in chat` (28)

## Promotional text (170 char max — editable without review)

```
No more "where should we meet?" Share your spot in any iMessage chat and Tween ranks places by everyone's drive time — so nobody gets stuck with the whole drive.
```
*159 chars.*

---

## Description

```
Stop arguing about where to meet.

Tween lives inside iMessage. Open any chat, tap the + beside the text box, pick
Tween, and share where you are. As soon as your friend does the same, Tween
finds places between you and ranks them by how long each person actually has to
travel — not by distance on a map, but by real drive time.

The fairest spot wins. Nobody gets stuck with the whole drive.


EVERYTHING HAPPENS IN THE CHAT

Your friend doesn't need the app. They see the spot, the map, and everyone's
travel time right in the conversation, and can agree or suggest somewhere else
with one tap. The whole negotiation stays where you were already talking.


FAIR MEANS FAIR

Tween compares real travel times from everyone's location and shows each
person's minutes side by side. A spot that's ten minutes for you and forty for
them isn't a compromise, and Tween says so.

• Coffee, food, gas, or a place to study — pick a category or search by name
• Everyone's travel time on every option, at a glance
• Agree in one tap, or counter with somewhere better
• Open in Apple Maps or Google Maps — your choice
• Set a max drive time so far-flung places stop crowding the list


NO ACCOUNT. NO SERVER. NO TRACKING.

There's nothing to sign up for. Tween has no backend at all — your location
never touches a server we run, because we don't run one. Everything stays on
your device and travels only inside the iMessage conversations you choose.

Location is requested only while you're using the app, never in the background.


TWEEN PRO

For meetups you plan in advance:

• Groups & home bases — save where friends usually start from, then open a
  group for instant fair spots with nobody sharing live location
• Pick a day and time — spots ranked by the traffic predicted for when you'll
  actually arrive
• Any way you travel — fairness by driving, transit, or walking, mixed per
  person, so a bus rider isn't judged against a driver
• Leave-by reminders — a nudge when it's time to head out, re-checked against
  live traffic
• Calendar sync — drop the meetup into your calendar with one tap

Meeting up right now stays free, forever.

Tween Pro is available as a one-time purchase or a monthly subscription.
```

## Keywords (100 char max, comma-separated, no spaces after commas)

```
halfway,midpoint,meet,meetup,middle,friends,imessage,coffee,plans,fair,between,drive,commute,spot
```
*97 chars.*

Deliberately excludes the app name (already indexed) and plurals of words
already present (App Store stems automatically).

## What's New (for the first release)

```
First release.

Tween finds the fair place to meet, right inside iMessage — ranked by everyone's
real travel time, with no account and no server.
```

---

## Support & marketing URLs

| Field | Value |
|---|---|
| Support URL | `https://github.com/kavigandham/tween/issues` |
| Marketing URL | *(optional — leave blank until there's a real landing page)* |
| Privacy Policy URL | `https://github.com/kavigandham/tween/blob/main/docs/privacy.md` |

## App Privacy answers (App Store Connect questionnaire)

Answer these to match `docs/privacy.md`:

| Question | Answer |
|---|---|
| Do you collect data from this app? | **No** |

That single answer is correct and is the whole section. Tween has no analytics,
no third-party SDKs, and no server. Location, contacts, and calendar are used
on-device only and are never transmitted to us — under Apple's definition,
data that never leaves the device and is not shared with third parties is not
"collected".

If App Review pushes back, the supporting facts are: no networking code other
than Apple's own MapKit and StoreKit; no analytics or crash-reporting SDK;
`PrivacyInfo.xcprivacy` declares only the required-reason APIs actually used.

## Age rating

4+ — no objectionable content, no user-generated content, no web browsing.

## Category

- Primary: **Navigation**
- Secondary: **Social Networking**

Navigation primary is the honest fit (the core value is travel-time ranking) and
is far less crowded than Social Networking.

---

## Review notes (paste into App Review Information)

```
Tween is an iMessage app. Its main surface lives inside Messages, not in the
standalone app.

TO TEST THE CORE FEATURE:
1. Open Messages and start a conversation (a second simulator/device, or any
   real contact).
2. Tap the + beside the text field, then choose Tween.
3. Tap "I'm in" to share a location.
4. The other side taps "I'm in" too. Tween then ranks nearby places by both
   people's drive times.

The standalone app is for searching places, managing friends, and settings.

TWEEN PRO:
Pro features (groups, scheduling, transit/walking fairness, leave-by reminders,
calendar sync) can be unlocked without a purchase using the redeem code:

    HALFWAY2026

Enter it in Settings → "Have a code?".

NO ACCOUNT IS REQUIRED. There is no server, login, or backend of any kind.
```

---

## Screenshot plan (6.9" — 1320 × 2868)

Six slides, each a real screenshot under a short headline. Order matters: the
first two are what most people ever see.

| # | Headline | Sub | Screen |
|---|---|---|---|
| 1 | It lives in your chat | No app needed for your friend | Extension expanded, spot list with ETAs |
| 2 | Fair means fair | Everyone's drive time, side by side | Spot list close-up |
| 3 | Agree in one tap | Or counter with somewhere better | Proposal panel, action row |
| 4 | Search like Maps | Coffee, food, gas, or by name | Host app search + results |
| 5 | Plan it ahead | Time, transit, reminders — Tween Pro | Plan sheet, scheduled |
| 6 | No account. No server. | Your location never leaves your phone | Map with pins, clean |
