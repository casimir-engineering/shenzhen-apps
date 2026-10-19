#!/usr/bin/env python3
"""Launch performance gate: this tree against the previous release, measured side by side in one run.

Builds the previous release's app and launch probe from its tag (cached under the work directory by commit), then
launches both probes headlessly (mac/tests/launch/SPDFMacLaunchPerformanceProbe.mm: no window on screen, no Dock
icon, no activation, state in a scratch directory) in interleaved rounds:

    release            the previous release tag
    friends-off        this tree with Friends turned off in Settings
    friends-on         this tree as installed (Friends on, its helper spawned at launch)

each with an empty window and with a restored synthetic drawing set. Wall time from process spawn to the first
frame moves with machine load; the main thread's CPU time before the first frame moves far less. Interleaving
puts the load of other work on the machine on every configuration alike, and the checks compare medians of
this run's own release measurements, so the margins below only have to cover run-to-run noise, never a different
machine or a busier hour. Exit status 0 when every check passes, 1 when one fails, 2 when the gate cannot run.
"""
import argparse, json, os, shutil, statistics, subprocess, sys, time

# Margins. Each round launches every configuration once, back to back, so the machine's load at that moment
# reaches all of them alike; a check compares the median over rounds of this tree's time divided by the release's
# time in the same round. Measured 2026-10-14 (load average 4 to 40 from parallel builds), for two builds whose
# launch paths are the same, the 99th percentile of that median over 15 rounds was 1.057 for main-thread CPU and
# 1.098 for wall time; over 30 rounds 1.04 and 1.06. A check that fails after the first 15 rounds is measured again
# for 15 more and judged on all 30, so noise has to fail twice while a real regression of 5% of main-thread work
# before the first frame (about 7 ms of the 145 ms empty launch) fails both times. Wall time also carries what
# CPU time cannot see -- the main thread waiting on a lock, a file or a process -- with a wider margin.
CPU_RATIO = 1.05
WALL_RATIO = 1.08
FIRST_ROUNDS, CONFIRM_ROUNDS = 15, 15
# Friends' own main-thread work before the first frame, from 1 kHz samples of the main thread: reading its
# setting and queueing the helper spawn take well under a millisecond, so a sample or two at most lands there.
# A process spawn on the main thread before the first frame (posix_spawn, posix_spawnp, fork, NSTask) fails outright,
# in any launch of this tree: the probe records every one (SPDFMacLaunchSpawnGuard.mm), so this is no sample.
FRIENDS_PRE_FRAME_SAMPLES = 3
# The Friends attach after the first paint (connect, title-bar button, Settings source) runs on the main thread
# while the person may already be scrolling: it measures about 1.2 ms and must stay a few milliseconds.
FRIENDS_ATTACH_MAIN_MS = 8.0

CONFIGS = (("release", "release", None), ("friends-off", "current", False), ("friends-on", "current", True))
SCENARIOS = ("empty", "drawing")
BASE_SETTINGS = ("version: 1\nshowShortcutHelpOnLaunch: false\nautoUpdateEnabled: false\n"
                 "defaultReaderPromptDismissed: true\nfullDiskAccessPromptDismissed: true\n"
                 "permissionsWizardShown: true\n")


def log(text):
    print(text, flush=True)


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def previous_release(portable):
    if os.environ.get("LAUNCH_PERF_BASELINE_REF"):
        return os.environ["LAUNCH_PERF_BASELINE_REF"]
    # The newest release tag this tree descends from, never one on HEAD itself: during a release the new tag is
    # created after this sweep, and a tagged HEAD still compares against the release before it.
    # In the Shenzhen repository, where this app is apps/pdf, its release tags read pdf/<version>-<build>.
    prefix = subprocess.run(["git", "-C", portable, "rev-parse", "--show-prefix"], capture_output=True, text=True,
                            check=True).stdout.strip()
    pattern = ("" if prefix == "portable/" else "pdf/") + "[0-9]*.[0-9]*.[0-9]*-[0-9]*"
    tags = subprocess.run(["git", "-C", portable, "tag", "--merged", "HEAD", "--no-contains", "HEAD",
                           "--sort=-creatordate", "--list", pattern],
                          capture_output=True, text=True, check=True).stdout.split()
    if not tags:
        raise SystemExit("launch performance: no previous release tag reachable from HEAD")
    return tags[0]


