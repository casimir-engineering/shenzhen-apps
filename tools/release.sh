#!/usr/bin/env bash
# One command per app, unattended, from build to published release:
#
#   tools/release.sh <pdf|files|3d> <version> [--publish] [--platforms mac|all] [--private-copy]
#
#   pdf, files  <version> is YY.M.D-N (26.10.20-1)
#   3d          <version> is preview-X.Y.Z, vX.Y.Z, or X.Y.Z for a preview
#   --publish   publish the GitHub release; without it the run stops before anything leaves the machine except the
#               notarization upload (a dry run)
#
# Stages: build, sign, package, notarize with the test suites alongside, staple, verify (the updater test), then
# publish and a live updater check. Each finished stage is stamped for this commit and version: running the same
# command again resumes where it stopped and skips what is done. docs/RELEASING.md has the details.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/python3 -I -B -u "$here/release/release.py" "$@"
