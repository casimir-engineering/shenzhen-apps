#!/bin/bash
# Locked Friends builds of a Tauri app that depends on this plugin through a registry of its own
# (`registry = "szfriends-pinned"`, answered by a placeholder unless a Friends build patches it to this checkout), as
# Shenzhen 3D does (docs/FRIENDS.md § Tauri there). A Friends build resolves more crates than the app's committed
# Cargo.lock holds, so the app keeps a second lock file for Friends builds, made from this pin, and builds with it and
# --locked. Every command works on a copy of the app's package in a temporary directory, with the patch in the copy's
# own manifest: neither the app's lock nor this checkout's lock files change, and the patch never reaches the core's
# or the plugin's workspace, so no lock file gains a [[patch.unused]] entry.
#
#   host-build.sh lock   <app package dir> <out>          the Friends-build lock file: the app's Cargo.lock with this
#                                                         pin's plugin and core added (no other version moves)
#   host-build.sh check  <app package dir> <friends lock>  fails when that lock no longer fits the app or this pin
#   host-build.sh vendor <app package dir> <friends lock> <out dir>
#                                                         one `cargo vendor --locked` pass: the app's Friends build,
#                                                         the core's workspace (the helper) and the plugin's own
#   host-build.sh config                                   the --config a Friends build passes to cargo
#
# The app package dir holds the app's Cargo.toml (src-tauri in Shenzhen 3D). Set CARGO_NET_OFFLINE=true to resolve
# and vendor from the crates already downloaded. Usage in a release build:
#
#   cp <friends lock> src-tauri/Cargo.lock && cargo build --locked --config "$(host-build.sh config)" …
#   (then the app's own Cargo.lock goes back)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
core=$(cd "$plugin/../core-rs" && pwd)
# Never fetched: a patch always answers it. On loopback, so a missing patch fails instead of reaching a registry.
registry='registries.szfriends-pinned.index="sparse+https://127.0.0.1:9/szfriends-pinned/"'

die() { echo "host-build.sh: $*" >&2; exit 1; }

# A copy of the app's package (manifest, lock, build script, sources) with the patch to this checkout's plugin in its
# own manifest, in $stage. $1: the app package dir; $2: the lock file to start from.
stage_app() {
    local app=$1 lock=$2
    [ -f "$app/Cargo.toml" ] || die "$app has no Cargo.toml"
    [ -f "$lock" ] || die "no lock file at $lock"
    grep -q 'registry *= *"szfriends-pinned"' "$app/Cargo.toml" ||
        die "$app/Cargo.toml names no dependency from szfriends-pinned"
    stage=$(mktemp -d "${TMPDIR:-/tmp}/szf-host-build.XXXXXX")
    mkdir "$stage/app"
    cp "$app/Cargo.toml" "$stage/app/Cargo.toml"
    cp "$lock" "$stage/app/Cargo.lock"
    [ -f "$app/build.rs" ] && cp "$app/build.rs" "$stage/app/"
    [ -d "$app/src" ] && cp -R "$app/src" "$stage/app/src"
    printf '\n[patch.szfriends-pinned]\ntauri-plugin-szfriends = { path = "%s" }\n' "$plugin" >>"$stage/app/Cargo.toml"
}

# cargo from the temporary directory, so no .cargo/config.toml of the app's repository or of this one applies.
cargo_in_stage() {
    (cd "$stage" && cargo "$@" --config "$registry")
}

cleanup() { [ -n "${stage:-}" ] && [ -d "$stage" ] && rm -r "$stage"; return 0; }
trap cleanup EXIT

case "${1:-}" in
lock)
    [ $# -eq 3 ] || die "usage: host-build.sh lock <app package dir> <out>"
    stage_app "$2" "$2/Cargo.lock"
    # Resolving keeps every version the app's lock already holds and adds what the plugin and the core bring.
    cargo_in_stage metadata --format-version 1 --manifest-path "$stage/app/Cargo.toml" >/dev/null
    grep -q '^name = "szfriends-helper"$' "$stage/app/Cargo.lock" || die "the lock does not name the core"
    if grep -q '^\[\[patch.unused\]\]' "$stage/app/Cargo.lock"; then die "the patch was not used"; fi
    cp "$stage/app/Cargo.lock" "$3"
    echo "host-build.sh: wrote $3"
    ;;
check)
    [ $# -eq 3 ] || die "usage: host-build.sh check <app package dir> <friends lock>"
    stage_app "$2" "$3"
    cargo_in_stage metadata --locked --format-version 1 --manifest-path "$stage/app/Cargo.toml" >/dev/null ||
        die "$3 does not fit this pin: make it again with host-build.sh lock"
    cmp -s "$3" "$stage/app/Cargo.lock" || die "$3 changed when resolved"
    echo "host-build.sh: $3 fits this pin"
    ;;
vendor)
    [ $# -eq 4 ] || die "usage: host-build.sh vendor <app package dir> <friends lock> <out dir>"
    stage_app "$2" "$3"
    mkdir -p "$4"
    out=$(cd "$4" && pwd)
    cargo_in_stage vendor --locked --manifest-path "$stage/app/Cargo.toml" --sync "$core/Cargo.toml" \
        --sync "$plugin/Cargo.toml" "$out" >/dev/null
    echo "host-build.sh: vendored into $out"
    ;;
config)
    printf 'patch.szfriends-pinned.tauri-plugin-szfriends.path="%s"\n' "$plugin"
    ;;
*)
    die "usage: host-build.sh lock|check|vendor|config …"
    ;;
esac
