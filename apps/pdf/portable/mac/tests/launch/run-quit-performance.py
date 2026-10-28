#!/usr/bin/env python3
"""Launch and quit on a heavy profile: speed budgets, and nothing lost across quits.

Both run this tree's app headlessly with the launch probe inserted (mac/tests/launch/SPDFMacLaunchPerformanceProbe.mm and
SPDFMacLaunchQuitProbe.mm: no window on screen, no Dock icon, no activation, its own bundle identifier so a quit never
reaches another ShenzhenPDF, state in a scratch folder). The profile is synthetic and written by the app itself
(PROBE_MODE=profile, SPDFMacLaunchProfileSeed.mm): 100 restored PDF tabs in eight named groups, 200 more documents read
before, Collection on and holding all 300 -- session.yaml, documents.yaml and bookmarks.yaml come out at 120, 420 and
430 KB, about what a year of daily use leaves.

    budget      15 interleaved rounds (QUIT_PERF_ROUNDS) of: launch with the profile cached (warm), launch with the app,
                its documents and its state just rewritten without the file cache (cold), and quit by Cmd+Q, by the
                window's close button and by closing the last tab of a window that has another beside it. Fails when a
                median passes its budget below. --baseline-app <ShenzhenPDF.app> measures that app in the same rounds
                and prints both, for a before/after table (no budget applies to it).
    integrity   20 quit-and-relaunch rounds (QUIT_INTEGRITY_ROUNDS), each editing and quitting at once with no wait
                (SPDFMacLaunchIntegrityProbe.mm): everything left must come back, no quit or edit may ask anything, and
                the session a relaunch saves must be the session the quit wrote. Then a Dock click while a quit is
                finishing must ask for a fresh launch.

Exit status 0 when every check passes, 1 when one fails, 2 when the test cannot run.
"""
import argparse, fcntl, importlib.util, json, os, re, shutil, statistics, subprocess, sys, time

# Budgets, medians over the rounds; measured 2026-10-28 on an M-series MacBook Pro with the load average at 4 to 6.
# Close: the window must be gone within two frames at 60 Hz. Before this budget existed it stayed on screen for the
# whole quit, about 350 ms (the writes, then AppKit's terminate). The process must then exit, quickly.
HIDDEN_MS = 33.0
EXIT_MS = 1000.0
# Launch, warm, to the first frame: about 225 ms wall and 175 ms of main-thread CPU now, against 300 and 250 before
# the launch work of 2026-10-28. The budgets sit about 25% above now, below where that work started.
FRAME_MS = 285.0
FRAME_MAIN_CPU_MS = 220.0
QUIT_SCENARIOS = ("quit-cmdq", "quit-close", "quit-lasttab")
SCENARIOS = ("launch-warm", "launch-cold") + QUIT_SCENARIOS
SETTINGS = ("version: 1\nshowShortcutHelpOnLaunch: false\nautoUpdateEnabled: false\ndefaultReaderPromptDismissed: true\n"
            "fullDiskAccessPromptDismissed: true\npermissionsWizardShown: true\n"
            "friends:\n  enabled: true\n  settingsIntroduced: 1\n")
# Session keys that change with every process and every activation; everything else must come back as it was left.
# Two more differ already in the release before the quit work, measured with this test (2026-10-28): the tab strip's
# scroll offset comes back 68 px off after a round that added a tab, and a document opened just before the quit gets
# its Collection history link (collectionHistoryID) only when the next launch captures it.
VOLATILE = re.compile(r"^[ \t]*(pid|sourcePID|sourceWindow|focusedAt|lastViewedAt|tabStripScroll|collectionHistoryID):"
                      r".*\n?", re.M)
BUNDLE_ID = "com.intuition.shenzhenpdf.quitperf"
PROBE = None


def log(text):
    print(text, flush=True)