def build_release(args, ref, work):
    """Extracts `ref` once per commit and builds its app and probe there; returns the app bundle path."""
    commit = subprocess.run(["git", "-C", args.portable, "rev-parse", f"{ref}^{{commit}}"], capture_output=True,
                            text=True, check=True).stdout.strip()
    root = os.path.join(work, "release-" + commit[:12])
    src = os.path.join(root, "src")
    if not os.path.isdir(os.path.join(src, "portable")):
        shutil.rmtree(root, ignore_errors=True)
        os.makedirs(src)
        same_mupdf = subprocess.run(["git", "-C", args.portable, "diff", "--quiet", commit, "HEAD", "--", "../mupdf"]
                                    ).returncode == 0
        paths = ["portable", "gfx", "ext", "tools"] + ([] if same_mupdf else ["mupdf"])
        archive = subprocess.Popen(["git", "-C", os.path.dirname(args.portable), "archive", commit] + paths,
                                   stdout=subprocess.PIPE)
        run(["tar", "-x", "-C", src], stdin=archive.stdout)
        if archive.wait() != 0:
            raise SystemExit(f"launch performance: git archive {ref} failed")
        with open(os.path.join(root, "mupdf-dir"), "w") as f:
            f.write(args.mupdf if same_mupdf else os.path.join(src, "mupdf"))
    mupdf = open(os.path.join(root, "mupdf-dir")).read().strip()
    jobs = str(os.cpu_count() or 4)
    log(f"Building the {ref} app and launch probe ({commit[:12]})")
    with open(os.path.join(root, "build.log"), "w") as out:
        result = subprocess.run(["make", "-C", os.path.join(src, "portable"), "-j" + jobs, "-f", "Makefile", "-f",
                                 os.path.join(args.launch_dir, "launch-performance-tests.mk"), "mac-app",
                                 "launch-performance-probe", f"LAUNCH_PERF_SRC_DIR={args.launch_dir}",
                                 f"BUILD={root}/build", f"DIST={root}/dist", f"MUPDF_DIR={mupdf}"],
                                stdout=out, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        raise SystemExit(f"launch performance: building {ref} failed, see {root}/build.log")
    return os.path.join(root, "dist", "ShenzhenPDF.app"), os.path.join(root, "build", "SPDFMacLaunchPerformanceProbe")


def bundle(app, probe, dest):
    """A copy of `app` with the probe beside its executable, under its own bundle identifier."""
    shutil.rmtree(dest, ignore_errors=True)
    run(["ditto", app, dest])
    run(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleIdentifier com.intuition.shenzhenpdf.launchperf",
         os.path.join(dest, "Contents", "Info.plist")])
    exe = os.path.join(dest, "Contents", "MacOS", "SPDFMacLaunchPerformanceProbe")
    shutil.copy2(probe, exe)
    run(["codesign", "--force", "--sign", "-", exe], stderr=subprocess.DEVNULL)
    return exe


def launch(exe, template, work, env_extra, args=()):
    state = os.path.join(work, "state")
    shutil.rmtree(state, ignore_errors=True)
    shutil.copytree(template, state)
    os.makedirs(os.path.join(state, "friends"), exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("SPDF_", "PROBE_", "SZFRIENDS_"))}
    env.update({"SPDF_STATE_DIR": state, "SZFRIENDS_STATE_DIR": os.path.join(state, "friends")})
    env.update(env_extra)
    try:
        out = subprocess.run([exe, *args], env=env, capture_output=True, text=True, timeout=120)
        rc, text = out.returncode, out.stdout
    except subprocess.TimeoutExpired:
        rc, text = -9, ""
    shutil.rmtree(state, ignore_errors=True)
    for line in text.splitlines():
        if line.startswith("PROBE ") and rc == 0:
            return json.loads(line[6:])
    raise SystemExit(f"launch performance: probe run failed (rc {rc}): {exe}")


