#!/bin/sh
# Builds build/MusicSync.app from the SwiftPM executable and ad-hoc signs it.
set -eu
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
# ARCHS="arm64 x86_64" makes a universal app.
FLAGS="-c $CONFIG"
for a in ${ARCHS:-}; do FLAGS="$FLAGS --arch $a"; done
swift build $FLAGS --product MusicSyncApp
BIN="$(swift build $FLAGS --show-bin-path)"
APP=build/MusicSync.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MusicSyncApp" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
# SwiftPM stamps the deployment target as the SDK version; AppKit then uses the old look.
EXE="$APP/Contents/MacOS/MusicSyncApp"
vtool -set-build-version macos 15.0 "$(xcrun --show-sdk-version)" -replace -output "$EXE" "$EXE"
codesign --force --deep --sign - "$APP"
echo "$APP"
