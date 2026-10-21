#!/usr/bin/env bash
# libsmb2.so for the Linux packages of Immuch360 Desktop: the library of dart_smb2's release libsmb2-r8, built again
# from the same sources on an older glibc.
#
# Why: dart_smb2 downloads its libsmb2.so already built (mobile/packages/dart_smb2/linux/CMakeLists.txt), and the one
# of libsmb2-r8 asks glibc 2.38 for one function (__isoc23_strtol, which strtol becomes when compiled against glibc
# 2.38 headers), so SMB shares did not open on Ubuntu 22.04 and Debian 12. The same sources compiled on Ubuntu 22.04
# need glibc 2.25 at most. The sources: libsmb2-scripts at the commit of release r8 (its version 0.1.3), which pins the
# libsmb2 commit and the SHA-256 of its archive (scripts/shared/_versions.sh) and applies its patches to it.
#
# What is checked: the commit of the scripts; the archive of libsmb2 (by the scripts); the library exports the same
# functions as the release's own (downloaded and checked by the SHA-256 dart_smb2 pins); no glibc version above the
# floor the .deb and the .rpm declare (2.34).
#
#   .github/desktop/libsmb2/build_linux.sh OUT_DIR [SOURCES]
#
# writes OUT_DIR/libsmb2.so and, with SOURCES, the corresponding source of that library (libsmb2 is under the LGPL
# 2.1 or later) as a .tar.gz: the archive of libsmb2 the scripts verified, in their cache folder so that the build
# runs again offline, the scripts at their commit, this script and a README.txt. The archive is made the same way each
# time (sorted names, one owner, the commit date of the scripts), so the same build gives the same file; each desktop
# release carries it (immuch360-desktop.yml, desktop_release.py). The same sources are those of the libraries of
# release libsmb2-r8 (mobile/packages/dart_smb2/IMMUCH360-NOTE.md).
#
# Then IMMUCH360_LIBSMB2=OUT_DIR/libsmb2.so for flutter build linux: dart_smb2's CMake bundles it instead of the
# download (mobile/packages/dart_smb2/IMMUCH360-NOTE.md). Needs git, gcc, python3, curl, objdump (binutils) and GNU tar.
set -euo pipefail

SCRIPTS_REPOSITORY=https://github.com/ales-drnz/libsmb2-scripts.git
# libsmb2-scripts 0.1.3 (2026-09-19), the scripts of dart_smb2's release libsmb2-r8
SCRIPTS_COMMIT=f0688e739ec56842981e455cf8eba4a34e7682e7
# The x86_64 libsmb2.so of the release, as pinned by dart_smb2's linux/CMakeLists.txt
RELEASE_URL=https://github.com/ales-drnz/dart_smb2/releases/download/libsmb2-r8/libsmb2_linux-x86_64.so
RELEASE_SHA256=78f1a94ab977ab46ce5c8718f2f3f7fc0e0acf707863e14cfa5eb3a5e5119db2
GLIBC_FLOOR=2.34

out=${1:?usage: build_linux.sh OUT_DIR [SOURCES.tar.gz]}
mkdir -p "$out"
out=$(cd "$out" && pwd)
sources=${2:-}
if [ -n "$sources" ]; then
  mkdir -p "$(dirname "$sources")"
  sources="$(cd "$(dirname "$sources")" && pwd)/$(basename "$sources")"
fi
self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "== libsmb2-scripts at $SCRIPTS_COMMIT"
git init -q "$work/scripts"
git -C "$work/scripts" fetch -q --depth 1 "$SCRIPTS_REPOSITORY" "$SCRIPTS_COMMIT"
git -C "$work/scripts" checkout -q FETCH_HEAD
[ "$(git -C "$work/scripts" rev-parse HEAD)" = "$SCRIPTS_COMMIT" ] || { echo "not the pinned commit"; exit 1; }
grep -E '^export LIBSMB2_(COMMIT|TARBALL_SHA256|VERSION)=' "$work/scripts/scripts/shared/_versions.sh" | sed 's/^/  /'

echo "== build (x86_64, $(gcc --version | head -n 1))"
ARCHS=x86_64 bash "$work/scripts/scripts/build_libsmb2_linux.sh" | sed 's/^/  /'
built="$work/scripts/release_builds/libsmb2_linux-x86_64.so"

