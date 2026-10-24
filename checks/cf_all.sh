#!/bin/bash
# Replay every recorded session with the old and the new behaviour, then compare (see tools/cf_compare.py).
cd "$(dirname "$0")/.."
ARGS=()
for pair in "204529 204514" "211103 211058" "211428 211424" "211645 211644" "212031 212028" "212247 212245"; do
  set -- $pair
  S=data/session-20261024-$1.jsonl; K=data/strokes-20261024-$2.jsonl
  OLD=$(checks/session_cf.sh "$S" 0 0.85 --legacy-edge | tail -1)
  NEW=$(checks/session_cf.sh "$S" 400 0.70 | tail -1)
  ARGS+=("$S" "$K" "$OLD" "$NEW")
done
python3 -I tools/cf_compare.py "${ARGS[@]}"
