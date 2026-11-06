#!/bin/bash
# 0.1.6.1 stability checks (the 6 Nov implicit-state audit): the bench's canvas-level checks (BENCH_ONLY=stability: #1 fingers
# already down, #2 pan or pinch incl. Karthik's recorded sessions, #4 a waiting move after Esc / G, #5 undo + redo, #6 the
# thumbnail cache) and the app's (--test-stability: #3 the overview, #4 the chevron, #6 the tile, #16 Settings).
# The app runs in the background, off screen (--offscreen), with a throwaway data folder and the dry pointer lock: no window,
# no focus, the pointer is never touched. APP=<app binary> / BENCH=<bench> run another build (e.g. 7955f70's, for the
# before). STABILITY_SESSIONS=<dir> points the session replay elsewhere (default ~/code/trackpad-draw/data, read only).
cd "$(dirname "$0")/.."
APP=${APP:-build/Scrawl.app/Contents/MacOS/TrackpadDraw}
BENCH=${BENCH:-build/bench}
fail=0
D=$(mktemp -d /tmp/td-stability.XXXX)
echo "== bench (BENCH_ONLY=stability)"
TRACKPAD_DRAW_DATA=$D/bench STABILITY_NAV_OUT=$D/nav.jsonl BENCH_ONLY=stability "$BENCH" || fail=1
echo "== app (--test-stability)"
mkdir -p "$D/app"
TRACKPAD_DRAW_DRYLOCK=1 TRACKPAD_DRAW_DATA=$D/app "$APP" --test-stability --offscreen >/dev/null 2>&1 &
P=$!
for _ in $(seq 1 900); do [ -f "$D/app/ui-step.txt" ] && break; kill -0 $P 2>/dev/null || break; sleep 0.1; done
kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
if [ -f "$D/app/test-stability.json" ]; then
  python3 -I - "$D/app/test-stability.json" <<'PY' || fail=1
import json, sys
r = json.load(open(sys.argv[1])); bad = 0
def show(name, v):
    global bad
    ok = v.get("ok") is True; bad += not ok
    print(("PASS" if ok else "FAIL"), name, {k: x for k, x in v.items() if k != "ok"})
for k, v in sorted(r["chevron"].items()): show("#4 chevron and move: " + k, v)
for k, v in sorted(r["overview"].items()): show("#3 draw mode vs the overview: " + k, v)
show("#16 Settings' resume expires", r["settingsResume"])
show("#6 deleted page's tile on a new page", r["deletedTile"])
sys.exit(1 if bad else 0)
PY
else echo "FAIL the app wrote no test-stability.json"; fail=1; fi
rm -rf "$D"
exit $fail
