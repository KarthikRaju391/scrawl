"""Recorded sessions vs replays of them: old behaviour (fidelity) and new behaviour (counterfactual).
Usage: cf_compare.py <orig session> <orig strokes> <old dir> <new dir> [more groups of 4...]
Strokes are aligned by touch-down order (the replays get the same touch input). Undo rates are
pooled over all original sessions: no page move before the stroke / a move after a pause (>= 400 ms)
/ a move mid-word (< 400 ms)."""
import json, sys, glob, math, statistics as st
def load(p): return [json.loads(l) for l in open(p)]
def strokes_log(p): return [r for r in load(p) if not r.get('kind')]

def timeline(sess, recs):
    acts = [r for r in sess if r['k'] == 'act']
    views = [(r['m'], r['src']) for r in sess if r['k'] == 'view']
    S, k = [], 0
    by_id, docs, undo, redo, page, moves = {}, {0: []}, {}, {}, 0, []
    for r in acts:
        a = r['a']
        if a == 'strokeBegin':
            rec = recs[k] if k < len(recs) else None; k += 1
            S.append(dict(m=r['m'], end=None, committed=False, undone=False, rec=rec))
        elif a == 'strokeEnd' and S: S[-1]['end'] = r['m']; S[-1]['committed'] = r.get('committed', False)
        elif a == 'commit':
            by_id[r['id']] = S[-1]; undo.setdefault(page, []).append(list(docs.get(page, []))); docs.setdefault(page, []).append(r['id'])
        elif a == 'undo' and undo.get(page):
            before = set(docs[page]); redo.setdefault(page, []).append(list(docs[page])); docs[page] = undo[page].pop()
            for i in before - set(docs[page]): by_id[i]['undone'] = True
        elif a == 'redo' and redo.get(page):
            undo.setdefault(page, []).append(list(docs[page])); docs[page] = redo[page].pop()
            for i in docs[page]: by_id[i]['undone'] = False
        elif a == 'newPage': page = max(docs) + 1; docs[page] = []
        elif a == 'goToPage': page = r['page']
        elif a in ('autoPan', 'newLine'): moves.append((r['m'], a))
    prev_end = None
    for s in S:
        lo = prev_end if prev_end is not None else -1e18
        s['moves'] = [a for (m, a) in moves if lo < m <= s['m']] if prev_end is not None else []
        s['viewChange'] = any(lo < m <= s['m'] for m, _ in views) if prev_end is not None else False
        s['gap'] = s['m'] - prev_end if prev_end is not None else None
        if s['end'] is not None: prev_end = s['end']
        sm = s['rec']['samples'] if s['rec'] else []
        if sm: s['c0'] = (sm[0][5], sm[0][6]); s['ppu'] = s['rec']['ptPerUnit']
    return S, moves

groups = [sys.argv[i:i + 4] for i in range(1, len(sys.argv), 4)]
runs = []
for orig_s, orig_k, old_dir, new_dir in groups:
    O, Om = timeline(load(orig_s), strokes_log(orig_k))
    R, Rm = timeline(load(glob.glob(old_dir + '/session-*.jsonl')[0]), strokes_log(glob.glob(old_dir + '/strokes-*.jsonl')[0]))
    N, Nm = timeline(load(glob.glob(new_dir + '/session-*.jsonl')[0]), strokes_log(glob.glob(new_dir + '/strokes-*.jsonl')[0]))
    assert len(O) == len(R) == len(N), (orig_s, len(O), len(R), len(N))
    runs.append((orig_s.split('/')[-1], O, Om, R, Rm, N, Nm))

def cat(s):
    if not s['moves']: return 'none'
    return 'midword' if s['gap'] is not None and s['gap'] < 0.4 else 'paused'
pool = {'none': [], 'paused': [], 'midword': []}
for _, O, *_ in runs:
    for o in O:
        if o['committed']: pool[cat(o)].append(o['undone'])
rate = {k: (sum(v) / len(v) if v else 0) for k, v in pool.items()}
print("undo rate in your recordings (all sessions): " + ", ".join(f"{k} {rate[k]:.0%} (n={len(pool[k])})" for k in ('none', 'paused', 'midword')))
print()
tot = dict(midO=0, midN=0, wwO=0, wwN=0, ww=0, modO=0.0, modN=0.0, actual=0, exp=0, expStill=0)
for name, O, Om, R, Rm, N, Nm in runs:
    dev = [math.hypot(o['c0'][0] - r['c0'][0], o['c0'][1] - r['c0'][1]) * o['ppu'] for o, r in zip(O, R) if o.get('c0') and r.get('c0') and o['committed']]
    ww = [i for i, o in enumerate(O) if o['gap'] is not None and o['gap'] < 0.3 and o['committed']]
    midO = sum(1 for o in O if o['committed'] and cat(o) == 'midword'); midN = sum(1 for n, o in zip(N, O) if o['committed'] and cat(n) == 'midword')
    wwO = sum(1 for i in ww if O[i]['moves']); wwN = sum(1 for i in ww if N[i]['moves'])
    exp = [i for i, o in enumerate(O) if o['committed'] and o['undone'] and cat(o) == 'midword']
    still = [i for i in exp if cat(N[i]) == 'midword']
    mO = sum(rate[cat(o)] for o in O if o['committed']); mN = sum(rate[cat(n)] for n, o in zip(N, O) if o['committed'])
    act = sum(o['undone'] for o in O if o['committed'])
    print(f"{name}: fidelity moves {len(Om)}/{len(Rm)}, starts p50 {st.median(dev):.2f} pt max {max(dev):.2f} | page moves {len(Om)} -> {len(Nm)} | "
          f"mid-word moves {midO} -> {midN} | within-word pairs with a page move {wwO}/{len(ww)} -> {wwN}/{len(ww)} | "
          f"undone after a mid-word move {len(exp)} -> still exposed {len(still)} | modelled undos {mO:.1f} -> {mN:.1f} (actual {act})")
    for k, v in (('midO', midO), ('midN', midN), ('wwO', wwO), ('wwN', wwN), ('ww', len(ww)), ('modO', mO), ('modN', mN), ('actual', act), ('exp', len(exp)), ('expStill', len(still))): tot[k] += v
print()
print(f"ALL: strokes that came right after a mid-word page move {tot['midO']} -> {tot['midN']}; within-word pairs split by a page move {tot['wwO']}/{tot['ww']} -> {tot['wwN']}/{tot['ww']}; "
      f"undone strokes that followed a mid-word move {tot['exp']} -> still exposed {tot['expStill']}; modelled undos {tot['modO']:.1f} -> {tot['modN']:.1f} (actual {tot['actual']})")
