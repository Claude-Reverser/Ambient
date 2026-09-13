#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/config.sh"
: "${SIGNING_IDENTITY:?Set the installed Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set a notarytool Keychain profile name}"
test -f "$DMG_PATH"
codesign --verify --strict "$APP_PATH"
codesign --verify --strict "$SETUP_PATH"
codesign --verify "$DMG_PATH"
for artifact in "$APP_PATH" "$SETUP_PATH" "$DMG_PATH"; do
    if ! codesign -dv --verbose=4 "$artifact" 2>&1 | grep -q '^Authority=Developer ID Application:'; then
        echo "Refusing to notarize an artifact without Developer ID signing: $artifact" >&2
        exit 1
    fi
done
REPORT="$(mktemp)"
trap 'rm -f "$REPORT"' EXIT
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$REPORT"
python3 - "$REPORT" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    report = json.load(source)
print("Notarization:", report.get("status"), "Submission:", report.get("id"))
if report.get("status") != "Accepted":
    raise SystemExit("Notarization was not accepted; retrieve its log with notarytool log.")
PY
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
(cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256")
echo "Accepted and stapled: $DMG_PATH"
