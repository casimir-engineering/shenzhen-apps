#!/usr/bin/env bash
# GUI capture harness for the GTK4 frontend.
#
#   capture.sh <output-dir> <pdf> [script]
#
# Runs the app under XWayland (GDK_BACKEND=x11) so xdotool synthetic input and
# ImageMagick `import` window capture work on a Wayland session — the same
# approach the June 2026 VM validation used. A capture script is a shell
# fragment sourced with helpers in scope:
#
#   key ctrl+k            # xdotool key to the app window
#   type "power tree"     # xdotool type
#   click 400 300         # click at window-relative coords
#   drag 100 200 300 200  # press-move-release
#   snap 03-zoom.png      # capture the window into <output-dir>
#   settle [ms]           # wait for paint to settle (default 400ms)
#
# Fails loudly: any helper error aborts the run with the app's stderr tail.
set -euo pipefail

OUT=${1:?usage: capture.sh <output-dir> <pdf> [script]}
PDF=${2:?need a pdf}
SCRIPT=${3:-}
BIN=${SPDF_BIN:-portable/build/ShenzhenPDF-gtk4}
mkdir -p "$OUT"

export GDK_BACKEND=x11
export SPDF_LAUNCH_PROFILE=1

applog=$(mktemp)
"$BIN" "$PDF" >"$applog" 2>&1 &
APP_PID=$!
trap 'kill $APP_PID 2>/dev/null || true' EXIT

WIN=""
for _ in $(seq 1 100); do
    WIN=$(xdotool search --pid "$APP_PID" --onlyvisible 2>/dev/null | head -1 || true)
    [ -n "$WIN" ] && break
    kill -0 "$APP_PID" 2>/dev/null || { echo "app died at launch:"; tail -20 "$applog"; exit 1; }
    sleep 0.1
done
[ -n "$WIN" ] && echo "window: $WIN" || { echo "no window after 10s"; tail -20 "$applog"; exit 1; }
xdotool windowactivate --sync "$WIN"

# Input goes through XTEST (no --window): GTK4/GDK ignores XSendEvent-style
# synthetic events, so keys must be injected at the server with the app
# window focused (windowactivate above + before each helper).
settle() { sleep "$(printf '%s' "${1:-400}" | awk '{print $1/1000}')"; }
key()    { xdotool windowactivate --sync "$WIN" key --clearmodifiers "$@"; settle 150; }
type()   { xdotool windowactivate --sync "$WIN" type --delay 30 "$@"; settle 150; }
click()  { local x=$1 y=$2; eval "$(xdotool getwindowgeometry --shell "$WIN")"; xdotool mousemove $((X+x)) $((Y+y)) click 1; settle 150; }
drag()   { eval "$(xdotool getwindowgeometry --shell "$WIN")"; xdotool mousemove $((X+$1)) $((Y+$2)) mousedown 1 mousemove_relative $(($3-$1)) $(($4-$2)) mouseup 1; settle 150; }
snap()   { import -window "$WIN" "$OUT/$1"; echo "snap $1"; }

settle 800
snap 00-launch.png
grep '^SPDF-LAUNCH' "$applog" | tee "$OUT/launch-profile.txt" || true

if [ -n "$SCRIPT" ]; then
    # shellcheck disable=SC1090
    source "$SCRIPT"
fi

kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
trap - EXIT
echo "captures in $OUT"
