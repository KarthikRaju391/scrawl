"""Multi-finger touch episodes in recorded sessions (draw mode): how fingers land, move and lift, to choose
tap rules that never match a pan or pinch. An episode = from the first frame with 2+ fingers down until all
lift. Per episode: finger count, landing spread (first to last touch-down), lift spread, duration, the most
any finger moved (mm). Then: how many episodes pass given tap rules, and how many pairs would be double taps.
Usage: python3 -I tools/tap_analysis.py data/session-*.jsonl"""
import json, sys, math, itertools
PADW, PADH = 124.8, 76.8

def episodes(path):
    rows = [json.loads(l) for l in open(path) if '"touch"' in l]
    out, cur, live, banned = [], None, {}, set()
    for r in rows:
        if r['k'] != 'touch': continue
        t = r['m']
        # As the app sees them: contacts that touched down in the 5% edge band are ignored until they lift.
        for c in r['c']:
            if c[0] not in live and c[0] not in banned and (c[2] < 0.05 or c[2] > 0.95 or c[3] < 0.05 or c[3] > 0.95): banned.add(c[0])
        banned &= {c[0] for c in r['c']}
        ids = {c[0]: (c[2] * PADW, c[3] * PADH) for c in r['c'] if c[0] not in banned}
        if cur is None and len(ids) >= 2:
            cur = dict(start=t, down={}, up={}, first={}, maxmove={}, n=0)
            for i, p in ids.items(): cur['down'][i] = live.get(i, (t, p))[0]; cur['first'][i] = live.get(i, (t, p))[1]
        if cur is not None:
            for i, p in ids.items():
                if i not in cur['down']: cur['down'][i] = t; cur['first'][i] = p
                f = cur['first'][i]; cur['maxmove'][i] = max(cur['maxmove'].get(i, 0), math.hypot(p[0] - f[0], p[1] - f[1]))
            for i in list(cur['down']):
                if i not in ids and i not in cur['up']: cur['up'][i] = t
            cur['n'] = max(cur['n'], len(ids))
            if not ids:
                downs, ups = sorted(cur['down'].values()), sorted(cur['up'].values())
                out.append(dict(n=len(cur['down']), peak=cur['n'], start=downs[0], end=ups[-1] if ups else t, land=downs[-1] - downs[0],
                                lift=(ups[-1] - ups[0]) if ups else 0, dur=(ups[-1] if ups else t) - downs[0], move=max(cur['maxmove'].values())))
                cur = None
        for i, p in ids.items():
            if i not in live: live[i] = (t, p)
        for i in list(live):
            if i not in ids: del live[i]
    return out

def is_tap(e, n, land, lift, dur, move): return e['n'] == n and e['land'] <= land and e['lift'] <= lift and e['dur'] <= dur and e['move'] <= move

if __name__ == '__main__':
    eps = []
    for p in sys.argv[1:]:
        for e in episodes(p): e['file'] = p; eps.append(e)
    print(f"{len(eps)} multi-finger episodes in {len(sys.argv) - 1} sessions; by finger count:",
          {k: sum(1 for e in eps if e['n'] == k) for k in sorted(set(e['n'] for e in eps))})
    two = [e for e in eps if e['n'] == 2]
    def pct(xs, q): xs = sorted(xs); return xs[min(len(xs) - 1, int(q * (len(xs) - 1)))] if xs else float('nan')
    for name, key, k in (("duration (ms)", 'dur', 1000), ("max finger movement (mm)", 'move', 1), ("landing spread (ms)", 'land', 1000), ("lift spread (ms)", 'lift', 1000)):
        xs = [e[key] * k for e in two]
        print(f"  2-finger {name}: min {min(xs):.1f}  p5 {pct(xs, .05):.1f}  p25 {pct(xs, .25):.1f}  p50 {pct(xs, .5):.1f}")
    for rules in (dict(land=0.12, lift=0.12, dur=0.30, move=3.0, gap=0.35), dict(land=0.08, lift=0.08, dur=0.25, move=2.0, gap=0.30),
                  dict(land=0.06, lift=0.06, dur=0.20, move=1.5, gap=0.30), dict(land=0.05, lift=0.05, dur=0.18, move=1.2, gap=0.30)):
        for n in (2, 3):
            taps = [e for e in eps if is_tap(e, n, rules['land'], rules['lift'], rules['dur'], rules['move'])]
            doubles = sum(1 for a, b in zip(taps, taps[1:]) if a['file'] == b['file'] and 0 <= b['start'] - a['end'] <= rules['gap'])
            print(f"rules {rules}: {n}-finger episodes counted as taps: {len(taps)}; as double taps: {doubles}")
    # The closest pans to tap rules, for margin.
    close = sorted(two, key=lambda e: (e['move'], e['dur']))[:5]
    print("five 2-finger episodes with the least movement:", [(round(e['move'], 2), round(e['dur'] * 1000), round(e['land'] * 1000), round(e['lift'] * 1000)) for e in close])
