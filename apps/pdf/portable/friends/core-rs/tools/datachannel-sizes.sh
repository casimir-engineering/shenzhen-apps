#!/bin/bash
# What the data-channel stack adds to a release binary, per target (ADR 0015 § 12 budgets: 6 MB for the whole desktop
# helper per architecture, 5 MB for the whole embedded core per Android ABI and iOS architecture).
#
#   datachannel-sizes.sh [target ...]   default: every target this Mac builds, then linux-vm and windows-vm
#
# Builds szfriends-datachannel-sys's two examples with the workspace's release profile (opt-level s, thin LTO, symbols
# stripped): dc_echo, which opens a data channel between two peers over 127.0.0.1, and baseline, the same standard-
# library machinery without the stack. Prints both sizes and their difference, and runs dc_echo where it can (this
# Mac's own architectures, the VMs). Targets:
#   aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim aarch64-linux-android
#       built here; Android with the NDK's API 24 clang (as run-device-tests.sh finds it), iOS for iOS 15.
#   linux-vm      the Ubuntu VM's own architecture, inside the guest ($SZFRIENDS_VM_TOOLCHAIN, SZFRIENDS_VM_AS_ROOT as
#                 in run-device-tests.sh)
#   windows-vm    aarch64-pc-windows-msvc and x86_64-pc-windows-msvc inside the Windows 11 VM (MSVC build tools)
# The VMs must already be running; the copy in the guest is removed afterwards. Starts and stops nothing.

set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
friends=$(cd "$here/.." && pwd)
toolchain=$(rustup run stable rustc --print sysroot)
export RUSTC="$toolchain/bin/rustc"
cargo="$toolchain/bin/cargo"
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$friends/../build/friends/core-rs/size-target}
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-12.0}
export IPHONEOS_DEPLOYMENT_TARGET=${IPHONEOS_DEPLOYMENT_TARGET:-15.0}
build=(build --release --locked -p szfriends-datachannel-sys --examples)

row() { # target, dc_echo bytes, baseline bytes, note
    awk -v t="$1" -v d="$2" -v b="$3" -v n="$4" \
        'BEGIN { printf "%-26s %10d %10d %10d  %.2f MB  %s\n", t, d, b, d - b, (d - b) / 1e6, n }'
}

local_target() {
    local target=$1 out note=""
    case "$target" in
    *-linux-android)
        local ndk linker variable
        ndk=${ANDROID_NDK_HOME:-$(ls -d "$HOME"/Library/Android/sdk/ndk/* 2>/dev/null | sort -V | tail -1)}
        linker=$(ls "$ndk"/toolchains/llvm/prebuilt/*/bin/"${target/armv7/armv7a}"24-clang | head -1)
        variable=$(echo "$target" | tr 'a-z-' 'A-Z_')
        export "CARGO_TARGET_${variable}_LINKER=$linker" "CC_${target//-/_}=$linker" "CXX_${target//-/_}=$linker++" \
            "AR_${target//-/_}=$(dirname "$linker")/llvm-ar"
        ;;
    esac
    "$cargo" "${build[@]}" --target "$target" --manifest-path "$here/Cargo.toml" --quiet
    out="$CARGO_TARGET_DIR/$target/release/examples"
    case "$target" in
    *-apple-darwin) note=$("$out/dc_echo" >/dev/null 2>&1 && echo "dc_echo ran" || echo "dc_echo FAILED") ;;
    esac
    row "$target" "$(stat -f %z "$out/dc_echo")" "$(stat -f %z "$out/baseline")" "$note"
}

# shellcheck source=run-vm-tests.sh
. "$here/tools/run-vm-tests.sh"

