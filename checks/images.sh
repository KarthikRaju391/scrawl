#!/bin/bash
# Image pages in the real app (background window, scratch data folders; never the real notebook). PASS/FAIL per case.
#   1. every way in: ⌘V and a drop (onto the open page), the Select tool on a picture (click, move, resize, ⌫, ⌘C, ⌘Z),
#      New Page from Image's import (HEIC, TIFF, PDF), the Inbox before launch and
#      while running (tools/inbox_write.py, the browser extension's way); the page header names the source; ⌘Z after a
#      new picture page takes it away and its file goes after the save; ink on a picture; Copy; exports.
#   2. kill -9 mid-stroke, reopen: the same notebook, the same picture files byte for byte, the page renders the same.
#   3. the overview's transitions with picture pages (checks/galleryflow.sh with TRACKPAD_DRAW_TEST_IMAGES).
#   4. a 4000 x 12000 screenshot: frame times scrolling it, ink latency on it vs a plain page, memory.
#   5. OLD_APP=<a 0.1.5 TrackpadDraw binary>: 0.1.5's notebook opens in this one unchanged, and 0.1.5 opens this one's
#      notebook with pictures (without them).
# Screenshots go to ${SHOTS:-/tmp/td-images-shots}.
cd "$(dirname "$0")/.."
APP="build/Scrawl.app/Contents/MacOS/TrackpadDraw"
SHOTS=${SHOTS:-/tmp/td-images-shots}; mkdir -p "$SHOTS"
BAD=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; BAD=$((BAD + 1)); }
waitfile() { for _ in $(seq 1 ${3:-120}); do [ -f "$1/$2" ] && return 0; sleep 0.25; done; return 1; }

D=$(mktemp -d /tmp/td-images.XXXX)
# A "web page" screenshot and two strokes on it in CSS px (dpr 2), for the Inbox items.
python3 -I - "$D" <<'PY'
import json, sys
from PIL import Image, ImageDraw
d = sys.argv[1]
im = Image.new("RGB", (1440, 3200), "white"); g = ImageDraw.Draw(im)
g.rectangle((0, 0, 1440, 120), fill=(26, 115, 232))
for k in range(40): g.rectangle((120, 220 + k * 72, 120 + 600 + (k * 137) % 560, 250 + k * 72), fill=(200, 205, 212))
im.save(d + "/web.png")
json.dump([{"tool": "highlighter", "color": "#fdd663", "size": 14, "points": [[60, 118, 0.5], [400, 118, 0.5]]},
           {"tool": "pen", "color": "#d93025", "size": 2.5, "points": [[[60 + i * 4, 200 + (i % 7) * 3, 0.6] for i in range(60)]][0]}],
          open(d + "/strokes.json", "w"))
PY
tools/inbox_write.py --data "$D" --id before-launch --image "$D/web.png" --url "https://www.example.com/article" --title "An example article" --scale 2 --strokes "$D/strokes.json" >/dev/null

TRACKPAD_DRAW_DATA=$D TRACKPAD_DRAW_IMAGE_GRACE=0 "$APP" --test-images write >/dev/null 2>&1 &
P=$!; sleep 1; WID=$(build/winid $P)
for _ in $(seq 1 3000); do
    [ -f "$D/midstroke.json" ] && break
    kill -0 $P 2>/dev/null || break
    if [ -f "$D/inbox-now.req" ]; then rm -f "$D/inbox-now.req"; tools/inbox_write.py --data "$D" --id while-running --image "$D/web.png" --url "https://example.org/b" --title "Second page" --scale 2 >/dev/null; fi
    for q in "$D"/shot-*.req; do [ -e "$q" ] || continue; n=$(basename "$q" .req); screencapture -x -o -l"$WID" "$SHOTS/$n.png"; rm -f "$q"; touch "$D/$n.done"; done
    sleep 0.02
