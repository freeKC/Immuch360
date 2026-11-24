#!/bin/sh
# Checks the AppImage of Immuch360 Desktop in a clean container of a distribution where no package of the app is
# installed, as a user who downloads it would run it. FUSE is not there in a container, so the AppImage runs with
# --appimage-extract-and-run, which extracts it to /tmp and starts it from there, and the video check runs the AppRun of
# a copy extracted once with --appimage-extract (the program the extracted run starts, whose process the check follows):
#   - --version answers before any library of the desktop is installed;
#   - on the bare container, --immuch360-check must fail and say which packages to install, with the command of this
#     distribution (AppRun); that very command is then run, as a user would copy it (without sudo, as root, with the
#     flag that answers yes), and nothing else of the app's libraries is installed;
#   - --immuch360-check then passes: every library of every ELF file of the AppImage is found, and libmpv;
#   - the AppImage holds its desktop entry (valid for desktop-file-validate, the dedicated graphics card asked for,
#     no TryExec), its icon, its AppStream description, the MIME types of the raw camera files, the licence and the
#     notice of the app and of libsmb2 with its corresponding source, and the notice and the corresponding source of
#     the runtime;
#   - the AppImage started with --appimage-extract-and-run on a virtual screen still runs after 20 seconds;
#   - with CLIP, the app plays it on a virtual screen (video_smoke.sh, next to this script), with the distribution's
#     libmpv. Where the distribution's FFmpeg has no H.264 decoder of its own (Fedora, openSUSE: OpenH264 at best, the
#     noopenh264 stub at worst), the H.264 clip is played for information and FALLBACK, the same picture in Theora,
#     is the one that must play, as in check_package.sh.
# xdg-user-dirs is not installed: the stand-in of the AppImage answers the app (AppRun).
#
#   docker run --rm -v "$PWD/dist:/pkgs:ro" -v "$PWD/.github/desktop/packaging/linux:/check:ro" \
#     -v "$PWD/mobile/test/fixtures/video:/clips:ro" -v "$PWD/video-smoke:/out" archlinux:latest \
#     sh /check/check_appimage.sh /pkgs/Immuch360-Desktop-<label>-linux-x86_64.AppImage \
#     [/clips/flat-6s.mp4 [/out [/clips/flat-6s-theora.mkv]]]
#
# Run as root inside the container; exit 1 on the first failed check.
set -eu

image=$1
clip=${2:-}
smoke_out=${3:-/tmp/video-smoke}
fallback=${4:-}
[ -f "$image" ] || { echo "no AppImage at $image"; exit 1; }
# shellcheck source=/dev/null
. /etc/os-release
echo "== $PRETTY_NAME: $(basename "$image")"
work=$(mktemp -d)
cp "$image" "$work/Immuch360.AppImage"
chmod 755 "$work/Immuch360.AppImage"
appimage="$work/Immuch360.AppImage"

case " ${ID:-} ${ID_LIKE:-} " in
  *" arch "*) family=arch ;;
  *" fedora "*) family=fedora ;;
  *" suse "* | *" opensuse "*) family=suse ;;
  *" debian "* | *" ubuntu "*) family=debian ;;
  *) echo "no family for $ID"; exit 1 ;;
esac

