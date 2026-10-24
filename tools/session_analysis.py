"""Does the view moving (auto-pan, pinch, new line) break where Karthik lands? Per stroke, from a
session log + its stroke log (recorded by the test build):
  - view changed between the previous lift and this touch-down? (and why)
  - landing vs where the previous ink is now on the pad (followed the screen) and vs where the finger
    physically lifted (habit), in pad mm
  - was the stroke undone later?
Usage: python3 -I tools/session_analysis.py <session.jsonl> <strokes.jsonl> [more pairs...]"""
import json, math, sys, statistics as st
PADW, PADH = 124.8, 76.8

def load(p): return [json.loads(l) for l in open(p)]
rows_all = []
args = sys.argv[1:]
for sp, kp in zip(args[0::2], args[1::2]):
    sess, recs = load(sp), [r for r in load(kp) if not r.get('kind')]
    views = [r for r in sess if r['k'] == 'view']
    def view_at(m):
        v = None
        for r in views:
            if r['m'] > m: break
            v = r
        return v or (views[0] if views else None)
    # Rebuild page contents exactly like the app (commits, erases, undo/redo/clear snapshots); a stroke
    # counts as undone if an undo removed it and nothing brought it back.
    strokes, k, by_id = [], 0, {}
    page, docs, undo, redo = 0, {0: []}, {}, {}
    def snap(): undo.setdefault(page, []).append(list(docs.get(page, []))); redo[page] = []
    for r in sess:
        if r['k'] != 'act': continue
        a = r['a']
        if a == 'strokeBegin':
            rec = recs[k] if k < len(recs) else None; k += 1
            if rec is None: continue
            strokes.append(dict(m=r['m'], pad=(r['padX'] * PADW, r['padY'] * PADH), rec=rec, undone=False, tool=rec['tool'],
                                committed=rec.get('committed', False)))
        elif a == 'commit': by_id[r['id']] = strokes[-1]; snap(); docs.setdefault(page, []).append(r['id'])
        elif a == 'erase': docs[page] = [i for i in docs.get(page, []) if i not in set(r['ids'])]
        elif a == 'undo' and undo.get(page):
            before = set(docs.get(page, [])); redo.setdefault(page, []).append(list(docs.get(page, []))); docs[page] = undo[page].pop()
            for i in before - set(docs[page]): by_id[i]['undone'] = True
        elif a == 'redo' and redo.get(page):
            undo.setdefault(page, []).append(list(docs.get(page, []))); docs[page] = redo[page].pop()
            for i in docs[page]: by_id[i]['undone'] = False
        elif a == 'clear' and docs.get(page): snap(); docs[page] = []
        elif a == 'newPage': page = max(docs) + 1; docs[page] = []
        elif a == 'goToPage': page = r['page']
    prev = None
    for s in strokes:
        if not s['committed'] or s['tool'] == 'eraser': continue
        if prev is not None and s['m'] - prev['endM'] < 3:
            changes = [v['src'] for v in views if prev['endM'] < v['m'] <= s['m']]
            v = view_at(s['m'])
            ex, ey = prev['inkEnd']
            ink_now = ((ex - v['x']) / v['w'] * PADW, (ey - v['y']) / v['h'] * PADH)
            d_ink = math.hypot(s['pad'][0] - ink_now[0], s['pad'][1] - ink_now[1])
            d_lift = math.hypot(s['pad'][0] - prev['liftPad'][0], s['pad'][1] - prev['liftPad'][1])
            rows_all.append(dict(change=sorted(set(changes))[0] if changes else None, d_ink=d_ink, d_lift=d_lift, undone=s['undone'],
                                 gap=s['m'] - prev['endM']))
        sm = s['rec']['samples']
        prev = dict(endM=s['m'] + (sm[-1][0] - sm[0][0]), inkEnd=(sm[-1][5], sm[-1][6]), liftPad=(sm[-1][1], sm[-1][2]))

def summ(name, v):
    if not v: return
    und = sum(x['undone'] for x in v) / len(v)
    follow = sum(x['d_ink'] < x['d_lift'] for x in v) / len(v)
    print(f"{name:28s} n={len(v):4d}  undone {und:5.1%}  landed closer to the ink's new place than to the lift: {follow:5.1%}  "
          f"|to ink| p50 {st.median([x['d_ink'] for x in v]):5.1f} mm  |to lift| p50 {st.median([x['d_lift'] for x in v]):5.1f} mm")
summ("view unchanged", [x for x in rows_all if x['change'] is None])
for c in sorted(set(x['change'] for x in rows_all if x['change'])):
    summ(f"after a view change: {c}", [x for x in rows_all if x['change'] == c])
