#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/config.sh"
cd "$ROOT"
mkdir -p "$SETUP_PATH/Contents/MacOS" "$SETUP_PATH/Contents/Resources" "$SETUP_PATH/Contents/Helpers"
swiftc -parse-as-library -O -target arm64-apple-macos14.0 Installer/Setup.swift Installer/FinderWindowCloser.swift -o "$SETUP_PATH/Contents/MacOS/AnimatedSetup"
cp "$APP_PATH/Contents/Resources/Ambient.icns" "$SETUP_PATH/Contents/Resources/Ambient.icns"
if [ -d "$SETUP_PATH/Contents/Helpers/Ambient.app" ]; then rm -rf "$SETUP_PATH/Contents/Helpers/Ambient.app"; fi
ditto "$APP_PATH" "$SETUP_PATH/Contents/Helpers/Ambient.app"
cat > "$SETUP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AnimatedSetup</string>
<key>CFBundleIdentifier</key><string>local.ambient.setup</string>
<key>CFBundleName</key><string>Animated Setup</string>
<key>CFBundleIconFile</key><string>Ambient.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSAppleEventsUsageDescription</key><string>Ambient Setup closes its installer disk window after opening, leaving your other Finder windows untouched.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --entitlements Installer/Setup.entitlements --sign "$SIGNING_IDENTITY" "$SETUP_PATH"
else
    codesign --force --sign - "$SETUP_PATH"
fi
codesign --verify --strict "$SETUP_PATH/Contents/Helpers/Ambient.app"
codesign --verify --strict "$SETUP_PATH"
