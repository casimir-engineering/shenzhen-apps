#!/bin/bash
# ADR 0018 § 2: measures the tree's leaf function, BLAKE3 against BLAKE2b, per core, and a whole file's tree and digest
# on every core, on this Mac or on a phone (the slowest supported one decides BLAKE3 against BLAKE2b; the fast-transfers
# journal records each run). Prints JSON lines.
#
#   tree-hash-bench.sh mac [MiB]                    here, arm64 natively, then x86_64 (Rosetta: indicative only)
#   tree-hash-bench.sh android [serial] [MiB]       an Android device or emulator already listed by `adb devices`
#
# iPhones run no command-line binaries: there, run the example's body from the app's test target. Starts nothing on the
# device but the benchmark, which deletes its scratch file.

set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
toolchain=$(rustup run stable rustc --print sysroot)
export RUSTC="$toolchain/bin/rustc"
cargo="$toolchain/bin/cargo"
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$here/../../build/friends/core-rs/bench-target}
# The release profile at full speed: the phone profile's opt-level only shrinks code a radio never waits on.
build() { # target
    CARGO_PROFILE_RELEASE_OPT_LEVEL=3 "$cargo" build --quiet --release --manifest-path "$here/Cargo.toml" \
        --config "$here/.cargo/config.toml" -p szfriends-core --example tree_hash_bench --target "$1"
    echo "$CARGO_TARGET_DIR/$1/release/examples/tree_hash_bench"
}

case "${1:-mac}" in
mac)
    "$(build aarch64-apple-darwin)" "${2:-1024}"
    arch -x86_64 "$(build x86_64-apple-darwin)" "${2:-1024}"
    ;;
android)
    ndk=${ANDROID_NDK_HOME:-$(ls -d "$HOME"/Library/Android/sdk/ndk/* 2>/dev/null | sort -V | tail -1)}
    linker=$(ls "$ndk"/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android24-clang | head -1)
    export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$linker" CC_aarch64_linux_android="$linker" \
        AR_aarch64_linux_android="$(dirname "$linker")/llvm-ar"
    adb_args=()
    [ -n "${2:-}" ] && adb_args=(-s "$2")
    binary=$(build aarch64-linux-android)
    adb "${adb_args[@]}" push "$binary" /data/local/tmp/szf-tree-hash-bench >/dev/null
    adb "${adb_args[@]}" shell "TMPDIR=/data/local/tmp /data/local/tmp/szf-tree-hash-bench ${3:-256}; \
        rm -f /data/local/tmp/szf-tree-hash-bench"
    ;;
*)
    echo "usage: tree-hash-bench.sh mac [MiB] | android [serial] [MiB]" >&2
    exit 2
    ;;
esac