# The package database of the container, then what the check itself needs, never a library of the app
quiet() {
  log=$1
  shift
  "$@" >"$log" 2>&1 || { tail -n 40 "$log"; return 1; }
}
case "$family" in
  arch)
    # A whole upgrade first: a partial one would mix libraries of two dates
    quiet /tmp/refresh.log pacman -Syu --noconfirm
    yes_flag=--noconfirm
    check_tools() { quiet /tmp/tools.log pacman -S --needed --noconfirm desktop-file-utils "$@"; }
    extra="xorg-server-xvfb xorg-xauth mesa xorg-xwd xorg-xwininfo sqlite findutils"
    ;;
  fedora)
    yes_flag=-y
    check_tools() { quiet /tmp/tools.log dnf install -y -q desktop-file-utils "$@"; }
    extra="xorg-x11-server-Xvfb xorg-x11-xauth mesa-dri-drivers xwd xwininfo sqlite findutils"
    ;;
  debian)
    export DEBIAN_FRONTEND=noninteractive
    quiet /tmp/refresh.log apt-get update
    yes_flag=-y
    check_tools() { quiet /tmp/tools.log apt-get install -y --no-install-recommends desktop-file-utils "$@"; }
    extra="xvfb xauth libgl1-mesa-dri x11-apps x11-utils sqlite3"
    ;;
  suse)
    quiet /tmp/refresh.log zypper --non-interactive refresh
    yes_flag=--non-interactive
    check_tools() { quiet /tmp/tools.log zypper --non-interactive install --no-recommends desktop-file-utils "$@"; }
    extra="xvfb-run xorg-x11-server-Xvfb xauth Mesa-dri xwd xwininfo sqlite3 findutils"
    ;;
esac

echo "-- the version, before anything of the desktop is installed"
version=$("$appimage" --appimage-extract-and-run --version)
echo "  $version"
case "$version" in "Immuch360 Desktop "*) ;; *) echo "unexpected answer"; exit 1 ;; esac

echo "-- the check of the libraries on the bare container"
status=0
"$appimage" --appimage-extract-and-run --immuch360-check >/tmp/check-bare.txt 2>&1 || status=$?
sed 's/^/  | /' /tmp/check-bare.txt
[ "$status" -ne 0 ] || { echo "  the check passed on a container without GTK: it must say what is missing"; exit 1; }
if grep -q 'Install the packages of your distribution that provide' /tmp/check-bare.txt; then
  echo "  a library without a package of $family in AppRun"
  exit 1
fi
commands=$(sed -n 's/^  sudo //p' /tmp/check-bare.txt)
[ -n "$commands" ] || { echo "  no install command for $family"; exit 1; }

echo "-- the commands the AppImage gave, as root and answering yes"
echo "$commands" | while read -r line; do
  # shellcheck disable=SC2086
  set -- $line
  manager=$1
  shift
  echo "  $manager $yes_flag $*"
  if [ "$manager" = zypper ]; then
    quiet /tmp/install.log zypper "$yes_flag" "$@"
  else
    quiet /tmp/install.log "$manager" "$yes_flag" "$@"
  fi
done

echo "-- the check of the libraries once they are installed"
"$appimage" --appimage-extract-and-run --immuch360-check | sed 's/^/  /'

echo "-- the files of the AppImage"
check_tools $extra
(cd "$work" && "$appimage" --appimage-extract >/dev/null)
root="$work/squashfs-root"
for file in AppRun .DirIcon com.aprogsys.immuch360.desktop com.aprogsys.immuch360.png fallback/xdg-user-dir \
  immuch360/immuch360 immuch360/lib/libsmb2.so immuch360/lib/libimmuch_sbs_codec.so \
  usr/share/applications/com.aprogsys.immuch360.desktop usr/share/metainfo/com.aprogsys.immuch360.metainfo.xml \
  usr/share/mime/packages/com.aprogsys.immuch360.xml usr/share/icons/hicolor/256x256/apps/com.aprogsys.immuch360.png \
  usr/share/doc/immuch360/copyright usr/share/licenses/immuch360/LICENSE \
  usr/share/licenses/immuch360/libsmb2/NOTICE usr/share/licenses/immuch360/libsmb2/LICENCE-LGPL-2.1.txt \
  immuch360/data/flutter_assets/packages/dart_smb2/libsmb2/Immuch360-libsmb2-sources.tar.gz \
  usr/share/doc/immuch360/appimage-runtime/RUNTIME-NOTICE.txt \
  usr/share/doc/immuch360/appimage-runtime/LICENCE-LGPL-2.1.txt \
  usr/share/doc/immuch360/appimage-runtime/fuse-3.15.0.tar.xz \
  usr/share/doc/immuch360/appimage-runtime/squashfuse-0.5.2.tar.gz \
  usr/share/doc/immuch360/appimage-runtime/type2-runtime-dd6cebedcbddde9c82f89b011e8e1d40b6e43868.tar.gz; do
  [ -e "$root/$file" ] || { echo "  no $file in the AppImage"; exit 1; }
