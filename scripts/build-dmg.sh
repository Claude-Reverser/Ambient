#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/config.sh"
cd "$ROOT"
./scripts/build-app.sh
./scripts/build-setup.sh
STAGE=$(mktemp -d)
MOUNT=""
cleanup() { if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet || true; fi; rm -rf "$STAGE"; }
trap cleanup EXIT
mkdir -p "$STAGE/content/.background"
ditto "$SETUP_PATH" "$STAGE/content/Animated Setup.app"
swift scripts/dmg-background.swift "$STAGE/content/.background/installer.png"
hdiutil create -quiet -fs HFS+ -volname "Ambient Installer $VERSION" -srcfolder "$STAGE/content" -format UDRW "$STAGE/edit.dmg"
MOUNT="$STAGE/mounted"
hdiutil attach -quiet -readwrite -noverify -mountpoint "$MOUNT" "$STAGE/edit.dmg"
LAYOUT_PYTHON="${LAYOUT_PYTHON:-python3}"
"$LAYOUT_PYTHON" scripts/dmg-layout.py "$MOUNT"
test -s "$MOUNT/.DS_Store"
sync
hdiutil detach "$MOUNT" -quiet
MOUNT=""
DEST="$DMG_PATH"
hdiutil convert "$STAGE/edit.dmg" -quiet -format UDZO -imagekey zlib-level=9 -o "$STAGE/final.dmg"
mv "$STAGE/final.dmg" "$DEST"
hdiutil verify "$DEST"
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DEST"
    codesign --verify "$DEST"
fi
(cd "$DIST_DIR" && shasum -a 256 "$(basename "$DEST")" > "$(basename "$DEST").sha256")
echo "Built $DEST (not yet notarized; see DISTRIBUTION.md)"
