#!/bin/sh
# Immuch360 Desktop on Linux shows a Gaussian splat (the splat viewer of the computers, review of 2 November 2026): the
# app is started with a small .spz as a file opened with the program, on the X display of the caller (a virtual screen
# of xvfb-run), and
#   - the splat opens in the viewer at once, as a tap on a splat does: a WebKitGTK window of the patched copy of
#     desktop_webview_window (mobile/packages/desktop_webview_window), its page served by the app's media bridge;
#   - the page says ready within 120 seconds, with some lit pixels (the app's log: "Ready: <name> ... non blank N",
#     logger SplatViewer, read from its database with sqlite3), and the app still runs;
#   - the page said nothing else went wrong: no "cannot show splats" (WebGL 2 or WebAssembly SIMD missing in this
#     WebKitGTK), no error of the page, no catch all error of the app.
# The renderer the page drew with (Mesa's software renderer on a virtual screen) and its time to ready are printed; the
# screen is captured as screen.png when ImageMagick is there. Software rendering only: no frame rate is claimed.
#
#   xvfb-run -a -s "-screen 0 1280x800x24" sh splat_smoke.sh APP SPLAT OUT_DIR
#
# APP is the executable of a build (bundle/immuch360) or the launcher of a package (immuch360), SPLAT a path to a small
# splat (mobile/test/fixtures/splat_viewer/room_floor.spz), OUT_DIR receives the output of the app, the lines of its
# log and the capture. Needs xwd and sqlite3. Exit 1 when a check fails.
#
# As video_smoke.sh: the app runs in a home of its own, twice (a file opened with the program waits for a session, so
# a first start makes the databases and the session without a server is written in the store), line buffered, without
# a session bus; a first start that a signal ends is made once more.
set -eu

app=$1
splat=$2
out=$3
[ -f "$splat" ] || { echo "no splat at $splat"; exit 1; }
[ -n "${DISPLAY:-}" ] || { echo "no X display: run under xvfb-run"; exit 1; }
mkdir -p "$out"
out=$(cd "$out" && pwd)
home=$(mktemp -d)
export HOME="$home"
export XDG_DATA_HOME="$home/.local/share" XDG_CONFIG_HOME="$home/.config" XDG_CACHE_HOME="$home/.cache"
export LIBGL_ALWAYS_SOFTWARE=1
export GDK_BACKEND=x11
unset WAYLAND_DISPLAY
export DBUS_SESSION_BUS_ADDRESS="unix:path=$home/no-session-bus"
# The splat is copied into the home: the app opens it where it is, read only
cp "$splat" "$home/"
splat="$home/$(basename "$splat")"
name=$(basename "$splat")

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

