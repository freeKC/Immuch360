#!/bin/sh
# Immuch360 Desktop on Linux plays a video: the app is started with a short clip as a file opened with the program, on
# the X display of the caller (a virtual screen of xvfb-run), and
#   - it still runs once the clip played for 5 seconds;
#   - its picture changes at each of three captures 2.5 seconds apart (the clip, 6 seconds of FFmpeg's testsrc with a
#     running clock, loops in the viewer), within 45 seconds of the start. The clip is H.264 Constrained Baseline with
#     one reference frame, which every distribution decodes: Fedora's FFmpeg has no H.264 decoder of its own and goes
#     through OpenH264, which refuses the Main and High profiles of most cameras (RPM Fusion's FFmpeg decodes them);
#   - media_kit_video made a video output for the player (its line "VideoOutput: H/W rendering" or "S/W rendering");
#   - neither media_kit_video nor the app's log (its database, read with sqlite3) holds an error of the players or of
#     libmpv: a libmpv that did not load, an output without libmpv, a warning of the loggers of the desktop video code.
#
#   xvfb-run -a -s "-screen 0 1280x800x24" sh video_smoke.sh APP CLIP OUT_DIR
#
# APP is the executable of a build (bundle/immuch360) or the launcher of a package (immuch360), CLIP a path to the
# clip (mobile/test/fixtures/video/flat-6s.mp4), OUT_DIR receives the output of the app, the lines of its log and,
# after a failure, the last capture. Needs xwd (x11-apps on Debian and Ubuntu, xwd on Fedora) and sqlite3; ImageMagick,
# when there, captures the screen as screen.png; gdb and xwininfo, when there, tell what a start that does not get on
# was doing. Exit 1 when a check fails.
#
# The app runs in a home of its own, so that its log is the one of this run, and twice: a file opened with the program
# waits for a session (lib/desktop/files/open_files.dart), and a new home has none, so a first start without the clip
# makes the databases, then the session without a server is written in the store as the welcome page writes it
# (StoreKey.localSession, 5003, in store_entity) and the second start opens the clip. Its output is line buffered
# (stdbuf), so that the lines of the native code are there when it is stopped.
#
# A start that a signal ends (a crash) before the app got on is made once more, each of the two starts once at most,
# after its stack is printed: the core the kernel wrote (the desktop workflow points the runner's core_pattern at
# /tmp/core.<pid>, a file of the container, and lifts the container's core limit) read by gdb. Fedora 40 crashed
# both starts of a container on a few runners, under software rendering, before any video, and passed on the next
# attempt of the job (desktop runs 39620217077 and 39631747676). Only the start is made again, never the video
# check: once the app runs with the clip, or a video output was made, a crash is a failure.
set -eu
# The core of a crash, where the limit of the container allows it
ulimit -c unlimited 2>/dev/null || true

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
# The window on the virtual screen, even where a Wayland display is set (WSLg)
export GDK_BACKEND=x11
unset WAYLAND_DISPLAY
# No session bus, as in a container: the bus of a CI runner answers neither the accessibility bus nor the secret
# service, and each costs the start 25 seconds of D-Bus timeout. Without one, each start runs on its own
# (my_application.cc) and libsecret fails at once
export DBUS_SESSION_BUS_ADDRESS="unix:path=$home/no-session-bus"

failed=0
fail() {
  echo "  FAILED: $1"
  failed=1
}

pid=
start() {
  log=$1
  shift
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL "$app" "$@" >"$log" 2>&1 &
  else
    "$app" "$@" >"$log" 2>&1 &
  fi
  pid=$!
}

stop() {
  kill "$pid" 2>/dev/null || true
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 10 ]; do
    sleep 0.5
    waited=$((waited + 1))
  done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# The checksum of the pixels of an xwd capture: its header and its colormap differ between two captures of the same
# screen (bytes xwd leaves as they were), its pixels do not. Height at byte 20, bytes per line at byte 48, big endian
pixels() {
  # shellcheck disable=SC2046
  set -- "$1" $(od -An -tu1 -j20 -N4 "$1") $(od -An -tu1 -j48 -N4 "$1")
  tail -c $(((($2 << 24) + ($3 << 16) + ($4 << 8) + $5) * (($6 << 24) + ($7 << 16) + ($8 << 8) + $9))) "$1" | cksum
}

