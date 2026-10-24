"""Edge touches in recorded sessions: where do strokes and two-finger gestures start, and which were undone?
For every contact: where it first touched (mm from each pad edge), what it became (a stroke, part of a
two-finger gesture, or nothing), and for strokes whether an undo removed them for good.
Usage: python3 -I tools/edge_analysis.py data/session-*.jsonl"""
import json, sys, collections
PADW, PADH = 124.8, 76.8

def analyse(path):
    rows = [json.loads(l) for l in open(path)]
    first, last, maxin, peers = {}, {}, {}, collections.defaultdict(set)
    strokes = []            # (contact id at begin, begin record)
    down_ids = []
    docs, undo, redo, by_id = [], [], [], {}
    pending_begin = None
    live, gen = set(), {}
    for r in rows:
        if r['k'] == 'touch':
            raw = [c[0] for c in r['c']]
            # Trackpad ids are reused: a contact is a new one each time its id reappears after a frame without it.
            for rid in raw:
                if rid not in live: gen[rid] = gen.get(rid, 0) + 1
            live = set(raw)
            ids = [(rid, gen[rid]) for rid in raw]
            for c in r['c']:
                i, x, y = (c[0], gen[c[0]]), c[2] * PADW, c[3] * PADH
                if i not in first: first[i] = (x, y, r['m'])
                last[i] = (x, y)
                fx, fy, _ = first[i]
                maxin[i] = max(maxin.get(i, 0), min(x, PADW - x, y) - min(fx, PADW - fx, fy))
                for j in ids:
                    if j != i: peers[i].add(j)
            down_ids = ids
        elif r['k'] == 'act':
            a = r['a']
            if a == 'strokeBegin':
                cid = down_ids[0] if len(down_ids) == 1 else None
                pending_begin = dict(cid=cid, x=r['padX'] * PADW, y=r['padY'] * PADH, undone=False, committed=False, m=r['m'])
                strokes.append(pending_begin)
            elif a == 'commit' and pending_begin is not None:
                pending_begin['committed'] = True; by_id[r['id']] = pending_begin
                undo.append(list(docs)); redo.clear(); docs.append(r['id'])
            elif a == 'erase':
                undo.append(list(docs)); docs = [i for i in docs if i not in set(r['ids'])]
            elif a == 'undo' and undo:
                before = set(docs); redo.append(list(docs)); docs = undo.pop()
                for i in before - set(docs): by_id[i]['undone'] = True
            elif a == 'redo' and redo:
                undo.append(list(docs)); docs = redo.pop()
                for i in docs:
                    if i in by_id: by_id[i]['undone'] = False
            elif a == 'clear':
                undo.append(list(docs)); docs = []
            elif a in ('newPage', 'goToPage'):
                docs, undo, redo = [], [], []   # approximate: per-page history not modelled here
    contacts = []
    for i, (x, y, m) in first.items():
        contacts.append(dict(id=i, x=x, y=y, lx=last[i][0], ly=last[i][1], inward=maxin.get(i, 0), multi=bool(peers[i]),
                             stroke=any(s['cid'] == i for s in strokes)))
    return contacts, strokes

def edge(x, y):
    return min((x, 'left'), (PADW - x, 'right'), (y, 'bottom'), (PADH - y, 'top'))

if __name__ == '__main__':
    allc, alls = [], []
    for p in sys.argv[1:]:
        c, s = analyse(p); allc += c; alls += s
    st = [s for s in alls if s['committed']]
    print(f"{len(allc)} contacts, {len(st)} committed strokes ({sum(s['undone'] for s in st)} undone)")
    print("\nCommitted strokes by where the ink started (distance to nearest edge):")
    print(" band   strokes  undone  rate   | by edge (strokes/undone)")
    for lo, hi in [(0, 2), (2, 4), (4, 6), (6, 8), (8, 12), (12, 99)]:
        g = [s for s in st if lo <= edge(s['x'], s['y'])[0] < hi]
        by = collections.Counter(); byu = collections.Counter()
        for s in g: e = edge(s['x'], s['y'])[1]; by[e] += 1; byu[e] += s['undone']
        print(f" {lo:>2}-{hi:<3}mm {len(g):>6} {sum(s['undone'] for s in g):>7} {100*sum(s['undone'] for s in g)/max(len(g),1):>5.0f}%  | " +
              " ".join(f"{e} {by[e]}/{byu[e]}" for e in ('left', 'right', 'bottom', 'top') if by[e]))
    print("\nContacts that took part in a two-finger frame, by where they started:")
    for lo, hi in [(0, 2), (2, 4), (4, 6), (6, 8), (8, 12), (12, 99)]:
        g = [c for c in allc if c['multi'] and lo <= edge(c['x'], c['y'])[0] < hi]
        by = collections.Counter(edge(c['x'], c['y'])[1] for c in g)
        print(f" {lo:>2}-{hi:<3}mm {len(g):>6}  " + " ".join(f"{e} {by[e]}" for e in ('left', 'right', 'bottom', 'top') if by[e]))
    print("\nContacts that became neither a stroke nor part of a gesture (e.g. too light / too short):")
    for lo, hi in [(0, 2), (2, 4), (4, 6), (6, 8), (8, 99)]:
        g = [c for c in allc if not c['multi'] and not c['stroke'] and lo <= edge(c['x'], c['y'])[0] < hi]
        print(f" {lo:>2}-{hi:<3}mm {len(g):>6}")
