#!/usr/bin/env bash
# ble-hardware-check.sh — Friends Nearby between a real Android phone running Shenzhen 3D and this Mac's running
# Friends helper, over real radios: Bluetooth always, the network when both are on it. It changes no setting on either
# device and never quits or restarts anything: it launches Shenzhen 3D on the phone (if it is not open), opens its
# Friends panel on Nearby, optionally taps "Make myself visible", watches for a while, and reports.
#
#   scripts/friends/ble-hardware-check.sh [--serial <adb serial>] [--seconds 90] [--phone-visible]
#                                         [--expect-mac-visible] [--out <dir>]
#
# --phone-visible       taps "Make myself visible for 5 minutes" on the phone, then expects the Mac to read the
#                       phone's public entry and open a channel to it (that is how a Mac lists a visible person).
# --expect-mac-visible  the Mac was made visible (Friends ▸ Nearby ▸ Make myself visible) before the run: the phone
#                       must read the Mac's public entry and list someone in Nearby.
#
# What it reads:
#   phone: `adb logcat -s SZFriendsBle` (BleRadio.kt: seen / read / served / accepted / advertising lines), the Nearby
#          screen (uiautomator), whether Bluetooth and Wi-Fi are on.
#   Mac:   the running helper ("Shenzhen Friends"), the app macOS attributes its Bluetooth access to and the answer
#          (tccd), and what the helper advertises (bluetoothd: the Friends service UUID, plus the public UUID while
#          visible). Reading the unified log needs no permission for these processes.
# Exit status: 0 when every expectation held, 1 otherwise, 2 for a setup problem.
set -u

SERIAL=""
SECONDS_TO_WATCH=90
PHONE_VISIBLE=0
MAC_VISIBLE=0
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --serial) SERIAL="$2"; shift 2 ;;
    --seconds) SECONDS_TO_WATCH="$2"; shift 2 ;;
    --phone-visible) PHONE_VISIBLE=1; shift ;;
    --expect-mac-visible) MAC_VISIBLE=1; shift ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

PACKAGE=com.shenzhen3d.viewer
SERVICE_UUID=22FB96F7-C35A-45B5-9673-1CAC64EC8E75
PUBLIC_UUID=C8B26601-A773-4E6D-BC10-BA6F596D92C1
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
[ -x "$ADB" ] || ADB=$(command -v adb) || { echo "no adb" >&2; exit 2; }
if [ -z "$SERIAL" ]; then
  SERIAL=$("$ADB" devices | awk 'NR > 1 && $2 == "device" && $1 !~ /^emulator-/ { print $1; exit }')
fi
[ -n "$SERIAL" ] || { echo "no phone connected over adb" >&2; exit 2; }
[ -n "$OUT" ] || OUT=$(mktemp -d "${TMPDIR:-/tmp}/ble-check.XXXXXX")
mkdir -p "$OUT"
adb() { "$ADB" -s "$SERIAL" "$@"; }
LOG=/usr/bin/log # zsh and some shells have a `log` builtin

FAILED=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=1; }
info() { printf 'info  %s\n' "$*"; }

# --- Phone ----------------------------------------------------------------------------------------------------------
code=$(adb shell dumpsys package "$PACKAGE" | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -1)
[ -n "$code" ] || { echo "$PACKAGE is not installed on $SERIAL" >&2; exit 2; }
info "phone $SERIAL: $(adb shell getprop ro.product.model | tr -d '\r'), Android $(adb shell getprop ro.build.version.release | tr -d '\r'), $PACKAGE versionCode $code"
[ "$(adb shell settings get global bluetooth_on | tr -d '\r')" = 1 ] && pass "phone Bluetooth is on" || fail "phone Bluetooth is off"
for permission in BLUETOOTH_SCAN BLUETOOTH_ADVERTISE BLUETOOTH_CONNECT; do
  adb shell dumpsys package "$PACKAGE" | grep -q "android.permission.$permission: granted=true" ||
    fail "phone: $PACKAGE lacks $permission (Friends ▸ Nearby ▸ Allow)"
done
if adb shell dumpsys wifi | grep -q "^Wi-Fi is enabled"; then
  info "phone Wi-Fi is on ($(adb shell dumpsys wifi | sed -n 's/.*mWifiInfo SSID: \([^,]*\),.*/\1/p' | head -1))"
else
  info "phone Wi-Fi is off: only Bluetooth can find the Mac"
fi

# --- Mac ------------------------------------------------------------------------------------------------------------
helper=$(pgrep -x "Shenzhen Friends" | head -1)
if [ -z "$helper" ]; then
  fail "Mac: no Friends helper is running (open Friends in Shenzhen Files, ShenzhenPDF or Shenzhen 3D)"
