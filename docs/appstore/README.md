# App Store screenshot pipeline

Two commands, from a booted simulator to uploadable slides.

```bash
# 1. Capture. -SHOT renders ONE surface edge to edge (TweenApp/ShotHarness.swift).
#    Do this TWICE: an iPhone 17 Pro Max into raw/, an iPad Pro 13" into raw-ipad/.
SIM=$(xcrun simctl list devices booted | grep "iPhone 17 Pro Max" | grep -o "[0-9A-F-]\{36\}")
xcrun simctl status_bar "$SIM" override --time "9:41" \
  --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3
for scene in fair vote plan; do
  xcrun simctl terminate "$SIM" com.kavigandham.TweenApp
  xcrun simctl launch "$SIM" com.kavigandham.TweenApp -SHOT "$scene"
  sleep 7   # the scene runs a real MKLocalSearch
  xcrun simctl io "$SIM" screenshot "raw/$scene.png"     # raw-ipad/ on the iPad pass
done

# 2. Compose.
xcrun swiftc -O compose.swift -o composebin && ./composebin
```

Output lands in `promo/` at **exactly 1320 × 2868** (6.9") and `promo-ipad/` at
**2064 × 2752** (iPad 13"). Upload both as-is — App Store Connect scales within
each device class but never between them, so an app that ships on iPad needs
both sets or iPad users see whatever was there last.

> **Do not run `sips` afterwards.** The old README told you to downscale to
> 1284 × 2778; `compose.swift` renders at the final size, so that step was
> resampling a finished composition and softening every glyph in the set. It
> is the single biggest reason the previous screenshots looked low-quality.

## Sizes

App Store Connect needs **one** iPhone set; it scales the rest.

| Display | Pixels | Use |
|---|---|---|
| iPhone 6.9" | 1320 × 2868 | **Upload this one**; ASC then shows "Using 6.9" Display" on the smaller slots |
| iPhone 6.5" | 1284 × 2778 | Accepted alternative — but don't downscale into it, re-capture |
| iPad 13" | 2064 × 2752 | Required while the app ships on iPad |

The **iMessage App** tab in Media Manager is a SEPARATE set with its own iPhone
and iPad slots — the extension has its own store page. Give it the three
extension scenes (`fair`, `vote`, `plan`); the host-app search slide doesn't
belong there.

## The scenes

| # | Scene | Headline | What's on screen |
|---|---|---|---|
| 1 | `fair` | Fair means fair | Both people pinned, real cafes ranked "You 10 · Kavi 8" |
| 2 | `vote` | Can't agree? Vote. | Two picks on the board, tied, with each one's drive times |
| 3 | `plan` | Then tell them you left | "It's a plan" + a friend's live ETA + Leaving now |
| 4 | — | Search like Maps | Host app search (`screenshots/04-search-like-maps.png`) |

Every headline describes something visible in its own capture. The previous
set promised "It lives in your chat" over a generic browse list and "Agree in
one tap" over a screen with no agree button on it.

## Why the captures look real without location services

`ShotHarness` seeds two coordinates (Oakland and Berkeley) and runs a **real
`MKLocalSearch`** around their midpoint, so the place names are genuine and the
drive times are computed by the real ranker. MapKit search needs no location
permission, which is what makes this work in a simulator that has no
CoreLocation at all.

The seed matters more than it sounds. `DebugLaunchSeed` — which the old
captures used — puts the two people in San Francisco and San Jose, 45 miles
apart, so every search returned 36-to-40-minute drives. The shipped
screenshots therefore argued *against* the product: the pitch is "a fair spot
between you", and the evidence on screen was an hour of driving to a place
called "Lalala". Oakland ↔ Berkeley is a meetup someone might actually have,
and the numbers sell the idea by themselves.

## Gotchas

- **The "◀ AppName" breadcrumb.** A cold `simctl launch` while another app was
  foregrounded stamps a back-to-app crumb into the status bar. Launch the same
  app twice (or capture the scenes in a loop, as above) and it disappears.
- **Give the scene ~7s.** It waits on a live MapKit search plus routing; a
  capture taken too early shows the spinner.

Copy for every slide, plus the full store listing, is in
[`../app-store.md`](../app-store.md).
