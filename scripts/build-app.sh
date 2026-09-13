#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/config.sh"
cd "$ROOT"
swift build -c release --arch arm64 --jobs "${BUILD_JOBS:-2}"
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/Ambient" "$APP_PATH/Contents/MacOS/Ambient"
ICON_WORK="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK"' EXIT
swift scripts/make-icon.swift "$ICON_WORK/Ambient.iconset"
iconutil -c icns "$ICON_WORK/Ambient.iconset" -o "$APP_PATH/Contents/Resources/Ambient.icns"
cp LICENSE THIRD-PARTY-NOTICES.md "$APP_PATH/Contents/Resources/"
cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Ambient</string>
<key>CFBundleIdentifier</key><string>local.ambient.wallpaper</string>
<key>CFBundleName</key><string>Ambient</string>
<key>CFBundleIconFile</key><string>Ambient.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_PATH"
else
    codesign --force --sign - "$APP_PATH"
fi
codesign --verify --strict "$APP_PATH"
echo "Built $APP_PATH"
