#!/bin/sh
# Builds the Android app from `android/` and `Sources/DriftboxAndroid`, installs it on the phone,
# and, given a test's name, runs it there and prints what it said:
#
#     scripts/android-app.sh                    # build and install; it opens on Pulse, playing acid
#     scripts/android-app.sh build              # build only, for a machine with no phone: CI
#     scripts/android-app.sh bundle             # build, and an App Bundle for Google Play beside it
#     scripts/android-app.sh midi-loopback      # and run the MIDI ports against Driftbox Loopback
#     scripts/android-app.sh gpu                # or the GPU contract on the phone's GPU
#     scripts/android-app.sh scenes             # or every scene drawn, checked and timed
#     scripts/android-app.sh text               # or the typesetter, held to what every platform's is
#     scripts/android-app.sh rack               # or every patch of the rack's opened and run for a second
#
# No Gradle: the SDK's own tools, in the order Gradle would call them. Beyond what
# `android-env.sh` needs, a JDK (JAVA_HOME; or the newest under Programs/Java on Windows, and the
# one `java_home` names on a Mac), and the Android SDK's build-tools and a platform, found where
# `android-env.sh` finds the SDK.
. "$(dirname "$0")/android-env.sh"
# The version and build the Mac's release carries too: the build is Android's version code, which
# only ever goes up.
. scripts/version.env

tools="$(newest "$android_sdk"/build-tools/*)"
platform="$(newest "$android_sdk"/platforms/android-*)"
case $host in
  windows) export JAVA_HOME="${JAVA_HOME:-$(newest "$local_app_data"/Programs/Java/jdk-*)}" ;;
  macos) export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home 2>/dev/null || true)}" ;;
esac
for need in "$tools/aapt2$exe" "$platform/android.jar" "${JAVA_HOME:-}/bin/javac$exe"; do
  [ -e "$need" ] || { echo "not found: $need" >&2; exit 1; }
done
java_bin="$JAVA_HOME/bin"
if [ $host = windows ]; then java_bin="$(cygpath -u "$java_bin")"; fi
export PATH="$java_bin:$PATH"
jar="$platform/android.jar"
app="$out/app"
rm -rf "$app"
mkdir -p "$app/classes" "$app/dex" "$app/stage/lib/arm64-v8a" "$app/stage/assets"

# The native library: everything the player has, the GPU layer on OpenGL ES, the scenes on it,
# type through Android's own and the canvas it is printed on, the session and the controls over
# the scene, the touch screen that puts them together, and the app's own module on top. The app
# checks the GPU contract with the contract tests' own programs.
extra_DriftboxAndroid=Tests/DriftboxGPUTests/Generated/ShaderPrograms.swift
# The rack session and the rack's controls are in it, though the phone does not show the rack yet.
modules="DriftboxGPU DriftboxGPUGLES DriftboxText DriftboxTextAndroid DriftboxCanvas DriftboxScenes DriftboxShell \
  DriftboxSession DriftboxRackSession DriftboxInterface DriftboxTouch DriftboxAndroid"
# shellcheck disable=SC2086
compile $core $modules
objects=""
for module in $modules; do objects="$objects $out/$module.o"; done
# shellcheck disable=SC2086
link "$app/stage/lib/arm64-v8a/libdriftbox.so" $objects -lswiftObservation -lGLESv3 -landroid -emit-library \
  -Xlinker -soname=libdriftbox.so
cp "$libcxx" "$app/stage/lib/arm64-v8a/"
# The Swift runtime is built against one NDK's C++ library, and a library linked with an older one
# links, and is refused by the phone when it loads, for want of a function the older library does
# not have. So every one it wants from libc++ is looked for in the libc++ it will load with.
"$llvm/bin/llvm-nm$exe" -D -u "$app/stage/lib/arm64-v8a/libdriftbox.so" | awk '{ print $2 }' |
  grep '^_ZN.*St6__ndk1' | sort -u >"$app/wanted.txt" || true
"$llvm/bin/llvm-nm$exe" -D --defined-only "$libcxx" | awk '{ print $3 }' | sort -u >"$app/libcxx.txt"
missing="$(comm -23 "$app/wanted.txt" "$app/libcxx.txt")"
if [ -n "$missing" ]; then
  echo "$missing" >&2
  echo "NDK $(basename "$ndk")'s libc++ lacks what $release's Swift runtime needs: use the NDK swift.org names for it" >&2
  exit 1
