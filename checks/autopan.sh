#!/bin/sh
# Auto-pan end to end: checks/autopan.sh [--writing-off]. Simulated writer at zoom 3 writes 40
# letters left to right, continuing just right of its last ink as it appears on screen.
cd "$(dirname "$0")/.."
OUT=$(mktemp -d /tmp/td-autopan.XXXX)
TRACKPAD_DRAW_DATA=$OUT "build/Trackpad Draw.app/Contents/MacOS/TrackpadDraw" --test-autopan "$@" >/dev/null 2>&1 &
PID=$!; sleep 1.2; WID=$(build/winid $PID); i=0
while [ ! -f "$OUT/ui-step.txt" ] && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); [ $i = 6 ] && screencapture -x -o -l"$WID" "$OUT/mid.png"; done
screencapture -x -o -l"$WID" "$OUT/final.png"; kill -TERM $PID
python3 -I - "$OUT/test-autopan.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); ev = r["events"]
print("writing mode:", r["writing"], " strokes:", r["strokes"], " pans:", r["pans"])
print("last-ink pad x after each letter:", " ".join(f"{e['lastInkPadX']:.2f}" for e in ev))
stuck = sum(1 for e in ev if e["lastInkPadX"] > 0.93)
print("letters written at the pad's right edge (no room left):", stuck)
PY
echo "$OUT"
