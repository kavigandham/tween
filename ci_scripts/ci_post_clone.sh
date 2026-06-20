#!/bin/sh
# Xcode Cloud runs this after cloning the repo, before xcodebuild.
# Regenerates TweenApp.xcodeproj from project.yml so the runner builds
# the same project local devs and Codemagic build.
set -e

if ! command -v brew >/dev/null 2>&1; then
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
fi

brew install xcodegen
xcodegen generate
