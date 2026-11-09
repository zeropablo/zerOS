#!/bin/bash
# Compile l'app (./build.sh) et la met dans une image disque à glisser dans Applications : dist/zerOS-<version>.dmg
set -e
cd "$(dirname "$0")"
./build.sh
APP="dist/zerOS.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
VOL="zerOS"
OUT="dist/zerOS-$VERSION.dmg"
WORK=$(mktemp -d)
# Hauteur de la barre de titre d'une fenêtre du Finder sans barre d'outils (mesurée sur capture, macOS 26/27).
FINDER_TITLE=${FINDER_TITLE:-28}
RW="$WORK/rw.dmg"

# Fond (1x + Retina dans un seul fichier) : `Resources/DMG/background.tiff`, utilisé tel quel (aucun écran nécessaire).
# `./make_dmg.sh --nouveau-fond` le régénère à la main : rendu par l'app elle-même (flèche en verre natif sur le fond
# d'Aujourd'hui, `--render-dmg-background`), capturé en 2x ; il faut alors un écran Retina allumé et déverrouillé, et la
# permission « Enregistrement de l'écran » pour le terminal qui lance ce script.
if [ "$1" = "--nouveau-fond" ]; then
  open -n "$APP" --args --render-dmg-background "$WORK"
  for _ in $(seq 1 40); do [ -s "$WORK/winid" ] && break; sleep 0.5; done
  [ -s "$WORK/winid" ] || { echo "Fond du .dmg : la fenêtre de rendu n'est pas apparue" >&2; exit 1; }
  screencapture -x -o -l"$(cat "$WORK/winid")" "$WORK/bg@2x.png"
  pkill -f "zerOS --render-dmg-background" || true
  W2=$(sips -g pixelWidth "$WORK/bg@2x.png" | awk '/pixelWidth/{print $2}')
  [ "$W2" = "1320" ] || { echo "Fond du .dmg : capture de $W2 px de large au lieu de 1320 (écran non Retina ?)" >&2; exit 1; }
  sips -z 420 660 "$WORK/bg@2x.png" --out "$WORK/bg.png" >/dev/null
  tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/background.tiff" >/dev/null
  cp "$WORK/background.tiff" Resources/DMG/background.tiff
fi
cp Resources/DMG/background.tiff "$WORK/background.tiff"
textutil -convert rtf Resources/PremierLancement.html -output "$WORK/Premier lancement.rtf"

# Détache un volume restant du même nom.
[ -d "/Volumes/$VOL" ] && hdiutil detach "/Volumes/$VOL" -force -quiet || true

hdiutil create -size 120m -fs HFS+ -volname "$VOL" -ov "$RW" -quiet
hdiutil attach "$RW" -noautoopen -quiet
MNT="/Volumes/$VOL"
ditto "$APP" "$MNT/zerOS.app"
ln -s /Applications "$MNT/Applications"
cp "$WORK/Premier lancement.rtf" "$MNT/Premier lancement.rtf"
mkdir "$MNT/.background"
cp "$WORK/background.tiff" "$MNT/.background/background.tiff"

# Disposition de la fenêtre (le Finder l'écrit dans le .DS_Store du volume).
osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    try
      set pathbar visible of container window to false
      set sidebar width of container window to 0
    end try
    -- 660 × 420 de contenu (la barre de titre s'ajoute au-dessus, voir FINDER_TITLE).
    set the bounds of container window to {200, 120, 860, 120 + 420 + $FINDER_TITLE}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    -- Centres des icônes : mêmes valeurs que DmgBackground (UI/DmgBackground.swift).
    set position of item "zerOS.app" of container window to {165, 170}
    set position of item "Applications" of container window to {495, 170}
    set position of item "Premier lancement.rtf" of container window to {330, 300}
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
cp Resources/AppIcon.icns "$MNT/.VolumeIcon.icns"
SetFile -a V "$MNT/.VolumeIcon.icns" 2>/dev/null || true
SetFile -a C "$MNT"
sync
hdiutil detach "$MNT" -quiet
rm -f "$OUT"
hdiutil convert "$RW" -format ULFO -o "$OUT" -quiet
rm -rf "$WORK"
echo "DMG prêt : $OUT"