def bundle(app, dest):
    """An ad hoc signed copy of `app` under its own bundle identifier (a quit cascades to every process that shares
    the identifier, so never the installed app's). Returns its executable."""
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("launch_gate", os.path.join(here, "run-launch-performance.py"))
    gate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gate)
    exe = gate.bundle(app, dest)
    info = os.path.join(dest, "Contents", "Info.plist")
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE_ID}", info], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", dest], check=True, stderr=subprocess.DEVNULL)
    return exe


def own_processes(bundle_dir):
    out = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    return [int(line.split(None, 1)[0]) for line in out.splitlines() if bundle_dir + "/" in line]


def run(exe, state, extra, timeout=120):
    """One launch of the probed app; its PROBE record, with when the process was gone (quit_reaped_ms)."""
    os.makedirs(os.path.join(state, "friends"), exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("SPDF_", "PROBE_", "SZFRIENDS_"))}
    env.update({"SPDF_STATE_DIR": state, "SZFRIENDS_STATE_DIR": os.path.join(state, "friends"),
                "DYLD_INSERT_LIBRARIES": PROBE, **extra})
    process = subprocess.Popen([exe], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        out, err = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        out, err = process.communicate()
    reaped = (time.time() - 978307200.0) * 1000.0
    record = next((json.loads(line[6:]) for line in out.splitlines() if line.startswith("PROBE ")), None)
    # The Friends helper this copy started, should it outlive the reader: counted, then ended (only this copy's).
    bundle_dir = os.path.dirname(os.path.dirname(os.path.dirname(exe)))
    leftover = own_processes(bundle_dir)
    for pid in leftover:
        try:
            os.kill(pid, 15)
        except OSError:
            pass
    if record is None:
        raise SystemExit(f"quit performance: probe run failed (rc {process.returncode}, {extra.get('PROBE_MODE')}):\n"
                         + "\n".join(err.splitlines()[-20:]))
    record["leftover_processes"] = len(leftover)
    if "quit_at_abs_ms" in record:
        record["quit_reaped_ms"] = reaped - record["quit_at_abs_ms"]
    return record


def copy_uncached(src, dst):
    """Copy a file so that none of it is in the file cache afterwards (F_NOCACHE writes): a cold read follows."""
    tmp = dst + ".uncached"
    with open(src, "rb") as source:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, os.stat(src).st_mode & 0o7777)
        try:
            fcntl.fcntl(fd, 48, 1)  # F_NOCACHE
            for chunk in iter(lambda: source.read(1 << 22), b""):
                os.write(fd, chunk)
            os.fsync(fd)
        finally:
            os.close(fd)
    shutil.copystat(src, tmp)
    os.replace(tmp, dst)


def uncache_tree(src, dst=None):
    for root, _, files in os.walk(src):
        target = os.path.join(dst, os.path.relpath(root, src)) if dst else root
        os.makedirs(target, exist_ok=True)
        for name in files:
            path = os.path.join(root, name)
            if os.path.islink(path):
                if dst:
                    os.symlink(os.readlink(path), os.path.join(target, name))
            else:
                copy_uncached(path, os.path.join(target, name))


def seed_profile(exe, work):
    """The synthetic profile, written by the app under test; returns (state template, documents folder)."""
    template, documents = os.path.join(work, "profile"), os.path.join(work, "documents")
    shutil.rmtree(template, ignore_errors=True)
    shutil.rmtree(documents, ignore_errors=True)
    os.makedirs(template)
    with open(os.path.join(template, "settings.yaml"), "w") as f:
        f.write(SETTINGS)
    with open(os.path.join(template, "ai-settings.yaml"), "w") as f:
        f.write("onboarding_revision: 2\nonboarding_step: 3\n")
    log("Writing the synthetic profile (100 tabs in groups, 300 documents in Collection)")
    record = run(exe, template, {"PROBE_MODE": "profile", "PROBE_PROFILE_DOCS": documents}, timeout=1200)
    shutil.rmtree(os.path.join(template, "friends"), ignore_errors=True)
    if record.get("tabs") != 100:
        raise SystemExit(f"quit performance: the profile has {record.get('tabs')} tabs, not 100")
    return template, documents


