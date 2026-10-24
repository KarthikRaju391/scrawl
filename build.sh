#!/bin/sh
# Builds build/Trackpad Draw.app with the Command Line Tools toolchain (no Xcode).
# Ad-hoc signed only (local use). Also builds the offline bench.
set -e
cd "$(dirname "$0")"
APP="build/Trackpad Draw.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/TrackpadDraw" app/*.swift \
  -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore -framework Carbon
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.trackpad-draw</string>
  <key>CFBundleName</key><string>Trackpad Draw</string>
  <key>CFBundleExecutable</key><string>TrackpadDraw</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force -s - "$APP" 2>/dev/null || true
swiftc -O -swift-version 5 -o build/bench app/Ink.swift bench/main.swift
echo "built: $APP"
