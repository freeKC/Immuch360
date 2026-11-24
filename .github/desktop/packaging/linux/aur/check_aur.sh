#!/bin/sh
# Checks the AUR package immuch360-bin (the PKGBUILD next to this script) in an archlinux container, as root:
#   - namcap on the PKGBUILD, then makepkg as a user, which downloads the .deb of the release the PKGBUILD names and
#     checks its SHA-256, and namcap on the package made: no error (its warnings are printed);
#   - .SRCINFO, which the AUR needs beside the PKGBUILD, is the one makepkg --printsrcinfo writes;
#   - the package installed with pacman, its dependencies from Arch: immuch360 --version answers, every library of every
#     ELF file of /usr/lib/immuch360 is found, libmpv is there, the desktop entry is valid.
#
#   docker run --rm -v "$PWD/.github/desktop/packaging/linux/aur:/aur:ro" archlinux:latest sh /aur/check_aur.sh
#
# Exit 1 on the first failed check.
set -eu

quiet() {
  log=$1
  shift
  "$@" >"$log" 2>&1 || { tail -n 40 "$log"; return 1; }
}

echo "== $(. /etc/os-release && echo "$PRETTY_NAME"): immuch360-bin"
quiet /tmp/upgrade.log pacman -Syu --noconfirm --needed base-devel namcap desktop-file-utils
useradd -m builder
work=/home/builder/immuch360-bin
mkdir -p "$work"
cp "$(dirname "$0")/immuch360-bin/PKGBUILD" "$work/"
chown -R builder: "$work"
as_builder() {
  su builder -c "cd $work && $*"
}

echo "-- namcap on the PKGBUILD"
as_builder namcap PKGBUILD | tee /tmp/namcap-pkgbuild.txt | sed 's/^/  /'
if grep -q ' E: ' /tmp/namcap-pkgbuild.txt; then
  echo "  namcap found an error in the PKGBUILD"
  exit 1
fi

echo "-- .SRCINFO"
as_builder makepkg --printsrcinfo > /tmp/SRCINFO
if [ -f "$(dirname "$0")/immuch360-bin/.SRCINFO" ]; then
  diff -u "$(dirname "$0")/immuch360-bin/.SRCINFO" /tmp/SRCINFO || { echo "  .SRCINFO is not what makepkg writes"; exit 1; }
  echo "  .SRCINFO is what makepkg --printsrcinfo writes"
else
  echo "  no .SRCINFO next to the PKGBUILD; makepkg writes:"
  sed 's/^/  | /' /tmp/SRCINFO
  exit 1
fi

echo "-- the dependencies from Arch, then makepkg"
# shellcheck disable=SC2046
quiet /tmp/depends.log pacman -S --needed --noconfirm $(sed -n 's/^\tdepends = //p' /tmp/SRCINFO)
quiet /tmp/makepkg.log as_builder makepkg --noconfirm
package=$(ls "$work"/immuch360-bin-*.pkg.tar.zst)
echo "  $(basename "$package"): $(stat -c %s "$package") bytes"

echo "-- namcap on the package"
namcap "$package" | tee /tmp/namcap-package.txt | sed 's/^/  /'
if grep -q ' E: ' /tmp/namcap-package.txt; then
  echo "  namcap found an error in the package"
  exit 1
fi

echo "-- the package installed"
quiet /tmp/install.log pacman -U --noconfirm "$package"
version=$(immuch360 --version)
echo "  $version"
case "$version" in "Immuch360 Desktop "*) ;; *) echo "  unexpected answer"; exit 1 ;; esac
missing=0
count=0
for file in /usr/lib/immuch360/immuch360 /usr/lib/immuch360/lib/*.so*; do
  count=$((count + 1))
  problems=$(ldd "$file" 2>&1 | grep 'not found' || true)
  [ -z "$problems" ] || { echo "  $file: $problems"; missing=1; }
done
[ "$missing" -eq 0 ] || { echo "  libraries missing: a dependency of the PKGBUILD is not declared"; exit 1; }
echo "  $count files, every library found"
ldconfig -p | grep -E 'libmpv\.so(\.[12])? ' | sed 's/^\s*/  /'
desktop-file-validate /usr/share/applications/com.aprogsys.immuch360.desktop
echo "  desktop-file-validate: no error"
for file in /usr/share/licenses/immuch360-bin/copyright /usr/share/licenses/immuch360-bin/libsmb2/NOTICE \
  /usr/lib/immuch360/data/flutter_assets/packages/dart_smb2/libsmb2/Immuch360-libsmb2-sources.tar.gz; do
  [ -f "$file" ] || { echo "  no $file"; exit 1; }
done
echo "  the licences and the source of libsmb2 are there"
echo "== immuch360-bin: all checks passed"
