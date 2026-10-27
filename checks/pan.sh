#!/bin/bash
# Horizontal page moves in every window shape (background): pans both ways, writing after a pan right, and no sideways pan while writing along a line.
cd "$(dirname "$0")/.."
D=$(mktemp -d /tmp/td-pan.XXXX)
TRACKPAD_DRAW_DATA=$D "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-pan "$@" >/dev/null 2>&1 &
P=$!; for _ in $(seq 1 240); do [ -f "$D/ui-step.txt" ] && break; sleep 0.25; done; kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D/test-pan.json" <<'PY'
import json, sys
bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
r = json.load(open(sys.argv[1]))
for c in r["cases"]:
    tag = f"{c['shape']}, zoom lock {'on' if c['locked'] else 'off'}"
    s = c["scroll"]; t = c["twoFinger"]; w = c["writeAfterPanRight"]; a = c["alongLine"]
    chk(s["afterRight"] < s["start"] - 20 and abs(s["afterLeft"] - s["start"]) < 1, f"{tag}: scroll moves the page both ways (x {s['start']:.0f} -> {s['afterRight']:.0f} -> {s['afterLeft']:.0f})")
    chk(abs(t["afterFingersLeft"] - t["start"] - t["want"]) < 0.03 * t["want"] and abs(t["afterFingersRight"] - t["start"]) < 0.03 * t["want"] and abs(t["zoom"] - 2) < 1e-6,
        f"{tag}: two-finger pan both ways in draw mode (x {t['start']:.0f} -> {t['afterFingersLeft']:.0f} -> {t['afterFingersRight']:.0f}, want ±{t['want']:.0f})")
    chk(w["newLines"] == 0 and abs(w["afterWritingAndPause"] - w["afterPan"]) < 1, f"{tag}: writing after panning right by hand stays there "
        f"(x {w['afterPan']:.0f} -> {w['afterWritingAndPause']:.0f}, new lines {w['newLines']})")
    chk(a["furthestViewX"] <= max(a["startX"], a["wantAfterNewLine"]) + 1 and a["newLines"] == 1 and abs(a["viewXAfterNewLine"] - a["wantAfterNewLine"]) < 1,
        f"{tag}: writing along the line never pans sideways (view x stays {a['startX']:.0f}, furthest {a['furthestViewX']:.0f}), then the new line returns to the margin (x {a['viewXAfterNewLine']:.0f}, want {a['wantAfterNewLine']:.0f})")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
PY
