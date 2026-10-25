#!/bin/bash
# Modes and tools: every key, toolbar button and menu item from every state follows one rule set (background).
cd "$(dirname "$0")/.."
D=$(mktemp -d /tmp/td-modes.XXXX)
TRACKPAD_DRAW_DATA=$D "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-modes >/dev/null 2>&1 &
P=$!; sleep 1; WID=$(build/winid $P)
for _ in $(seq 1 600); do
    [ -f "$D/ui-step.txt" ] && break
    for q in "$D"/shot-*.req; do [ -e "$q" ] || continue; n=$(basename "$q" .req); sleep 0.3; screencapture -x -o -l"$WID" "$D/$n.png"; mv "$q" "$D/$n.taken"; touch "$D/$n.done"; done
    sleep 0.05
done
kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D/test-modes.json" <<'PY'
import json, sys, collections
r = json.load(open(sys.argv[1])); bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
f = r["failures"]
by = collections.Counter(x["input"] for x in f)
chk(not f, f"state x input matrix: {r['cases'] - len(f)}/{r['cases']} cases follow the rules (32 states x keys, toolbar buttons, menu items)")
for name, n in by.most_common():
    ex = next(x for x in f if x["input"] == name)
    why = "opened a panel" if ex["panelOpened"] else ("toolbar out of sync" if not ex["toolbarShowsIt"] else "")
    print(f"   {name}: {n} cases wrong, e.g. from {ex['from']} want {ex['want']} got {ex['got']} {why}")
chk(not r["missingMenus"], f"menu items for every mode (missing: {r['missingMenus']})")
w, t = r["writingPanel"], r["toolPanel"]
chk(w["opened"] and w["stillWriting"], "secondary click on the writing button opens its settings without turning writing off")
chk(t["opened"] and t["stillEraser"], "secondary click on the selected tool opens its sizes / colours without switching tool")
print("screenshots:", sys.argv[1].rsplit("/",1)[0])
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
PY
