#!/bin/bash
# Builds a release into dist/<version>/: universal Scrawl.app (hardened runtime), a DMG and a zip,
# and SHA256SUMS.txt.
#   scripts/release.sh
#       ad-hoc signed: what the GitHub release ships (no Apple Developer ID; macOS warns on first open,
#       see README "Installing").
#   SIGN_ID="Developer ID Application: <Name> (<TEAMID>)" scripts/release.sh
#       signed with a Developer ID (the certificate must be in the login keychain).
#   ... NOTARY_PROFILE=<profile> scripts/release.sh
#       also notarizes and staples. Make the profile once with
#       `xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <TEAMID>`.
#       Nothing here contains or invents credentials; without these variables the steps are skipped.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./release.conf
SIGN_ID=${SIGN_ID:--}
export SIGN_ID
CONFIG=release ./build.sh
APP="build/release/$APP_NAME.app"
DIST="dist/$VERSION"
SLUG=$(echo "$APP_NAME" | tr ' ' '-')
rm -rf "$DIST"; mkdir -p "$DIST"

echo "== verify the app"
codesign --verify --strict --deep "$APP"
codesign -dv "$APP" 2>&1 | grep -E "flags=.*runtime" >/dev/null || { echo "hardened runtime missing"; exit 1; }
lipo -archs "$APP/Contents/MacOS/TrackpadDraw"

echo "== DMG"
STAGE=$(mktemp -d /tmp/td-dmg.XXXX)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<TXT
$APP_NAME $VERSION

Install: drag $APP_NAME into Applications.

This build isn't notarized by Apple, so macOS asks before opening it the first time:
  macOS 14: Control-click (or right-click) $APP_NAME in Applications, choose Open, then Open again.
  macOS 15 and later: open it once. macOS says it can't check it for malware: click Done (not Move to
  Trash). Then go to System Settings > Privacy & Security, scroll to "$APP_NAME was blocked", click
  Open Anyway and confirm.
After that it opens normally. Press Control-Option-D (or D) to draw with the trackpad, Esc to stop.

Your pages are saved on this Mac only. See Help > $APP_NAME Help in the app.
TXT
DMG="$DIST/$SLUG-$VERSION.dmg"
hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
[ "$SIGN_ID" != "-" ] && codesign --force -s "$SIGN_ID" --timestamp "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    [ "$SIGN_ID" = "-" ] && { echo "notarization needs SIGN_ID (a Developer ID)"; exit 1; }
    echo "== notarize"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
else
    echo "== notarization skipped (no NOTARY_PROFILE)"
fi

echo "== update signature"
# The in-app updater checks the DMG's Ed25519 signature (Scrawl-<version>.dmg.sig, uploaded with the DMG).
SIGN_KEY=${UPDATE_SIGNING_KEY:-$HOME/.config/scrawl/update-signing.key}
if [ -f "$SIGN_KEY" ]; then
    swiftc -O -o build/update-sign tools/update-sign.swift
    build/update-sign --sign "$SIGN_KEY" "$DMG"
    build/update-sign --verify "$UPDATE_PUBLIC_KEY" "$DMG" "$DMG.sig" || { echo "the DMG's signature doesn't match UPDATE_PUBLIC_KEY"; exit 1; }
else
    echo "== no update signing key at $SIGN_KEY: the DMG is unsigned (the in-app updater will refuse it)"
fi
echo "== zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$SLUG-$VERSION.zip"
# SHA256SUMS.txt lists only what gets uploaded (the DMG; the zip stays local), so `shasum -c` passes on a download.
(cd "$DIST" && shasum -a 256 *.dmg > SHA256SUMS.txt && cat SHA256SUMS.txt)
# Forget the release build and any staged copy: only the installed app is Scrawl to LaunchServices (checks/launchservices.sh).
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for a in "$APP" "${STAGE:-}/$APP_NAME.app"; do if [ -e "$a" ]; then "$LSREGISTER" -u "$(cd "$(dirname "$a")" && pwd)/$(basename "$a")" 2>/dev/null || true; fi; done
echo "release: $DIST (signed: $([ "$SIGN_ID" = "-" ] && echo ad-hoc || echo "$SIGN_ID"))"
