#!/usr/bin/env bash
#
# Capture Tween's screens from a booted simulator, one PNG per (scene, appearance).
# Feeds the `screenshot-audit` agent (.claude/agents/screenshot-audit.md).
#
#   scripts/audit_screens.sh --list
#   scripts/audit_screens.sh --out /tmp/screens
#   scripts/audit_screens.sh --only home,results,place --appearance dark
#
# Assumes TweenApp is already built and installed on the target simulator.
# Build first with:
#   xcodebuild -project TweenApp.xcodeproj -scheme TweenApp -configuration Debug \
#     -destination "platform=iOS Simulator,id=$UDID" build
# (default DerivedData — see CLAUDE.md / the codesign xattr trap.)

set -euo pipefail

BUNDLE="com.kavigandham.TweenApp"
UDID="${TWEEN_SIM_UDID:-}"
OUT=""
APPEARANCE="both"
ONLY=""
SETTLE_SCALE="${TWEEN_SETTLE_SCALE:-1}"

# scene <name> <settle-seconds> <launch args...>
#
# Every -DEMO_* argument opts OUT of the first-run tour on its own; -SKIP_TUTORIAL
# is only needed for the states that seed nothing. -FORCE_TUTORIAL wins over both.
read -r -d '' SCENES <<'TABLE' || true
tour|6|-FORCE_TUTORIAL -DEMO_WHERE_ILL_BE
home|5|-SKIP_TUTORIAL
home-located|6|-DEMO_WHERE_ILL_BE
home-peek|5|-DEMO_WHERE_ILL_BE -START_AT_PEEK
results|11|-DEMO_CATEGORY_STUDY
place-card|7|-DEMO_SPOT_CARD -DEMO_SPOT_GROUP
place-sheet|12|-DEMO_SPOT_SHEET
place-sheet-large|12|-DEMO_SPOT_SHEET -DEMO_SPOT_SHEET_LARGE
route-ab|7|-DEMO_ROUTE_AB
solo-after-leave|8|-DEMO_SOLO_AFTER_LEAVE
groups-pro|6|-DEMO_GROUPS -DEMO_PRO_UNLOCKED
groups-locked|6|-DEMO_GROUPS -DEMO_PRO_LOCKED
friends|6|-HARNESS_HOST_FRIENDS -SKIP_TUTORIAL
rides|6|-HARNESS_HOST_RIDES -SKIP_TUTORIAL
spot-library|6|-DEMO_SPOT_LIBRARY -DEMO_PRO_UNLOCKED
spot-library-detail|7|-DEMO_SPOT_LIBRARY_DETAIL -DEMO_PRO_UNLOCKED
settings|5|-DEMO_SETTINGS
paywall|6|-DEMO_SETTINGS -DEMO_PAYWALL -DEMO_PAYWALL_PRICES
pro-nudge|5|-DEMO_PRO_NUDGE
referrals|6|-DEMO_REFERRALS
ext-invite|5|-HARNESS -HARNESS_INVITE
ext-meetup|5|-HARNESS -HARNESS_MEETUP
ext-proposal-draft|5|-HARNESS -HARNESS_PROPOSAL_DRAFT
ext-own-proposal|5|-HARNESS -HARNESS_OWN_PROPOSAL
ext-contested-vote|5|-HARNESS -HARNESS_CONTESTED_VOTE
ext-solo-waiting|5|-HARNESS -HARNESS_SOLO_WAITING
ext-no-results|5|-HARNESS -HARNESS_TWO_READY_NO_RESULTS
TABLE

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --list) printf '%s\n' "$SCENES" | cut -d'|' -f1; exit 0 ;;
    --out) OUT="$2"; shift 2 ;;
    --appearance) APPEARANCE="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --udid) UDID="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$UDID" ]; then
  UDID=$(xcrun simctl list devices booted | grep -m1 -o '[0-9A-F]\{8\}-[0-9A-F]\{4\}-[0-9A-F]\{4\}-[0-9A-F]\{4\}-[0-9A-F]\{12\}' || true)
fi
[ -n "$UDID" ] || { echo "No booted simulator. Boot one or pass --udid." >&2; exit 1; }

xcrun simctl get_app_container "$UDID" "$BUNDLE" >/dev/null 2>&1 \
  || { echo "$BUNDLE is not installed on $UDID — build and install it first." >&2; exit 1; }

[ -n "$OUT" ] || OUT="${TMPDIR:-/tmp}/tween-screens-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

case "$APPEARANCE" in
  both) MODES="light dark" ;;
  light|dark) MODES="$APPEARANCE" ;;
  *) echo "--appearance must be light, dark, or both" >&2; exit 2 ;;
esac

# A fixed status bar keeps the diff between two runs about the app, not the clock.
xcrun simctl status_bar "$UDID" override \
  --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 \
  --dataNetwork wifi --wifiBars 3 >/dev/null 2>&1 || true

echo "device : $UDID"
echo "out    : $OUT"

count=0
while IFS='|' read -r name settle args; do
  [ -n "$name" ] || continue
  if [ -n "$ONLY" ] && ! printf '%s' ",$ONLY," | grep -q ",$name,"; then continue; fi
  for mode in $MODES; do
    xcrun simctl ui "$UDID" appearance "$mode" >/dev/null 2>&1 || true
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    xcrun simctl launch "$UDID" "$BUNDLE" $args >/dev/null
    sleep "$(awk -v s="$settle" -v k="$SETTLE_SCALE" 'BEGIN{print s*k}')"
    shot="$OUT/${name}-${mode}.png"
    xcrun simctl io "$UDID" screenshot --type png "$shot" >/dev/null 2>&1
    printf '  %-22s %-5s %s\n' "$name" "$mode" "$(basename "$shot")"
    count=$((count + 1))
  done
done <<< "$SCENES"

xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl ui "$UDID" appearance light >/dev/null 2>&1 || true

# The manifest tells the audit agent which launch args produced which PNG, so a
# finding can be reproduced with one command.
{
  echo "# Tween screen capture — $(date '+%Y-%m-%d %H:%M')"
  echo "device: $UDID   bundle: $BUNDLE   commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo
  printf '%-24s %s\n' "FILE" "LAUNCH ARGS"
  while IFS='|' read -r name settle args; do
    [ -n "$name" ] || continue
    if [ -n "$ONLY" ] && ! printf '%s' ",$ONLY," | grep -q ",$name,"; then continue; fi
    for mode in $MODES; do
      [ -f "$OUT/${name}-${mode}.png" ] && printf '%-24s %s\n' "${name}-${mode}.png" "$args"
    done
  done <<< "$SCENES"
} > "$OUT/manifest.txt"

echo "captured $count screenshot(s) → $OUT"
