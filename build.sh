#!/bin/zsh
# Compile Épingle et assemble Epingle.app (sans Xcode, avec les Command Line Tools).
#
#   ./build.sh                    compile pour ce Mac et installe dans /Applications
#   UNIVERSAL=1 ./build.sh        binaire universel (Apple Silicon + Intel)
#   NO_INSTALL=1 ./build.sh       ne pas installer dans /Applications
#   VERSION=2.1 ./build.sh        numéro de version de l'app
#   SIGN_IDENTITY="Developer ID Application: Nom (TEAMID)" ./build.sh
#                                 signature Developer ID (sinon signature locale « ad hoc »)
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${VERSION:-2.0.2}
APP=build/Epingle.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

compile() {
  swiftc -O -swift-version 5 -target "$1-apple-macos14" Sources/*.swift -o "$2"
}

if [[ -n "${UNIVERSAL:-}" ]]; then
  compile arm64 build/Epingle-arm64
  compile x86_64 build/Epingle-x86_64
  lipo -create build/Epingle-arm64 build/Epingle-x86_64 -output "$APP/Contents/MacOS/Epingle"
  rm build/Epingle-arm64 build/Epingle-x86_64
else
  compile "$(uname -m)" "$APP/Contents/MacOS/Epingle"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.nadir.epingle</string>
  <key>CFBundleName</key><string>Épingle</string>
  <key>CFBundleDisplayName</key><string>Épingle</string>
  <key>CFBundleExecutable</key><string>Epingle</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSScreenCaptureUsageDescription</key><string>Épingle affiche une copie en direct des fenêtres épinglées.</string>
</dict>
</plist>
PLIST

IDENTITY=${SIGN_IDENTITY:--}
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - --identifier com.nadir.epingle "$APP"
else
  # Runtime renforcé + horodatage : requis pour la notarisation Apple.
  codesign --force --options runtime --timestamp --sign "$IDENTITY" --identifier com.nadir.epingle "$APP"
fi

if [[ -z "${NO_INSTALL:-}" ]]; then
  # Emplacement stable, requis pour l'ouverture à la connexion.
  pkill -x Epingle 2>/dev/null || true
  rm -rf /Applications/Epingle.app
  cp -R "$APP" /Applications/
  echo "OK → /Applications/Epingle.app"
else
  echo "OK → $PWD/$APP"
fi
