#!/bin/bash
# Export Page… (⇧⌘E): the bench's export checks (PNG/SVG size, what's on screen vs the canvas's render, transparency,
# SVG parse and render-back, self-crossing highlighter, the size cap, the PDF read back), then the real sheet in the app:
# opened by ⇧⌘E, every option changed through its control, the size shown, saved through the sheet's Save, the choices
# remembered, the usage event. Screenshots of the sheet go to $OUT (default: the temp folder).
cd "$(dirname "$0")/.."
APP="${APP:-build/Scrawl.app/Contents/MacOS/TrackpadDraw}"
BENCH="${BENCH:-build/bench}"
bad=0
# A failed build leaves the old app in place: never test it (an old binary once saved into the person's Documents).
if [ -z "$ALLOW_STALE" ] && [ -n "$(find app -name '*.swift' -newer "$APP" | head -1)" ]; then echo "FAIL $APP is older than app/ (build first)"; echo "RESULT: FAIL"; exit 1; fi
if [ -x "$BENCH" ] && [ -z "$NO_BENCH" ]; then
    BENCH_ONLY=export "$BENCH" | tee /tmp/td-export-bench.$$ | grep -E "^(PASS|FAIL)"
    grep -q "^FAIL" /tmp/td-export-bench.$$ && bad=1; rm -f /tmp/td-export-bench.$$
fi
D=$(mktemp -d /tmp/td-export.XXXX); OUT="${OUT:-$D}"
TRACKPAD_DRAW_DATA=$D "$APP" --test-export --no-activate >/dev/null 2>&1 &
P=$!; sleep 1
for _ in $(seq 1 400); do
    [ "$(cat "$D/ui-step.txt" 2>/dev/null)" = done ] && break
    for q in "$D"/shot-*.req; do
        [ -e "$q" ] || continue
        n=$(basename "$q" .req); sleep 0.3
        build/winid $P all > "$D/$n.windows"
        while read -r id x y w h; do screencapture -x -o -l"$id" "$D/$n-$id.png"; done < "$D/$n.windows"
        mv "$q" "$D/$n.taken"; touch "$D/$n.done"
    done
    sleep 0.1
done
kill -TERM $P 2>/dev/null; for _ in $(seq 1 20); do kill -0 $P 2>/dev/null || break; sleep 0.25; done; kill -9 $P 2>/dev/null; wait $P 2>/dev/null
dlg=$(build/crashdialogs --close); [ -n "$dlg" ] && echo "FAIL the test left a crash dialog (closed it: pid $dlg)" && bad=1
python3 -I - "$D" "$OUT" <<'PY'
import json, sys, os, re
d, out = sys.argv[1], sys.argv[2]
try: r = json.load(open(d + "/test-export.json"))
except Exception as e: print("FAIL no result:", e); print("RESULT: FAIL (1)"); sys.exit(1)
bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
chk(r.get("menuTitle") == "Export Page…", f"File › ⇧⌘E is \"Export Page…\" ({r.get('menuTitle')!r})")
chk(r.get("sheet") and r.get("accessory"), f"⇧⌘E opens the save sheet with the export options (sheet {r.get('sheet')}, options {r.get('accessory')})")
if not (r.get("sheet") and r.get("accessory")): print("RESULT: FAIL"); sys.exit(1)
st = {s["step"]: s for s in r["states"]}
page, screen = r["pageRect"], r["screenRect"]
def dims(rect, s): return f"{round(rect[2] * s):,} × {round(rect[3] * s):,} px"
o = st["opened"]
chk((o["format"], o["scale"], o["area"], o["background"]) == ("png", 2, "page", "paper") and o["type"] == "png" and o["name"].endswith(".png"),
    f"first time: PNG, 2×, Page, Paper; the file is .png ({o['format']}, {o['scale']}, {o['area']}, {o['background']}, {o['name']})")
