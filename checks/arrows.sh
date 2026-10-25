#!/bin/bash
# Page arrows dim (and do nothing, by click or ⌘[ / ⌘]) when there's no page that way (background).
cd "$(dirname "$0")/.."
APP="build/Scrawl.app/Contents/MacOS/TrackpadDraw"
D=$(mktemp -d /tmp/td-arrows.XXXX)
for ph in write read; do
    rm -f "$D/ui-step.txt"
    TRACKPAD_DRAW_DATA=$D "$APP" --test-arrows $ph >/dev/null 2>&1 &
    P=$!; for _ in $(seq 1 80); do [ -f "$D/ui-step.txt" ] && break; sleep 0.25; done; kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
done
python3 -I - "$D" <<'PY'
import json, sys
d = sys.argv[1]; w = json.load(open(d + "/test-arrows-write.json")); rd = json.load(open(d + "/test-arrows-read.json")); bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
st = {s["at"]: s for s in w["steps"]}
def arrows(s, prev, nxt): return s["prevArrow"] == prev and s["prevMenu"] == prev and s["nextArrow"] == nxt and s["nextMenu"] == nxt
for at, prev, nxt in [("one page", False, False), ("three pages, on the last", True, False), ("middle", True, True), ("first", False, True),
                      ("page 1 opened from the overview", False, True)]:
    s = st[at]; chk(arrows(s, prev, nxt), f"{at} (page {s['page'] + 1} of {s['pages']}): Prev {'on' if prev else 'dimmed'}, Next {'on' if nxt else 'dimmed'} (arrows and ⌘[ / ⌘] menu items agree)")
f = st["first: click Prev, ⌘["]
chk(f["pageAfterPrevClick"] == 0 and f["pageAfterCmdBracket"] == 0, "first page: clicking the dimmed Prev and pressing ⌘[ do nothing")
chk(f["pageAfterCmdCloseBracket"] == 1, "control: ⌘] on the first page goes to page 2")
l = st["last: click Next, ⌘]"]
chk(l["pageAfterNextClick"] == 2 and l["pageAfterCmdCloseBracket"] == 2 and l["pages"] == 3, "last page: clicking the dimmed Next and pressing ⌘] do nothing (no page is added)")
a = rd["atLaunch"]; chk(arrows(a, True, False) and a["page"] == 2 and a["pages"] == 3, f"at launch, notebook open on page {a['page'] + 1} of {a['pages']}: Prev on, Next dimmed")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
PY
