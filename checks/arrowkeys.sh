#!/bin/bash
# Arrow keys: pan the canvas; move a selection in the pages overview (background).
cd "$(dirname "$0")/.."
D=$(mktemp -d /tmp/td-arrowk.XXXX)
TRACKPAD_DRAW_DATA=$D "build/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-arrowkeys >/dev/null 2>&1 &
P=$!; for _ in $(seq 1 120); do [ -f "$D/ui-step.txt" ] && break; sleep 0.25; done; kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
python3 -I - "$D/test-arrowkeys.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
def near(a, b, tol=0.5): return abs(a - b) < tol
for p in r["pans"]:
    tag = f"{p['shape']}, zoom {p['zoom']:.0f}, lock {'on' if p['locked'] else 'off'}"
    w, h = p["start"][2], p["start"][3]
    (b, a) = p["right"]; dx = a[0] - b[0]
    (b2, a2) = p["down"]; dy = b2[1] - a2[1]
    (b3, a3) = p["up"]; uy = a3[1] - b3[1]
    (b4, a4) = p["left"]; lx = b4[0] - a4[0]
    (b5, a5) = p["shift-right"]; sx = a5[0] - b5[0]
    (b6, a6) = p["shift-down"]; sy = b6[1] - a6[1]
    reach = p.get("reach", 0) * p["pageWidth"]   # 0.1.6: the view goes this far past the page's sides and top
    if p["zoom"] == 1 and reach == 0:
        ok = near(dx, 0) and near(lx, 0) and near(sx, 0) and near(dy, 0.1 * h) and near(uy, 0.1 * h) and near(sy, h)
        what = f"← → do nothing (the page fits), ↓ ↑ {dy:.0f} units (10% of {h:.0f}), Shift+↓ {sy:.0f} (one view)"
    else:
        ok = near(dx, 0.1 * w) and near(lx, 0.1 * w) and near(dy, 0.1 * h) and near(uy, 0.1 * h) and near(sx, w) and near(sy, h)
        what = f"→ ← {dx:.0f} units (10% of {w:.0f}), ↓ ↑ {dy:.0f}, Shift+→ {sx:.0f}, Shift+↓ {sy:.0f} (one view)"
    if reach == 0:
        clamp = near(p["topAfterUps"], p["pageTop"]) and near(p["leftAfterLefts"], 0) and near(p["rightAfterRights"], p["pageWidth"])
        where = "stops at the page top and sides"
    else:   # the view's centre stops `reach` past the page's sides and top
        clamp = near(p["topAfterUps"], p["pageTop"] + reach + h / 2) and near(p["leftAfterLefts"], -reach - w / 2) and near(p["rightAfterRights"], p["pageWidth"] + reach + w / 2)
        where = f"stops {reach:.0f} units past the page's top and sides (the canvas's reach)"
    clamp = clamp and near(p["zoomAfter"], p["zoom"], 1e-6)
    chk(ok and clamp, f"{tag}: {what}; {where}; zoom unchanged")
d = r["drawWriting"]
chk(d["moved"] and d["newLines"] == 0 and d["page"] == d["page0"] and d["pages"] == d["pages0"] and d["drawMode"], "draw mode + writing mode: arrows pan; no new line, no page change")
t = r["textField"]
chk(t["focusedField"] and not t["viewMoved"] and not t["drawMode"], "a text field with focus gets arrows and letters (the canvas doesn't pan, D doesn't toggle draw mode)")
g = r["gallery"]; cols, cells = g["columns"], g["cells"]
chk(cells == 42 and g["startSelected"] == 2, f"overview: selection starts on the current page (3); {cells} tiles in {cols} columns")
chk(g["leftFromFirst"] == 0 and g["upFromFirstRow"] == 0, "← and ↑ on the first tile stay put (no wrap)")
chk(g["rightFromFirst"] == 1 and g["downFromFirst"] == 1 + cols, f"→ moves to the next page, ↓ by a row ({cols})")
chk(g["rightFromLast"] == cells - 1 and g["downFromLast"] == cells - 1, "→ and ↓ on the last tile stay put")
chk(g["downIntoPartialRow"] == g["lastCell"], f"↓ into the partial last row from a column past its end goes to the last tile ({g['downIntoPartialRow']})")
chk(g["rowEndRight"] == cols, "→ at the end of a row continues on the next row")
chk(g["selectedVisible"], f"the selection scrolls into view (tile {g['selectedAfterDowns'] + 1} visible)")
rt = g["return"]
chk(rt["page"] == 9 and rt["galleryHidden"] and all(abs(a - b) < 0.5 for a, b in zip(rt["from"], rt["want"])) and len(rt["from"]) == 4,
    "Return opens the selected page (10), growing from its tile")
chk(g["startSelectedSecondOpen"] == 9 and g["space"]["page"] == g["twoRight"], f"reopened: selection on the current page (10); → → then Space opens the tile two along (page {g['twoRight'] + 1})")
chk(g["newTileSelected"] and g["newPage"]["pages"] == g["pagesBeforeReturn"] + 1 and g["newPage"]["page"] == g["pagesBeforeReturn"],
    "\"+ New page\" can be selected; Return on it adds the page and opens it")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
PY
