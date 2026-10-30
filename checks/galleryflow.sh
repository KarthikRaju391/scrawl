#!/bin/bash
# Pages overview, Karthik's loop (30 Oct): highlight a tile, G opens it, G goes back, again and again (a page at 370%,
# presses 0.25 s apart and faster). Each transition starts on exactly what the tile shows and ends on exactly what the
# page (or the tile) then shows, the toolbar is never missing, and every press makes one change without stacking.
cd "$(dirname "$0")/.."
run() {   # run <dir> [env]: the loop, at normal speed or with slow (2 s) transitions; takes the screenshots it asks for
    local D=$1; shift
    env TRACKPAD_DRAW_DATA=$D "$@" "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-galleryflow >/dev/null 2>&1 &
    local P=$!; sleep 1; local WID=$(build/winid $P)
    for _ in $(seq 1 6000); do
        [ -f "$D/ui-step.txt" ] && break
        for q in "$D"/*.req; do [ -e "$q" ] || continue; n=$(basename "$q" .req); screencapture -x -o -l"$WID" "$D/$n.png"; rm -f "$q"; touch "$D/$n.done"; done
        sleep 0.02
    done
    kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
}
D=$(mktemp -d /tmp/td-gflow.XXXX); S=$(mktemp -d /tmp/td-gflow-slow.XXXX)
run "$D"; run "$S" TRACKPAD_DRAW_SLOW_TRANSITION=1
python3 -I - "$D/test-galleryflow.json" "$S/test-galleryflow.json" "$S" <<'PY'
import json, sys, os
from PIL import Image
r = json.load(open(sys.argv[1])); slow = json.load(open(sys.argv[2])); S = sys.argv[3]; bad = 0
def crop(name):   # the screenshot's region the app named (window points -> screenshot pixels)
    info = json.load(open(f"{S}/{name}.json")); im = Image.open(f"{S}/{name}.png").convert("L")
    x, y, w, h = info["rect"]; k = info["scale"]
    return im.crop((round(x * k), round(y * k), round((x + w) * k), round((y + h) * k)))
def sharpness(im):   # 90th percentile of the brightness gradient where there is an edge
    px = im.load(); w, h = im.size; g = []
    for yy in range(1, h - 1, 2):
        for xx in range(1, w - 1, 2):
            v = abs(px[xx + 1, yy] - px[xx - 1, yy]) + abs(px[xx, yy + 1] - px[xx, yy - 1])
            if v > 24: g.append(v)
    if len(g) < 50: return 0
    g.sort(); return g[len(g) * 9 // 10]
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
MATCH = 6    # mean grey difference (0-255) between two images of the same thing (fix: <= 4.9; 2459ff6: >= 7.5)
# Frames: from the slow run (2 s transitions: the first and last frames are within ~1% of the ends).
calm = slow["transitions"][:slow["calmCount"]]
opens = [t for t in calm if t["opening"]]; closes = [t for t in calm if not t["opening"]]
fv = [round(t["firstVsTile"], 1) for t in opens if "firstVsTile" in t]
chk(len(fv) == len(opens) and all(v < MATCH for v in fv), f"opening: the first frame is what the overview showed there (the tile; no jump to another image): differences {fv}")
lp = [round(t["lastVsPage"], 1) for t in opens if "lastVsPage" in t]
chk(lp and all(v < MATCH for v in lp), f"opening: the last frame is the page as it then shows (no pop): differences {lp}")
lt = [round(t["lastVsTile"], 1) for t in closes if "lastVsTile" in t]
chk(lt and all(v < MATCH for v in lt), f"closing: the last frame is exactly what the tile then shows (no image swap in the tile): differences {lt}")
# No picture shown above its own resolution, and mid-way frames as sharp as the page (opening different pages, two of
# them saved at 370% / 300% and not opened since launch).
up = [round(t.get("maxUpscale", 0), 2) for t in calm]
chk(up and max(up) <= 1.05, f"no frame shows a picture larger than it was rendered (worst upscale per transition: {up})")
sr = []
for t in opens:
    if "midShot" not in t or not os.path.exists(f"{S}/{t['midShot']}.png") or not os.path.exists(f"{S}/{t['endShot']}.png"): continue
    mid = crop(t["midShot"]); end = crop(t["endShot"]).resize(mid.size, Image.LANCZOS)   # the final page at the mid frame's size
    a, b = sharpness(mid), sharpness(end)
    sr.append((t["tile"], round(a / b, 2) if b else 0))
chk(len(sr) >= 5 and all(v >= 0.8 for _, v in sr), f"opening other pages: mid-way frames (screenshots) are as sharp as the page they open, scaled to the same size (edge sharpness ratio per tile: {sr})")
# The toolbar, at his speed: in front when a page is on screen (first frame of closing, last frame of opening).
calm = r["transitions"][:r["calmCount"]]
cf = [t["toolbarOnTopFirst"] for t in calm if not t["opening"] and "toolbarOnTopFirst" in t]
ol = [t["toolbarOnTopLast"] for t in calm if t["opening"]]
chk(cf and all(cf) and ol and all(ol), f"the toolbar stays on screen in front while the page is shown (closing first frames {cf}; opening last frames {ol})")
z = [t for t in calm if t["opening"] and t["tile"] in (4, 6)]
chk(len(z) >= 3 and all(t["pageAfter"] == t["tile"] and not t["shownAfter"] for t in z), "the pages saved at 370% and 300% open from their tiles (pages 5 and 7)")
chk(all(t["pageAfter"] != t["pageBefore"] for t in calm if t["opening"]), "every opening is a different page from the one just left")
chk(all(t["settled"] for t in calm) and all(t["shownAfter"] != t["opening"] for t in calm), "calm loop: every press makes one change and has ended before the next")
chk(r["fastChanges"] == r["fastPresses"] and r["maxTransitionViews"] <= 1 and r["endSettled"],
    f"presses every 0.12 s (faster than a transition): {r['fastChanges']} changes for {r['fastPresses']} presses, at most {r['maxTransitionViews']} transition at once")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
PY
