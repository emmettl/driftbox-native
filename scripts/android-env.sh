#!/bin/sh
# What every Android build shares: where the tools are, and how Swift is compiled and linked for a
# phone. Sourced by `android-build.sh`, which makes `driftbox-play`, and `android-app.sh`, which
# makes the app.
#
# Written for the swift.org toolchain on Windows, whose installer brings the Android platform, and
# run from Git Bash. It needs the Android NDK and platform-tools (adb) as well, and finds them
# where Android Studio puts them. Every location can be overridden: DRIFTBOX_SWIFTC,
# DRIFTBOX_ANDROID_SWIFT_SDK, ANDROID_NDK_HOME and ADB.
#
# Linked statically, and from the essentials of Foundation only. The installer's dynamic arm64
# runtime has no libdispatch.so, which full Foundation needs, and its static one no Swift
# Dispatch overlay, which full Foundation also needs; nothing here uses more than the essentials,
# and leaving the rest out is what an Android build wants anyway (see the roadmap). A static link
# does not follow the essentials' own autolinking, so their libraries are named.
set -eu
cd "$(dirname "$0")/.."
# Git Bash would otherwise turn the phone's /data/local/tmp into a Windows path on its way to adb.
export MSYS_NO_PATHCONV=1

local_app_data="${LOCALAPPDATA:-}"
if command -v cygpath >/dev/null 2>&1 && [ -n "$local_app_data" ]; then
  local_app_data="$(cygpath -m "$local_app_data")"
fi
newest() { ls -d "$@" 2>/dev/null | sort -V | tail -1; }

swiftc="${DRIFTBOX_SWIFTC:-$(newest "$local_app_data"/Programs/Swift/Toolchains/*/usr/bin/swiftc.exe)}"
sdk="${DRIFTBOX_ANDROID_SWIFT_SDK:-$(newest "$local_app_data"/Programs/Swift/Platforms/*/Android.platform/Developer/SDKs/Android.sdk)}"
ndk="${ANDROID_NDK_HOME:-$(newest "$local_app_data"/Android/Sdk/ndk/*)}"
adb="${ADB:-$(command -v adb || echo "$local_app_data/Android/Sdk/platform-tools/adb.exe")}"
for need in "$swiftc" "$sdk" "$ndk" "$adb"; do
  [ -e "$need" ] || { echo "not found: $need" >&2; exit 1; }
done
llvm="$(newest "$ndk"/toolchains/llvm/prebuilt/*)"
# Android 10, the first with native MIDI.
target=aarch64-unknown-linux-android29
libcxx="$llvm/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"

# Short on purpose: swiftc on Windows writes nothing, and says nothing, past MAX_PATH.
out="${DRIFTBOX_ANDROID_OUT:-${TMPDIR:-/tmp}/dbxa/arm64}"
mkdir -p "$out"
if command -v cygpath >/dev/null 2>&1; then out="$(cygpath -m "$out")"; fi
echo "using $("$swiftc" --version 2>&1 | head -1), NDK $(basename "$ndk")"

# Everything below the app and the player, in the order they depend on each other.
core="DriftboxDSP DriftboxSeq DriftboxEngine DriftboxRack DriftboxDocument DriftboxHost DriftboxHostAndroid"
# Sources/CAAudio and Sources/CAMidi are where the NDK module maps are found.
common="-target $target -sdk $sdk -sysroot $llvm/sysroot -I $sdk/usr/include -I Sources/CAAudio -I Sources/CAMidi"

# Each module named, compiled whole into $out/<module>.o with its interface beside it.
compile() {
  for module in "$@"; do
    # Gone first, so that a module that fails cannot leave the last build's in its place.
    rm -f "$out/$module.o" "$out/$module.swiftmodule"
    # shellcheck disable=SC2086
    if ! "$swiftc" $common -enable-experimental-feature Extern -wmo -O -parse-as-library -swift-version 6 \
      -module-name "$module" -I "$out" \
      -emit-module -emit-module-path "$out/$module.swiftmodule" -c -o "$out/$module.o" \
      $(find "Sources/$module" -name '*.swift' | sort) >"$out/$module.log" 2>&1; then
      grep -v "libc not found" "$out/$module.log" >&2
      echo "$module did not build" >&2
      exit 1
    fi
    echo "  $module: ok"
  done
}

# The modules named, linked with the Swift runtime into $1; the rest of the arguments go to swiftc,
# `-emit-library` among them for a shared library.
link() {
  product="$1"
  shift
  objects=""
  for module in $core; do objects="$objects $out/$module.o"; done
  rm -f "$product"
  # shellcheck disable=SC2086
  "$swiftc" -target $target -sdk "$sdk" -sysroot "$llvm/sysroot" \
    -resource-dir "$sdk/usr/lib/swift_static" -static-stdlib \
    -L "$(newest "$llvm"/lib/clang/*/lib/linux/aarch64)" \
    $objects "$@" -l_FoundationCollections -l_FoundationCShims -lswift_RegexParser -ldispatch -lBlocksRuntime \
    -o "$product"
  echo "  $(basename "$product"): ok"
}
