#!/bin/sh
# Zoom lock end to end (runs in the background): every path with the lock on; prints each step.
cd "$(dirname "$0")/.."
OUT=$(mktemp -d /tmp/td-zoomlock.XXXX)
TRACKPAD_DRAW_DATA=$OUT "build/Trackpad Draw.app/Contents/MacOS/TrackpadDraw" --test-zoomlock --no-activate >/dev/null 2>&1 &
PID=$!
for i in $(seq 1 120); do [ -f "$OUT/ui-step.txt" ] && break; sleep 0.5; done
kill -TERM $PID 2>/dev/null
python3 -I - "$OUT/test-zoomlock.json" "$OUT" <<'PY'
import json, sys, glob
steps = json.load(open(sys.argv[1]))["steps"]
bad = 0
for s in steps:
    flag = ""
    if "zoomUnchangedSinceLock" in s and not s["step"].startswith(("UNLOCK", "pinch out (unlocked)", "Esc, then E", "P (outside", "D enters")):
        if not s["locked"] or not s["zoomUnchangedSinceLock"] or not s["toolbarShowsLocked"]: flag = "  <-- FAIL"; bad += 1
    if s["step"].startswith("Esc, then E") and not (s["tool"] == "eraser" and s["toolbarTool"] == "eraser" and not s["drawMode"]): flag = "  <-- FAIL"; bad += 1
    if s["step"].startswith("P (outside") and s["tool"] != "pen": flag = "  <-- FAIL"; bad += 1
    if s["step"].startswith("D enters") and not s["drawMode"]: flag = "  <-- FAIL"; bad += 1
    print(f"{s['step']:62s} locked={str(s['locked']):5s} zoom={s['zoom']:<6} page={s['page']} tool={s['tool']:7s} draw={s['drawMode']} {flag}")
ev = [json.loads(l) for f in glob.glob(sys.argv[2] + "/strokes-*.jsonl") for l in open(f)]
ev = [e for e in ev if e.get("kind") == "event"]
print("zoom/lock events:", [(e["what"], e.get("source"), e.get("locked"), round(e.get("to", 0), 2)) for e in ev])
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad} steps)")
PY
