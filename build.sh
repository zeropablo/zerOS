#!/bin/bash
# Compile zerOS.app dans ./dist (et l'installe dans /Applications avec --install).
# Signature : identité de signature de code nommée par la variable SIGN_IDENTITY si elle est définie
# (ex. SIGN_IDENTITY="Mon certificat" ./build.sh), sinon signature ad hoc (codesign -s -).
set -e
cd "$(dirname "$0")"
APP="dist/zerOS.app"
INSTALL=""
for a in "$@"; do case "$a" in --install) INSTALL=1;; esac; done
swift build -c release
BUILT=.build/release/zerOS
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Version du SDK inscrite dans le binaire : SwiftPM y écrit la version minimale (15.0), et macOS 26+ rend alors les contrôles
# standard comme avant macOS 26 (compatibilité selon le SDK du binaire : boutons, marges). On y inscrit 26.0 : rendu de
# macOS 26+ sur macOS 26+, minimum inchangé (Info.plist).
MINOS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Resources/Info.plist)
vtool -set-build-version macos "$MINOS" 26.0 -replace -output "$APP/Contents/MacOS/zerOS" "$BUILT" 2>/dev/null
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Thème (fonds, icônes de section, icône de barre des menus).
if [ -d Resources/Theme ]; then
  cp -R Resources/Theme "$APP/Contents/Resources/Theme"
  xattr -cr "$APP"
fi

if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --deep --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
  echo "Signé avec « $SIGN_IDENTITY »"
else
  codesign --force --deep --sign - "$APP"
  echo "Signé en ad hoc : l'accès complet au disque sera à redonner après chaque compilation."
fi
echo "OK: $APP"

if [ -n "$INSTALL" ]; then
  osascript -e 'quit app "zerOS"' 2>/dev/null || true
  rm -rf "/Applications/zerOS.app"
  ditto "$APP" "/Applications/zerOS.app"
  echo "Installé dans /Applications"
fi
