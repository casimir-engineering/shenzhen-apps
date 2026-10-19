#!/bin/bash
# friends-datachannel-check: proves the vendored online transport stack (friends/deps/datachannel.mk) is fit to
# link into the helper.
#   1. The link test runs: two peer connections in one process exchange a message over 127.0.0.1.
#   2. The linked program depends on /usr/lib/libc++.1.dylib and /usr/lib/libSystem.B.dylib and nothing else, and
#      targets macOS 12 on the build's architecture (MAC_ARCH among the make variables; arm64 by default).
#   3. Linked with -dead_strip and -Wl,-x, nothing of the stack is exported (one documented exception below) and
#      no local symbol names remain.
#   4. Every member of the six archives is an object for that architecture with a macOS 12 floor.
#   5. Reproducibility: every archive is rebuilt from scratch in a second build directory, at a different job
#      count, and must be byte-identical to the first build (libtool -D writes no dates, uids or modes).
#
# usage: check-datachannel.sh <link-test> <deps-build-dir> <make> [make variable assignments ...]
# Runs from portable/ (make's cwd). Bash 3.2 compatible (macOS /bin/bash). Writes only to a temporary directory.

set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "usage: $0 <link-test> <deps-build-dir> <make> [VAR=value ...]" >&2
    exit 2
fi
link_test=$1
deps_build=$2
make_cmd=$3
shift 3
archives="libdatachannel.a libjuice.a libusrsctp.a libmbedtls.a libmbedx509.a libmbedcrypto.a"
# The architecture the build was made for: the MAC_ARCH assignment passed on for the rebuild, or arm64. otool -hv
# names it in capitals (ARM64, X86_64).
arch=arm64
for assignment in "$@"; do
    case "$assignment" in MAC_ARCH=*) arch=${assignment#MAC_ARCH=} ;; esac
done
cputype=$(echo "$arch" | tr 'a-z' 'A-Z')
failed=0
fail() {
    echo "friends-datachannel-check: $*" >&2
    failed=1
}

# 1. Run it.
if ! "$link_test"; then
    fail "the link test failed"
fi

# 2. Dynamic libraries, platform and architecture of the program.
libraries=$(otool -L "$link_test" | sed -n 's/^[[:space:]]*\([^ ]*\) (compatibility.*/\1/p' | LC_ALL=C sort)
expected=$(printf '%s\n' /usr/lib/libSystem.B.dylib /usr/lib/libc++.1.dylib | LC_ALL=C sort)
if [ "$libraries" != "$expected" ]; then
    fail "the link test depends on more than libc++ and libSystem:"
    echo "$libraries" >&2
fi
build=$(vtool -show-build "$link_test")
if ! echo "$build" | grep -q 'platform MACOS' || ! echo "$build" | grep -q 'minos 12\.0$'; then
    fail "the link test does not target macOS 12:"
    echo "$build" >&2
fi
if [ "$(lipo -archs "$link_test")" != "$arch" ]; then
    fail "the link test is not $arch only: $(lipo -archs "$link_test")"
fi

# 3. Exports and local symbols. usrsctp defines its own timingsafe_bcmp on Apple platforms (sctp_userspace.c),
# and macOS's <string.h> declares that name with default visibility, so -fvisibility=hidden cannot hide it. It is
# the only exception of the stack's own; the helper link can drop it with -Wl,-unexported_symbol,_timingsafe_bcmp.
# On x86_64 libc++ also exports the type_info objects and names of its own templates the stack instantiates
# (std::function, std::regex, ...): they are libc++'s, which marks them default visibility, and arm64 keeps them
# hidden only because its typeinfo comparison works without unique symbols. They are allowed on x86_64 alone.
exported=$(nm -gU "$link_test" | awk '{print $NF}' | grep -v -x -e '__mh_execute_header' -e '_main' \
    -e '_timingsafe_bcmp' | { if [ "$arch" = x86_64 ]; then grep -v '^__ZT[IS]NSt3__1'; else cat; fi; } || true)
if [ -n "$exported" ]; then
    fail "the link test exports symbols from the stack:"
    echo "$exported" | awk 'NR <= 20' >&2
fi
# -Wl,-x leaves only external symbols: defined ones (uppercase type) and undefined ones (U). awk keeps reading to
# the end, so pipefail never sees nm killed by a closed pipe.
locals=$(nm "$link_test" | awk 'NF == 3 && $2 ~ /^[a-z]$/ && ++n <= 5')
if [ -n "$locals" ]; then
    fail "local symbol names survived -Wl,-x:"
    echo "$locals" >&2
fi

# 4. Every archive member: a Mach-O object for $arch with LC_BUILD_VERSION minos 12.0.
for name in $archives; do
    archive="$deps_build/$name"
    if [ ! -f "$archive" ]; then
        fail "missing $archive"
        continue
    fi
    members=$(ar -t "$archive" | grep -c -v '^__\.SYMDEF')
    ours=$(otool -hv "$archive" | awk -v cpu="$cputype" '$1 == "MH_MAGIC_64" && $2 == cpu && $5 == "OBJECT"' | wc -l)
    floors=$(otool -l "$archive" | grep -c '^ *minos 12\.0$' || true)
    builds=$(otool -l "$archive" | grep -c 'cmd LC_BUILD_VERSION$' || true)
    if [ "$members" -eq 0 ] || [ "$ours" -ne "$members" ] || [ "$floors" -ne "$members" ] ||
        [ "$builds" -ne "$members" ]; then
        fail "$name: $members members, $ours $arch objects, $builds build versions, $floors with minos 12.0"
    fi
done

# 5. Reproducibility.
scratch=$(mktemp -d "${TMPDIR:-/tmp}/szfriends-datachannel-check.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
if ! "$make_cmd" -s -j3 "BUILD=$scratch/build" "$@" friends-datachannel > "$scratch/rebuild.log" 2>&1; then
    fail "the second build failed:"
    tail -20 "$scratch/rebuild.log" >&2
else
    for name in $archives; do
        if ! cmp -s "$deps_build/$name" "$scratch/build/friends/deps/$name"; then
            fail "$name differs between two builds of the same sources"
        fi
    done
fi

if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "friends-datachannel-check passed: links against libc++ and libSystem only, $arch, macOS 12, reproducible"
