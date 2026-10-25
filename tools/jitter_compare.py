"""Ink steadiness per recorded stroke log: how much the drawn points wobble around their own smoothed path
(screen points), against how much the raw finger samples wobble (scaled to screen points by the stroke's
own raw->ink scale), plus ink lag (finger to ink, screen points) and sample timing.
Usage: python3 -I tools/jitter_compare.py data/strokes-*.jsonl"""
import json, sys, math, statistics as st

def wobble(pts, w=4):
    """RMS distance of each point from the mean of its +-w neighbours (high-frequency jitter)."""
    out = []
    for i in range(w, len(pts) - w):
        mx = sum(p[0] for p in pts[i - w:i + w + 1]) / (2 * w + 1); my = sum(p[1] for p in pts[i - w:i + w + 1]) / (2 * w + 1)
        out.append(math.hypot(pts[i][0] - mx, pts[i][1] - my))
    return math.sqrt(sum(o * o for o in out) / len(out)) if out else None

def length(pts): return sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(pts, pts[1:]))

for path in sys.argv[1:]:
    rows = [json.loads(l) for l in open(path)]
    ink, raw, ratio, lag, gaps = [], [], [], [], []
    for r in rows:
        if r.get('kind') or not r.get('committed') or len(r.get('samples', [])) < 20 or r.get('tool') == 'eraser': continue
        s = r['samples']; k = r['ptPerUnit'] * r['zoom']                 # canvas units -> screen points
        o = [(x[5] * k, x[6] * k) for x in s]; m = [(x[1], x[2]) for x in s]
        lo, lm = length(o), length(m)
        if lm < 2: continue
        scale = lo / lm                                                   # screen pt per mm along this stroke
        wo, wm = wobble(o), wobble([(a * scale, b * scale) for a, b in m])
        if wo is None: continue
        ink.append(wo); raw.append(wm); ratio.append(wo / wm if wm > 0 else 0)
        gaps += [b[0] - a[0] for a, b in zip(s, s[1:])]
    if not ink: print(f"{path}: no strokes"); continue
    print(f"{path.split('/')[-1]}: {len(ink)} strokes; ink wobble p50 {st.median(ink):.3f} pt (p90 {sorted(ink)[int(.9 * len(ink))]:.3f}); "
          f"raw finger wobble p50 {st.median(raw):.3f} pt; ink/raw p50 {st.median(ratio):.2f}; sample gap p50 {st.median(gaps) * 1000:.1f} ms")
