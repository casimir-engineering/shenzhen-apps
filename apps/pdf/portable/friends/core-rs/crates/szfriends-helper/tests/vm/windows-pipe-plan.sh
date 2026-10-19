#!/bin/bash
# ADR 0015 § 8's pipe test plan, the cases that need a second principal, in the running Windows 11 VM:
#
#   1. another account (SYSTEM, through prlctl exec without --current-user) creates the advertised name first: the
#      client refuses it and sends nothing;
#   2. a pipe created by the same user in another process, whose owner was then made another account's: refused
#      for its owner, nothing sent;
#   3. a low-integrity process of the same user squats the advertised name: refused as server, nothing sent;
#   4. a low-integrity process of the same user as a client of a real helper: it never gets in.
#
# The single-principal cases (a forged advertised name, a name left behind and squatted, a second helper without the
# lock, a remote client) are `tests/windows_pipe.rs`, run by `tools/run-device-tests.sh windows-vm`.
#
#   windows-pipe-plan.sh [VM name]          default "Windows 11"
#
# Copies the workspace into a fresh temporary directory in the guest, builds the helper and `examples/pipe-probe`
# (feature `testing`) for $SZFRIENDS_WINDOWS_TARGET (default aarch64-pc-windows-msvc) with the guest user's rustup,
# runs the cases (the user's side is windows-pipe-plan.ps1), and removes the directory. Every process it starts in
# the guest exits by itself within a minute.

set -euo pipefail

vm=${1:-Windows 11}
target=${SZFRIENDS_WINDOWS_TARGET:-aarch64-pc-windows-msvc}
here=$(cd "$(dirname "$0")" && pwd)
friends=$(cd "$here/../../../../.." && pwd)
user=(prlctl exec "$vm" --current-user)
system=(prlctl exec "$vm")
failed=0

run() { "${user[@]}" "$@" | tr -d '\r'; }
as_system() { "${system[@]}" "$@" | tr -d '\r'; }
check() { # description, expected (an extended regular expression), actual
    if printf '%s' "$3" | grep -Eq "^($2)\$"; then
        printf 'ok    %s: %s\n' "$1" "$3"
    else
        printf 'FAIL  %s: expected %s, got %s\n' "$1" "$2" "$3"
        failed=1
    fi
}
field() { printf '%s\n' "$2" | sed -n "s/^$1: //p" | head -1; }

dir=$(run powershell -NoProfile -Command \
    "\$d = Join-Path \$env:TEMP ('szfh-plan-' + [guid]::NewGuid().ToString('N').Substring(0,8));" \
    "New-Item -ItemType Directory \$d | Out-Null; \$d")
case "$dir" in *szfh-plan-*) ;; *) echo "no temporary directory in the guest ($dir)" >&2; exit 1 ;; esac
[ -n "${SZFRIENDS_PLAN_KEEP:-}" ] || trap 'run cmd /c "rmdir /s /q $dir" >/dev/null 2>&1 || true' EXIT

COPYFILE_DISABLE=1 tar --no-xattrs -czf - --exclude 'core-rs/target' --exclude 'core-rs/fuzz/target' \
    --exclude '.DS_Store' -C "$friends" core-rs fixtures service/identity/wordlist | base64 |
    "${user[@]}" powershell -NoProfile -Command \
    "[IO.File]::WriteAllBytes('$dir\\tree.tgz', [Convert]::FromBase64String([Console]::In.ReadToEnd()))"
run cmd /c "mkdir $dir\\src & tar -xzf $dir\\tree.tgz -C $dir\\src" >/dev/null
echo "building the helper and pipe-probe for $target in $dir"
cargo='%USERPROFILE%\.cargo\bin\cargo.exe'
run cmd /c "cd /d $dir\\src\\core-rs && set CARGO_TARGET_DIR=$dir\\target&& $cargo build --locked -p szfriends-helper \
--features testing --example pipe-probe --bins --target $target 2>&1" | tail -1
bin="$dir\\target\\$target\\debug"
probe="$bin\\examples\\pipe-probe.exe"
plan="$dir\\src\\core-rs\\crates\\szfriends-helper\\tests\\vm\\windows-pipe-plan.ps1"
user_case() { run powershell -NoProfile -ExecutionPolicy Bypass -File "$plan" -Case "$1" -Dir "$dir" -Bin "$bin"; }

# 1. Another account creates the name first, with a DACL letting anyone in.
name=$(run "$probe" name "$dir\\state1")
run cmd /c "echo $name> $dir\\name1.txt"
as_system "$probe" squat "$name" "D:(A;;GA;;;WD)" "$dir\\squat1.txt" >/dev/null 2>&1 &
out=$(user_case 1)
wait
check "another account's pipe" "refused (peer_other_user|peer_unknown)" "$(field verdict "$out")"
check "  and it was sent" "0" "$(field sent "$out")"

# 2. The same user's process creates the name; SYSTEM then makes itself the pipe's owner. SYSTEM's side waits in the
# guest from the start: a second exec started while the first runs may only begin once it has finished.
"${system[@]}" powershell -NoProfile -ExecutionPolicy Bypass -File "$plan" -Case 20 -Dir "$dir" -Bin "$bin" \
    >/dev/null 2>&1 &
out=$(user_case 2)
wait
check "  owner changed" "owner set" "$(field owner "$out")"
check "a pipe owned by another account" "refused pipe_other_owner" "$(field verdict "$out")"
check "  and it was sent" "0" "$(field sent "$out")"
[ -n "$(field owner "$out")" ] || printf 'the user side said:\n%s\n' "$out"

# 3. A low-integrity process of the same user squats the name (a sandboxed reader or a browser's renderer).
out=$(user_case 3)
check "a low-integrity squatter" "refused peer_lower_integrity" "$(field verdict "$out")"
check "  and it was sent" "0" "$(field sent "$out")"

# 4. A low-integrity client of a real helper: the pipe's label keeps it out, and the helper would refuse it anyway.
out=$(user_case 4)
check "the helper itself" "connected" "$(field helper "$out")"
check "a low-integrity client" "error .*|refused .*" "$(field 'low client' "$out")"
check "  and the helper left" "True" "$(field 'helper exited' "$out")"

if [ "$failed" = 0 ]; then
    echo "windows pipe plan: every case refused as it should"
else
    echo "windows pipe plan: FAILED"
fi
exit "$failed"
