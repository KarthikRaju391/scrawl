#!/bin/bash
# Release smoke test (background): build the release, mount the DMG read-only, and run the app from the
# mounted volume: identity, signature, menus, About, update check against a local fixture server,
# MultitouchSupport loading under the hardened runtime, no network at launch, persistence across
# kill -9, the public-touch fallback, cursor restore, and drawing performance at 2,000+ strokes.
cd "$(dirname "$0")/.."
. ./release.conf
BAD=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; BAD=$((BAD + 1)); }
[ "${SKIP_BUILD:-}" = 1 ] || scripts/release.sh >/tmp/td-release-build.log 2>&1 || { echo "FAIL release build (see /tmp/td-release-build.log)"; exit 1; }
SLUG=$(echo "$APP_NAME" | tr ' ' '-'); DMG="dist/$VERSION/$SLUG-$VERSION.dmg"
(cd "dist/$VERSION" && shasum -a 256 -c SHA256SUMS.txt >/dev/null && [ "$(awk '{print $2}' SHA256SUMS.txt)" = "$SLUG-$VERSION.dmg" ]) && pass "SHA256SUMS.txt lists exactly the DMG, and it matches" || fail "checksums"

MNT=$(mktemp -d /tmp/td-mnt.XXXX)
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$DMG" || { fail "DMG mounts"; exit 1; }
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
trap '"$LSREGISTER" -u "$MNT/$APP_NAME.app" 2>/dev/null; hdiutil detach -quiet "$MNT" 2>/dev/null' EXIT   # the app ran from here: forget it
APPDIR="$MNT/$APP_NAME.app"; BIN="$APPDIR/Contents/MacOS/TrackpadDraw"
[ -d "$APPDIR" ] && [ -L "$MNT/Applications" ] && [ -f "$MNT/Read me first.txt" ] && pass "DMG: app, Applications link, install notes" || fail "DMG contents"
grep -q "Open Anyway" "$MNT/Read me first.txt" && pass "install notes cover the Gatekeeper prompt (Open / Open Anyway)" || fail "install notes"

archs=$(lipo -archs "$BIN"); [ "$archs" = "x86_64 arm64" ] && pass "universal binary ($archs)" || fail "archs: $archs"
sig=$(codesign -dv --verbose=2 "$APPDIR" 2>&1)
echo "$sig" | grep -q "flags=.*runtime" && pass "hardened runtime on ($(echo "$sig" | grep -o 'flags=[^ ]*'))" || fail "hardened runtime"
ents=$(codesign -d --entitlements :- "$APPDIR" 2>/dev/null | tr -d '\n\t ')
echo "$ents" | grep -qE "<dict/>|<dict></dict>" && pass "no entitlements (no sandbox exceptions, JIT or library-validation opt-outs)" || fail "entitlements: $ents"
codesign --verify --strict --deep "$APPDIR" && pass "signature verifies (ad-hoc: $(echo "$sig" | grep -c 'Signature=adhoc') )" || fail "codesign verify"
spctl -a -t exec "$APPDIR" 2>/dev/null && fail "Gatekeeper accepted an un-notarized app?" || pass "Gatekeeper rejects it as expected without a Developer ID (users see the Open Anyway prompt)"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APPDIR/Contents/Info.plist"; }
[ "$(plist CFBundleShortVersionString)" = "$VERSION" ] && [ "$(plist CFBundleVersion)" = "$BUILD_NUMBER" ] && [ "$(plist CFBundleIdentifier)" = "$BUNDLE_ID" ] && [ "$(plist LSMinimumSystemVersion)" = "$MIN_MACOS" ] \
    && pass "Info.plist: $(plist CFBundleName) $(plist CFBundleShortVersionString) build $(plist CFBundleVersion), $(plist CFBundleIdentifier), macOS $(plist LSMinimumSystemVersion)+" || fail "Info.plist"
[ -f "$APPDIR/Contents/Resources/AppIcon.icns" ] && [ "$(plist CFBundleIconFile)" = AppIcon ] && pass "app icon" || fail "icon"

run() {  # run <dir> <args...>: from the DMG, background, until ui-step.txt
    local D=$1; shift
    TRACKPAD_DRAW_DATA=$D "$BIN" "$@" >/dev/null 2>&1 &
    local P=$!; for _ in $(seq 1 80); do [ -f "$D/ui-step.txt" ] && break; sleep 0.25; done; kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
}

