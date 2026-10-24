#!/bin/bash
# The cursor always comes back (background; dry-run lock: every step runs except the CG cursor calls,
# so the Mac's real cursor is never taken). Reads the watchdog log for each way draw mode can end.
cd "$(dirname "$0")/.."
APP="build/Scrawl.app/Contents/MacOS/TrackpadDraw"
BAD=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; BAD=$((BAD + 1)); }
waitfile() { for _ in $(seq 1 60); do [ -f "$1" ] && return 0; sleep 0.25; done; return 1; }
gone() { for _ in $(seq 1 40); do kill -0 $1 2>/dev/null || return 0; sleep 0.25; done; return 1; }

run() {  # run <how> <expect: "restored:<reason>" | "watchdog:<locked>">
    local how=$1 want=$2 D; D=$(mktemp -d /tmp/td-cursor.XXXX)
    TRACKPAD_DRAW_DRYLOCK=1 TRACKPAD_DRAW_DATA=$D "$APP" --test-cursor $how >/dev/null 2>&1 &
    local P=$!
    if ! waitfile "$D/locked.json" || ! grep -q '"locked":true' "$D/locked.json"; then fail "$how: draw mode never locked"; kill -9 $P; return; fi
    case $how in
        kill) kill -9 $P ;;
        term) kill -TERM $P ;;
        crash|quit) ;;
        *) waitfile "$D/after.json"; kill -TERM $P ;;
    esac
    gone $P || { kill -9 $P; fail "$how: app did not exit"; return; }
    # The watchdog notices the exit and logs it.
    for _ in $(seq 1 20); do grep -q "exited" "$D/watchdog.log" 2>/dev/null && break; sleep 0.25; done
    local wd; wd=$(pgrep -f -- "--watchdog $P$")
    [ -n "$wd" ] && { kill $wd; fail "$how: watchdog still running"; }
    local log; log=$(grep -v "watching" "$D/watchdog.log" | sed -E 's/^[^ ]+ //' | tr '\n' '|')
    case $want in
        restored:*)
            local r=${want#restored:}
            if grep -q "cursor restored: $r" "$D/watchdog.log" && grep -q "locked=false" "$D/watchdog.log" \
               && { [ ! -f "$D/after.json" ] || grep -q '"locked":false' "$D/after.json"; }; then
                pass "$how: app restored the cursor itself ($r), watchdog saw it unlocked"
            else fail "$how: $log"; fi ;;
        watchdog)
            if grep -q "exited (locked=true); re-associated mouse and showed cursor" "$D/watchdog.log"; then
                pass "$how: app died while locked, watchdog restored the cursor"
            else fail "$how: $log"; fi ;;
    esac
}

run kill watchdog
run crash watchdog
run term "restored:SIGTERM"
run quit "restored:quit"
run esc "restored:Esc"
run sleep "restored:display sleep"
run systemsleep "restored:system sleep"
run session "restored:user switched"
run screens "restored:displays changed"

# Without the dry-run flag the test refuses to lock at all.
D=$(mktemp -d /tmp/td-cursor.XXXX)
TRACKPAD_DRAW_DATA=$D "$APP" --test-cursor kill >/dev/null 2>&1 &
P=$!; waitfile "$D/refused-not-dry.json"; kill -TERM $P; gone $P
if [ -f "$D/refused-not-dry.json" ] && ! grep -q "cursor locked" "$D/watchdog.log" 2>/dev/null; then pass "without TRACKPAD_DRAW_DRYLOCK the test refuses to lock the real cursor"; else fail "test locked without dry run"; fi
sleep 2; dlg=$(build/crashdialogs --close)
[ -z "$dlg" ] && pass "no crash dialog left on screen by the test crash" || fail "test crash opened a crash dialog (closed it: pid $dlg)"
echo "RESULT: $([ $BAD = 0 ] && echo PASS || echo "FAIL ($BAD)")"
