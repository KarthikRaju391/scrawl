#!/bin/bash
# Pages survive crashes, kill -9 and quitting (background, scratch data folders). PASS/FAIL per case.
cd "$(dirname "$0")/.."
APP="build/Scrawl.app/Contents/MacOS/TrackpadDraw"
BAD=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; BAD=$((BAD + 1)); }
waitfile() { for _ in $(seq 1 ${3:-80}); do [ -f "$1/$2" ] && return 0; sleep 0.25; done; return 1; }
reopen() {  # reopen the notebook in $1, wait for the report
    rm -f "$1/ui-step.txt" "$1/actual.json"
    TRACKPAD_DRAW_DATA=$1 "$APP" --test-persist read >/dev/null 2>&1 &
    local p=$!; waitfile "$1" ui-step.txt; kill -TERM $p 2>/dev/null; wait $p 2>/dev/null
}
same() {  # expected vs actual summary in $1: identical notebook (sha of every page, stroke, view, history)
    python3 -I - "$1" <<'PY'
import json, sys
d = sys.argv[1]
e, a = json.load(open(d + "/expected.json")), json.load(open(d + "/actual.json"))
ok = e["sha256"] == a["sha256"]
print(f"{'identical' if ok else 'DIFFERENT'}: pages {[(p['strokes'], p['undo'], p['redo'], p['zoom']) for p in a['pages']]}, "
      f"{a['strokeTable']} strokes, {a['points']} points; load: {a.get('loadStatus')}")
sys.exit(0 if ok else 1)
PY
}

pngsame() {  # same picture (anti-aliasing may differ by 1/255) and there is ink on it
    python3 -I - "$1" "$2" <<'PY'
import sys
from PIL import Image
a, b = (Image.open(p).convert("RGB") for p in sys.argv[1:3])
pa, pb = a.tobytes(), b.tobytes()
bg = pa[0:3]
ink = sum(1 for i in range(0, len(pa), 3) if max(abs(pa[i + k] - bg[k]) for k in range(3)) > 24)
off = sum(1 for i in range(len(pa)) if abs(pa[i] - pb[i]) > 8)
print(f"{ink} ink pixels, {off} channel values off by more than 8/255")
sys.exit(0 if a.size == b.size and ink > 500 and off == 0 else 1)
PY
}

# 1, 2) Mid-stroke kill -9, and a real crash mid-stroke.
for how in kill crash; do
    D=$(mktemp -d /tmp/td-persist.XXXX)
    if [ $how = crash ]; then
        TRACKPAD_DRAW_DATA=$D "$APP" --test-persist write --crash >/dev/null 2>&1 &
        P=$!; waitfile "$D" midstroke.json
        for _ in $(seq 1 40); do kill -0 $P 2>/dev/null || break; sleep 0.25; done
        kill -9 $P 2>/dev/null; wait $P 2>/dev/null; code=$?
        why="crashed (exit $code) mid-stroke"
    else
        TRACKPAD_DRAW_DATA=$D "$APP" --test-persist write >/dev/null 2>&1 &
        P=$!; waitfile "$D" midstroke.json; sleep 0.3; kill -9 $P; wait $P 2>/dev/null
        why="kill -9 mid-stroke"
    fi
    inflight=$(python3 -c "import json;print(json.load(open('$D/midstroke.json'))['inFlightPoints'])" 2>/dev/null)
    reopen "$D"
    if r=$(same "$D"); then pass "$why ($inflight points of ink in flight): reopened $r"; else fail "$why: $r"; fi
    if r=$(pngsame "$D/before.png" "$D/after.png"); then pass "  $how: reopened page renders the same as before the $how ($r)"; else fail "  $how: page renders differently after reopening ($r)"; fi
done

