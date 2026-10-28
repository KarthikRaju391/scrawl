#!/bin/bash
# Automatic new line (and Return): the view goes one line down AND back to the line start (background).
cd "$(dirname "$0")/.."
D=$(mktemp -d /tmp/td-nl.XXXX)
TRACKPAD_DRAW_DATA=$D "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-newline "$@" >/dev/null 2>&1 &
P=$!; for _ in $(seq 1 240); do [ -f "$D/ui-step.txt" ] && break; sleep 0.25; done; kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D/test-newline.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); bad = []
cases = r["cases"]
for c in cases:
    ok = c["newLines"] >= 1 and abs(c["viewMinX"] - c["wantMinX"]) < 1.0 and c["movedDown"] > 0 and (not c["locked"] or abs(c["zoomAfter"] - c["zoom"]) < 1e-9)
    if not ok: bad.append(c)
print(("PASS" if not bad else "FAIL"), f"auto new line returns to the block's start (where its first line began): {len(cases) - len(bad)}/{len(cases)} cases "
      "(3 line widths x zoom 2/3/5 x zoom lock off/on x 2 starts)")
for c in bad[:12]:
    print(f"   {c['lineWidth']:>4} zoom {c['zoom']} {'locked' if c['locked'] else 'free  '} {c['start']:<24} "
          f"{c['letters']} letters, {c['strokes']} strokes, new lines {c['newLines']}, view x {c['viewMinX']:.0f} (want {c['wantMinX']:.0f}), down {c['movedDown']:.0f}")
if len(bad) > 12: print(f"   ... and {len(bad) - 12} more")
pc = r["palmOnEdgeDuringPause"]
okp = pc["newLines"] == 1 and abs(pc["viewMinX"] - pc["wantMinX"]) < 1.0 and pc["movedDown"] > 0
print(("PASS" if okp else "FAIL"), f"palm resting on the pad's edge through the pause: the new line still happens ({pc['newLines']}, view x {pc['viewMinX']:.0f}, want {pc['wantMinX']:.0f})")
if not okp: bad.append(pc)
rk = r["returnKey"]
okr = abs(rk["viewMinX"] - rk["wantMinX"]) < 1.0 and rk["movedDown"] > 0
print(("PASS" if okr else "FAIL"), f"Return in writing mode: one line down and back to the line start (view x {rk['viewMinX']:.0f}, want {rk['wantMinX']:.0f}, down {rk['movedDown']:.0f})")
print("RESULT:", "PASS" if not bad and okr else f"FAIL ({len(bad) + (0 if okr else 1)})")
PY
