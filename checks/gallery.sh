#!/bin/bash
# Page overview (background): open/close round trips, thumbnails vs page contents, caching, many pages,
# the New page tile, persistence across a restart, and the transition geometry. Then a slowed-down run
# for screenshots of the grid and of an opening transition.
cd "$(dirname "$0")/.."
APP="build/Scrawl.app/Contents/MacOS/TrackpadDraw"
run() {  # run <dir> <phase> [env...]
    local D=$1 ph=$2; shift 2
    rm -f "$D/ui-step.txt"
    env TRACKPAD_DRAW_DATA=$D "$@" "$APP" --test-gallery $ph >/dev/null 2>&1 &
    local P=$!; sleep 1; local WID; WID=$(build/winid $P)
    for _ in $(seq 1 400); do
        [ -f "$D/ui-step.txt" ] && break
        for q in "$D"/shot-*.req; do
            [ -e "$q" ] || continue
            n=$(basename "$q" .req); screencapture -x -o -l"$WID" "$D/$n.png"; mv "$q" "$D/$n.taken"; touch "$D/$n.done"
        done
        sleep 0.05
    done
    kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
}
D=$(mktemp -d /tmp/td-gal.XXXX)
run "$D" write
run "$D" read
S=$(mktemp -d /tmp/td-galshots.XXXX)
run "$S" write TRACKPAD_DRAW_SLOW_TRANSITION=1
python3 -I - "$D" "$S" <<'PY'
import json, sys, os
d, sdir = sys.argv[1], sys.argv[2]
w = json.load(open(d + "/test-gallery-write.json")); rd = json.load(open(d + "/test-gallery-read.json")); bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
def near(a, b, tol=0.5): return len(a) == 4 and len(b) == 4 and max(abs(x - y) for x, y in zip(a, b)) < tol
c = w["close"]; t = c["transition"]
chk(c["shown"] and not c["drawModeInGallery"] and t["kind"] == "close" and t["page"] == 2, "G from page 3: the overview opens, draw mode is left")
chk(near(t["from"], c["want"]["from"]) and near(t["startFrame"], c["want"]["from"]) and near(t["to"], c["want"]["to"]) and near(t["endFrame"], c["want"]["to"]),
    f"closing transition: starts at the canvas {t['startFrame']}, ends in page 3's grid cell {t['endFrame']}")
th = w["thumbnails"]
chk(all(x["found"] == x["want"] and x["strayRows"] == 0 for x in th),
    "thumbnails match the pages: " + ", ".join(f"page {x['page'] + 1} {x['found']}/{x['want']} lines" for x in th))
ca = w["cache"]
chk(ca["afterReopen"] == ca["first"] and ca["afterOnePageChanged"] == ca["first"] + 1,
    f"thumbnails cached: {ca['first']} rendered, {ca['afterReopen'] - ca['first']} more on reopening, {ca['afterOnePageChanged'] - ca['afterReopen']} after one page changed")
o = w["open"]; t = o["transition"]
chk(o["pageIndex"] == 4 and o["galleryHidden"] and o["drawModeBack"], "clicking page 5's cell opens page 5 and returns to draw mode")
chk(t["kind"] == "open" and near(t["from"], o["want"]["from"]) and near(t["startFrame"], o["want"]["from"]) and near(t["to"], o["want"]["to"]) and near(t["endFrame"], o["want"]["to"]),
    f"opening transition: starts at page 5's cell {t['startFrame']}, ends at the canvas {t['endFrame']}")
rt = w["roundTrip"]; chk(rt["pageIndex"] == 4 and rt["drawMode"] and rt["galleryHidden"], "G, G: back on the same page, in draw mode")
sc = w["scroll"]; chk(sc["docHeight"] > sc["visibleHeight"] and sc["cell40Visible"] and sc["scrolledBy"] > 0,
    f"40 pages scroll ({sc['docHeight']:.0f} pt of grid in {sc['visibleHeight']:.0f} pt; page 40 scrolled into view)")
n = w["newPage"]; chk(n["pages"] == 41 and n["pageIndex"] == 40 and near(n["from"], n["want"]), "the New page tile (last in the grid) adds page 41, opens it, growing from the tile")
e = w["esc"]; chk(e["galleryHidden"] and e["pageIndex"] == 40, "Esc in the overview goes back to the current page")
a = rd["afterRestart"]
chk(a["pages"] == 41 and a["galleryShown"] and all(x["found"] == x["want"] and x["strayRows"] == 0 for x in a["thumbnails"]),
    f"after a restart: {a['pages']} pages in the overview, thumbnails still match ({a['load']})")
shots = [f for f in sorted(os.listdir(sdir)) if f.endswith(".png")]
chk(len(shots) == 5, f"screenshots of the grid and an opening transition: {len(shots)} ({sdir})")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
PY
