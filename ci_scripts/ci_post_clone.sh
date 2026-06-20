#!/bin/sh
# Xcode Cloud runs this after cloning the repo, before xcodebuild.
# Working dir is the script's directory (ci_scripts/), so cd to the
# cloned repo root before invoking xcodegen.
set -e

cd "$CI_PRIMARY_REPOSITORY_PATH"

if ! command -v brew >/dev/null 2>&1; then
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
fi

brew install xcodegen
xcodegen generate
