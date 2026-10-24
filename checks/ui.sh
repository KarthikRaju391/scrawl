#!/bin/sh
# Toolbar/panel/background walk-through with real NSEvent clicks; one screenshot per step.
cd "$(dirname "$0")/.."
OUT=$(mktemp -d /tmp/td-ui.XXXX)
TRACKPAD_DRAW_DATA=$OUT "build/Trackpad Draw.app/Contents/MacOS/TrackpadDraw" --test-ui >/dev/null 2>&1 &
PID=$!
sleep 1; WID=$(build/winid $PID)
last=""
for i in $(seq 1 120); do
  s=$(cat "$OUT/ui-step.txt" 2>/dev/null)
  if [ -n "$s" ] && [ "$s" != "$last" ]; then
    [ "$s" = done ] && break
    sleep 0.9; screencapture -x -o -l"$WID" "$OUT/$s.png"; echo "captured $s"; last=$s
  fi
  sleep 0.2
done
kill -TERM $PID
echo "$OUT"
