#!/usr/bin/env python3
"""Where the main thread's launch time goes, and what changed between builds.

Reads the samples szf_launch_probe.c records with SZF_PROBE_SAMPLES (launch_perf.py compare --samples): each
sample is a main-thread stack weighted by the CPU time the thread used since the previous one. Prints, per build,
the inclusive main-thread CPU milliseconds per launch of every function (symbols from nm on the app's own
binaries; system libraries by image) and the largest differences against the first build named.

Usage: launch_profile.py BASE NAME=PROBE_COPY:SAMPLES_FILE ... [--top=N]"""
import bisect, collections, os, subprocess, sys

args = [a for a in sys.argv[1:] if not a.startswith("--")]
top = 40
for a in sys.argv:
    if a.startswith("--top="):
        top = int(a.split("=")[1])
base = args[0]
variants = {}
for spec in args[1:]:
    name, rest = spec.split("=", 1)
    app, samples = rest.split(":", 1)
    variants[name] = (app, samples)

symcache = {}


def symbols(app, image):
    key = (app, image)
    if key in symcache:
        return symcache[key]
    path = None
    for sub in ("Contents/MacOS", "Contents/Frameworks"):
        p = os.path.join(app, sub, image)
        if os.path.exists(p):
            path = p
    table = None
    if path:
        out = subprocess.run(["nm", "-n", "--defined-only", path], capture_output=True, text=True).stdout
        addrs, names = [], []
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[1].lower() == "t":
                addrs.append(int(parts[0], 16))
                names.append(parts[2].lstrip("_"))
        table = (addrs, names)
    symcache[key] = table
    return table


def name_of(app, frame):
    image, off = frame.rsplit(":", 1)
    t = symbols(app, image)
    if not t or not t[0]:
        return "[%s]" % image
    i = bisect.bisect_right(t[0], int(off, 16)) - 1
    if i < 0:
        return "[%s]" % image
    return "%s`%s" % (image.split(".")[0], t[1][i])


results = {}
for name, (app, path) in variants.items():
    runs = 0
    incl = collections.Counter()
    total = 0
    for line in open(path):
        if line.startswith("# run"):
            runs += 1
            continue
        parts = line.split()
        if not parts:
            continue
        weight, frames = int(parts[0]) / 1000.0, parts[1:]  # main-thread CPU ms since the previous sample
        total += weight
        seen = set()
        for fr in frames:
            n = name_of(app, fr)
            if n not in seen:
                seen.add(n)
                incl[n] += weight
    results[name] = (runs, total, incl)
    print("%s: %d runs, %.1f main-thread CPU ms/run sampled" % (name, runs, total / runs))

b_runs, b_total, b_incl = results[base]
for name, (runs, total, incl) in results.items():
    if name == base:
        continue
    print("\n== %s vs %s: inclusive main-thread CPU ms per run, largest increases" % (name, base))
    keys = set(incl) | set(b_incl)
    diffs = []
    for k in keys:
        a = incl[k] / runs
        b = b_incl[k] / b_runs
        diffs.append((a - b, k, a, b))
    diffs.sort(reverse=True)
    for d, k, a, b in diffs[:top]:
        print("  %+7.2f  %7.2f  %7.2f  %s" % (d, a, b, k))
    print("  ... largest decreases")
    for d, k, a, b in sorted(diffs)[:15]:
        print("  %+7.2f  %7.2f  %7.2f  %s" % (d, a, b, k))
