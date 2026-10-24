#!/bin/sh
# End-to-end: replay recorded strokes through the app's input callback, screenshot every 2 s,
# count ink on screen, report frames rendered vs presented and input->present latency.
# Usage: checks/e2e.sh <strokes.jsonl> [extra flags: --test-front --test-lock --no-activate]
cd "$(dirname "$0")/.."
OUT=$(mktemp -d /tmp/td-e2e.XXXX)
IN=$1; shift
START=$(date +%s)
TRACKPAD_DRAW_DATA=$OUT "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-replay "$IN" "$@" >/dev/null 2>&1 &
PID=$!
sleep 1.5
WID=$(build/winid $PID)
i=0
while [ $i -lt 30 ]; do
  sleep 2; i=$((i+1))
  screencapture -x -o -l"$WID" "$OUT/s$i.png"
  echo "t+$(( $(date +%s)-START ))s $(build/inkcount "$OUT/s$i.png")"
  [ -f "$OUT/test-replay-done.json" ] && break
done
sleep 1; screencapture -x -o -l"$WID" "$OUT/final.png"; echo "final: $(build/inkcount "$OUT/final.png")"
# Esc must leave draw mode and release the cursor (posted to the app; pass ESC=hid to use the HID stream).
build/sendkey ${ESC:-$PID}; sleep 1
echo "after Esc: $(cat "$OUT/test-exit.json" 2>/dev/null || echo 'draw mode NOT exited')"
screencapture -x -o -l"$WID" "$OUT/after-esc.png"
kill -TERM $PID; sleep 1
echo "report: $(cat "$OUT/test-replay-done.json" 2>/dev/null || echo 'NOT FINISHED')"
python3 -I checks/latency_report.py "$OUT"/strokes-*.jsonl
tail -1 "$OUT/watchdog.log" 2>/dev/null
echo "artifacts: $OUT"
