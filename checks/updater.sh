#!/bin/bash
# The in-app updater end to end (background; never takes focus): an old copy of the dev build in a temp
# "Applications" folder checks a local fake GitHub (release JSON, DMG, SHA256SUMS.txt, .sig), downloads, verifies,
# stages, restarts into the new version, and the new version opens the same notebook (its own TRACKPAD_DRAW_DATA).
# Then every way it can go wrong. Signed with a throwaway key, never the release key.
#   checks/updater.sh [scenario ...]      (default: all)
cd "$(dirname "$0")/.."
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
W=$(mktemp -d /tmp/scrawl-updater.XXXX); W=$(cd "$W" && pwd -P); OLD=1.0.0; NEW=1.0.1; BAD=0
# Everything LaunchServices knows under this run's folder (resolved paths: a deleted bundle is matched only by them).
registered_here() { "$LS" -dump 2>/dev/null | awk '/^path:/{sub(/^path: */,""); sub(/ \(0x[0-9a-f]+\)$/,""); print}' | grep -F "$W/" | sort -u; }
forget_all() { registered_here | while read -r b; do "$LS" -u "$b" 2>/dev/null; done; }
pass() { echo "PASS $*"; }; fail() { echo "FAIL $*"; BAD=$((BAD + 1)); }
[ -x build/Scrawl.app/Contents/MacOS/TrackpadDraw ] || { echo "build first (./build.sh)"; exit 2; }
swiftc -O -o "$W/update-sign" tools/update-sign.swift || exit 2
PUB=$("$W/update-sign" --generate "$W/test.key")

# Apps: the dev build with a version and the test key, re-signed ad hoc.
mkapp() {   # mkapp <dest .app> <version> [bundle id]
    rm -rf "$1"; ditto build/Scrawl.app "$1"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $2" -c "Set :ScrawlUpdatePublicKey $PUB" "$1/Contents/Info.plist"
    [ -n "$3" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $3" "$1/Contents/Info.plist"
    codesign --force --deep -s - "$1" 2>/dev/null
    "$LS" -u "$1" 2>/dev/null
}
mkdmg() {   # mkdmg <name> <version> [bundle id] [crash]
    local s="$W/stage-$1"; mkdir -p "$s"; mkapp "$s/Scrawl.app" "$2" "$3"
    if [ "$4" = crash ]; then printf '#!/bin/sh\nexit 3\n' > "$s/Scrawl.app/Contents/MacOS/TrackpadDraw"; chmod +x "$s/Scrawl.app/Contents/MacOS/TrackpadDraw"; codesign --force --deep -s - "$s/Scrawl.app" 2>/dev/null; fi
    hdiutil create -quiet -volname "Scrawl" -srcfolder "$s" -fs HFS+ -format UDZO -ov "$W/$1.dmg"
    "$LS" -u "$s/Scrawl.app" 2>/dev/null; rm -rf "$s"
}
mkdmg good $NEW; mkdmg older 0.9.0; mkdmg wrongid $NEW com.example.not-scrawl; mkdmg crash $NEW "" crash
for d in good older wrongid crash; do "$W/update-sign" --sign "$W/test.key" "$W/$d.dmg"; done
forget_all
cp "$W/good.dmg" "$W/other.bin"; echo x >> "$W/other.bin"; "$W/update-sign" --sign "$W/test.key" "$W/other.bin"   # a valid signature of other bytes
SEED=$(ls -t build/robot-*/data/Notebook.tdnb ~/code/trackpad-draw/build/robot-*/data/Notebook.tdnb 2>/dev/null | head -1)

# The fake GitHub: reads $W/mode.json on every request.
cat > "$W/server.py" <<'PY'
import http.server, json, os, sys, time, hashlib
W = sys.argv[1]; NEW = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def mode(self): return json.load(open(W + "/mode.json"))
    def send(self, code, body, ctype="application/octet-stream"):
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        m = self.mode(); base = "http://127.0.0.1:%d/dl/" % self.server.server_address[1]; name = "Scrawl-%s.dmg" % NEW
        dmg = open(W + "/" + m.get("dmg", "good") + ".dmg", "rb").read()
        if self.path.startswith("/repos/"):
            assets = [{"name": name, "browser_download_url": base + name}, {"name": "SHA256SUMS.txt", "browser_download_url": base + "SHA256SUMS.txt"}]
            if m.get("sig") != "missing": assets.append({"name": name + ".sig", "browser_download_url": base + name + ".sig"})
            tag = "v" + (NEW if m.get("tag", "new") == "new" else "0.0.1")
            self.send(200, json.dumps({"tag_name": tag, "html_url": "http://127.0.0.1/release", "draft": False, "prerelease": False,
                                       "body": "What's new in %s\n\n- A test release served by checks/updater.sh.\n- Second line of notes." % NEW, "assets": assets}).encode(), "application/json")
        elif self.path == "/dl/SHA256SUMS.txt":
            h = hashlib.sha256(dmg).hexdigest() if m.get("sums", "ok") == "ok" else "0" * 64
            self.send(200, ("%s  %s\n" % (h, name)).encode(), "text/plain")
        elif self.path == "/dl/" + name + ".sig":
            src = {"ok": m.get("dmg", "good") + ".dmg.sig", "bad": "other.bin.sig"}.get(m.get("sig", "ok"))
            if not src: return self.send(404, b"")
            self.send(200, open(W + "/" + src, "rb").read(), "text/plain")
        elif self.path == "/dl/" + name:
            t = m.get("transfer", "ok")
            if t == "error": return self.send(500, b"server error")
            self.send_response(200); self.send_header("Content-Length", str(len(dmg))); self.end_headers()
            if t == "truncate": self.wfile.write(dmg[: len(dmg) // 2]); self.wfile.flush(); self.connection.close(); return
            step = 32768 if t == "slow" else len(dmg)
            for i in range(0, len(dmg), step):
                try: self.wfile.write(dmg[i:i + step]); self.wfile.flush()
                except Exception: return
                if t == "slow": time.sleep(0.25)
        else: self.send(404, b"")
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[3])), H).serve_forever()
PY
PORT=$((20000 + RANDOM % 20000))
python3 "$W/server.py" "$W" "$NEW" "$PORT" & SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
sleep 0.5

