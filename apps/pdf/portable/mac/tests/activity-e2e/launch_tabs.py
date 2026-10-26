#!/usr/bin/env python3
"""Launch with about a hundred restored tabs: this tree's app against another build, side by side.

usage: launch_tabs.py --app <ShenzhenPDF.app> --baseline <ShenzhenPDF.app> --probe <SPDFMacLaunchPerformanceProbe.dylib>
                      --work <new folder> [--rounds 15] [--tabs 100]

Recording when documents are opened and viewed must add nothing before the first frame. Both apps restore the same
session of --tabs PDFs in four groups, with an activity.yaml holding a date for each (the baseline ignores it), and
are measured by the launch performance probe (mac/tests/launch) in interleaved rounds: spawn to first frame and the
main thread's CPU before it. Prints the medians and the median per-round ratio; exit status 1 when the ratio of
main-thread CPU passes the release gate's 1.05 or wall time its 1.08.
"""
import argparse
import importlib.util
import os
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from run_activity_e2e import READER_SETTINGS, write_activity, write_documents, write_session  # noqa: E402

spec = importlib.util.spec_from_file_location("launchperf", os.path.join(HERE, "../launch/run-launch-performance.py"))
launchperf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launchperf)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--probe", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--rounds", type=int, default=15)
    parser.add_argument("--tabs", type=int, default=100)
    args = parser.parse_args()
    work = os.path.abspath(args.work)
    os.makedirs(work)
    launchperf.PROBE = os.path.abspath(args.probe)
    template = os.path.join(work, "template")
    os.makedirs(template)
    with open(os.path.join(template, "settings.yaml"), "w") as f:
        f.write(READER_SETTINGS)
    with open(os.path.join(template, "ai-settings.yaml"), "w") as f:
        f.write("onboarding_revision: 2\nonboarding_step: 3\n")
    paths = write_documents(os.path.join(work, "documents"), [f"Spec {i:03d}" for i in range(args.tabs)])
    groups = [(f"G{i * 4 // args.tabs}", f"Group {i * 4 // args.tabs}", "Blue") for i in range(args.tabs)]
    write_session(template, paths, groups, selected=0)
    now = time.time()
    write_activity(template, {p: {"opened": now - 86400 * i, "viewed": now - 86400 * i} for i, p in enumerate(paths)},
                   now - 30 * 86400)
    exes = {"current": launchperf.bundle(os.path.abspath(args.app), os.path.join(work, "current", "ShenzhenPDF.app")),
            "baseline": launchperf.bundle(os.path.abspath(args.baseline), os.path.join(work, "baseline", "ShenzhenPDF.app"))}
    results = {"current": [], "baseline": []}
    for r in range(args.rounds):
        for name in (("current", "baseline") if r % 2 == 0 else ("baseline", "current")):
            results[name].append(launchperf.launch(exes[name], template, work, {"PROBE_MODE": "launch"}))
    print(f"{args.tabs} restored tabs, {args.rounds} interleaved rounds")
    for name in ("baseline", "current"):
        rs = results[name]
        print(f"{name:9} first frame {launchperf.median(rs, 'frame_ms'):7.1f} ms [{launchperf.spread(rs, 'frame_ms')}]  "
              f"main CPU to frame {launchperf.median(rs, 'frame_main_cpu_ms'):6.1f} ms "
              f"[{launchperf.spread(rs, 'frame_main_cpu_ms')}]")
    ratios = {}
    for metric in ("frame_ms", "frame_main_cpu_ms"):
        ratios[metric] = statistics.median(c[metric] / b[metric] for c, b in zip(results["current"], results["baseline"]))
        print(f"median per-round ratio {metric}: {ratios[metric]:.3f}")
    ok = ratios["frame_main_cpu_ms"] <= 1.05 and ratios["frame_ms"] <= 1.08
    print("launch with restored tabs: " + ("unchanged" if ok else "SLOWER"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
