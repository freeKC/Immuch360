#!/bin/sh
# Immuch360 Desktop on Linux plays a video: the app is started with a short clip as a file opened with the program, on
# the X display of the caller (a virtual screen of xvfb-run), and
#   - it still runs once the clip played for 5 seconds;
#   - its picture changes at each of three captures 2.5 seconds apart (the clip, 6 seconds of FFmpeg's testsrc with a
#     running clock, loops in the viewer), within 45 seconds of the start;
#   - media_kit_video made a video output for the player (its line "VideoOutput: H/W rendering" or "S/W rendering");
#   - neither media_kit_video nor the app's log (its database, read with sqlite3) holds an error of the players or of
#     libmpv: a libmpv that did not load, an output without libmpv, a warning of the loggers of the desktop video code.
#
#   xvfb-run -a -s "-screen 0 1280x800x24" sh video_smoke.sh APP CLIP OUT_DIR
#
# APP is the executable of a build (bundle/immuch360) or the launcher of a package (immuch360), CLIP a path to the
# clip (mobile/test/fixtures/video/flat-6s.mp4), OUT_DIR receives the output of the app, the captures and the lines of
# its log. Needs xwd (x11-apps on Debian and Ubuntu, xwd on Fedora) and sqlite3; ImageMagick, when there, turns the last
# capture into screen.png. The app runs in a home of its own, so that its log is the one of this start. Exit 1 when a
# check fails.
set -eu

app=$1
clip=$2
out=$3
[ -f "$clip" ] || { echo "no clip at $clip"; exit 1; }
[ -n "${DISPLAY:-}" ] || { echo "no X display: run under xvfb-run"; exit 1; }
mkdir -p "$out"
out=$(cd "$out" && pwd)
home=$(mktemp -d)
export HOME="$home"
export XDG_DATA_HOME="$home/.local/share" XDG_CONFIG_HOME="$home/.config" XDG_CACHE_HOME="$home/.cache"
# Software rendering, as on a computer without a GPU driver
export LIBGL_ALWAYS_SOFTWARE=1

"$app" "$clip" >"$out/output.log" 2>&1 &
pid=$!
echo "-- $app $(basename "$clip") (pid $pid)"

stop() {
  kill "$pid" 2>/dev/null || true
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 10 ]; do
    sleep 0.5
    waited=$((waited + 1))
  done
  kill -9 "$pid" 2>/dev/null || true
}

failed=0
fail() {
  echo "  FAILED: $1"
  failed=1
}

# Captures every 2.5 seconds from the sixth second, 16 at most: three in a row, each different from the one before,
# make 5 seconds of a moving picture
sleep 6
changes=0
count=0
xwd -root -silent >"$out/capture-0.xwd"
while [ "$changes" -lt 2 ] && [ "$count" -lt 16 ] && kill -0 "$pid" 2>/dev/null; do
  sleep 2.5
  count=$((count + 1))
  xwd -root -silent >"$out/capture-$count.xwd"
  if cmp -s "$out/capture-$((count - 1)).xwd" "$out/capture-$count.xwd"; then
    changes=0
  else
    changes=$((changes + 1))
  fi
done

if kill -0 "$pid" 2>/dev/null; then
  echo "  the app runs after $count captures"
  # The app writes its log to its database every 5 seconds: the lines of the playback reach it before the stop
  sleep 6
else
  status=0
  wait "$pid" || status=$?
  fail "the app ended by itself (exit $status)"
fi
if [ "$changes" -ge 2 ]; then
  echo "  the picture changed at each of the last three captures, 2.5 seconds apart"
else
  fail "the picture did not change at three captures in a row ($count captures)"
fi
stop

if command -v convert >/dev/null 2>&1; then
  convert "xwd:$out/capture-$count.xwd" "$out/screen.png" && echo "  last capture: screen.png"
fi
# The captures stay for a look only when something failed
[ "$failed" -eq 1 ] || rm -f "$out"/capture-*.xwd

echo "-- the output of the app (media_kit_video's lines)"
grep -i 'media_kit' "$out/output.log" | sed 's/^/  | /' | head -n 20 || true
if grep -q 'VideoOutput: \(H/W\|S/W\) rendering' "$out/output.log"; then
  echo "  a video output was made for the player"
else
  fail "no video output in the output of the app"
fi
if grep -q 'libmpv is missing\|libmpv could not be opened\|libmpv has no' "$out/output.log"; then
  fail "media_kit_video found no usable libmpv"
fi

echo "-- the log of the app"
database=$(find "$home" -name immich_logs.sqlite | head -n 1)
if [ -z "$database" ]; then
  fail "no log database under $home"
else
  # level: the index of LogLevel (mobile/lib/domain/models/log.model.dart), 6 warning, 7 severe, 8 shout
  tab=$(printf '\t')
  sqlite3 -separator "$tab" "$database" \
    "SELECT level, coalesce(logger, ''), replace(message, char(10), ' ') FROM logger_messages ORDER BY id" \
    >"$out/log.txt"
  echo "  $(wc -l <"$out/log.txt") lines; warnings and errors:"
  awk -F '\t' '$1 >= 6' "$out/log.txt" | cut -c1-240 | sed 's/^/  | /'
  video_loggers='DesktopVideo|DesktopPlayer|PlayerPool|DesktopVideoController|VideoThumbnailGrabber'
  video_loggers="$video_loggers|OpenedFiles|OpenFiles"
  if awk -F '\t' -v loggers="^($video_loggers)\$" '$1 >= 6 && $2 ~ loggers {found = 1} END {exit !found}' \
    "$out/log.txt"; then
    fail "the video code logged a warning or an error"
  fi
fi

rm -rf "$home"
[ "$failed" -eq 0 ] || { tail -n 40 "$out/output.log" | sed 's/^/  > /'; exit 1; }
echo "  the clip played"