# run <scenario> <mode json> [app flags...]: fresh Applications + data folders, launch the old app, wait for it to finish.
run() {
    S=$1; MODE=$2; shift 2
    A="$W/$S/Applications"; D="$W/$S/data"; mkdir -p "$A" "$D"
    mkapp "$A/Scrawl.app" $OLD
    [ -n "$SEED" ] && cp "$SEED" "$D/Notebook.tdnb"
    echo "$MODE" > "$W/mode.json"
    NB0=$(python3 -c "import plistlib,sys; f=plistlib.load(open(sys.argv[1],'rb')); print(len(f['pages']), sum(len(p['strokes']) for p in f['pages']))" "$D/Notebook.tdnb" 2>/dev/null)
    [ -n "$RO" ] && chmod 555 "$A"
    TRACKPAD_DRAW_DATA=$D TRACKPAD_DRAW_UPDATE_URL="http://127.0.0.1:$PORT/repos/o/r/releases/latest" SCRAWL_UPDATE_APPS_DIR=$A \
        "$A/Scrawl.app/Contents/MacOS/TrackpadDraw" --test-update "$@" >/dev/null 2>&1 &
    P=$!
    for _ in $(seq 1 240); do grep -q '"done" : true\|"restarting" : true' "$D/update-state.json" 2>/dev/null && break; sleep 0.25; done
    # In /Applications, Spotlight registers the staged copy while it waits; do the same here, before the restart.
    grep -q '"restarting" : true' "$D/update-state.json" 2>/dev/null && [ -d "$A/.Scrawl-update.app" ] && "$LS" -f "$A/.Scrawl-update.app" 2>/dev/null
    [ -n "$SHOT" ] && WN=$(python3 -c "import json;print(json.load(open('$D/update-state.json')).get('panelWindow',0))" 2>/dev/null) && [ "$WN" != 0 ] && screencapture -x -o -l"$WN" "$W/$S-panel.png"
    if grep -q '"restarting" : true' "$D/update-state.json" 2>/dev/null; then
        for _ in $(seq 1 160); do [ -f "$D/update-report.json" ] && grep -qE "updated to|didn't start" "$D/update.log" 2>/dev/null && break; sleep 0.25; done
        sleep 2.5
    else kill -TERM $P 2>/dev/null; wait $P 2>/dev/null; fi
    STATES=$(python3 -c "import json;print(' > '.join(s['state'] for s in json.load(open('$D/update-state.json'))['states']))" 2>/dev/null)
    VERNOW=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$A/Scrawl.app/Contents/Info.plist" 2>/dev/null)
    NB1=$(python3 -c "import plistlib,sys; f=plistlib.load(open(sys.argv[1],'rb')); print(len(f['pages']), sum(len(p['strokes']) for p in f['pages']))" "$D/Notebook.tdnb" 2>/dev/null)
    LEFT=$(ls -a "$A" | grep -v '^\.\.\?$' | tr '\n' ' ')
    # Bundles LaunchServices still knows inside this Applications folder, other than Scrawl.app itself (the staged copy
    # and the backup must be forgotten once they're gone).
    STALE=$("$LS" -dump 2>/dev/null | awk '/^path:/{sub(/^path: */,""); sub(/ \(0x[0-9a-f]+\)$/,""); print}' | grep -F "$(cd "$A" && pwd -P)/" | grep -v "^$(cd "$A" && pwd -P)/Scrawl.app$" | sort -u | tr '\n' ' ')
    chmod 755 "$A" 2>/dev/null
    for b in "$A"/*.app "$A"/.*.app "$A"/*.old-update; do [ -e "$b" ] && "$LS" -u "$b" 2>/dev/null; done
    pkill -f "$A/Scrawl.app/Contents/MacOS/TrackpadDraw" 2>/dev/null
    forget_all
}
want() { [ -z "$ONLY" ] || echo " $ONLY " | grep -q " $1 "; }
ONLY="$*"
ok='{"dmg":"good"}'

if want happy; then SHOT=1 run happy "$ok" --update-restart; SHOT=
    R=$(cat "$W/happy/data/update-report.json" 2>/dev/null)
    [ -z "$STALE" ] && pass "after the update LaunchServices knows nothing in that folder but Scrawl.app" || fail "after the update LaunchServices still knows: $STALE"
    echo "$STATES" | grep -q "offer > downloading > verifying > ready" && [ "$VERNOW" = $NEW ] && echo "$R" | grep -q "\"version\" : \"$NEW\"" && [ "$NB0" = "$NB1" ] && [ "$LEFT" = "Scrawl.app " ] \
        && pass "happy path: offer > download > verify > ready > restart; $NEW is installed and running and opened the same notebook ($NB1 pages/strokes); nothing left over ($LEFT)" \
        || fail "happy path: states [$STATES], installed $VERNOW, report $R, notebook $NB0 -> $NB1, left [$LEFT], log: $(cat "$W/happy/data/update.log" 2>/dev/null)"
    xattr "$W/happy/Applications/Scrawl.app" 2>/dev/null | grep -q quarantine && fail "the installed app is quarantined" || pass "the installed app carries no quarantine flag (no Gatekeeper prompt)"
fi
check_refused() {   # check_refused <name> <expected text>
    echo "$STATES" | grep -q "failed.*$2" && [ "$VERNOW" = $OLD ] && [ "$NB0" = "$NB1" ] && [ "$LEFT" = "Scrawl.app " ] \
        && pass "$1: refused (\"$(echo "$STATES" | sed 's/.*failed //')\"), $OLD untouched, nothing staged" \
        || fail "$1: states [$STATES], installed $VERNOW, notebook $NB0 -> $NB1, left [$LEFT]"
}
want badsha    && { run badsha '{"dmg":"good","sums":"bad"}';                 check_refused "bad checksum" "checksum"; }
want badsig    && { SHOT=1 run badsig '{"dmg":"good","sig":"bad"}';                  check_refused "bad signature" "signed"; }
want nosig     && { run nosig '{"dmg":"good","sig":"missing"}';               check_refused "missing signature" "signed"; }
want truncate  && { run truncate '{"dmg":"good","transfer":"truncate"}';      check_refused "truncated download" "download\|incomplete\|checksum"; }
want error     && { run error '{"dmg":"good","transfer":"error"}';            check_refused "server error" "500"; }
want older     && { run older '{"dmg":"older"}';                              check_refused "a DMG with an older version" "isn't newer"; }
want wrongid   && { run wrongid '{"dmg":"wrongid"}';                          check_refused "a DMG with another app" "isn't Scrawl"; }
if want cancel; then run cancel '{"dmg":"good","transfer":"slow"}' --update-cancel-after 0.6; check_refused "Cancel during the download" "cancelled"; fi
if want double; then SHOT= run double '{"dmg":"good","transfer":"slow"}' --update-double
    N=$(python3 -c "import json;print(json.load(open('$W/double/data/update-state.json')).get('downloadsStarted',0))" 2>/dev/null)
    [ "$N" = 1 ] && echo "$STATES" | grep -q "ready" && pass "Download and Install pressed three times: one download ($N), ready" || fail "double click: $N downloads, states [$STATES]"
fi
if want notnewer; then run notnewer '{"dmg":"good","tag":"old"}'
    echo "$STATES" | grep -q "^upToDate" && [ "$VERNOW" = $OLD ] && pass "a release that isn't newer: up to date, no sheet" || fail "not newer: [$STATES]"
fi
if want readonly; then RO=1 run readonly "$ok"; RO=
    echo "$STATES" | grep -q "unsupported.*can't replace itself" && [ "$VERNOW" = $OLD ] && pass "a folder it can't write to: says so, offers the release page, changes nothing" || fail "read-only: [$STATES], installed $VERNOW"
fi
if want crash; then run crash '{"dmg":"crash"}' --update-restart
    R=$(cat "$W/crash/data/update-report.json" 2>/dev/null)
    [ -z "$STALE" ] && pass "after the rollback LaunchServices knows nothing in that folder but Scrawl.app" || fail "after the rollback LaunchServices still knows: $STALE"
    [ "$VERNOW" = $OLD ] && echo "$R" | grep -q "\"version\" : \"$OLD\"" && grep -q "didn't start; putting the old one back" "$W/crash/data/update.log" && [ "$NB0" = "$NB1" ] \
        && pass "a new version that won't start: the old one is put back and reopened ($R)" || fail "crash: installed $VERNOW, report $R, log $(cat "$W/crash/data/update.log" 2>/dev/null)"
fi
for s in happy badsig; do [ -f "$W/$s-panel.png" ] && cp "$W/$s-panel.png" /tmp/scrawl-update-panel-$s.png && echo "panel screenshot: /tmp/scrawl-update-panel-$s.png"; done
forget_all
left=$(registered_here)
[ -z "$left" ] && pass "LaunchServices knows nothing under $W after the run" || fail "LaunchServices still knows: $(echo $left)"
echo "work: $W"
echo "RESULT: $([ $BAD = 0 ] && echo PASS || echo "FAIL ($BAD)")"