done
echo "  the program, libsmb2 and its source, the codec, the entry, the icons, the licences and the runtime's source"
desktop-file-validate "$root/com.aprogsys.immuch360.desktop"
echo "  desktop-file-validate: no error"
grep -qx 'PrefersNonDefaultGPU=true' "$root/com.aprogsys.immuch360.desktop" \
  || { echo "  the desktop entry does not ask for the dedicated graphics card"; exit 1; }
! grep -q '^TryExec=' "$root/com.aprogsys.immuch360.desktop" || { echo "  a TryExec in the entry"; exit 1; }
grep -q '^X-AppImage-Version=' "$root/com.aprogsys.immuch360.desktop" || { echo "  no X-AppImage-Version"; exit 1; }
echo "  PrefersNonDefaultGPU=true, no TryExec, $(grep '^X-AppImage-Version=' "$root/com.aprogsys.immuch360.desktop")"
if command -v xdg-user-dir >/dev/null 2>&1; then
  echo "  xdg-user-dir is installed here: the stand-in of the AppImage is not used"
else
  echo "  no xdg-user-dir here: the stand-in answers DOCUMENTS with $(HOME=/tmp/home-check sh "$root/fallback/xdg-user-dir" DOCUMENTS)"
fi

echo "-- a start of the AppImage on a virtual screen (--appimage-extract-and-run)"
export LIBGL_ALWAYS_SOFTWARE=1
start_home=$(mktemp -d)
HOME="$start_home" DBUS_SESSION_BUS_ADDRESS="unix:path=$start_home/no-bus" GDK_BACKEND=x11 \
  setsid xvfb-run -a -s "-screen 0 1280x800x24" "$appimage" --appimage-extract-and-run >/tmp/start.log 2>&1 &
pid=$!
sleep 20
if kill -0 "$pid" 2>/dev/null; then
  echo "  still running after 20 seconds (stopped by the check)"
  kill -TERM -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  sleep 2
  kill -KILL -- "-$pid" 2>/dev/null || true
else
  sed 's/^/  | /' /tmp/start.log | tail -n 40
  echo "  the AppImage ended by itself after less than 20 seconds"
  exit 1
fi
wait "$pid" 2>/dev/null || true
sed 's/^/  | /' /tmp/start.log | tail -n 12

if [ -n "$clip" ]; then
  echo "-- the machine and the video stack"
  echo "  $(sed -n 's/^model name\s*:\s*//p' /proc/cpuinfo | head -n 1), $(nproc) threads"
  smoke() {
    xvfb-run -a -s "-screen 0 1280x800x24" sh "$(dirname "$0")/video_smoke.sh" "$root/AppRun" "$1" "$2"
  }
  case "$family" in
    fedora | suse)
      [ -n "$fallback" ] || { echo "  $family needs the Theora clip too"; exit 1; }
      echo "-- the H.264 clip, for information only: $family's own FFmpeg may not decode it"
      if smoke "$clip" "$smoke_out/h264-information"; then
        echo "  (information) the H.264 clip played"
      else
        echo "  (information) the H.264 clip did not play"
      fi
      echo "-- a video played on a virtual screen, the Theora clip"
      smoke "$fallback" "$smoke_out"
      ;;
    *)
      echo "-- a video played on a virtual screen"
      smoke "$clip" "$smoke_out"
      ;;
  esac
fi
echo "== $PRETTY_NAME: all checks of the AppImage passed"