fi
# Symbols are half of what the libraries weigh, and the NDK's libc++ comes with all of its own.
for library in "$app"/stage/lib/arm64-v8a/*.so; do "$llvm/bin/llvm-strip$exe" --strip-unneeded "$library"; done

# Java, to dex.
javac --release 17 -Xlint:-options -classpath "$jar" -d "$app/classes" \
  $(find android/java -name '*.java')
"$tools/d8$bat" --release --min-api 29 --lib "$jar" --output "$app/dex" \
  $(find "$app/classes" -name '*.class')
cp "$app/dex/classes.dex" "$app/stage/"

# The manifest and resources, then the dex and the libraries added without compression, which is
# how Android maps a library straight out of the package; then aligned, then signed with a key of
# this machine's own.
"$tools/aapt2$exe" compile --dir android/res -o "$app/resources.zip"
# The session's resources, the catalogue and its songs, which the app unpacks and plays by name,
# and beside them the rack's, its modules' faces and its patches: added below with the dex, since
# aapt2 on Windows would name them with backslashes, which Android cannot find.
cp -r Sources/DriftboxSession/Resources "$app/stage/assets/"
cp -r Sources/DriftboxRackSession/Resources/. "$app/stage/assets/Resources/"
"$tools/aapt2$exe" link -o "$app/unaligned.apk" -I "$jar" --manifest android/AndroidManifest.xml \
  --min-sdk-version 29 --target-sdk-version "${platform##*android-}" \
  --version-code "$DRIFTBOX_BUILD" --version-name "$DRIFTBOX_VERSION" "$app/resources.zip"
(cd "$app/stage" && jar -uf0M ../unaligned.apk classes.dex lib assets)
"$tools/zipalign$exe" -f -P 16 4 "$app/unaligned.apk" "$app/aligned.apk"
keystore="$out/debug.keystore"
[ -f "$keystore" ] || keytool -genkeypair -keystore "$keystore" -storepass android -keypass android \
  -alias driftbox -keyalg RSA -validity 10000 -dname "CN=Driftbox debug" >/dev/null 2>&1
"$tools/apksigner$bat" sign --ks "$keystore" --ks-pass pass:android --out "$app/driftbox.apk" "$app/aligned.apk"
echo "  driftbox.apk: ok ($(($(wc -c <"$app/driftbox.apk") / 1024)) KB)"
if [ "${1:-}" = bundle ]; then
  # The same, as an App Bundle, which is what Google Play takes: the resources linked again in the
  # protocol buffer form a bundle holds, and every piece laid out as a bundle's base module, then
  # made into one by Google's bundletool (DRIFTBOX_BUNDLETOOL, or the newest jar under the Android
  # folder beside the SDK). Unsigned: a release signs it with its upload key.
  bundletool="${DRIFTBOX_BUNDLETOOL:-$(newest "$(dirname "$android_sdk")"/bundletool/bundletool-all-*.jar)}"
  [ -f "$bundletool" ] || { echo "not found: bundletool (DRIFTBOX_BUNDLETOOL)" >&2; exit 1; }
  "$tools/aapt2$exe" link --proto-format -o "$app/proto.zip" -I "$jar" --manifest android/AndroidManifest.xml \
    --min-sdk-version 29 --target-sdk-version "${platform##*android-}" \
    --version-code "$DRIFTBOX_BUILD" --version-name "$DRIFTBOX_VERSION" "$app/resources.zip"
  base="$app/base"
  rm -rf "$base" "$app/base.zip"
  mkdir -p "$base/manifest" "$base/dex"
  (cd "$base" && jar -xf ../proto.zip)
  mv "$base/AndroidManifest.xml" "$base/manifest/"
  cp "$app/dex/classes.dex" "$base/dex/"
  cp -r "$app/stage/lib" "$app/stage/assets" "$base/"
  jar --create --no-manifest --file "$app/base.zip" -C "$base" .
  java -jar "$bundletool" build-bundle --modules="$app/base.zip" --output="$app/driftbox.aab" \
    --config=android/bundle.json --overwrite
  echo "  driftbox.aab: ok ($(($(wc -c <"$app/driftbox.aab") / 1024)) KB)"
fi
if [ "${1:-}" = build ] || [ "${1:-}" = bundle ]; then
  echo "built $app/driftbox.apk"
  exit 0
fi

need_adb
"$adb" install -r "$app/driftbox.apk" >/dev/null
echo "installed on $("$adb" shell getprop ro.product.model | tr -d '\r')"
[ $# -gt 0 ] || exit 0

"$adb" logcat -c
"$adb" shell am force-stop app.driftbox
# The screen on, which the scenes are drawn to: an emulator with no window starts with it off.
"$adb" shell input keyevent KEYCODE_WAKEUP
"$adb" shell wm dismiss-keyguard
"$adb" shell am start -n app.driftbox/.Main --es run "$1" >/dev/null
# Until the test says it is done, or half a minute; longer where the GPU is slower than a phone's,
# as an emulator's drawing in software is: DRIFTBOX_ANDROID_WAIT seconds.
limit="${DRIFTBOX_ANDROID_WAIT:-30}"
waited=0
until "$adb" logcat -d -s Driftbox:I | grep -q " done$"; do
  waited=$((waited + 1))
  [ $waited -lt "$limit" ] || { echo "no answer in $limit seconds" >&2; break; }
  sleep 1
done
"$adb" logcat -d -s Driftbox:I AndroidRuntime:E DEBUG:F | grep -v "^---------" | sed -E 's/^.* (I|E|F) [A-Za-z]+ *: //'