# The program a core belongs to: the launcher of a package execs it (/opt/immuch360/immuch360)
binary=$(command -v "$app" || echo "$app")
if [ "$(head -c 2 "$binary" 2>/dev/null)" = '#!' ]; then
  binary=$(sed -n 's/^exec \([^ ]*\) .*/\1/p' "$binary" | head -n 1)
fi

# The stack of a start that a signal ended, from its core: the threads (the crashed one marked *) and the frames of
# the crashed one, each with its library, which tells Mesa's software renderer from the engine or the app's plugins
crash_report() {
  signal=$(($1 - 128))
  echo "  the app was ended by signal $signal ($(kill -l "$signal" 2>/dev/null || echo unknown))"
  core=
  for candidate in "/tmp/core.$pid" "core.$pid" core; do
    if [ -f "$candidate" ]; then
      core=$candidate
      break
    fi
  done
  if [ -z "$core" ]; then
    echo "  no core (core_pattern $(cat /proc/sys/kernel/core_pattern 2>/dev/null), core limit $(ulimit -c))"
  elif command -v gdb >/dev/null 2>&1; then
    gdb -q -batch -ex 'info threads' -ex 'bt 40' "$binary" "$core" 2>/dev/null \
      | grep -E '^(\*|#|Program terminated)' | head -n 80 | cut -c1-220 | sed 's/^/  | /' || true
  else
    echo "  a core, but no gdb to read it"
  fi
  [ -z "$core" ] || rm -f "$core"
}

# The exit status of the app once it no longer runs, read once, with the stack of a crash
ended=
collect() {
  if [ -z "$ended" ]; then
    ended=0
    wait "$pid" || ended=$?
    if [ "$ended" -gt 128 ]; then
      crash_report "$ended"
    fi
  fi
}