chk(o["label"] == dims(page, 2), f"size shown: {o['label']!r} = page {page[2]:.0f} × {page[3]:.1f} units × 2")
s = st["svg"]; chk(s["type"] == "svg" and s["name"].endswith(".svg") and s["label"] == dims(page, 2) + " (vector)", f"SVG: the file becomes .svg ({s['name']}), {s['label']!r}")
s = st["3x"]; chk(s["label"].startswith(dims(page, 3)) and s["percent"] == "300", f"3×: {s['label']!r}, field {s['percent']}%")
s = st["250%"]; chk(s["scale"] == 2.5 and s["scaleItem"] == "Custom" and s["label"].startswith(dims(page, 2.5)), f"typing 250%: Custom, {s['label']!r}")
s = st["screen"]; chk(s["area"] == "screen" and s["label"].startswith(dims(screen, 2.5)), f"What's on screen: {s['label']!r} = the view {screen[2]:.1f} × {screen[3]:.1f} units × 2.5")
bw, bh = r["bounds"]; vis = r["visible"]
chk(abs(screen[2] / screen[3] - bw / bh) < 0.002 and screen[0] <= vis[0] + 0.01 and screen[0] + screen[2] >= vis[0] + vis[2] - 0.01,
    f"the screen area is the whole view (aspect {screen[2] / screen[3]:.4f} = window {bw / bh:.4f}) around the pad's area")
s = st["transparent"]; chk(s["background"] == "transparent", "background: Transparent")
s = st["800% page"]; chk(s["orange"] and "Too large at 800%" in s["label"], f"800% of the page warns and is capped: {s['label']!r}")
s = st["40% typed"]; chk(s["scale"] == 0.5 and not s["orange"], f"40% typed is held at the 50% minimum ({s['scale']}, {s['label']!r})")
chk(r.get("savedSVG") and r.get("pngFilesAfterSVG") == [] and r.get("svgPaths") == r.get("svgWantPaths"),
    f"Save after switching PNG → SVG wrote one .svg file holding SVG ({r.get('svgFiles')}, .png files: {r.get('pngFilesAfterSVG')}): {r.get('svgPaths')} stroke paths for {r.get('svgWantPaths')} strokes in view")
chk(r.get("savedPNG") and len(r.get("svgFilesAfterPNG", [])) == 1,
    f"Save after switching SVG → PNG wrote one .png file holding PNG ({r.get('pngFiles')}); the SVG is untouched")
m = re.search(r'viewBox="([^"]+)"', r.get("svgHead", "")); vb = [float(x) for x in m.group(1).split()] if m else []
want = [screen[0], r["pageTop"] - (screen[1] + screen[3]), screen[2], screen[3]]
chk(len(vb) == 4 and all(abs(a - b) < 0.01 for a, b in zip(vb, want)), f"its viewBox is the view: {vb} = {[round(x, 2) for x in want]}")
re_ = r.get("reopened") or {}
chk((re_.get("format"), re_.get("scale"), re_.get("area"), re_.get("background")) == ("svg", 2.5, "screen", "transparent") and str(re_.get("name", "")).endswith(".svg"),
    f"reopened, the sheet remembers the last choices: {re_}")
chk(r.get("pngSize") and r.get("pngSize") == r.get("snapSize") and r.get("screenDiffOver40", 1) < 0.004 and r.get("screenDiffMean", 99) < 1.5,
    f"PNG of what's on screen at {r.get('screenPercent')}% = the canvas's render of the window's view: {r.get('pngSize')} vs {r.get('snapSize')}, "
    f"{r.get('screenDiffOver40', 1) * 100:.3f}% of pixels > 40/255 apart, mean {r.get('screenDiffMean', 99):.2f}")
chk(r.get("cancelLeavesNoFile"), "Cancel writes nothing")
ev = [json.loads(l) for l in r.get("exportEvents", [])]
fm = [e.get("props", {}).get("format") for e in ev]
chk(fm == ["svg", "png"] and all(set(e.get("props", {})) == {"format"} for e in ev), f"usage: one \"export\" event per save, format only ({fm})")
# The photos: the sheet's window (the smaller one) next to the main window.
os.makedirs(out, exist_ok=True)
for n in ("defaults", "svg-screen", "capped"):
    try:
        wins = [l.split() for l in open(f"{d}/shot-{n}.windows")]
        wins.sort(key=lambda w: int(w[3]) * int(w[4]))
        for i, w in enumerate(wins):
            src = f"{d}/shot-{n}-{w[0]}.png"
            if os.path.exists(src): os.replace(src, f"{out}/export-sheet-{n}{'' if i == 0 else '-window'}.png")
    except FileNotFoundError: pass
shots = sorted(f for f in os.listdir(out) if f.startswith("export-sheet-"))
chk(len(shots) >= 3, f"screenshots: {out}/ {shots}")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
sys.exit(1 if bad else 0)
PY
r=$?
[ $bad -ne 0 ] && echo "RESULT: bench export checks FAILED" && exit 1
exit $r
