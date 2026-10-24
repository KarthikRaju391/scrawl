"""Re-filter recorded raw samples with One Euro settings (same maths as app/Ink.swift, plus the
streamline step) and report, in screen points at writing zoom 3 (~32.9 pt per pad mm):
  lag    = distance from output to the raw finger position at the same sample
  wobble = RMS of the output's second difference minus the raw signal's (smoothness gained/lost)
Usage: python3 -I tools/filter_sweep.py data/strokes-*.jsonl"""
import json, math, sys

PT_PER_MM = 1600 * 0.855 / 124.8 * 3   # canvas ~1368 pt wide at zoom 1, x3

def one_euro(samples, min_cutoff, beta, streamline, d_cutoff=1.0):
    out = []; prev = None; dprev = (0.0, 0.0); tprev = 0; last = None
    alpha = lambda c, dt: 1 / (1 + (1 / (2 * math.pi * c)) / dt)
    for t, x, y in samples:
        if prev is None:
            prev = (x, y); tprev = t; f = (x, y)
        else:
            dt = max(t - tprev, 1e-4); tprev = t
            dx = ((x - prev[0]) / dt, (y - prev[1]) / dt)
            ad = alpha(d_cutoff, dt)
            dprev = (dprev[0] + ad * (dx[0] - dprev[0]), dprev[1] + ad * (dx[1] - dprev[1]))
            a = alpha(min_cutoff + beta * math.hypot(*dprev), dt)
            f = (prev[0] + a * (x - prev[0]), prev[1] + a * (y - prev[1])); prev = f
        if last is not None:
            k = 0.15 + (1 - streamline) * 0.85
            f = (last[0] + (f[0] - last[0]) * k, last[1] + (f[1] - last[1]) * k)
        last = f; out.append(f)
    return out

def wobble(pts):
    acc = [math.hypot(c[0] - 2 * b[0] + a[0], c[1] - 2 * b[1] + a[1]) for a, b, c in zip(pts, pts[1:], pts[2:])]
    return math.sqrt(sum(v * v for v in acc) / max(len(acc), 1))

def main():
    strokes = []
    for p in sys.argv[1:]:
        for l in open(p):
            s = json.loads(l)
            if s.get('kind') != 'contact' and s.get('committed') and len(s['samples']) > 20:
                strokes.append([(r[0], r[1], r[2]) for r in s['samples']])
    raw_w = sum(wobble([(x, y) for _, x, y in s]) for s in strokes) / len(strokes)
    print(f"{len(strokes)} strokes; raw wobble {raw_w * PT_PER_MM:.2f} pt RMS second difference")
    def q(v, p): v = sorted(v); return v[min(len(v) - 1, int(p * (len(v) - 1)))]
    import os
    grid = [(1.0, 0.05, 0.25), (1.0, 0.5, 0.0), (1.0, 1.0, 0.0), (1.5, 1.0, 0.0), (1.5, 2.0, 0.0), (2.0, 1.0, 0.0), (2.0, 2.0, 0.0), (1e9, 0, 0.0)]
    for mc, beta, sl in grid:
        lags = []; w = 0
        for s in strokes:
            f = one_euro(s, mc, beta, sl)
            lags += [math.hypot(a[0] - x, a[1] - y) for a, (_, x, y) in zip(f, s)]
            w += wobble(f)
        name = "no filter" if mc > 1e8 else f"minCutoff {mc:g} beta {beta:g} streamline {sl:g}"
        print(f"{name:42s} lag p50 {q(lags, .5) * PT_PER_MM:5.1f} pt  p95 {q(lags, .95) * PT_PER_MM:5.1f} pt   wobble {w / len(strokes) * PT_PER_MM:.2f} pt")


if __name__ == "__main__":
    main()
