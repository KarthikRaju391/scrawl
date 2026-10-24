"""Check 2 (latency), software part + video arithmetic.

Software: python3 -I latency_report.py data/strokes-*.jsonl
  Time from a trackpad frame reaching the app (MultitouchSupport callback) to the frame showing it
  being presented on the display (Metal presentedTime). Excludes the touch sensor + driver before
  the callback, and the panel's pixel response after presentation; the 240 fps video measures those.

Video: python3 -I latency_report.py --frames 11 12 10 ...  (frame counts at 240 fps, one per trial)
"""
import json
import statistics as st
import sys

if len(sys.argv) > 2 and sys.argv[1] == "--frames":
    n = [float(x) for x in sys.argv[2:]]
    ms = [x * 1000 / 240 for x in n]
    print(f"{len(ms)} trials: mean {st.mean(ms):.1f} ms, median {st.median(ms):.1f} ms, min {min(ms):.1f}, max {max(ms):.1f} "
          f"(±4.2 ms per trial from frame quantization) -> {'PASS' if st.mean(ms) < 50 else 'FAIL'} (target < ~50 ms)")
    sys.exit()

lat = []
for path in sys.argv[1:]:
    for line in open(path):
        lat += json.loads(line).get("latencyMs", [])
if not lat:
    print("no latency samples (draw some strokes in draw mode first)")
else:
    lat.sort()
    q = lambda p: lat[min(len(lat) - 1, int(p * (len(lat) - 1)))]
    print(f"app input -> photons-out-of-GPU (presentedTime): n={len(lat)}, p50 {q(.5):.1f} ms, p95 {q(.95):.1f} ms, max {lat[-1]:.1f} ms")
