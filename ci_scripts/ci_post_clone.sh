#!/bin/sh
# Xcode Cloud runs this after cloning the repo, before xcodebuild. It
# regenerates TweenApp.xcodeproj from project.yml (the source of truth) with
# XcodeGen.
#
# TweenApp.xcodeproj is ALSO committed to git, so a transient failure
# installing XcodeGen must NOT hard-fail the whole archive. Previously
# `set -e` + a flaky `brew install xcodegen` (a network/Homebrew hiccup in
# the Xcode Cloud runner) aborted ci_post_clone and blocked the TestFlight
# build entirely — the same commit passed on one workflow run and failed on
# another. Now XcodeGen is best-effort: regenerate when it's available, and
# otherwise fall back to the committed project so the build always proceeds.
set -e

cd "$CI_PRIMARY_REPOSITORY_PATH"

# De-flake / speed up Homebrew in CI.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_INSTALL_UPGRADE=1

# Put brew on PATH (Apple Silicon default is /opt/homebrew).
if ! command -v brew >/dev/null 2>&1; then
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null || true)"
fi

# The `if` condition is exempt from `set -e`, so a failed install drops to the
# fallback instead of aborting. A failure of `xcodegen generate` itself IS a
# real error and still stops the build (set -e), since it means project.yml is
# broken.
if command -v brew >/dev/null 2>&1 && brew install xcodegen; then
  echo "ci_post_clone: regenerating TweenApp.xcodeproj from project.yml"
  xcodegen generate
else
  echo "ci_post_clone: WARNING — xcodegen unavailable; building the committed TweenApp.xcodeproj as-is"
fi
