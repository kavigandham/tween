# Collaborator Setup — Building Tween on Mac

## Prerequisites
- macOS with Xcode 16+
- Homebrew (`brew`)

## First-Time Setup

```bash
# 1. Clone the repo
git clone <repo-url> && cd tween

# 2. Install xcodegen (generates .xcodeproj from project.yml)
brew install xcodegen

# 3. Generate the Xcode project
xcodegen generate

# 4. Open in Xcode
open TweenApp.xcodeproj
```

## Every Time You Pull

```bash
git pull
xcodegen generate    # regenerate project from updated project.yml
```

Then in Xcode: select iPhone 16 simulator, ⌘B to build, ⌘U to run tests.

## What to Check Per Phase

| Phase | What to Verify |
|-------|---------------|
| 01 | Project opens, both targets build, 7 unit tests pass |
| 02 | App launches to map, "I'm in" captures location, pins render |
| 03 | Search returns results, ranked by fairness when both coords present |
| 04 | Extension renders in iMessage (open Messages → Tween app drawer) |
| 05 | Friend roster persists, ping timestamps update |
| 06 | "Send to chat" hands off to extension, onboarding shows on first launch |
| 07 | All styling uses tokens, haptics fire, a11y labels present |
| 08 | Harness mode (`-HARNESS` launch arg) renders extension views, release build succeeds |

## Reporting Issues
If a phase doesn't build or tests fail, note:
- Which phase
- The exact error (screenshot or copy the build log)
- Whether it's a compile error, runtime crash, or test failure

The dev can then resume from that phase: `./orchestrator.sh <phase-name>`

## Two-iPhone Test (after Phase 08)
The final gate before TestFlight requires two physical iPhones:
1. Install Tween on both via Xcode (Run on device)
2. Open an iMessage thread between the two phones
3. Person A: tap Tween in app drawer → "I'm in"
4. Person B: receives bubble → tap → "I'm in"
5. Both see ranked fair spots
6. Person A picks a spot → sends bubble
7. Person B receives, can counter with a different spot

Simulator can't test MSMessage sending reliably — this must be on real devices.