# What a start that does not get on was doing: the state of its threads, its windows, the files of its home
diagnose() {
  echo "-- what the app was doing"
  # The launcher of a package execs the program: the same process
  for task in /proc/"$pid"/task/*; do
    [ -d "$task" ] || continue
    printf '  | thread %s, state %s, waiting in %s\n' "$(cat "$task/comm" 2>/dev/null)" \
      "$(cut -d ' ' -f 3 "$task/stat" 2>/dev/null)" "$(cat "$task/wchan" 2>/dev/null)"
  done
  if command -v gdb >/dev/null 2>&1; then
    debugger=gdb
    [ "$(id -u)" -eq 0 ] || debugger="sudo -n gdb"
    $debugger -p "$pid" -batch -ex 'thread apply all bt 15' 2>/dev/null | grep -E '^(Thread|#)' | head -n 120 \
      | cut -c1-200 | sed 's/^/  | /' || true
  fi
  if command -v xwininfo >/dev/null 2>&1; then
    xwininfo -root -tree 2>/dev/null | grep -v '^\s*$' | head -n 20 | sed 's/^/  | /' || true
  fi
  find "$home" -maxdepth 5 | head -n 40 | sed 's/^/  | /'
}

echo "-- a first start, which makes the databases"
attempt=1
while :; do
  start "$out/first-start.log"
  ended=
  database=
  waited=0
  while [ "$waited" -lt 60 ] && kill -0 "$pid" 2>/dev/null; do
    database=$(find "$home" -name immich.sqlite 2>/dev/null | head -n 1)
    if [ -n "$database" ] && sqlite3 "$database" 'SELECT count(*) FROM store_entity' >/dev/null 2>&1; then
      break
    fi
    database=
    sleep 1
    waited=$((waited + 1))
  done
  if [ -n "$database" ]; then
    echo "  $(echo "$database" | sed "s|^$home|~|") after $waited seconds"
    # The start goes on to its first page before it stops
    sleep 5
  fi
  if kill -0 "$pid" 2>/dev/null; then
    break
  fi
  collect
  if [ "$attempt" -eq 1 ] && [ "$ended" -gt 128 ]; then
    echo "  the first start crashed: made once more in an empty home (the start only)"
    mv "$out/first-start.log" "$out/first-start-crashed.log"
    find "$home" -mindepth 1 -delete
    attempt=2
    continue
  fi
  break
done
if [ -z "$database" ] || ! kill -0 "$pid" 2>/dev/null; then
  if kill -0 "$pid" 2>/dev/null; then
    fail "no database with its store after $waited seconds"
    diagnose
  else
    fail "the app ended by itself (exit $ended)"
  fi
  stop
  tail -n 40 "$out/first-start.log" | sed 's/^/  > /'
  rm -rf "$home"
  exit 1
fi
stop
sqlite3 "$database" 'INSERT OR REPLACE INTO store_entity (id, string_value, int_value) VALUES (5003, NULL, 1)'
echo "  the session without a server is set"

echo "-- $(basename "$app") $(basename "$clip")"
attempt=1
while :; do
  start "$out/output.log" "$clip"
  ended=
  echo "  pid $pid"
  # Captures every 2.5 seconds from the sixth second, 16 at most: three in a row, each different from the one
  # before, make 5 seconds of a moving picture
  sleep 6
  if kill -0 "$pid" 2>/dev/null; then
    break
  fi
  collect
  if [ "$attempt" -eq 1 ] && [ "$ended" -gt 128 ] && ! grep -q 'VideoOutput:' "$out/output.log"; then
    echo "  the start with the clip crashed before any video output: made once more (the start only)"
    mv "$out/output.log" "$out/output-crashed.log"
    attempt=2
    continue
  fi
  break
done
changes=0
count=0
xwd -root -silent >"$out/capture-0.xwd"
while [ "$changes" -lt 2 ] && [ "$count" -lt 16 ] && kill -0 "$pid" 2>/dev/null; do
  sleep 2.5
  count=$((count + 1))
  xwd -root -silent >"$out/capture-$count.xwd"
  if [ "$(pixels "$out/capture-$((count - 1)).xwd")" = "$(pixels "$out/capture-$count.xwd")" ]; then
    changes=0
    echo "  capture $count: the same picture"
  else
    changes=$((changes + 1))
    echo "  capture $count: another picture"
  fi
done

if kill -0 "$pid" 2>/dev/null; then
  echo "  the app runs after $count captures"
  if command -v import >/dev/null 2>&1; then
    import -window root "$out/screen.png" && echo "  screen.png captured while the clip plays"
  fi
  if [ "$changes" -lt 2 ]; then
    diagnose
  fi
  # The app writes its log to its database every 5 seconds: the lines of the playback reach it before the stop
  sleep 6
else
  collect
  fail "the app ended by itself (exit $ended)"
fi
if [ "$changes" -ge 2 ]; then
  echo "  the picture changed at each of the last three captures, 2.5 seconds apart"
else
  fail "the picture did not change at three captures in a row ($count captures)"
fi
stop

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
logs=$(find "$home" -name immich_logs.sqlite | head -n 1)
if [ -z "$logs" ]; then
  fail "no log database under $home"
else
  # level: the index of LogLevel (mobile/lib/domain/models/log.model.dart), 6 warning, 7 severe, 8 shout; the
  # error of a line (details) follows its message
  tab=$(printf '\t')
  sqlite3 -separator "$tab" "$logs" \
    "SELECT level, coalesce(logger, ''), replace(message || coalesce(': ' || details, ''), char(10), ' ')
     FROM logger_messages ORDER BY id" >"$out/log.txt"
  echo "  $(wc -l <"$out/log.txt") lines; warnings and errors:"
  awk -F '\t' '$1 >= 6' "$out/log.txt" | cut -c1-300 | sed 's/^/  | /'
  # Whether the clip reached the viewer: a build that loses the session without a server at the second start shows
  # the welcome page instead (its log says "Missing crucial offline login info"), whose animation changes the picture
  if grep -q 'Opened 1 files with the program' "$out/log.txt"; then
    echo "  the app opened the clip (OpenFiles)"
  else
    echo "  (information) the log does not say that the app opened the clip: the picture may be another page's"
  fi
  video_loggers='DesktopVideo|DesktopPlayer|PlayerPool|DesktopVideoController|VideoThumbnailGrabber'
  video_loggers="$video_loggers|OpenedFiles|OpenFiles"
  if awk -F '\t' -v loggers="^($video_loggers)\$" '$1 >= 6 && $2 ~ loggers {found = 1} END {exit !found}' \
    "$out/log.txt"; then
    fail "the video code logged a warning or an error"
  fi
fi

rm -rf "$home"
if [ "$failed" -eq 1 ]; then
  # The captures stay for a look when something failed (a few hundred kilobytes each once zipped)
  if command -v convert >/dev/null 2>&1 && [ ! -f "$out/screen.png" ]; then
    convert "xwd:$out/capture-$count.xwd" "$out/screen.png" || true
  fi
  tail -n 40 "$out/output.log" | sed 's/^/  > /'
  exit 1
fi
rm -f "$out"/capture-*.xwd
echo "  the clip played"
