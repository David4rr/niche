#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

out=build
app="$out/Niche.app"
rm -rf "$out"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp vendor/mediaremote-adapter/mediaremote-adapter.pl "$app/Contents/Resources/"
framework="$app/Contents/Resources/MediaRemoteAdapter.framework"
cp -R vendor/mediaremote-adapter/MediaRemoteAdapter.framework "$app/Contents/Resources/"
lipo -thin arm64e -output "$framework/Versions/A/MediaRemoteAdapter" vendor/mediaremote-adapter/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter
strip -x "$framework/Versions/A/MediaRemoteAdapter" 2>/dev/null
codesign --force --sign "Apple Development" "$framework"

xcrun swiftc -Osize -wmo -parse-as-library -target arm64-apple-macos15.0 -Xlinker -dead_strip \
    -o "$app/Contents/MacOS/Niche" NotchAnimation.swift AudioSpectrum.swift MusicLab.swift AgentSessions.swift LiveActivities.swift Updater.swift SettingsView.swift NicheApp.swift
strip -x "$app/Contents/MacOS/Niche"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.niche</string>
    <key>CFBundleName</key><string>Niche</string>
    <key>CFBundleExecutable</key><string>Niche</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.0</string>
    <key>CFBundleVersion</key><string>6</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAudioCaptureUsageDescription</key><string>Niche listens to the playing app's audio to drive the visualizer bars.</string>
</dict>
</plist>
PLIST

codesign --force --sign "Apple Development" "$app"

staging="$out/dmg"
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname Niche -srcfolder "$staging" -ov -format ULMO "$out/Niche.dmg" >/dev/null
rm -rf "$staging"
echo "$out/Niche.dmg"
