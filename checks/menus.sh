#!/bin/bash
# Menus (background): every item as the app shows it, on a page and in the overview's search field. Text fields get
# Cut / Copy / Paste / Select All; ⌘C on a page copies the page. Prints the menu table.
cd "$(dirname "$0")/.."
APP="${APP:-build/Scrawl.app/Contents/MacOS/TrackpadDraw}"
D=$(mktemp -d /tmp/td-menus.XXXX)
TRACKPAD_DRAW_DATA=$D "$APP" --test-menus --no-activate >/dev/null 2>&1 &
P=$!; for _ in $(seq 1 120); do [ -f "$D/ui-step.txt" ] && break; sleep 0.25; done
kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D" <<'PY'
import json, sys
try: r = json.load(open(sys.argv[1] + "/test-menus.json"))
except Exception as e: print("FAIL no result:", e); print("RESULT: FAIL (1)"); sys.exit(1)
bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
page = {(i["menu"], i["title"]): i for i in r["onPage"]}
srch = {(i["menu"], i["action"]): i for i in r["inSearch"]}
for i in r["onPage"]: print(f"  {i['menu']:6} {i['title']:42} {i['key']:6} {'on ' if i['on'] else '   '}{'' if i['enabled'] else '(dimmed)'}")
edit = lambda act: srch.get(("Edit", act), {})
ei = {e["action"]: e for e in r.get("editItems", [])}
chk(set(ei) == {"cut:", "paste:", "selectAll:"} and all(e["toFirstResponder"] for e in ei.values()) and ei["selectAll:"]["fieldTakesIt"],
    f"Edit has Cut, Paste and Select All, sent to the focused text field ({list(ei.values())})")
fs = [i for i in r["onPage"] if i["action"] == "toggleFullScreen:"]
chk(len(fs) == 1, f"View has one Enter Full Screen (macOS sets its shortcut): {r.get('fullScreenItems')}")
chk(edit("copyPageAction").get("title") == "Copy", "in the search field ⌘C reads Copy (its text), not Copy Page as Image")
chk(r["selectAllHandled"] and r["selected"] == "{0, 11}", f"⌘A in the search field selects its text ({r['selected']})")
chk(page.get(("Edit", "Copy Page as Image"), {}).get("key") == "⌘C" and not page.get(("Edit", "Paste"), {}).get("enabled", True),
    "on a page with nothing on the pasteboard: ⌘C is Copy Page as Image; Paste is dimmed")
chk(r.get("pasteWithImage") is True, "on a page with an image on the pasteboard: Paste is enabled (it puts the picture on the page)")
dupes = {}
for i in r["onPage"]:
    if i["key"]: dupes.setdefault(i["key"], []).append(i["title"])
chk(all(len(v) == 1 for v in dupes.values()), f"no shortcut is used twice: {[v for v in dupes.values() if len(v) > 1]}")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
PY
