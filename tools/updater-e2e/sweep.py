#!/usr/bin/env python3
"""The processes an updater test left running, found by the exact path of their executable, never by name.

usage: sweep.py [--grace=SECONDS] [--kill] [--orphans] PATH...

Lists every process whose executable lies under one of the PATHs: a test's work directory, or a test copy's .app.
That includes a copy the updater reopened after installing, which runs with launchd as its parent and whose command
line says nothing about the test, and a process whose bundle the updater has since moved away or deleted (the Friends
helper an old test copy started, still running after Squirrel replaced that copy): it is found by the path it was
started from (the kernel's exec path and argv[0]) as well as by where its executable is now (proc_pidpath).
--orphans keeps only those whose parent is launchd: what a finished test left behind, not what a test still running
has open. Waits up to --grace seconds for them to exit on their own; with
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
    """{pid: executable path, or ""} for every process."""
    count = _libproc.proc_listallpids(None, 0)
    pids = (ctypes.c_int * (count + 256))()
    count = _libproc.proc_listallpids(pids, ctypes.sizeof(pids))
    found = {}
    buf = ctypes.create_string_buffer(4096)
    for pid in pids[:max(count, 0)]:
        if pid <= 1:
            continue
        # "" when there is none to read: a deleted executable, or another user's process.
        readable = _libproc.proc_pidpath(pid, buf, ctypes.sizeof(buf)) > 0
        found[pid] = buf.value.decode("utf-8", "replace") if readable else ""
    return found


_libc = ctypes.CDLL(None, use_errno=True)
_args = ctypes.create_string_buffer(1 << 20)  # kern.argmax


def started_from(pid):
    """The exec path and argv[0] the process was started with (KERN_PROCARGS2), which stay as they were when the
    executable is moved or deleted afterwards."""
    size = ctypes.c_size_t(ctypes.sizeof(_args))
    mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
    if _libc.sysctl(mib, 3, _args, ctypes.byref(size), None, 0) != 0 or size.value < 4:
        return []
    parts = [p for p in ctypes.string_at(_args, size.value)[4:].split(b"\0") if p][:2]
    return [p.decode("utf-8", "replace") for p in parts if p.startswith(b"/")]


def parent(pid):
    info = ctypes.create_string_buffer(136)  # struct proc_bsdinfo; pbi_ppid at offset 16
    if _libproc.proc_pidinfo(pid, 3, 0, info, 136) < 20:  # PROC_PIDTBSDINFO
        return None
    return int.from_bytes(info.raw[16:20], "little")


def owned(roots, orphans=False):
    me = {os.getpid(), os.getppid()}
    found = {}
    for pid, exe in executables().items():
        if pid in me or (orphans and parent(pid) != 1):
            continue
        for path in [exe, *started_from(pid)]:
            if path and any(path.startswith(root + "/") for root in roots):
                found[pid] = path
                break
    return found


def main(argv):
    grace = 0.0
    kill = False
    orphans = False
    roots = []
    for arg in argv:
        if arg.startswith("--grace="):
            grace = float(arg.split("=", 1)[1])
        elif arg == "--kill":
            kill = True
        elif arg == "--orphans":
            orphans = True
        elif arg.startswith("--"):
            print(f"sweep.py: unknown option {arg}", file=sys.stderr)
            return 2
        else:
            # Both spellings: a process started through a symlinked path (/tmp, /var) keeps that path in its argv.
            for root in (os.path.realpath(arg), os.path.abspath(arg)):
                if root.rstrip("/") not in roots:
                    roots.append(root.rstrip("/"))
    if not roots:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    for root in roots:
        if not allowed(root):
            print(f"sweep.py: refusing {root}: installed apps live there", file=sys.stderr)
            return 2
    deadline = time.time() + grace
    left = owned(roots, orphans)
    while left and time.time() < deadline:
        time.sleep(0.5)
        left = owned(roots, orphans)
    if not left:
        return 0
    for pid, exe in sorted(left.items()):
        print(f"still running: {pid} {exe}")
    if kill:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            for pid, exe in owned(roots, orphans).items():
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    pass
            stop = time.time() + 5
            while owned(roots, orphans) and time.time() < stop:
                time.sleep(0.25)
            if not owned(roots, orphans):
                break
        for pid, exe in sorted(owned(roots, orphans).items()):
            print(f"could not end: {pid} {exe}")
        print("ended" if not owned(roots, orphans) else "some could not be ended")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