def templates(exes, work, document):
    """Per configuration: an empty state and one that restores `document`, saved by that build itself."""
    out = {}
    for name, tree, friends in CONFIGS:
        empty = os.path.join(work, "templates", f"empty-{name}")
        shutil.rmtree(empty, ignore_errors=True)
        os.makedirs(empty)
        settings = BASE_SETTINGS
        if friends is not None:
            settings += f"friends:\n  enabled: {'true' if friends else 'false'}\n  settingsIntroduced: 1\n"
        with open(os.path.join(empty, "settings.yaml"), "w") as f:
            f.write(settings)
        with open(os.path.join(empty, "ai-settings.yaml"), "w") as f:
            f.write("onboarding_revision: 2\nonboarding_step: 3\n")
        drawing = os.path.join(work, "templates", f"drawing-{name}")
        shutil.rmtree(drawing, ignore_errors=True)
        shutil.copytree(empty, drawing)
        env = {"SPDF_STATE_DIR": drawing, "SZFRIENDS_STATE_DIR": os.path.join(drawing, "friends"), "PROBE_MODE": "seed"}
        os.makedirs(env["SZFRIENDS_STATE_DIR"])
        base = {k: v for k, v in os.environ.items() if not k.startswith(("SPDF_", "PROBE_", "SZFRIENDS_"))}
        run([exes[tree], document], env={**base, **env}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=120)
        shutil.rmtree(env["SZFRIENDS_STATE_DIR"])
        out[name] = {"empty": empty, "drawing": drawing}
    return out


def median(records, key):
    values = [r[key] for r in records if r.get(key) is not None and r[key] >= 0]
    return statistics.median(values) if values else None


