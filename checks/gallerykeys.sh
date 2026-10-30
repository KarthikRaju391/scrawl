#!/bin/bash
# Pages overview: one highlight, moved by arrows and the pointer; G / Return / Space open it; Esc goes back.
cd "$(dirname "$0")/.."
D=$(mktemp -d /tmp/td-gkeys.XXXX)
TRACKPAD_DRAW_DATA=$D "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-gallerykeys >/dev/null 2>&1 &
P=$!; sleep 1; WID=$(build/winid $P)
for _ in $(seq 1 400); do
    [ -f "$D/ui-step.txt" ] && break
    for q in "$D"/shot-*.req; do [ -e "$q" ] || continue; n=$(basename "$q" .req); sleep 0.2; screencapture -x -o -l"$WID" "$D/$n.png"; mv "$q" "$D/$n.taken"; touch "$D/$n.done"; done
    sleep 0.05
done
kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D/test-gallerykeys.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
o = r["open"]; chk(o["selected"] == 2 and o["rings"] == {"2": 1}, f"opening on page 3: the highlight is on page 3, and exactly one ring is drawn (rings: {o['rings']})")
a = r["afterRightRight"]; w = a["want"]
chk(a["selected"] == w and w != 2 and a["rings"] == {str(w): 1} and a["currentDot"], f"→ → moves that one ring two tiles along, to page {w + 1} (rings: {a['rings']}); page 3 keeps its small dot as the page that's open")
g = r["gOpens"]; chk(g["page"] == w and not g["galleryShown"] and g["kind"] == "open", f"G opens the highlighted page (page {g['page'] + 1}), not the one that was open (3), with the grow animation")
e = r["esc"]; chk(e["startSelected"] == w and e["page"] == w and not e["galleryShown"], f"reopened: highlight on the current page ({w + 1}); after moving it, Esc goes back to it (page {e['page'] + 1})")
h = r["hover"]; chk(h["selected"] == 7 and h["rings"] == {"7": 1} and h["pageAfterReturn"] == 7, f"hovering page 8 moves the one highlight there; Return opens it (page {h['pageAfterReturn'] + 1})")
chk(r["click"]["page"] == 9, "clicking page 10 opens page 10")
chk(r["space"]["page"] == r["space"]["want"] and r["space"]["want"] != 9, f"Space opens the highlighted page (page {r['space']['want'] + 1}, one tile on from page 10)")
n = r["newPage"]; chk(n["pages"] == n["pagesBefore"] + 1 and n["page"] == n["pagesBefore"], "G on '+ New page' adds a page and opens it")
for k, want_shown, label in (("holdGOnPage", True, "G held on a page"), ("holdGInOverview", False, "G held in the overview (page 7 highlighted)"), ("holdReturnInOverview", False, "Return held in the overview (page 9 highlighted)")):
    x = r[k]
    chk(x["transitions"] == 1 and x["switches"] == 1 and x["shownAfter"] == want_shown,
        f"{label} for 1.5 s (auto-repeat): one change, no flashing between the overview and the page (transitions {x['transitions']}, switches {x['switches']}, overview shown after: {x['shownAfter']}, page {x['pageBefore'] + 1} -> {x['pageAfter'] + 1})")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
print("screenshots:", sys.argv[1].rsplit("/", 1)[0])
PY
