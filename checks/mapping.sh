#!/bin/bash
# Any window shape and full screen: paper everywhere, the pad's area undistorted and centred (background).
cd "$(dirname "$0")/.."
D=$(mktemp -d /tmp/td-map.XXXX)
TRACKPAD_DRAW_DATA=$D "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-mapping "$@" >/dev/null 2>&1 &
P=$!; sleep 1; WID=$(build/winid $P)
for _ in $(seq 1 240); do
    [ -f "$D/ui-step.txt" ] && break
    for q in "$D"/shot-*.req; do
        [ -e "$q" ] || continue
        n=$(basename "$q" .req); sleep 0.4
        screencapture -x -o -l"$WID" "$D/$n.png"; mv "$q" "$D/$n.taken"; touch "$D/$n.done"
    done
    sleep 0.25
done
kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D" <<'PY'
import json, sys
from PIL import Image
d = sys.argv[1]; r = json.load(open(d + "/test-mapping.json")); bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
chk(not r["aspectLocked"], "window shape is free (no aspect lock): tall, wide, snapped beside another app")
chk(r["fullScreenPrimary"], "window can go full screen (green button, ⌃⌘F)")
for s in r["scenarios"]:
    w, h = s["view"]; pr = s["padRect"]; ux, uy = s["unitsPerPtXY"]; p = s["pan"]; z = s["zoom"]
    ink = s["inkStarts"]
    inkErr = max(abs(ink[0][0] - pr[0]), abs(ink[0][1] - pr[1]), abs(ink[1][0] - (pr[0] + pr[2])), abs(ink[1][1] - (pr[1] + pr[3]))) if len(ink) == 2 else 99
    outline = s["outlineInDrawMode"]
    checks = {
        "no gap": s["gapPt"] < 0.5,
        "pad area has the pad's shape": abs(s["padRectAspect"] - r["padAspect"]) < 0.002,
        "centred left-right, at the top": s["padRectCentredErr"] < 0.5,
        "largest that fits": s["padRectFills"],
        "no stretch": abs(ux - uy) / ux < 1e-6,
        "corners": s["cornerErrPt"] < 0.5,
        "ink from the corners": inkErr < 1.0,
        "outline in draw mode only": len(outline) == 4 and max(abs(a - b) for a, b in zip(outline, pr)) < 0.5 and not s["outlineOutsideDrawMode"],
        "edge guard": s["bandStrokeInk"] == 0,
        "pan follows the fingers, same on both axes": abs(p["dx"] - p["wantDx"]) < 0.02 * p["wantDx"] and abs(p["dy"] - p["wantDy"]) < 0.02 * p["wantDy"],
        "zoom lock holds, pinch zooms when unlocked": abs(z["locked"] - z["before"]) < 1e-9 and z["unlocked"] > z["before"] * 1.5,
    }
    if "screenshot" in s:
        try:
            im = Image.open(d + "/" + s["screenshot"]).convert("RGB"); W, H = im.size
            # Corners and side edges of the content area, inside the rounded window corners, below the title bar.
            title = int(H * 0.0) + 70
            # (bottom samples sit above the toolbar, which spans nearly the whole width of a narrow window)
            pts = [(30, title + 10), (W - 30, title + 10), (30, H - 150), (W - 30, H - 150), (6, (H + title) // 2), (W - 6, (H + title) // 2)]
            px = [im.getpixel(q) for q in pts]
            grey = [q for q in px if all(abs(c - g) <= 4 for c, g in zip(q, (241, 243, 244)))]
            checks["paper to the edges (screenshot)"] = all(min(q) >= 250 for q in px) and not grey
            s["pixels"] = px
        except Exception as e:
            checks["paper to the edges (screenshot)"] = False; s["pixels"] = str(e)
    failed = [k for k, v in checks.items() if not v]
    chk(not failed, f"{s['name']} {int(w)}x{int(h)}: pad area {pr[2]:.0f}x{pr[3]:.0f} at ({pr[0]:.0f},{pr[1]:.0f}); "
        + ("all of: " + ", ".join(checks) if not failed else "failed: " + ", ".join(failed) + f" | pixels {s.get('pixels')} pan {p} zoom {z} ink {ink}"))
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
print("screenshots:", d)
PY
