#!/bin/bash
# Builds release binaries and wraps the GUI in build/FanCurve.app
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=build/FanCurve.app
VERSION=$(date +%Y.%m.%d.%H%M)
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$BIN/FanCurve" "$APP/Contents/MacOS/FanCurve"
cp "$BIN/fancurved" build/fancurved
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>FanCurve</string>
  <key>CFBundleIdentifier</key><string>local.fancurve.app</string>
  <key>CFBundleExecutable</key><string>FanCurve</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>FanCurve shows your upcoming meetings in the menu bar and lets you join video calls in one click.</string>
  <key>NSCalendarsUsageDescription</key><string>FanCurve shows your upcoming meetings in the menu bar and lets you join video calls in one click.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" build/fancurved
echo "$VERSION" > build/VERSION
echo "built $APP and build/fancurved (version $VERSION)"
