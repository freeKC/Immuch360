#!/bin/bash
# immuch360-run on macOS (lot L10 of the desktop parity plan, 21 November 2026): the launcher of the programs of the
# app, .github/desktop/ai/immuch360_run.c, which a watcher of its own makes die with the app. Run by the macOS jobs of
# immuch360-desktop.yml on the launcher they built and on the one of the app bundle:
#   - its own exit codes: 2 without a program, 125 when the app given is not its parent, 127 without such a program;
#   - a program that ends by itself takes its watcher with it, and its output reaches the app;
#   - a stand-in for the app (a shell) killed with SIGKILL while the program (sleep) runs under the launcher: the
#     program must be gone within a second, and its watcher with it.
#
#   check_launcher.sh LAUNCHER
set -u
launcher=$1
work=$(mktemp -d)
failed=0

fail() {
  echo "::error::immuch360-run: $*"
  failed=1
}

watchers() {
  ps -axo pid=,comm= | awk '/immuch360-run$/ {print $1}'
}

status=0
"$launcher" --parent $$ > /dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "without a program: exit $status, 2 expected"
status=0
"$launcher" --parent 1 -- /bin/echo never > /dev/null 2>&1 || status=$?
[ "$status" -eq 125 ] || fail "with an app that is not its parent: exit $status, 125 expected"
status=0
"$launcher" --parent $$ -- "$work/no-such-program" > /dev/null 2>&1 || status=$?
[ "$status" -eq 127 ] || fail "without such a program: exit $status, 127 expected"

before=$(watchers | wc -l | tr -d ' ')
said=$("$launcher" --parent $$ --nice 10 -- /bin/echo said)
[ "$said" = said ] || fail "the output of the program: '$said'"
sleep 1
after=$(watchers | wc -l | tr -d ' ')
[ "$after" -le "$before" ] || fail "a watcher is left after its program ended ($before before, $after after)"

# The stand-in for the app: a shell that starts the launcher as its own child, writes the id of the program, waits
sh -c '"$2" --parent $$ --nice 10 -- /bin/sleep 300 & echo $! > "$1.part"; mv "$1.part" "$1"; wait' \
  sh "$work/program.pid" "$launcher" &
app=$!
for _ in $(seq 1 100); do
  [ -s "$work/program.pid" ] && break
  sleep 0.1
done
program=$(cat "$work/program.pid" 2>/dev/null || true)
if [ -z "$program" ]; then
  fail "the stand-in for the app never started the program"
else
  sleep 0.5
  name=$(ps -p "$program" -o comm= | tr -d ' ')
  case "$name" in
    */sleep | sleep) ;;
    *) fail "the program runs as '$name', /bin/sleep expected (execv keeps its id)" ;;
  esac
  nice=$(ps -p "$program" -o nice= | tr -d ' ')
  [ "$nice" = 10 ] || fail "the program runs at nice '$nice', 10 expected"
  [ "$(watchers | wc -l | tr -d ' ')" -gt "$after" ] || fail "no watcher runs beside the program"
  start=$(python3 -c 'import time; print(time.monotonic())')
  kill -KILL "$app"
  wait "$app" 2> /dev/null
  gone=
  for _ in $(seq 1 50); do
    if ! kill -0 "$program" 2> /dev/null; then
      gone=$(python3 -c "import time; print(round(time.monotonic() - $start, 3))")
      break
    fi
    sleep 0.02
  done
  if [ -z "$gone" ]; then
    kill -KILL "$program" 2> /dev/null
    fail "the program $program outlived the app by more than a second"
  else
    echo "the app killed: the program was gone after $gone s"
  fi
  sleep 0.5
  left=$(watchers | wc -l | tr -d ' ')
  [ "$left" -le "$before" ] || fail "a watcher is left after the app and its program ($left running)"
fi

if [ "$failed" -eq 0 ]; then
  echo "immuch360-run ($launcher): exit codes 2, 125 and 127, the output, nice 10, the program and its watcher gone with the app"
fi
exit "$failed"
