#!/bin/sh
# What every Android build shares: where the tools are, and how Swift is compiled and linked for a
# phone. Sourced by `android-build.sh`, which makes `driftbox-play`, and `android-app.sh`, which
# makes the app.
#
# Built with a swift.org toolchain and swift.org's Swift SDK for Android of the same version, and
# the Android NDK, on any of the three: Windows, from Git Bash; macOS; or Linux, which CI builds on.
# Each is found where its installer puts it on that platform, and every location can be overridden:
# DRIFTBOX_SWIFTC, DRIFTBOX_ANDROID_SWIFT_SDK (the bundle's swift-android folder), ANDROID_NDK_HOME
# and ADB. A phone, and adb, are needed only to install and run.
#
#     Windows  the toolchain and the SDK under %LOCALAPPDATA%\Programs\Swift, the NDK and adb
#              under %LOCALAPPDATA%\Android\Sdk, where Android Studio puts them
#     macOS    the toolchain in ~/Library/Developer/Toolchains (not Xcode's own Swift, which the
#              SDK is not built for), the SDK where `swift sdk install` puts it, the NDK and adb
#              under ~/Library/Android/sdk
#     Linux    swiftc on the PATH, the SDK where `swift sdk install` puts it, the NDK at
#              ANDROID_NDK_HOME or under ANDROID_HOME
#
# swift.org's SDK rather than the Android platform the Windows installer brings: that one's standard
# library has no SIMD types, which the GPU layer is written in, and its arm64 runtime lacks
# libdispatch.so and the static Dispatch overlay, without which Foundation will not link. Linked
# statically; a static link does not follow every library's own autolinking, so they are named.
set -eu
cd "$(dirname "$0")/.."
# Git Bash would otherwise turn the phone's /data/local/tmp into a Windows path on its way to adb.
export MSYS_NO_PATHCONV=1

newest() { ls -d "$@" 2>/dev/null | sort -V | tail -1; }

# What the host is, and what its tools are called there: the SDK's build tools are scripts ending
# .bat on Windows, and every executable ends .exe.
if command -v cygpath >/dev/null 2>&1; then
  host=windows exe=.exe bat=.bat
  local_app_data="$(cygpath -m "${LOCALAPPDATA:-}")"
  swift_sdks="$local_app_data/Programs/Swift/SDKs"
  android_sdk="${ANDROID_HOME:-$local_app_data/Android/Sdk}"
elif [ "$(uname)" = Darwin ]; then
  host=macos exe= bat=
  swift_sdks="$HOME/Library/org.swift.swiftpm/swift-sdks"
  android_sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
else
  host=linux exe= bat=
  swift_sdks="$HOME/.swiftpm/swift-sdks"
  android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
fi

bundle="${DRIFTBOX_ANDROID_SWIFT_SDK:-$(newest "$swift_sdks"/swift-*_android.artifactbundle/swift-android)}"
# The toolchain the SDK was made for: its version is in the bundle's name.
release="$(basename "$(dirname "$bundle")" | sed 's/_android.artifactbundle$//')"
case $host in
  windows) swiftc="${DRIFTBOX_SWIFTC:-$(newest "$local_app_data"/Programs/Swift/Toolchains/*/usr/bin/swiftc.exe)}" ;;
  macos) swiftc="${DRIFTBOX_SWIFTC:-$HOME/Library/Developer/Toolchains/$release.xctoolchain/usr/bin/swiftc}" ;;
  linux) swiftc="${DRIFTBOX_SWIFTC:-$(command -v swiftc || true)}" ;;
esac
ndk="${ANDROID_NDK_HOME:-$(newest "$android_sdk"/ndk/*)}"
adb="${ADB:-$(command -v adb || echo "$android_sdk/platform-tools/adb$exe")}"
for need in "$swiftc" "$bundle" "$ndk"; do
  [ -e "$need" ] || { echo "not found: $need" >&2; exit 1; }
