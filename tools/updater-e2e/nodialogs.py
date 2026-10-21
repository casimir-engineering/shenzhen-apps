#!/usr/bin/env python3
"""What keeps an updater test off the person's screen, apart from the test's own hidden windows.

usage: nodialogs.py unregister ROOT...       forget every app under ROOT in LaunchServices; exit 1 if any is still known
       nodialogs.py stale                    the same for every test copy of any earlier run (".../updater-e2e/...")
       nodialogs.py known ROOT...            list the apps under ROOT that LaunchServices knows (exit 1 if any)
       nodialogs.py prompts START END        Gatekeeper prompts in the unified log between two epoch times (exit 1 if any)

Why. A test copy of Shenzhen 3D must keep the released bundle identifier (Squirrel compares the update's designated
requirement), and every copy that runs registers itself with LaunchServices under it. Afterwards LaunchServices can
pick such a copy for anything that opens "Shenzhen 3D" by identifier, URL scheme or document: a copy that is
unnotarized and was modified after signing (the fixture, the relaunch copy: spctl says "Unnotarized Developer ID"), or
one in a folder the person never installed from. Gatekeeper then shows its "is damaged and can't be opened" dialog on
the owner's screen, long after the test ended. So a test unregisters its copies as soon as each one has stopped, and
checks the unified log for a Gatekeeper prompt (syspolicyd, CoreServicesUIAgent) during its own window: a prompt fails
the run.

Only paths under the given ROOTs, or (stale) under an updater-e2e folder, are ever unregistered.
"""
import os
import re
import subprocess
import sys
import time

LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/"
              "Versions/A/Support/lsregister")
LOG = "/usr/bin/log"
# What the unified log says when Gatekeeper rejects something and tells the person about it: syspolicyd records the
# denial and ends the process, CoreServicesUIAgent puts the dialog (or the "Verifying" panel) up.
PROMPT_PREDICATE = (
    '(process == "syspolicyd" AND (eventMessage CONTAINS "Gatekeeper denial breadcrumb" '
    'OR eventMessage CONTAINS "Terminating process due to Gatekeeper rejection")) '
    'OR (process == "CoreServicesUIAgent" AND (eventMessage CONTAINS "uiagent] displaying" '
    'OR eventMessage CONTAINS "GKQuarantineResolver" OR eventMessage CONTAINS "progressed to"))')


def real(path):
    return os.path.realpath(path)


def registered_apps():
    """Every bundle path LaunchServices knows (its dump lists each `path:` once per bundle record)."""
    out = subprocess.run([LSREGISTER, "-dump"], capture_output=True, text=True, errors="replace").stdout
    paths = []
    for line in out.splitlines():
        m = re.match(r"^path:\s+(.*?) \(0x[0-9a-f]+\)\s*$", line)
        if m:
            paths.append(m.group(1))
    return paths


def under(path, roots):
    p = real(path)
    return any(p == r or p.startswith(r + os.sep) for r in roots)


def known_under(roots):
    roots = [real(r) for r in roots]
    # The dump holds the path as registered, which may spell /private/var as /var: compare both spellings.
    return sorted({p for p in registered_apps() if under(p, roots) or any(p.startswith(r + os.sep) for r in roots)})


def unregister(paths):
    for p in paths:
        subprocess.run([LSREGISTER, "-u", p], capture_output=True)


def forget(roots):
    """Unregisters every app under `roots` (twice at most: a helper can be re-listed with its parent). Returns the
    paths LaunchServices still knows afterwards."""
    left = []
    for _ in range(2):
        left = known_under(roots)
        if not left:
            return []
        unregister(left)
    return known_under(roots)


def forget_stale():
    stale = sorted({p for p in registered_apps() if "/updater-e2e/" in p})
    unregister(stale)
    return sorted({p for p in registered_apps() if "/updater-e2e/" in p}), stale


def prompts(start, end, settle=3):
    """The Gatekeeper prompt lines in the unified log between two epoch times; [] when there were none. The log is
    given a moment to persist what the last seconds wrote."""
    time.sleep(settle)
    fmt = "%Y-%m-%d %H:%M:%S"
    cmd = [LOG, "show", "--style", "compact", "--info", "--debug", "--start", time.strftime(fmt, time.localtime(start - 1)),
           "--end", time.strftime(fmt, time.localtime(end + settle)), "--predicate", PROMPT_PREDICATE]
    p = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    if p.returncode != 0:
        return [f"log show failed ({p.returncode}): {p.stderr.strip()[:200]}"]
    return [l[:300] for l in p.stdout.splitlines() if l and not l.startswith(("Timestamp", "Filtering"))]


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    cmd, args = argv[0], argv[1:]
    if cmd == "unregister" and args:
        left = forget(args)
        for p in left:
            print(f"still registered with LaunchServices: {p}")
        return 1 if left else 0
    if cmd == "known" and args:
        known = known_under(args)
        for p in known:
            print(p)
        return 1 if known else 0
    if cmd == "stale":
        left, forgot = forget_stale()
        print(f"forgot {len(forgot) - len(left)} of {len(forgot)} test copies of earlier runs")
        for p in left:
            print(f"still registered with LaunchServices: {p}")
        return 1 if left else 0
    if cmd == "prompts" and len(args) == 2:
        found = prompts(float(args[0]), float(args[1]))
        for line in found:
            print(line)
        return 1 if found else 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
