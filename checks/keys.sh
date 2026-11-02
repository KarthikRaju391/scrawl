#!/bin/bash
# Single-key shortcuts toggle: each key pressed twice comes back to where it started (background).
cd "$(dirname "$0")/.."
D=$(mktemp -d /tmp/td-keys.XXXX)
TRACKPAD_DRAW_DATA=$D "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-keys >/dev/null 2>&1 &
P=$!; for _ in $(seq 1 60); do [ -f "$D/ui-step.txt" ] && break; sleep 0.25; done; kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D/test-keys.json" <<'PY'
import json, sys
st = {s["after"]: s for s in json.load(open(sys.argv[1]))["steps"]}; bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
want = [  # step, field, value
    ("D", "draw", True), ("P on pen, no other tool used yet", "tool", "pen"),
    ("D again", "draw", False), ("D (back on)", "draw", True),
    ("W", "writing", True), ("W again", "writing", False),
    ("L", "zoomLocked", True), ("L again", "zoomLocked", False), ("Z", "zoomLocked", True), ("Z again", "zoomLocked", False),
    ("M", "tool", "marker"), ("M again", "tool", "pen"), ("H", "tool", "highlighter"), ("H again", "tool", "pen"),
    ("E", "tool", "eraser"), ("E again", "tool", "pen"), ("S", "tool", "select"), ("S again", "tool", "pen"),
    ("P on pen (last other tool: select)", "tool", "select"), ("P again", "tool", "pen"),
    ("P (from highlighter)", "tool", "pen"), ("P again (back to highlighter)", "tool", "highlighter"),
    ("D (enter)", "draw", True), ("Esc", "draw", False),
]
for step, field, v in want:
    chk(st[step][field] == v, f"{step}: {field} = {st[step][field]}")
sync = [k for k, s in st.items() if s["toolbarTool"] != s["tool"] or s["toolbarZoomLocked"] != s["zoomLocked"]
        or s["toolbarWriting"] != s["writing"] or s["toolbarDraw"] != s["draw"]]
chk(not sync, f"toolbar matches after every press ({len(st)} steps; out of sync: {sync})")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
PY
