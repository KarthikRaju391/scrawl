"""Score the blind rejoin A/B from the test app's data folder (read after the sessions are done).
Each launch logs its hidden condition ("abCondition"); each exported page (page-*.png) belongs to
the session running when it was exported. Per condition: OCR character accuracy of the pangram pages,
and undos + eraser strokes per 100 strokes (the "that landed wrong" signal).
Usage: python3 -I checks/ab_score.py ~/code/trackpad-draw-predict/data"""
import glob, json, os, re, subprocess, sys
from datetime import datetime
d = sys.argv[1]
TEXT = " ".join(["The quick brown fox jumps over the lazy dog"] * 5)
sessions = []
for f in sorted(glob.glob(d + "/strokes-*.jsonl")):
    start = datetime.strptime(re.search(r"strokes-(\d{8}-\d{6})", f).group(1), "%Y%m%d-%H%M%S")
    rows = [json.loads(l) for l in open(f)]
    cond = next((r["rejoin"] for r in rows if r.get("what") == "abCondition"), None)
    if cond is None: continue
    strokes = [r for r in rows if not r.get("kind") and r.get("committed")]
    sessions.append(dict(start=start, cond=cond, strokes=len(strokes), erasers=sum(r["tool"] == "eraser" for r in strokes),
                         undos=sum(r.get("what") == "undo" for r in rows), pages=[]))
for png in sorted(glob.glob(d + "/page-*.png")):
    t = datetime.strptime(re.search(r"page-(\d{8}-\d{6})", png).group(1), "%Y%m%d-%H%M%S")
    owner = [s for s in sessions if s["start"] <= t]
    if owner: owner[-1]["pages"].append(png)
ocr_bin = os.path.join(os.path.dirname(__file__), "..", "build", "ocr_text")
for cond in ("off", "on"):
    ss = [s for s in sessions if s["cond"] == cond]
    accs = []
    for s in ss:
        for p in s["pages"]:
            out = subprocess.run([ocr_bin, p, TEXT], capture_output=True, text=True).stdout
            m = re.search(r"OFF: character accuracy ([\d.]+)%", out)
            if m: accs.append(float(m.group(1)))
    n = sum(s["strokes"] for s in ss) or 1
    fix = sum(s["undos"] + s["erasers"] for s in ss)
    print(f"rejoin {cond:3s}: sessions {len(ss)}, pages {len(accs)}, OCR mean {sum(accs)/len(accs) if accs else float('nan'):.1f}% {accs}, "
          f"undos+erasers per 100 strokes {100*fix/n:.1f}")
