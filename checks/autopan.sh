#!/bin/sh
# Auto-pan end to end: checks/autopan.sh [--writing-off]. Simulated writer at zoom 3 writes 40
# letters left to right, continuing just right of its last ink as it appears on screen.
cd "$(dirname "$0")/.."
OUT=$(mktemp -d /tmp/td-autopan.XXXX)
TRACKPAD_DRAW_DATA=$OUT "build/Trackpad Draw.app/Contents/MacOS/TrackpadDraw" --test-autopan --no-activate "$@" >/dev/null 2>&1 &
PID=$!; sleep 1.2; WID=$(build/winid $PID); i=0
while [ ! -f "$OUT/ui-step.txt" ] && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); [ $i = 6 ] && screencapture -x -o -l"$WID" "$OUT/mid.png"; done
screencapture -x -o -l"$WID" "$OUT/final.png"; kill -TERM $PID
python3 -I - "$OUT/test-autopan.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print("writing mode:", r["writing"], " strokes:", r["strokes"], " letters:", r["letters"], " returns re-anchored:", r["returns"], " new lines:", r["newLines"])
print("letters overlapping the previous letter:", r["overlapsWithPreviousLetter"], " letters left of the previous (same row):", r["lettersLeftOfPrevious"], " rows:", r["lineRows"])
print("touch-down x on the pad: min %.2f max %.2f" % (min(r["touchX"]), max(r["touchX"])))
print("hint: before", r["hintBefore"], "after a stroke 1.1 screens down", r["hintAfterDeepStroke"], "| new page:", r["afterNewPage"], "back:", r["backToFirst"])
PY
echo "$OUT"
