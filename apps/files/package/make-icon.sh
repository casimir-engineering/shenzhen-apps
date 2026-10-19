#!/usr/bin/env bash
#
# make-icon.sh — generate package/AppIcon.icns (and package/dmg-logo.png) from
# the Shenzhen Files folder-first mark rendered by make-logo.swift.
#
# The folder remains visually dominant while the 深圳 signature stays legible.
# The source fills the square canvas but has no pre-rounded corners, allowing
# macOS to apply one native enclosure without shrinking it into a nested icon.
#
# Usage:
#   ./make-icon.sh
#
# Re-runnable: regenerates the iconset from scratch on every invocation.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

logo_script="$script_dir/make-logo.swift"
logo_source="$script_dir/AppIcon-source-v7.png"
out_icns="$script_dir/AppIcon.icns"
out_logo="$script_dir/dmg-logo.png"
iconset="$script_dir/build/AppIcon.iconset"

command -v iconutil >/dev/null 2>&1 || { echo "error: iconutil not found" >&2; exit 1; }
command -v swift >/dev/null 2>&1 || { echo "error: swift not found" >&2; exit 1; }
[[ -f "$logo_script" ]] || { echo "error: $logo_script not found" >&2; exit 1; }
[[ -f "$logo_source" ]] || { echo "error: $logo_source not found" >&2; exit 1; }

rm -rf "$iconset"
mkdir -p "$iconset"

# Standard macOS iconset: each point size at 1x and @2x.
declare -a specs=(
  "16  icon_16x16.png"
  "32  icon_16x16@2x.png"
  "32  icon_32x32.png"
  "64  icon_32x32@2x.png"
  "128 icon_128x128.png"
  "256 icon_128x128@2x.png"
  "256 icon_256x256.png"
  "512 icon_256x256@2x.png"
  "512 icon_512x512.png"
  "1024 icon_512x512@2x.png"
)
for spec in "${specs[@]}"; do
  size="${spec%% *}"
  name="${spec##* }"
  swift "$logo_script" "$iconset/$name" "$size"
done

iconutil -c icns "$iconset" -o "$out_icns"
echo "wrote $out_icns"

# The DMG background generator (dmg-background.swift) draws this mark above
# the wordmark; render a comfortable 512-px master.
swift "$logo_script" "$out_logo" 512
echo "wrote $out_logo"
