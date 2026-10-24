"""Summarize a probe JSONL log: per step, what each width signal does.

Usage: python3 -I analyze.py log.jsonl
"""
import json
import statistics as st
import sys
from collections import defaultdict


def q(vals, p):
    vals = sorted(vals)
    if not vals:
        return float("nan")
    return vals[min(len(vals) - 1, int(p * (len(vals) - 1) + 0.5))]


def rng(vals):
    if not vals:
        return "n/a"
    return f"min {min(vals):.3g} / p50 {q(vals, .5):.3g} / p95 {q(vals, .95):.3g} / max {max(vals):.3g} (n={len(vals)})"


def corr(a, b):
    if len(a) < 3 or st.pstdev(a) == 0 or st.pstdev(b) == 0:
        return float("nan")
    return st.correlation(a, b)


rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
by_step = defaultdict(list)
for r in rows:
    by_step[r["step"]].append(r)

for meta in (r for r in rows if r["src"] in ("meta", "mtdevice")):
    print("meta:", {k: v for k, v in meta.items() if k not in ("t", "step", "down")})

for step, rs in by_step.items():
    if step in ("gap", "idle", "done"):
        continue
    mt = [r for r in rs if r["src"] == "mt" and r.get("f")]
    touch = [f for r in mt for f in r["f"] if f["state"] in (3, 4)]  # MakeTouch/Touching
    if not mt and not any(r["src"] != "mt" for r in rs):
        continue
    print(f"\n## {step}")
    if mt:
        ts = [r["ts"] for r in mt]
        dts = [b - a for a, b in zip(ts, ts[1:]) if 0 < b - a < 0.1]
        if dts:
            print(f"MT frame interval: p50 {q(dts, .5)*1000:.1f} ms (~{1/q(dts, .5):.0f} Hz)")
        for clicked in (False, True):
            fs = [f for r in mt if bool(r.get("btn", r.get("down"))) == clicked for f in r["f"] if f["state"] in (3, 4)]
            if not fs:
                continue
            label = "CLICKED" if clicked else "not clicked"
            print(f"  [{label}] fingers={len(fs)}")
            for k in ("pressure", "total", "density", "major", "minor"):
                print(f"    {k:9s} {rng([f[k] for f in fs])}")
            nz = sum(1 for f in fs if f["pressure"] > 0)
            print(f"    pressure>0 in {nz}/{len(fs)} finger-samples")
        # Are signals independent of each other? (if pressure just tracks contact size, it's not force)
        if touch:
            print(f"  corr(pressure,total)={corr([f['pressure'] for f in touch],[f['total'] for f in touch]):.2f}"
                  f"  corr(total,major)={corr([f['total'] for f in touch],[f['major'] for f in touch]):.2f}")
            speed = [((f['vx']**2 + f['vy']**2) ** .5) for f in touch]
            print(f"  corr(speed,total)={corr(speed,[f['total'] for f in touch]):.2f}"
                  f"  corr(speed,pressure)={corr(speed,[f['pressure'] for f in touch]):.2f}")
        # Per-finger: in multi-finger frames, do fingers report different pressure?
        multi = [r for r in mt if sum(1 for f in r["f"] if f["state"] in (3, 4)) >= 2]
        if multi:
            diffs = []
            for r in multi:
                ps = [f["pressure"] for f in r["f"] if f["state"] in (3, 4)]
                diffs.append(max(ps) - min(ps))
            print(f"  multi-finger frames={len(multi)}; per-frame pressure spread between fingers: {rng(diffs)}")
        # Jitter: spread of absolute position (mm) per held finger
        if step in ("hold_still", "rest_light"):
            per = defaultdict(list)
            for f in touch:
                per[f["id"]].append((f["ax"], f["ay"]))
            for fid, pts in per.items():
                if len(pts) > 20:
                    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
                    print(f"  finger {fid}: raw position spread x {max(xs)-min(xs):.3f} mm, y {max(ys)-min(ys):.3f} mm, sd {st.pstdev(xs):.3f}/{st.pstdev(ys):.3f} mm over {len(pts)} frames")
    pr = [r for r in rs if r["src"] == "pressure"]
    if pr:
        up = [r for r in pr if not r["down"]]
        print(f"NSEvent pressure events={len(pr)} (while mouse NOT down: {len(up)}); p {rng([r['p'] for r in pr])}; stages {sorted(set(r['stage'] for r in pr))}")
    nst = [r for r in rs if r["src"] == "nstouch"]
    if nst:
        ts = [t for r in nst for t in r["touches"]]
        dev = {(t["devW"], t["devH"]) for t in ts}
        print(f"NSTouch events={len(nst)}, touches={len(ts)}, resting={sum(t['resting'] for t in ts)}, deviceSize(pt)={dev}")
    mouse = [r for r in rs if r["src"] == "mouse"]
    if mouse:
        print(f"mouse events: {defaultdict(int, {m['type']: sum(1 for x in mouse if x['type']==m['type']) for m in mouse})}")
