#!/bin/sh
# Aim-first mode end to end (background). Prints PASS/FAIL per case.
cd "$(dirname "$0")/.."
OUT=$(mktemp -d /tmp/td-aim.XXXX)
TRACKPAD_DRAW_DATA=$OUT "build/Trackpad Draw.app/Contents/MacOS/TrackpadDraw" --test-aim --no-activate >/dev/null 2>&1 &
PID=$!
for i in $(seq 1 60); do [ -f "$OUT/ui-step.txt" ] && break; sleep 0.5; done
kill -TERM $PID 2>/dev/null
python3 -I - "$OUT/test-aim.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
a = r["aimThenPress"]; chk(a["strokes"] == 1 and abs(a["firstInkX"] - 50.1) < 1.6 and a["leftmostInkX"] > 48.4, f"aim then press: ink starts at the press (x {a['firstInkX']:.1f} mm, leftmost {a['leftmostInkX']:.1f}; aiming ran 40-50 mm)")
q = r["quickPress"]; chk(q["strokes"] == 2 and abs(q["firstInkX"] - 30) < 0.15 and abs(q["firstInkY"] - 50) < 0.15, f"quick press: ink starts where the finger touched down ({q['firstInkX']:.2f}, {q['firstInkY']:.2f} mm vs 30, 50)")
chk(r["lightTap"]["newStrokes"] == 0, f"light tap: no ink ({r['lightTap']['newStrokes']} strokes)")
o = r["aimOffLightStroke"]; chk(o["newStrokes"] == 1 and abs(o["firstInkX"] - 20) < 0.6, f"aim off: a light stroke inks at once (x {o['firstInkX']:.2f} mm)")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
PY