done
sleep 0.3; kill -9 $P 2>/dev/null; wait $P 2>/dev/null
rm -f "$D/ui-step.txt"
TRACKPAD_DRAW_DATA=$D "$APP" --test-images read >/dev/null 2>&1 &
P=$!; waitfile "$D" ui-step.txt; kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
cp "$D/export.png" "$SHOTS/export.png" 2>/dev/null; cp "$D/export.svg" "$SHOTS/export.svg" 2>/dev/null; cp "$D/copy.png" "$SHOTS/copy.png" 2>/dev/null

python3 -I - "$D" <<'PY' || BAD=$((BAD + 1))
import json, sys, os
from PIL import Image
d = sys.argv[1]; bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
w = json.load(open(d + "/images-write.json"))
e, a = json.load(open(d + "/expected.json")), json.load(open(d + "/actual.json"))
chk(w.get("inboxBeforeLaunch", -1) >= 0, f"an Inbox item written before launch becomes a page at launch (page {w.get('inboxBeforeLaunch', -1) + 1})")
chk(w["pasteEnabled"] and w["paste"] and w["pasteOnPage"] and w["pasteSelected"] and "from a pasted image" in w["pasteHeader"], f"⌘V with an image on the pasteboard: Paste is enabled, the picture goes on the open page, selected with the Select tool; header: {w['pasteHeader']!r}")
pr = w.get("pasteRendered", [0, 1])
chk(pr[1] > 0.05 and abs(pr[0] - pr[1]) < 0.25 * pr[1], f"the canvas draws the pasted picture at once: {pr[0]:.1%} of its render is the card's blue, the picture covers {pr[1]:.1%} of the view")
chk(w["dragEntered"] and w["dropTaken"] and w["drop"] and w["dropAtPointer"] and w["dropOnPage"], "a JPEG file dropped on the window: on the open page, centred where it was dropped")
chk(w["clickSelects"] and w["moveByPointer"] and w["resizeByPointer"], "Select tool through the window's events: a click selects the photo, a drag moves it by exactly the pointer's travel, a corner drag resizes it (proportions kept, the opposite corner fixed)")
chk(w["copyPicture"], "⌘C with the photo selected puts its original JPEG bytes on the pasteboard")
chk(w["deleteKey"] and w["undoDelete"] and w["undoMoves"] and w["redoMoves"], "⌫ deletes it; ⌘Z brings it back; two more ⌘Z undo the resize and the move exactly; redo redoes them")
chk(w["dropTextRefused"], "a dropped text file is refused (no copy cursor, not taken)")
chk(w["open3"] and "Handout.pdf" in w["openHeader"] and w["menuItem"].endswith(" n"), f"New Page from Image's import: HEIC, TIFF, PDF -> 3 pages, the last opened ({w['openHeader']!r}); the menu item ⇧⌘N ({w['menuItem']})")
chk(w["inboxWhileRunning"] and w["inboxDone"] and "Second page" in w["inboxHeader"], f"an Inbox item written while the app runs: a page at once, its result file after the save; header {w['inboxHeader']!r}")
for item in ["before-launch", "while-running"]:
    p = f"{d}/Inbox/{item}.done.json"
    r = json.load(open(p)) if os.path.exists(p) else {}
    chk(r.get("ok") is True and r.get("page", 0) >= 1 and not os.path.exists(f"{d}/Inbox/{item}.scrawlpage"), f"Inbox {item}: {r}, the item removed")
chk(w["undoFileBefore"] and w["undoRemovedPage"] and not w["undoFileAfterSave"], "⌘Z after a new picture page: the page goes, and its picture file after the save (no other page uses it)")
chk(w["inkOnPicture"] >= 5 and w["copyPNG"] > 10000, f"ink on a picture through the real input path ({w['inkOnPicture']} strokes); Copy as Image over it ({w['copyPNG'] // 1024} KB PNG)")
web = [p for p in a["imagePages"] if p["importId"] == "before-launch"]
chk(len(web) == 1 and web[0]["strokes"] == 2 and "An example article" in web[0]["images"][0]["source"], f"the snapshot page: the picture and its 2 strokes, source {web[0]['images'][0]['source'] if web else '?'}")
chk(e["sha256"] == a["sha256"] and e["files"] == a["files"] and a["loadStatus"].startswith("loaded"),
    f"kill -9 mid-stroke on an image page, reopened: the same notebook ({len(a['pages'])} pages, {len(a['imagePages'])} with pictures) and the same {len(a['files'])} picture files byte for byte")
