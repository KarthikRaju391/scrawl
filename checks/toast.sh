#!/bin/bash
# Pill labels are centred: in a screenshot of each pill, the text is centred in the pill within 1 pt (across:
# its ink; up and down: from the top of the tallest letters to the baseline).
cd "$(dirname "$0")/.."
D=$(mktemp -d /tmp/td-toast.XXXX)
TRACKPAD_DRAW_DATA=$D "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-toast >/dev/null 2>&1 &
P=$!; sleep 1; WID=$(build/winid $P)
for _ in $(seq 1 200); do
    [ -f "$D/ui-step.txt" ] && break
    for q in "$D"/shot-*.req; do [ -e "$q" ] || continue; n=$(basename "$q" .req); sleep 0.2; screencapture -x -o -l"$WID" "$D/$n.png"; mv "$q" "$D/$n.taken"; touch "$D/$n.done"; done
    sleep 0.05
done
kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D" <<'PY'
import json, sys
from PIL import Image
d = sys.argv[1]; r = json.load(open(d + "/test-toast.json")); bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
for c in r["cases"]:
    im = Image.open(f"{d}/shot-{c['n']}.png").convert("RGB"); W, H = im.size
    k = W / c["window"][0]                                  # pixels per point
    x, y, w, h = c["pill"]
    # Pill in image pixels (window origin bottom-left; the image includes the title bar on top).
    L, R = int(round(x * k)), int(round((x + w) * k)); T, B = int(round(H - (y + h) * k)), int(round(H - y * k))
    # Inside the pill: skip its rounded ends (they show the page behind them); pills pad text by >= the radius.
    rad = int(round(h / 2 * k)) + 2
    crop = im.crop((L + rad, T + 2, R - rad, B - 2))
    off = (rad - (R - L) / 2, 0)   # crop centre = pill centre horizontally (symmetric crop)
    px = crop.load(); cw, ch = crop.size
    # The pill colour: the most common colour in the crop; text = pixels far from it.
    from collections import Counter
    bg = Counter(list(crop.getdata())).most_common(1)[0][0]
    xs, ys = [], []
    for j in range(ch):
        for i in range(cw):
            p = px[i, j]
            if sum(abs(p[q] - bg[q]) for q in range(3)) > 120: xs.append(i); ys.append(j)
    if not xs: chk(False, f"{c['name']}: no text found"); continue
    # Horizontal: the text's ink box. Vertical: from the top of the tallest letters to the baseline (the lowest
    # row with at least a third of the busiest row's ink: descenders like the g in "Nothing" don't count).
    tx = (min(xs) + max(xs) + 1) / 2 / k
    from collections import Counter as C2
    rowc = C2(ys); top = min(ys); busiest = max(rowc.values())
    base = max(j for j, n in rowc.items() if n >= busiest / 3)
    ty = (top + base + 1) / 2 / k
    px_c, py_c = cw / 2 / k, ch / 2 / k   # the crop is symmetric about the pill's centre
    dx, dy = tx - px_c, ty - py_c
    chk(abs(dx) <= 1 and abs(dy) <= 1, f"{c['name']}: text centre is {dx:+.1f} pt across, {dy:+.1f} pt down from the pill's centre (pill {w:.0f}x{h:.0f} pt)  [shot-{c['n']}.png]")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
print("screenshots:", d)
PY
