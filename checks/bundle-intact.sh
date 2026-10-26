#!/bin/bash
# A rebuild never leaves the app bundle empty or half-built: Karthik runs build/release/Scrawl.app (and
# build/Scrawl.app) while the suites rebuild them, so opening it mid-build must still find a whole app.
# Runs a dev build and checks the bundle every 0.1 s. The release build takes the same path in build.sh.
cd "$(dirname "$0")/.."
. ./release.conf
APP="build/$APP_NAME.app"
BAD=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; BAD=$((BAD + 1)); }
[ -x "$APP/Contents/MacOS/TrackpadDraw" ] || ./build.sh >/dev/null 2>&1
./build.sh > /tmp/td-bundle-intact-build.log 2>&1 &
B=$!; polls=0; gaps=0; first=""
while kill -0 $B 2>/dev/null; do
    polls=$((polls + 1))
    if [ ! -x "$APP/Contents/MacOS/TrackpadDraw" ] || [ ! -f "$APP/Contents/Info.plist" ] || [ ! -f "$APP/Contents/Resources/AppIcon.icns" ]; then
        gaps=$((gaps + 1)); [ -z "$first" ] && first="poll $polls: $(ls -R "$APP" 2>&1 | tr '\n' ' ' | cut -c1-120)"
    fi
    sleep 0.1
done
wait $B && pass "build finished" || fail "build failed (see /tmp/td-bundle-intact-build.log)"
[ $gaps = 0 ] && pass "the bundle was whole at every check during the rebuild ($polls checks)" || fail "the bundle was missing or incomplete at $gaps of $polls checks during the rebuild ($first)"
codesign --verify --strict "$APP" 2>/dev/null && pass "the new bundle's signature verifies" || fail "signature"
ls -d build/.staging-* 2>/dev/null | grep -q . && fail "staging folder left behind" || pass "no staging folder left behind"
echo "RESULT: $([ $BAD = 0 ] && echo PASS || echo "FAIL ($BAD)")"
[ $BAD = 0 ]
