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
# Usage counts go to PostHog from release builds only (docs/analytics.md).
if [ "$CONFIG" = release ]; then PH_TOKEN=${POSTHOG_PROJECT_TOKEN:-}; else PH_TOKEN=; fi
BUILD=${BUILD_NUMBER:-1}
# Dev builds show as "Scrawl Dev" and are unregistered from LaunchServices after every build, so Spotlight, Open With and
# `open -b` only ever find the installed app (checks/launchservices.sh).
if [ "$CONFIG" = release ]; then DISPLAY_NAME=$APP_NAME; else DISPLAY_NAME="$APP_NAME Dev"; fi
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ "$CONFIG" = release ]; then FINAL="build/release/$APP_NAME.app"; else FINAL="build/$APP_NAME.app"; fi
FRAMEWORKS="-framework AppKit -framework Metal -framework MetalKit -framework QuartzCore -framework Carbon"
# Build and sign in a staging folder, then swap it in: the app at $FINAL may be open (Karthik runs it while the
# checks rebuild it), so it is never empty or half-built (checks/bundle-intact.sh).
STAGE="build/.staging-$CONFIG"
APP="$STAGE/$APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$(dirname "$FINAL")"
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
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
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
  <key>ScrawlPostHogToken</key><string>$PH_TOKEN</string>
  <key>ScrawlPostHogHost</key><string>${POSTHOG_HOST:-}</string>
  <key>TDBuildConfig</key><string>$CONFIG</string>
  <key>ScrawlUpdatePublicKey</key><string>${UPDATE_PUBLIC_KEY:-}</string>
</dict></plist>
PLIST
if [ "$CONFIG" = release ]; then
    codesign --force --options runtime --timestamp=none --entitlements app.entitlements -s "${SIGN_ID:--}" "$APP"
else
    codesign --force -s - "$APP" 2>/dev/null || true
fi
OLD="$FINAL.old-$$"
[ -e "$FINAL" ] && mv "$FINAL" "$OLD"
mv "$APP" "$FINAL"
rm -rf "$OLD" "$STAGE"
APP=$FINAL
"$LSREGISTER" -u "$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")" 2>/dev/null || true
echo "built: $APP ($CONFIG, $VERSION build $BUILD)"
[ "$CONFIG" = release ] && exit 0
swiftc -O -swift-version 5 -o build/bench $(ls app/*.swift | grep -v -e main.swift -e TestZoomLock.swift -e TestPersist.swift -e TestInput.swift -e TestAbout.swift -e TestMapping.swift -e TestEdge.swift -e TestKeys.swift -e TestNewLine.swift -e TestPage.swift -e TestGallery.swift -e TestArrows.swift -e TestMeta.swift -e TestGallerySpeed.swift -e TestToolDraw.swift -e TestTaps.swift -e TestArrowKeys.swift -e TestToast.swift -e TestJitter.swift -e TestGalleryKeys.swift -e TestGalleryFlow.swift -e TestGalleryReplay.swift -e TestGalleryOrder.swift -e TestAccessibility.swift -e TestMenus.swift -e TestExport.swift -e TestSelect.swift -e TestSelectBar.swift -e TestUpdate.swift -e Selection.swift -e TestModes.swift -e Robot.swift -e TestPan.swift -e UsageEvents.swift -e AppMenu.swift -e AppGallery.swift) bench/*.swift \
  $FRAMEWORKS -framework PDFKit
swiftc -O -o build/winid tools/winid.swift          # window id for the screenshot checks (screencapture -l)
swiftc -O -o build/crashdialogs tools/crashdialogs.swift   # used by the crash checks
