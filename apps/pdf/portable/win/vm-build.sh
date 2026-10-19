#!/usr/bin/env bash
# Build (and optionally run) repo C/C++ sources inside the Parallels Windows VM,
# driven entirely from the macOS command line.
#
#   portable/win/vm-build.sh [--run] <target-name> <source>... [-- <arg>...]
#
# Sources are paths relative to the repo root, e.g. portable/core/spdf_recolor.c.
# Anything after a lone `--` is passed to the program under --run, as GUEST
# arguments: a path there must be a Windows path the guest can see, e.g.
#   C:\spdf\portable\win\smoke\fixture.pdf                    (the mirrored repo)
#   \\Mac\Home\Documents\spdf-win\out\page.rgba               (writes back to the Mac)
#
# THE ONE INVARIANT: this script exits with the guest's real exit code.
# A compile error in the VM must make this script exit non-zero on the Mac,
# because that is the only signal anything else has that a Windows build is
# broken. `prlctl exec` propagates the guest's exit code faithfully (verified:
# `exit /b 7` in the guest gives $? == 7 on the Mac), so the job here is simply
# not to lose it -- hence no `set -e`, no pipes around the prlctl call, and no
# trailing command that would overwrite $?.
set -uo pipefail

VM_NAME="${SPDF_VM_NAME:-Windows 11}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE="${SPDF_WIN_STAGE:-$HOME/Documents/spdf-win}"
# How the guest addresses the staging directory. The mapped drive Z: is NOT
# visible in the SYSTEM session prlctl uses, so this must stay a UNC path.
GUEST_SHARE="\\\\Mac\\Home\\Documents\\$(basename "$STAGE")"
GUEST_OUT='C:\spdf-build'

RUN=0
if [[ "${1:-}" == "--run" ]]; then
  RUN=1
  shift
fi

if [[ $# -lt 2 ]]; then
  echo "usage: $(basename "$0") [--run] <target-name> <source>... [-- <arg>...]" >&2
  exit 64
fi

TARGET="$1"
shift

# Split the tail into sources and program arguments at a lone `--`.
RUN_ARGS=()
SOURCES=()
seen_sep=0
for arg in "$@"; do
  if [[ $seen_sep -eq 0 && "$arg" == "--" ]]; then
    seen_sep=1
    continue
  fi
  if [[ $seen_sep -eq 1 ]]; then
    RUN_ARGS+=("$arg")
  else
    SOURCES+=("$arg")
  fi
done
if [[ ${#SOURCES[@]} -eq 0 ]]; then
  echo "vm-build: no sources given" >&2
  exit 64
fi
set -- "${SOURCES[@]}"

# Sources are named relative to the repo root but must resolve inside the staged
# subtrees (portable/core, portable/win, ext). Catch a typo here rather than
# letting it surface as a confusing cl.exe error 40 minutes into a build.
for src in "$@"; do
  if [[ ! -f "$REPO_ROOT/$src" ]]; then
    echo "vm-build: no such source: $src" >&2
    exit 66
  fi
done

if ! "$REPO_ROOT/portable/win/sync-to-vm.sh"; then
  echo "vm-build: sync to $STAGE failed" >&2
  exit 65
fi

for src in "$@"; do
  if [[ ! -f "$STAGE/$src" ]]; then
    echo "vm-build: $src is not inside a staged subtree (portable/core, portable/win, ext)" >&2
    exit 66
  fi
done

# Windows-ify the source paths for the guest script.
guest_sources=()
for src in "$@"; do
  guest_sources+=("${src//\//\\}")
done

echo "vm-build: compiling $TARGET in '$VM_NAME' ..."
prlctl exec "$VM_NAME" cmd.exe /c \
  "$GUEST_SHARE\\portable\\win\\guest-build.cmd $TARGET ${guest_sources[*]}"
rc=$?

if [[ $rc -ne 0 ]]; then
  echo "vm-build: guest build FAILED (exit $rc)" >&2
  exit $rc
fi
echo "vm-build: built $GUEST_OUT\\$TARGET.exe"

if [[ $RUN -eq 1 ]]; then
  echo "vm-build: running $TARGET.exe ${RUN_ARGS[*]-}"
  prlctl exec "$VM_NAME" cmd.exe /c "$GUEST_OUT\\$TARGET.exe ${RUN_ARGS[*]-}"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "vm-build: guest program exited $rc" >&2
  fi
fi

exit $rc
