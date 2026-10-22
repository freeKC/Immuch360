#!/bin/sh
# Installs a .deb or an .rpm of Immuch360 Desktop in a clean container of a distribution and checks it, as a user
# would get it: the package manager brings the dependencies the package declares, then
#   - immuch360 --version answers (the launcher /usr/bin/immuch360);
#   - every library that each ELF file of /opt/immuch360 needs is found (ldd), so the dependencies are complete,
#     libsmb2.so included (built on Ubuntu 22.04 by the workflow, .github/desktop/libsmb2/build_linux.sh);
#   - libmpv, which media_kit and media_kit_video open when a video plays (libmpv.so, .so.2 or .so.1), is installed;
#   - the desktop entry passes desktop-file-validate, and the MIME types of the raw camera files are registered;
#   - with --start, the app starts on a virtual screen (Xvfb, software rendering) and still runs after 20 seconds;
#   - with --video CLIP, the app started with the clip plays it on a virtual screen (video_smoke.sh, next to this
#     script), with the libmpv of the distribution; its output, log and captures go to OUT_DIR (/tmp/video-smoke by
#     default). The machine (its processor) and the versions of the video stack are printed first, for the day a
#     container fails where another passed.
#
# H.264 on Fedora: its FFmpeg (ffmpeg-free, which mpv-libs takes) has no H.264 decoder of its own and decodes H.264
# through libopenh264, which two packages provide: openh264, Cisco's build, from the fedora-cisco-openh264 repository,
# and noopenh264, a stub in Fedora's own repositories that refuses every stream ("libopenh264: Unable to create
# decoder"). The repository is enabled with skip_if_unavailable, so on a runner that does not reach Cisco's server dnf
# takes the stub without a word (desktop runs 39646919361 and 39651337243). Cisco's build is therefore installed first,
# that repository required for this one command, three attempts 15 seconds apart. When it still cannot be reached, H.264
# is not available in the container: the H.264 clip is played for information only, its result does not count, and
# FALLBACK_CLIP, the same picture in a codec of Fedora's own FFmpeg, is the video that must play. That clip is Theora
# in Matroska, a codec mpv never hands to a hardware decoder: with VP9 or AV1, the mpv 0.41 and FFmpeg 8 of Fedora 44
# first try Vulkan video (Mesa's lavapipe in the container) and CUDA and log errors the app records as warnings of its
# player, which the video check counts as failures. A user of Fedora gets the same choice for camera videos: RPM
# Fusion's FFmpeg or Cisco's openh264 (the release notes say so).
#
#   docker run --rm -v "$PWD/dist:/pkgs:ro" -v "$PWD/.github/desktop/packaging/linux:/check:ro" \
#     -v "$PWD/mobile/test/fixtures/video:/clips:ro" -v "$PWD/video-smoke:/out" ubuntu:24.04 \
#     sh /check/check_package.sh /pkgs/Immuch360-Desktop-<label>-linux-amd64.deb \
#     [--start | --video /clips/flat-6s.mp4 [/out [/clips/flat-6s-theora.mkv]]]
#
# Run as root inside the container; exit 1 on the first failed check.
set -eu

package=$1
start=${2:-}
clip=${3:-}
smoke_out=${4:-/tmp/video-smoke}
fallback=${5:-}
[ -f "$package" ] || { echo "no package at $package"; exit 1; }
# shellcheck source=/dev/null
. /etc/os-release
echo "== $PRETTY_NAME: $(basename "$package")"

case "$package" in
  *.deb)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # The package from the folder, its dependencies from the archive; desktop-file-utils for the check
    apt-get install -y -qq "$package" desktop-file-utils >/tmp/install.log 2>&1 || { cat /tmp/install.log; exit 1; }
    dpkg -s immuch360 | sed -n 's/^\(Version\|Depends\): /  \1: /p'
    # Debian's and Ubuntu's FFmpeg decode H.264 themselves
    h264=yes
    # gdb for the stacks of a start that crashed or does not get on (video_smoke.sh)
    install_extra() {
      apt-get install -y -qq xvfb xauth libgl1-mesa-dri x11-apps x11-utils sqlite3 gdb >/tmp/extra.log 2>&1 \
        || { cat /tmp/extra.log; exit 1; }
    }
    video_stack() {
      dpkg-query -W -f '${Package} ${Version}\n' 'libmpv[12]' 'libavcodec[0-9]*' libgl1-mesa-dri 'libllvm[0-9]*' \
        libgtk-3-0 'libgtk-3-0t64' 2>/dev/null | sed 's/^/  /'
    }
    ;;
  *.rpm)
    # Cisco's openh264 before the package, so that libavcodec-free finds its libopenh264 there and dnf does not take
    # the stub (see above)
    attempt=1
    until dnf install -y -q --setopt=fedora-cisco-openh264.skip_if_unavailable=False openh264 >/tmp/openh264.log 2>&1
    do
      echo "  openh264 from fedora-cisco-openh264, attempt $attempt of 3: $(grep -v '^\s*$' /tmp/openh264.log | tail -n 1)"
      [ "$attempt" -lt 3 ] || break
      attempt=$((attempt + 1))
      sleep 15
    done
    dnf install -y -q "$package" desktop-file-utils >/tmp/install.log 2>&1 || { cat /tmp/install.log; exit 1; }
    rpm -q --qf '  Version: %{VERSION}-%{RELEASE}\n' immuch360
    echo "  Requires: $(rpm -q --requires immuch360 | grep -v '^rpmlib(' | tr '\n' ' ')"
    if rpm -q openh264 >/dev/null 2>&1; then
      h264=yes
    else
      h264=no
    fi
    echo "  libopenh264: $(rpm -q openh264 noopenh264 | grep -v 'not installed' | tr '\n' ' ')"
    install_extra() {
      dnf install -y -q xorg-x11-server-Xvfb xorg-x11-xauth mesa-dri-drivers xwd xwininfo sqlite gdb >/tmp/extra.log \
        2>&1 || { cat /tmp/extra.log; exit 1; }
    }
    video_stack() {
      rpm -q mpv-libs libavcodec-free openh264 noopenh264 mesa-dri-drivers llvm-libs gtk3 | grep -v 'not installed' \
        | sed 's/^/  /'
    }
    ;;
  *) echo "not a .deb or an .rpm: $package"; exit 1 ;;
