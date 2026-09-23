#!/bin/zsh
# Compile Épingle et assemble Epingle.app (sans Xcode, avec les Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Epingle.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

swiftc -O -swift-version 5 -target arm64-apple-macos14 \
  Sources/*.swift -o "$APP/Contents/MacOS/Epingle"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.nadir.epingle</string>
  <key>CFBundleName</key><string>Épingle</string>
  <key>CFBundleDisplayName</key><string>Épingle</string>
  <key>CFBundleExecutable</key><string>Epingle</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSScreenCaptureUsageDescription</key><string>Épingle affiche une copie en direct des fenêtres épinglées.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier com.nadir.epingle "$APP"

# Installation dans /Applications (emplacement stable, requis pour l'ouverture à la connexion).
pkill -x Epingle 2>/dev/null || true
rm -rf /Applications/Epingle.app
cp -R "$APP" /Applications/
echo "OK → /Applications/Epingle.app"
