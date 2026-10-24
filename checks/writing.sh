#!/bin/sh
# Writing-mode simulation: checks/writing.sh [--writing-off]. Prints where each word started on
# the pad and where it landed on the page; saves the page PNG and mid-run screenshots.
cd "$(dirname "$0")/.."
OUT=$(mktemp -d /tmp/td-write.XXXX)
TRACKPAD_DRAW_DATA=$OUT "build/Trackpad Draw.app/Contents/MacOS/TrackpadDraw" --test-writing "$@" >/dev/null 2>&1 &
PID=$!
sleep 1.2; WID=$(build/winid $PID); i=0
while [ ! -f "$OUT/ui-step.txt" ] && [ $i -lt 40 ]; do sleep 2; i=$((i+1)); screencapture -x -o -l"$WID" "$OUT/s$i.png"; done
kill -TERM $PID
python3 -I - "$OUT/test-writing.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print("writing mode:", r["writing"], " strokes:", r["strokes"])
print("pad x where each word started:", [round(s["padX"], 2) for s in r["starts"]])
print("words that ran out of pad:", sum(int(s["overflow"]) for s in r["starts"]))
w = r["words"]
overl = sum(1 for a, b in zip(w, w[1:]) if abs(a["midY"] - b["midY"]) < 20 and b["minX"] < a["maxX"])
lines = 1 + sum(1 for a, b in zip(w, w[1:]) if b["midY"] < a["midY"] - 20)
print("words overlapping the previous word:", overl, " lines:", lines)
PY
echo "$OUT"