chk(all(len(f.split(".")[0]) == 32 for f in a["files"]) and len(a["files"]) == len({i["asset"] for p in a["imagePages"] for i in p["images"]}), f"Images/ holds exactly the pictures the pages use: {sorted(a['files'])}")
pa, pb = (Image.open(f"{d}/{n}.png").convert("RGB") for n in ("before", "after"))
off = sum(1 for x, y in zip(pa.tobytes(), pb.tobytes()) if abs(x - y) > 8)
chk(pa.size == pb.size and off == 0, f"the image page renders the same after reopening ({pa.size[0]} x {pa.size[1]}, {off} values off)")
svg = open(d + "/export.svg").read()
n_pics = len([p for p in a["imagePages"] if p["page"] == w["inkPage"]][0]["images"])
chk(svg.count("<image ") == n_pics and "data:image/png;base64," in svg and "data:image/jpeg;base64," in svg, f"Export Page as SVG embeds the page's {n_pics} pictures (base64: the PNG and the JPEG as their own bytes)")
from subprocess import run
pdf = run(["python3", "-I", "-c", "import sys;d=open(sys.argv[1],'rb').read();print(d.count(b'/Subtype /Image'), d.count(b'/Type /Page'))", d + "/export.pdf"], capture_output=True, text=True).stdout.split()
chk(len(pdf) == 2 and int(pdf[0]) >= 1, f"Export All Pages as PDF has the pictures ({pdf[0] if pdf else '?'} image objects)")
sys.exit(1 if bad else 0)
PY

# 3. The overview's transitions with picture pages.
if out=$(TRACKPAD_DRAW_TEST_IMAGES=1 checks/galleryflow.sh 2>&1); then pass "overview transitions with picture pages: $(echo "$out" | grep -c ^PASS) checks pass"; else echo "$out" | grep FAIL; fail "overview transitions with picture pages"; fi

# 4. A 4000 x 12000 screenshot.
B=$(mktemp -d /tmp/td-images-big.XXXX)
TRACKPAD_DRAW_DATA=$B "$APP" --test-images big >/dev/null 2>&1 &
P=$!; waitfile "$B" ui-step.txt 400; kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$B" <<'PY' || BAD=$((BAD + 1))
import json, sys, glob
b = sys.argv[1]; r = json.load(open(b + "/images-big.json")); bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
lat = {"plain": [], "picture": []}; phase = None
for line in open(r["strokeLog"]):
    o = json.loads(line)
    if o.get("kind") == "event" and o.get("what") == "phase": phase = o["phase"]
    elif phase and o.get("committed"): lat[phase] += o.get("latencyMs", [])
def q(v, f): v = sorted(v); return v[int(f * (len(v) - 1))] if v else 0
chk(r["made"] and r["importSeconds"] < 3, f"4000 x 12000 screenshot pasted: a page in {r['importSeconds']:.2f} s")
if not lat["picture"] and not lat["plain"]:
    print("SKIP ink latency: no frame reaches the screen in a background window (nothing is presented), so input-to-screen can't be measured here; the bench's per-frame CPU/GPU cost with and without the picture stands in")
else: chk(len(lat["picture"]) > 50 and q(lat["picture"], .5) <= q(lat["plain"], .5) + 2 and q(lat["picture"], .95) <= q(lat["plain"], .95) + 3,
    f"ink latency (input to on screen) on it: p50 {q(lat['picture'], .5):.1f} / p95 {q(lat['picture'], .95):.1f} ms vs a plain page {q(lat['plain'], .5):.1f} / {q(lat['plain'], .95):.1f} ms ({len(lat['picture'])} / {len(lat['plain'])} frames)")