def fresh_state(template, state, cold=False):
    shutil.rmtree(state, ignore_errors=True)
    if cold:
        uncache_tree(template, state)
    else:
        shutil.copytree(template, state, symlinks=True)


def median(records, key):
    values = [r[key] for r in records if r.get(key) is not None and r[key] >= 0]
    return statistics.median(values) if values else None


def budget(args, work):
    apps = {"this tree": args.app}
    if args.baseline_app:
        apps["baseline"] = args.baseline_app
    exes = {name: bundle(app, os.path.join(work, f"app-{i}", "ShenzhenPDF.app")) for i, (name, app) in enumerate(apps.items())}
    template, documents = seed_profile(exes["this tree"], work)
    runs = [(name, scenario) for name in apps for scenario in SCENARIOS]
    results = {key: [] for key in runs}
    log(f"Launching {len(runs)} configurations x {args.rounds} rounds, interleaved")
    for r in range(args.rounds):
        order = runs[r % len(runs):] + runs[:r % len(runs)]
        for name, scenario in order if r % 2 == 0 else order[::-1]:
            state = os.path.join(work, "state")
            cold = scenario == "launch-cold"
            if cold:
                uncache_tree(os.path.dirname(os.path.dirname(os.path.dirname(exes[name]))))
                uncache_tree(documents)
            fresh_state(template, state, cold)
            mode = "launch" if scenario.startswith("launch") else scenario
            results[(name, scenario)].append(run(exes[name], state, {"PROBE_MODE": mode}))
    columns = (("frame_ms", "first frame"), ("frame_main_cpu_ms", "main CPU"), ("first_page_ms", "first page"),
               ("interactive_ms", "interactive"), ("quit_hidden_ms", "window gone"), ("quit_reaped_ms", "exited"))
    log(f"\nMedians over {args.rounds} rounds, ms from process spawn (launch) or from the quit (quit)")
    log(f"{'app':10} {'scenario':13} " + " ".join(f"{title:>12}" for _, title in columns))
    for name, scenario in runs:
        values = [median(results[(name, scenario)], key) for key, _ in columns]
        log(f"{name:10} {scenario:13} " + " ".join(f"{'-' if v is None else f'{v:.1f}':>12}" for v in values))
    ours = {scenario: results[("this tree", scenario)] for scenario in SCENARIOS}
    failures = []

    def check(ok, text):
        log(f"{'ok' if ok else 'FAIL':4} {text}")
        if not ok:
            failures.append(text)

    log("")
    warm = ours["launch-warm"]
    check(median(warm, "frame_ms") <= FRAME_MS, f"warm launch to the first frame {median(warm, 'frame_ms'):.1f} ms "
          f"(budget {FRAME_MS:.0f})")
    check(median(warm, "frame_main_cpu_ms") <= FRAME_MAIN_CPU_MS, f"main-thread CPU to the first frame "
          f"{median(warm, 'frame_main_cpu_ms'):.1f} ms (budget {FRAME_MAIN_CPU_MS:.0f})")
    for scenario in QUIT_SCENARIOS:
        records = ours[scenario]
        check(median(records, "quit_hidden_ms") <= HIDDEN_MS and not any(r["quit_hidden_by_exit"] for r in records),
              f"{scenario}: window gone {median(records, 'quit_hidden_ms'):.1f} ms after the quit (budget "
              f"{HIDDEN_MS:.0f}), before the process ended in every round")
        check(median(records, "quit_reaped_ms") <= EXIT_MS, f"{scenario}: process gone "
              f"{median(records, 'quit_reaped_ms'):.1f} ms after the quit (budget {EXIT_MS:.0f})")
        check(not any(r["quit_modals"] or r["modals"] for r in records), f"{scenario}: no question asked")
    check(not any(r["leftover_processes"] for rs in ours.values() for r in rs), "no process outlived its reader")
    return failures


