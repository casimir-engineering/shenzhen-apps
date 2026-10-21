#!/usr/bin/env python3
"""The processes an updater test left running, found by the exact path of their executable, never by name.

usage: sweep.py [--grace=SECONDS] [--kill] PATH...

Lists every process whose executable (proc_pidpath) lies under one of the PATHs: a test's work directory, or a test
copy's .app. That includes a copy the updater reopened after installing, which runs with launchd as its parent and
whose command line says nothing about the test. Waits up to --grace seconds for them to exit on their own; with
--kill, those still there then get SIGTERM and, 5 s later, SIGKILL. Prints each one it found and exits 1 if anything
was still running after the grace period (killed or not), 0 when nothing was. A test calls it as it exits and fails
when it reports anything.

It refuses a PATH where installed apps live (/Applications, ~/Applications, /System, a home folder or a parent of
one), so a mistaken argument can never end the person's own apps.
"""
import ctypes
import os
import signal
import sys
import time

REFUSED_UNDER = ("/Applications", "/System", "/Library", "/usr", "/bin", "/sbin", "/opt",
                 os.path.realpath(os.path.expanduser("~/Applications")))
REFUSED_EXACT = {"/", "/Users", "/private", "/private/tmp", "/private/var", "/tmp", "/var", "/Volumes",
                 os.path.realpath(os.path.expanduser("~")), os.path.realpath(os.path.expanduser("~/Library")),
                 os.path.realpath(os.path.expanduser("~/Library/Caches")),
                 os.path.realpath(os.path.expanduser("~/Downloads")), os.path.realpath(os.path.expanduser("~/Desktop"))}


def allowed(root):
    if root in REFUSED_EXACT:
        return False
    return not any(root == r or root.startswith(r + "/") for r in REFUSED_UNDER)


_libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)


def executables():
    """{pid: executable path} for every process this user can see."""
    count = _libproc.proc_listallpids(None, 0)
    pids = (ctypes.c_int * (count + 256))()
    count = _libproc.proc_listallpids(pids, ctypes.sizeof(pids))
    found = {}
    buf = ctypes.create_string_buffer(4096)
    for pid in pids[:max(count, 0)]:
        if pid <= 1:
            continue
        if _libproc.proc_pidpath(pid, buf, ctypes.sizeof(buf)) > 0:
            found[pid] = buf.value.decode("utf-8", "replace")
    return found


def owned(roots):
    me = {os.getpid(), os.getppid()}
    return {pid: exe for pid, exe in executables().items()
            if pid not in me and any(exe.startswith(root + "/") for root in roots)}


def main(argv):
    grace = 0.0
    kill = False
    roots = []
    for arg in argv:
        if arg.startswith("--grace="):
            grace = float(arg.split("=", 1)[1])
        elif arg == "--kill":
            kill = True
        elif arg.startswith("--"):
            print(f"sweep.py: unknown option {arg}", file=sys.stderr)
            return 2
        else:
            roots.append(os.path.realpath(arg).rstrip("/"))
    if not roots:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    for root in roots:
        if not allowed(root):
            print(f"sweep.py: refusing {root}: installed apps live there", file=sys.stderr)
            return 2
    deadline = time.time() + grace
    left = owned(roots)
    while left and time.time() < deadline:
        time.sleep(0.5)
        left = owned(roots)
    if not left:
        return 0
    for pid, exe in sorted(left.items()):
        print(f"still running: {pid} {exe}")
    if kill:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            for pid, exe in owned(roots).items():
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    pass
            stop = time.time() + 5
            while owned(roots) and time.time() < stop:
                time.sleep(0.25)
            if not owned(roots):
                break
        for pid, exe in sorted(owned(roots).items()):
            print(f"could not end: {pid} {exe}")
        print("ended" if not owned(roots) else "some could not be ended")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
