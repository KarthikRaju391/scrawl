#!/bin/bash
# The Select tool: the bench's selection checks (the rectangle through the real input path under pan, zoom and a pinch;
# Copy's PNG/PDF/SVG against the canvas's render; Export Selection; clearing; never an edit), then the tool in the app
# (background, dry pointer lock): S, a finger drag, the bar, ⌘C, Esc, a pointer drag, the bar's Copy and Export…, the
# sheet on Selection, Esc / another tool / another page clearing it. Screenshots go to $OUT.
cd "$(dirname "$0")/.."
APP="${APP:-build/Scrawl.app/Contents/MacOS/TrackpadDraw}"
bad=0
if [ -z "$ALLOW_STALE" ] && [ -n "$(find app -name '*.swift' -newer "$APP" | head -1)" ]; then echo "FAIL $APP is older than app/ (build first)"; echo "RESULT: FAIL"; exit 1; fi
if [ -x build/bench ] && [ -z "$NO_BENCH" ]; then
    BENCH_ONLY=export build/bench | sed -n '/a one-finger drag with Select/,$p' | tee /tmp/td-select-bench.$$ | grep -E "^(PASS|FAIL)"
    grep -q "^FAIL" /tmp/td-select-bench.$$ && bad=1; [ -s /tmp/td-select-bench.$$ ] || { echo "FAIL no selection checks in the bench"; bad=1; }; rm -f /tmp/td-select-bench.$$
fi
D=$(mktemp -d /tmp/td-select.XXXX); OUT="${OUT:-$D}"
TRACKPAD_DRAW_DRYLOCK=1 TRACKPAD_DRAW_DATA=$D "$APP" --test-select --no-activate >/dev/null 2>&1 &
P=$!; sleep 1
for _ in $(seq 1 400); do
    [ "$(cat "$D/ui-step.txt" 2>/dev/null)" = done ] && break
    for q in "$D"/shot-*.req; do
        [ -e "$q" ] || continue
        n=$(basename "$q" .req); sleep 0.2
        build/winid $P all > "$D/$n.windows"
        # The largest window (the main one, with any sheet over it).
        id=$(sort -k4,4n -k5,5n "$D/$n.windows" | tail -1 | cut -d' ' -f1); [ -n "$id" ] && screencapture -x -o -l"$id" "$D/$n.png"
        mv "$q" "$D/$n.taken"; touch "$D/$n.done"
    done
    sleep 0.1
done
kill -TERM $P 2>/dev/null; for _ in $(seq 1 20); do kill -0 $P 2>/dev/null || break; sleep 0.25; done; kill -9 $P 2>/dev/null; wait $P 2>/dev/null
dlg=$(build/crashdialogs --close); [ -n "$dlg" ] && echo "FAIL the test left a crash dialog (closed it: pid $dlg)" && bad=1
python3 -I - "$D" "$OUT" <<'PY'
import json, sys, os, shutil
d, out = sys.argv[1], sys.argv[2]
try: r = json.load(open(d + "/test-select.json"))
except Exception as e: print("FAIL no result:", e); print("RESULT: FAIL (1)"); sys.exit(1)
bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
if "refused" in r: chk(False, r["refused"]); print("RESULT: FAIL"); sys.exit(1)
near = lambda a, b, t=0.05: len(a) == len(b) == 4 and all(abs(x - y) < t for x, y in zip(a, b))
m = r["menu"]
chk(m["select"] == "Select  (S)" and m["exportSelection"] == "Export Selection…" and m["exportSelectionKey"].endswith("-e") and not m["exportSelectionEnabledWithout"]
    and m["copyTitleWithout"] == "Copy Page as Image", f"menus: Tools › Select (S); File › Export Selection… ⌥⌘E, dimmed with no selection; ⌘C is Copy Page as Image ({m})")