done
# adb, and a phone, only for what is put on one.
need_adb() {
  [ -e "$adb" ] || { echo "not found: $adb" >&2; exit 1; }
}
llvm="$(newest "$ndk"/toolchains/llvm/prebuilt/*)"
resources="$bundle/swift-resources/usr/lib"
sdk="$bundle/ndk-sysroot"

# The bundle wants its ndk-sysroot made once, from the NDK: its own script does it with symlinks,
# which Windows makes only for an administrator, so there it is done with junctions instead, the
# start-up objects copied. And tar on Windows leaves the bundle's links to clang's headers as empty
# files, which the compiler's own copy of those headers stands in for.
# Made again when it was made from another NDK than this one, which an NDK updated leaves behind.
if [ $host != windows ] && [ -L "$sdk/usr/include" ] && [ "$(readlink "$sdk/usr/include")" != "$llvm/sysroot/usr/include" ]; then
  rm -rf "$sdk"
fi
if [ ! -d "$sdk/usr/include" ]; then
  if [ $host = windows ]; then
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
    (cd "$bundle" && ANDROID_NDK_HOME="$ndk" bash scripts/setup-android-sdk.sh >/dev/null)
  fi
  echo "set up $sdk"
fi
for clang in "$resources"/swift*-*/clang; do
  if [ -f "$clang" ] && [ ! -s "$clang" ]; then
    rm "$clang"
    cp -r "$(dirname "$swiftc")/../lib/swift/clang" "$clang"
  fi
done

# The compiler's runtime, which clang links, from the NDK: a macOS or Linux toolchain's clang would
# look in its own resource directory, which has none for Android. Windows' finds the NDK's already.
runtime=""
[ $host = windows ] || runtime="-Xclang-linker -resource-dir -Xclang-linker $(newest "$llvm"/lib/clang/*)"

# Android 10, the first with native MIDI.
target=aarch64-unknown-linux-android29
libcxx="$llvm/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"

# Short on purpose: swiftc on Windows writes nothing, and says nothing, past MAX_PATH.
out="${DRIFTBOX_ANDROID_OUT:-${TMPDIR:-/tmp}/dbxa/arm64}"
mkdir -p "$out"
if [ $host = windows ]; then out="$(cygpath -m "$out")"; fi
echo "using $("$swiftc" --version 2>&1 | head -1), $(basename "$(dirname "$bundle")"), NDK $(basename "$ndk")"

# Everything below the app and the player, in the order they depend on each other.
core="DriftboxDSP DriftboxSeq DriftboxEngine DriftboxRack DriftboxDocument DriftboxHost DriftboxHostAndroid"
# Sources/CAAudio, CAMidi, CGLES, CLooper and CMedia are where the NDK module maps are found.
common="-target $target -resource-dir $resources/swift-aarch64 -sdk $sdk -I Sources/CAAudio -I Sources/CAMidi -I Sources/CGLES -I Sources/CLooper -I Sources/CMedia"
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
    -L "$(newest "$llvm"/lib/clang/*/lib/linux/aarch64)" $runtime \
    $objects "$@" -lswiftSynchronization -lswiftDispatch -ldispatch -lBlocksRuntime -lswift_RegexParser \
    -lCoreFoundation -l_FoundationCollections -l_FoundationCShims -l_FoundationICU \
    -o "$product"
  # A shared library links with symbols it cannot find, and the phone only refuses it when it
  # loads: so a use of the old Foundation is looked for here instead. Anywhere in the name, which
  # is where its extensions of the standard library's types put it: `$sSy10FoundationE…` is
  # StringProtocol's localizedCaseInsensitiveCompare.
  old="$("$llvm/bin/llvm-nm$exe" -D -u "$product" | grep -E '\$s.*(10Foundation|31FoundationInternationalization)' || true)"
  if [ -n "$old" ]; then
    echo "$old" >&2
    echo "$(basename "$product") uses the old Foundation, which is not linked" >&2
    exit 1
  fi
  echo "  $(basename "$product"): ok"
}
