#!/usr/bin/env bash
# The tests of the Android lab workflow (immuch360-android-lab.yml), run by the emulator action once the emulator of
# the runner is up, from the root of the repository: debug.checkjni set, logcat recorded, the fake Immich server of the
# lab tests started on the runner (fake_immich.py, port 2283, which the emulator reaches at 10.0.2.2 and which runs the
# LAB_HOST commands of the tests), then the stress test of the vendored ok_http (required), upstream's background sync
# teardown test (reported only), the lab smoke test and the background run test (required); then the fake server again,
# answering as a server set to JPEG XL thumbnails and previews (--image-format jxl, its records in the jxl folder), for
# the JPEG XL test (required); and at the end logcat read by check_logcat.py, whose verdict is the result of the step: a
# crash, an ANR or a death of the app in any scenario fails it, and so does a "Not decoded" line of the app in a jxl
# scenario. Never on a device of the owner.
set -uo pipefail

serial=emulator-5554
app=com.aprogsys.immuch360.debug
port=2283
out="${RUNNER_TEMP:-/tmp}/android-lab"
adb="${ANDROID_HOME:?}/platform-tools/adb"
mkdir -p "$out"
: > "$out/results.txt"

"$adb" -s "$serial" shell setprop debug.checkjni 1
echo "debug.checkjni=$("$adb" -s "$serial" shell getprop debug.checkjni | tr -d '\r')"
"$adb" -s "$serial" logcat -c || true
"$adb" -s "$serial" logcat -v threadtime > "$out/logcat.txt" 2>&1 &
logcat=$!

# The fake Immich server in the format of thumbnails $1 (jpeg or jxl), its records in the folder $2, its output in the
# file $3; returns once it answers
start_server() {
  local format=$1 records=$2 output=$3
  mkdir -p "$records"
  python3 .github/android-lab/fake_immich.py --port "$port" --fixtures mobile/test/fixtures/android_lab \
    --spec open-api/immich-openapi-specs.json --out "$records" --adb "$adb" --serial "$serial" --package "$app" \
    --image-format "$format" > "$output" 2>&1 &
  server=$!
  for _ in $(seq 1 40); do
    curl -sf -o /dev/null "http://127.0.0.1:$port/lab/state" && break
    sleep 0.5
  done
  cat "$output"
}

# The state of the fake server saved to the file $1, then the server stopped and the port free again
stop_server() {
  curl -sf "http://127.0.0.1:$port/lab/state" > "$1" || true
  kill "$server" 2>/dev/null || true
  wait "$server" 2>/dev/null || true
  for _ in $(seq 1 20); do
    curl -sf -o /dev/null "http://127.0.0.1:$port/lab/state" || break
    sleep 0.5
  done
}

start_server jpeg "$out" "$out/server.txt"

# One test file: its output kept, its exit status written as name=status
run() {
  local name=$1 file=$2 status=0 started=$SECONDS
  echo "::group::$name ($file)"
  (cd mobile && mise exec -- flutter test "$file" -d "$serial" --flavor phone --reporter expanded) 2>&1 \
    | tee "$out/$name.txt" || status=$?
  echo "::endgroup::"
  echo "$name: exit status $status, $((SECONDS - started)) s"
  echo "$name=$status" >> "$out/results.txt"
}

run stress integration_test/ok_http_receiver_stress_test.dart
run teardown integration_test/background_sync_teardown_test.dart
run smoke integration_test/lab_server_smoke_test.dart
run background integration_test/lab_background_worker_test.dart
stop_server "$out/server-state.json"

start_server jxl "$out/jxl" "$out/server-jxl.txt"
run jxl integration_test/lab_jxl_server_test.dart
stop_server "$out/server-jxl-state.json"

sleep 3
kill "$logcat" 2>/dev/null || true
wait "$logcat" 2>/dev/null || true

python3 .github/android-lab/check_logcat.py --app "$app" --results "$out/results.txt" \
  --required stress --required smoke --required background --required jxl \
  --scenarios redirect,timeline,originals,native-decode,upload,background-end,background-cancel \
  --scenarios jxl-grid,jxl-viewer,jxl-360,jxl-native-decode --not-decoded jxl- \
  --out "$out" "$out/logcat.txt"
