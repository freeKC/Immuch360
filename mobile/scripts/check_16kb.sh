#!/usr/bin/env bash
# 16 KB page size check of Android APKs and app bundles (Google Play rule for apps that target Android 15 or later).
#
# Usage: check_16kb.sh <file.apk|file.aab> [more files...]
#
# For every native library: the smallest p_align of its LOAD segments (readelf -lW).
#   64 bit ABIs (arm64-v8a, x86_64): FAIL below 0x4000.
#   32 bit ABIs (armeabi-v7a, x86): reported only (no 16 KB page kernels on 32 bit devices).
# APK: also "zipalign -c -P 16 -v 4" and whether lib/*.so are stored uncompressed (reported).
# AAB: also BundleConfig.pb, uncompress_native_libraries must be enabled with PAGE_ALIGNMENT_16K or more (AGP 8.5.1+).
# Exit status 1 when a file is missing, a 64 bit library is below 16 KB, the APK zip alignment fails or the bundle
# is not set for 16 KB.
# Environment: ZIPALIGN (zipalign of build-tools 35 or later), WORK (scratch folder, default next to each input).
# Needs readelf (binutils), unzip and python3.
set -uo pipefail

find_zipalign() {
  if [[ -n "${ZIPALIGN:-}" ]]; then echo "$ZIPALIGN"; return; fi
  local d
  for d in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Android/Sdk" /usr/local/lib/android/sdk; do
    [[ -n "$d" && -d "$d/build-tools" ]] || continue
    ls -d "$d"/build-tools/3[5-9]*/zipalign "$d"/build-tools/[4-9][0-9]*/zipalign 2>/dev/null | sort -V | tail -1
    return
  done
}

# Smallest Align of the LOAD program headers, in decimal (0 when there is none)
min_load_align() {
  local m="" v
  while read -r v; do
    v=$((v))
    if [[ -z "$m" ]] || (( v < m )); then m=$v; fi
  done < <(readelf -lW "$1" 2>/dev/null | awk '$1 == "LOAD" { print $NF }')
  echo "${m:-0}"
}

bundle_alignment() {
  # Prints "enabled=<0|1> alignment=<n>" from BundleConfig.pb (Optimizations=2 > UncompressNativeLibraries=2).
  python3 - "$1" <<'PY'
import sys
def fields(b):
    i = 0
    while i < len(b):
        k = 0; s = 0
        while True:
            c = b[i]; i += 1; k |= (c & 0x7f) << s; s += 7
            if c < 0x80: break
        f, t = k >> 3, k & 7
        if t == 0:
            v = 0; s = 0
            while True:
                c = b[i]; i += 1; v |= (c & 0x7f) << s; s += 7
                if c < 0x80: break
            yield f, t, v
        elif t == 2:
            n = 0; s = 0
            while True:
                c = b[i]; i += 1; n |= (c & 0x7f) << s; s += 7
                if c < 0x80: break
            yield f, t, b[i:i+n]; i += n
        elif t == 5: yield f, t, b[i:i+4]; i += 4
        elif t == 1: yield f, t, b[i:i+8]; i += 8
        else: raise SystemExit("unknown wire type")
data = open(sys.argv[1], 'rb').read()
enabled = alignment = 0
for f, t, v in fields(data):
    if f == 2 and t == 2:
        for f2, t2, v2 in fields(v):
            if f2 == 2 and t2 == 2:
                for f3, t3, v3 in fields(v2):
                    if f3 == 1: enabled = v3
                    if f3 == 2: alignment = v3
print(f"enabled={enabled} alignment={alignment}")
PY
}

if (( $# == 0 )); then
  echo "usage: $0 <file.apk|file.aab> [more files...]" >&2
  exit 2
fi

status=0
for archive in "$@"; do
  if [[ ! -f "$archive" ]]; then
    echo "=== $archive"
    echo "FAIL: file not found"
    status=1
    continue
  fi
  archive=$(readlink -f "$archive")
  work="${WORK:-$(dirname "$archive")}/.check16kb.$$"
  rm -rf "$work"; mkdir -p "$work"
  echo "=== $archive"
  case "$archive" in
    *.aab) unzip -q -o "$archive" '*/lib/*.so' -d "$work" 2>/dev/null ;;
    *)     unzip -q -o "$archive" 'lib/*.so' -d "$work" 2>/dev/null ;;
  esac
  fails=0
  while IFS= read -r so; do
    rel="${so#"$work"/}"
    abi=$(basename "$(dirname "$so")")
    a=$(min_load_align "$so")
    if [[ "$abi" == arm64-v8a || "$abi" == x86_64 ]]; then
      if (( a >= 16384 )); then verdict=OK; else verdict=FAIL; fails=$((fails+1)); fi
    else
      if (( a >= 16384 )); then verdict="OK(32bit)"; else verdict="info-32bit-4k"; fi
    fi
    printf '%-14s 0x%-6x %s\n' "$verdict" "$a" "$rel"
  done < <(find "$work" -name '*.so' | sort)
  if [[ "$archive" == *.aab ]]; then
    unzip -p "$archive" BundleConfig.pb > "$work/BundleConfig.pb" 2>/dev/null
    bc=$(bundle_alignment "$work/BundleConfig.pb")
    echo "BundleConfig uncompress_native_libraries: $bc (alignment 2 = PAGE_ALIGNMENT_16K, 3 = 64K)"
    if [[ "$bc" != "enabled=1 alignment=2" && "$bc" != "enabled=1 alignment=3" ]]; then
      echo "FAIL: bundle not set for 16 KB zip alignment (AGP 8.5.1 or later sets it)"; status=1
    fi
  else
    comp=$(unzip -v "$archive" 'lib/*.so' 2>/dev/null | awk '/\.so$/ && $2 != "Stored"' | wc -l)
    echo "compressed lib/*.so entries: $comp (0 expected with extractNativeLibs=false)"
    za=$(find_zipalign)
    if [[ -n "$za" && -x "$za" ]]; then
      if "$za" -c -P 16 -v 4 "$archive" > "$work/zipalign.txt" 2>&1; then
        echo "zipalign -c -P 16 -v 4: OK ($za)"
      else
        echo "zipalign -c -P 16 -v 4: FAILED"; grep -E 'lib/.*BAD|Verification' "$work/zipalign.txt" | head -20; status=1
      fi
    elif [[ -n "${ZIPALIGN:-}" ]]; then
      echo "FAIL: ZIPALIGN=$ZIPALIGN is not an executable"; status=1
    else
      echo "zipalign: not found (set ZIPALIGN to the zipalign of build-tools 35 or later)"
    fi
  fi
  echo "64 bit libraries below 16 KB: $fails"
  (( fails == 0 )) || status=1
  rm -rf "$work"
done
exit $status