# No network at launch: sample the process's sockets for 4 s.
D=$(mktemp -d /tmp/td-rel.XXXX)
TRACKPAD_DRAW_DATA=$D "$BIN" --test-about >/dev/null 2>&1 &
P=$!; socks=0
for _ in $(seq 1 20); do n=$(lsof -a -i -p $P 2>/dev/null | tail -n +2 | wc -l); socks=$((socks + n)); sleep 0.2; done
kill -TERM $P; wait $P 2>/dev/null
[ $socks = 0 ] && pass "no network connections at launch (lsof, 20 samples over 4 s)" || fail "network sockets seen at launch: $socks"

# About, menus, MT under hardened runtime, update check against a local fixture.
FX=$(mktemp -d /tmp/td-fx.XXXX); mkdir -p "$FX/repos/o/r/releases"
# Shape from docs.github.com/rest/releases/releases#get-the-latest-release (fields the app reads, plus some it ignores).
cat > "$FX/repos/o/r/releases/latest" <<JSON
{"url":"https://api.github.com/repos/o/r/releases/2","html_url":"https://github.com/o/r/releases/tag/v9.9.0","id":2,"tag_name":"v9.9.0","name":"Scrawl 9.9.0","draft":false,"prerelease":false,"published_at":"2026-11-01T10:00:00Z","body":"notes","assets":[]}
JSON
PORT=$((20000 + RANDOM % 20000))
python3 -m http.server $PORT --bind 127.0.0.1 --directory "$FX" >/dev/null 2>&1 &
SRV=$!; sleep 1
D=$(mktemp -d /tmp/td-rel.XXXX)
TRACKPAD_DRAW_UPDATE_URL="http://127.0.0.1:$PORT/repos/o/r/releases/latest" run "$D" --test-about --start-mt --check-updates
D2=$(mktemp -d /tmp/td-rel.XXXX)
TRACKPAD_DRAW_UPDATE_URL="http://127.0.0.1:$PORT/repos/o/r/releases/missing" run "$D2" --test-about --check-updates
kill $SRV; wait $SRV 2>/dev/null
D3=$(mktemp -d /tmp/td-rel.XXXX)
TRACKPAD_DRAW_UPDATE_URL="http://127.0.0.1:1/latest" run "$D3" --test-about --check-updates
python3 -I - "$D" "$D2" "$D3" "$VERSION" <<'PY'
import json, sys
a, b, c = (json.load(open(d + "/test-about.json")) for d in sys.argv[1:4]); ver = sys.argv[4]
bad = 0
def chk(ok, msg):
    global bad; bad += 0 if ok else 1; print("PASS" if ok else "FAIL", msg)
chk(a["config"] == "release" and a["version"] == ver,
    f"release build reports {a['version']} build {a['build']} ({a['config']})")
m = {(x["menu"], x["title"]): x for x in a["menus"]}
need = [("Scrawl", "About Scrawl"), ("Scrawl", "Check for Updates…"), ("Scrawl", "Quit Scrawl"),
        ("File", "Export All Pages as PDF…"), ("File", "Export Page…"), ("Edit", "Undo"), ("Edit", "Redo"),
        ("Help", "Scrawl Help"), ("Help", "Keyboard Shortcuts"), ("Help", "Record Touch Diagnostics"), ("Help", "Show Logs in Finder")]
missing = [n for n in need if n not in m]
unwired = [f"{k[0]} > {k[1]}" for k, x in m.items() if not x["wired"]]
chk(not missing and not unwired, f"menu bar: {len(a['menus'])} items, all wired (missing {missing}, unwired {unwired})")
chk(m[("Help", "Scrawl Help")]["key"] == "?" and m[("Scrawl", "Quit Scrawl")]["key"] == "q", "Help is ⌘?, Quit is ⌘Q")
old = [f"{x['menu']} > {x['title']}" for x in a["menus"] if "Trackpad Draw" in x["menu"] + x["title"]] + [v for v in a["about"].values() if "Trackpad Draw" in v]
chk(not old and a["about"].get("ApplicationName") == "Scrawl", f"no old name left in menus or About ({old})")
ab = a["about"]
chk(ab.get("ApplicationVersion") == ver and "build" in ab.get("Version", "") and "MultitouchSupport" in ab.get("Credits", ""), f"About box: {ab.get('ApplicationName')} {ab.get('ApplicationVersion')} ({ab.get('Version')})")
chk(a["welcomeWouldShow"] and not a["migrationRanInTest"], "fresh install (empty settings, after migrating an old install): the welcome window shows; this test run did not migrate anything")
chk(a.get("mtStart") == "ok", f"MultitouchSupport loads under the hardened runtime: {a.get('mtStart')} ({a.get('mtSummary')})")
u = a["update"]; chk(u["result"] == "available" and u["version"] == "9.9.0" and u["page"].endswith("v9.9.0"), f"update check: newer release found ({u})")
chk(b["update"]["result"] == "failed" and "No published release" in b["update"]["why"], f"update check, 404: {b['update']['why']}")
chk(c["update"]["result"] == "failed" and "Couldn't reach" in c["update"]["why"], f"update check, server down: {c['update']['why'][:60]}…")
chk(a["updateURL"].startswith("http://127.0.0.1"), "update URL override works (default: " + "release.conf UPDATE_URL)")
sys.exit(bad)
PY
[ $? = 0 ] || BAD=$((BAD + 1))

