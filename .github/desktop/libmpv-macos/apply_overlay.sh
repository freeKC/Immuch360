#!/usr/bin/env bash
# Puts the files of this folder over a checkout of the macOS build recipe of libmpv (media-kit/libmpv-darwin-build), as
# .github/workflows/immuch360-libmpv.yml does before it builds: the recipe at its pinned commit, brought to the FFmpeg
# and mpv commits of the Windows build (see packages.lock.nix and the header of each .nix file).
#
#   apply_overlay.sh RECIPE_DIR
#
# Then the recipe builds for macOS 12 and later, the oldest macOS the app runs on (MACOSX_DEPLOYMENT_TARGET of
# mobile/macos), instead of 10.9: libplacebo is C++20, whose library parts need a newer macOS than 10.9.
#
# FFmpeg's options: mk-pkg-ffmpeg-meson.build is the recipe's meson.build of mk-pkg-ffmpeg with the lines that say
# Immuch360 (the yuv4mpegpipe demuxer and the rawvideo decoder, for the y4m of the AV2 decoder). It replaces the
# recipe's file only when that file is the one the copy was made from (its SHA-256 below): a newer recipe stops here
# instead of losing its own changes to FFmpeg's options.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
recipe=${1:?the folder of the recipe}
min_version=12.0
# nix/packages/mk-pkg-ffmpeg/meson.build of media-kit/libmpv-darwin-build at aadae8ce295dd15a222839c361c4c984ce9befb2
ffmpeg_meson_sha256=3ffeb357a0f2a67e0b9e34792dd6add91c3257f59d2b68ac1f2966c57568a312

sha256_of() {
  if command -v sha256sum > /dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

for file in packages.lock.nix nix/packages/mk-pkg-ffmpeg/default.nix nix/packages/mk-pkg-mpv/default.nix \
  nix/packages/mk-pkg-ffmpeg/meson.build nix/packages/mk-out-libs/default.nix nix/packages/mk-pkg-libpng/default.nix \
  cross-files/macos-arm64.ini cross-files/macos-amd64.ini; do
  [[ -f "$recipe/$file" ]] || { echo "not the expected recipe: $file is missing"; exit 1; }
done
found=$(sha256_of "$recipe/nix/packages/mk-pkg-ffmpeg/meson.build")
if [[ "$found" != "$ffmpeg_meson_sha256" ]]; then
  echo "not the expected recipe: nix/packages/mk-pkg-ffmpeg/meson.build has the SHA-256 $found, the copy"
  echo "mk-pkg-ffmpeg-meson.build was made from $ffmpeg_meson_sha256: make the copy again from the recipe's file"
  exit 1
fi

cp "$here/packages.lock.nix" "$recipe/packages.lock.nix"
cp "$here/mk-pkg-ffmpeg.nix" "$recipe/nix/packages/mk-pkg-ffmpeg/default.nix"
cp "$here/mk-pkg-ffmpeg-meson.build" "$recipe/nix/packages/mk-pkg-ffmpeg/meson.build"
cp "$here/mk-pkg-mpv.nix" "$recipe/nix/packages/mk-pkg-mpv/default.nix"
cp "$here/mk-out-libs.nix" "$recipe/nix/packages/mk-out-libs/default.nix"
cp "$here/mk-pkg-libpng.nix" "$recipe/nix/packages/mk-pkg-libpng/default.nix"
mkdir -p "$recipe/nix/packages/mk-pkg-libplacebo"
cp "$here/mk-pkg-libplacebo.nix" "$recipe/nix/packages/mk-pkg-libplacebo/default.nix"
echo 'import ../../utils/targets/pkgs.nix' > "$recipe/nix/packages/mk-pkg-libplacebo/targets.nix"
cp "$here/immuch360-mpv-objc-language.patch" "$recipe/patches/immuch360-mpv-objc-language.patch"
cp "$here/immuch360-mpv-cocoa-without-swift.patch" "$recipe/patches/immuch360-mpv-cocoa-without-swift.patch"

for ini in "$recipe"/cross-files/macos-*.ini; do
  grep -q "min_version   = '-mmacosx-version-min=10.9'" "$ini" || { echo "$ini: no 10.9 line to change"; exit 1; }
  sed -i.orig "s/-mmacosx-version-min=10.9/-mmacosx-version-min=$min_version/" "$ini"
  rm "$ini.orig"
done

# Nix reads a flake from git: the new files must be known to git, or nix build does not see them
if git -C "$recipe" rev-parse --git-dir > /dev/null 2>&1; then
  git -C "$recipe" add -A
fi
echo "overlay applied to $recipe (macOS $min_version and later)"
