#!/bin/bash
# Pages overview, Karthik's loop (30 Oct): highlight a tile, G opens it, G goes back, again and again (a page at 370%,
# presses 0.25 s apart and faster). Each transition starts on exactly what the tile shows and ends on exactly what the
# page (or the tile) then shows, the toolbar is never missing, and every press makes one change without stacking.
cd "$(dirname "$0")/.."
run() {   # run <dir> [env]: the loop, at normal speed or with slow (2 s) transitions
    local D=$1; shift
    env TRACKPAD_DRAW_DATA=$D "$@" "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-galleryflow >/dev/null 2>&1 &
    local P=$!; for _ in $(seq 1 1200); do [ -f "$D/ui-step.txt" ] && break; sleep 0.1; done
    kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
}
D=$(mktemp -d /tmp/td-gflow.XXXX); S=$(mktemp -d /tmp/td-gflow-slow.XXXX)
run "$D"; run "$S" TRACKPAD_DRAW_SLOW_TRANSITION=1
python3 -I - "$D/test-galleryflow.json" "$S/test-galleryflow.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); slow = json.load(open(sys.argv[2])); bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
MATCH = 6    # mean grey difference (0-255) between two images of the same thing (fix: <= 4.9; 2459ff6: >= 7.5)
# Frames: from the slow run (2 s transitions: the first and last frames are within ~1% of the ends).
calm = slow["transitions"][:slow["calmCount"]]
opens = [t for t in calm if t["opening"]]; closes = [t for t in calm if not t["opening"]]
fv = [round(t["firstVsTile"], 1) for t in opens if "firstVsTile" in t]
chk(len(fv) == len(opens) and all(v < MATCH for v in fv), f"opening: the first frame is the tile as it was (no jump to another image): differences {fv}")
lp = [round(t["lastVsPage"], 1) for t in opens if "lastVsPage" in t]
chk(lp and all(v < MATCH for v in lp), f"opening: the last frame is the page as it then shows (no pop): differences {lp}")
lt = [round(t["lastVsTile"], 1) for t in closes if "lastVsTile" in t]
chk(lt and all(v < MATCH for v in lt), f"closing: the last frame is exactly what the tile then shows (no image swap in the tile): differences {lt}")
# The toolbar, at his speed: in front when a page is on screen (first frame of closing, last frame of opening).
calm = r["transitions"][:r["calmCount"]]
cf = [t["toolbarOnTopFirst"] for t in calm if not t["opening"] and "toolbarOnTopFirst" in t]
ol = [t["toolbarOnTopLast"] for t in calm if t["opening"]]
chk(cf and all(cf) and ol and all(ol), f"the toolbar stays on screen in front while the page is shown (closing first frames {cf}; opening last frames {ol})")
z = [t for t in calm if t["opening"] and t["tile"] == 4]
chk(z and all(t["pageAfter"] == 4 and not t["shownAfter"] for t in z), "the page saved at 370% opens from its tile (page 5)")
chk(all(t["settled"] for t in calm) and all(t["shownAfter"] != t["opening"] for t in calm), "calm loop: every press makes one change and has ended before the next")
chk(r["fastChanges"] == r["fastPresses"] and r["maxTransitionViews"] <= 1 and r["endSettled"],
    f"presses every 0.12 s (faster than a transition): {r['fastChanges']} changes for {r['fastPresses']} presses, at most {r['maxTransitionViews']} transition at once")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
PY
