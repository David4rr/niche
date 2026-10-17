#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

out=build
app="$out/Niche.app"
rm -rf "$out"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp vendor/mediaremote-adapter/mediaremote-adapter.pl "$app/Contents/Resources/"
cp -R vendor/mediaremote-adapter/MediaRemoteAdapter.framework "$app/Contents/Resources/"

xcrun swiftc -O -parse-as-library -target arm64-apple-macos15.0 \
    -o "$app/Contents/MacOS/Niche" NotchAnimation.swift AudioSpectrum.swift MusicLab.swift AgentSessions.swift SettingsView.swift NicheApp.swift

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.niche</string>
    <key>CFBundleName</key><string>Niche</string>
    <key>CFBundleExecutable</key><string>Niche</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAudioCaptureUsageDescription</key><string>Niche listens to the playing app's audio to drive the visualizer bars.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"

staging="$out/dmg"
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname Niche -srcfolder "$staging" -ov -format UDZO "$out/Niche.dmg" >/dev/null
rm -rf "$staging"
echo "$out/Niche.dmg"
