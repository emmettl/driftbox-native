#!/bin/sh
# The audio targets are held to two rules, and the compiler checks both.
#
#  1. They compile as Embedded Swift for a bare WebAssembly target: no Foundation, no reflection,
#     no platform. This does NOT rule out existentials or allocation — Embedded Swift accepts
#     `any P` as of 6.3, which was measured rather than assumed.
#  2. Every function on the render path is marked `@_noAllocation`, and an optimised build turns
#     an allocation, an existential or a class instance inside one into an error. Those
#     diagnostics come from the optimiser, so a debug build says nothing: step 2 is a release build.
#
# This goes round SwiftPM on purpose. Xcode's toolchain ships no Embedded standard library, so
# the check needs a swift.org toolchain, and that may be older than the tools version the
# manifest asks for. Invoking swiftc directly means the two never have to agree. Set
# DRIFTBOX_EMBEDDED_SWIFTC to choose one; otherwise the newest swift.org toolchain installed on a
# Mac, then whatever `swiftc` is on PATH (which is right inside the swift.org Linux images).
set -eu
cd "$(dirname "$0")/.."

swiftc="${DRIFTBOX_EMBEDDED_SWIFTC:-}"
if [ -z "$swiftc" ]; then
  latest="$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swiftc"
  if [ -x "$latest" ]; then swiftc="$latest"; else swiftc="$(command -v swiftc)"; fi
fi
echo "using $("$swiftc" --version 2>&1 | head -1)"

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# In dependency order, so each module can import the ones before it.
for target in DriftboxDSP DriftboxSeq DriftboxEngine; do
  "$swiftc" -target wasm32-unknown-none-wasm \
    -enable-experimental-feature Embedded -enable-experimental-feature Extern \
    -wmo -O -parse-as-library -swift-version 6 \
    -module-name "$target" -I "$out" \
    -emit-module -emit-module-path "$out/$target.swiftmodule" \
    -c -o "$out/$target.o" \
    $(find "Sources/$target" -name '*.swift' | sort)
  echo "  $target: ok"
done
echo "constrained targets compile as Embedded Swift"

swift build -c release --scratch-path .build-release --quiet
echo "render paths are allocation-free"