def normalized_session(path):
    """The session without its volatile keys; list markers become indentation, so a list item whose first key was
    dropped still lines up."""
    with open(path) as f:
        text = re.sub(r"^(\s*)- ", lambda m: m.group(1) + "  ", f.read(), flags=re.M)
    return VOLATILE.sub("", text)


def integrity(args, work):
    exe = bundle(args.app, os.path.join(work, "app-0", "ShenzhenPDF.app"))
    template, documents = seed_profile(exe, work)
    state, record = os.path.join(work, "state"), os.path.join(work, "record")
    fresh_state(template, state)
    shutil.rmtree(record, ignore_errors=True)
    os.makedirs(record)
    failures = []

    def check(ok, text):
        if not ok:
            log(f"FAIL {text}")
            failures.append(text)

    for r in range(1, args.rounds + 1):
        how = "close" if r % 3 == 0 else "cmdq"
        result = run(exe, state, {"PROBE_MODE": "quit-integrity", "PROBE_ROUND": str(r), "PROBE_RECORD": record,
                                  "PROBE_QUIT_HOW": how})
        with open(os.path.join(record, f"restored-{r}.json")) as f:
            restored = json.load(f)
        with open(os.path.join(record, f"expected-{r}.json")) as f:
            left = json.load(f)
        check(not restored["problems"], f"round {r}: restored {restored['problems']}")
        check(not left["problems"], f"round {r}: editing {left['problems']}")
        check(not result["quit_modals"] and not result["modals"],
              f"round {r}: a question was asked: {result.get('modal_texts')}")
        check(not result["quit_hidden_by_exit"], f"round {r}: the window stayed until the process ended")
        if r > 1:
            check(normalized_session(os.path.join(record, f"quit-{r - 1}.yaml")) ==
                  normalized_session(os.path.join(record, f"session-{r}.yaml")),
                  f"round {r}: the session saved after relaunching differs from the one the quit wrote")
        shutil.copy(os.path.join(state, "session.yaml"), os.path.join(record, f"quit-{r}.yaml"))
        log(f"round {r:2} ({how}): {len(left['edits'])} documents edited so far, window gone in "
            f"{result['quit_hidden_ms']:.1f} ms, exited in {result['quit_reaped_ms']:.0f} ms")
    # A Dock click 10 ms into a quit: the quitting process asks Launch Services for a fresh launch once its writes
    # are done (the probe records the request instead of launching anything).
    result = run(exe, state, {"PROBE_MODE": "quit-cmdq", "PROBE_REOPEN": "10"})
    check(result.get("relaunch_requested") is True and result.get("relaunch_app", "").endswith("ShenzhenPDF.app"),
          f"a reopen while finishing did not start a fresh launch: {result}")
    log(f"reopen while finishing: fresh launch requested {result.get('relaunch_ms', -1):.1f} ms into the quit")
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("check", choices=("budget", "integrity"))
    parser.add_argument("--app", required=True)
    parser.add_argument("--probe", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--baseline-app")
    parser.add_argument("--rounds", type=int)
    args = parser.parse_args()
    global PROBE
    PROBE = os.path.abspath(args.probe)
    if args.rounds is None:
        args.rounds = int(os.environ.get("QUIT_PERF_ROUNDS" if args.check == "budget" else "QUIT_INTEGRITY_ROUNDS",
                                         15 if args.check == "budget" else 20))
    work = os.path.abspath(os.path.join(args.work, args.check))
    os.makedirs(work, exist_ok=True)
    failures = budget(args, work) if args.check == "budget" else integrity(args, work)
    if failures:
        log(f"\nquit {args.check}: {len(failures)} check(s) failed")
        return 1
    log(f"\nquit {args.check}: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
