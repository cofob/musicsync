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
# App Intents metadata, as Xcode makes it: compiler const values of the app module, then the metadata processor.
META="$(mktemp -d)"
find Sources/MusicSyncApp -name '*.swift' > "$META/sources"
echo '["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider"]' > "$META/protocols.json"
TRIPLE="$(uname -m)-apple-macos15.0"
xcrun swiftc -typecheck -parse-as-library -swift-version 6 -module-name MusicSyncApp -target "$TRIPLE" -I "$BIN" -I "$BIN/Modules" -wmo \
    -emit-const-values-path "$META/MusicSyncApp.swiftconstvalues" -Xfrontend -const-gather-protocols-file -Xfrontend "$META/protocols.json" \
    @"$META/sources"
echo "$META/MusicSyncApp.swiftconstvalues" > "$META/constvalues"
: > "$META/empty"
xcrun appintentsmetadataprocessor --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" \
    --module-name MusicSyncApp --sdk-root "$(xcrun --show-sdk-path)" --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family macOS --deployment-target 15.0 --bundle-identifier dev.cofob.musicsync --target-triple "$TRIPLE" \
    --output "$APP/Contents/Resources" --binary-file "$APP/Contents/MacOS/MusicSyncApp" --source-file-list "$META/sources" \
    --metadata-file-list "$META/empty" --static-metadata-file-list "$META/empty" --swift-const-vals-list "$META/constvalues" \
    --compile-time-extraction --deployment-aware-processing --no-app-shortcuts-localization --force >&2
rm -rf "$META"
# SwiftPM stamps the deployment target as the SDK version; AppKit then uses the old look.
EXE="$APP/Contents/MacOS/MusicSyncApp"
vtool -set-build-version macos 15.0 "$(xcrun --show-sdk-version)" -replace -output "$EXE" "$EXE"
codesign --force --deep --sign - "$APP"
echo "$APP"
