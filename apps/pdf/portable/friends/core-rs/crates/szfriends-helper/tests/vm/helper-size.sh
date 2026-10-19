#!/bin/bash
# The desktop helper against ADR 0015 § 12's budget: at most 6 MB (6,000,000 bytes) stripped per architecture.
#
#   helper-size.sh windows-vm [VM]     release builds for $SZFRIENDS_WINDOWS_TARGETS (default: aarch64 and x86_64 MSVC)
#   helper-size.sh linux-vm [VM]       a release build for the guest's own architecture
#
# Builds in the running VM from the same copy run-device-tests.sh makes (the workspace, the fixtures and ext/'s
# data-channel sources), with the workspace's release profile (symbols stripped), prints each binary's size and fails
# when one is over budget. Linux takes the toolchain and the vendored crates as run-device-tests.sh does
# ($SZFRIENDS_VM_TOOLCHAIN, $SZFRIENDS_VM_AS_ROOT, $SZFRIENDS_VM_VENDOR); Windows runs through cmd.exe only. The copy
# is removed afterwards. $SZFRIENDS_HELPER_PROFILE (default release) and $SZFRIENDS_HELPER_FEATURES (cargo's feature
# flags, default the helper's own) measure other builds, such as `phone` or `--no-default-features --features online`.

set -euo pipefail

budget=6000000
platform=${1:?usage: helper-size.sh windows-vm | linux-vm [VM name]}
here=$(cd "$(dirname "$0")" && pwd)
friends=$(cd "$here/../../../../.." && pwd)
failed=0
profile=${SZFRIENDS_HELPER_PROFILE:-release}
features=${SZFRIENDS_HELPER_FEATURES:-}
# shellcheck source=../../../../tools/run-vm-tests.sh
. "$friends/core-rs/tools/run-vm-tests.sh"

row() { # label, bytes
    local verdict=ok
    [ "$2" -le "$budget" ] || { verdict="OVER BUDGET"; failed=1; }
    awk -v l="$1" -v b="$2" -v v="$verdict" \
        'BEGIN { printf "%-40s %10d  %5.2f MB  (budget 6 MB) %s\n", l, b, b / 1e6, v }'
}

case "$platform" in
windows-vm)
    vm=${2:-Windows 11}
    user=(prlctl exec "$vm" --current-user)
    dir=$("${user[@]}" cmd /c "echo %TEMP%\\szfh-size-%RANDOM%%RANDOM%" </dev/null | tr -d '\r')
    case "$dir" in *szfh-size-*) ;; *) echo "no temporary directory in the guest" >&2; exit 1 ;; esac
    trap '"${user[@]}" cmd /c "rmdir /s /q $dir" </dev/null >/dev/null 2>&1 || true' EXIT
    "${user[@]}" cmd /c "mkdir $dir" </dev/null
    vm_payload | fold -w 76 | "${user[@]}" cmd /c "findstr ^^ > $dir\\tree.b64"
    "${user[@]}" cmd /c "certutil -decode $dir\\tree.b64 $dir\\tree.tgz >nul && tar -xzf $dir\\tree.tgz -C $dir" \
        </dev/null >/dev/null
    for target in ${SZFRIENDS_WINDOWS_TARGETS:-aarch64-pc-windows-msvc x86_64-pc-windows-msvc}; do
        "${user[@]}" cmd /c "cd /d $dir\\core-rs && set CARGO_TARGET_DIR=$dir\\target&& \
%USERPROFILE%\\.cargo\\bin\\cargo.exe build --profile $profile $features --locked -p szfriends-helper --bins \
--target $target 2>&1" \
            </dev/null | tr -d '\r' | tail -1
        bytes=$("${user[@]}" cmd /c "for %I in ($dir\\target\\$target\\$profile\\szfriends-helper.exe) do @echo %~zI" \
            </dev/null | tr -d '\r')
        row "szfriends-helper.exe ($target, $profile${features:+ $features})" "$bytes"
    done
    ;;
linux-vm)
    vm=${2:-Ubuntu 24.04 (with Rosetta)}
    exec=(prlctl exec "$vm")
    [ "${SZFRIENDS_VM_AS_ROOT:-0}" = 1 ] || exec+=(--current-user)
    bin=${SZFRIENDS_VM_TOOLCHAIN:-'$HOME/.cargo/bin'}
    vendor=$(vm_vendor)
    dir=$("${exec[@]}" "mktemp -d /tmp/szfh-size.XXXXXX")
    case "$dir" in /tmp/szfh-size.*) ;; *) echo "no temporary directory in the guest" >&2; exit 1 ;; esac
    trap '"${exec[@]}" "rm -rf $dir" >/dev/null 2>&1 || true' EXIT
    vm_payload "$vendor" | "${exec[@]}" "base64 -d | tar -xzf - -C $dir"
    offline=$(vm_linux_vendored "$dir" "$vendor" "${exec[@]}")
    "${exec[@]}" "cd $dir/core-rs && PATH=$bin:\$PATH RUSTC=$bin/rustc CARGO_HOME=$dir/cargo-home \
CARGO_TARGET_DIR=$dir/target CARGO_INCREMENTAL=0 $bin/cargo build --profile $profile $features --locked $offline \
-p szfriends-helper --bins 2>&1 | tail -1"
    bytes=$("${exec[@]}" "stat -c %s $dir/target/$profile/szfriends-helper")
    row "szfriends-helper ($("${exec[@]}" "uname -m"), $profile${features:+ $features})" "$bytes"
    ;;
*)
    echo "unknown platform: $platform" >&2
    exit 2
    ;;
esac
exit "$failed"
