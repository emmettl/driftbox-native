#!/bin/sh
# Builds `driftbox-play` for an arm64 Android phone and runs its bench there over adb, once on each
# kind of core the phone has: step 1 of milestone 5. No app and no install: Android runs a plain
# executable from /data/local/tmp.
#
#     scripts/android-bench.sh                          # acid, on every kind of core
#     scripts/android-bench.sh conformance/fixtures/documents/orrery.song.json
#
# Written for the swift.org toolchain on Windows, whose installer brings the Android platform, and
# run from Git Bash. It needs the Android NDK and platform-tools (adb) as well, and finds them
# where Android Studio puts them. Every location can be overridden: DRIFTBOX_SWIFTC,
# DRIFTBOX_ANDROID_SWIFT_SDK, ANDROID_NDK_HOME and ADB.
#
# Linked statically, and from the essentials of Foundation only. The installer's dynamic arm64
# runtime has no libdispatch.so, which full Foundation needs, and its static one no Swift
# Dispatch overlay, which full Foundation also needs; nothing below the bench uses more than the
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
target=aarch64-unknown-linux-android28

# Short on purpose: swiftc on Windows writes nothing, and says nothing, past MAX_PATH.
out="${DRIFTBOX_ANDROID_OUT:-${TMPDIR:-/tmp}/dbxa/arm64}"
mkdir -p "$out"
if command -v cygpath >/dev/null 2>&1; then out="$(cygpath -m "$out")"; fi
echo "using $("$swiftc" --version 2>&1 | head -1), NDK $(basename "$ndk")"

common="-target $target -sdk $sdk -sysroot $llvm/sysroot -I $sdk/usr/include"
for module in DriftboxDSP DriftboxSeq DriftboxEngine DriftboxRack DriftboxDocument DriftboxHost; do
  # shellcheck disable=SC2086
  "$swiftc" $common -enable-experimental-feature Extern -wmo -O -parse-as-library -swift-version 6 \
    -module-name "$module" -I "$out" \
    -emit-module -emit-module-path "$out/$module.swiftmodule" -c -o "$out/$module.o" \
    $(find "Sources/$module" -name '*.swift' | sort) 2>&1 | grep -v "libc not found" || true
  [ -f "$out/$module.o" ] || { echo "$module did not build" >&2; exit 1; }
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
[ $# -gt 0 ] || set -- conformance/fixtures/documents/acid.song.json
echo "on $("$adb" shell getprop ro.product.model | tr -d '\r'), $("$adb" shell getprop ro.soc.model | tr -d '\r')"
for song in "$@"; do
  "$adb" push -q "$song" "$phone/"
  # The first core of each speed, which is one of each kind: little, big and any prime.
  "$adb" shell "cd $phone && chmod 755 driftbox-play && seen= &&
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
      n=\${cpu##*cpu}; hz=\$(cat \$cpu/cpufreq/cpuinfo_max_freq)
      case \" \$seen \" in *\" \$hz \"*) continue;; esac; seen=\"\$seen \$hz\"
      echo \"cpu\$n, up to \$((hz / 1000))MHz:\"
      LD_LIBRARY_PATH=. taskset \$(printf %x \$((1 << n))) ./driftbox-play $(basename "$song") --bench | sed 's/^/  /'
    done"
done
