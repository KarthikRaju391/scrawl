"""How far the predicted tip lands from where the finger really was `ahead` later, on recorded
strokes (same filter + prediction maths as the app). Screen pt at 100% zoom (10.96 pt/mm)."""
import json, math, sys
sys.path.insert(0, 'tools')
from filter_sweep import one_euro  # noqa: E402
PT = 10.96
strokes = []
for p in sys.argv[1:]:
    for l in open(p):
        r = json.loads(l)
        if not r.get('kind') and r.get('committed') and len(r['samples']) > 20:
            strokes.append([(s[0], s[1], s[2]) for s in r['samples']])
def q(v, p): v = sorted(v); return v[min(len(v) - 1, int(p * (len(v) - 1)))]
for mc, beta in [(1.0, 1.0), (4.0, 1.0)]:
    for ahead_ms in (0, 8, 16, 24):
        err_all, err_end = [], []
        for st in strokes:
            f = one_euro(st, mc, beta, 0.0)
            for i in range(2, len(st)):
                dt = st[i][0] - st[i-2][0]
                vx, vy = (f[i][0] - f[i-2][0]) / dt, (f[i][1] - f[i-2][1]) / dt
                speed = math.hypot(vx, vy)
                a = min(ahead_ms / 1000, 0.025) if ahead_ms and speed > 20 else 0
                px, py = f[i][0] + vx * a, f[i][1] + vy * a
                # where the finger actually was `ahead` later (or at lift, if the stroke ended first)
                tgt = st[-1]
                for j in range(i, len(st)):
                    if st[j][0] - st[i][0] >= ahead_ms / 1000: tgt = st[j]; break
                e = math.hypot(px - tgt[1], py - tgt[2]) * PT
                err_all.append(e)
                if st[-1][0] - st[i][0] < 0.06: err_end.append(e)   # last 60 ms before lifting
        print(f"minCutoff {mc:g} beta {beta:g}, prediction {ahead_ms:2d} ms: tip vs real finger p50 {q(err_all,.5):4.1f} pt p95 {q(err_all,.95):5.1f} pt | last 60 ms before lift p50 {q(err_end,.5):4.1f} p95 {q(err_end,.95):5.1f} pt")
