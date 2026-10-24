"""Check 3 (jitter): finger held still for 2 s at 100% zoom; spread of the drawn line must be < 1 px.

Usage: python3 -I jitter_check.py data/strokes-*.jsonl
Looks for committed strokes whose raw finger position stayed within 2 mm for >= 2 s
(draw a dot and hold). Skips the first 0.2 s (touch-down settling), then measures over 2 s:
  - centre-line spread: max extent of the filtered points, in screen points and physical pixels
  - raw spread of the sensor input over the same window, for comparison
Strokes drawn at a zoom other than 1 are reported but don't count toward the check.
"""
import json
import sys

found = 0
worst = None
for path in sys.argv[1:]:
    for line in open(path):
        s = json.loads(line)
        if s.get("kind"):
            continue
        sm = s["samples"]  # t, raw mm x, y, pressure, size, out x, y, out pressure
        if not s.get("committed") or len(sm) < 50:
            continue
        t0 = sm[0][0]
        win = [r for r in sm if 0.2 <= r[0] - t0 <= 2.2]
        if not win or win[-1][0] - win[0][0] < 1.9:
            continue
        rx = [r[1] for r in win]; ry = [r[2] for r in win]
        if max(max(rx) - min(rx), max(ry) - min(ry)) > 2.0:
            continue  # finger moved: not a hold
        found += 1
        k = s["ptPerUnit"] * s["zoom"]
        ox = [r[5] for r in win]; oy = [r[6] for r in win]
        spread_pt = max(max(ox) - min(ox), max(oy) - min(oy)) * k
        spread_px = spread_pt * s["backing"]
        raw_pt = max(max(rx) - min(rx), max(ry) - min(ry)) / 124.8 * 1600 / s["zoom"] * k  # raw mm -> canvas -> pt
        pr = [r[7] for r in win]
        ok = spread_px < 1.0
        if s["zoom"] == 1 and (worst is None or spread_px > worst):
            worst = spread_px
        print(f"{path.split('/')[-1]} {s['tool']} zoom {s['zoom']:.2f}: {len(win)} samples over {win[-1][0]-win[0][0]:.2f} s; "
              f"drawn spread {spread_pt:.3f} pt = {spread_px:.3f} px (raw input {raw_pt:.3f} pt); "
              f"pressure range {min(pr):.2f}-{max(pr):.2f} -> {'PASS' if ok else 'FAIL'}")
if not found:
    print("no held-still strokes found (hold one finger still >= 2.2 s in draw mode, then lift)")
elif worst is not None:
    print(f"\nworst at 100% zoom: {worst:.3f} px -> {'PASS' if worst < 1 else 'FAIL'} (target < 1 px)")
