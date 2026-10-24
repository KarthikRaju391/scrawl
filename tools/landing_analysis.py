"""Where does the finger land when it comes back down? Karthik's sessions, read-only.
For consecutive strokes (lift -> next touch-down within 2 s), delta = touch-down - previous lift on the
pad (mm). Contexts: dot (next stroke < 3 mm long), return (jumps left > 15% of the pad), above/below
(|dy| > 6 mm), continue (|delta| < 4 mm), other. Reports per-context spread and the systematic
(average) offset, per session, to see whether any of it is consistent enough to correct."""
import json, math, sys, statistics as st
PADW, PADH = 124.8, 76.8

def strokes(path):
    out = []
    for l in open(path):
        r = json.loads(l)
        if r.get('kind') or not r.get('committed') or len(r['samples']) < 2: continue
        s = r['samples']
        L = sum(math.hypot(b[1] - a[1], b[2] - a[2]) for a, b in zip(s, s[1:]))
        out.append(dict(t0=s[0][0], t1=s[-1][0], down=(s[0][1], s[0][2]), lift=(s[-1][1], s[-1][2]), length=L, zoom=r['zoom'],
                        h=max(x[2] for x in s) - min(x[2] for x in s)))
    return out

def ctx(a, b):
    dx, dy = b['down'][0] - a['lift'][0], b['down'][1] - a['lift'][1]
    if b['length'] < 3: return 'dot', dx, dy
    if dx < -0.15 * PADW: return 'return', dx, dy
    if abs(dy) > 6: return 'above/below', dx, dy
    if math.hypot(dx, dy) < 4: return 'continue', dx, dy
    return 'other', dx, dy

def fmt(v): return f"{st.mean(v):+5.2f} ± {st.pstdev(v):4.2f}" if len(v) > 1 else "  n/a"
allc = {}
for path in sys.argv[1:]:
    ss = strokes(path)
    pairs = [(a, b) for a, b in zip(ss, ss[1:]) if 0 <= b['t0'] - a['t1'] < 2]
    by = {}
    for a, b in pairs:
        c, dx, dy = ctx(a, b)
        by.setdefault(c, []).append((dx, dy, b['t0'] - a['t1']))
        allc.setdefault(c, []).append((dx, dy, b['t0'] - a['t1'], path))
    print(f"\n{path.split('/')[-1]}: {len(ss)} strokes, {len(pairs)} lift->touch pairs")
    for c in ('continue', 'other', 'dot', 'above/below', 'return'):
        v = by.get(c, [])
        if not v: continue
        print(f"  {c:12s} n={len(v):4d}  dx {fmt([x[0] for x in v])} mm  dy {fmt([x[1] for x in v])} mm  gap {st.median([x[2] for x in v])*1000:4.0f} ms")
print("\nALL SESSIONS")
for c in ('continue', 'other', 'dot', 'above/below', 'return'):
    v = allc.get(c, [])
    if v: print(f"  {c:12s} n={len(v):4d}  dx {fmt([x[0] for x in v])} mm  dy {fmt([x[1] for x in v])} mm")
# Is the 'continue' offset systematic? per-session means and a split-half check.
cont = allc.get('continue', [])
sess = sorted(set(x[3] for x in cont))
means = [(st.mean([x[0] for x in cont if x[3] == s]), st.mean([x[1] for x in cont if x[3] == s])) for s in sess if sum(1 for x in cont if x[3] == s) > 20]
print("  'continue' mean offset per session (dx, dy mm):", [(round(a, 2), round(b, 2)) for a, b in means])
