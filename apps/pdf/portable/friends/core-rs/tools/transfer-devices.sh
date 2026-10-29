#!/bin/bash
# The transfer bench on real devices (ADR 0018 § Verification): this Mac against another Mac or an Android phone over a
# real route, today's peers on both ends (examples/transfer_devices.rs). Payloads go there and come back, and the
# copies that come back are checked here, so nothing has to be prepared on the device.
#
#   transfer-devices.sh mac <ssh host> [address]           the other Mac runs the helper's Objective-C peer
#                                                           (BENCH_REMOTE_PEER=rust: the Rust core instead); it must be
#                                                           an Apple silicon Mac reachable by ssh with a key
#   transfer-devices.sh android <phone address> [serial]   the phone runs the Rust core, as Shenzhen 3D does; it must
#                                                           be listed by `adb devices`, on the same Wi-Fi as this Mac
#
# <address> is what this Mac dials: the device's Wi-Fi or Ethernet address (default: the ssh host), or its
# fe80::…%awdl0 address for AWDL between Macs (with BENCH_ROUTE_CLASS=p2p_wifi). Also:
#   BENCH_ROUTE_NAME   name for the table: wifi (default), ethernet, awdl
#   BENCH_ROUTE_CLASS  lan (default) or p2p_wifi: the route class this Mac declares (chunk size and window)
#   BENCH_SIZES        1m,100m,2g,small (default 1m,100m,small)
#   BENCH_LOCAL        objc (default) or rust: the peer on this Mac
#   BENCH_LINK_BYTES_PER_SECOND  one TCP connection's rate between the two, for the share of the link: run
#                      `iperf3 -s` there and `iperf3 -c <address>` here, and give bytes per second (Mbit/s × 125,000)
#   BENCH_OUT          results file (default build/friends/core-rs/transfer-devices.jsonl)
#
# Bluetooth is not covered: these peers speak TCP only; Bluetooth between real devices needs the helpers' lanes (WP3,
# WP4). An iPhone cannot run a peer process; Shenzhen 3D's iOS core runs in the simulator only (run-device-tests.sh).
# The remote peer listens on every interface while the run lasts; on a Mac its firewall may ask once to allow it. Its
# state goes to /tmp/szf-bench on the Mac (cleared at restart) or /data/local/tmp/szf/home on the phone, one fresh
# directory per run; nothing is installed, and no app or helper of the owner's is started or stopped.

set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
portable=$(cd "$here/../.." && pwd)
build=$portable/build/friends/core-rs
kind=${1:?usage: transfer-devices.sh mac <ssh host> [address] | android <phone address> [serial]}

make -C "$portable" friends-session-peer friends-transfer-examples >&2
export SZFRIENDS_OBJC_PEER=$build/SZFSessionPeer
export BENCH_OUT=${BENCH_OUT:-$build/transfer-devices.jsonl}

case "$kind" in
mac)
    host=${2:?the other Mac's ssh host}
    export BENCH_REMOTE_HOST=${3:-$host}
    peer=SZFSessionPeer
    [ "${BENCH_REMOTE_PEER:-objc}" = rust ] && peer=session_peer
    ssh "$host" mkdir -p szf-bench /tmp/szf-bench
    scp "$build/SZFSessionPeer" "$build/target/release/examples/session_peer" "$host:szf-bench/"
    export BENCH_REMOTE="ssh -T $host szf-bench/$peer"
    export BENCH_REMOTE_HOME=/tmp/szf-bench
    ;;
android)
    export BENCH_REMOTE_HOST=${2:?the phone's address on this network}
    adb_args=()
    [ -n "${3:-}" ] && adb_args=(-s "$3")
    toolchain=$(rustup run stable rustc --print sysroot)
    ndk=${ANDROID_NDK_HOME:-$(ls -d "$HOME"/Library/Android/sdk/ndk/* 2>/dev/null | sort -V | tail -1)}
    linker=$(ls "$ndk"/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android24-clang | head -1)
    export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$linker" CC_aarch64_linux_android="$linker" \
        CXX_aarch64_linux_android="$linker++" AR_aarch64_linux_android="$(dirname "$linker")/llvm-ar"
    RUSTC="$toolchain/bin/rustc" CARGO_TARGET_DIR="$build/device-target" "$toolchain/bin/cargo" build \
        --manifest-path "$here/Cargo.toml" --config "$here/.cargo/config.toml" --locked --release \
        --target aarch64-linux-android -p szfriends-interop --example session_peer >&2
    adb ${adb_args[@]+"${adb_args[@]}"} shell mkdir -p /data/local/tmp/szf/home
    adb ${adb_args[@]+"${adb_args[@]}"} push "$build/device-target/aarch64-linux-android/release/examples/session_peer" \
        /data/local/tmp/szf/session_peer >&2
    export BENCH_REMOTE="adb ${adb_args[*]+${adb_args[*]}} shell -T /data/local/tmp/szf/session_peer"
    export BENCH_REMOTE_HOME=/data/local/tmp/szf/home
    ;;
*)
    echo "transfer-devices.sh: unknown kind $kind (mac or android)" >&2
    exit 2
    ;;
esac

"$build/target/release/examples/transfer_devices"
