#!/bin/sh
# Wraps the release Driftbox executable in a minimal application bundle, so the system treats it
# as an app: a Dock icon, activation, a bundle identifier. No signing; local use only.
set -eu
cd "$(dirname "$0")/.."
swift build -c release --scratch-path .build-release --product Driftbox
app=.build-release/Driftbox.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build-release/release/Driftbox "$app/Contents/MacOS/Driftbox"
# The resource bundle is looked for beside the executable, as Bundle.module expects. It is the
# library's rather than the executable's, because the catalogue is read by the code that moved.
bundle=$(find .build-release -maxdepth 4 -name "DriftboxKit_DriftboxApp.bundle" | head -1)
cp -R "$bundle" "$app/Contents/MacOS/"
cp -R "$bundle" "$app/Contents/Resources/"
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
# An unsigned bundle sitting in a build directory is not something the system goes looking for, so
# the type it has just declared is announced by hand. Nothing is installed; it is registered where
# it stands, which is what a local build wants.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$lsregister" ] && "$lsregister" -f "$app"
echo "built $app"
