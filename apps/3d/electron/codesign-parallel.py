#!/usr/bin/env python3
"""codesign, several at once, for electron-builder's signing pass (package-mac.mjs puts this first on its PATH as
`codesign` when SZF_PARALLEL_CODESIGN is set).

@electron/osx-sign signs every file of the app one after the other, deepest first, each with a secure timestamp from
Apple's server: some seven hundred signatures, three minutes mostly spent waiting on the network. This runs them side by
side and keeps everything else as it was:

- a call that signs (--sign, -s) starts the real /usr/bin/codesign with the same arguments in the background and
  returns at once, after every signature still running on a deeper path, or on the same file by another path (a
  framework's Versions/Current), has finished (a bundle is never signed before what it holds; paths at one depth
  never hold one another), and while fewer than SZF_CODESIGN_JOBS (8) run;
- any other call (--verify, --display) first waits for every signature started, fails with their output if one did,
  then runs as itself;
- `codesign --szf-drain` waits for everything and fails if anything failed (package-mac.mjs runs it after the build).

State lives in SZF_CODESIGN_STATE, a directory of the packaging run.
"""
import os
import subprocess
import sys
import time

REAL = "/usr/bin/codesign"
STATE = os.environ.get("SZF_CODESIGN_STATE", "")
JOBS = int(os.environ.get("SZF_CODESIGN_JOBS") or 8)


def jobs():
    """[(job, depth, real path, finished status or None)]"""
    out = []
    for name in sorted(os.listdir(STATE)):
        if not name.endswith(".job"):
            continue
        job = os.path.join(STATE, name[:-4])
        try:
            depth, real = open(job + ".job").read().rstrip("\n").split(" ", 1)
            depth = int(depth)
        except (OSError, ValueError):
            continue
        status = None
        if os.path.exists(job + ".status"):
            try:
                status = int(open(job + ".status").read().strip() or "1")
            except (OSError, ValueError):
                status = None  # being written
            if status == 0:
                os.replace(job + ".job", job + ".done")  # finished: never read again
                continue
        out.append((job, depth, real, status))
    return out


def wait(until):
    while not until(jobs()):
        time.sleep(0.05)


def failures():
    """The signatures that failed, reported once (their output on stderr), so a retry of the whole pass can go on."""
    bad = [(job, status) for job, _, _, status in jobs() if status not in (None, 0)]
    for job, status in bad:
        try:
            sys.stderr.write(open(job + ".log", errors="replace").read())
        except OSError:
            pass
        sys.stderr.write(f"codesign-parallel: {open(job + '.args').read().strip()} exited with {status}\n")
        os.replace(job + ".job", job + ".failed")
    return bad


def main(argv):
    if not STATE or not os.path.isdir(STATE):
        os.execv(REAL, [REAL] + argv)
    if argv == ["--szf-drain"]:
        wait(lambda js: all(status is not None for _, _, _, status in js))
        return 1 if failures() else 0
    # Only @electron/osx-sign's own pass, whose every signature names entitlements and is followed by its
    # verification; anything else (the Friends helper signed in afterPack) runs as it always did, in turn.
    signing = any(a in ("--sign", "-s") or a.startswith("--sign=") for a in argv) and "--entitlements" in argv and \
        not any(a in ("--verify", "-v", "--display", "-d") for a in argv)
    if not signing:
        wait(lambda js: all(status is not None for _, _, _, status in js))
        if failures():
            return 1
        os.execv(REAL, [REAL] + argv)
    target = os.path.abspath(argv[-1])
    depth = len(target.split(os.sep))
    # A framework's Versions/Current is Versions/A: the same file by two paths is never signed twice at once.
    real = os.path.realpath(target)
    wait(lambda js: not any(status is None and (d > depth or r == real) for _, d, r, status in js) and
         sum(1 for _, _, _, status in js if status is None) < JOBS)
    if failures():
        return 1
    job = os.path.join(STATE, f"{time.time_ns():020d}-{os.getpid()}")
    with open(job + ".args", "w") as f:
        f.write(" ".join(argv) + "\n")
    with open(job + ".job.tmp", "w") as f:
        f.write(f"{depth} {real}\n")
    os.replace(job + ".job.tmp", job + ".job")
    log = open(job + ".log", "w")
    # The status file is written by a shell that outlives this process: electron-builder sees this call return now.
    subprocess.Popen(["/bin/sh", "-c", 'r=0; "$0" "$@" || r=$?; echo $r > "$SZF_JOB.status.tmp" && '
                      'mv "$SZF_JOB.status.tmp" "$SZF_JOB.status"', REAL, *argv],
                     stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True,
                     env=dict(os.environ, SZF_JOB=job))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
