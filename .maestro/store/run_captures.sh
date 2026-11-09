#!/bin/bash
# App Store captures of Immuch360 on an iOS simulator (workflow immuch360-ios-captures.yml, job capture).
#
# usage: run_captures.sh iphone|ipad en|fr APP MEDIA OUT
#   APP    the simulator build (Runner.app, debug, --dart-define=IMMUCH_SCREENSHOTS=true)
#   MEDIA  what media.py wrote: library/ (added to the photo library) and nas/ (served over WebDAV)
#   OUT    the captures: Maestro's screenshots and the simulator's own after each flow, the record of the device,
#          the logs
#
# A new simulator of the newest iOS runtime (iPhone 17 Pro Max, 1320 x 2868, or iPad Pro 13-inch, 2064 x 2752), in the
# language of the run, dark appearance, status bar at 9:41 with a full battery. The app is installed, the photo
# library filled, the share served on 127.0.0.1:8765 (read only, no password), then the flows of this folder run in
# order. A flow that fails leaves what it captured; the next ones still run.
set -uo pipefail

KIND=$1
LANG_CODE=$2
APP=$3
MEDIA=$4
OUT=$5
HERE=$(cd "$(dirname "$0")" && pwd)
BUNDLE=com.aprogsys.immuch360.dev.debug
mkdir -p "$OUT/maestro" "$OUT/sim" "$OUT/logs"
OUT=$(cd "$OUT" && pwd)

case "$LANG_CODE" in
  en) LANGS=en-US; LOCALE=en_US; SHARE_NAME="Home NAS"; HOLIDAYS=Holidays; FILMS=Films; FILM="Lighthouse at sunset" ;;
  fr) LANGS=fr-FR; LOCALE=fr_FR; SHARE_NAME="Mon NAS"; HOLIDAYS=Vacances; FILMS=Films; FILM="Phare au coucher du soleil" ;;
  *) echo "language en or fr, not $LANG_CODE"; exit 2 ;;
esac
case "$KIND" in
  iphone) TYPES="iPhone 17 Pro Max|iPhone 16 Pro Max"; SIZE=1320x2868
          LIST_TILE="12%,63%"; FACE="92%,9%"; SEEK_FROM="6%,89%"; SEEK_TO="58%,89%" ;;
  ipad)   TYPES="iPad Pro 13-inch (M5)|iPad Pro 13-inch (M4)"; SIZE=2064x2752
          LIST_TILE="12%,47%"; FACE="97%,4%"; SEEK_FROM="4%,92%"; SEEK_TO="58%,92%" ;;
  *) echo "device iphone or ipad, not $KIND"; exit 2 ;;
esac

# The newest iOS runtime, and the first device type of TYPES it supports
read -r RUNTIME DEVTYPE < <(TYPES="$TYPES" python3 "$HERE/pick_device.py")
echo "runtime $RUNTIME, device type $DEVTYPE"
UDID=$(xcrun simctl create "Store $KIND $LANG_CODE" "$DEVTYPE" "$RUNTIME")
echo "$UDID" > "$OUT/udid.txt"
{
  echo "device type: $DEVTYPE"
  echo "runtime: $RUNTIME"
  echo "udid: $UDID"
  echo "language: $LANGS, locale $LOCALE"
  xcodebuild -version | tr '\n' ' ' | sed 's/^/xcode: /'
  echo
} > "$OUT/sim-device.txt"
cat "$OUT/sim-device.txt"

# The language and the region, written while booted, read at the next boot
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b
xcrun simctl spawn "$UDID" defaults write -g AppleLanguages -array "$LANGS"
xcrun simctl spawn "$UDID" defaults write -g AppleLocale -string "$LOCALE"
xcrun simctl shutdown "$UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b
xcrun simctl spawn "$UDID" defaults read -g AppleLanguages | tr -d '\n '; echo
xcrun simctl ui "$UDID" appearance dark
# 9:41, the date of Apple's own captures on an iPad status bar
xcrun simctl status_bar "$UDID" override --time "2007-01-09T09:41:00Z" --dataNetwork wifi --wifiMode active \
  --wifiBars 3 --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100 \
  || xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100

xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant photos "$BUNDLE" || true
xcrun simctl privacy "$UDID" grant photos-add "$BUNDLE" || true

# The photo library, oldest first
for f in $(ls "$MEDIA/library" | sort -t_ -k2); do
  xcrun simctl addmedia "$UDID" "$MEDIA/library/$f" || echo "could not add $f"
