#!/usr/bin/env bash
# Build AIUsageBar (release) and assemble a proper .app bundle so that
# Launch-at-login (SMAppService) and LSUIElement behaviour work correctly.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="AI Usage Bar"
BUNDLE="build/${APP_NAME}.app"
BIN_NAME="AIUsageBar"

echo "▶ Building release binary…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${BIN_NAME}"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "✗ Binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "▶ Assembling ${BUNDLE}…"
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"
cp "$BIN_PATH" "${BUNDLE}/Contents/MacOS/${BIN_NAME}"
cp Info.plist "${BUNDLE}/Contents/Info.plist"

# Ad-hoc code signature. SMAppService is happier with a signature; replace "-"
# with your Developer ID for distribution.
echo "▶ Code signing (ad-hoc)…"
codesign --force --deep --sign - "$BUNDLE" || {
    echo "⚠ codesign failed; app will still run but login-item may be limited." >&2
}

echo "✓ Built ${BUNDLE}"
echo
echo "Run it:      open \"${BUNDLE}\""
echo "Install:     cp -R \"${BUNDLE}\" /Applications/"
echo "Terminal probe (no GUI):  \"${BUNDLE}/Contents/MacOS/${BIN_NAME}\" --probe"
