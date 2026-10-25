#!/bin/bash
# Ink steadiness while writing with autosave running on a ~4.5 MB notebook (background). Bar: the ink tip
# moves within 1 pt of its steady per-frame step on every displayed frame (a freeze then a jump fails it), and
# autosave holds the main thread for under 8 ms per save.
cd "$(dirname "$0")/.."
D=$(mktemp -d /tmp/td-jitter.XXXX)
TRACKPAD_DRAW_DATA=$D "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-jitter >/dev/null 2>&1 &
P=$!; for _ in $(seq 1 160); do [ -f "$D/ui-step.txt" ] && break; sleep 0.25; done; kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D/test-jitter.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
print(f"notebook: {r['strokes']} strokes, {r['fileMB']:.1f} MB; encoding it takes {r['encodeMs']:.0f} ms")
s = r["saveMainThreadMs"]
chk(r["savesDuringWriting"] >= 3 and max(s) < 8, f"autosave while writing: {r['savesDuringWriting']} saves, main thread held {max(s):.1f} ms at most (bar 8 ms)")
chk(r["jitterMax"] < 1.0, f"ink tip jitter while writing: every displayed frame's step within {r['jitterMax']:.2f} pt of the steady step (bar 1 pt; p99 {r['jitterP99']:.2f}); longest gap between frames {r['maxTickGapMs']:.0f} ms")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
PY