done
python3 "$HERE/../media/prepare_panoramas.py" --check \
  "$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Media/DCIM" > "$OUT/logs/library-check.txt" 2>&1
find "$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Media/DCIM" -type f | sort >> "$OUT/logs/library-check.txt"
cat "$OUT/logs/library-check.txt"

# The share: the holiday folder and the film under the names of the language of the run
NAS="$RUNNER_TEMP/nas-$KIND-$LANG_CODE"
rm -rf "$NAS"
mkdir -p "$NAS/$HOLIDAYS" "$NAS/$FILMS"
cp "$MEDIA"/nas/holidays/* "$NAS/$HOLIDAYS/"
cp "$MEDIA/nas/films/film.mp4" "$NAS/$FILMS/$FILM.mp4"
cat > "$RUNNER_TEMP/wsgidav.yaml" <<YAML
host: 127.0.0.1
port: 8765
provider_mapping:
  "/":
    root: "$NAS"
    readonly: true
http_authenticator:
  domain_controller: null
  accept_basic: true
  accept_digest: false
  default_to_digest: false
simple_dc:
  user_mapping:
    "*": true
verbose: 1
YAML
"$RUNNER_TEMP/dav/bin/wsgidav" --config "$RUNNER_TEMP/wsgidav.yaml" > "$OUT/logs/wsgidav.log" 2>&1 &
DAV_PID=$!
sleep 4
curl -s -X PROPFIND -H 'Depth: 1' http://127.0.0.1:8765/ | head -c 1500; echo

export PATH="$PATH:$HOME/.maestro/bin"
export MAESTRO_CLI_NO_ANALYTICS=1
export MAESTRO_DRIVER_STARTUP_TIMEOUT=240000
cd "$OUT/maestro"

# A screenshot of the simulator every 1.5 s while a flow runs whose moments are short (the sphere, the film resumed)
burst() {
  local name=$1 i=0
  while [ -f "$OUT/burst.on" ]; do
    i=$((i + 1))
    xcrun simctl io "$UDID" screenshot --type=png "$OUT/sim/$name-burst-$(printf %03d $i).png" > /dev/null 2>&1
    sleep 1.5
  done
}

for flow in s1-start s2-list-sphere s3-device-only s4-share s5-film s6-timeline; do
  case "$flow" in
    s2-list-sphere|s5-film) touch "$OUT/burst.on"; burst "$flow" & BURST_PID=$! ;;
    *) BURST_PID= ;;
  esac
  echo "::group::flow $flow"
  maestro --device "$UDID" test \
    -e "LIST_TILE=$LIST_TILE" -e "FACE=$FACE" -e "SHARE_NAME=$SHARE_NAME" -e "HOLIDAYS=$HOLIDAYS" \
    -e "FILMS=$FILMS" -e "FILM=$FILM" -e "SEEK_FROM=$SEEK_FROM" -e "SEEK_TO=$SEEK_TO" \
    --debug-output "$OUT/logs/debug-$flow" --test-output-dir "$OUT/logs/test-$flow" \
    "$HERE/$flow.yaml" > "$OUT/logs/$flow.log" 2>&1
  status=$?
  tail -40 "$OUT/logs/$flow.log"
  echo "::endgroup::"
  rm -f "$OUT/burst.on"
  [ -n "$BURST_PID" ] && wait "$BURST_PID" 2>/dev/null
  echo "flow $flow: exit $status" | tee -a "$OUT/flows.txt"
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/sim/after-$flow.png" > /dev/null 2>&1
  maestro --device "$UDID" hierarchy > "$OUT/logs/hierarchy-after-$flow.json" 2> /dev/null || true
done

# The screenshots of the flows, wherever Maestro put them
find "$OUT/logs" "$HERE" "$HOME/.maestro/tests" -name 's[0-9][0-9]-*.png' -exec cp -n {} "$OUT/maestro/" \; 2>/dev/null
kill "$DAV_PID" 2>/dev/null
# The size of every capture: the device's own pixels or a problem
for f in "$OUT"/maestro/*.png "$OUT"/sim/after-*.png; do
  [ -f "$f" ] || continue
  sz=$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}')
  echo "$(basename "$f") $sz $([ "$sz" = "$SIZE" ] && echo ok || echo OTHER-SIZE)"
done | tee "$OUT/sizes.txt"
xcrun simctl shutdown "$UDID" || true
exit 0
