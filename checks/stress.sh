#!/bin/sh
# Performance under a full page: checks/stress.sh [count] [--zoomed]. Prints per-frame CPU/GPU and frame gaps.
cd "$(dirname "$0")/.."
OUT=$(mktemp -d /tmp/td-stress.XXXX)
TRACKPAD_DRAW_DATA=$OUT "build/Trackpad Draw Predict.app/Contents/MacOS/TrackpadDraw" --test-stress data/strokes-20261024-161939.jsonl --count ${1:-400} $2 >/dev/null 2>&1 &
PID=$!; sleep 1.2; WID=$(build/winid $PID)
for i in $(seq 1 30); do [ -f "$OUT/ui-step.txt" ] && break; sleep 0.5; [ $i = 6 ] && screencapture -x -o -l"$WID" "$OUT/mid.png"; done
screencapture -x -o -l"$WID" "$OUT/final.png"; kill -TERM $PID
cat "$OUT/test-stress.json"; echo; echo "$OUT"
