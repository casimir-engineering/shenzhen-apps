#!/usr/bin/env bash
#
# test-macos-volumes.sh — build and run the mounted-volume tests, no display.
#
# nautilus/test/displayless/test-macos-volumes attaches, renames and ejects
# real throwaway disk images, and mounts throwaway WebDAV shares the way
# Finder mounts network volumes, one of them named with precomposed (NFC)
# accented and Hangul characters. It checks that the shared volume monitor the
# sidebars listen to reports every change once, on the main thread, within a
# second of the command returning, and that the sidebar's merged list follows.
# It opens no windows; Finder may show the test volumes on the desktop while
# they are mounted.
#
#   1. configure  $BUILD_TESTS (default <repo>/build-tests, gitignored) from
#                 nautilus/ with the release options plus -Dtests=headless
#   2. build      only the test executable: upstream's other tests need
#                 Linux-only dependencies (glycin) and do not build here
#   3. serve      two WebDAV shares on 127.0.0.1 with the system Apache
#                 (/usr/sbin/httpd, mod_dav), unless --no-network
#   4. run        meson test test-macos-volumes; the script exits with its
#                 status
#   5. clean up   unmount the shares and detach any disk image the test left
#                 behind (an aborted test cannot clean up itself), stop
#                 Apache, remove the scratch directory
#
# Run tools/setup-nautilus-tree.sh first; this script never changes nautilus/.
#
# Usage: tools/test-macos-volumes.sh [--no-network]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
BREW="${HOMEBREW_PREFIX:-/opt/homebrew}"
BUILD="${BUILD_TESTS:-$repo_root/build-tests}"
TREE="$repo_root/nautilus"

network=1
for arg in "$@"; do
  case "$arg" in
    --no-network) network=0 ;;
    -h|--help) sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$TREE" ]]; then
  echo "error: nautilus/ is missing; run tools/setup-nautilus-tree.sh first" >&2
  exit 1
fi

export PKG_CONFIG_PATH="$BREW/opt/icu4c@78/lib/pkgconfig:$BREW/opt/libarchive/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

log() { printf '==> %s\n' "$*"; }

scratch="$(mktemp -d -t szf-volumes-test)"
httpd_conf=""
server_url=""

cleanup() {
  local status=$?
  set +e
  # A WebDAV mount whose server is gone hangs, so unmount before stopping it.
  if [[ -n "$server_url" ]]; then
    mount | awk -v url="$server_url" 'index($0, url) == 1 { sub(/^.* on /, ""); sub(/ \(webdav.*$/, ""); print }' |
      while IFS= read -r point; do
        log "unmounting leftover share at $point"
        diskutil unmount force "$point" >/dev/null 2>&1 || true
      done
  fi
  # Detach every disk image attached from the scratch directory.
  hdiutil info -plist 2>/dev/null | python3 -c '
import plistlib, sys
scratch = tuple(p.rstrip("/") + "/" for p in sys.argv[1:])
for image in plistlib.loads(sys.stdin.buffer.read()).get("images", []):
    if image.get("image-path", "").startswith(scratch):
        for entity in image.get("system-entities", []):
            dev = entity.get("dev-entry", "")
            if dev.rstrip("0123456789").endswith("disk"):
                print(dev)
' "$scratch" "$(cd "$scratch" && pwd -P)" | while IFS= read -r dev; do
    log "detaching leftover test image $dev"
    hdiutil detach -force "$dev" >/dev/null 2>&1 || true
  done
  if [[ -n "$httpd_conf" ]]; then
    /usr/sbin/httpd -f "$httpd_conf" -k stop >/dev/null 2>&1
    # -k stop only signals; wait for the server to go before removing its
    # pid file and logs.
    for _ in $(seq 50); do
      [[ -e "$scratch/dav/httpd.pid" ]] || break
      sleep 0.1
    done
  fi
  rm -rf "$scratch"
  exit "$status"
}
trap cleanup EXIT

# --- 1. configure --------------------------------------------------------------
if [[ ! -f "$BUILD/build.ninja" ]]; then
  log "meson setup $BUILD (release options, -Dtests=headless)"
  meson setup "$BUILD" "$TREE" \
    --prefix="$BUILD/prefix" \
    --buildtype=debugoptimized \
    -Dmacos_port=true \
    -Dextensions=false \
    -Dselinux=disabled \
    -Dcloudproviders=disabled \
    -Dtests=headless \
    -Dintrospection=false >/dev/null
fi

# --- 2. build ------------------------------------------------------------------
log "ninja -C $BUILD test/displayless/test-macos-volumes"
ninja -C "$BUILD" test/displayless/test-macos-volumes

# --- 3. serve ------------------------------------------------------------------
if [[ "$network" == 1 ]]; then
  if [[ -x /usr/sbin/httpd && -f /usr/libexec/apache2/mod_dav_fs.so ]]; then
    port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
    share="szf-share-$RANDOM"
    # "SZF Partagé 공유 <n>", written precomposed (NFC): é as U+00E9, 공 and
    # 유 as single Hangul syllables. NetFS mounts it at a mount point the
    # kernel keeps precomposed.
    nfc_share="$(printf 'SZF Partag\xc3\xa9 \xea\xb3\xb5\xec\x9c\xa0 %d' "$RANDOM")"
    dav="$scratch/dav"
    mkdir -p "$dav/root/$share" "$dav/root/$nfc_share" "$dav/lock"
    echo "Shenzhen Files volume test" > "$dav/root/$share/readme.txt"
    echo "Shenzhen Files volume test" > "$dav/root/$nfc_share/readme.txt"
    httpd_conf="$dav/httpd.conf"
    cat > "$httpd_conf" <<EOF
ServerRoot "/usr"
Listen 127.0.0.1:$port
ServerName 127.0.0.1
PidFile "$dav/httpd.pid"
ErrorLog "$dav/error.log"
LoadModule mpm_prefork_module libexec/apache2/mod_mpm_prefork.so
LoadModule unixd_module libexec/apache2/mod_unixd.so
LoadModule authz_core_module libexec/apache2/mod_authz_core.so
LoadModule dav_module libexec/apache2/mod_dav.so
LoadModule dav_fs_module libexec/apache2/mod_dav_fs.so
LoadModule dir_module libexec/apache2/mod_dir.so
LoadModule mime_module libexec/apache2/mod_mime.so
TypesConfig /private/etc/apache2/mime.types
DavLockDB "$dav/lock/DavLock"
DocumentRoot "$dav/root"
<Directory "$dav/root">
  Dav On
  Require all granted
</Directory>
EOF
    /usr/sbin/httpd -f "$httpd_conf" -k start
    server_url="http://127.0.0.1:$port/"
    share_url="$server_url$share"
    nfc_share_url="$server_url$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1].encode()))' "$nfc_share")"
    for _ in $(seq 50); do
      if curl -s -o /dev/null -X PROPFIND -H 'Depth: 0' "$share_url/"; then
        break
      fi
      sleep 0.1
    done
    log "serving WebDAV shares at $share_url and $nfc_share_url"
    export NAUTILUS_TEST_WEBDAV_URL="$share_url"
    export NAUTILUS_TEST_WEBDAV_NFC_URL="$nfc_share_url"
  else
    log "no /usr/sbin/httpd with mod_dav: the network-volume cases will be skipped"
  fi
fi

# --- 4. run --------------------------------------------------------------------
export NAUTILUS_TEST_SCRATCH="$scratch"
log "meson test test-macos-volumes"
meson test -C "$BUILD" --no-rebuild --verbose --print-errorlogs test-macos-volumes
