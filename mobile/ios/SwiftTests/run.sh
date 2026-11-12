#!/bin/sh
# Compiles the pure Swift of the 360° player's stabilisation (Runner/Spherical/StabilizationTable.swift and
# PlayerStabilization.swift) with the tests of main.swift, and runs them: no simulator, no target in the Xcode project.
# On macOS with Xcode (the CI's macOS job), or anywhere a Swift toolchain with Foundation is installed.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
spherical="$here/../Runner/Spherical"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
if command -v xcrun >/dev/null 2>&1; then
  compiler="xcrun --sdk macosx swiftc"
else
  compiler="swiftc"
fi
$compiler -swift-version 5 -O -o "$out/stabilization-tests" \
  "$spherical/StabilizationTable.swift" "$spherical/PlayerStabilization.swift" "$here/main.swift"
"$out/stabilization-tests" "$spherical/RawStitchShaders.metal" "$spherical/RawStitchRenderer.swift"
