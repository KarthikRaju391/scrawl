#!/bin/sh
# Simulated hand A/B (background): checks/hand.sh <on|off> <seed> [sigma]
# Prints placement error of stroke starts vs the intended spot (mm on the pad), by context, and OCR.
cd "$(dirname "$0")/.."
OUT=$(mktemp -d /tmp/td-hand.XXXX)
TRACKPAD_DRAW_DATA=$OUT "build/Trackpad Draw.app/Contents/MacOS/TrackpadDraw" --test-hand /tmp/hershey-dl --rejoin "$1" --seed "$2" --sigma "${3:-1.9}" --no-activate >/dev/null 2>&1 &
PID=$!
for i in $(seq 1 240); do [ -f "$OUT/ui-step.txt" ] && break; sleep 0.5; done
kill -TERM $PID 2>/dev/null
TEXT=$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['text'])" "$OUT/test-hand.json")
OCR=$(build/ocr_text "$OUT/page.png" "$TEXT" | grep "OFF" | grep -o "[0-9.]*%")
python3 -I - "$OUT/test-hand.json" "$OCR" <<'PY'
import json, sys, math, statistics as st
r = json.load(open(sys.argv[1])); plan, drawn = r["plan"], r["drawn"]
assert len(plan) == len(drawn), (len(plan), len(drawn))
# Relative placement: each stroke's start measured from the previous stroke's end, vs intended.
rel = {}
for i in range(1, len(plan)):
    p0, p1, d0, d1 = plan[i - 1], plan[i], drawn[i - 1], drawn[i]
    if p1["ctx"] == "newWord": continue
    ix, iy = p1["x"] - p0["ex"], p1["y"] - p0["ey"]
    dx, dy = d1[0] - d0[2], d1[1] - d0[3]
    rel.setdefault(p1["ctx"], []).append(math.hypot(dx - ix, dy - iy))
row = {"snap": r["rejoin"], "seed": r["seed"], "snapped": r["snapped"], "ocr": sys.argv[2]}
for k in ("rejoin", "inWord"):
    if k in rel: row[k + "_relErr_mm"] = round(st.mean(rel[k]), 2); row[k + "_n"] = len(rel[k])
print(json.dumps(row))
PY
PY
