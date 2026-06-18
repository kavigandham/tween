# Tween — Automated Build Orchestrator

## What This Does
Feeds 8 phase prompts to Claude Code sequentially, writing all Swift source from scratch. Your collaborator pulls the repo and builds on a Mac with Xcode.

## Your Setup (no Xcode needed)

```bash
# 1. Create project directory
mkdir tween && cd tween && git init

# 2. Copy these files in, preserving structure:
#    CLAUDE.md, orchestrator.sh, prompts/, project.yml

# 3. Make orchestrator executable
chmod +x orchestrator.sh

# 4. Run
./orchestrator.sh

# 5. After each phase (or after all 8), push
git push origin main
```

## What the Orchestrator Does
Runs `prompts/01-scaffold.md` through `08-tests-testflight.md` in order. After each phase it checks that expected files exist and are non-empty. There's no compilation gate — your friend is the build gate.

## Collaborator's Setup (Mac with Xcode)
See `FRIEND_SETUP.md` — they pull the repo, generate the Xcode project from `project.yml`, build, and test.

## Resuming After a Failure
```bash
./orchestrator.sh 04-imessage-extension
```

## Phase Summary
| # | What It Builds |
|---|---------------|
| 01 | Directory structure, project.yml, core models (TweenState, LocationCache, LocationProvider) |
| 02 | Host app map, "I'm in" flow, pin views, bottom sheet |
| 03 | Search, FairnessRanker, result rows, category chips |
| 04 | iMessage extension, CompactView, ExpandedView, BubbleImageRenderer |
| 05 | Friend roster, contact picker, ping log, reply banner |
| 06 | Host→extension hand-off, spot detail, onboarding tutorial |
| 07 | Design tokens, animations, haptics, accessibility |
| 08 | UI test harness, privacy manifest, release config, metadata |
