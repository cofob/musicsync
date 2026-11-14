#!/bin/sh
# Saves a PNG of one app scene from the demo instance: scripts/shot.sh <scene> <out.png>
# Scenes: see `Shot.show` in Sources/MusicSyncApp/Shot.swift. Env: MUSICSYNC_SHOT_DELAY, MUSICSYNC_VOLUMES, TIMEOUT.
set -eu
[ $# -eq 2 ] || { echo "usage: $0 <scene> <out.png>" >&2; exit 2; }
OUT="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
cd "$(dirname "$0")/.."
swift build --product MusicSyncApp >&2
BIN="$(swift build --show-bin-path)"
# A copy stamped with the real SDK version, so AppKit uses the current look (see bundle.sh).
vtool -set-build-version macos 15.0 "$(xcrun --show-sdk-version)" -replace -output "$BIN/MusicSyncApp-shot" "$BIN/MusicSyncApp" 2>/dev/null
codesign --force --sign - "$BIN/MusicSyncApp-shot" 2>/dev/null
rm -f "$OUT"
MUSICSYNC_DEMO=1 MUSICSYNC_MUTE=1 MUSICSYNC_SHOT="$OUT" MUSICSYNC_SCENE="$1" "$BIN/MusicSyncApp-shot" &
PID=$!
# Hard timeout: stops only the process started here.
( sleep "${TIMEOUT:-60}"; kill -9 "$PID" 2>/dev/null ) &
WATCH=$!
STATUS=0
wait "$PID" || STATUS=$?
pkill -P "$WATCH" 2>/dev/null || true  # its sleep, by parent PID
kill "$WATCH" 2>/dev/null || true
[ "$STATUS" -eq 0 ] && [ -s "$OUT" ] || { echo "shot failed ($STATUS)" >&2; exit 1; }
echo "$OUT"
