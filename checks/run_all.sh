#!/bin/bash
# Every automated check, in the background (no focus, no cursor, no trackpad). Logs go to a temp folder;
# prints one line per suite. Usage: checks/run_all.sh [--no-release]
cd "$(dirname "$0")/.."
LOG=$(mktemp -d /tmp/td-runall.XXXX)
./build.sh >"$LOG/build.log" 2>&1 || { echo "FAIL build (see $LOG/build.log)"; exit 1; }
suites=(
  "bench|./build/bench data/passive-1.jsonl"
  "persist|checks/persist.sh"
  "real-folder-untouched|checks/real-folder.sh"
  "bundle-intact|checks/bundle-intact.sh"
  "ink-jitter|checks/jitter.sh"
  "cursor|checks/cursor.sh"
  "input|checks/input.sh"
  "mapping|checks/mapping.sh"
  "edge-guard|checks/edge.sh"
  "keys|checks/keys.sh"
  "modes-matrix|checks/modes.sh"
  "tool-enters-draw|checks/tooldraw.sh"
  "tap-gestures|checks/taps.sh"
  "posthog-sink|checks/posthog.sh"
  "arrow-keys|checks/arrowkeys.sh"
  "overview-highlight|checks/gallerykeys.sh"
  "overview-order|checks/galleryorder.sh"
  "voiceover-toolbar|checks/a11y.sh"
  "menus|checks/menus.sh"
  "export-sheet|NO_BENCH=1 checks/export.sh"
  "select-tool|NO_BENCH=1 checks/select.sh"
  "select-bar|checks/selectbar.sh"
  "pill-labels|checks/toast.sh"
  "newline|checks/newline.sh"
  "page-edges|checks/page.sh"
  "gallery|checks/gallery.sh"
  "gallery-speed|checks/gallery_speed.sh"
  "page-arrows|checks/arrows.sh"
  "page-dates|checks/meta.sh"
  "zoomlock|checks/zoomlock.sh"
  "pan-moves|checks/pan.sh"
  "writing-flow|checks/autopan.sh"
  "ui|checks/ui.sh"
  "e2e-replay|checks/e2e.sh data/strokes-20261024-161939.jsonl"
  "session-replay|checks/cf_all.sh"
  "edge-replay|checks/edge_cf.sh"
)
[ "${1:-}" = --no-release ] || suites+=("release-dmg|checks/release.sh")
bad=0; skipped=0
for s in "${suites[@]}"; do
  name=${s%%|*}; cmd=${s#*|}
  t0=$(date +%s)
  bash -c "$cmd" >"$LOG/$name.log" 2>&1; code=$?
  p=$(grep -c "^PASS" "$LOG/$name.log"); f=$(grep -c "^FAIL" "$LOG/$name.log"); k=$(grep -c "^SKIP" "$LOG/$name.log")
  skipped=$((skipped + k))
  verdict=PASS; { [ $f -gt 0 ] || [ $code -ne 0 ] || grep -q "RESULT: FAIL" "$LOG/$name.log"; } && { verdict=FAIL; bad=$((bad + 1)); }
  printf "%-5s %-16s %3d pass %2d fail %2d skipped  %3ds  %s\n" $verdict "$name" "$p" "$f" "$k" $(( $(date +%s) - t0 )) "$LOG/$name.log"
  grep "^SKIP" "$LOG/$name.log" | sed 's/^/        /'
done
echo "RESULT: $([ $bad = 0 ] && echo PASS || echo "FAIL ($bad suites)")$([ $skipped -gt 0 ] && echo ", $skipped checks skipped (listed above)")  logs: $LOG"
