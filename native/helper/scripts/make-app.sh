#!/bin/bash
# Wraps the release build into "Murmur.app". Run after:
#   swift build -c release --arch arm64
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$(swift build -c release --arch arm64 --show-bin-path)"
OUT="${1:-build}"
APP="$OUT/Murmur.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/MediaRemoteAdapter"

cp "$BIN/MurmurHelper" "$APP/Contents/MacOS/Murmur"
cp "$BIN/libMediaRemoteAdapter.dylib" "$APP/Contents/Resources/MediaRemoteAdapter/"
cp Resources/run.pl "$APP/Contents/Resources/MediaRemoteAdapter/"
cp Sources/CIMediaRemote/LICENSE-NOTICE.txt "$APP/Contents/Resources/MediaRemoteAdapter/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.thomasgreenleaf.murmur.accessibility-mac-app</string>
    <key>CFBundleName</key><string>Murmur</string>
    <key>CFBundleDisplayName</key><string>Murmur</string>
    <key>CFBundleExecutable</key><string>Murmur</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAudioCaptureUsageDescription</key><string>Murmur records meeting audio from your Mac so it can take notes.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>Murmur reads your calendar to show upcoming meetings and link notes to them.</string>
    <key>NSCalendarsUsageDescription</key><string>Murmur reads your calendar to show upcoming meetings and link notes to them.</string>
</dict>
</plist>
PLIST

echo "built: $APP"
