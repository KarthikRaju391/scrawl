#!/bin/sh
# Builds build/Scrawl.app with the Command Line Tools toolchain (no Xcode), plus the offline bench.
#   ./build.sh                 development build: this Mac's architecture, bundle id local.trackpad-draw,
#                              ad-hoc signed, diagnostics on (Karthik's own copy keeps its settings)
#   CONFIG=release ./build.sh  release build: universal (arm64 + x86_64), -D RELEASE, identity from
#                              release.conf, hardened runtime, signed with $SIGN_ID (default ad-hoc "-")
set -e
cd "$(dirname "$0")"
. ./release.conf
CONFIG=${CONFIG:-dev}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
if [ "$CONFIG" = release ]; then APP="build/release/$APP_NAME.app"; else APP="build/$APP_NAME.app"; fi
FRAMEWORKS="-framework AppKit -framework Metal -framework MetalKit -framework QuartzCore -framework Carbon"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# The binary is always TrackpadDraw; the bundle name follows release.conf.
if [ "$CONFIG" = release ]; then
    ID=$BUNDLE_ID
    # Test modes ship too (they only run with explicit --test-* arguments): the DMG smoke test uses them.
    for arch in arm64 x86_64; do
        swiftc -O -swift-version 5 -D RELEASE -target $arch-apple-macos$MIN_MACOS -o build/TrackpadDraw-$arch app/*.swift $FRAMEWORKS
    done
    lipo -create build/TrackpadDraw-arm64 build/TrackpadDraw-x86_64 -output "$APP/Contents/MacOS/TrackpadDraw"
    rm build/TrackpadDraw-arm64 build/TrackpadDraw-x86_64
else
    ID=local.trackpad-draw
    swiftc -O -swift-version 5 -target $(uname -m)-apple-macos$MIN_MACOS -o "$APP/Contents/MacOS/TrackpadDraw" app/*.swift $FRAMEWORKS
fi
cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>TrackpadDraw</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Karthik Raju</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>TDUpdateURL</key><string>$UPDATE_URL</string>
  <key>TDBuildConfig</key><string>$CONFIG</string>
</dict></plist>
PLIST
if [ "$CONFIG" = release ]; then
    codesign --force --options runtime --timestamp=none --entitlements app.entitlements -s "${SIGN_ID:--}" "$APP"
else
    codesign --force -s - "$APP" 2>/dev/null || true
fi
echo "built: $APP ($CONFIG, $VERSION build $BUILD)"
[ "$CONFIG" = release ] && exit 0
swiftc -O -swift-version 5 -o build/bench $(ls app/*.swift | grep -v -e main.swift -e TestZoomLock.swift -e TestPersist.swift -e TestInput.swift -e TestAbout.swift -e AppMenu.swift) bench/*.swift \
  $FRAMEWORKS -framework PDFKit
swiftc -O -o build/crashdialogs tools/crashdialogs.swift   # used by the crash checks
