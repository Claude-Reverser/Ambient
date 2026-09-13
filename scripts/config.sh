#!/bin/bash
# Shared build paths and release metadata.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
BUILD_NUMBER="${BUILD_NUMBER:-12}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
APP_PATH="$DIST_DIR/Ambient.app"
SETUP_PATH="$DIST_DIR/Animated Setup.app"
DMG_PATH="$DIST_DIR/Ambient-${VERSION}-apple-silicon.dmg"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must contain a semantic version, such as 0.7.0." >&2
    exit 1
fi
if [ -n "${SIGNING_IDENTITY:-}" ] && [[ "$SIGNING_IDENTITY" != 'Developer ID Application:'* ]]; then
    echo "SIGNING_IDENTITY must be a Developer ID Application identity. Unset it for an ad-hoc development build." >&2
    exit 1
fi
mkdir -p "$DIST_DIR"
