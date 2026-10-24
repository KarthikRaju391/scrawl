"""Plain vs damped prediction on recorded strokes. Metrics (screen pt at 100% zoom):
  behind  = tip vs the finger when the frame appears (+23 ms)
  offpath = tip's distance from the path the finger actually took in the next 60 ms (the 'bending')"""
import json, math, sys
sys.path.insert(0, 'tools')
from filter_sweep import one_euro
PT = 10.96
strokes = []
for p in sys.argv[1:]:
    for l in open(p):
        r = json.loads(l)
        if not r.get('kind') and r.get('committed') and len(r['samples']) > 20:
            strokes.append([(s[0], s[1], s[2]) for s in r['samples']])
def q(v, p): v = sorted(v); return v[min(len(v) - 1, int(p * (len(v) - 1)))]
def seg_dist(px, py, a, b):
    dx, dy = b[1] - a[1], b[2] - a[2]; l2 = dx * dx + dy * dy
    t = 0 if l2 == 0 else max(0, min(1, ((px - a[1]) * dx + (py - a[2]) * dy) / l2))
    return math.hypot(px - (a[1] + t * dx), py - (a[2] + t * dy))
def run(ahead_ms, damped):
    behind, off = [], []
    for st in strokes:
        f = one_euro(st, 1.0, 1.0, 0.0)
        for i in range(4, len(st)):
            dt = st[i][0] - st[i-2][0]
            v = ((f[i][0]-f[i-2][0])/dt, (f[i][1]-f[i-2][1])/dt)
            dt2 = st[i-2][0] - st[i-4][0]
            v0 = ((f[i-2][0]-f[i-4][0])/dt2, (f[i-2][1]-f[i-4][1])/dt2)
            sp, sp0 = math.hypot(*v), math.hypot(*v0)
            a = min(ahead_ms / 1000, 0.025) if ahead_ms and sp > 20 else 0
            if damped and a:
                if sp < sp0: a *= (sp / sp0) ** 2                       # slowing down: predict less
                cos = (v[0]*v0[0] + v[1]*v0[1]) / max(sp * sp0, 1e-9)
                a *= max(0.0, (cos - 0.7) / 0.3)                          # turning > ~45 deg: no prediction
            px, py = f[i][0] + v[0]*a, f[i][1] + v[1]*a
            tgt = next((st[j] for j in range(i, len(st)) if st[j][0]-st[i][0] >= 0.023), st[-1])
            behind.append(math.hypot(px-tgt[1], py-tgt[2]) * PT)
            fut = [st[j] for j in range(i, len(st)) if st[j][0]-st[i][0] <= 0.06]
            off.append((min(seg_dist(px, py, a_, b_) for a_, b_ in zip(fut, fut[1:])) if len(fut) > 1 else math.hypot(px-st[i][1], py-st[i][2])) * PT)
    return q(behind, .5), q(behind, .95), q(off, .5), q(off, .95)
for ahead in (0, 8, 16, 24):
    for damped in ((False, True) if ahead else (False,)):
        b5, b95, o5, o95 = run(ahead, damped)
        print(f"prediction {ahead:2d} ms {'damped' if damped else 'plain ':6s}: behind finger p50 {b5:4.1f} p95 {b95:5.1f} pt | off the real path p50 {o5:4.1f} p95 {o95:5.1f} pt")
