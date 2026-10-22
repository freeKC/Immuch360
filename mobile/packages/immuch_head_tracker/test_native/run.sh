#!/usr/bin/env bash
# Builds the head tracker with gcc and runs its native tests on the frames of the recorded clip (needs cmake, g++ and
# ffmpeg). The build folder is the first argument, a temporary folder by default.
#   test_native/run.sh [build folder]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
clip="$here/../../../test/fixtures/video/painted-head-12s.mp4"
build="${1:-$(mktemp -d)}"
cmake -S "$here" -B "$build" -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build "$build" -j "$(nproc)" > /dev/null
ffmpeg -nostdin -v error -y -i "$clip" -vf format=gray -f rawvideo "$build/clip-320x240.y8"
"$build/ht_core_test" "$build/clip-320x240.y8" 320 240
