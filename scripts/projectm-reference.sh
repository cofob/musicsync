#!/bin/bash
# Builds libprojectM 4.1.8 (static) and Tests/MilkDropParityTests/ProjectM/projectm-render.c against it, for
# ProjectMParityTests. Prints the path of the tool. Run again to rebuild only what changed.
#   PROJECTM_CACHE  folder for the download, the build and the tool (default $TMPDIR/projectm-reference)
# Uses cmake and ninja from PATH, else from a venv in the cache folder (pip install cmake ninja).
#
# Patches to projectM, so that frames are repeatable and match MilkDropKit's test setup (every random value 0.5):
#   - the clock steps 1/60 s per frame (projectM 4.1 has no frame-time API), first frame at time 0;
#   - the final image goes to framebuffer `projectm_reference_fbo` (the tool's FBO), not to 0;
#   - rand_preset, rand_frame and the rot_* random values are 0.5; hue offsets are 0.5 (MilkDropKit's rand_start);
#   - EEL rand(n) uses 0.5 in place of the Mersenne Twister value;
#   - randNN textures pick with a fixed seed (the pick still differs from MilkDropKit's).
set -euo pipefail

version=4.1.8
cache="${PROJECTM_CACHE:-${TMPDIR:-/tmp}/projectm-reference}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
tool_src="$repo/Tests/MilkDropParityTests/ProjectM/projectm-render.c"
mkdir -p "$cache"
cache="$(cd "$cache" && pwd)"

if ! command -v cmake >/dev/null || ! command -v ninja >/dev/null; then
    [ -x "$cache/venv/bin/ninja" ] || { python3 -m venv "$cache/venv" && "$cache/venv/bin/pip" install -q cmake ninja; } >&2
    export PATH="$cache/venv/bin:$PATH"
fi

src="$cache/src/libprojectM-$version"
if [ ! -f "$src/.patched" ]; then
    tarball="$cache/libprojectM-$version.tar.gz"
    [ -f "$tarball" ] || curl -fsSL -o "$tarball" \
        "https://github.com/projectM-visualizer/projectm/releases/download/v$version/libprojectM-$version.tar.gz"
    rm -rf "$cache/src" "$cache/build" "$cache/install"
    mkdir -p "$cache/src"
    tar xzf "$tarball" -C "$cache/src"
    lib="$src/src/libprojectM"
    perl -0pi -e 's/auto currentTime = std::chrono::high_resolution_clock::now\(\);\n\n    double currentFrameTime = std::chrono::duration<double>\(currentTime - m_startTime\).count\(\);/static long calls = -1;\n    double currentFrameTime = static_cast<double>(calls++) \/ 60.0;/' "$lib/TimeKeeper.cpp"
    perl -0pi -e 's/glBindFramebuffer\(GL_DRAW_FRAMEBUFFER, 0\);/glBindFramebuffer(GL_DRAW_FRAMEBUFFER, projectm_reference_fbo);/; s/namespace libprojectM \{/extern "C" { unsigned int projectm_reference_fbo = 0; }\n\nnamespace libprojectM {/' "$lib/ProjectM.cpp"
    perl -pi -e 's/static auto floatRand = \[\]\(\) \{.*\};/static auto floatRand = []() { return 0.5f; };/' "$lib/MilkdropPreset/MilkdropShader.cpp"
    perl -pi -e 's/(hueRandomOffsets\[\d\]) = .*;/$1 = 0.5f;/' "$lib/MilkdropPreset/PresetState.cpp"
    perl -pi -e 's/rndEngine\(rndDevice\(\)\)/rndEngine(1u)/' "$lib/Renderer/TextureManager.cpp"
    perl -pi -e 's/prjm_eval_genrand_int32\(\) \* \(1.0 \/ \(double\) 0xFFFFFFFF\) \* rand_max/0.5 * rand_max/' \
        "$src/vendor/projectm-eval/projectm-eval/TreeFunctions.c"
    grep -q "calls++" "$lib/TimeKeeper.cpp" && grep -q projectm_reference_fbo "$lib/ProjectM.cpp" \
        && grep -q "return 0.5f" "$lib/MilkdropPreset/MilkdropShader.cpp" && grep -q "= 0.5f" "$lib/MilkdropPreset/PresetState.cpp" \
        && grep -q "rndEngine(1u)" "$lib/Renderer/TextureManager.cpp" \
        && grep -q "0.5 \* rand_max" "$src/vendor/projectm-eval/projectm-eval/TreeFunctions.c" \
        || { echo "patching projectM failed" >&2; exit 1; }
    touch "$src/.patched"
fi

if [ ! -f "$cache/install/lib/libprojectM-4.a" ]; then
    cmake -S "$src" -B "$cache/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_PLAYLIST=OFF -DENABLE_SYSTEM_PROJECTM_EVAL=OFF -DCMAKE_INSTALL_PREFIX="$cache/install" >&2
    cmake --build "$cache/build" >&2
    cmake --install "$cache/build" >&2
fi

tool="$cache/bin/projectm-render"
if [ ! -x "$tool" ] || [ "$tool_src" -nt "$tool" ]; then
    mkdir -p "$cache/bin"
    clang -O2 -std=c11 -Wall -DGL_SILENCE_DEPRECATION -I"$cache/install/include" "$tool_src" -o "$tool" \
        "$cache/install/lib/libprojectM-4.a" "$cache/build/vendor/projectm-eval/projectm-eval/libprojectM_eval.a" -lc++ \
        -framework OpenGL -framework CoreGraphics -framework ImageIO -framework CoreFoundation >&2
fi
echo "$tool"
