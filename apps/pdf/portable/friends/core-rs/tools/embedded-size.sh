#!/bin/bash
# The Friends service as a phone app embeds it, against ADR 0015 § 12: at most 5 MB per Android ABI and iOS
# architecture, and 3 MB compressed in an APK split.
#
#   embedded-size.sh [aarch64-linux-android] [aarch64-apple-ios]   default: both
#
# Builds tools/embedded-size (the helper's service behind its protocol server, as the Tauri plugin's embedded mode
# runs it) with the workspace's phone profile (opt-level z, fat LTO) and phone.toml (the bundled SQLite's flags),
# twice: with online (the host connection and the data-channel stack) and nearby only. Android: the cdylib an app
# loads, linked by the NDK's API 24 clang (as run-device-tests.sh finds it), already stripped by the profile;
# "deflated" is its size after gzip -9, close to what an APK split's deflate stores. iOS: the staticlib linked into
# tools/embedded-size/stub.c with -dead_strip for iOS 15 against the system SQLite, stripped, minus the same stub
# linked without the core.
# Prints bytes and MB per row. Builds into $CARGO_TARGET_DIR (default build/friends/core-rs/size-target).

set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
friends=$(cd "$here/.." && pwd)
toolchain=$(rustup run stable rustc --print sysroot)
export RUSTC="$toolchain/bin/rustc"
cargo="$toolchain/bin/cargo"
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$friends/../build/friends/core-rs/size-target}
export IPHONEOS_DEPLOYMENT_TARGET=${IPHONEOS_DEPLOYMENT_TARGET:-15.0}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/szfriends-embedded-size.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

row() { # label, bytes, budget MB
    awk -v l="$1" -v b="$2" -v m="$3" 'BEGIN { printf "%-60s %10d  %5.2f MB  (budget %s MB)\n", l, b, b / 1e6, m }'
}

build() { # target, crate type, cargo feature flags...
    local target=$1 kind=$2
    shift 2
    "$cargo" rustc --profile phone --locked -p szfriends-embedded-size --target "$target" --crate-type "$kind" "$@" \
        --manifest-path "$here/Cargo.toml" --config "$here/phone.toml" --quiet
}

android() {
    local target=aarch64-linux-android ndk linker variable so features label
    ndk=${ANDROID_NDK_HOME:-$(ls -d "$HOME"/Library/Android/sdk/ndk/* 2>/dev/null | sort -V | tail -1)}
    linker=$(ls "$ndk"/toolchains/llvm/prebuilt/*/bin/${target}24-clang | head -1)
    variable=$(echo "$target" | tr 'a-z-' 'A-Z_')
    export "CARGO_TARGET_${variable}_LINKER=$linker" "CC_${target//-/_}=$linker" "CXX_${target//-/_}=$linker++" \
        "AR_${target//-/_}=$(dirname "$linker")/llvm-ar"
    so="$CARGO_TARGET_DIR/$target/phone/libszfriends_embedded_size.so"
    for features in "" "--no-default-features"; do
        label="$target, with online"
        [ -z "$features" ] || label="$target, nearby only"
        build "$target" cdylib $features
        row "$label" "$(stat -f %z "$so")" 5
        row "$label, deflated" "$(gzip -9 -c "$so" | wc -c)" 3
    done
}

ios() {
    local target=aarch64-apple-ios sdk features label lib
    sdk=$(xcrun --sdk iphoneos --show-sdk-path)
    local cc=(xcrun --sdk iphoneos clang -arch arm64 "-mios-version-min=$IPHONEOS_DEPLOYMENT_TARGET" -isysroot "$sdk"
        -Os -Wl,-dead_strip)
    "${cc[@]}" -DSZF_BASELINE "$here/tools/embedded-size/stub.c" -o "$scratch/baseline"
    strip "$scratch/baseline"
    lib="$CARGO_TARGET_DIR/$target/phone/libszfriends_embedded_size.a"
    for features in "" "--no-default-features"; do
        label="$target, with online"
        [ -z "$features" ] || label="$target, nearby only"
        build "$target" staticlib $features
        "${cc[@]}" "$here/tools/embedded-size/stub.c" "$lib" -lc++ -lsqlite3 -liconv -framework Security \
            -framework CoreFoundation -framework SystemConfiguration -o "$scratch/core"
        strip "$scratch/core"
        row "$label" $(($(stat -f %z "$scratch/core") - $(stat -f %z "$scratch/baseline"))) 5
    done
}

for target in "${@:-aarch64-linux-android aarch64-apple-ios}"; do
    for one in $target; do
        case "$one" in
        aarch64-linux-android) android ;;
        aarch64-apple-ios) ios ;;
        *) echo "unknown target: $one" >&2; exit 2 ;;
        esac
    done
done