# Its own count of half seconds: the waits of the checks keep theirs
stop() {
  kill "$pid" 2>/dev/null || true
  halves=0
  while kill -0 "$pid" 2>/dev/null && [ "$halves" -lt 10 ]; do
    sleep 0.5
    halves=$((halves + 1))
  done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# The app's log in its database, one line per message: level, logger, message and its details. level is the index of
# LogLevel (mobile/lib/domain/models/log.model.dart): 6 warning, 7 severe, 8 shout
log_lines() {
  logs=$(find "$home" -name immich_logs.sqlite 2>/dev/null | head -n 1)
  [ -n "$logs" ] || return 0
  tab=$(printf '\t')
  sqlite3 -separator "$tab" "$logs" \
    "SELECT level, coalesce(logger, ''), replace(message || coalesce(': ' || details, ''), char(10), ' ')
     FROM logger_messages ORDER BY id" 2>/dev/null || true
}

echo "-- a first start, which makes the databases"
attempt=1
while :; do
  start "$out/first-start.log"
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
    sleep 5
  fi
  if kill -0 "$pid" 2>/dev/null; then
    break
  fi
  ended=0
  wait "$pid" || ended=$?
  if [ "$attempt" -eq 1 ] && [ "$ended" -gt 128 ]; then
    echo "  the first start was ended by signal $((ended - 128)): made once more in an empty home (the start only)"
    mv "$out/first-start.log" "$out/first-start-crashed.log"
    find "$home" -mindepth 1 -maxdepth 1 ! -name "$name" -exec rm -rf {} +
    attempt=2
    continue
  fi
  break
done
if [ -z "$database" ] || ! kill -0 "$pid" 2>/dev/null; then
  fail "no database with its store after $waited seconds, or the app ended"
  stop
  tail -n 40 "$out/first-start.log" | sed 's/^/  > /'
  rm -rf "$home"
  exit 1
fi
stop
sqlite3 "$database" 'INSERT OR REPLACE INTO store_entity (id, string_value, int_value) VALUES (5003, NULL, 1)'
echo "  the session without a server is set"

echo "-- $(basename "$app") $name"
start "$out/output.log" "$splat"
echo "  pid $pid"
# The app writes its log to its database every 5 seconds
ready=
waited=0
while [ "$waited" -lt 120 ] && kill -0 "$pid" 2>/dev/null; do
  sleep 2
  waited=$((waited + 2))
  log_lines >"$out/log.txt"
  ready=$(awk -F '\t' -v name="$name" '$2 == "SplatViewer" && index($3, "Ready: " name " ") == 1' "$out/log.txt" \
    | head -n 1)
  [ -z "$ready" ] || break
  if awk -F '\t' '$2 == "SplatViewer" && $1 >= 6' "$out/log.txt" | grep -q 'cannot show splats\|The splat viewer page:'
  then
    break
  fi
done
if kill -0 "$pid" 2>/dev/null; then
  if command -v xwd >/dev/null 2>&1; then
    xwd -root -silent >"$out/screen.xwd" || true
  fi
  # The lines of the last seconds reach the database before the stop
  sleep 6
  log_lines >"$out/log.txt"
  running=yes
else
  running=no
fi
stop

echo "-- the splat viewer (the app's log)"
awk -F '\t' '$2 == "SplatViewer" || $2 == "SplatViewerWindow" || $2 == "SplatPage" || $2 == "SplatViewerLaunch"' \
  "$out/log.txt" | cut -f 3 | cut -c1-300 | sed 's/^/  | /'
if [ -n "$ready" ]; then
  message=$(printf '%s' "$ready" | cut -f 3)
  # "Ready: room_floor.spz 2345 ms, 2000 gaussians, <renderer>, non blank 0.42, 1280x800, {...}"
  load=$(printf '%s' "$message" | sed -n 's/^Ready: [^ ]* \([0-9]*\) ms.*/\1/p')
  lit=$(printf '%s' "$message" | sed -n 's/.*, non blank \([0-9.]*\),.*/\1/p')
  echo "  ready in ${load:-?} ms after the page opened, after about $waited seconds from the start, lit ${lit:-?}"
  case "$lit" in
    '' | 0 | 0.0) fail "the page said ready with nothing lit" ;;
  esac
else
  fail "the page did not say ready within 120 seconds"
  echo "  (WebKitGTK and some NVIDIA drivers: WEBKIT_DISABLE_DMABUF_RENDERER=1; here a virtual screen without a GPU)"
fi
[ "$running" = yes ] || fail "the app ended by itself"
if awk -F '\t' '$2 == "SplatViewer" && $1 >= 6' "$out/log.txt" | grep -q 'cannot show splats'; then
  fail "the web view of this system cannot show splats (WebGL 2 or WebAssembly SIMD)"
fi
if awk -F '\t' '$2 == "SplatViewer" && $1 >= 6' "$out/log.txt" | grep -q 'The splat viewer page:'; then
  fail "the page reported an error"
fi
if awk -F '\t' '$1 >= 7' "$out/log.txt" | grep -q 'Catch all'; then
  fail "an error reached the app's catch all"
  awk -F '\t' '$1 >= 7' "$out/log.txt" | cut -c1-300 | sed 's/^/  | /'
fi
echo "-- the output of the app (WebKit's lines)"
grep -i 'webkit\|egl\|dmabuf\|gbm' "$out/output.log" | head -n 20 | cut -c1-200 | sed 's/^/  | /' || true

if [ -f "$out/screen.xwd" ] && command -v convert >/dev/null 2>&1; then
  convert "xwd:$out/screen.xwd" "$out/screen.png" && rm -f "$out/screen.xwd" && echo "  screen.png captured"
fi
rm -rf "$home"
if [ "$failed" -eq 1 ]; then
  tail -n 40 "$out/output.log" | sed 's/^/  > /'
  exit 1
fi
echo "  the splat showed"