for z in ("zoom1", "zoom2"):
    s = r[z]
    chk(s["frames"] > 150 and s["workP95"] < 4 and s["gpuP95"] < 6, f"scrolling it at {z[4:]}x, a step a frame: {s['frames']} frames; the frame's own CPU work p50 {s['workP50']:.2f} / p95 {s['workP95']:.2f} ms (building it p95 {s['buildP95']:.2f}), GPU p95 {s['gpuP95']:.2f} ms; waiting for a drawable p95 {s['waitP95']:.2f} ms (a background window's drawables come back slowly: not counted; frame gaps aren't measurable there)")
m = r["footprintMB"]; mi = r["footprintAfterImportMB"]
chk(r["gpuTexturesMB"] <= 256 and m[1] - mi < r["gpuTexturesMB"] + 128, f"memory: footprint {m[0]:.0f} MB, {mi:.0f} after the import (the test's own 4000 x 12000 fixture included), {m[1]:.0f} after scrolling it: +{m[1] - mi:.0f} MB for GPU textures of {r['gpuTexturesMB']:.0f} MB (budget 256) and frames")
sys.exit(1 if bad else 0)
PY

# 5. Against 0.1.5 itself.
if [ -n "$OLD_APP" ]; then
    O=$(mktemp -d /tmp/td-images-old.XXXX)
    TRACKPAD_DRAW_DATA=$O "$OLD_APP" --test-persist write >/dev/null 2>&1 &
    P=$!; waitfile "$O" midstroke.json; sleep 0.3; kill -9 $P; wait $P 2>/dev/null
    cp "$O/Notebook.tdnb" "$O/old.tdnb"
    rm -f "$O/ui-step.txt"; TRACKPAD_DRAW_DATA=$O "$APP" --test-persist read >/dev/null 2>&1 &
    P=$!; waitfile "$O" ui-step.txt; kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
    python3 -I - "$O" <<'PY' && pass "a 0.1.5 notebook opens in 0.1.6 unchanged (same summary hash), and is written back without new keys" || fail "a 0.1.5 notebook in 0.1.6"
import json, plistlib, sys
o = sys.argv[1]
e, a = json.load(open(o + "/expected.json")), json.load(open(o + "/actual.json"))
old, new = plistlib.load(open(o + "/old.tdnb", "rb")), plistlib.load(open(o + "/Notebook.tdnb", "rb"))
old.pop("appVersion", None); new.pop("appVersion", None)
keys = lambda n: sorted(n) + sorted({k for p in n["pages"] for k in p})
print(e["sha256"] == a["sha256"], keys(old) == keys(new))
sys.exit(0 if e["sha256"] == a["sha256"] and keys(old) == keys(new) else 1)
PY
    N=$(mktemp -d /tmp/td-images-new.XXXX); cp -R "$D"/Notebook.tdnb "$D"/Images "$N"/
    TRACKPAD_DRAW_DATA=$N "$OLD_APP" --test-persist read >/dev/null 2>&1 &
    P=$!; waitfile "$N" ui-step.txt; kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
    python3 -I - "$N" "$D" <<'PY' && pass "0.1.5 opens a notebook with pictures: every page and stroke, no crash, not set aside" || fail "0.1.5 with a 0.1.6 notebook"
import json, sys, os
n, d = sys.argv[1:3]
a, e = json.load(open(n + "/actual.json")), json.load(open(d + "/actual.json"))
ok = a["loadStatus"].startswith("loaded") and [p["strokes"] for p in a["pages"]] == [p["strokes"] for p in e["pages"]] and not [f for f in os.listdir(n) if "unreadable" in f]
print(a["loadStatus"], [p["strokes"] for p in a["pages"]])
sys.exit(0 if ok else 1)
PY
fi
echo "screenshots: $SHOTS"
[ $BAD -eq 0 ] && echo "images: all passed" || echo "images: $BAD failed"
exit $BAD
