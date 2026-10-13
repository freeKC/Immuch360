#!/bin/sh
# Installs a .deb or an .rpm of Immuch360 Desktop in a clean container of a distribution and checks it, as a user
# would get it: the package manager brings the dependencies the package declares, then
#   - immuch360 --version answers (the launcher /usr/bin/immuch360);
#   - every library that each ELF file of /opt/immuch360 needs is found (ldd), so the dependencies are complete;
#   - libmpv, which media_kit opens when a video plays (libmpv.so, .so.2 or .so.1), is installed;
#   - the desktop entry passes desktop-file-validate, and the MIME types of the raw camera files are registered;
#   - with --start, the app starts on a virtual screen (Xvfb, software rendering) and still runs after 20 seconds.
#
#   docker run --rm -v "$PWD/dist:/pkgs:ro" -v "$PWD/.github/desktop/packaging/linux:/check:ro" ubuntu:24.04 \
#     sh /check/check_package.sh /pkgs/Immuch360-Desktop-<label>-linux-amd64.deb [--start]
#
# Run as root inside the container; exit 1 on the first failed check.
set -eu

package=$1
start=${2:-}
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
    install_extra() {
      apt-get install -y -qq xvfb xauth libgl1-mesa-dri >/tmp/extra.log 2>&1 || { cat /tmp/extra.log; exit 1; }
    }
    ;;
  *.rpm)
    dnf install -y -q "$package" desktop-file-utils >/tmp/install.log 2>&1 || { cat /tmp/install.log; exit 1; }
    rpm -q --qf '  Version: %{VERSION}-%{RELEASE}\n' immuch360
    echo "  Requires: $(rpm -q --requires immuch360 | grep -v '^rpmlib(' | tr '\n' ' ')"
    install_extra() {
      dnf install -y -q xorg-x11-server-Xvfb xorg-x11-xauth mesa-dri-drivers >/tmp/extra.log 2>&1 \
        || { cat /tmp/extra.log; exit 1; }
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
  if ldd "$file" 2>&1 | grep -v 'execution permission' | grep -q 'not found'; then
    echo "  $file:"
    ldd "$file" 2>&1 | grep 'not found' | sed 's/^/    /'
    missing=1
  fi
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

if [ "$start" = "--start" ]; then
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
