#!/bin/bash
# The Select tool's Copy / Export… bar shows as the drag ends: from mouseUp to the bar committed to the screen's layer tree
# (Core Animation's presentation copy, what the window server draws) at most ~1 frame (50 ms), over 3 drags, with no other
# input and no layout forced. Background; the app refuses to run this in front.
cd "$(dirname "$0")/.."
APP="${APP:-build/Scrawl.app/Contents/MacOS/TrackpadDraw}"
if [ -z "$ALLOW_STALE" ] && [ -n "$(find app -name '*.swift' -newer "$APP" | head -1)" ]; then echo "FAIL $APP is older than app/ (build first)"; echo "RESULT: FAIL"; exit 1; fi
D=$(mktemp -d /tmp/td-selectbar.XXXX)
TRACKPAD_DRAW_DRYLOCK=1 TRACKPAD_DRAW_DATA=$D "$APP" --test-selectbar --no-activate >/dev/null 2>&1 &
P=$!; for _ in $(seq 1 200); do [ "$(cat "$D/ui-step.txt" 2>/dev/null)" = done ] && break; sleep 0.1; done
kill -TERM $P 2>/dev/null; for _ in $(seq 1 20); do kill -0 $P 2>/dev/null || break; sleep 0.25; done; kill -9 $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D/test-selectbar.json" <<'PY'
import json, sys
try: r = json.load(open(sys.argv[1]))
except Exception as e: print("FAIL no result:", e); print("RESULT: FAIL (1)"); sys.exit(1)
bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
if "refused" in r: chk(False, r["refused"]); print("RESULT: FAIL"); sys.exit(1)
frame = 1000 / r.get("refreshHz", 60)
for x in r["runs"]:
    c, s = x["committedMs"], x["shownMs"]
    near = all(abs(a - b) < 1.5 for a, b in zip(x["barFrame"], x["expected"]))
    chk(x["hiddenDuringDrag"], f"drag {x['run'] + 1}: no bar while dragging")
    chk(c is not None and c <= max(frame, 50) and near,
        f"drag {x['run'] + 1}: the bar is on screen {'never (1.5 s)' if c is None else f'{c:.1f} ms'} after mouseUp (shown in the view tree {'never' if s is None else f'{s:.1f} ms'}; a frame is {frame:.1f} ms; limit {max(frame, 50):.0f} ms), under the box's corner: {near}")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
sys.exit(1 if bad else 0)
PY
