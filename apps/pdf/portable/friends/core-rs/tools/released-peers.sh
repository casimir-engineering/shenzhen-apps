#!/bin/bash
# Builds the released session peers the interop matrix runs against (examples/transfer_interop.rs), each from its tag
# in a git worktree of its own under <out>, once per commit, and prints the variables that name them:
#   SZFRIENDS_RELEASED_OBJC_PEER  tools/objc-session-peer linked against the Mac helper's code at $SZFRIENDS_MAC_TAG
#                                 (default pdf/26.10.29-1: ShenzhenPDF and Shenzhen Files 26.10.29-1)
#   SZFRIENDS_RELEASED_RUST_PEER  examples/session_peer.rs over the Rust core at $SZFRIENDS_RUST_TAG
#                                 (default 3d/preview-0.2.4: Shenzhen 3D 0.2.4)
# The Rust peer's main is today's examples/session_peer.rs, copied into the tag's worktree when that tag has none: it
# only wraps the tag's own RustPeer, so the session, transfer and store code is the release's.
#
#   eval "$(friends/core-rs/tools/released-peers.sh build/friends/core-rs/released)"
#
# Builds only; runs and installs nothing. Remove a worktree with `git worktree remove <out>/src-<commit>`.

set -euo pipefail

out=${1:?usage: released-peers.sh <output directory>}
mac_tag=${SZFRIENDS_MAC_TAG:-pdf/26.10.29-1}
rust_tag=${SZFRIENDS_RUST_TAG:-3d/preview-0.2.4}
here=$(cd "$(dirname "$0")/.." && pwd)
example=$here/crates/szfriends-interop/examples/session_peer.rs
mkdir -p "$out"
out=$(cd "$out" && pwd)

# The worktree for a tag's commit, made once.
worktree() {
    local commit
    commit=$(git -C "$here" rev-parse "$1^{commit}")
    local tree=$out/src-$commit
    if [ ! -d "$tree/apps/pdf/portable" ]; then
        git -C "$here" worktree add --detach "$tree" "$commit" >&2
    fi
    printf '%s\n' "$tree"
}

label() { printf '%s\n' "${1##*/}" | sed 's/^preview-//'; }

objc_bin=$out/SZFSessionPeer-$(label "$mac_tag")
if [ ! -x "$objc_bin" ]; then
    tree=$(worktree "$mac_tag")
    echo "released-peers: building the Objective-C peer at $mac_tag" >&2
    make -C "$tree/apps/pdf/portable" -j8 friends-session-peer >&2
    cp "$tree/apps/pdf/portable/build/friends/core-rs/SZFSessionPeer" "$objc_bin"
fi

rust_bin=$out/session_peer-$(label "$rust_tag")
if [ ! -x "$rust_bin" ]; then
    tree=$(worktree "$rust_tag")
    crate=$tree/apps/pdf/portable/friends/core-rs
    [ -f "$crate/crates/szfriends-interop/examples/session_peer.rs" ] ||
        cp "$example" "$crate/crates/szfriends-interop/examples/session_peer.rs"
    echo "released-peers: building the Rust peer at $rust_tag" >&2
    CARGO_TARGET_DIR="$tree/apps/pdf/portable/build/friends/core-rs/target" cargo build \
        --manifest-path "$crate/Cargo.toml" --config "$crate/.cargo/config.toml" --locked --release \
        -p szfriends-interop --example session_peer >&2
    cp "$tree/apps/pdf/portable/build/friends/core-rs/target/release/examples/session_peer" "$rust_bin"
fi

printf 'export SZFRIENDS_RELEASED_OBJC_PEER=%q SZFRIENDS_RELEASED_OBJC_LABEL=%q\n' "$objc_bin" "objc-$(label "$mac_tag")"
printf 'export SZFRIENDS_RELEASED_RUST_PEER=%q SZFRIENDS_RELEASED_RUST_LABEL=%q\n' "$rust_bin" "rust-$(label "$rust_tag")"
