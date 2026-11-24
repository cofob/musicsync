#!/bin/bash
# Makes the MilkDrop preset cache and uploads it to R2 (https://musicsync-cache.cfb.wtf/<prefix>/index.json).
# Options: --sample N, --dry-run, --refresh, --platforms macos,ios, --prefix milkdrop (see PresetCacheTool).
# PROGRESS_CMD: a command run with each progress line as its argument (for example a chat notifier).
# The R2 keys come from ENV_FILE (default .env at the repo root): AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
# AWS_DEFAULT_REGION, AWS_ENDPOINT_URL, S3_BUCKET (an S3_BUCKET set in the environment wins). Nothing of it is printed.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env}"
bucket="${S3_BUCKET:-}"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
export S3_BUCKET="${bucket:-${S3_BUCKET:-}}"
export RCLONE_S3_PROVIDER=Cloudflare RCLONE_S3_ENV_AUTH=true RCLONE_S3_NO_CHECK_BUCKET=true
export RCLONE_S3_ENDPOINT="${AWS_ENDPOINT_URL:-}" RCLONE_S3_REGION="${AWS_DEFAULT_REGION:-auto}"
# Its own build folder, so a test run in .build does not hold the build.
build=(swift build -c release --scratch-path .build/preset-cache-tool)
"${build[@]}" --product PresetCacheTool
exec "$("${build[@]}" --show-bin-path)/PresetCacheTool" "$@"
