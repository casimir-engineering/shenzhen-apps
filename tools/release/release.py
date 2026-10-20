#!/usr/bin/env python3
"""tools/release.sh <pdf|files|3d> <version> [--publish] [--platforms mac|all] [--private-copy]

One command per app, from build to published release, unattended. docs/RELEASING.md § One command per app says what
each stage does, how a rerun resumes, which caches it keeps and where its output goes.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import Failure, say  # noqa: E402


def main(argv):
    parser = argparse.ArgumentParser(prog="tools/release.sh", description=__doc__.split("\n\n")[1].strip())
    parser.add_argument("app", choices=("pdf", "files", "3d"))
    parser.add_argument("version", help="pdf, files: YY.M.D-N; 3d: preview-X.Y.Z, vX.Y.Z or X.Y.Z (a preview)")
    parser.add_argument("--publish", action="store_true", help="publish the GitHub release (default: dry run)")
    parser.add_argument("--platforms", choices=("mac", "all"), default="mac",
                        help="3d: also build Windows, Linux, Android, iOS and the web (default: mac)")
    parser.add_argument("--private-copy", action="store_true",
                        help="3d: also build and publish the copy for SHENZHEN_3D_MIRROR_OWNER")
    opts = parser.parse_args(argv)
    if opts.app != "3d" and (opts.platforms != "mac" or opts.private_copy):
        parser.error("--platforms and --private-copy are for 3d")
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    if opts.app == "pdf":
        from app_pdf import PdfRelease as cls
    elif opts.app == "files":
        from app_files import FilesRelease as cls
    else:
        from app_3d import ThreeDRelease as cls
    try:
        release = cls(repo, opts.version, opts)
    except Failure as error:
        say(f"FAILED: {error}")
        return 2
    return release.main()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
