#!/usr/bin/env bash
#
# Builds the styled, drag-to-install disk image.
#
#   scripts/make-dmg.sh <path/to/Seal.app> <out.dmg> [background.tiff]
#
# Split out of release.sh so the window styling can be built and looked at
# without a 10-minute archive + notarization round trip in front of it.
#
# The layout constants below and the canvas in Brand/gen-dmg-background.swift
# are one design in two files: the background is a picture, so Finder will
# happily park an icon somewhere the art does not expect. Change one, change
# the other, then run this script and actually look at the window.

set -euo pipefail

APP_SRC="${1:?usage: make-dmg.sh <App.app> <out.dmg> [background.tiff]}"
DMG_OUT="${2:?usage: make-dmg.sh <App.app> <out.dmg> [background.tiff]}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKGROUND="${3:-$ROOT/Brand/out/dmg/background.tiff}"

APP_NAME="$(basename "$APP_SRC" .app)"
# The volume name is the window title. Carrying the version there tells people
# which build they are installing, and keeps two mounted releases from
# colliding on /Volumes — a collision this script has to refuse outright.
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP_SRC/Contents/Info.plist" 2>/dev/null || true)"
VOL_NAME="$APP_NAME${SHORT_VERSION:+ $SHORT_VERSION}"

# ---------------- Layout (must match gen-dmg-background.swift) -------------
BG_W=640           # background canvas, 1x points
BG_H=400
TITLE_BAR=32       # Finder's `bounds` is the whole frame, title bar included,
                   # so the window has to be this much taller than the picture
                   # or the last 32pt of art never shows. Measured, not guessed.
ICON_SIZE=128
ICON_ROW_Y=214     # centre line of both icons
APP_X=168          # centre of the app icon
APPS_X=472         # centre of the /Applications drop target
# ---------------------------------------------------------------------------

[ -d "$APP_SRC" ] || { echo "✗ No app at $APP_SRC"; exit 1; }
[ -f "$BACKGROUND" ] || { echo "✗ No background at $BACKGROUND — run: swift Brand/gen-dmg-background.swift"; exit 1; }

# A volume of the same name already mounted is the one failure that looks like
# success: the image mounts as "Seal 1.0 1", every Finder command below lands
# on the *other* disk, and the DMG ships with a default window.
if [ -e "/Volumes/$VOL_NAME" ]; then
  echo "✗ /Volumes/$VOL_NAME is already mounted (probably this same release)."
  echo "  Eject it first, or this build styles the wrong disk:"
  echo "      hdiutil detach \"/Volumes/$VOL_NAME\""
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"

echo "  · staging"
# Stage the app next to an /Applications symlink so the mounted disk image is
# the drag-and-drop install everyone already knows. Handing someone a window
# containing only an app leaves them to guess, and the ones who guess wrong run
# Seal from the disk image forever — where it cannot update itself.
cp -R "$APP_SRC" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
cp "$BACKGROUND" "$STAGE/.background/background.tiff"

ICNS="$(find "$APP_SRC/Contents/Resources" -maxdepth 1 -name '*.icns' -print -quit 2>/dev/null || true)"
[ -n "$ICNS" ] || echo "  ⚠️  no .icns in the app bundle — the volume keeps the generic disk icon"

# Size the read-write image with room to spare: hdiutil sizes -srcfolder images
# to a snug fit, and a full volume cannot take the .DS_Store that carries every
# window setting below. The styling then vanishes with no error anywhere.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 64 ))
RW="$WORK/rw.dmg"
echo "  · creating a ${SIZE_MB}MB read-write image"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov \
  -fs HFS+ -format UDRW -size "${SIZE_MB}m" "$RW" >/dev/null

echo "  · mounting"
ATTACH="$(hdiutil attach "$RW" -readwrite -noverify -noautoopen)"
DEV="$(echo "$ATTACH" | grep '^/dev/' | sed 1q | awk '{print $1}')"
detach() {
  # Finder is still holding the volume the instant after it writes .DS_Store,
  # so the first detach loses a race often enough to matter.
  for _ in 1 2 3 4 5; do
    hdiutil detach "$DEV" >/dev/null 2>&1 && return 0
    sleep 1
  done
  hdiutil detach "$DEV" -force >/dev/null 2>&1 || true
}
trap 'detach; rm -rf "$WORK"' EXIT

MOUNT="$(echo "$ATTACH" | grep -o '/Volumes/.*$' | sed 1q)"
[ -n "$MOUNT" ] || { echo "✗ could not find the mount point"; exit 1; }
[ "$MOUNT" = "/Volumes/$VOL_NAME" ] || { echo "✗ mounted at $MOUNT, not /Volumes/$VOL_NAME"; exit 1; }

echo "  · setting the window up in Finder"
if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set sidebar width of container window to 0
    set the bounds of container window to {200, 140, $((200 + BG_W)), $((140 + BG_H + TITLE_BAR))}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to $ICON_SIZE
    set text size of opts to 13
    set label position of opts to bottom
    set shows item info of opts to false
    set shows icon preview of opts to false
    set background picture of opts to file ".background:background.tiff"
    set position of item "$APP_NAME.app" of container window to {$APP_X, $ICON_ROW_Y}
    set position of item "Applications" of container window to {$APPS_X, $ICON_ROW_Y}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
then
  echo "✗ Finder would not style the window."
  echo "  \"Not authorized to send Apple events\" means this terminal needs Finder"
  echo "  in System Settings → Privacy & Security → Automation."
  exit 1
fi

# Finder writes .DS_Store lazily. Without this the file is often still in a
# buffer when the volume is torn down, and the image ships unstyled.
sync
sleep 2
[ -f "$MOUNT/.DS_Store" ] || echo "  ⚠️  no .DS_Store was written — the window settings did not stick"

# The mounted volume gets the app's own icon instead of a generic white drive,
# in the sidebar and on the desktop. This happens only now, after Finder has
# been told to go away, because `update without registering applications`
# deletes .VolumeIcon.icns outright — silently, whether or not the file carries
# the icnC creator code and whether or not the volume flag is already set.
# Installing the icon first and styling the window second loses the icon every
# time, with nothing in any log to say so.
if [ -n "$ICNS" ] && command -v SetFile >/dev/null; then
  cp "$ICNS" "$MOUNT/.VolumeIcon.icns"
  SetFile -c icnC "$MOUNT/.VolumeIcon.icns"
  SetFile -a C "$MOUNT"
  sync
elif [ -n "$ICNS" ]; then
  echo "  ⚠️  SetFile is missing (Xcode command line tools) — generic volume icon"
fi

echo "  · compressing"
detach
trap 'rm -rf "$WORK"' EXIT
rm -f "$DMG_OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUT" >/dev/null

echo "  ✓ $DMG_OUT"