def spread(records, key):
    values = sorted(r[key] for r in records if r.get(key) is not None and r[key] >= 0)
    return f"{values[0]:.0f}..{values[-1]:.0f}" if values else "-"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--probe", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--portable", required=True)
    parser.add_argument("--mupdf", required=True)
    parser.add_argument("--launch-dir", required=True)
    parser.add_argument("--rounds", type=int, default=int(os.environ.get("LAUNCH_PERF_ROUNDS", FIRST_ROUNDS)))
    args = parser.parse_args()
    work = os.path.abspath(args.work)
    os.makedirs(work, exist_ok=True)

    ref = previous_release(args.portable)
    release_app, release_probe = build_release(args, ref, work)
    exes = {"current": bundle(args.app, args.probe, os.path.join(work, "current", "ShenzhenPDF.app")),
            "release": bundle(release_app, release_probe, os.path.join(work, "release", "ShenzhenPDF.app"))}
    document = os.path.join(work, "Drawing set.pdf")
    run([exes["current"]], env={"PROBE_MODE": "fixture", "PROBE_DOCUMENT": document, "PATH": os.environ["PATH"]})
    states = templates(exes, work, document)

    results = {(name, scen): [] for name, _, _ in CONFIGS for scen in SCENARIOS}
    load = []

    def measure(rounds, scenarios):
        runs = [(name, tree, scen) for name, tree, _ in CONFIGS for scen in scenarios]
        log(f"Launching {len(runs)} configurations x {rounds} rounds, interleaved, against {ref}")
        for r in range(rounds):
            order = runs[r % len(runs):] + runs[:r % len(runs)]
            batch = {}
            for name, tree, scen in order if r % 2 == 0 else order[::-1]:
                batch[(name, scen)] = launch(exes[tree], states[name][scen], work, {"PROBE_MODE": "launch"})
                load.append(os.getloadavg()[0])
            for key, rec in batch.items():
                results[key].append(rec)

    def ratio(name, scen, metric):
        pairs = zip(results[(name, scen)], results[("release", scen)])
        return statistics.median(c[metric] / r[metric] for c, r in pairs)

    def failing():
        out = []
        for scen in SCENARIOS:
            for name in ("friends-on", "friends-off"):
                for metric, limit in (("frame_main_cpu_ms", CPU_RATIO), ("frame_ms", WALL_RATIO)):
                    if ratio(name, scen, metric) > limit:
                        out.append(scen)
        return sorted(set(out))

    measure(args.rounds, SCENARIOS)
    again = failing()
    if again:
        log(f"Measuring {', '.join(again)} again before judging")
        measure(CONFIRM_ROUNDS, again)
    sampled = {scen: launch(exes["current"], states["friends-on"][scen], work,
                            {"PROBE_MODE": "launch", "PROBE_SAMPLE": "0"}) for scen in SCENARIOS}

    log(f"\nMedians [min..max]; load average {min(load):.1f}..{max(load):.1f}")
    log(f"{'scenario':9} {'configuration':13} {'rounds':>6} {'first frame ms':>19} {'main CPU to frame ms':>21} "
        f"{'Friends attach ms':>18} {'helper start ms':>16}")
    for scen in SCENARIOS:
        for name, _, _ in CONFIGS:
            rs = results[(name, scen)]
            attach, helper = median(rs, "friends_after_paint_ms"), median(rs, "helper_start_ms")
            log(f"{scen:9} {name:13} {len(rs):6} {median(rs, 'frame_ms'):7.1f} [{spread(rs, 'frame_ms'):>9}] "
                f"{median(rs, 'frame_main_cpu_ms'):9.1f} [{spread(rs, 'frame_main_cpu_ms'):>9}] "
                f"{'-' if attach is None else f'{attach:.1f}':>18} {'-' if helper is None else f'{helper:.0f}':>16}")

    failures = []
    log("")
    for scen in SCENARIOS:
        for name in ("friends-on", "friends-off"):
            for metric, limit, what in (("frame_main_cpu_ms", CPU_RATIO, "main-thread CPU before the first frame"),
                                        ("frame_ms", WALL_RATIO, "spawn to first frame")):
                value = ratio(name, scen, metric)
                ok = value <= limit
                log(f"{'ok' if ok else 'FAIL':4} {scen} launch, {name}: {what} {value:.3f}x {ref} (limit {limit:.2f}x)")
                if not ok:
                    failures.append(f"{scen} {name} {metric}")
        on, off = results[("friends-on", scen)], results[("friends-off", scen)]
        if not all(r.get("helper_running") for r in on) or any(r.get("helper_running") for r in off):
            failures.append(f"{scen}: helper")
            log(f"FAIL {scen}: the helper must run with Friends on, and only then")
        # SZFriendsLinkState 2: connected and past the handshake once the launch settled. A link still looking for
        # its helper retries every 2 s for as long as the reader runs (a refused hello did exactly that).
        unready = [r.get("friends_link_status") or r.get("friends_link_state") for r in on
                   if r.get("friends_link_state") != 2]
        ok = not unready
        log(f"{'ok' if ok else 'FAIL':4} {scen} launch: Friends connected to its helper in {len(on) - len(unready)} of "
            f"{len(on)} launches{'' if ok else f' (otherwise: {unready[0]})'}")
        if not ok:
            failures.append(f"{scen}: Friends link")
        attach = median(on, "friends_after_paint_ms")
        ok = attach is not None and attach <= FRIENDS_ATTACH_MAIN_MS
        shown = "-" if attach is None else f"{attach:.1f}"
        log(f"{'ok' if ok else 'FAIL':4} {scen} launch: Friends attach after the first paint {shown} ms on the main "
            f"thread (limit {FRIENDS_ATTACH_MAIN_MS:.0f})")
        if not ok:
            failures.append(f"{scen}: Friends attach")
        s = sampled[scen]
        ok = s.get("sample_friends", 99) <= FRIENDS_PRE_FRAME_SAMPLES
        log(f"{'ok' if ok else 'FAIL':4} {scen} launch: {s.get('sample_friends')} of {s.get('sample_total')} "
            f"main-thread samples before the first frame in Friends code (limit {FRIENDS_PRE_FRAME_SAMPLES})")
        if not ok:
            failures.append(f"{scen}: Friends work on the main thread before the first frame")
        ours = on + off + [s]
        spawns = [r for r in ours if r.get("main_spawns_before_frame", 1) != 0]
        ok = not spawns
        detail = "" if ok else f": {spawns[0].get('main_spawns_before_frame_calls') or 'not recorded'}"
        log(f"{'ok' if ok else 'FAIL':4} {scen} launch: {len(spawns)} of {len(ours)} launches spawned a process on "
            f"the main thread before the first frame (limit 0){detail}")
        if not ok:
            failures.append(f"{scen}: process spawn on the main thread before the first frame")

    if failures:
        log(f"\nlaunch performance: {len(failures)} check(s) failed")
        return 1
    log("\nlaunch performance: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
