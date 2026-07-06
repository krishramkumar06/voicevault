#!/bin/zsh
# Builds VoiceVault.app into dist/ from a clean release compile.
# No Xcode required — SwiftPM + system tools only.
#
#   ./Scripts/build_app.sh            # ad-hoc signed (default)
#   SIGNING_IDENTITY="Developer ID Application: …" ./Scripts/build_app.sh
#
# With a real SIGNING_IDENTITY set, the output is ready for notarytool.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=dist/VoiceVault.app
IDENTITY="${SIGNING_IDENTITY:--}"   # "-" = ad-hoc

echo "── Compiling (release)…"
swift build -c release 2>&1 | tail -1

echo "── Assembling ${APP}…"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VoiceVault "$APP/Contents/MacOS/VoiceVault"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "── Drawing the icon…"
swift Scripts/make_icon.swift /tmp/voicevault_icon_1024.png >/dev/null
ICONSET=/tmp/VoiceVault.iconset
rm -rf "$ICONSET" && mkdir "$ICONSET"
for SIZE in 16 32 128 256 512; do
  DOUBLE=$((SIZE * 2))
  sips -z $SIZE $SIZE /tmp/voicevault_icon_1024.png \
    --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  sips -z $DOUBLE $DOUBLE /tmp/voicevault_icon_1024.png \
    --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "── Signing (identity: ${IDENTITY})…"
codesign --force --deep --sign "$IDENTITY" \
  --options runtime --timestamp=none "$APP" 2>/dev/null \
  || codesign --force --deep --sign "$IDENTITY" "$APP"

echo "── Zipping…"
VERSION=$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)
ditto -c -k --keepParent "$APP" "dist/VoiceVault-${VERSION}.zip"

echo "✓ dist/VoiceVault-${VERSION}.zip"
codesign -dv "$APP" 2>&1 | grep -E 'Signature|Authority' || true
