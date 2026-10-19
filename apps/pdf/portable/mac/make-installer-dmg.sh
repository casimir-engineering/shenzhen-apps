#!/usr/bin/env bash
set -euo pipefail

# Build the Shenzhen PDF installer-style DMG: the app on the left, an
# Applications symlink on the right, and the arrow background from
# dmg-background.swift (600x400 pt window, app icon at (150,200),
# Applications at (450,200), 128 pt icons).
#
# Usage:  make-installer-dmg.sh <ShenzhenPDF.app> <output.dmg> <volume name>
#
# The Finder window layout (.DS_Store) is written by scripting Finder on a
# mounted read-write image, which is then converted to compressed read-only
# UDZO. Requires Automation permission for Finder scripting (one-time prompt).
# Signing is the caller's job (the Makefile's dmg target signs afterwards).
#
# Layout contract with the auto-updater (SPDFUpdater.mm): exactly ONE
# non-symlink *.app at the volume root (the Applications symlink and the
# hidden .background folder are skipped by its discovery glob).

usage() { echo "usage: $0 <app-bundle> <output.dmg> <volume-name>" >&2; exit 2; }

[[ $# -eq 3 ]] || usage
APP="$1"
OUT_DMG="$2"
VOLNAME="$3"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BG_1X="$script_dir/dmg-background.png"
BG_2X="$script_dir/dmg-background@2x.png"

[[ -d "$APP" ]] || { echo "app bundle not found: $APP" >&2; exit 1; }
[[ -f "$BG_1X" && -f "$BG_2X" ]] || { echo "dmg-background PNGs not found next to this script" >&2; exit 1; }

if [[ -d "/Volumes/$VOLNAME" ]]; then
  echo "A volume named '$VOLNAME' is already mounted — detach it first (hdiutil detach '/Volumes/$VOLNAME')." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d /tmp/spdf-dmg-build.XXXXXX)"
STAGING="$WORK_DIR/staging"
RW_DMG="$WORK_DIR/read-write.dmg"
MOUNT_POINT=""
mkdir "$STAGING"

detach_mount() {
  [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]] || return 0
  hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || \
    hdiutil detach -force "$MOUNT_POINT" >/dev/null 2>&1
  MOUNT_POINT=""
}

cleanup() {
  detach_mount || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# --- 1. Stage: app + Applications symlink + hidden background -----------------
echo "==> Staging installer layout"
ditto "$APP" "$STAGING/$(basename "$APP")"
ln -s /Applications "$STAGING/Applications"
mkdir "$STAGING/.background"
# Multi-resolution TIFF so the background renders crisp on retina displays.
tiffutil -cathidpicheck "$BG_1X" "$BG_2X" -out "$STAGING/.background/dmg-background.tiff" >/dev/null

# --- 2. Read-write image, mounted for Finder layout ---------------------------
echo "==> Creating read-write image"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDRW -fs HFS+ "$RW_DMG" >/dev/null

echo "==> Mounting and applying Finder window layout"
attach_plist="$(hdiutil attach -readwrite -noverify -noautoopen -plist "$RW_DMG")"
MOUNT_POINT="$(printf '%s' "$attach_plist" | plutil -extract 'system-entities' json -o - - \
  | /usr/bin/python3 -c 'import json,sys; print(next(e["mount-point"] for e in json.load(sys.stdin) if "mount-point" in e))')"
[[ -d "$MOUNT_POINT" ]] || { echo "failed to determine mount point" >&2; exit 1; }

APP_NAME="$(basename "$APP")"
osascript <<EOF
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {400, 120, 1000, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set background picture of viewOptions to file ".background:dmg-background.tiff"
    set position of item "$APP_NAME" of container window to {150, 200}
    set position of item "Applications" of container window to {450, 200}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

# Wait for Finder to persist the layout to .DS_Store.
for _ in $(seq 1 20); do
  [[ -f "$MOUNT_POINT/.DS_Store" ]] && break
  sleep 0.5
done
[[ -f "$MOUNT_POINT/.DS_Store" ]] || { echo "Finder did not write .DS_Store on the volume" >&2; exit 1; }
sync

echo "==> Detaching and converting to compressed UDZO"
detach_mount
rm -f "$OUT_DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT_DMG" >/dev/null

# --- 3. Verify the final image (read-only mount) ------------------------------
echo "==> Verifying final image layout"
verify_plist="$(hdiutil attach -readonly -nobrowse -noautoopen -plist "$OUT_DMG")"
MOUNT_POINT="$(printf '%s' "$verify_plist" | plutil -extract 'system-entities' json -o - - \
  | /usr/bin/python3 -c 'import json,sys; print(next(e["mount-point"] for e in json.load(sys.stdin) if "mount-point" in e))')"
fail=0
[[ -d "$MOUNT_POINT/$APP_NAME" && ! -L "$MOUNT_POINT/$APP_NAME" ]] || { echo "MISSING: $APP_NAME at volume root" >&2; fail=1; }
[[ -L "$MOUNT_POINT/Applications" ]] || { echo "MISSING: Applications symlink" >&2; fail=1; }
[[ -f "$MOUNT_POINT/.background/dmg-background.tiff" ]] || { echo "MISSING: .background/dmg-background.tiff" >&2; fail=1; }
[[ -f "$MOUNT_POINT/.DS_Store" ]] || { echo "MISSING: .DS_Store" >&2; fail=1; }
app_count="$(find "$MOUNT_POINT" -maxdepth 1 -name '*.app' ! -type l | wc -l | tr -d ' ')"
[[ "$app_count" == "1" ]] || { echo "EXPECTED exactly 1 non-symlink .app at root, found $app_count" >&2; fail=1; }
detach_mount
[[ $fail -eq 0 ]] || exit 1

echo "==> Installer DMG ready: $OUT_DMG"
