#!/bin/sh
# Check 4: kill the app with SIGKILL mid-stroke; the system cursor must still work afterwards.
# If the cursor is ever stuck: open the app again and press ⌃⌥D twice (lock + unlock re-associates it).
cd "$(dirname "$0")/.."
APP="build/Trackpad Draw Predict.app"
open "$APP"; sleep 2
PID=$(pgrep -f "MacOS/TrackpadDraw$" | head -1)
[ -z "$PID" ] && { echo "app did not start"; exit 1; }
echo "During the 8 s countdown: press ⌃⌥D (enters draw mode, cursor disappears),"
echo "then put one finger on the trackpad and keep drawing until the app vanishes."
for i in 8 7 6 5 4 3 2 1 0; do printf "\r%s " $i; sleep 1; done
kill -9 "$PID" && printf "\nkilled %s with SIGKILL\n" "$PID"
sleep 1
tail -1 data/watchdog.log
case "$(tail -1 data/watchdog.log)" in *locked=true*) echo "(draw mode was on at the kill: valid run)";; *) echo "(draw mode was NOT on at the kill: rerun)";; esac
printf "Lift your finger and move the cursor. Does it move and show normally? [y/n] "
read ans
echo "$(date -u +%FT%TZ) kill-test: cursor ok=$ans; $(tail -1 data/watchdog.log)" >> data/checks.log
echo "recorded in data/checks.log"
