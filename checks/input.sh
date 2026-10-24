#!/bin/bash
# Touch input without MultitouchSupport, MT going quiet mid-use, and the welcome window (background).
cd "$(dirname "$0")/.."
APP="build/Scrawl.app/Contents/MacOS/TrackpadDraw"
run() {  # run <dir> <args...>
    local D=$1; shift
    TRACKPAD_DRAW_DATA=$D "$APP" "$@" >/dev/null 2>&1 &
    local P=$!; for _ in $(seq 1 60); do [ -f "$D/ui-step.txt" ] && break; sleep 0.25; done; kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
}
F=$(mktemp -d /tmp/td-input.XXXX); S=$(mktemp -d /tmp/td-input.XXXX); W=$(mktemp -d /tmp/td-input.XXXX)
run "$F" --test-input fallback --input-nstouch
run "$S" --test-input stall
run "$W" --test-input welcome
python3 -I - "$F" "$S" "$W" <<'PY'
import json, sys
f, s, w = (json.load(open(d + "/test-input.json")) for d in sys.argv[1:4])
bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
chk(not f["multitouchStarted"] and not f["usingMTAtStart"], "MultitouchSupport off (--input-nstouch): never started")
chk(f["strokes"] == 3, f"public touch path draws: {f['strokes']}/3 strokes")
chk(not f["aimActive"], "aim-first stays off without pressure (a light touch must still ink)")
x, y = f["inkStartsAtTouchMM"]
chk(abs(x - 0.102 * 160) < 2 and abs(y - 0.7 * 100) < 2, f"ink starts where the finger touched ({x:.1f}, {y:.1f} mm; want ~16, 70)")
(a0, a1), (c0, c1), _ = f["pressures"]
chk(a1 - a0 > 0.3 and c1 - c0 < (a1 - a0) / 2, f"no pressure on this path: width follows speed (speeding-up stroke {a0:.2f}-{a1:.2f}, steady stroke {c0:.2f}-{c1:.2f})")
chk("basic touch input" in f["banner"], f"window says so: \"{f['banner']}\"")
chk(s["usingMTAtStart"] and not s["usingMTAfter"] and s["inputStalled"], "MT silent while a finger is down: switched to the public touch path")
chk(s["strokes"] >= 2, f"drawing kept working through the switch ({s['strokes']} strokes)")
iw = " ".join(s.get("infoWindow", []))
chk(not s["infoWindowWhileDrawing"], "no window pops up mid-drawing")
chk("Touches weren't arriving" in iw and "[Open Input Monitoring Settings]" in iw, "on leaving draw mode, the help window explains it, with an Input Monitoring button")
full = " ".join(w["full"])
chk("Welcome to Scrawl" in full and "Trackpad Draw" not in full and "⌃⌥D" in full and "Esc" in full and "Full touch input" in full and "[Start Drawing]" in full,
    "welcome: what it does, ⌃⌥D / Esc, which input is live, Start button")
chk("Nothing is uploaded" in full and "Check for Updates" in full, "welcome: privacy note (pages stay local, only network use is Check for Updates)")
chk("No trackpad found" in " ".join(w["none"]) and "Basic touch input" in " ".join(w["basic"]), "no-trackpad and basic-input messages")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
PY
echo "snapshots: $W/welcome-full.png $W/welcome-stalled.png"
