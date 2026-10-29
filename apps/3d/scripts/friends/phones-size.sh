#!/bin/bash
# What Shenzhen Friends adds to the Android app's native library, per ABI, against ADR 0015 § 12's budget of 5 MB:
# libapp_lib.so built in release without Friends and with it as phone builds have it (the `friends-online` feature:
# nearby and online), both stripped, and the difference. Friends' crates are built for size
# (src-tauri/friends/phones-profile.toml) with the core's phone.toml (the bundled SQLite's flags), as Friends phone
# builds are, and from src-tauri/friends/Cargo.lock with --locked, as platform-build.mjs builds them: the library alone
# (crate type cdylib), so that the profile's LTO runs.
#
#   scripts/friends/phones-size.sh [rust targets…]   default: aarch64-linux-android
#
# Needs NDK_HOME (NDK 28+) and the pinned checkout (setup-tauri-friends.mjs --phones). Builds into a temporary
# target directory, removed afterwards; src-tauri/Cargo.lock is put back.

set -euo pipefail

targets=("${@:-aarch64-linux-android}")
here=$(cd "$(dirname "$0")/../.." && pwd)
budget=5000000
: "${NDK_HOME:?NDK_HOME names the Android NDK}"
config=$(cd "$here" && node scripts/friends/setup-tauri-friends.mjs --print-config)
plugin=$(cd "$here" && node scripts/friends/setup-tauri-friends.mjs --print-plugin)
bin=$(ls -d "$NDK_HOME"/toolchains/llvm/prebuilt/*/bin | head -1)
work=$(mktemp -d "${TMPDIR:-/tmp}/szf-phones-size.XXXXXX")
cp "$here/src-tauri/Cargo.lock" "$work/Cargo.lock"
restore() { cp "$work/Cargo.lock" "$here/src-tauri/Cargo.lock"; rm -r "$work"; }
trap restore EXIT
bash "$plugin/tools/host-build.sh" check "$here/src-tauri" "$here/src-tauri/friends/Cargo.lock"
export CARGO_TARGET_DIR=$work/target
failed=0

for target in "${targets[@]}"; do
    case $target in
        aarch64-linux-android) clang=aarch64-linux-android24-clang ;;
        x86_64-linux-android) clang=x86_64-linux-android24-clang ;;
        armv7-linux-androideabi) clang=armv7a-linux-androideabi24-clang ;;
        i686-linux-android) clang=i686-linux-android24-clang ;;
        *) echo "not an Android target: $target" >&2; exit 64 ;;
    esac
    variable=$(echo "$target" | tr 'a-z-' 'A-Z_')
    lower=$(echo "$target" | tr '-' '_')
    export "CARGO_TARGET_${variable}_LINKER=$bin/$clang" "CC_${lower}=$bin/$clang" "CXX_${lower}=$bin/$clang++" \
        "AR_${lower}=$bin/llvm-ar"
    sizes=()
    # Both from the Friends lock: it holds every version the app's own lock does, so the build without Friends is
    # the same.
    cp "$here/src-tauri/friends/Cargo.lock" "$here/src-tauri/Cargo.lock"
    for features in "" "--features friends-online"; do
        # shellcheck disable=SC2086
        cargo rustc --release --locked --lib --crate-type cdylib --quiet --target "$target" $features --config "$config" \
            --config "$here/src-tauri/friends/phones-profile.toml" --config "$plugin/../core-rs/phone.toml" \
            --manifest-path "$here/src-tauri/Cargo.toml"
        "$bin/llvm-strip" -o "$work/stripped.so" "$CARGO_TARGET_DIR/$target/release/libapp_lib.so"
        sizes+=("$(stat -f %z "$work/stripped.so" 2>/dev/null || stat -c %s "$work/stripped.so")")
    done
    added=$((sizes[1] - sizes[0]))
    awk -v t="$target" -v a="${sizes[0]}" -v b="${sizes[1]}" -v d="$added" -v m="$budget" 'BEGIN {
        printf "%-26s without %6.2f MB  with %6.2f MB  Friends adds %5.2f MB (budget %.0f MB)\n",
            t, a / 1e6, b / 1e6, d / 1e6, m / 1e6 }'
    [ "$added" -le "$budget" ] || failed=1
done
exit $failed
