#!/usr/bin/env bash
# Builds the head tracker with gcc and runs its native tests on the frames of the recorded clip, then on the same clip
# through the y4m fake camera (needs cmake, g++ and ffmpeg). The build folder is the first argument, a temporary folder
# by default; a second argument is where to write the landmark track of the clip (the fixture
# test/fixtures/spatial/painted-head-12s.track is made that way).
#   test_native/run.sh [build folder] [track out]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
clip="$here/../../../test/fixtures/video/painted-head-12s.mp4"
build="${1:-$(mktemp -d)}"
track="${2:-$build/painted-head-12s.track}"
cmake -S "$here" -B "$build" -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build "$build" -j "$(nproc)" > /dev/null
ffmpeg -nostdin -v error -y -i "$clip" -vf format=gray -f rawvideo "$build/clip-320x240.y8"
# The same frames as a YUV4MPEG2 file for the y4m fake camera, written here: a minimal FFmpeg build may lack the
# yuv4mpegpipe muxer. The clip is 320 x 240 at 15 frames a second (painted-head-12s.txt).
python3 - "$build/clip-320x240.y8" "$build/clip.y4m" <<'PY'
import sys
frame = 320 * 240
data = open(sys.argv[1], 'rb').read()
with open(sys.argv[2], 'wb') as out:
    out.write(b'YUV4MPEG2 W320 H240 F15:1 Ip A1:1 Cmono\n')
    for start in range(0, len(data) - frame + 1, frame):
        out.write(b'FRAME\n')
        out.write(data[start:start + frame])
PY
TMPDIR="$build" "$build/ht_core_test" "$build/clip-320x240.y8" 320 240 "$build/clip.y4m" "$track"
