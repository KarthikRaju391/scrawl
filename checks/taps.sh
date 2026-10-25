#!/bin/bash
# Two-finger double tap = undo, three-finger double tap = redo, in draw mode (background).
cd "$(dirname "$0")/.."
D=$(mktemp -d /tmp/td-taps.XXXX)
TRACKPAD_DRAW_DATA=$D "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-taps >/dev/null 2>&1 &
P=$!; for _ in $(seq 1 60); do [ -f "$D/ui-step.txt" ] && break; sleep 0.25; done; kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D/test-taps.json" <<'PY'
import json, sys
s = {x["at"]: x for x in json.load(open(sys.argv[1]))["steps"]}; bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
def view(a): return (round(a["viewX"], 6), round(a["viewY"], 6), round(a["zoom"], 9))
b = s["three strokes"]
chk(b["strokes"] == 3, "start: three strokes")
u = s["two-finger double tap"]; chk(u["strokes"] == 2 and view(u) == view(b), f"two-finger double tap: exactly one undo ({b['strokes']} -> {u['strokes']}), the view didn't move")
chk(u["toast"] == "Undo" and u["redoEnabled"], f"…shows \"Undo\" ({u['toast']!r}) and enables Redo in the toolbar")
r = s["three-finger double tap"]; chk(r["strokes"] == 3 and view(r) == view(b) and r["toast"] == "Redo", f"three-finger double tap: exactly one redo (-> {r['strokes']}), \"Redo\" shown, view unchanged")
for at in ("single two-finger tap", "single three-finger tap", "slow double tap (0.6 s apart)", "two quick short two-finger pans"):
    chk(s[at]["strokes"] == 3, f"{at}: no undo or redo ({s[at]['strokes']} strokes), no ink")
chk(s["single two-finger tap"]["strokes"] == 3 and view(s["slow double tap (0.6 s apart)"]) == view(b), "taps leave the view where it was")
p = s["two-finger pan"]; chk(p["strokes"] == 3 and view(p) != view(b), "a two-finger pan still pans, and doesn't undo")
z = s["pinch"]; chk(z["strokes"] == 3 and z["zoom"] > p["zoom"] * 1.2, f"a pinch still zooms ({p['zoom']:.2f} -> {z['zoom']:.2f}), and doesn't undo")
w0, w1 = s["writing mode, one more stroke"], s["writing mode: two-finger double tap"]
chk(w1["strokes"] == w0["strokes"] - 1, f"writing mode: the double tap undoes the last stroke ({w0['strokes']} -> {w1['strokes']})")
n0, e0, e1 = s["a new line, eraser selected"], s["eraser stroke over a line"], s["eraser selected: two-finger double tap"]
chk(e0["strokes"] == n0["strokes"] - 1 and e1["strokes"] == e0["strokes"] + 1, f"eraser selected: the double tap undoes the erase ({e0['strokes']} -> {e1['strokes']}), not an empty step")
p0, p1 = s["a line to pan over, eraser selected"], s["eraser: one finger on the line, a second joins (pan)"]
chk(p1["strokes"] == p0["strokes"], f"eraser selected, one finger on a line and a second joining to pan: nothing erased ({p0['strokes']} -> {p1['strokes']})")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
PY
