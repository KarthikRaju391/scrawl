#!/bin/sh
# Auto-pan end to end: checks/autopan.sh [--writing-off]. Simulated writer at zoom 3 writes 40
# letters left to right, continuing just right of its last ink as it appears on screen.
cd "$(dirname "$0")/.."
OUT=$(mktemp -d /tmp/td-autopan.XXXX)
TRACKPAD_DRAW_DATA=$OUT "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-autopan --no-activate "$@" >/dev/null 2>&1 &
PID=$!; sleep 1.2; WID=$(build/winid $PID); i=0
while [ ! -f "$OUT/ui-step.txt" ] && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); [ $i = 6 ] && screencapture -x -o -l"$WID" "$OUT/mid.png"; done
screencapture -x -o -l"$WID" "$OUT/final.png"; kill -TERM $PID
python3 -I - "$OUT/test-autopan.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print("auto-pan:", ["off", "centre", "left"][r["autoPan"]], " strokes:", r["strokes"], " auto-pans:", r["pans"], " new lines:", r["newLines"])
print("letters overlapping the previous letter:", r["overlapsWithPreviousLetter"], " rows (left edge of each):", [round(x) for x in r["rowStarts"]])
print("touch-down x on the pad: min %.2f max %.2f" % (min(r["touchX"]), max(r["touchX"])))
if r["wordStartAfterPan"]: print("after each auto-pan, the word just written starts at pad x:", " ".join(f"{x:.2f}" for x in r["wordStartAfterPan"]))
mode = ["off", "centre", "left"][r["autoPan"]]
ok = r["strokes"] == 90 and r["overlapsWithPreviousLetter"] == 0 and r["newLines"] >= 4 and ((r["pans"] == 0) if mode == "off" else (r["pans"] > 0))
print(("PASS" if ok else "FAIL"), f"writing mode ({mode}): every letter drawn (90), none overlapping, {r['newLines']} new lines, {r['pans']} auto-pans")
PY
echo "$OUT"
