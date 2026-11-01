#!/bin/bash
# Edge guard through the real input path, with the guard at its default (5%) and, as a control, off.
cd "$(dirname "$0")/.."
D=$(mktemp -d /tmp/td-edge.XXXX)
TRACKPAD_DRAW_DATA=$D "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-edge >/dev/null 2>&1 &
P=$!; for _ in $(seq 1 60); do [ -f "$D/ui-step.txt" ] && break; sleep 0.25; done; kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D/test-edge.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
home = r["strokeStartingInBand"]["viewY"]
still = lambda s: abs(s["zoom"] - 3) < 1e-6 and abs(s["viewX"]) < 1e-6 and abs(s["viewY"] - home) < 1e-6
chk(abs(r["guard"] - 0.05) < 1e-9, f"default edge guard 5% ({r['guard'] * r['padMM'][0]:.1f} mm at the sides, {r['guard'] * r['padMM'][1]:.1f} mm top/bottom)")
s = r["strokeStartingInBand"]; chk(s["strokes"] == 0 and still(s), "strokes starting in the side or bottom band: no ink, no pan")
s = r["palmOnSideThenStroke"]; chk(s["strokes"] == 1 and s["points"][0] > 300 and still(s), f"palm resting on the side, then a stroke: one full stroke ({s['points']} pts), view unchanged")
s = r["palmLandsMidStroke"]; chk(s["strokes"] == 1 and s["points"][0] > 250 and still(s), f"palm lands on the side mid-stroke: the stroke carries on ({s['points']} pts), no pan or zoom")
s = r["pinchWithThumbOnBottom"]; chk(s["strokes"] == 0 and abs(s["zoom"] - s["want"]) < 0.03 * s["want"], f"thumb resting on the bottom during a real pinch: the pinch zooms 3 -> {s['zoom']:.2f} (fingers spread 3x; want {s['want']:.2f}, from where it left the dead zone; a pinch snaps near whole zooms)")
s = r["panWithOneFingerInBand"]; chk(still(s), f"two fingers, one in the band: no pan or zoom (the inner finger alone draws: {s['strokes']} stroke)")
s = r["strokeIntoBand"]; chk(s["strokes"] == 1 and s["lastInk"][0] < 0 and s["firstInk"][0] > 0.25, f"stroke starting inside and running into the band: kept, ink reaches the edge (ends at {s['lastInk'][0]:+.3f} of the view)")
for c in r["cornerStrokes"]:
    (a, b), (x, y) = c["firstInk"]
    chk(max(abs(a), abs(b), abs(x - 1), abs(y - 1)) < 0.002, f"{int(c['view'][0])}x{int(c['view'][1])}: strokes from the active area's corners start at the view's corners ({a:.4f},{b:.4f}) / ({x:.4f},{y:.4f})")
# Control: guard off, the same input misbehaves (so the checks above can fail).
o = r["off.strokeStartingInBand"]; p = r["off.palmOnSideThenStroke"]; m = r["off.palmLandsMidStroke"]
chk(o["strokes"] == 2 and p["strokes"] == 0 and not still(p) and not still(m),
    f"control, guard off: band strokes ink ({o['strokes']}), a resting palm turns strokes into zoom/pan (zoom {p['zoom']:.2f}, {m['zoom']:.2f})")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
PY