linux_vm() {
    local vm=${SZFRIENDS_LINUX_VM:-Ubuntu 24.04 (with Rosetta)} dir output
    local exec=(prlctl exec "$vm")
    [ "${SZFRIENDS_VM_AS_ROOT:-0}" = 1 ] || exec+=(--current-user)
    local bin=${SZFRIENDS_VM_TOOLCHAIN:-'$HOME/.cargo/bin'}
    dir=$("${exec[@]}" "mktemp -d /tmp/szfriends-core-rs.XXXXXX")
    case "$dir" in /tmp/szfriends-core-rs.*) ;; *) echo "linux-vm: no temporary directory ($dir)" >&2; return 1 ;; esac
    vm_payload | "${exec[@]}" "base64 -d | tar -xzf - -C $dir"
    output=$("${exec[@]}" "cd $dir/core-rs && PATH=$bin:\$PATH RUSTC=$bin/rustc CARGO_HOME=$dir/cargo-home \
CARGO_TARGET_DIR=$dir/target $bin/cargo ${build[*]} --quiet 2>&1 && e=$dir/target/release/examples && \
echo \$(stat -c %s \$e/dc_echo) \$(stat -c %s \$e/baseline) && \$e/dc_echo") || true
    "${exec[@]}" "rm -rf $dir"
    set -- $output
    row "linux-vm ($("${exec[@]}" "uname -m"))" "${1:-0}" "${2:-0}" "$(echo "$output" | grep -q '^ok:' && echo \
        "dc_echo ran" || echo "FAILED: $output")"
}

windows_vm() {
    local vm=${SZFRIENDS_WINDOWS_VM:-Windows 11} dir output target
    local exec=(prlctl exec "$vm" --current-user)
    dir=$("${exec[@]}" powershell -NoProfile -Command \
        "\$d = Join-Path \$env:TEMP ('szfriends-core-rs-' + [guid]::NewGuid().ToString('N'));" \
        "New-Item -ItemType Directory \$d | Out-Null; \$d" | tr -d '\r')
    case "$dir" in *szfriends-core-rs-*) ;; *) echo "windows-vm: no temporary directory ($dir)" >&2; return 1 ;; esac
    vm_payload | "${exec[@]}" powershell -NoProfile -Command \
        "[IO.File]::WriteAllBytes('$dir\\tree.tgz', [Convert]::FromBase64String([Console]::In.ReadToEnd()))"
    "${exec[@]}" cmd /c "tar -xzf $dir\\tree.tgz -C $dir"
    for target in ${SZFRIENDS_WINDOWS_TARGETS:-aarch64-pc-windows-msvc x86_64-pc-windows-msvc}; do
        local examples="$dir\\target\\$target\\release\\examples"
        output=$("${exec[@]}" cmd /c "cd /d $dir\\core-rs && set CARGO_TARGET_DIR=$dir\\target&& \
%USERPROFILE%\\.cargo\\bin\\cargo.exe ${build[*]} --quiet --target $target 2>&1 && \
for %f in ($examples\\dc_echo.exe $examples\\baseline.exe) do @echo %~zf" | tr -d '\r') || true
        local sizes ran
        sizes=$(echo "$output" | grep -E '^[0-9]+$' | tr '\n' ' ')
        ran=$("${exec[@]}" cmd /c "$examples\\dc_echo.exe" 2>&1 | tr -d '\r') || true
        set -- $sizes
        row "$target" "${1:-0}" "${2:-0}" "$(echo "$ran" | grep -q '^ok:' && echo "dc_echo ran" || echo \
            "FAILED: $output $ran")"
    done
    "${exec[@]}" cmd /c "rmdir /s /q $dir"
}

targets=("$@")
[ ${#targets[@]} -gt 0 ] || targets=(aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim \
    aarch64-linux-android linux-vm windows-vm)
printf '%-26s %10s %10s %10s  %s\n' target dc_echo baseline added ""
for target in "${targets[@]}"; do
    case "$target" in
    linux-vm) linux_vm ;;
    windows-vm) windows_vm ;;
    *) local_target "$target" ;;
    esac
done
