#!/bin/bash
# Builds a release into dist/<version>/: universal Trackpad Draw.app (hardened runtime), a DMG and a zip,
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
  macOS 15 and later: open it once (macOS blocks it), then go to System Settings > Privacy & Security,
  scroll to "$APP_NAME was blocked", click Open Anyway and confirm.
After that it opens normally.

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

echo "== zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$SLUG-$VERSION.zip"
(cd "$DIST" && shasum -a 256 *.dmg *.zip > SHA256SUMS.txt && cat SHA256SUMS.txt)
echo "release: $DIST (signed: $([ "$SIGN_ID" = "-" ] && echo ad-hoc || echo "$SIGN_ID"))"
