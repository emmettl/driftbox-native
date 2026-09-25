#!/bin/sh
# What every Android build shares: where the tools are, and how Swift is compiled and linked for a
# phone. Sourced by `android-build.sh`, which makes `driftbox-play`, and `android-app.sh`, which
# makes the app.
#
# Written for the swift.org toolchain on Windows, run from Git Bash, with swift.org's own Swift SDK
# for Android beside it (its artifact bundle, unpacked under Programs/Swift/SDKs), the Android NDK
# and platform-tools (adb), found where Android Studio puts them. Every location can be
# overridden: DRIFTBOX_SWIFTC, DRIFTBOX_ANDROID_SWIFT_SDK (the bundle's swift-android folder),
# ANDROID_NDK_HOME and ADB.
#
# swift.org's SDK rather than the Android platform the Windows installer brings: that one's standard
# library has no SIMD types, which the GPU layer is written in, and its arm64 runtime lacks
# libdispatch.so and the static Dispatch overlay, without which Foundation will not link. Linked
# statically; a static link does not follow every library's own autolinking, so they are named.
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
bundle="${DRIFTBOX_ANDROID_SWIFT_SDK:-$(newest "$local_app_data"/Programs/Swift/SDKs/swift-*_android.artifactbundle/swift-android)}"
ndk="${ANDROID_NDK_HOME:-$(newest "$local_app_data"/Android/Sdk/ndk/*)}"
adb="${ADB:-$(command -v adb || echo "$local_app_data/Android/Sdk/platform-tools/adb.exe")}"
for need in "$swiftc" "$bundle" "$ndk" "$adb"; do
  [ -e "$need" ] || { echo "not found: $need" >&2; exit 1; }
done
llvm="$(newest "$ndk"/toolchains/llvm/prebuilt/*)"
resources="$bundle/swift-resources/usr/lib"
sdk="$bundle/ndk-sysroot"

# The bundle wants its ndk-sysroot made once, from the NDK: its own script does it with symlinks,
# which Windows makes only for an administrator, so there it is done with junctions instead, the
# start-up objects copied. And tar on Windows leaves the bundle's links to clang's headers as empty
# files, which the compiler's own copy of those headers stands in for.
if [ ! -d "$sdk/usr/include" ]; then
  if command -v cygpath >/dev/null 2>&1; then
    mkdir -p "$sdk/usr/lib"
    cmd //c "mklink /J $(cygpath -w "$sdk/usr/include") $(cygpath -w "$llvm/sysroot/usr/include")" >/dev/null
    for triple in aarch64-linux-android x86_64-linux-android; do
      cmd //c "mklink /J $(cygpath -w "$sdk/usr/lib/$triple") $(cygpath -w "$llvm/sysroot/usr/lib/$triple")" >/dev/null
    done
    for folder in swift swift_static; do
      for start in "$resources"/"$folder"-*/android/*/swiftrt.o; do
        arch="$(basename "$(dirname "$start")")"
        mkdir -p "$sdk/usr/lib/$folder/android/$arch"
        cp "$start" "$sdk/usr/lib/$folder/android/$arch/"
      done
    done
  else
    ANDROID_NDK_HOME="$ndk" "$bundle/scripts/setup-android-sdk.sh"
  fi
  echo "set up $sdk"
fi
for clang in "$resources"/swift*-*/clang; do
  if [ -f "$clang" ] && [ ! -s "$clang" ]; then
    rm "$clang"
    cp -r "$(dirname "$swiftc")/../lib/swift/clang" "$clang"
  fi
done

# Android 10, the first with native MIDI.
target=aarch64-unknown-linux-android29
libcxx="$llvm/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"

# Short on purpose: swiftc on Windows writes nothing, and says nothing, past MAX_PATH.
out="${DRIFTBOX_ANDROID_OUT:-${TMPDIR:-/tmp}/dbxa/arm64}"
mkdir -p "$out"
if command -v cygpath >/dev/null 2>&1; then out="$(cygpath -m "$out")"; fi
echo "using $("$swiftc" --version 2>&1 | head -1), $(basename "$(dirname "$bundle")"), NDK $(basename "$ndk")"

# Everything below the app and the player, in the order they depend on each other.
core="DriftboxDSP DriftboxSeq DriftboxEngine DriftboxRack DriftboxDocument DriftboxHost DriftboxHostAndroid"
# Sources/CAAudio, CAMidi and CGLES are where the NDK module maps are found.
common="-target $target -resource-dir $resources/swift-aarch64 -sdk $sdk -I Sources/CAAudio -I Sources/CAMidi -I Sources/CGLES"
# `import Foundation` is the old Foundation on Android, over FoundationEssentials, and a module that
# imports it links it and its internationalisation: 48MB, most of it ICU's data. Nothing here uses
# either — what Driftbox takes from Foundation is FoundationEssentials' — but a library linked is a
# library searched, and the linker once found a function FoundationEssentials needs in the old
# Foundation first and brought all of it in. So neither is linked, and `link` fails a library that
# still asks for one.
common="$common -Xfrontend -disable-autolink-library -Xfrontend Foundation"
common="$common -Xfrontend -disable-autolink-library -Xfrontend FoundationInternationalization"

# Each module named, compiled whole into $out/<module>.o with its interface beside it: its sources,
# but for any whose paths match the pattern a caller names in `skip_<module>`, and any a caller
# names in `extra_<module>`.
compile() {
  for module in "$@"; do
    # Gone first, so that a module that fails cannot leave the last build's in its place.
    rm -f "$out/$module.o" "$out/$module.swiftmodule"
    extra="$(eval echo "\${extra_$module:-}")"
    skip="$(eval echo "\${skip_$module:-}")"
    sources="$(find "Sources/$module" -name '*.swift' | sort)"
    [ -z "$skip" ] || sources="$(echo "$sources" | grep -vE "$skip")"
    # shellcheck disable=SC2086
    if ! "$swiftc" $common -enable-experimental-feature Extern -wmo -O -parse-as-library -swift-version 6 \
      -module-name "$module" -I "$out" \
      -emit-module -emit-module-path "$out/$module.swiftmodule" -c -o "$out/$module.o" \
      $sources $extra >"$out/$module.log" 2>&1; then
      cat "$out/$module.log" >&2
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
  "$swiftc" -target $target -sdk "$sdk" -resource-dir "$resources/swift_static-aarch64" -static-stdlib \
    -L "$(newest "$llvm"/lib/clang/*/lib/linux/aarch64)" \
    $objects "$@" -lswiftSynchronization -lswiftDispatch -ldispatch -lBlocksRuntime -lswift_RegexParser \
    -lCoreFoundation -l_FoundationCollections -l_FoundationCShims -l_FoundationICU \
    -o "$product"
  # A shared library links with symbols it cannot find, and the phone only refuses it when it
  # loads: so a use of the old Foundation is looked for here instead.
  old="$("$llvm/bin/llvm-nm.exe" -D -u "$product" | grep -E '\$s10Foundation|\$s31FoundationInternationalization' || true)"
  if [ -n "$old" ]; then
    echo "$old" >&2
    echo "$(basename "$product") uses the old Foundation, which is not linked" >&2
    exit 1
  fi
  echo "  $(basename "$product"): ok"
}
