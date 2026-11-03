#!/usr/bin/env python3
"""Who serves the person's own Shenzhen Friends: the processes holding ~/Library/Application Support/Shenzhen
Friends/ipc/helper.sock. Reads only (lsof); connects to nothing and ends nothing.

usage: friends-socket.py [--pids]

Exits 0 when nothing holds the socket or only helpers of apps installed in /Applications do, 1 (with one line per
holder) when anything else does: a test copy's helper that ran with the person's home took over their Friends, and
their own apps cannot reach it. --pids prints the holders' PIDs, one per line, and exits 0.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sweep import executables, started_from  # noqa: E402

SOCKET = os.path.realpath(os.path.expanduser("~/Library/Application Support/Shenzhen Friends")) + "/ipc/helper.sock"
INSTALLED = "/Applications/"


def holders():
    """{pid: the paths it is judged by (judged_paths)} for every process with the socket open."""
    out = subprocess.run(["lsof", "-n", "-P", "-U", "-F", "pn"], capture_output=True, text=True).stdout
    pids, pid = set(), None
    for line in out.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n") and line[1:] == SOCKET and pid:
            pids.add(pid)
    exes = executables()
    return {pid: judged_paths(exes.get(pid, ""), started_from(pid)) for pid in sorted(pids)}


def judged_paths(executable, started):
    """The paths a holder is judged by: where it was started from (exec path and argv[0]) when that can be read, else
    its executable. Installing a new build moves the running app's bundle aside, so the person's own helper, started
    from /Applications, then has its executable wherever the old bundle went; where it was started from still says
    /Applications. A test copy's helper is started from the test copy, wherever its executable is now."""
    return [p for p in started if p] or ([executable] if executable else [])


def foreign(found):
    """The holders that are not a helper of an app in /Applications: every path they were started from must be."""
    return {pid: paths for pid, paths in found.items() if not paths or not all(p.startswith(INSTALLED) for p in paths)}


def main(argv):
    found = holders()
    if argv == ["--pids"]:
        for pid in found:
            print(pid)
        return 0
    if argv:
        print(__doc__.strip().splitlines()[3], file=sys.stderr)
        return 2
    bad = foreign(found)
    for pid, paths in bad.items():
        print(f"holds {SOCKET}: {pid} {paths[0] if paths else '(executable unknown)'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
