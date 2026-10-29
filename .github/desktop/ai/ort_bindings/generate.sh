#!/usr/bin/env bash
# Writes mobile/lib/desktop/ai/ort/ort_api_bindings.dart from the header of ONNX Runtime 1.31.0 kept in include/, then
# ort_functions.json: the entries of the table the app calls, their place, and the size of the table of API 23 read
# from the header of 1.23.2 (downloaded at its release commit and checked by its SHA-256, never kept here).
#
# Needs Dart 3.13 or later on the PATH (the Flutter of mobile/mise.toml), libclang for ffigen (clang 19 on Debian 13),
# curl, sha256sum and python3. From the root of the repository, with an absolute path since mise runs it from mobile:
#
#   mise exec -C mobile -- "$PWD/.github/desktop/ai/ort_bindings/generate.sh"
#
# Run it again after a change of the header or of the entries mobile/lib/desktop/ai/ort calls, and commit what it
# writes.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../../.." && pwd)
bindings="$root/mobile/lib/desktop/ai/ort/ort_api_bindings.dart"
commit_1_23_2=a83fc4d58cb48eb68890dd689f94f28288cf2278
raw="https://raw.githubusercontent.com/microsoft/onnxruntime/$commit_1_23_2/include/onnxruntime/core/session"

cd "$here"
dart pub get
dart run ffigen --config ffigen.yaml
(cd "$root/mobile" && dart format "$bindings")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/include"
curl -fsSL -o "$tmp/include/onnxruntime_c_api.h" "$raw/onnxruntime_c_api.h"
curl -fsSL -o "$tmp/include/onnxruntime_ep_c_api.h" "$raw/onnxruntime_ep_c_api.h"
(cd "$tmp/include" && sha256sum -c - <<'SUMS'
71125e66180a991d65c9bdbad4aa20daaa1f7a48c7a5c0fa5f18f250ac839a02  onnxruntime_c_api.h
b92778f50c36ecdf53d0344e0129a78b306afed653f81bba8a9597e3e6e9546f  onnxruntime_ep_c_api.h
SUMS
)
# The same configuration on the older header, written next to it
sed -e "s#^output: .*#output: '$tmp/ort_api_1_23_2.dart'#" -e "s#'include/onnxruntime_c_api.h'#'$tmp/include/onnxruntime_c_api.h'#" \
  ffigen.yaml > "$tmp/ffigen.yaml"
dart run ffigen --config "$tmp/ffigen.yaml"

python3 "$here/ort_functions.py" --bindings "$bindings" --api23 "$tmp/ort_api_1_23_2.dart" \
  --sources "$root/mobile/lib/desktop/ai/ort" --out "$here/ort_functions.json"
