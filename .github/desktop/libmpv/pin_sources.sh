#!/usr/bin/env bash
# Checks the git sources of the libmpv build out at the commits of sources.lock, for
# .github/workflows/immuch360-libmpv.yml.
#
# Usage: pin_sources.sh <lock file> <source folder> <pinned|heads> <package>...
#
# Runs after the recipe's download targets, before anything is built: the recipe gives every package an empty update
# step and, when the source folder already holds a clone, never clones or resets it again, so the commit left here is
# the one built. FFmpeg and mpv are skipped (the workflow inputs pin them), and so are packages that are archives (the
# recipe checks those by SHA-256).
#
# pinned: every git package must have a line in the lock, else the run stops and prints the lines to add.
# heads:  nothing is moved; the lines of the commits the clones are at are printed, for a review of the lock.
#
# Prints the lock lines of what it left on stdout, and its progress on stderr.
set -euo pipefail

if [ $# -lt 3 ]; then
  echo "usage: $0 <lock file> <source folder> <pinned|heads> <package>..." >&2
  exit 2
fi
lock=$1
src=$2
mode=$3
shift 3
case "$mode" in
  pinned | heads) ;;
  *)
    echo "mode: pinned or heads, not '$mode'" >&2
    exit 2
    ;;
esac
[ -f "$lock" ] || {
  echo "no lock file: $lock" >&2
  exit 2
}

pin_of() {
  awk -v p="$1" '$1 == p && $2 ~ /^[0-9a-f]{40}$/ { print $2; exit }' "$lock"
}

missing=()
moved=0
for p in "$@"; do
  case "$p" in
    ffmpeg | mpv) continue ;;
  esac
  dir="$src/$p"
  if [ ! -d "$dir/.git" ]; then
    continue
  fi
  head=$(git -C "$dir" rev-parse HEAD)
  if [ "$mode" = heads ]; then
    echo "$p $head"
    continue
  fi
  pin=$(pin_of "$p")
  if [ -z "$pin" ]; then
    missing+=("$p $head")
    continue
  fi
  if [ "$head" != "$pin" ]; then
    # The clones are partial (--filter=tree:0): every commit of the branch is there, its trees come on checkout. A pin
    # outside the cloned branch is fetched by its id.
    if ! git -C "$dir" cat-file -e "$pin^{commit}" 2> /dev/null; then
      git -C "$dir" fetch -q --filter=tree:0 --no-tags origin "$pin"
    fi
    git -C "$dir" -c advice.detachedHead=false checkout -q --detach "$pin"
    # Submodules the clone initialised follow the commit, as a clone of that commit would have them
    if git -C "$dir" submodule status 2> /dev/null | grep -q '^[ +U]'; then
      git -C "$dir" submodule update -q --init --recursive
    fi
    moved=$((moved + 1))
    echo "$p: $head -> $pin" >&2
  fi
  now=$(git -C "$dir" rev-parse HEAD)
  if [ "$now" != "$pin" ]; then
    echo "$p is at $now, not at its pin $pin" >&2
    exit 1
  fi
  echo "$p $pin"
done

if [ ${#missing[@]} -gt 0 ]; then
  echo "Not pinned in $lock (add these lines after a review of the commits):" >&2
  printf '%s\n' "${missing[@]}" >&2
  exit 1
fi
if [ "$mode" = pinned ]; then
  echo "pinned: $moved moved to their lock commit" >&2
fi