esac

echo "-- the launcher"
version=$(immuch360 --version)
echo "  $version"
case "$version" in "Immuch360 Desktop "*) ;; *) echo "unexpected answer"; exit 1 ;; esac

echo "-- the libraries of every ELF file in /opt/immuch360"
missing=0
count=0
for file in /opt/immuch360/immuch360 /opt/immuch360/lib/*.so*; do
  [ -f "$file" ] || continue
  count=$((count + 1))
  # Fedora's ldd warns about libraries without the execute bit, which the loader does not need
  problems=$(ldd "$file" 2>&1 | grep -v 'execution permission' | grep 'not found' || true)
  [ -n "$problems" ] || continue
  # A glibc too old for libsmb2.so (the one dart_smb2 downloads needs 2.38) would take the SMB shares away: the
  # workflow builds it on Ubuntu 22.04 instead, so it is checked like every other file
  echo "  $file:"
  echo "$problems" | sed 's/^\s*/    /'
  missing=1
done
[ "$missing" -eq 0 ] || { echo "libraries missing: a dependency of the package is not declared"; exit 1; }
echo "  $count files, every library found"

echo "-- libmpv"
if ldconfig -p | grep -E 'libmpv\.so(\.[12])? ' >/tmp/mpv.txt; then
  sed 's/^\s*/  /' /tmp/mpv.txt
else
  echo "  no libmpv.so, .so.2 or .so.1"
  exit 1
fi

echo "-- the desktop entry and the MIME types"
desktop-file-validate /usr/share/applications/com.aprogsys.immuch360.desktop
echo "  desktop-file-validate: no error"
grep -o '^MimeType=.*' /usr/share/applications/com.aprogsys.immuch360.desktop | cut -c1-120 | sed 's/^/  /'
if command -v update-mime-database >/dev/null 2>&1; then
  update-mime-database /usr/share/mime
  for glob in insp insv 360 osv; do
    grep -q "\*\.$glob\$" /usr/share/mime/globs2 || { echo "  *.$glob is not in the MIME database"; exit 1; }
  done
  echo "  *.insp, *.insv, *.360 and *.osv have their types"
else
  echo "  shared-mime-info is not installed here: the MIME types are not checked"
fi

if [ "$start" = "--video" ]; then
  install_extra
  echo "-- the machine and the video stack"
  # The processor matters to Mesa's software renderer (llvmpipe), whose LLVM compiles the shaders for it
  echo "  $(sed -n 's/^model name\s*:\s*//p' /proc/cpuinfo | head -n 1), $(nproc) threads," \
    "$(grep -o -w 'avx2\|avx512f' /proc/cpuinfo | sort -u | tr '\n' ' ')"
  video_stack
  smoke() {
    xvfb-run -a -s "-screen 0 1280x800x24" sh "$(dirname "$0")/video_smoke.sh" immuch360 "$1" "$2"
  }
  if [ "$h264" = yes ]; then
    echo "-- a video played on a virtual screen"
    smoke "$clip" "$smoke_out"
  elif [ -n "$fallback" ]; then
    echo "-- H.264 not available in this container (openh264 repository unreachable), Theora clip used"
    echo "-- the H.264 clip, for information only: its result does not count"
    if smoke "$clip" "$smoke_out/h264-information"; then
      echo "  (information) the H.264 clip played"
    else
      echo "  (information) the H.264 clip did not play, as expected with the noopenh264 stub"
    fi
    echo "-- a video played on a virtual screen, the Theora clip"
    smoke "$fallback" "$smoke_out"
  else
    echo "  H.264 not available in this container (openh264 repository unreachable), and no Theora clip was given"
    exit 1
  fi
elif [ "$start" = "--start" ]; then
  echo "-- a start on a virtual screen"
  install_extra
  export LIBGL_ALWAYS_SOFTWARE=1
  status=0
  timeout 20 xvfb-run -a -s "-screen 0 1280x800x24" immuch360 >/tmp/start.log 2>&1 || status=$?
  sed 's/^/  | /' /tmp/start.log | tail -n 40
  if [ "$status" -eq 124 ]; then
    echo "  still running after 20 seconds (stopped by the check)"
  else
    echo "  the app ended by itself after less than 20 seconds (exit $status)"
    exit 1
  fi
fi
echo "== $PRETTY_NAME: all checks passed"
