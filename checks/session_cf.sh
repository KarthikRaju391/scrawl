#!/bin/sh
# Re-run a recorded session through the app (background, virtual clock).
# Usage: checks/session_cf.sh <session.jsonl> <pause ms> <pan edge> [--legacy-edge] -> prints the output dir
cd "$(dirname "$0")/.."
OUT=$(mktemp -d /tmp/td-cf.XXXX)
TRACKPAD_DRAW_DATA=$OUT "build/Trackpad Draw.app/Contents/MacOS/TrackpadDraw" --test-session "$1" --pause-ms "$2" --pan-edge "$3" $4 --no-activate >/dev/null 2>&1 &
PID=$!
for i in $(seq 1 600); do [ -f "$OUT/ui-step.txt" ] && break; sleep 0.5; done
kill -TERM $PID 2>/dev/null; sleep 0.5
echo "$OUT"
