#!/bin/bash
# Page dates (background): created/edited dates, restart, old notebooks, the overview tiles and the open
# page's label. Saves screenshots of both.
cd "$(dirname "$0")/.."
APP="build/Scrawl.app/Contents/MacOS/TrackpadDraw"
run() {  # run <dir> <phase>
    local D=$1 ph=$2; rm -f "$D/ui-step.txt"
    TRACKPAD_DRAW_DATA=$D "$APP" --test-meta $ph >/dev/null 2>&1 &
    local P=$!; sleep 1; local WID; WID=$(build/winid $P)
    for _ in $(seq 1 300); do
        [ -f "$D/ui-step.txt" ] && break
        for q in "$D"/shot-*.req; do [ -e "$q" ] || continue; n=$(basename "$q" .req); sleep 0.3; screencapture -x -o -l"$WID" "$D/$n.png"; mv "$q" "$D/$n.taken"; touch "$D/$n.done"; done
        sleep 0.05
    done
    kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
}
D=$(mktemp -d /tmp/td-meta.XXXX); run "$D" write; run "$D" read
O=$(mktemp -d /tmp/td-metaold.XXXX); run "$O" makeold; mv "$O/old.tdnb" "$O/Notebook.tdnb"; rm -f "$O/test-meta-makeold.json"; run "$O" readold
python3 -I - "$D" "$O" <<'PY'
import json, sys, datetime
d, o = sys.argv[1], sys.argv[2]
w = json.load(open(d + "/test-meta-write.json")); rd = json.load(open(d + "/test-meta-read.json")); old = json.load(open(o + "/test-meta-readold.json")); bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
p1 = w["page1AtLaunch"]
chk(abs(p1["created"] - p1["wallClock"]) < 30, "the first page of a new notebook gets created = now")
b, a = w["beforeStroke"], w["dates"]
chk(b[1]["created"] == 1_792_400_000 and b[2]["created"] == 1_792_600_000, "new pages get the date they were made")
chk(a[0]["created"] == b[0]["created"] and a[0]["edited"] == 1_792_800_000 and b[0]["edited"] != 1_792_800_000 and a[1] == b[1] and a[2] == b[2],
    "a stroke on page 1 moves its edited date (to Oct 24) and leaves its created date and the other pages alone")
chk(rd["dates"] == a, "after a restart: every page's created and edited dates are the same")
def fmt(t):   # the system's medium date in the local time zone, as Python's macOS locale would render it isn't reliable: compare app vs app
    return t
L, R = w["labels"], rd["labels"]
chk(L == R, "after a restart: the overview tiles and the open page's label read the same")
chk(all(f"Page {i + 1}  ·  " in t for i, t in enumerate(L["tiles"])) and L["tiles"][1].endswith(L["hints"][1].split("created ")[1].split("  ·")[0]),
    f"tiles show the created date: {L['tiles']}")
chk(all("created " in h for h in L["hints"]) and "date unknown" not in " ".join(L["hints"]), f"the open page's label shows its created date: \"{L['hints'][1]}\"")
chk(old["load"].startswith("loaded 2") and [x["strokes"] for x in old["dates"]] == [2, 1] and all(x["created"] == -1 and x["edited"] == -1 for x in old["dates"])
    and all("date unknown" in t for t in old["labels"]["tiles"]) and all("created date unknown" in h for h in old["labels"]["hints"]),
    f"an old notebook (no dates) opens with all pages and strokes; tiles and label say \"date unknown\" ({old['labels']['tiles']})")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
print("screenshots:", d)
PY
