#!/bin/bash
# Pages overview order (background): the "New page" tile first, then the pages, the most recently changed first.
# Ink, an eraser swipe, scratch-out and undo count as a change; a view change and an eraser swipe over blank paper
# don't; a page with only a created date sorts by it, one with no dates goes last. Also the initial highlight, G back
# and forth, the arrows, Return on New page, ⌘] in notebook order, Delete and ⌘Z. Saves two screenshots.
cd "$(dirname "$0")/.."
APP="${APP:-build/Scrawl.app/Contents/MacOS/TrackpadDraw}"
D=$(mktemp -d /tmp/td-galleryorder.XXXX)
TRACKPAD_DRAW_DATA=$D "$APP" --test-gallery-order --no-activate >/dev/null 2>&1 &
P=$!; sleep 1; WID=$(build/winid $P)
for _ in $(seq 1 400); do
    [ -f "$D/ui-step.txt" ] && break
    for q in "$D"/shot-*.req; do [ -e "$q" ] || continue; n=$(basename "$q" .req); sleep 0.3; screencapture -x -o -l"$WID" "$D/$n.png"; mv "$q" "$D/$n.taken"; touch "$D/$n.done"; done
    sleep 0.05
done
kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D" <<'PY'
import json, sys
d = sys.argv[1]
try: r = json.load(open(d + "/test-gallery-order.json"))
except Exception as e: print("FAIL no result:", e); print("RESULT: FAIL (1)"); sys.exit(1)
bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
o1 = r["open1"]
want = ["new", "4", "0", "6", "3", "1", "5", "2", "7"]   # page 5 undo, 1 scratch, 7 created-only, 4 erased, 2 ink, 6, 3 (looked at), 8 (no dates)
chk(r["erasedOnPage4"] == 0 and r["page3Strokes"] == 1, f"setup: the eraser swipe erased page 4's ink ({r['erasedOnPage4']} left); the blank-paper swipe left page 3's ({r['page3Strokes']})")
chk(o1["visual"] == want, f"tiles, top-left first: New page, then most recently changed: {o1['visual']} (want {want})")
chk(o1["labels"][0] == "New page" and o1["labels"][1].startswith("Page 5  ·  edited ") and o1["labels"][-1] == "Page 8  ·  date unknown",
    f"labels: {o1['labels'][:3]} ... {o1['labels'][-2:]}")
chk(o1["selected"] == "2" and o1["ringOn"] == ["2"] and o1["current"] == 2, f"the highlight starts on the page you came from (page 3, tile {o1['selectedAt']}): {o1['selected']}, ring on {o1['ringOn']}")
ci = r["closeInto"]
chk(ci["to"] == ci["page3Tile"], f"the page shrinks into its own tile: {ci['to']} vs {ci['page3Tile']}")
gb = r["gBack"]
chk(gb["page"] == 2 and gb["from"] == gb["tile"], f"G again opens page 3, growing from its tile ({gb['from']})")
chk(r["nextFromPage3"] == 3 and r["prevBack"] == 2, f"⌘] / ⌘[ keep the notebook's order: page 3 -> {r['nextFromPage3'] + 1} -> {r['prevBack'] + 1}")
chk(r["hintBefore"].startswith("Page 3 of 8"), f"the open page's label keeps its number: \"{r['hintBefore'][:24]}\"")
chk(r["afterUpLeft"]["selected"] == "new" and r["afterUpLeft"]["selectedAt"] == 0, f"up / left as far as they go: the New page tile ({r['afterUpLeft']['selected']})")
chk(r["rightFromFirst"]["selected"] == "4", f"right from New page: the most recently changed page (page 5): {r['rightFromFirst']['selected']}")
chk(r["leftFromFirst"]["selected"] == "new", "left from New page stays there (no wrap)")
ar = r["afterReturn"]
chk(ar["pages"] == 9 and ar["page"] == 8 and ar["strokes"] == 0 and ar["from"] == ar["tile"], f"Return on New page: a 9th page at the end, opened, growing from the first tile ({ar})")
chk(r["hintNew"].startswith("Page 9 of 9"), f"it's numbered at the end: \"{r['hintNew'][:24]}\"")
o2 = r["open2"]
chk(o2["visual"][:3] == ["new", "8", "4"] and o2["selected"] == "8", f"reopened: the new page comes right after New page and is highlighted: {o2['visual'][:4]}")
b, ad = r["labelsBeforeDelete"], r["afterDelete"]
chk(ad["pages"] == 8 and ad["labels"][ad["selectedAt"]] == b[2] and ad["selectedAt"] == 1, f"Delete: the next tile moves up and is highlighted: {ad['labels'][1]} (was {b[2]})")
ar2 = r["afterRestore"]
chk(ar2["pages"] == 9 and ar2["labels"] == b, "⌘Z: the page is back, in the same place")
chk([str(x) for x in r["matching"]] == ar2["visual"][1:], f"search results come in tile order: {r['matching']}")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
print("screenshots:", d)
PY
