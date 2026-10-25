#!/bin/bash
# Pages overview responsiveness (background): input to the first frame of the grow / shrink transition,
# with the 41-page notebook (two full pages). Budget: median 50 ms over 5 runs (worst under 100 ms, as the Mac
# may be busy); animation 0.20-0.25 s, easing out, no gap over 34 ms between its frames.
cd "$(dirname "$0")/.."
D=$(mktemp -d /tmp/td-gspeed.XXXX)
TRACKPAD_DRAW_DATA=$D "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-gallery-speed >/dev/null 2>&1 &
P=$!; for _ in $(seq 1 240); do [ -f "$D/ui-step.txt" ] && break; sleep 0.25; done; kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D/test-gallery-speed.json" <<'PY'
import json, sys, statistics as st
r = json.load(open(sys.argv[1])); bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
for name, xs in (("click a tile -> grow", r["opens"]), ("G -> shrink into the grid", r["closes"])):
    ff = [x["inputToFirstFrameMs"] for x in xs]; ss = [x["inputToStartMs"] for x in xs]
    chk(st.median(ff) < 50 and max(ff) < 100, f"{name}: input to first animation frame median {st.median(ff):.1f} ms (budget 50), worst {max(ff):.1f} ms (cap 100); to transition start median {st.median(ss):.1f} ms")
    gap = max(x["maxFrameGapMs"] for x in xs); tot = st.median(x["totalMs"] for x in xs)
    chk(gap < 34 and tot < 300, f"{name}: smooth after the first frame (longest gap between frames {gap:.1f} ms; the whole transition {tot:.0f} ms)")
    d = xs[0]["durationS"]; pr = st.median(x["firstFrameProgress"] for x in xs)
    chk(0.2 <= d <= 0.25 and pr > 0.02, f"{name}: {d:.2f} s, easing out (the first frame already covers {pr * 100:.1f}% of the way)")
o = r["opens"]
chk(all(x["page"] == (4 if i % 2 == 0 else 2) and x["endFrame"] == x["canvas"] for i, x in enumerate(o)), "every click opens the clicked page and ends exactly at the canvas")
print(f"(a full-size render of a full page takes {r['fullPageRenderMs']:.0f} ms)")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
PY