# 3) Quit right after a stroke: the quit itself saves (no autosave had time to run).
D=$(mktemp -d /tmp/td-persist.XXXX)
TRACKPAD_DRAW_DATA=$D "$APP" --test-persist write --quit >/dev/null 2>&1 &
P=$!; for _ in $(seq 1 80); do kill -0 $P 2>/dev/null || break; sleep 0.25; done
kill -9 $P 2>/dev/null; wait $P 2>/dev/null
reopen "$D"
if r=$(same "$D"); then pass "quit straight after a stroke: reopened $r"; else fail "quit straight after a stroke: $r"; fi

# 4) Writing continuously, kill -9 at a random moment: only the last half second can be lost.
for run in 1 2 3; do
    D=$(mktemp -d /tmp/td-persist.XXXX)
    TRACKPAD_DRAW_DATA=$D "$APP" --test-persist stream >/dev/null 2>&1 &
    P=$!; waitfile "$D" commits.log; sleep "$(python3 -c 'import random;print(round(random.uniform(2.5,5),2))')"
    KT=$(python3 -c 'import time;print(time.time())'); kill -9 $P; wait $P 2>/dev/null
    reopen "$D"
    out=$(python3 -I - "$D" "$KT" <<'PY'
import json, sys
d, kt = sys.argv[1], float(sys.argv[2])
commits = [l.split() for l in open(d + "/commits.log") if l.strip()]
got = json.load(open(d + "/actual.json"))["pages"][0]["strokes"]
safe = max([int(c[2]) for c in commits if float(c[1]) < kt - 0.6] or [0])   # committed > 0.6 s before the kill
total = int(commits[-1][2])
lost_s = kt - max([float(c[1]) for c in commits if int(c[2]) <= got] or [kt])
print(f"{got}/{total} strokes reopened, {total - got} lost (newest kept stroke {lost_s:.2f} s before the kill)")
sys.exit(0 if got >= safe and got <= total else 1)
PY
)
    if [ $? = 0 ]; then pass "writing, kill -9 at a random moment (run $run): $out"; else fail "writing, kill -9 (run $run): $out"; fi
done

# 5) kill -9 while a 12 MB notebook is being written, 8 times: the file is never half-written.
D=$(mktemp -d /tmp/td-persist.XXXX); okn=0
TRACKPAD_DRAW_DATA=$D "$APP" --test-persist bigsave >/dev/null 2>&1 &
P=$!; waitfile "$D" bigsave-ready.txt 120; kill -9 $P; wait $P 2>/dev/null
for k in $(seq 1 8); do
    TRACKPAD_DRAW_DATA=$D "$APP" --test-persist bigsave >/dev/null 2>&1 &
    P=$!; waitfile "$D" bigsave-ready.txt 120; rm -f "$D/bigsave-ready.txt"
    sleep "$(python3 -c 'import random;print(round(random.uniform(0.05,0.6),3))')"; kill -9 $P; wait $P 2>/dev/null
    reopen "$D"; same "$D" >/dev/null && okn=$((okn + 1))
done
[ $okn = 8 ] && pass "kill -9 during repeated 12 MB saves: notebook intact on all $okn/8 reopenings" || fail "kill -9 during saves: intact $okn/8"

# 6) An unreadable notebook is kept aside, never overwritten; the app starts with a fresh one.
D=$(mktemp -d /tmp/td-persist.XXXX); head -c 5000 /dev/urandom > "$D/Notebook.tdnb"
reopen "$D"
if ls "$D"/Notebook-unreadable-*.tdnb >/dev/null 2>&1 && grep -q unreadable "$D/actual.json"; then pass "unreadable notebook: kept aside as $(basename "$D"/Notebook-unreadable-*.tdnb), app opened a fresh one"; else fail "unreadable notebook not kept aside"; fi

sleep 2; dlg=$(build/crashdialogs --close)
[ -z "$dlg" ] && pass "no crash dialog left on screen by the test crash" || fail "test crash opened a crash dialog (closed it: pid $dlg)"
echo "RESULT: $([ $BAD = 0 ] && echo PASS || echo "FAIL ($BAD)")"
