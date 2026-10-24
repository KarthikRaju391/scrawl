"""Edge guard off vs on, replaying Karthik's recorded sessions (same touches, virtual clock = recorded time).
Usage: edge_compare.py <orig session> <orig strokes> <guard-off dir> <guard-on dir> [more groups of 4...]
Strokes are matched by touch-down time. A stroke the guard removes counts as stray if Karthik undid it
in the recording, and as a real stroke lost if he kept it. Two-finger gestures (pinch/pan view
changes, grouped by 150 ms gaps) are counted per run."""
import json, sys, glob, os
# cf_compare.py runs its comparison when imported; take just its helpers (load, strokes_log, timeline).
_src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cf_compare.py')).read()
exec(_src[:_src.index('\ngroups = ')])

def run(d):
    sess = load(glob.glob(d + '/session-*.jsonl')[0])
    begins, out, cur = [], [], None
    for r in sess:
        if r['k'] != 'act': continue
        if r['a'] == 'strokeBegin': cur = r['m']
        elif r['a'] == 'strokeEnd' and cur is not None:
            if r.get('committed'): out.append(cur)
            cur = None
    nav, last = [], None
    for r in sess:
        if r['k'] == 'view' and r.get('src') == 'pinch':
            if last is None or r['m'] - last > 0.15: nav.append([r['m'], r['m']])
            else: nav[-1][1] = r['m']
            last = r['m']
    return out, nav

def near(m, xs, tol=0.03): return any(abs(m - x) < tol for x in xs)

tot = dict(s0=0, s1=0, removed=0, stray=0, lost=0, added=0, n0=0, n1=0, undos=0)
args = sys.argv[1:]
for sp, kp, d0, d1 in zip(args[0::4], args[1::4], args[2::4], args[3::4]):
    orig, _ = timeline(load(sp), strokes_log(kp))
    undone = [s['m'] for s in orig if s['committed'] and s['undone']]
    kept = [s['m'] for s in orig if s['committed'] and not s['undone']]
    s0, n0 = run(d0); s1, n1 = run(d1)
    removed = [m for m in s0 if not near(m, s1)]
    added = [m for m in s1 if not near(m, s0)]
    stray = [m for m in removed if near(m, undone)]
    lost = [m for m in removed if near(m, kept)]
    t = dict(s0=len(s0), s1=len(s1), removed=len(removed), stray=len(stray), lost=len(lost), added=len(added), n0=len(n0), n1=len(n1), undos=len(undone))
    for k in tot: tot[k] += t[k]
    print(f"{os.path.basename(sp)}: strokes {t['s0']} -> {t['s1']} (removed {t['removed']}: {t['stray']} were undone in the recording, "
          f"{t['lost']} were kept; {t['added']} new) | two-finger gestures {t['n0']} -> {t['n1']}")
t = tot
print(f"\nALL: strokes {t['s0']} -> {t['s1']}; removed {t['removed']} = {t['stray']} stray (undone in the recording) + {t['lost']} real strokes lost "
      f"+ {t['removed'] - t['stray'] - t['lost']} unmatched; {t['added']} strokes now drawn that a resting edge touch had turned into a gesture; "
      f"two-finger gestures {t['n0']} -> {t['n1']} ({t['n0'] - t['n1']} removed); undos in the recordings {t['undos']}, "
      f"of which {t['stray']} were for strokes the guard now never draws")
