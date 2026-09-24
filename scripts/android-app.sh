#!/bin/sh
# Builds the Android app from `android/` and `Sources/DriftboxAndroid`, installs it on the phone,
# and, given a test's name, runs it there and prints what it said:
#
#     scripts/android-app.sh                    # build and install; it opens on Pulse, playing acid
#     scripts/android-app.sh midi-loopback      # and run the MIDI ports against Driftbox Loopback
#     scripts/android-app.sh gpu                # or the GPU contract on the phone's GPU
#     scripts/android-app.sh scenes             # or every scene drawn, checked and timed
#     scripts/android-app.sh text               # or the typesetter, held to what every platform's is
#
# No Gradle: the SDK's own tools, in the order Gradle would call them. Beyond what
# `android-env.sh` needs, a JDK (JAVA_HOME, or the newest under Programs/Java), and the Android
# SDK's build-tools and a platform, found under Android/Sdk as Android Studio lays them out, or at
# ANDROID_HOME.
. "$(dirname "$0")/android-env.sh"

android_home="${ANDROID_HOME:-$local_app_data/Android/Sdk}"
tools="$(newest "$android_home"/build-tools/*)"
platform="$(newest "$android_home"/platforms/android-*)"
export JAVA_HOME="${JAVA_HOME:-$(newest "$local_app_data"/Programs/Java/jdk-*)}"
for need in "$tools/aapt2.exe" "$platform/android.jar" "$JAVA_HOME/bin/javac.exe"; do
  [ -e "$need" ] || { echo "not found: $need" >&2; exit 1; }
done
java_bin="$JAVA_HOME/bin"
if command -v cygpath >/dev/null 2>&1; then java_bin="$(cygpath -u "$java_bin")"; fi
export PATH="$java_bin:$PATH"
jar="$platform/android.jar"
app="$out/app"
rm -rf "$app"
mkdir -p "$app/classes" "$app/dex" "$app/stage/lib/arm64-v8a" "$app/stage/assets/songs"

# The native library: everything the player has, the GPU layer on OpenGL ES, the scenes on it,
# type through Android's own, and the app's own module on top. The app checks the GPU contract with
# the contract tests' own programs.
extra_DriftboxAndroid=Tests/DriftboxGPUTests/Generated/ShaderPrograms.swift
# shellcheck disable=SC2086
compile $core DriftboxGPU DriftboxGPUGLES DriftboxScenes DriftboxText DriftboxTextAndroid DriftboxAndroid
link "$app/stage/lib/arm64-v8a/libdriftbox.so" "$out/DriftboxGPU.o" "$out/DriftboxGPUGLES.o" \
  "$out/DriftboxScenes.o" "$out/DriftboxText.o" "$out/DriftboxTextAndroid.o" "$out/DriftboxAndroid.o" \
  -lGLESv3 -landroid -emit-library -Xlinker -soname=libdriftbox.so
cp "$libcxx" "$app/stage/lib/arm64-v8a/"
# Symbols are half of what the libraries weigh, and the NDK's libc++ comes with all of its own.
for library in "$app"/stage/lib/arm64-v8a/*.so; do "$llvm/bin/llvm-strip.exe" --strip-unneeded "$library"; done

# Java, to dex.
javac --release 17 -Xlint:-options -classpath "$jar" -d "$app/classes" \
  $(find android/java -name '*.java')
"$tools/d8.bat" --release --min-api 29 --lib "$jar" --output "$app/dex" \
  $(find "$app/classes" -name '*.class')
cp "$app/dex/classes.dex" "$app/stage/"

# The manifest and resources, then the dex and the libraries added without compression, which is
# how Android maps a library straight out of the package; then aligned, then signed with a key of
# this machine's own.
"$tools/aapt2.exe" compile --dir android/res -o "$app/resources.zip"
# The catalogue's songs, which the app plays by name: added below with the dex, since aapt2 on
# Windows would name them with backslashes, which Android cannot find.
cp conformance/fixtures/documents/*.song.json "$app/stage/assets/songs/"
"$tools/aapt2.exe" link -o "$app/unaligned.apk" -I "$jar" --manifest android/AndroidManifest.xml \
  --min-sdk-version 29 --target-sdk-version "${platform##*android-}" --version-code 1 --version-name 0.1 \
  "$app/resources.zip"
(cd "$app/stage" && jar -uf0M ../unaligned.apk classes.dex lib assets)
"$tools/zipalign.exe" -f -P 16 4 "$app/unaligned.apk" "$app/aligned.apk"
keystore="$out/debug.keystore"
[ -f "$keystore" ] || keytool -genkeypair -keystore "$keystore" -storepass android -keypass android \
  -alias driftbox -keyalg RSA -validity 10000 -dname "CN=Driftbox debug" >/dev/null 2>&1
"$tools/apksigner.bat" sign --ks "$keystore" --ks-pass pass:android --out "$app/driftbox.apk" "$app/aligned.apk"
echo "  driftbox.apk: ok ($(($(wc -c <"$app/driftbox.apk") / 1024)) KB)"

"$adb" install -r "$app/driftbox.apk" >/dev/null
echo "installed on $("$adb" shell getprop ro.product.model | tr -d '\r')"
[ $# -gt 0 ] || exit 0

"$adb" logcat -c
"$adb" shell am force-stop app.driftbox
"$adb" shell am start -n app.driftbox/.Main --es run "$1" >/dev/null
# Until the test says it is done, or half a minute.
waited=0
until "$adb" logcat -d -s Driftbox:I | grep -q " done$"; do
  waited=$((waited + 1))
  [ $waited -lt 30 ] || { echo "no answer in 30 seconds" >&2; break; }
  sleep 1
done
"$adb" logcat -d -s Driftbox:I AndroidRuntime:E DEBUG:F | grep -v "^---------" | sed -E 's/^.* (I|E|F) [A-Za-z]+ *: //'