# Persistence across kill -9, from the DMG build.
D=$(mktemp -d /tmp/td-rel.XXXX)
TRACKPAD_DRAW_DATA=$D "$BIN" --test-persist write >/dev/null 2>&1 &
P=$!; for _ in $(seq 1 80); do [ -f "$D/midstroke.json" ] && break; sleep 0.25; done; sleep 0.3; kill -9 $P; wait $P 2>/dev/null
run "$D" --test-persist read
python3 -I -c "
import json,sys; e=json.load(open('$D/expected.json')); a=json.load(open('$D/actual.json'))
ok=e['sha256']==a['sha256'] and a['previousCrash'] and 'closed unexpectedly' in a['hint']
print(('PASS' if ok else 'FAIL'), 'kill -9 mid-stroke, reopen: notebook identical, unexpected-quit note shown:', a['hint'][:70])
sys.exit(0 if ok else 1)" || BAD=$((BAD + 1))
grep -q "ended without quitting" "$D/crashes.log" && pass "local crash note written ($D/crashes.log)" || fail "crash note"

# Public-touch fallback and cursor restore, from the DMG build.
D=$(mktemp -d /tmp/td-rel.XXXX); run "$D" --test-input fallback --input-nstouch
python3 -I -c "
import json,sys; f=json.load(open('$D/test-input.json')); ok=f['strokes']==3 and not f['multitouchStarted']
print(('PASS' if ok else 'FAIL'), 'MultitouchSupport off: public touch path draws', f['strokes'], 'strokes'); sys.exit(0 if ok else 1)" || BAD=$((BAD + 1))
D=$(mktemp -d /tmp/td-rel.XXXX)
TRACKPAD_DRAW_DRYLOCK=1 TRACKPAD_DRAW_DATA=$D "$BIN" --test-cursor kill >/dev/null 2>&1 &
P=$!; for _ in $(seq 1 60); do [ -f "$D/locked.json" ] && break; sleep 0.25; done; kill -9 $P; wait $P 2>/dev/null; sleep 1.5
grep -q "exited (locked=true); re-associated" "$D/watchdog.log" && pass "kill -9 in draw mode: watchdog restores the cursor (dry run)" || fail "watchdog"

# Performance with 2,000 and 3,000 strokes: Scrawl's own time per frame (building and encoding it), budget one
# 120 Hz frame (8.3 ms). The time spent waiting for a drawable from the window server is reported but not
# counted: it depends on the compositor (a test window behind the user's windows gets one per refresh).
BUDGET=8.3
for args in "2000" "3000 --zoomed"; do
    D=$(mktemp -d /tmp/td-rel.XXXX)
    TRACKPAD_DRAW_DATA=$D "$BIN" --test-stress data/strokes-20261024-161939.jsonl --count $args >/dev/null 2>&1 &
    P=$!; for _ in $(seq 1 120); do [ -f "$D/ui-step.txt" ] && break; sleep 0.5; done; kill -TERM $P 2>/dev/null; wait $P 2>/dev/null
    POWER=$(pmset -g batt | head -1 | grep -o "'.*'" | tr -d "'")
    python3 -I - "$D/test-stress.json" "$args" "$BUDGET" "$POWER" <<'PY' || BAD=$((BAD + 1))
import json, sys
r = json.load(open(sys.argv[1])); args, budget, power = sys.argv[2], float(sys.argv[3]), sys.argv[4]
ok = r["strokes"] >= int(args.split()[0]) and r["ownP95"] < budget and r["gpuP95"] < budget
print("PASS" if ok else "FAIL", f"{r['strokes']} strokes{' zoomed' if 'zoomed' in args else ''}: Scrawl's own time per frame p95 {r['ownP95']:.2f} ms "
      f"(max {r['ownMax']:.2f}; building {r['buildP95']:.2f}), GPU {r['gpuP95']:.1f} ms; budget {budget} ms (120 Hz). "
      f"Waiting for a drawable: p50 {r['drawableWaitP50']:.1f} ms (window server, {power})")
sys.exit(0 if ok else 1)
PY
done
echo "RESULT: $([ $BAD = 0 ] && echo PASS || echo "FAIL ($BAD)")"
