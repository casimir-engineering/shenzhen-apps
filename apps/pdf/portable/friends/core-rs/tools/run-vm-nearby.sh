#!/bin/bash
# Nearby between the Objective-C helper on this Mac and a Rust helper inside a Parallels VM (ADR 0015, wave 4):
# builds szfriends-testnet in the VM from a copy of the workspace, then runs crates/szfriends-interop/tests/
# vm_nearby.rs here, whose bridge starts the guest through `prlctl exec` and keeps every socket on loopback on both
# sides. The copy is removed afterwards, and each guest removes its own home as it exits.
#
#   run-vm-nearby.sh windows-vm [VM name]   default "Windows 11"; as the VM's signed-in user; aarch64 MSVC
#   run-vm-nearby.sh linux-vm [VM name]     default "Ubuntu 24.04 (with Rosetta)"; the toolchain in
#                                           $SZFRIENDS_VM_TOOLCHAIN, as root when SZFRIENDS_VM_AS_ROOT=1, the crates
#                                           from $SZFRIENDS_VM_VENDOR when set (run-vm-tests.sh)
#
# Needs the Objective-C helper built (make friends-helper: build/friends/helper/szfriends-helper, or
# $SZFRIENDS_OBJC_HELPER). Starts and stops no VM: resuming or suspending one is the caller's choice.

set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
friends=$(cd "$here/.." && pwd)
platform=${1:?usage: run-vm-nearby.sh windows-vm [VM] | linux-vm [VM]}
objc=${SZFRIENDS_OBJC_HELPER:-$friends/../build/friends/helper/szfriends-helper}
[ -x "$objc" ] || { echo "no Objective-C helper at $objc (make friends-helper)" >&2; exit 1; }
failed=0
# shellcheck source=run-vm-tests.sh
. "$here/tools/run-vm-tests.sh"

# Each prints the guest's directory after copying the tree into it and building the bridge there.
prepare_windows() { # VM name
    local vm=$1 dir exec=(prlctl exec "$1" --current-user)
    dir=$("${exec[@]}" cmd /c "echo %TEMP%\\szfriends-nearby-%RANDOM%%RANDOM%" </dev/null | tr -d '\r')
    "${exec[@]}" cmd /c "mkdir $dir\\tmp" </dev/null
    vm_payload | fold -w 76 | "${exec[@]}" cmd /c "findstr ^^ > $dir\\tree.b64"
    "${exec[@]}" cmd /c "certutil -decode $dir\\tree.b64 $dir\\tree.tgz >nul && tar -xzf $dir\\tree.tgz -C $dir" \
        </dev/null >/dev/null
    "${exec[@]}" cmd /c "cd /d $dir\\core-rs && set CARGO_TARGET_DIR=$dir\\target&& \
%USERPROFILE%\\.cargo\\bin\\cargo.exe build --locked --release -p szfriends-interop --bin szfriends-testnet 2>&1" \
        </dev/null | tr -d '\r' | tail -3 >&2
    echo "$dir"
}

prepare_linux() { # VM name
    local vm=$1 dir bin=${SZFRIENDS_VM_TOOLCHAIN:-'$HOME/.cargo/bin'} exec=(prlctl exec "$1") vendor offline
    [ "${SZFRIENDS_VM_AS_ROOT:-0}" = 1 ] || exec+=(--current-user)
    vendor=$(vm_vendor) || return 1
    dir=$("${exec[@]}" "mktemp -d /tmp/szfriends-nearby.XXXXXX")
    vm_payload "$vendor" | "${exec[@]}" "base64 -d | tar -xzf - -C $dir && mkdir $dir/tmp"
    offline=$(vm_linux_vendored "$dir" "$vendor" "${exec[@]}")
    "${exec[@]}" "cd $dir/core-rs && PATH=$bin:\$PATH RUSTC=$bin/rustc CARGO_HOME=$dir/cargo-home \
CARGO_TARGET_DIR=$dir/target CARGO_INCREMENTAL=0 $bin/cargo build --locked $offline --release -p szfriends-interop \
--bin szfriends-testnet 2>&1" | tail -3 >&2
    echo "$dir"
}

case "$platform" in
windows-vm) vm=${2:-Windows 11} ;;
linux-vm) vm=${2:-Ubuntu 24.04 (with Rosetta)} ;;
*) echo "unknown platform $platform" >&2; exit 2 ;;
esac
prlctl status "$vm" 2>/dev/null | grep -q " running" || { echo "the VM \"$vm\" is not running" >&2; exit 1; }
if [ "$platform" = windows-vm ]; then
    dir=$(prepare_windows "$vm")
    spec="$vm|1|$dir\\target\\release\\szfriends-testnet.exe|$dir\\tmp"
else
    dir=$(prepare_linux "$vm")
    user=1
    [ "${SZFRIENDS_VM_AS_ROOT:-0}" = 1 ] && user=0
    spec="$vm|$user|$dir/target/release/szfriends-testnet|$dir/tmp"
fi
status=0
binary=${spec#*|*|}
binary=${binary%|*}
if [ "$platform" = windows-vm ]; then
    built=$(prlctl exec "$vm" --current-user cmd /c "if exist $binary echo built" </dev/null | tr -d '\r')
else
    exec=(prlctl exec "$vm")
    [ "${SZFRIENDS_VM_AS_ROOT:-0}" = 1 ] || exec+=(--current-user)
    built=$("${exec[@]}" "test -x $binary && echo built")
fi
[ "$built" = built ] || { echo "$platform: szfriends-testnet did not build in the VM" >&2; status=1; }
[ "$status" = 0 ] && SZFRIENDS_OBJC_HELPER="$objc" SZFRIENDS_VM_GUEST="$spec" \
    cargo test --manifest-path "$here/Cargo.toml" --locked -p szfriends-interop --test vm_nearby \
    -- --test-threads=1 --nocapture || status=$?
if [ "$platform" = windows-vm ]; then
    left=$(prlctl exec "$vm" --current-user cmd /c "dir /b $dir\\tmp 2>nul" </dev/null | tr -d '\r')
    prlctl exec "$vm" --current-user cmd /c "rmdir /s /q $dir" </dev/null
else
    exec=(prlctl exec "$vm")
    [ "${SZFRIENDS_VM_AS_ROOT:-0}" = 1 ] || exec+=(--current-user)
    left=$("${exec[@]}" "ls $dir/tmp")
    "${exec[@]}" "rm -rf $dir"
fi
if [ -n "$left" ]; then
    echo "$platform: guest homes left behind: $left" >&2
    status=1
fi
exit $status
