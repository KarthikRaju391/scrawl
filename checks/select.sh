#!/bin/bash
# The Select tool (a pointer tool): the bench's selection checks (a pointer drag under pan and zoom; finger touches draw
# nothing; Copy's PNG/PDF/SVG against the canvas's render; Export Selection; clearing; never an edit), then the tool in the
# app (background, dry pointer lock): S from draw mode gives the pointer back, fingers draw nothing, a pointer drag, the
# bar, ⌘C, the bar's Copy and Export…, the sheet on Selection, Esc, S / P / D back to drawing, a waiting next-line move
# dropped, another tool / page clearing it. Screenshots go to $OUT.
cd "$(dirname "$0")/.."
APP="${APP:-build/Scrawl.app/Contents/MacOS/TrackpadDraw}"
bad=0
if [ -z "$ALLOW_STALE" ] && [ -n "$(find app -name '*.swift' -newer "$APP" | head -1)" ]; then echo "FAIL $APP is older than app/ (build first)"; echo "RESULT: FAIL"; exit 1; fi
if [ -x build/bench ] && [ -z "$NO_BENCH" ]; then
    BENCH_ONLY=export build/bench | sed -n '/a pointer drag with Select/,$p' | tee /tmp/td-select-bench.$$ | grep -E "^(PASS|FAIL)"
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
s = r["afterS"]
chk(s["drawBefore"] and s["tool"] == "select" and not s["draw"] and not s["pointerLocked"] and s["toolbarShown"] and s["toolbarTool"] == "select",
    f"S from draw mode picks Select and gives the pointer back: draw mode off, pointer free, toolbar showing {s}")
f = r["fingers"]; chk(f["selection"] == [] and f["strokes"] == f["strokes0"], f"finger touches with Select draw neither a box nor ink (selection {f['selection']}, strokes {f['strokes']})")
g = r["drag"]
chk(near(g["selection"], g["want"]) and g["strokes"] == 6, f"a pointer drag makes the box under the pointer: {[round(x, 1) for x in g['selection']]} = {[round(x, 1) for x in g['want']]}; no ink")
chk(near(r["drawn"], g["selection"]), "the canvas draws it (dashed outline and tint) at that box")
b = r["bar"]; chk(b["shown"] and r["barNextTo"] and b["copy"] == "Copy" and b["export"] == "Export…", f"the bar shows next to it with plain labels ({b['copy']}, {b['export']})")
mw = r["menuWith"]; chk(mw["copyTitle"] == "Copy Selection as Image" and mw["exportSelectionEnabled"], f"with a selection ⌘C reads Copy Selection as Image; Export Selection… is enabled {mw}")
cp = r["copy"]; pb = cp["pasteboard"]
chk(cp["performed"] and {"public.png", "com.adobe.pdf", "public.svg-image"} <= set(pb["types"]) and pb.get("png") == cp["want"] and pb["pdfBytes"] > 1000 and pb["svgHasViewBox"] and cp["barCopy"] == "Copied" and cp["toast"] == "",
    f"⌘C puts PNG {pb.get('png')} (= box x 2: {cp['want']}), PDF ({pb['pdfBytes']} bytes) and SVG on the pasteboard; the bar says {cp['barCopy']!r} (no toast: {cp['toast']!r})")
rp = r["replaced"]; chk(near(rp["selection"], rp["want"]) and rp["bar"]["shown"], f"a new drag replaces it: {[round(x, 1) for x in rp['selection']]}")
bc = r["barCopy"]; chk(bc["changed"] and bc["pasteboard"].get("png"), f"the bar's Copy copies it ({bc['pasteboard'].get('png')})")
sh = r["sheet"]
chk(sh["open"] and sh["area"] == "Selection" and sh["areas"] == ["Page", "What's on screen", "Selection"] and sh["label"].startswith(f"{sh['want'][0]:,} × {sh['want'][1]:,} px"),
    f"the bar's Export… opens the sheet on Area Selection ({sh['areas']}); size shown {sh['label']!r} = box x 3")
ex = r.get("exported", {})
chk(ex.get("size") == sh["want"] and str(ex.get("name", "")).startswith("Selection"), f"saving writes the region: {ex}")
chk(r["rememberedAreaAfter"] == "screen", f"the sheet remembers its other choices but not Area Selection (area still {r['rememberedAreaAfter']!r})")
eo = r["escOutside"]; chk(eo["cleared"] and not eo["bar"]["shown"] and not eo["exportSelectionEnabled"] and eo["copyTitle"] == "Copy Page as Image", "Esc clears it; the bar goes; ⌘C copies the page again")
sw = r["sheetWithout"]; chk(sw["areas"] == ["Page", "What's on screen"] and sw["area"] == "What's on screen", f"with no selection, Export Page… offers Page and What's on screen only ({sw})")
sa = r["sAgain"]; chk(sa == {"tool": "pen", "draw": True}, f"S again goes back to the pen and to draw mode (it was on when Select was picked) {sa}")
pf = r["pFromSelect"]; chk(pf == {"from": "select", "tool": "pen", "draw": True}, f"P from Select: the pen, drawing {pf}")
df = r["dFromSelect"]; chk(df == {"from": "select", "tool": "pen", "draw": True}, f"D from Select: draw mode with the pen {df}")
pm = r["pendingMove"]; chk(pm["waitingBefore"] and not pm["waitingAfter"] and not pm["viewMoved"] and not pm["draw"], f"a waiting next-line move is dropped when Select is picked; the view stays put {pm}")
ts = r["toolSwitch"]; chk(ts["had"] and ts["cleared"] and ts["tool"] == "highlighter" and ts["draw"], f"another tool (H) clears the selection and draws {ts}")
ps = r["pageSwitch"]; chk(ps["had"] and ps["cleared"] and not ps["bar"]["shown"], "another page clears it")
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
