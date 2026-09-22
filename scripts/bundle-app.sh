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
# The resource bundle is looked for beside the executable, as Bundle.module expects.
bundle=$(find .build-release -maxdepth 4 -name "DriftboxKit_Driftbox.bundle" | head -1)
cp -R "$bundle" "$app/Contents/MacOS/"
cp -R "$bundle" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Driftbox</string>
  <key>CFBundleIdentifier</key><string>app.driftbox.native</string>
  <key>CFBundleName</key><string>Driftbox</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
echo "built $app"
