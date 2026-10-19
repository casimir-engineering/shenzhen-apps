#!/usr/bin/env bash
#
# make-dmg.sh — build the styled Shenzhen Files installer DMG (PLAN.md §4.5).
#
# Pipeline: staging dir (Nautilus.app + /Applications symlink + hidden
# .background/) → combine 1x/2x art into a Retina-aware multi-representation
# TIFF → hdiutil UDRW image → mount → Finder view options via osascript (icon
# size 128, background picture, icon positions 150/450) → detach → hdiutil
# convert to compressed UDZO.
#
# Usage:
#   ./make-dmg.sh [--check] [path/to/app] [out.dmg]
#
#   --check   dry-run: validate tool + asset availability, then exit.
#
# Defaults: app = <repo>/dist/Shenzhen Files.app,
#           out = <repo>/dist/ShenzhenFiles-mac-<arch>.dmg
#           (asset name matches shenzhen-pdf's ShenzhenPDF-mac-arm64.dmg
#           convention; the self-updater looks for exactly this name).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

vol_name="Shenzhen Files"
bg_png="$script_dir/dmg-background.png"
bg_png_2x="$script_dir/dmg-background@2x.png"

check_only=0
if [[ "${1:-}" == "--check" ]]; then
  check_only=1
  shift
fi

app_path="${1:-$repo_root/dist/Shenzhen Files.app}"
out_dmg="${2:-$repo_root/dist/ShenzhenFiles-mac-$(uname -m).dmg}"

# --- validation (both modes) -------------------------------------------------
fail=0
for tool in hdiutil osascript sips tiffutil; do
  if command -v "$tool" >/dev/null 2>&1; then
    [[ $check_only -eq 1 ]] && echo "ok: $tool ($(command -v "$tool"))"
  else
    echo "error: required tool not found: $tool" >&2
    fail=1
  fi
done
for asset in "$bg_png" "$bg_png_2x"; do
  if [[ -f "$asset" ]]; then
    [[ $check_only -eq 1 ]] && echo "ok: $(basename "$asset")"
  else
    echo "error: missing background art: $asset" >&2
    echo "       generate it with: swift $script_dir/dmg-background.swift '$bg_png' '$bg_png_2x'" >&2
    fail=1
  fi
done
if [[ -f "$bg_png" && -f "$bg_png_2x" ]]; then
  background_1x_size="$(sips -g pixelWidth -g pixelHeight "$bg_png" 2>/dev/null |
                        awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w "x" h}')"
  background_2x_size="$(sips -g pixelWidth -g pixelHeight "$bg_png_2x" 2>/dev/null |
                        awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w "x" h}')"
  if [[ "$background_1x_size" != "600x400" || "$background_2x_size" != "1200x800" ]]; then
    echo "error: DMG backgrounds must be 600x400 (1x) and 1200x800 (2x); got $background_1x_size and $background_2x_size" >&2
    fail=1
  elif [[ $check_only -eq 1 ]]; then
    echo "ok: DMG backgrounds are exact 1x/2x dimensions"
  fi
fi

if [[ $check_only -eq 1 ]]; then
  if [[ -d "$app_path" ]]; then
    echo "ok: app bundle present: $app_path"
  else
    echo "note: app bundle not built yet: $app_path (fine for --check)"
  fi
  [[ $fail -eq 0 ]] && echo "check passed"
  exit "$fail"
fi

[[ $fail -eq 0 ]] || exit 1
if [[ ! -d "$app_path" ]]; then
  echo "error: app bundle not found: $app_path" >&2
  exit 1
fi

app_name="$(basename "$app_path")"

# --- staging -----------------------------------------------------------------
staging="$(mktemp -d /tmp/nautilus-dmg-staging.XXXXXX)"
rw_dmg="$(mktemp -u /tmp/nautilus-dmg-rw.XXXXXX).dmg"
device=""

cleanup() {
  if [[ -n "$device" ]]; then
    hdiutil detach "$device" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$staging" "$rw_dmg"
}
trap cleanup EXIT

cp -R "$app_path" "$staging/$app_name"
ln -s /Applications "$staging/Applications"
mkdir "$staging/.background"
tiffutil -cathidpicheck "$bg_png" "$bg_png_2x" \
  -out "$staging/.background/dmg-background.tiff" >/dev/null
tiff_rep_count="$(tiffutil -info "$staging/.background/dmg-background.tiff" |
                   grep -c '^Directory at ')"
[[ "$tiff_rep_count" == "2" ]] || {
  echo "error: Retina DMG background does not contain both 1x and 2x representations" >&2
  exit 1
}

# --- read-write image, Finder layout ----------------------------------------
# Size the image with headroom for the Finder metadata (.DS_Store).
hdiutil create -volname "$vol_name" -srcfolder "$staging" -ov \
  -format UDRW -fs HFS+ "$rw_dmg" >/dev/null

attach_out="$(hdiutil attach "$rw_dmg" -readwrite -noverify -noautoopen)"
device="$(echo "$attach_out" | awk '/^\/dev\// { print $1; exit }')"
mount_point="$(echo "$attach_out" | grep -o '/Volumes/.*$' | head -1)"
if [[ -z "$device" || -z "$mount_point" ]]; then
  echo "error: failed to attach $rw_dmg" >&2
  exit 1
fi
echo "mounted $device at $mount_point"

# Finder registers new volumes asynchronously; scripting it before the disk
# appears fails with -1728 ("Can't get disk"). Poll until Finder sees it.
for _ in $(seq 1 20); do
  if osascript -e "tell application \"Finder\" to get disk \"$vol_name\"" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
osascript -e "tell application \"Finder\" to get disk \"$vol_name\"" >/dev/null 2>&1 \
  || { echo "error: Finder never registered volume '$vol_name'" >&2; exit 1; }

osascript <<EOF
tell application "Finder"
    tell disk "$vol_name"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 700, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to file ".background:dmg-background.tiff"
        set position of item "$app_name" of container window to {150, 200}
        set position of item "Applications" of container window to {450, 200}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

sync
hdiutil detach "$device" >/dev/null
device=""

# --- compress to final UDZO --------------------------------------------------
mkdir -p "$(dirname "$out_dmg")"
rm -f "$out_dmg"
hdiutil convert "$rw_dmg" -format UDZO -imagekey zlib-level=9 -o "$out_dmg" >/dev/null

echo "wrote $out_dmg"
