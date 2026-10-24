#!/bin/sh
# Analyse recorded sessions and render a replay clip around every undo.
# Usage: checks/session_report.sh [data dir]   (default: ~/code/trackpad-draw/data)
cd "$(dirname "$0")/.."
DIR=${1:-$HOME/code/trackpad-draw/data}
OUT=$DIR/reports; mkdir -p "$OUT"
swiftc -O -o build/replay tools/replay.swift 2>/dev/null
for S in "$DIR"/session-*.jsonl; do
  # the stroke log started just before the session file (same launch)
  K=$(ls "$DIR"/strokes-*.jsonl | awk -v s="$(basename "$S" | sed 's/session-//')" '{ split($0, p, "strokes-"); if (p[2] <= s) last = $0 } END { print last }')
  NAME=$(basename "$S" .jsonl)
  echo "== $NAME (strokes: $(basename "$K"))"
  python3 -I tools/session_analysis.py "$S" "$K"
  build/replay "$S" "$K" "$OUT/$NAME" --undos --fps 15 | tail -1
done
echo "clips in $OUT"
