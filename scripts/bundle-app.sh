#!/bin/sh
# Wraps the release Driftbox executable in a minimal application bundle, so the system treats it
# as an app: a Dock icon, activation, a bundle identifier. With the rack inside it as an AUv3
# extension, for other apps to load. Signed ad hoc, for this machine; local use only.
set -eu
cd "$(dirname "$0")/.."
swift build -c release --scratch-path .build-release --product Driftbox
swift build -c release --scratch-path .build-release --product DriftboxRackExtension
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
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
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

# The rack as an AUv3 app extension: an Audio Unit that Logic, GarageBand or any other app can load,
# out of process. SwiftPM builds its executable, whose entry point is NSExtensionMain; the bundle
# around it is made here, as Xcode would make it.
ext="$app/Contents/PlugIns/DriftboxRack.appex"
mkdir -p "$ext/Contents/MacOS" "$ext/Contents/Resources"
cp .build-release/release/DriftboxRackExtension "$ext/Contents/MacOS/DriftboxRackExtension"
for bundle in .build-release/release/DriftboxKit_*.bundle; do
  cp -R "$bundle" "$ext/Contents/Resources/"
done
cat > "$ext/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>DriftboxRackExtension</string>
  <key>CFBundleIdentifier</key><string>app.driftbox.native.rack</string>
  <key>CFBundleName</key><string>Driftbox Rack</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSExtension</key><dict>
    <!-- An Audio Unit with a face: the rack's own, in the app's window. -->
    <key>NSExtensionPointIdentifier</key><string>com.apple.AudioUnit-UI</string>
    <!-- RackViewController, the face and the factory both, by the Objective-C name it gives itself. -->
    <key>NSExtensionPrincipalClass</key><string>DriftboxRackViewController</string>
    <key>NSExtensionAttributes</key><dict>
      <key>AudioComponents</key><array><dict>
        <key>description</key><string>Driftbox Rack</string>
        <key>factoryFunction</key><string>DriftboxRackViewController</string>
        <!-- RackAudioUnit.componentDescription: an instrument, 'drck' by 'Drfb'. -->
        <key>manufacturer</key><string>Drfb</string>
        <key>name</key><string>Driftbox: Rack</string>
        <key>sandboxSafe</key><true/>
        <key>subtype</key><string>drck</string>
        <key>tags</key><array><string>Synthesizer</string></array>
        <key>type</key><string>aumu</string>
        <key>version</key><integer>1</integer>
      </dict></array>
    </dict>
  </dict>
</dict></plist>
PLIST
# Inside out: the extension, sandboxed, then the app around it.
codesign --force --sign - --entitlements scripts/extension.entitlements "$ext"
codesign --force --sign - "$app"

# A bundle sitting in a build directory is not something the system goes looking for, so the type
# it has just declared and the extension inside it are announced by hand. Nothing is installed;
# they are registered where they stand, which is what a local build wants.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$lsregister" ] && "$lsregister" -f "$app"
pluginkit -a "$ext"
echo "built $app"
