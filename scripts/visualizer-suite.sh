#!/bin/bash
# Renders MilkDrop presets with MilkDropKit, butterchurn and projectM from the same input and writes an HTML report
# (DIR/index.html) that compares them: table, frames, difference images, videos and debug info.
#   scripts/visualizer-suite.sh [--sample N | --all] [--videos worst|all|none] [--out DIR]
#   --sample N  N presets of each category (default 20, about 470 presets, 7 minutes), plus the worst of the last run
#   --all       every preset (about 15 000; hours)
#   --videos    side-by-side videos for the worst presets (default), every preset or none
#   --out DIR   report folder (default .build/visualizer-suite)
# Downloads the preset packs and the texture pack of projectM-visualizer at fixed commits once, into
# VISUALIZER_SUITE_CACHE (default ~/Library/Caches/visualizer-suite), and builds the projectM tool there
# (scripts/projectm-reference.sh; PROJECTM_CACHE picks another build).
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
sample=20 videos=worst out="$repo/.build/visualizer-suite"
while [ $# -gt 0 ]; do
    case "$1" in
        --sample) sample="$2"; shift 2 ;;
        --all) sample=0; shift ;;
        --videos) videos="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        *) sed -n '2,11p' "$0" >&2; exit 1 ;;
    esac
done
case "$videos" in worst|all|none) ;; *) echo "--videos: worst, all or none" >&2; exit 1 ;; esac
cache="${VISUALIZER_SUITE_CACHE:-$HOME/Library/Caches/visualizer-suite}"
mkdir -p "$cache/packs" "$out"
cache="$(cd "$cache" && pwd)" out="$(cd "$out" && pwd)"

# name, commit (cream-of-the-crop: the one PresetPack downloads).
cream="$(sed -n 's/.*static let commit = "\([0-9a-f]*\)".*/\1/p' "$repo/Sources/MilkDropKit/Library/PresetPack.swift")"
packs=(
    "presets-cream-of-the-crop $cream"
    "presets-milkdrop-original e03b83e3338d8f1ed6cbcf908c719f249ef24288"
    "presets-projectm-classic 14a6244a7d32eb7e114e1a92d1cb93358cdcc54a"
    "presets-en-d fff71ea81223109f3558351667eef851f2781c96"
    "presets-milkdrop-texture-pack 6368812f27bc747b517218fbf89d21d59afce4d9"
)
for entry in "${packs[@]}"; do
    read -r name commit <<<"$entry"
    dir="$cache/packs/$name-$commit"
    [ -f "$dir/.done" ] && continue
    echo "downloading $name@${commit:0:7}" >&2
    rm -rf "$dir" && mkdir -p "$dir"
    curl -fsSL "https://codeload.github.com/projectM-visualizer/$name/tar.gz/$commit" | tar xzf - -C "$dir" --strip-components 1
    touch "$dir/.done"
done
pack() { echo "$cache/packs/$1-$(printf '%s\n' "${packs[@]}" | sed -n "s/^$1 //p")"; }

tool="$(PROJECTM_CACHE="${PROJECTM_CACHE:-$cache/projectm}" "$repo/scripts/projectm-reference.sh")"

config="$out/suite.json"
cat >"$config" <<EOF
{
  "out": "$out",
  "sample": $sample,
  "videos": "$videos",
  "projectM": "$tool",
  "textures": "$(pack presets-milkdrop-texture-pack)/textures",
  "known": "$cache/worst.txt",
  "packs": [
    {"name": "bundled", "dir": "$repo/Sources/MilkDropKit/Resources/Presets"},
    {"name": "cream-of-the-crop", "dir": "$(pack presets-cream-of-the-crop)"},
    {"name": "milkdrop-original", "dir": "$(pack presets-milkdrop-original)"},
    {"name": "projectm-classic", "dir": "$(pack presets-projectm-classic)"},
    {"name": "en-d", "dir": "$(pack presets-en-d)"}
  ]
}
EOF
cd "$repo"
# Release: native frame times as in the app; enable-testing for @testable imports.
MILKDROP_SUITE="$config" swift test -c release -Xswiftc -enable-testing --filter VisualizerSuiteTests
echo "report: $out/index.html"