s = r["afterS"]; chk(s == {"tool": "select", "draw": True, "toolbarTool": "select"}, f"S picks Select (and draw mode, like every tool); the toolbar shows it {s}")
g = r["drag"]
chk(near(g["selection"], g["want"]) and g["strokes"] == 6, f"a one-finger drag makes the rectangle where the finger went: {[round(x, 1) for x in g['selection']]} = {[round(x, 1) for x in g['want']]}; no ink")
chk(near(r["drawn"], g["selection"]), "the canvas draws it (dashed outline and tint) at that rectangle")
b = r["barDrawMode"]; chk(b["shown"] and r["barNextTo"] and b["copy"] == "Copy ⌘C", f"the bar shows next to it (under its bottom-right corner, or over it); in draw mode it names the keys ({b['copy']}, {b['export']})")
mw = r["menuWith"]; chk(mw["copyTitle"] == "Copy Selection as Image" and mw["exportSelectionEnabled"], f"with a selection ⌘C reads Copy Selection as Image; Export Selection… is enabled {mw}")
cp = r["copy"]; pb = cp["pasteboard"]
chk(cp["performed"] and {"public.png", "com.adobe.pdf", "public.svg-image"} <= set(pb["types"]) and pb.get("png") == cp["want"] and pb["pdfBytes"] > 1000 and pb["svgHasViewBox"] and cp["toast"] == "Copied",
    f"⌘C puts PNG {pb.get('png')} (= rectangle x 2: {cp['want']}), PDF ({pb['pdfBytes']} bytes) and SVG on the pasteboard; the toast says {cp['toast']!r}")
e = r["escInDraw"]; chk(not e["draw"] and e["kept"] and e["bar"]["shown"] and e["bar"]["copy"] == "Copy", f"Esc in draw mode leaves it and keeps the selection; the bar's buttons are for the pointer ({e['bar']['copy']}, {e['bar']['export']})")
p = r["pointer"]; chk(near(p["selection"], p["want"]) and p["bar"]["shown"], f"a pointer drag outside draw mode makes a new rectangle (replacing the old): {[round(x, 1) for x in p['selection']]}")
bc = r["barCopy"]; chk(bc["changed"] and bc["pasteboard"].get("png"), f"the bar's Copy copies it ({bc['pasteboard'].get('png')})")
sh = r["sheet"]
chk(sh["open"] and sh["area"] == "Selection" and sh["areas"] == ["Page", "What's on screen", "Selection"] and sh["label"].startswith(f"{sh['want'][0]:,} × {sh['want'][1]:,} px"),
    f"the bar's Export… opens the sheet on Area Selection ({sh['areas']}); size shown {sh['label']!r} = rectangle x 3")
ex = r.get("exported", {})
chk(ex.get("size") == sh["want"] and str(ex.get("name", "")).startswith("Selection"), f"saving writes the region: {ex}")
chk(r["rememberedAreaAfter"] == "screen", f"the sheet remembers its other choices but not Area Selection (area still {r['rememberedAreaAfter']!r})")
eo = r["escOutside"]; chk(eo["cleared"] and not eo["bar"]["shown"] and not eo["exportSelectionEnabled"] and eo["copyTitle"] == "Copy Page as Image", "Esc outside draw mode clears it; the bar goes; ⌘C copies the page again")
sw = r["sheetWithout"]; chk(sw["areas"] == ["Page", "What's on screen"] and sw["area"] == "What's on screen", f"with no selection, Export Page… offers Page and What's on screen only ({sw})")
ts = r["toolSwitch"]; chk(ts == {"tool": "pen", "cleared": True}, f"S again goes back to the pen and clears the selection {ts}")
ps = r["pageSwitch"]; chk(ps["cleared"] and not ps["bar"]["shown"], "another page clears it")
ne = r["notAnEdit"]; chk(ne["sameDoc"] and ne["strokes"] == ne["strokes0"] and ne["version"] == ne["version0"] and ne["canUndo"] == ne["canUndo0"], f"none of it was an edit (strokes {ne['strokes']}, version {ne['version']} was {ne['version0']}, undo unchanged)")
os.makedirs(out, exist_ok=True)
shots = []
for f in sorted(os.listdir(d)):
    if f.startswith("shot-") and f.endswith(".png"): shutil.copy(f"{d}/{f}", f"{out}/select-{f[5:]}"); shots.append(f"select-{f[5:]}")
chk(len(shots) == 3, f"screenshots in {out}: {shots}")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
sys.exit(1 if bad else 0)
PY
r=$?
[ $bad -ne 0 ] && echo "RESULT: bench selection checks FAILED" && exit 1
exit $r
