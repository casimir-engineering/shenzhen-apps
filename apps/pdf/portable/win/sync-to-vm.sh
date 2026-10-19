#!/usr/bin/env bash
# Mirror the platform-independent parts of the repo into a directory the
# Parallels guest can actually see.
#
# WHY THIS EXISTS: the guest mounts the Mac home directory but only exposes
# Desktop, Documents and Downloads. ~/Projects is NOT shared, so the repo is
# invisible from Windows no matter how the path is spelled. We therefore stage
# a copy under ~/Documents, which the guest reads as
#   \\Mac\Home\Documents\spdf-win
# The mapped drive Z: that Parallels sets up for the interactive user does NOT
# exist in the SYSTEM session `prlctl exec` runs in, so guest-side tooling must
# use the UNC path, never Z:.
#
# Idempotent: rsync --delete makes the staging tree exactly match the repo, so
# a deleted source file disappears on the Windows side too.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE="${SPDF_WIN_STAGE:-$HOME/Documents/spdf-win}"

mkdir -p "$STAGE"

# Only the parts a Windows build can possibly need. portable/mac and
# portable/linux are deliberately absent: syncing them would just make the
# copy-into-guest step slower for files MSVC will never open.
#
# mupdf is here because the Windows target links libmupdf, and it must be the
# SAME tree the macOS build uses -- a different MuPDF would make the
# macOS-vs-Windows pixel comparison (the port's main correctness check)
# meaningless. See portable/win/README.md, "Building MuPDF for ARM64".
SUBTREES=(portable/core portable/win ext mupdf)

RSYNC_ARGS=(
  -a --delete
  # --delete alone PROTECTS excluded files that are already in the destination.
  # Without this, changing an exclude leaves the old tree behind forever -- and
  # in mupdf's case that is 190 MB of generated/ the guest then robocopies on
  # every build for nothing.
  --delete-excluded
  # mupdf/thirdparty/* are SYMLINKS into ext/ (brotli -> ../../ext/brotli, ...).
  # Parallels' shared folder does not present macOS symlinks to Windows in a form
  # robocopy or cl.exe can follow, so dereference the ones that point outside the
  # subtree being copied and stage real files instead. None of the other subtrees
  # contain symlinks, so this is a no-op for them.
  --copy-unsafe-links
  --exclude '.git'
  --exclude '.DS_Store'
  # Build output, ours and the guest's. build/ is where vm-build.sh drops both
  # the macOS reference binary and the fetched guest artifacts.
  --exclude 'build/'
  --exclude '*.o'
  --exclude '*.obj'
  --exclude '*.a'
  --exclude '*.lib'
  --exclude '*.pdb'
  --exclude '*.ilk'
  --exclude '*.exe'
)

# Per-subtree extra excludes. Kept tiny and justified: every megabyte here is
# paid twice, once by rsync and once by the guest's robocopy into C:\spdf.
mupdf_excludes=(
  --exclude '/docs/'      # 2.8 MB of Sphinx sources; nothing compiles from it
  --exclude '/generated/' # 190 MB of fonts hexdumped into C string literals. The
                          # Windows build cannot use them -- MSVC needs multiple
                          # GB of heap per megabyte of literal and dies with
                          # C1060 on the large ones (SourceHanSerif's is 103 MB
                          # of C). It embeds the ORIGINAL binaries under
                          # resources/ with mupdf's own scripts/bin2coff.c
                          # instead, which is what mupdf.sln does on Windows too.
                          # See portable/win/README.md, "The font blob problem".
)

for sub in "${SUBTREES[@]}"; do
  extra=()
  [[ "$sub" == mupdf ]] && extra=("${mupdf_excludes[@]}")
  mkdir -p "$STAGE/$(dirname "$sub")"
  rsync "${RSYNC_ARGS[@]}" "${extra[@]+"${extra[@]}"}" "$REPO_ROOT/$sub/" "$STAGE/$sub/"
done

if [[ "${SPDF_WIN_SYNC_QUIET:-0}" != "1" ]]; then
  printf 'staged %s -> %s (%s files, %s)\n' \
    "$(IFS=' '; echo "${SUBTREES[*]}")" \
    "$STAGE" \
    "$(find "$STAGE" -type f | wc -l | tr -d ' ')" \
    "$(du -sh "$STAGE" | cut -f1)"
  printf 'guest sees this as \\\\Mac\\Home\\Documents\\%s\n' "$(basename "$STAGE")"
fi