else
  info "Mac helper pid $helper: $(ps -o command= -p "$helper")"
  # macOS asks on behalf of the app that started the helper; its answer is what the helper gets.
  tcc=$("$LOG" show --last 7d --style compact --predicate \
    "process == \"tccd\" AND eventMessage CONTAINS \"msgID=$helper.\" AND (eventMessage CONTAINS \"AUTHREQ_RESULT\" OR eventMessage CONTAINS \"AUTHREQ_SUBJECT\" OR eventMessage CONTAINS \"kTCCServiceBluetoothAlways\")" 2>/dev/null)
  subject=$(printf '%s\n' "$tcc" | sed -n 's/.*AUTHREQ_SUBJECT: msgID=[0-9.]*, subject=\([^,]*\),.*/\1/p' | tail -1)
  if printf '%s\n' "$tcc" | grep -q "AUTHREQ_RESULT.*authValue=2"; then
    pass "Mac: Bluetooth allowed for the helper (asked as ${subject:-?})"
  elif printf '%s\n' "$tcc" | grep -q "AUTHREQ_RESULT.*authValue=0"; then
    fail "Mac: Bluetooth denied for ${subject:-the app that started the helper} (System Settings ▸ Privacy & Security ▸ Bluetooth)"
  else
    info "Mac: no Bluetooth answer for the helper in the last 7 days of the log; going by its advertising below"
  fi
  advert=$("$LOG" show --last 20m --style compact --predicate \
    "process == \"bluetoothd\" AND eventMessage CONTAINS \"start advertising' request from session \\\"com.intuition.shenzhenfriends-peripheral-$helper-\"" 2>/dev/null | tail -1)
  if [ -z "$advert" ]; then
    fail "Mac: the helper has not (re)started Bluetooth advertising in the last 20 minutes"
  elif printf '%s' "$advert" | grep -q "$PUBLIC_UUID"; then
    pass "Mac advertises Friends, visible (since ${advert:11:8})"
  else
    pass "Mac advertises Friends, hidden (since ${advert:11:8})"
    [ "$MAC_VISIBLE" = 1 ] && fail "Mac: --expect-mac-visible, but its last advertisement has no public UUID"
  fi
fi

# --- Drive the phone ------------------------------------------------------------------------------------------------
ui() { adb exec-out uiautomator dump /dev/tty 2>/dev/null | grep -o '<node [^>]*>'; }
# Taps the centre of the first node whose text or content-desc is exactly $1.
tap() {
  local bounds
  bounds=$(ui | grep -E "(text|content-desc)=\"$1\"" | head -1 | sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p')
  [ -n "$bounds" ] || return 1
  set -- $bounds
  adb shell input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))
}
started=$(adb shell date '+%m-%d %H:%M:%S.000' | tr -d '\r')
if ! adb shell dumpsys activity activities | grep -q "topResumedActivity=.*$PACKAGE"; then
  adb shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 4
fi
ui | grep -q 'text="Nearby"' || { tap "Friends"; sleep 2; }
tap "Nearby" || fail "phone: no Nearby tab in the Friends panel"
sleep 1
if [ "$PHONE_VISIBLE" = 1 ]; then
  tap "Make myself visible for 5 minutes" && info "phone: made visible for 5 minutes" ||
    info "phone: no 'Make myself visible' button (already visible?)"
fi

info "watching for ${SECONDS_TO_WATCH}s…"
sleep "$SECONDS_TO_WATCH"
adb logcat -d -v time -T "$started" -s SZFriendsBle > "$OUT/phone-ble.log" 2>/dev/null
adb exec-out screencap -p > "$OUT/phone.png"
ui > "$OUT/phone-ui.txt"
[ -n "${helper:-}" ] && "$LOG" show --last "$((SECONDS_TO_WATCH + 30))s" --style compact --predicate \
  "process == \"bluetoothd\" AND eventMessage CONTAINS \"shenzhenfriends\"" > "$OUT/mac-bluetoothd.log" 2>/dev/null

# --- Verdicts -------------------------------------------------------------------------------------------------------
B="$OUT/phone-ble.log"
grep -q "advertising failed" "$B" && fail "phone: advertising failed ($(grep -m1 'advertising failed' "$B" | sed 's/.*: //'))"
seen=$(grep -c " seen " "$B")
reads=$(grep -E " read [0-9A-F:]{17} value=[0-9a-f]{30}" "$B" | awk '{ print $5 }' | sort -u | wc -l | tr -d ' ')
[ "$reads" -gt 0 ] && pass "phone found $reads Friends device(s) over Bluetooth and read their presence" ||
  fail "phone read no Friends device over Bluetooth (sightings: $seen)"
# A public value carries a non-zero public PSM in bytes 12..14 of version 1.
public_reads=$(grep -E " read .* public=01[0-9a-f]{22}" "$B" | grep -v -E "public=01[0-9a-f]{22}0000" | awk '{ print $5 }' | sort -u | wc -l | tr -d ' ')
if [ "$MAC_VISIBLE" = 1 ]; then
  [ "$public_reads" -gt 0 ] && pass "phone read a visible device's public entry" || fail "phone read no public entry"
  grep -q " open .* psm=[0-9]* ok" "$B" && pass "phone opened a channel to a visible device (handshake for its profile)" ||
    fail "phone could not open a channel to the visible device ($(grep -m1 -o 'open .*failed.*' "$B"))"
  if grep -q 'text="Nobody visible nearby"' "$OUT/phone-ui.txt"; then
    fail "phone Nearby still says 'Nobody visible nearby'"
  else
    pass "phone Nearby lists someone ($(grep -o 'text="[^"]*"' "$OUT/phone-ui.txt" | sed -n '/Shenzhen 3D keeps looking/,$p' | head -1))"
  fi
else
  info "phone read $public_reads visible device(s)"
fi
served=$(grep -c " served 9f2bc83c " "$B")
[ "$served" -gt 0 ] && pass "a Mac/phone read this phone's presence $served time(s): it is seen over Bluetooth" ||
  fail "nobody read this phone's presence over Bluetooth"
if [ "$PHONE_VISIBLE" = 1 ]; then
  grep -q " served e66577a2 .*size=1[5-9]" "$B" && pass "the phone's public entry was read" ||
    fail "nobody read the phone's public entry"
  grep -q "accepted channel from .* public=true" "$B" && pass "a device opened the phone's public channel (handshake for its profile)" ||
    fail "nobody opened the phone's public channel"
fi
echo "logs and screenshot: $OUT"
exit "$FAILED"
