#!/bin/bash
# The trackpad covers the whole writing area, windowed and full screen (background).
cd "$(dirname "$0")/.."
D=$(mktemp -d /tmp/td-map.XXXX)
TRACKPAD_DRAW_DATA=$D "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-mapping "$@" >/dev/null 2>&1 &
P=$!; for _ in $(seq 1 60); do [ -f "$D/ui-step.txt" ] && break; sleep 0.25; done; kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D/test-mapping.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
chk(abs(r["windowContentAspect"] - r["padAspect"]) < 0.01, f"window content has the trackpad's shape ({r['windowContentAspect']:.3f} vs pad {r['padAspect']:.3f}): no stretch when windowed")
chk(r["fullScreenPrimary"], "window can go full screen (green button, ⌃⌘F)")
for s in r["scenarios"]:
    e = s["cornerErrorPt"]
    chk(s["gapPt"] < 0.5 and max(e.values()) < 0.5 and s["toolbarHiddenInDrawMode"],
        f"{s['name']}: writing area = whole {int(s['container'][0])}x{int(s['container'][1])} view (gap {s['gapPt']:.1f} pt); "
        f"pad corners/edges land on the view's corners/edges (worst {max(e.values()):.2f} pt at zoom 1 and zoom 3 panned); "
        f"toolbar hidden in draw mode; stretch {abs(s['stretch'] - 1) * 100:.1f}%")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
PY
