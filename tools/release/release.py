#!/usr/bin/env python3
"""tools/release.sh <pdf|files|3d> <version> [--publish] [--platforms mac|all] [--private-copy]
   tools/release.sh all [--pdf VERSION] [--files VERSION] [--3d VERSION] [--publish] [--platforms mac|all]

One command per app, from build to published release, unattended; `all` runs the three apps' releases at once, in one
process that shares the machine's cores and memory between them (jobs.py), each app with the version its commit sets
unless named. docs/RELEASING.md § One command per app says what each stage does, how a rerun resumes, which caches it
keeps and where its output goes.
"""
import argparse
import copy
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import Failure, git, label, say  # noqa: E402

APPS = ("pdf", "files", "3d")


def release_class(app):
    if app == "pdf":
        from app_pdf import PdfRelease as cls
    elif app == "files":
        from app_files import FilesRelease as cls
    else:
        from app_3d import ThreeDRelease as cls
    return cls


def main(argv):
    parser = argparse.ArgumentParser(prog="tools/release.sh", description=__doc__.split("\n\n")[1].strip())
    parser.add_argument("app", choices=APPS + ("all",))
    parser.add_argument("version", nargs="?",
                        help="pdf, files: YY.M.D-N; 3d: preview-X.Y.Z, vX.Y.Z or X.Y.Z (a preview); not with all")
    parser.add_argument("--pdf", dest="v_pdf", metavar="VERSION", help="all: ShenzhenPDF's version")
    parser.add_argument("--files", dest="v_files", metavar="VERSION", help="all: Shenzhen Files' version")
    parser.add_argument("--3d", dest="v_3d", metavar="VERSION", help="all: Shenzhen 3D's version")
    parser.add_argument("--publish", action="store_true", help="publish the GitHub release (default: dry run)")
    parser.add_argument("--platforms", choices=("mac", "all"), default="mac",
                        help="3d: also build Windows, Linux, Android, iOS and the web (default: mac)")
    parser.add_argument("--private-copy", action="store_true",
                        help="3d: also build and publish the copy for SHENZHEN_3D_MIRROR_OWNER")
    opts = parser.parse_args(argv)
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    if opts.app != "all":
        if not opts.version:
            parser.error(f"{opts.app} needs a version")
        if opts.app != "3d" and (opts.platforms != "mac" or opts.private_copy):
            parser.error("--platforms and --private-copy are for 3d")
        try:
            release = release_class(opts.app)(repo, opts.version, opts)
        except Failure as error:
            say(f"FAILED: {error}")
            return 2
        return release.main()
    if opts.version:
        parser.error("all takes each app's version as --pdf, --files and --3d (default: the one its commit sets)")
    return run_all(repo, opts)


def run_all(repo, opts):
    """The three apps' releases at once. Each keeps its own stages, stamps, logs and lock, as when run alone."""
    commit = git(repo, "rev-parse", "HEAD")
    releases = {}
    for app in APPS:
        app_opts = copy.copy(opts)
        if app != "3d":
            app_opts.platforms, app_opts.private_copy = "mac", False
        cls = release_class(app)
        version = getattr(opts, f"v_{app}") or committed(cls, repo, commit)
        try:
            releases[app] = cls(repo, version, app_opts)
        except Failure as error:
            say(f"FAILED: {app}: {error}")
            return 2
    start = time.time()
    codes = {}

    def one(app):
        label(f"{app}: ")
        codes[app] = releases[app].main()

    threads = [threading.Thread(target=one, args=(app,), name=f"release:{app}") for app in APPS]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    total = time.time() - start
    lines = ["", f"{'App':<8} {'Version':<16} {'Result':<8} {'Wall s':>7}  Run folder"]
    for app in APPS:
        r = releases[app]
        lines.append(f"{app:<8} {r.tag:<16} {'ok' if codes.get(app) == 0 else 'stopped':<8} {r.wall:7.0f}  {r.run_dir}")
    lines.append(f"{'all':<8} {'':<16} {'':<8} {total:7.0f}")
    print("\n".join(lines), flush=True)
    return 0 if all(code == 0 for code in codes.values()) else 1


def committed(cls, repo, commit):
    """The version a commit sets for an app (Makefile, make-app.sh, package.json)."""
    probe = cls.__new__(cls)
    probe.repo, probe.commit = repo, commit
    if cls.app == "3d":
        probe.tag = "preview-0.0.0"
    return probe.committed_version()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
