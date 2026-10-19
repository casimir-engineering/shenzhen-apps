#!/usr/bin/env bash
# Build libmupdf for Windows ARM64 inside the Parallels VM, from macOS.
#
#   portable/win/mupdf-build.sh [ninja args...]
#
#   portable/win/mupdf-build.sh                       # everything
#   portable/win/mupdf-build.sh obj/source/fitz/draw-device.obj   # one file
#   portable/win/mupdf-build.sh -j4 -v                # slower, verbose
#   portable/win/mupdf-build.sh -t clean              # wipe the object tree
#
# Steps: stage the repo (sync-to-vm.sh), regenerate the MSVC build description
# from mupdf/Makefile's own macOS recipe (mupdf-gen-ninja.sh), then run ninja in
# the guest (mupdf-build.cmd).
#
# Artifacts land in the guest at
#   C:\spdf-build\mupdf\libmupdf.lib
#   C:\spdf-build\mupdf\libmupdf-third.lib
# and stay there between runs; nothing copies them back to the Mac, because
# nothing on the Mac can link them.
#
# Exits with the guest's real exit code. Same reasoning as vm-build.sh: no
# `set -e`, no pipe around the prlctl call, nothing after it that clobbers $?.
set -uo pipefail

VM_NAME="${SPDF_VM_NAME:-Windows 11}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE="${SPDF_WIN_STAGE:-$HOME/Documents/spdf-win}"
GUEST_SHARE="\\\\Mac\\Home\\Documents\\$(basename "$STAGE")"

if ! "$REPO_ROOT/portable/win/sync-to-vm.sh"; then
  echo "mupdf-build: sync to $STAGE failed" >&2
  exit 65
fi

# The build description goes straight into the staging directory rather than the
# repo: it is generated output, and $STAGE/mupdf-win sits outside every subtree
# sync-to-vm.sh mirrors with --delete, so it survives the next sync.
if ! "$REPO_ROOT/portable/win/mupdf-gen-ninja.sh" "$STAGE/mupdf-win"; then
  echo "mupdf-build: could not generate the MSVC build description" >&2
  exit 67
fi

start=$SECONDS
echo "mupdf-build: building libmupdf (ARM64) in '$VM_NAME' ..."
prlctl exec "$VM_NAME" cmd.exe /c \
  "$GUEST_SHARE\\portable\\win\\mupdf-build.cmd $*"
rc=$?
elapsed=$((SECONDS - start))

if [[ $rc -ne 0 ]]; then
  echo "mupdf-build: FAILED after ${elapsed}s (exit $rc)" >&2
  exit $rc
fi
echo "mupdf-build: OK in ${elapsed}s -> C:\\spdf-build\\mupdf\\libmupdf.lib"
exit 0
