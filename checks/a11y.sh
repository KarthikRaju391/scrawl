#!/bin/bash
# VoiceOver and the toolbar (background): every button is an accessibility element with a name, a role, help, a
# frame over the button, and a press that does what a click does.
cd "$(dirname "$0")/.."
APP="${APP:-build/Scrawl.app/Contents/MacOS/TrackpadDraw}"
D=$(mktemp -d /tmp/td-a11y.XXXX)
TRACKPAD_DRAW_DATA=$D "$APP" --test-a11y --no-activate >/dev/null 2>&1 &
P=$!; for _ in $(seq 1 120); do [ -f "$D/ui-step.txt" ] && break; sleep 0.25; done
kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D" <<'PY'
import json, sys
try: r = json.load(open(sys.argv[1] + "/test-a11y.json"))
except Exception as e: print("FAIL no result:", e); print("RESULT: FAIL (1)"); sys.exit(1)
bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
E = r.get("elements") or []
labels = [e["label"] for e in E]
chk(len(E) == 16, f"VoiceOver finds 16 toolbar buttons: {labels}")
chk(len(set(labels)) == len(E) and all(labels), "each has its own name")
chk(all(e["help"] for e in E), "each has help (the tooltip, with its shortcut)")
toggles = {"Draw", "Pen", "Marker", "Highlighter", "Eraser", "Writing mode", "Zoom lock"}
chk(all((e["role"] == "AXCheckBox") == (e["label"] in toggles) for e in E) and all(e["role"] in ("AXCheckBox", "AXButton") for e in E),
    "buttons that toggle are checkboxes (on / off), the rest buttons")
chk([e["label"] for e in E if e["role"] == "AXCheckBox" and e["value"] == 1] == ["Pen"], "at launch only the pen is on")
wx, wy, ww, wh = r["window"]
fr = [e["frame"] for e in E]
inside = all(x >= wx and y >= wy and x + w <= wx + ww and y + h <= wy + wh and w > 20 and h > 20 for x, y, w, h in fr)
apart = all(fr[i][0] + fr[i][2] <= fr[i + 1][0] + 0.5 for i in range(len(fr) - 1))
chk(inside and apart, "each sits over its button, inside the window, left to right")
chk(not r["toolbarIsElement"] and r["toolbarRole"] == "AXToolbar", "the toolbar itself is a toolbar group, not one blank element")
p = r["presses"]
chk(p["prevOnFirstPage"] is False and [e["enabled"] for e in E if e["label"] == "Previous page"] == [False], "Previous page is dimmed on the first page; pressing it does nothing")
chk(p["writingOn"] and p["writingValue"] == 1 and p["writingOffAgain"], "pressing Writing mode turns it on (and reads as on), again turns it off")
chk(p["newPage"] == 2, "pressing New page adds a page")
chk(p["eraserAndDraw"], "pressing Eraser picks it and turns draw mode on, like a click")
chk(p["childrenInDrawMode"] == 0 and p["childrenAfter"] == 16, "in draw mode (toolbar hidden) there's nothing to reach; after, all 16 again")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
PY
