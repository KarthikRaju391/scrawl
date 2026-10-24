#!/bin/bash
# Every automated check, in the background (no focus, no cursor, no trackpad). Logs go to a temp folder;
# prints one line per suite. Usage: checks/run_all.sh [--no-release]
cd "$(dirname "$0")/.."
LOG=$(mktemp -d /tmp/td-runall.XXXX)
./build.sh >"$LOG/build.log" 2>&1 || { echo "FAIL build (see $LOG/build.log)"; exit 1; }
suites=(
  "bench|./build/bench data/passive-1.jsonl"
  "persist|checks/persist.sh"
  "cursor|checks/cursor.sh"
  "input|checks/input.sh"
  "aim|checks/aim.sh"
  "zoomlock|checks/zoomlock.sh"
  "autopan-centre|checks/autopan.sh --autopan centre"
  "autopan-left|checks/autopan.sh --autopan left"
  "autopan-off|checks/autopan.sh --autopan off"
  "ui|checks/ui.sh"
  "e2e-replay|checks/e2e.sh data/strokes-20261024-161939.jsonl"
  "session-replay|checks/cf_all.sh"
)
[ "${1:-}" = --no-release ] || suites+=("release-dmg|checks/release.sh")
bad=0
for s in "${suites[@]}"; do
  name=${s%%|*}; cmd=${s#*|}
  t0=$(date +%s)
  bash -c "$cmd" >"$LOG/$name.log" 2>&1; code=$?
  p=$(grep -c "^PASS" "$LOG/$name.log"); f=$(grep -c "^FAIL" "$LOG/$name.log")
  verdict=PASS; { [ $f -gt 0 ] || [ $code -ne 0 ] || grep -q "RESULT: FAIL" "$LOG/$name.log"; } && { verdict=FAIL; bad=$((bad + 1)); }
  printf "%-5s %-16s %3d pass %2d fail  %3ds  %s\n" $verdict "$name" "$p" "$f" $(( $(date +%s) - t0 )) "$LOG/$name.log"
done
echo "RESULT: $([ $bad = 0 ] && echo PASS || echo "FAIL ($bad suites)")  logs: $LOG"
