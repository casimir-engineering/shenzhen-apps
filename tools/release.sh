#!/usr/bin/env bash
# One command per app, unattended, from build to published release:
#
#   tools/release.sh <pdf|files|3d> <version> [--publish] [--platforms mac|all]
#
#   pdf, files  <version> is YY.M.D-N (26.10.20-1)
#   3d          <version> is preview-X.Y.Z, vX.Y.Z, or X.Y.Z for a preview
#   --publish   publish the GitHub release; without it the run stops before anything leaves the machine except the
#               notarization upload (a dry run)
#   3d with SHENZHEN_3D_MIRROR_OWNER set: also the hand-over release on that owner's shenzhen-3D (docs/RELEASING.md)
#
# Stages: build, sign, package, notarize with the test suites alongside, staple, verify (the updater test), then
# publish and a live updater check. Each finished stage is stamped for this commit and version: running the same
# command again resumes where it stopped and skips what is done. docs/RELEASING.md has the details.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Friends' test-only build switches never go into a release (release/release.py, friends_test_switches_set, says why
# and checks MAKEFLAGS too): refused here as well, before anything runs.
switches=$(compgen -e | grep -E '^(SZFRIENDS_TEST_[A-Za-z0-9_]*|FRIENDS_TEST_BUILD_FLAGS|SHENZHEN_FAST_TEST_BUILD)$' | tr '\n' ' ' || true)
if [ -n "$switches" ]; then
    echo "FAILED: ${switches% } set: Friends' test-only switches never go into a release; unset them first" >&2
    exit 2
fi
exec /usr/bin/python3 -I -B -u "$here/release/release.py" "$@"
