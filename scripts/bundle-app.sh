#!/bin/sh
# Wraps the release Driftbox executable in a minimal application bundle, so the system treats it
# as an app: a Dock icon, activation, a bundle identifier. With the rack and the groovebox inside it
# as an AUv3 extension, for other apps to load. Signed ad hoc, for this machine; local use only.
set -eu
cd "$(dirname "$0")/.."
. scripts/version.env
# The version an Audio Unit host keeps a component by, and scans it again when it changes: the
# release's, as Apple packs one, a byte each for minor and patch.
component_version=$(echo "$DRIFTBOX_VERSION" | awk -F. '{ print $1 * 65536 + $2 * 256 + $3 }')
swift build -c release --scratch-path .build-release --product Driftbox
swift build -c release --scratch-path .build-release --product DriftboxAudioUnits
app=.build-release/Driftbox.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build-release/release/Driftbox "$app/Contents/MacOS/Driftbox"
# Every target's resource bundle — the app's, the session's songs, the rack session's patches and
# cards — in Resources, where Bundle.module looks first. A bundle left out is found at its absolute
# build path instead, which works on this machine and nowhere else; one beside the executable stops
# the bundle being signed.
for bundle in .build-release/release/DriftboxKit_*.bundle; do
  cp -R "$bundle" "$app/Contents/Resources/"
done
# The icon, where the Finder and the Dock look for one. `scripts/make-icon.swift` draws it.
cp Sources/DriftboxApp/Resources/AppIcon.icns "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Driftbox</string>
  <key>CFBundleIdentifier</key><string>app.driftbox.native</string>
  <key>CFBundleName</key><string>Driftbox</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$DRIFTBOX_VERSION</string>
  <key>CFBundleVersion</key><string>$DRIFTBOX_BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- What the Mac says when it asks whether Driftbox may listen: the first time a rack patch with
       an Audio Input module plays. Without it the system ends the app rather than ask. -->
  <key>NSMicrophoneUsageDescription</key>
  <string>The rack's Audio Input module plays what comes in from a microphone or an interface.</string>
  <!-- A song is JSON, and claiming every .json file on the machine would be rude, so songs get a
       type of their own under the bundle identifier which conforms to JSON, so that whatever
       could read one still can. Declaring it is what lets a double-click in the Finder and a drop
       on the dock icon reach the app at all. .driftbox first, which makes it what Save proposes;
       .song.json after it, for songs saved before there was one. -->
  <key>UTExportedTypeDeclarations</key>
  <array><dict>
    <key>UTTypeIdentifier</key><string>app.driftbox.native.song</string>
    <key>UTTypeDescription</key><string>Driftbox Song</string>
    <key>UTTypeConformsTo</key><array><string>public.json</string></array>
    <key>UTTypeTagSpecification</key><dict>
      <key>public.filename-extension</key><array><string>driftbox</string><string>song.json</string></array>
    </dict>
  </dict></array>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Driftbox Song</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSItemContentTypes</key><array><string>app.driftbox.native.song</string></array>
  </dict></array>
</dict></plist>
PLIST

# The rack and the groovebox as an AUv3 app extension: two instruments that Logic, GarageBand or
# any other app can load, out of process. SwiftPM builds its executable, whose entry point is
# NSExtensionMain; the bundle around it is made here, as Xcode would make it.
ext="$app/Contents/PlugIns/DriftboxAudioUnits.appex"
mkdir -p "$ext/Contents/MacOS" "$ext/Contents/Resources"
cp .build-release/release/DriftboxAudioUnits "$ext/Contents/MacOS/DriftboxAudioUnits"
for bundle in .build-release/release/DriftboxKit_*.bundle; do
  cp -R "$bundle" "$ext/Contents/Resources/"
done
cat > "$ext/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>DriftboxAudioUnits</string>
  <key>CFBundleIdentifier</key><string>app.driftbox.native.audiounits</string>
  <key>CFBundleName</key><string>Driftbox Audio Units</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$DRIFTBOX_VERSION</string>
  <key>CFBundleVersion</key><string>$DRIFTBOX_BUILD</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSExtension</key><dict>
    <!-- Audio Units with faces: each instrument's own, in the app's window. -->
    <key>NSExtensionPointIdentifier</key><string>com.apple.AudioUnit-UI</string>
    <!-- AudioUnitViewController, the face and the factory both, by the Objective-C name it gives
         itself; it makes whichever instrument the subtype asks for. -->
    <key>NSExtensionPrincipalClass</key><string>DriftboxAudioUnitViewController</string>
    <key>NSExtensionAttributes</key><dict>
      <key>AudioComponents</key><array><dict>
        <key>description</key><string>Driftbox Rack</string>
        <key>factoryFunction</key><string>DriftboxAudioUnitViewController</string>
        <!-- RackAudioUnit.componentDescription: an instrument, 'drck' by 'Drfb'. -->
        <key>manufacturer</key><string>Drfb</string>
        <key>name</key><string>Driftbox: Rack</string>
        <key>sandboxSafe</key><true/>
        <key>subtype</key><string>drck</string>
        <key>tags</key><array><string>Synthesizer</string></array>
        <key>type</key><string>aumu</string>
        <key>version</key><integer>$component_version</integer>
      </dict><dict>
        <key>description</key><string>Driftbox Groovebox</string>
        <key>factoryFunction</key><string>DriftboxAudioUnitViewController</string>
        <!-- GrooveboxAudioUnit.componentDescription: an instrument, 'drgb' by 'Drfb'. -->
        <key>manufacturer</key><string>Drfb</string>
        <key>name</key><string>Driftbox: Groovebox</string>
        <key>sandboxSafe</key><true/>
        <key>subtype</key><string>drgb</string>
        <key>tags</key><array><string>Drums</string><string>Synthesizer</string></array>
        <key>type</key><string>aumu</string>
        <key>version</key><integer>$component_version</integer>
      </dict></array>
    </dict>
  </dict>
</dict></plist>
PLIST
# Inside out: the extension, sandboxed, then the app around it. Ad hoc, for this machine; a release
# is signed again, for everyone's, by scripts/release.py.
codesign --force --sign - --entitlements scripts/extension.entitlements "$ext"
codesign --force --sign - --entitlements scripts/app.entitlements "$app"

# A bundle sitting in a build directory is not something the system goes looking for, so the type
# it has just declared and the extension inside it are announced by hand. Nothing is installed;
# they are registered where they stand, which is what a local build wants.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$lsregister" ] && "$lsregister" -f "$app"
pluginkit -a "$ext"
echo "built $app"
