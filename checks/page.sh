#!/bin/bash
# The page's bounds (background). The infinite canvas (0.1.6): paper everywhere, the same ruled paper beside the page's
# column as on it, and the column's sides marked by a faint 1 px line; the page top never sits below the window top.
# (Before 0.1.6, --column-bound: a plain grey desk with a shadowed edge.) Saves screenshots.
cd "$(dirname "$0")/.."
D=$(mktemp -d /tmp/td-page.XXXX)
TRACKPAD_DRAW_DATA=$D "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-page "$@" >/dev/null 2>&1 &
P=$!; sleep 1; WID=$(build/winid $P)
for _ in $(seq 1 240); do
    [ -f "$D/ui-step.txt" ] && break
    for q in "$D"/shot-*.req; do
        [ -e "$q" ] || continue
        n=$(basename "$q" .req); sleep 0.5
        screencapture -x -o -l"$WID" "$D/$n.png"; mv "$q" "$D/$n.taken"; touch "$D/$n.done"
    done
    sleep 0.2
done
kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D" <<'PY'
import json, sys
from PIL import Image
d = sys.argv[1]; r = json.load(open(d + "/test-page.json")); bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
for s in r["shots"]:
    vw, vh = s["view"]; im = Image.open(f"{d}/shot-{s['n']}.png").convert("RGB"); W, H = im.size
    k = W / s["window"][0]                      # image pixels per point
    def px(x, y): return im.getpixel((min(max(int(x * k), 0), W - 1), min(max(int(H - y * k), 0), H - 1)))   # view point -> pixel
    def column(x, y0, y1):                      # pixels down a vertical line, avoiding toolbar and labels
        return [px(x, y) for y in range(int(y0), int(y1), 2)]
    lo, hi = vh * 0.18, vh * 0.80
    issues = []
    # The page top is at or above the window top: no off-page space above it.
    if s["pageTop"] < vh - 0.5: issues.append(f"page top {s['pageTop']:.0f} pt below the window top")
    # Beside the column: the same ruled white paper as on it (you can write there).
    def ruled(col): return sum(1 for c in col if min(c) >= 250) >= len(col) * 0.6 and any(200 < c[0] < 245 for c in col)
    for side, x in (("left", s["pageLeft"] - 30), ("right", s["pageRight"] + 30)):
        if 4 < x < vw - 4:
            col = column(x, lo, hi)
            if not ruled(col): issues.append(f"beside the column ({side}) not ruled paper ({sorted(set(col))[:3]})")
    # On the page: white paper with ruled lines (a column away from ink has white and line pixels).
    xin = max(s["pageLeft"], 0) + 12
    col = column(xin, lo, hi)
    whites = sum(1 for c in col if min(c) >= 250); lines = sum(1 for c in col if 200 < c[0] < 245)
    if whites < len(col) * 0.6 or lines == 0: issues.append(f"page not ruled white paper (white {whites}/{len(col)}, line {lines})")
    # The column's side: a faint line at it (darker than the paper 20 pt away on the same row), on most rows.
    for side, x in (("left", s["pageLeft"]), ("right", s["pageRight"])):
        if 4 < x - 22 and x + 22 < vw - 4:
            rows = [lo + (hi - lo) * i / 8 for i in range(9)]
            marked = sum(1 for y in rows if min(sum(px(x + dx / 2, y)) for dx in range(-4, 5)) < 640 and min(px(x + 20, y)) >= 250 and min(px(x - 20, y)) >= 250)
            if marked < 3: issues.append(f"no visible {side} column edge ({marked} of {len(rows)} rows)")
    edges = [e for e, x in (("left", s["pageLeft"]), ("right", s["pageRight"])) if 0 < x < vw]
    chk(not issues, f"{s['name']} ({vw:.0f}x{vh:.0f}): page edges on screen: {', '.join(edges) or 'none (page fills the width)'}; "
        + ("ruled paper beside the column, its sides a faint line, page top at the window top" if not issues else "; ".join(issues)) + f"  [shot-{s['n']}.png]")
sm = r["smallest"]
chk(sm["pill"][0] >= 0 and sm["pill"][1] <= sm["view"][0], f"at the smallest window ({sm['view'][0]:.0f} x {sm['view'][1]:.0f} pt) the whole toolbar is inside it (pill x {sm['pill'][0]:.0f}-{sm['pill'][1]:.0f})")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
print("screenshots:", d)
PY
