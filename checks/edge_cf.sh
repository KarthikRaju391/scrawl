#!/bin/bash
# Edge guard off vs on (5%) over Karthik's recorded sessions (see tools/edge_compare.py).
cd "$(dirname "$0")/.."
ARGS=()
for pair in "204529 204514" "211103 211058" "211428 211424" "211645 211644" "212031 212028" "212247 212245"; do
  set -- $pair
  S=data/session-20261024-$1.jsonl; K=data/strokes-20261024-$2.jsonl
  OFF=$(checks/session_cf.sh "$S" 400 0.70 --edge-guard 0 | tail -1)
  ON=$(checks/session_cf.sh "$S" 400 0.70 --edge-guard 0.05 | tail -1)
  ARGS+=("$S" "$K" "$OFF" "$ON")
done
python3 -I tools/edge_compare.py "${ARGS[@]}"
