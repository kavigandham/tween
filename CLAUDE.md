# Tween

A serverless, iMessage-native meetup coordinator. Two friends share locations; the app proposes the fairest places to meet by drive time.

## Environment
Xcode 26.5 is installed. Build and test locally: run `xcodegen generate` after adding/removing files (all targets use directory globs in `project.yml`), then `xcodebuild test -project TweenApp.xcodeproj -scheme TweenApp -destination 'platform=iOS Simulator,...'`. Extension memory profiling and real iMessage delivery still require physical devices.

## Stack
- Swift 5.9+, SwiftUI, iOS 17+ deployment target
- Apple Messages framework (MSMessagesAppViewController, MSMessage, MSConversation)
- CoreLocation, MapKit (MKLocalSearch, MKDirections, MKMapSnapshotter)
- App Group UserDefaults as cross-process IPC
- No server. No accounts. No backend. No third-party dependencies.

## Targets
| Target | Type | Bundle ID |
|--------|------|-----------|
| TweenApp | iOS App (SwiftUI lifecycle) | `com.kavigandham.TweenApp` |
| TweenMessages | Messages Extension | `com.kavigandham.TweenApp.messages` |
| TweenAppTests | Unit Test Bundle | `com.kavigandham.TweenApp.TweenAppTests` |
| TweenAppUITests | UI Test Bundle | `com.kavigandham.TweenApp.TweenAppUITests` |

App Group: `group.com.kavigandham.tween`

## Directory Structure
```
TweenApp/           Host app source
TweenMessages/      iMessage extension source
Shared/             Compiled into BOTH targets (not a framework)
TweenAppTests/      Unit tests
TweenAppUITests/    UI tests
```

Files in `Shared/` must be listed under BOTH `TweenApp` and `TweenMessages` sources in `project.yml`.

## HARD CONSTRAINTS — DO NOT VIOLATE

1. **Extension memory ceiling ~120 MB.** `MKMapSnapshotter` only — NEVER `MKMapView`, in every extension surface (`ExpandedView`, `CompactView`, `BubbleImageRenderer`). Cap ranking at 5 in extension, 8 in app. Cancel all Tasks in `willResignActive`. (A flag-disabled interactive `Map` once lived in `ExpandedView`; deleted 2026-07-14 — resurrect only from git history WITH on-device memory profiling.)

2. **`MSMessage.url` ≤ 5000 chars, `https`/`file` scheme only.** Coordinates + spot name only. Never route geometry.
   - Every wire string is BOUNDED, and bounded by its ENCODED length, not its grapheme count — `participantNameAllowed` is ASCII-only, so one 60-grapheme emoji name is ~4500 encoded chars and makes every send in that conversation fail (`TweenState.boundedName` / `boundedKey`, pen-test 2026-10-13). That includes `t` (the spot name), `from`, `p`, `pids`, `pj`, `agreed`, `agreedIds` and `gone`.
   - Every wire LIST is bounded too: `maxParticipants = 32` (the iMessage group maximum) and `maxNameListCount = 64`. An unbounded roster was a one-bubble extension DoS.
   - `encodedURL()` filters `isManual` participants once, at the top, because `p=`/`pids=`/`pj=`/`opts`/`votes`/`tt` are all indexed against that same array.

3. **Compact view = keyboard height.** No first responder, no keyboard, no text input.

4. **Location: When-In-Use only.** `NSLocationWhenInUseUsageDescription` in the EXTENSION'S Info.plist. Retain `CLLocationManager`.

5. **No API keys** in code or URLs.

6. **App Group UserDefaults is unencrypted.** Coordinates and preferences only.
   - *Sanctioned exception (product decisions 2026-07-06, 2026-08-02):* `FriendRoster` (`Shared/TweenFriend.swift`) persists friend display name, optional CNContact identifier, and phone/email handle — so ping compose keeps working even if Contacts access is later revoked. Pro adds per-friend saved addresses — a list of `FriendPlace` (label + coordinate), generalising the original single home base — and `GroupStore` (`Shared/FriendGroup.swift`) persists named groups of friend-ID references. Home bases are LOCAL planning data: they seed `manual:` participants for group searches and are never broadcast in any payload. Nothing else PII-bearing may be added.
   - *Sanctioned exception (product decision 2026-09-21):* `MyPlaceStore` (`Shared/MyPlaces.swift`) persists the LOCAL user's own saved places — Home in V1 — as label + formatted address + coordinate, so "I'm in" can offer "From Home" without a GPS wait. Same contract as a friend's saved address and then some: the formatted address is display sugar for the owner's own screens only, and no encoder puts a `MyPlace` (or its `address`) into an `MSMessage` payload, a group record, or a participant. A join COPIES the coordinate as a declared location (`JoinOrigin`), so a participation's origin is a snapshot and editing Home later never rewrites a meetup already in flight. Per-group Tween history (`GroupTween`) is names and dates, never coordinates.

7. **`@Observable`**, not `ObservableObject`. `@State` owns, `@Bindable` for two-way.

8. **No server, no accounts, no backend.**

## Product shape (decided 2026-10-13)

- **Free is bare bones; Pro is everything else.** Free: Tween finds a fair place,
  you share it in the chat, and everyone sees the travel times that prove it is
  fair. Pro: mood search, saved places (yours AND a friend's), favourites,
  declared locations, groups, day/time planning, per-person travel modes,
  leave-by reminders, calendar, Arrival Sync. The paywall's comparison table in
  `PaywallSheet.comparisonRows` must stay a truthful mirror of the real
  `ProEntitlement.isUnlocked` gates — every Pro row names a gate that exists.
- **The first-run tour is the DEMONSTRATION, not a tour of the app.** Five steps
  plus the Pro card: welcome → I'm in → search → open a spot → send it to the
  chat. It was twelve and people skipped it, which meant they skipped the part
  that matters. Do not re-add "here is another screen" steps.

## Conventions
- Atomic single-key JSON writes to App Group (prevents torn reads)
- All styling through `Shared/Tokens.swift`
- Tests reset App Group UserDefaults in `setUp()`
- Conventional commit messages: `feat:`, `fix:`, `test:`, `refactor:`, `chore:`, `polish:`
- After completing a phase, run `git add -A && git commit` with the specified message
