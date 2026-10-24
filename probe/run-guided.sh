#!/bin/sh
# One-minute guided probe. Builds, opens the probe window, then writes the log + summary to data/.
set -e
cd "$(dirname "$0")"
./build.sh
ts=$(date +%Y%m%d-%H%M%S)
./probe-bin "../data/guided-$ts.jsonl"
python3 -I analyze.py "../data/guided-$ts.jsonl" | tee "../data/guided-$ts.txt"
