"""Scratch-out detector, prototyped on every committed stroke Karthik recorded (data/strokes-*.jsonl) and on
synthetic scratches. Shape only, in pad millimetres (independent of zoom):
  legs      the stroke projected on its main axis, split where it turns back (hysteresis: 30% of the extent)
  big legs  legs at least 55% of the extent long
  ratio     path length / extent along the axis
  speed     path length / duration (mm/s)
A scratch: >= 4 legs (3 turn-backs), 3 of them big, ratio >= 3.0, speed >= 60 mm/s, extent >= 4 mm, a pen or marker
stroke, net turning under 0.75 turns (circling isn't scratching), and >= 40% of its points within 1.5 mm
of ink already on the page.
Usage: python3 -I tools/scratch_analysis.py [--worst N]
"""
import json, glob, math, random, sys

def features(pts, ts):
    n = len(pts)
    if n < 6: return None
    mx = sum(p[0] for p in pts) / n; my = sum(p[1] for p in pts) / n
    sxx = sum((p[0] - mx) ** 2 for p in pts); syy = sum((p[1] - my) ** 2 for p in pts); sxy = sum((p[0] - mx) * (p[1] - my) for p in pts)
    ang = 0.5 * math.atan2(2 * sxy, sxx - syy)
    ux, uy = math.cos(ang), math.sin(ang)
    s = [(p[0] - mx) * ux + (p[1] - my) * uy for p in pts]
    ext = max(s) - min(s)
    if ext <= 0: return None
    h = 0.3 * ext
    legs, start, ext_pt, direction = [], s[0], s[0], 0
    for v in s[1:]:
        if direction >= 0 and v > ext_pt: ext_pt = v; direction = 1 if v - start > h else direction
        elif direction <= 0 and v < ext_pt: ext_pt = v; direction = -1 if start - v > h else direction
        if direction == 1 and ext_pt - v > h: legs.append(ext_pt - start); start = ext_pt; ext_pt = v; direction = -1
        elif direction == -1 and v - ext_pt > h: legs.append(start - ext_pt); start = ext_pt; ext_pt = v; direction = 1
    legs.append(abs(ext_pt - start))
    big = sum(1 for l in legs if l >= 0.55 * ext)
    L = sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(pts, pts[1:]))
    dur = max(ts[-1] - ts[0], 1e-3)
    # Net turning: a zig-zag turns left and right in turn (net ~0); circling turns one way (2 pi per loop).
    rs, acc = [pts[0]], 0.0
    for a, b in zip(pts, pts[1:]):
        acc += math.hypot(b[0] - a[0], b[1] - a[1])
        if acc >= 0.5: rs.append(b); acc = 0.0
    net = 0.0
    for a, b, c in zip(rs, rs[1:], rs[2:]):
        t1 = math.atan2(b[1] - a[1], b[0] - a[0]); t2 = math.atan2(c[1] - b[1], c[0] - b[0])
        d = (t2 - t1 + math.pi) % (2 * math.pi) - math.pi
        if abs(d) < 0.8 * math.pi: net += d   # a cusp (turning back) has no side
    return {"bigLegs": big, "legs": len(legs), "ratio": L / ext, "speed": L / dur, "extent": ext, "dur": dur, "loops": abs(net) / (2 * math.pi)}

def is_scratch(f):
    return f and f["bigLegs"] >= 3 and f["legs"] >= 4 and f["ratio"] >= 3.0 and f["speed"] >= 60 and f["extent"] >= 4 and f["loops"] < 0.75

def synthetic(rng, n):
    out = []
    for _ in range(n):
        legs = rng.randint(4, 9); amp = rng.uniform(5, 30); spd = rng.uniform(70, 220); ang = rng.uniform(-0.6, 0.6)
        drift = rng.uniform(0.2, 1.2)   # mm sideways per leg
        pts = []
        x, y = 0.0, 0.0
        for k in range(legs):
            tx = (amp if k % 2 == 0 else 0) + rng.gauss(0, amp * 0.08); ty = k * drift + rng.gauss(0, 0.3)
            steps = max(3, int(abs(tx - x) / (spd * 0.008)))
            for i in range(steps):
                u = (i + 1) / steps
                pts.append((x + (tx - x) * u + rng.gauss(0, 0.05), y + (ty - y) * u + rng.gauss(0, 0.05)))
            x, y = tx, ty
        ca, sa = math.cos(ang), math.sin(ang)
        pts = [(p[0] * ca - p[1] * sa, p[0] * sa + p[1] * ca) for p in pts]
        out.append((pts, [i * 0.008 for i in range(len(pts))]))
    return out

def overlap(scr, prev, reach):
    """Share of the scratch's points within `reach` (canvas units) of earlier ink."""
    near = 0
    xs = [p[0] for p in scr]; ys = [p[1] for p in scr]
    box = (min(xs) - reach, min(ys) - reach, max(xs) + reach, max(ys) + reach)
    cand = [q for q in prev if not (q[1][2] < box[0] or q[1][0] > box[2] or q[1][3] < box[1] or q[1][1] > box[3])]
    for p in scr:
        if any(any((p[0] - a[0]) ** 2 + (p[1] - a[1]) ** 2 <= reach * reach for a in pts) for pts, _ in cand): near += 1
    return near / len(scr)

def main():
    real, fp, shape_only = 0, [], []
    feats = []
    for f in sorted(glob.glob("data/strokes-*.jsonl")):
        prev = []   # earlier strokes in this file, canvas points and bounds (undos ignored: more ink, a harder test)
        for line in open(f):
            try: d = json.loads(line)
            except ValueError: continue
            sm = d.get("samples") or []
            if not d.get("committed") or len(sm) < 6: continue
            real += 1
            ft = features([(r[1], r[2]) for r in sm], [r[0] for r in sm])
            cpts = [(r[5], r[6]) for r in sm]
            if ft: feats.append(ft)
            if is_scratch(ft):
                # mm -> canvas units for this stroke: from the first and last samples
                dmm = math.hypot(sm[-1][1] - sm[0][1], sm[-1][2] - sm[0][2]) or 1
                k = math.hypot(sm[-1][5] - sm[0][5], sm[-1][6] - sm[0][6]) / dmm or 1
                ov = overlap(cpts, prev, 1.5 * k)
                shape_only.append((f, d.get("tool"), round(ov, 2), ft))
                if d.get("tool") in ("pen", "marker") and ov >= 0.4: fp.append((f, ft))
            xs = [p[0] for p in cpts]; ys = [p[1] for p in cpts]
            prev.append((cpts, (min(xs), min(ys), max(xs), max(ys))))
            prev = prev[-400:]
    for f, tool, ov, ft in shape_only: print("  shape matches:", f.split("/")[-1], tool, "overlap", ov, "legs", ft["bigLegs"], "loops", round(ft["loops"], 2))
    rng = random.Random(1)
    syn = synthetic(rng, 2000)
    hit = sum(1 for p, t in syn if is_scratch(features(p, t)))
    print(f"real strokes: {real}, detected as scratch (false positives): {len(fp)}")
    print(f"synthetic scratches: {len(syn)}, detected: {hit} ({hit / len(syn):.1%})")
    # Margins: how close real strokes come to each gate.
    worst = sorted(feats, key=lambda f: (-f["bigLegs"], -f["ratio"]))[:int(sys.argv[2]) if len(sys.argv) > 2 else 8]
    for w in worst: print("  closest real:", {k: round(v, 1) for k, v in w.items()})
    for f, ft in fp[:10]: print("  FP", f, ft)

if __name__ == "__main__":
    main()
