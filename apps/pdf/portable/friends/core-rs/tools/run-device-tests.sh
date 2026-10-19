#!/bin/bash
# Runs the core-rs test suites on another platform: inside an iOS simulator, on an Android emulator or device, or in
# the Parallels VMs for Windows and Linux.
#
#   run-device-tests.sh ios-sim <simulator UDID>   the simulator must already be booted (xcrun simctl boot <UDID>)
#   run-device-tests.sh android [adb serial]       an emulator or device already listed by `adb devices`
#   run-device-tests.sh windows-vm [VM name]       default "Windows 11"; runs as the VM's signed-in user
#   run-device-tests.sh linux-vm [VM name]         default "Ubuntu 24.04 (with Rosetta)"
#
# Builds with rustup's stable toolchain (Homebrew's cargo has no mobile standard libraries) into
# $CARGO_TARGET_DIR (default: the scratch-friendly ../../build/friends/core-rs/device-target). The simulator reads
# the tree in place; for Android the binaries and fixtures are pushed to /data/local/tmp/szfriends and SZFRIENDS_DIR
# points there. Starts and stops nothing: booting simulators and emulators, and resuming or suspending VMs, is the
# caller's choice. Android compiles C and C++ and links with the NDK's API 24 clang ($ANDROID_NDK_HOME, or the newest
# NDK under ~/Library/Android/sdk/ndk).
#
# The VMs build and test inside the guest, from a copy of the workspace, the fixtures and the helper files the tests
# read, in a fresh temporary directory that is removed afterwards (prlctl exec; nothing is shared or mounted):
#   windows-vm  cargo test for $SZFRIENDS_WINDOWS_TARGETS (default: aarch64-pc-windows-msvc, the Arm VM's own, and
#               x86_64-pc-windows-msvc, which Windows on Arm runs emulated), with %USERPROFILE%\.cargo\bin\cargo.exe
#               (a user-level rustup) and the MSVC build tools in the guest.
#   linux-vm    cargo test for the guest's own architecture with the toolchain in $SZFRIENDS_VM_TOOLCHAIN (a bin
#               directory holding cargo and rustc; default ~/.cargo/bin), as the guest's current user, or as root when
#               SZFRIENDS_VM_AS_ROOT=1 (for a toolchain only root can read), and the guest's cc and c++; no
#               incremental compilation (CARGO_INCREMENTAL=0). $SZFRIENDS_VM_VENDOR, a `cargo vendor` directory made on
#               the Mac (`cargo vendor --locked <dir>` in core-rs), goes along and the guest builds offline from it.
# Otherwise crates are fetched inside the guest; the tests themselves use no network. Windows runs through cmd.exe.

set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
friends=$(cd "$here/.." && pwd)
platform=${1:?usage: run-device-tests.sh ios-sim <UDID> | android [serial] | windows-vm [VM] | linux-vm [VM]}
toolchain=$(rustup run stable rustc --print sysroot)
export RUSTC="$toolchain/bin/rustc"
cargo="$toolchain/bin/cargo"
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$friends/../build/friends/core-rs/device-target}

# Prints the test executables cargo built for $1, one per line.
build_tests() {
    "$cargo" test --manifest-path "$here/Cargo.toml" --config "$here/.cargo/config.toml" --workspace --target "$1" \
        --no-run --message-format=json \
        2>/dev/null | python3 -c '
import json, sys
for line in sys.stdin:
    message = json.loads(line)
    if message.get("reason") == "compiler-artifact" and message.get("executable") and message["profile"]["test"]:
        print(message["executable"])'
}

failed=0
report() { # name, output
    local result
    result=$(printf '%s\n' "$2" | grep "test result" | tail -1)
    printf '%s: %s\n' "$(basename "$1")" "${result:-no result}"
    case "$result" in *" 0 failed"*) ;; *) failed=1; printf '%s\n' "$2" | tail -20 ;; esac
}

case "$platform" in
ios-sim)
    udid=${2:?the booted simulator UDID}
    export IPHONEOS_DEPLOYMENT_TARGET=${IPHONEOS_DEPLOYMENT_TARGET:-15.0} # the app's floor (ADR 0015)
    for test in $(build_tests aarch64-apple-ios-sim); do
        report "$test" "$(xcrun simctl spawn "$udid" "$test" 2>&1 || true)"
    done
    ;;
android)
    ndk=${ANDROID_NDK_HOME:-$(ls -d "$HOME"/Library/Android/sdk/ndk/* 2>/dev/null | sort -V | tail -1)}
    linker=$(ls "$ndk"/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android24-clang | head -1)
    export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$linker"
    # The same compilers for szfriends-datachannel-sys's C and C++ (cc), so the stack targets API 24 too.
    export CC_aarch64_linux_android="$linker" CXX_aarch64_linux_android="$linker++" \
        AR_aarch64_linux_android="$(dirname "$linker")/llvm-ar"
    adb_args=()
    [ -n "${2:-}" ] && adb_args=(-s "$2")
    device=/data/local/tmp/szfriends
    adb "${adb_args[@]}" shell "rm -rf $device && mkdir -p $device/friends/service/session/tests \
        $device/friends/service/store/tests $device/friends/service/thumbnails/fuzz/corpus \
        $device/friends/server/friends/test/vectors"
    adb "${adb_args[@]}" push "$friends/fixtures" "$device/friends/" >/dev/null
    adb "${adb_args[@]}" push "$friends/service/session/tests/vectors" "$device/friends/service/session/tests/" \
        >/dev/null
    adb "${adb_args[@]}" push "$friends/service/store/tests/fixtures" "$device/friends/service/store/tests/" >/dev/null
    adb "${adb_args[@]}" push "$friends/service/thumbnails/fuzz/corpus/frame" \
        "$device/friends/service/thumbnails/fuzz/corpus/" >/dev/null
    adb "${adb_args[@]}" push "$friends/../server/friends/test/vectors/host-list-v1.json" \
        "$device/friends/server/friends/test/vectors/" >/dev/null
    for test in $(build_tests aarch64-linux-android); do
        adb "${adb_args[@]}" push "$test" "$device/" >/dev/null
        name=$(basename "$test")
        output=$(adb "${adb_args[@]}" shell "cd $device && SZFRIENDS_DIR=$device/friends ./$name" 2>&1 || true)
        report "$test" "$output"
    done
    ;;
windows-vm | linux-vm)
    # shellcheck source=run-vm-tests.sh
    . "$here/tools/run-vm-tests.sh"
    run_vm_tests "$platform" "${2:-}"
    ;;
*)
    echo "unknown platform: $platform" >&2
    exit 2
    ;;
esac

exit "$failed"
