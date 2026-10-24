"""On recorded strokes: wherever the finger came to rest mid-stroke (raw speed < 5 mm/s for >= 100 ms),
how long the smoothed ink kept moving (until within 1 px of the resting finger), per Smoothing setting.
Uses the same filter maths as the app (tools/filter_sweep.py). 1 px = 1/21.9 mm at 100% zoom."""
import json, math, sys
sys.path.insert(0, 'tools')
from filter_sweep import one_euro  # noqa: E402

anchors = [(0, 30, 4), (0.5, 4, 1), (1, 0.5, 0.1)]
def params(s):
    a, b = (anchors[0], anchors[1]) if s <= 0.5 else (anchors[1], anchors[2])
    u = (s - a[0]) / (b[0] - a[0])
    return tuple(math.exp(math.log(a[i]) + (math.log(b[i]) - math.log(a[i])) * u) for i in (1, 2))

PX = 21.9
strokes = []
for p in sys.argv[1:]:
    for l in open(p):
        r = json.loads(l)
        if not r.get('kind') and r.get('committed') and len(r['samples']) > 20:
            strokes.append([(s[0], s[1], s[2]) for s in r['samples']])
def q(v, p): v = sorted(v); return v[min(len(v) - 1, int(p * (len(v) - 1)))] if v else float('nan')
for label, (mc, beta) in [("old default (1, 1)", (1.0, 1.0))] + [(f"slider {int(s*100):3d}%", params(s)) for s in (0, .25, .5, .75, 1)]:
    settles = []; stops = 0
    for st in strokes:
        f = one_euro(st, mc, beta, 0.0)
        i = 1
        while i < len(st) - 13:
            sp = [math.hypot(st[j][1] - st[j-1][1], st[j][2] - st[j-1][2]) / max(st[j][0] - st[j-1][0], 1e-3) for j in range(i, i + 13)]
            if all(v < 5 for v in sp):          # resting for 13 frames (~100 ms)
                stops += 1
                rest = st[i]
                k = next((j for j in range(i, len(st)) if math.hypot(f[j][0] - st[j][1], f[j][1] - st[j][2]) * PX < 1), None)
                settles.append(((st[k][0] - rest[0]) * 1000) if k is not None else 999)
                i += 13
                while i < len(st) - 1 and math.hypot(st[i][1] - st[i-1][1], st[i][2] - st[i-1][2]) / 0.008 < 5: i += 1
            i += 1
    print(f"{label:20s} minCutoff {mc:5.2f} beta {beta:4.2f}: {stops} rests; ink still moving after the finger stopped: p50 {q(settles,.5):4.0f} ms, p90 {q(settles,.9):4.0f} ms")
