#!/bin/zsh
# Crée build/Epingle-<version>.dmg (binaire universel) : glisser Épingle dans Applications.
#
#   ./make-dmg.sh                 version par défaut de build.sh
#   VERSION=2.1 ./make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

# SKIP_BUILD=1 : réutiliser build/Epingle.app (par ex. déjà signée et notarisée).
if [[ -z "${SKIP_BUILD:-}" ]]; then UNIVERSAL=1 NO_INSTALL=1 ./build.sh; fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Epingle.app/Contents/Info.plist)

STAGING=build/dmg
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R build/Epingle.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/Lisez-moi.txt" <<'TXT'
Installation d'Épingle
======================

1. Glissez Épingle dans le dossier Applications.

2. Premier lancement : l'app n'est pas signée par Apple, macOS la bloque.
   Ouvrez-la une fois (double-clic), puis allez dans
   Réglages Système → Confidentialité et sécurité, et cliquez sur « Ouvrir quand même ».

3. Autorisez Épingle dans Réglages Système → Confidentialité et sécurité :
   - Accessibilité
   - Enregistrement de l'écran
   puis relancez l'app.

Utilisation : icône 📌 dans la barre de menus.
  ⌃⌥P       épingler / désépingler la fenêtre active
  ⌃⌥Espace  rechercher une fenêtre
TXT

DMG="build/Epingle-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Épingle" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" > /dev/null
rm -rf "$STAGING"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
echo "OK → $PWD/$DMG"
