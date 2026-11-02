#!/bin/bash
# Picking a tool outside draw mode turns draw mode on with that tool, ready to use (background).
cd "$(dirname "$0")/.."
D=$(mktemp -d /tmp/td-tool.XXXX)
TRACKPAD_DRAW_DRYLOCK=1 TRACKPAD_DRAW_DATA=$D "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-tooldraw >/dev/null 2>&1 &
P=$!; for _ in $(seq 1 60); do [ -f "$D/ui-step.txt" ] && break; sleep 0.25; done; kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D/test-tooldraw.json" <<'PY'
import json, sys
st = {s["at"]: s for s in json.load(open(sys.argv[1]))["steps"]}; bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
def is_(at, draw, tool): s = st[at]; return s["draw"] == draw and s["tool"] == tool
chk(is_("start: pen, outside draw mode, one stroke", False, "pen") and st["start: pen, outside draw mode, one stroke"]["strokes"] == 1, "start: outside draw mode, pen, one stroke on the page")
chk(is_("E outside draw mode", True, "eraser"), "E outside draw mode: draw mode on, eraser active")
chk(st["a stroke with the eraser"]["strokes"] == 0, "a finger stroke right after erases the stroke under it")
chk(is_("E again (in draw mode)", True, "pen"), "E again: back to the pen, still in draw mode")
chk(is_("D", False, "pen"), "D still leaves draw mode")
chk(is_("M outside draw mode", True, "marker") and is_("H outside draw mode", True, "highlighter"), "M and H outside draw mode: draw mode on with that tool")
chk(is_("P outside draw mode", True, "pen"), "P outside draw mode (on the marker): draw mode on with the pen")
chk(not st["Esc"]["draw"], "Esc leaves draw mode, as before")
chk(is_("toolbar: eraser clicked outside draw mode", True, "eraser") and not st["Esc after the toolbar click"]["draw"], "toolbar: clicking the eraser outside draw mode turns draw mode on with the eraser")
out = [k for k, s in st.items() if s["toolbarTool"] != s["tool"] or s["toolbarDraw"] != s["draw"]]
chk(not out, f"toolbar in sync at every step (out of sync: {out})")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
PY
