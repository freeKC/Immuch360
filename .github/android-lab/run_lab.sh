#!/usr/bin/env bash
# The tests of the Android lab workflow (immuch360-android-lab.yml), run by the emulator action once the emulator of
# the runner is up, from the root of the repository: debug.checkjni set, logcat recorded, the stress test of the
# vendored ok_http (required), upstream's background sync teardown test (reported only), then logcat read for a crash
# of the app by check_logcat.py, whose verdict is the result of the step. Never on a device of the owner.
set -uo pipefail

serial=emulator-5554
app=com.aprogsys.immuch360.debug
out="${RUNNER_TEMP:-/tmp}/android-lab"
adb="${ANDROID_HOME:?}/platform-tools/adb"
mkdir -p "$out"
: > "$out/results.txt"

"$adb" -s "$serial" shell setprop debug.checkjni 1
echo "debug.checkjni=$("$adb" -s "$serial" shell getprop debug.checkjni | tr -d '\r')"
"$adb" -s "$serial" logcat -c || true
"$adb" -s "$serial" logcat -v threadtime > "$out/logcat.txt" 2>&1 &
logcat=$!

# One test file: its output kept, its exit status written as name=status
run() {
  local name=$1 file=$2 status=0
  echo "::group::$name ($file)"
  (cd mobile && mise exec -- flutter test "$file" -d "$serial" --flavor phone --reporter expanded) 2>&1 \
    | tee "$out/$name.txt" || status=$?
  echo "::endgroup::"
  echo "$name: exit status $status"
  echo "$name=$status" >> "$out/results.txt"
}

run stress integration_test/ok_http_receiver_stress_test.dart
run teardown integration_test/background_sync_teardown_test.dart

sleep 3
kill "$logcat" 2>/dev/null || true
wait "$logcat" 2>/dev/null || true

python3 .github/android-lab/check_logcat.py --app "$app" --results "$out/results.txt" --required stress \
  --out "$out" "$out/logcat.txt"
