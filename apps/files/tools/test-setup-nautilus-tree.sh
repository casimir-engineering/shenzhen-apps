#!/usr/bin/env bash
#
# test-setup-nautilus-tree.sh — the configure step of tools/setup-nautilus-tree.sh under macOS's own bash 3.2.
#
# Step 2 compares an existing build/ with the release options, passing friends_root only when the Friends adapter
# patch is applied. Without the patch the list of Friends arguments is empty, and bash 3.2 treats an empty array as
# unset under `set -u`, so "${friends_args[@]}" stopped the script there. This runs the script's own lines for that
# step, from `friends_args=()` to the end of the option check, with /bin/bash against a stand-in build/ in a
# temporary directory: once without the adapter patch (no friends_root), once with it, and once with a build/
# configured for another Friends checkout, which must still be refused. Nothing is built or fetched.
#
# Usage: tools/test-setup-nautilus-tree.sh   (prints "SetupNautilusTreeTests passed" and exits 0)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d -t szf-nautilus-test)"
trap 'rm -rf "$T"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# The configure step's lines, exactly as the script has them, up to the branch that runs meson setup for a new
# build/ (which this test never takes, since its build/ exists), closed with the `fi` that branch ends with.
awk '/^friends_args=\(\)$/ { on = 1 } on && /^else$/ { exit } on { print }' \
  "$script_dir/setup-nautilus-tree.sh" >"$T/step.sh"
echo fi >>"$T/step.sh"
grep -q 'intro-buildoptions.json' "$T/step.sh" || fail "the configure step was not found in setup-nautilus-tree.sh"

mkdir -p "$T/build/meson-info" "$T/friends"
: >"$T/build/build.ninja"
options() { # options <friends_root or empty>
  python3 - "$T/install" "$1" >"$T/build/meson-info/intro-buildoptions.json" <<'PYEOF'
import json, sys
opts = {"prefix": sys.argv[1], "buildtype": "debugoptimized", "macos_port": True, "extensions": False,
        "selinux": "disabled", "cloudproviders": "disabled", "tests": "none", "introspection": False}
if sys.argv[2]:
    opts["friends_root"] = sys.argv[2]
print(json.dumps([{"name": k, "value": v} for k, v in opts.items()]))
PYEOF
}

# run <number of patches>: the step under /bin/bash with set -u, with stand-ins for what it calls before the check.
run() {
  cat >"$T/run.sh" <<EOF
set -euo pipefail
BUILD="$T/build"; PREFIX="$T/install"; script_dir="$T"; repo_root="$T"
MESON_OPTIONS=(--prefix="$T/install")
PATCHES=($(printf 'p%.0s ' $(seq 1 "$1")))
friends_lock_read() { FRIENDS_ROOT="$T/friends"; }
log() { printf '==> %s\n' "\$*"; }
EOF
  cat "$T/step.sh" >>"$T/run.sh"
  printf '\necho configure-check-ok\n' >>"$T/run.sh"
  printf ':\n' >"$T/friends-lock.sh"
  printf '#!/bin/sh\nexit 0\n' >"$T/setup-friends.sh"
  chmod +x "$T/setup-friends.sh"
  /bin/bash "$T/run.sh" >"$T/out" 2>&1
}

[[ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" == 3 ]] || echo "note: /bin/bash is not 3.2 here; the test still runs"

options ""
run 1 || { cat "$T/out" >&2; fail "without the adapter patch the configure step must pass under bash 3.2"; }
grep -q configure-check-ok "$T/out" || { cat "$T/out" >&2; fail "the configure step did not finish"; }

options "$T/friends"
run 2 || { cat "$T/out" >&2; fail "with the adapter patch a build/ configured for this checkout must pass"; }

options "$T/elsewhere"
if run 2; then cat "$T/out" >&2; fail "a build/ configured for another Friends checkout must be refused"; fi
grep -q 'friends_root' "$T/out" || { cat "$T/out" >&2; fail "the refusal must name friends_root"; }

echo "SetupNautilusTreeTests passed"
