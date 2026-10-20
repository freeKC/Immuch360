#!/usr/bin/env bash
# Puts the files of this folder over a checkout of the macOS build recipe of libmpv (media-kit/libmpv-darwin-build), as
# .github/workflows/immuch360-libmpv.yml does before it builds: the recipe at its pinned commit, brought to the FFmpeg
# and mpv commits of the Windows build (see packages.lock.nix and the header of each .nix file).
#
#   apply_overlay.sh RECIPE_DIR
#
# Then the recipe builds for macOS 12 and later, the oldest macOS the app runs on (MACOSX_DEPLOYMENT_TARGET of
# mobile/macos), instead of 10.9: libplacebo is C++20, whose library parts need a newer macOS than 10.9.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
recipe=${1:?the folder of the recipe}
min_version=12.0

for file in packages.lock.nix nix/packages/mk-pkg-ffmpeg/default.nix nix/packages/mk-pkg-mpv/default.nix \
  nix/packages/mk-out-libs/default.nix cross-files/macos-arm64.ini cross-files/macos-amd64.ini; do
  [[ -f "$recipe/$file" ]] || { echo "not the expected recipe: $file is missing"; exit 1; }
done

cp "$here/packages.lock.nix" "$recipe/packages.lock.nix"
cp "$here/mk-pkg-ffmpeg.nix" "$recipe/nix/packages/mk-pkg-ffmpeg/default.nix"
cp "$here/mk-pkg-mpv.nix" "$recipe/nix/packages/mk-pkg-mpv/default.nix"
cp "$here/mk-out-libs.nix" "$recipe/nix/packages/mk-out-libs/default.nix"
mkdir -p "$recipe/nix/packages/mk-pkg-libplacebo"
cp "$here/mk-pkg-libplacebo.nix" "$recipe/nix/packages/mk-pkg-libplacebo/default.nix"
echo 'import ../../utils/targets/pkgs.nix' > "$recipe/nix/packages/mk-pkg-libplacebo/targets.nix"
cp "$here/immuch360-mpv-objc-language.patch" "$recipe/patches/immuch360-mpv-objc-language.patch"

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