echo "== the functions of the release's library"
curl -sSfL -o "$work/release.so" "$RELEASE_URL"
echo "$RELEASE_SHA256  $work/release.so" | sha256sum -c - | sed 's/^/  /'
exports() { objdump -T "$1" | awk '$0 !~ /\*UND\*/ && $2 == "g" {print $NF}' | sort; }
exports "$work/release.so" >"$work/release.txt"
exports "$built" >"$work/built.txt"
if ! diff "$work/release.txt" "$work/built.txt" >"$work/exports.diff"; then
  echo "  the exported functions differ from the release's:"
  sed 's/^/    /' "$work/exports.diff"
  exit 1
fi
echo "  $(wc -l <"$work/built.txt") exported symbols, as the release's"

echo "== glibc"
newest=$(objdump -T "$built" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -V | tail -n 1)
echo "  newest version asked: $newest (floor of the packages: $GLIBC_FLOOR)"
if [ "$(printf '%s\n%s\n' "$newest" "$GLIBC_FLOOR" | sort -V | tail -n 1)" != "$GLIBC_FLOOR" ]; then
  echo "  above the floor"
  exit 1
fi

cp "$built" "$out/libsmb2.so"
echo "== $out/libsmb2.so ($(sha256sum "$out/libsmb2.so" | cut -d' ' -f1))"

[ -n "$sources" ] || exit 0
echo "== the sources of this library"
pinned() { sed -n "s/^export $1=\"\${$1:-\([^}]*\)}\"$/\1/p" "$work/scripts/scripts/shared/_versions.sh"; }
libsmb2_commit=$(pinned LIBSMB2_COMMIT)
libsmb2_sha256=$(pinned LIBSMB2_TARBALL_SHA256)
[[ "$libsmb2_commit" =~ ^[0-9a-f]{40}$ && "$libsmb2_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "  no pinned libsmb2"; exit 1; }
cached="$work/scripts/sources/cache/libsmb2-$libsmb2_commit.tar.gz"
echo "$libsmb2_sha256  $cached" | sha256sum -c - | sed 's/^/  /'
top=immuch360-libsmb2-sources
tree="libsmb2-scripts-$SCRIPTS_COMMIT"
stage="$work/sources/$top"
mkdir -p "$stage/$tree/sources/cache"
git -C "$work/scripts" archive --format=tar "$SCRIPTS_COMMIT" | tar -x -C "$stage/$tree"
cp "$cached" "$stage/$tree/sources/cache/"
cp "$self" "$stage/build_linux.sh"
cat >"$stage/README.txt" <<README
The corresponding source of libsmb2 in Immuch360

libsmb2 (https://github.com/sahlberg/libsmb2, GNU Lesser General Public License version 2.1 or later) is the library
of the SMB shares of Immuch360, loaded by the dart_smb2 package. This archive holds the sources every libsmb2 binary of
Immuch360 is built from:

$tree/
    libsmb2-scripts (https://github.com/ales-drnz/libsmb2-scripts, BSD 3-Clause) at commit $SCRIPTS_COMMIT:
    the patches it applies to libsmb2 (patches/libsmb2), its configuration header (scripts/shared/config/config.h),
    the wrapper built into the library (src/smb2_wrapper.c) and the build script of each system. The binaries of
    release libsmb2-r8 of https://github.com/ales-drnz/dart_smb2 (Android, iOS, macOS, Windows) are built by them.

$tree/sources/cache/libsmb2-$libsmb2_commit.tar.gz
    libsmb2 at commit $libsmb2_commit, as GitHub serves it (SHA-256 $libsmb2_sha256),
    where the scripts look for it before they download it.

build_linux.sh
    the script of Immuch360 (.github/desktop/libsmb2/build_linux.sh) that built lib/libsmb2.so of the Linux
    packages from those sources on $(. /etc/os-release && echo "$PRETTY_NAME") with $(gcc --version | head -n 1).

The library it built: SHA-256 $(sha256sum "$out/libsmb2.so" | cut -d' ' -f1).

To build it again without the network: in $tree, run ARCHS=x86_64 bash scripts/build_libsmb2_linux.sh, which
writes release_builds/libsmb2_linux-x86_64.so (needs gcc and python3).
README
epoch=$(git -C "$work/scripts" log -1 --format=%ct "$SCRIPTS_COMMIT")
tar --sort=name --format=gnu --owner=0 --group=0 --numeric-owner --mtime="@$epoch" --mode='u+rwX,go+rX,go-w' \
  -C "$work/sources" -cf - "$top" | gzip -9n >"$sources"
echo "  $sources ($(du -h "$sources" | cut -f1), SHA-256 $(sha256sum "$sources" | cut -d' ' -f1))"
