#!/bin/sh
# Builds `driftbox-play` for an arm64 Android phone and pushes it there over adb, to $phone. Sourced
# by `android-bench.sh` and `android-play.sh`, which say what to run once it is there. No app and
# no install: Android runs a plain executable from /data/local/tmp.
#
# Written for the swift.org toolchain on Windows, whose installer brings the Android platform, and
# run from Git Bash. It needs the Android NDK and platform-tools (adb) as well, and finds them
# where Android Studio puts them. Every location can be overridden: DRIFTBOX_SWIFTC,
# DRIFTBOX_ANDROID_SWIFT_SDK, ANDROID_NDK_HOME and ADB.
#
# Linked statically, and from the essentials of Foundation only. The installer's dynamic arm64
# runtime has no libdispatch.so, which full Foundation needs, and its static one no Swift
# Dispatch overlay, which full Foundation also needs; nothing in `driftbox-play` uses more than the
# essentials, and leaving the rest out is what an Android build wants anyway (see the roadmap).
# A static link does not follow the essentials' own autolinking, so their libraries are named.
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

# Short on purpose: swiftc on Windows writes nothing, and says nothing, past MAX_PATH.
out="${DRIFTBOX_ANDROID_OUT:-${TMPDIR:-/tmp}/dbxa/arm64}"
mkdir -p "$out"
if command -v cygpath >/dev/null 2>&1; then out="$(cygpath -m "$out")"; fi
echo "using $("$swiftc" --version 2>&1 | head -1), NDK $(basename "$ndk")"

# Sources/CAAudio and Sources/CAMidi are where the NDK module maps are found.
common="-target $target -sdk $sdk -sysroot $llvm/sysroot -I $sdk/usr/include -I Sources/CAAudio -I Sources/CAMidi"
for module in DriftboxDSP DriftboxSeq DriftboxEngine DriftboxRack DriftboxDocument DriftboxHost DriftboxHostAndroid; do
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
# shellcheck disable=SC2086
"$swiftc" $common -wmo -O -parse-as-library -swift-version 6 -module-name driftbox_play -I "$out" \
  -c -o "$out/driftbox-play.o" Sources/driftbox-play/*.swift
# shellcheck disable=SC2086
"$swiftc" -target $target -sdk "$sdk" -sysroot "$llvm/sysroot" \
  -resource-dir "$sdk/usr/lib/swift_static" -static-stdlib \
  -L "$(newest "$llvm"/lib/clang/*/lib/linux/aarch64)" \
  "$out"/*.o -l_FoundationCollections -l_FoundationCShims -lswift_RegexParser -ldispatch -lBlocksRuntime \
  -o "$out/driftbox-play"
echo "  driftbox-play: ok"

phone=/data/local/tmp/driftbox
"$adb" shell mkdir -p "$phone"
"$adb" push -q "$out/driftbox-play" "$llvm/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$phone/"
"$adb" shell chmod 755 "$phone/driftbox-play"
echo "on $("$adb" shell getprop ro.product.model | tr -d '\r'), $("$adb" shell getprop ro.soc.model | tr -d '\r')"
