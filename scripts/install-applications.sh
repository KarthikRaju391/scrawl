#!/bin/bash
# Install a release DMG into /Applications: scripts/install-applications.sh dist/<version>/Scrawl-<version>.dmg
# Refuses while Scrawl runs from /Applications (quit it first: it saves on quit). Replaces the bundle, forgets the
# mounted copy and registers /Applications/Scrawl.app, so it is the only Scrawl LaunchServices knows.
set -e
cd "$(dirname "$0")/.."; . ./release.conf
DMG=${1:?usage: scripts/install-applications.sh <dmg>}
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if pgrep -f "/Applications/$APP_NAME.app/Contents/MacOS/" >/dev/null; then echo "Scrawl is running from /Applications: quit it first"; exit 1; fi
MNT=$(mktemp -d /tmp/scrawl-install.XXXX)
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$DMG"
trap '"$LSREGISTER" -u "$MNT/$APP_NAME.app" 2>/dev/null; hdiutil detach -quiet "$MNT" 2>/dev/null' EXIT
rm -rf "/Applications/$APP_NAME.app"
ditto "$MNT/$APP_NAME.app" "/Applications/$APP_NAME.app"
codesign --verify --deep --strict "/Applications/$APP_NAME.app"
"$LSREGISTER" -f "/Applications/$APP_NAME.app"
echo "installed: /Applications/$APP_NAME.app $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "/Applications/$APP_NAME.app/Contents/Info.plist") build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "/Applications/$APP_NAME.app/Contents/Info.plist")"
