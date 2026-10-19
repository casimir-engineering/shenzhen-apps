#!/usr/bin/env python3
"""Headless launch and idle measurements of Shenzhen Files builds; tools/test-macos-launch-performance.sh runs it.

Every run starts Contents/MacOS/nautilus of a probe copy of an app (see `prepare`) directly, with the environment
Contents/MacOS/nautilus-launcher exports, its own XDG and Friends state, and libszf_launch_probe.dylib inserted: no
Dock icon, no focus change, no window on screen (tools/perf/szf_launch_probe.c). Nothing of the person's own
Shenzhen Files (settings, update state, Friends identity) is read or written, and their running copy is never
contacted: the probe copy has another bundle id, its directory name does not end in .app (so the updater stays
off), GSettings uses a keyfile in the run's directory, and no D-Bus session bus is reachable.

Subcommands
  prepare APP DEST       copy APP to DEST as a probe copy
  compare                interleaved A/B launches of a baseline and a candidate; the gate
  idle                   memory and CPU over an idle minute, app and Friends helper, all variants at once
"""
import argparse, json, os, random, shutil, signal, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))

# What the gate holds a candidate to, per metric: it fails when the median of the per-round differences
# (candidate - baseline) is above both the absolute and the relative allowance AND the candidate was slower in
# at least 3 of every 4 rounds. Main-thread CPU time is the least sensitive to other load on the machine, so it
# gets the tightest allowance; wall times get more room.
#   launch   a small folder: launch to the first window, its first frame, and the folder listed
#   folders  a folder of thousands of subfolders, listed with "folders first": what each folder costs to load
#            (the 26.10 package check once made it 20% slower). Its allowances leave room for the few
#            microseconds a folder that check still takes.
GATES = {
    "launch": {
        "map_main_cpu_ms": (4.0, 0.025),
        "map_ms": (12.0, 0.05),
        "paint_ms": (20.0, 0.05),
        "loaded_ms": (25.0, 0.05),
        "loaded_main_cpu_ms": (8.0, 0.03),
        "loaded_footprint_mb": (8.0, 0.03),
    },
    "folders": {
        "map_main_cpu_ms": (4.0, 0.025),
        "loaded_ms": (40.0, 0.06),
        "loaded_main_cpu_ms": (30.0, 0.05),
        "loaded_footprint_mb": (8.0, 0.03),
    },
}
REPORTED = ["ctor_ms", "display_open_ms", "map_ms", "map_main_cpu_ms", "map_proc_cpu_ms", "paint_ms",
            "loaded_ms", "loaded_main_cpu_ms", "loaded_proc_cpu_ms", "loaded_footprint_mb"]


def tool(name):
    path = os.path.join(os.environ.get("SZF_PERF_TOOLS", HERE), name)
    if not os.path.exists(path):
        sys.exit("error: %s is missing; tools/test-macos-launch-performance.sh builds it" % path)
    return path


# ---- probe copies -----------------------------------------------------------------------------------------------

def cmd_prepare(a):
    app = os.path.realpath(a.app)
    if app.startswith("/Applications/"):
        sys.exit("error: refusing to use an installed app; build one (package/make-app.sh) and pass that")
    if not os.path.isfile(os.path.join(app, "Contents", "MacOS", "nautilus")):
        sys.exit("error: %s is not a Shenzhen Files app bundle" % app)
    dest = os.path.abspath(a.dest)
    if dest.endswith(".app"):
        sys.exit("error: the probe copy's name must not end in .app (the updater runs in a .app)")
    if os.path.exists(dest):
        shutil.rmtree(dest)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    # ditto keeps modification times. A plain cp -R does not: a folder can end up newer than the icon-theme.cache
    # in it, and GTK then ignores the cache and reads the icon folders on every launch (3-4 ms of main thread).
    subprocess.run(["/usr/bin/ditto", app, dest], check=True)
    plist = os.path.join(dest, "Contents", "Info.plist")
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleIdentifier com.intuition.shenzhenfiles.perfprobe",
                    "-c", "Delete :LSUIElement", plist], capture_output=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Add :LSUIElement bool true", plist], check=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", dest], check=True, capture_output=True)
    print(dest)


# ---- one launch ---------------------------------------------------------------------------------------------------

def seed(rundir, friends):
    cfg = os.path.join(rundir, "config")
    os.makedirs(os.path.join(cfg, "nautilus"), exist_ok=True)
    os.makedirs(os.path.join(cfg, "glib-2.0", "settings"), exist_ok=True)
    for d in ("data", "cache", "state", "friends"):
        os.makedirs(os.path.join(rundir, d), exist_ok=True)
    # The one-time first-launch dialogs count as answered, as on every launch after the first.
    with open(os.path.join(cfg, "nautilus", "macos-fda.ini"), "w") as f:
        f.write("[fda]\nprompt-dismissed=true\nfirst-launch-prompt-shown=true\n")
    with open(os.path.join(cfg, "nautilus", "macos-integration.ini"), "w") as f:
        f.write("[integration]\nchoice-made=true\n")
    # Settings as a returning user has them, the same for every launch: the GTK settings already migrated and
    # "folders first" on, so loading a folder asks about each subfolder whether it is a package.
    with open(os.path.join(cfg, "glib-2.0", "settings", "keyfile"), "w") as f:
        f.write("[org/gnome/nautilus/preferences]\nmigrated-gtk-settings=true\n")
        if friends in ("on", "off"):
            f.write("friends-enabled=%s\n" % ("true" if friends == "on" else "false"))
        f.write("\n[org/gtk/gtk4/settings/file-chooser]\nsort-directories-first=true\n")


def environment(app, rundir, out, exit_after, extra=None):
    res = os.path.join(app, "Contents", "Resources")
    env = {
        "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "LOGNAME": os.environ.get("USER", ""),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/zsh", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "LANG": "en_US.UTF-8",
        # What Contents/MacOS/nautilus-launcher exports.
        "XDG_DATA_DIRS": res + "/share",
        "GSETTINGS_SCHEMA_DIR": res + "/share/glib-2.0/schemas",
        "NAUTILUS_DATADIR": res + "/share/nautilus",
        "GDK_PIXBUF_MODULE_FILE": res + "/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache",
        "GDK_PIXBUF_MODULEDIR": res + "/lib/gdk-pixbuf-2.0/2.10.0/loaders",
        "GIO_MODULE_DIR": res + "/lib/gio/modules",
        "FONTCONFIG_FILE": res + "/etc/fonts/fonts.conf",
        # Isolation.
        "XDG_CONFIG_HOME": rundir + "/config", "XDG_DATA_HOME": rundir + "/data",
        "XDG_CACHE_HOME": rundir + "/cache", "XDG_STATE_HOME": rundir + "/state",
        "GSETTINGS_BACKEND": "keyfile",
        "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + rundir + "/no-bus",
        # An ad hoc build honours it; its helper then uses no radio, no network and no host (test mode).
        "SZFRIENDS_STATE_DIR": rundir + "/friends",
        "DYLD_INSERT_LIBRARIES": tool("libszf_launch_probe.dylib"),
        "SZF_PROBE_OUT": out, "SZF_PROBE_EXIT": exit_after,
    }
    env.update(extra or {})
    return env


def helper_pids(app, rundir):
    """The Friends helpers serving this run directory's state (they hold its helper.lock)."""
    lock = os.path.join(rundir, "friends", "helper.lock")
    if not os.path.exists(lock):
        return []
    r = subprocess.run(["/usr/bin/pgrep", "-f", os.path.join(app, "Contents", "Helpers")],
                       capture_output=True, text=True)
    candidates = [int(x) for x in r.stdout.split()]
    if not candidates:
        return []
    r = subprocess.run(["/usr/sbin/lsof", "-t", "--", lock], capture_output=True, text=True)
    holders = {int(x) for x in r.stdout.split()}
    return [p for p in candidates if p in holders]


def stop_helpers(app, rundir):
    for sig, tries in ((signal.SIGTERM, 50), (signal.SIGKILL, 20)):
        pids = helper_pids(app, rundir)
        if not pids:
            return
        for pid in pids:
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        for _ in range(tries):
            if not helper_pids(app, rundir):
                return
            time.sleep(0.1)


def read_events(path):
    ev = {}
    try:
        with open(path) as f:
            for line in f:
                if line.strip():
                    e = json.loads(line)
                    ev.setdefault(e["event"], e)
    except FileNotFoundError:
        pass
    return ev


def launch_once(app, rundir, folder, exit_after, timeout, extra=None):
    out = os.path.join(rundir, "probe.jsonl")
    if os.path.exists(out):
        os.unlink(out)
    env = environment(app, rundir, out, exit_after, extra)
    with open(os.path.join(rundir, "app.log"), "w") as log:
        p = subprocess.Popen([os.path.join(app, "Contents", "MacOS", "nautilus"), folder], env=env, stdout=log,
                             stderr=subprocess.STDOUT, cwd=rundir)
        try:
            code = p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
            code = "timeout"
    ev = read_events(out)
    stop_helpers(app, rundir)
    res = {"exit": code}
    # Counted by the probe until the map; a run that never mapped counts what it saw.
    if "map" in ev:
        res["main_spawns"] = ev["map"].get("main_spawns", 0)
    elif "main_spawn" in ev:
        res["main_spawns"] = 1
    if "main_spawn" in ev:
        res["main_spawn"] = "%s %s" % (ev["main_spawn"].get("call"), ev["main_spawn"].get("path"))
    if "ON_SCREEN" in ev:
        res["on_screen"] = ev["ON_SCREEN"]
    for name in ("ctor", "display_open", "map", "paint", "loaded"):
        if name in ev:
            res[name + "_ms"] = ev[name]["t_ms"]
            res[name + "_main_cpu_ms"] = ev[name]["main_cpu_ms"]
            res[name + "_proc_cpu_ms"] = ev[name]["proc_cpu_ms"]
            res[name + "_footprint_mb"] = ev[name]["footprint_mb"]
    return res


# ---- statistics ---------------------------------------------------------------------------------------------------

def quantile(xs, p):
    xs = sorted(xs)
    k = (len(xs) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def paired(rows, metric, base, cand):
    by = {}
    for r in rows:
        if r.get("exit") == 0 and metric in r:
            by.setdefault(r["round"], {})[r["variant"]] = r[metric]
    d = [v[cand] - v[base] for v in by.values() if base in v and cand in v]
    b = [v[base] for v in by.values() if base in v]
    c = [v[cand] for v in by.values() if cand in v]
    if not d:
        return None
    rng = random.Random(1)
    boots = sorted(statistics.median(rng.choices(d, k=len(d))) for _ in range(2000))
    return {"base_median": statistics.median(b), "base_min": min(b), "base_max": max(b),
            "cand_median": statistics.median(c), "cand_min": min(c), "cand_max": max(c),
            "delta_median": statistics.median(d), "delta_q1": quantile(d, .25), "delta_q3": quantile(d, .75),
            "ci_low": boots[50], "ci_high": boots[1949], "slower": sum(1 for x in d if x > 0), "n": len(d)}


# ---- compare: the gate --------------------------------------------------------------------------------------------

def cmd_compare(a):
    variants = [("baseline", os.path.abspath(a.baseline), a.baseline_friends, {}),
                ("candidate", os.path.abspath(a.candidate), a.candidate_friends,
                 {"SZF_PROBE_DELAY_MS": str(a.inject_delay_ms)} if a.inject_delay_ms else {})]
    folder = os.path.abspath(a.folder)
    os.makedirs(a.workdir, exist_ok=True)
    rundirs = {}
    for name, app, friends, extra in variants:
        rundirs[name] = os.path.join(a.workdir, name)
        seed(rundirs[name], friends)
        stop_helpers(app, rundirs[name])
    # Warm-up: the first launch of a fresh copy pays for page-ins and signature checks of every file.
    for _ in range(a.warmup):
        for name, app, friends, extra in variants:
            launch_once(app, rundirs[name], folder, a.exit, a.timeout, extra)
    if a.samples:
        # Main-thread stacks up to the map (or until loaded), for tools/perf/launch_profile.py; slows the launches
        # it samples.
        for name, app, friends, extra in variants:
            path = os.path.join(rundirs[name], "samples.txt")
            if os.path.exists(path):
                os.unlink(path)
            extra["SZF_PROBE_SAMPLES"] = path
            if a.samples == "loaded":
                extra["SZF_PROBE_SAMPLE_UNTIL"] = "loaded"
    rows = []
    load = []
    for r in range(a.rounds):
        # ABBA: each variant runs first in half of the rounds, so load drift and order effects cancel.
        order = variants if r % 2 == 0 else variants[::-1]
        for name, app, friends, extra in order:
            load.append(os.getloadavg()[0])
            res = launch_once(app, rundirs[name], folder, a.exit, a.timeout, extra)
            res.update(variant=name, round=r)
            rows.append(res)
            if "on_screen" in res:
                print("FAILED: a window of the %s reached the screen; stopping" % name, file=sys.stderr)
                return 3
    failed_runs = [r for r in rows if r["exit"] != 0]
    # Not a matter of allowances: a process spawned on the main thread before the first window fails outright.
    spawned = [r for r in rows if r["variant"] == "candidate" and r.get("main_spawns", 0) > 0]
    gate = GATES[a.gate]
    report = {"gate": a.gate, "rounds": a.rounds, "folder": folder, "load1_median": statistics.median(load),
              "load1_range": [min(load), max(load)], "failed_runs": len(failed_runs), "metrics": {}, "regressions": []}
    print("Shenzhen Files %s gate, %d interleaved rounds, folder %s, load average %.1f (%.1f-%.1f)" % (
        a.gate, a.rounds, os.path.basename(folder), report["load1_median"], min(load), max(load)))
    print("%-22s %-28s %-28s %-34s %s" % ("metric", "baseline median [range]", "candidate median [range]",
                                         "paired delta median [IQR]", "slower"))
    for m in REPORTED:
        s = paired(rows, m, "baseline", "candidate")
        if s is None:
            continue
        report["metrics"][m] = s
        verdict = ""
        if m in gate:
            absolute, relative = gate[m]
            allowance = max(absolute, relative * s["base_median"])
            s["allowance"] = allowance
            if s["delta_median"] > allowance and s["slower"] * 4 >= s["n"] * 3:
                verdict = "REGRESSION (allowance %.1f)" % allowance
                report["regressions"].append(m)
        print("%-22s %-28s %-28s %-34s %2d/%-2d %s" % (
            m, "%.1f [%.1f-%.1f]" % (s["base_median"], s["base_min"], s["base_max"]),
            "%.1f [%.1f-%.1f]" % (s["cand_median"], s["cand_min"], s["cand_max"]),
            "%+.1f (%+.1f%%) [%+.1f, %+.1f]" % (s["delta_median"], 100 * s["delta_median"] / s["base_median"],
                                               s["delta_q1"], s["delta_q3"]),
            s["slower"], s["n"], verdict))
    report["main_spawn_runs"] = len(spawned)
    if a.report:
        with open(a.report, "w") as f:
            json.dump({"summary": report, "runs": rows}, f, indent=1)
    if spawned:
        print("FAILED: the candidate spawned a process on the main thread before its first window in %d of %d "
              "launches (%s)" % (len(spawned), a.rounds, spawned[0].get("main_spawn", "?")), file=sys.stderr)
        return 1
    if failed_runs:
        print("FAILED: %d runs did not finish (see %s/*/app.log)" % (len(failed_runs), a.workdir), file=sys.stderr)
        return 2
    if report["regressions"]:
        print("FAILED: the candidate is slower than the baseline: %s" % ", ".join(report["regressions"]),
              file=sys.stderr)
        return 1
    print("PASSED: no metric is slower than the baseline beyond its allowance")
    return 0


# ---- idle ---------------------------------------------------------------------------------------------------------

def proc_stats(pids):
    if not pids:
        return {}
    r = subprocess.run([tool("szf_proc_stats")] + [str(p) for p in pids], capture_output=True, text=True)
    return {d["pid"]: d for d in (json.loads(l) for l in r.stdout.splitlines())}


def cmd_idle(a):
    variants = []
    for spec in a.variant:
        name, rest = spec.split("=", 1)
        app, _, friends = rest.partition(",friends=")
        variants.append((name, os.path.abspath(app), friends or "default"))
    folder = os.path.abspath(a.folder)
    rows = []
    for r in range(a.rounds):
        procs = []
        for name, app, friends in variants:
            rundir = os.path.join(a.workdir, name)
            seed(rundir, friends)
            stop_helpers(app, rundir)
            out = os.path.join(rundir, "probe.jsonl")
            if os.path.exists(out):
                os.unlink(out)
            log = open(os.path.join(rundir, "app.log"), "w")
            p = subprocess.Popen([os.path.join(app, "Contents", "MacOS", "nautilus"), folder],
                                 env=environment(app, rundir, out, "none"), stdout=log, stderr=subprocess.STDOUT,
                                 cwd=rundir)
            procs.append((name, app, friends, rundir, p, out))
        deadline = time.time() + 60
        while time.time() < deadline and not all("loaded" in read_events(o) for *_, o in procs):
            time.sleep(0.2)
        time.sleep(a.settle)

        def sample():
            s = {}
            for name, app, friends, rundir, p, out in procs:
                hp = helper_pids(app, rundir)
                st = proc_stats([p.pid] + hp)
                s[name] = (st.get(p.pid, {}), {h: st.get(h, {}) for h in hp})
            return s
        t0 = time.time()
        s0 = sample()
        on_screen = False
        while time.time() - t0 < a.secs:
            time.sleep(5)
            for name, app, friends, rundir, p, out in procs:
                if proc_stats([p.pid]).get(p.pid, {}).get("onscreen", 0):
                    on_screen = True
            if on_screen:
                break
        s1 = sample()
        for name, app, friends, rundir, p, out in procs:
            p.terminate()
        for name, app, friends, rundir, p, out in procs:
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
            stop_helpers(app, rundir)
        if on_screen:
            print("FAILED: a window reached the screen; stopping", file=sys.stderr)
            return 3
        for name, app, friends, rundir, p, out in procs:
            a0, h0 = s0[name]
            a1, h1 = s1[name]
            row = {"variant": name, "friends": friends, "round": r, "secs": time.time() - t0,
                   "load1": os.getloadavg()[0], "exit": 0,
                   "app_footprint_mb": a1.get("footprint_mb"), "app_resident_mb": a1.get("resident_mb"),
                   "app_idle_cpu_ms": a1.get("cpu_ms", 0) - a0.get("cpu_ms", 0),
                   "app_idle_wakeups": (a1.get("idle_wakeups", 0) + a1.get("interrupt_wakeups", 0) -
                                        a0.get("idle_wakeups", 0) - a0.get("interrupt_wakeups", 0)),
                   "helpers": len(h1)}
            common = set(h0) & set(h1)
            if common:
                h = common.pop()
                row["helper_footprint_mb"] = h1[h].get("footprint_mb")
                row["helper_idle_cpu_ms"] = h1[h].get("cpu_ms", 0) - h0[h].get("cpu_ms", 0)
                row["helper_idle_wakeups"] = (h1[h].get("idle_wakeups", 0) + h1[h].get("interrupt_wakeups", 0) -
                                              h0[h].get("idle_wakeups", 0) - h0[h].get("interrupt_wakeups", 0))
            rows.append(row)
    names = [v[0] for v in variants]
    print("Idle %.0f s after loading and %.0f s settling, %d rounds (all variants running at once)" % (
        a.secs, a.settle, a.rounds))
    print("%-24s" % "metric" + "".join("%-30s" % n for n in names))
    for m in ("app_footprint_mb", "app_resident_mb", "app_idle_cpu_ms", "app_idle_wakeups", "helpers",
              "helper_footprint_mb", "helper_idle_cpu_ms", "helper_idle_wakeups"):
        line = "%-24s" % m
        for n in names:
            xs = sorted(r[m] for r in rows if r["variant"] == n and r.get(m) is not None)
            line += "%-30s" % ("%.1f [%.1f-%.1f] n=%d" % (statistics.median(xs), xs[0], xs[-1], len(xs)) if xs else "-")
        print(line)
    if a.report:
        with open(a.report, "w") as f:
            json.dump(rows, f, indent=1)
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("app")
    p.add_argument("dest")
    c = sub.add_parser("compare")
    c.add_argument("--baseline", required=True, help="probe copy of the baseline (usually the last release)")
    c.add_argument("--candidate", required=True, help="probe copy of the candidate")
    c.add_argument("--baseline-friends", default="default", choices=["on", "off", "default"])
    c.add_argument("--candidate-friends", default="default", choices=["on", "off", "default"])
    c.add_argument("--folder", required=True)
    c.add_argument("--rounds", type=int, default=15)
    c.add_argument("--warmup", type=int, default=1)
    c.add_argument("--exit", default="loaded")
    c.add_argument("--timeout", type=float, default=60)
    c.add_argument("--inject-delay-ms", type=int, default=0, help="self-test: slow the candidate's main thread")
    c.add_argument("--gate", default="launch", choices=sorted(GATES), help="which allowances apply (see GATES)")
    c.add_argument("--samples", nargs="?", const="map", choices=["map", "loaded"],
                   help="record main-thread stacks to <workdir>/*/samples.txt, until the map or until loaded")
    c.add_argument("--workdir", required=True)
    c.add_argument("--report")
    i = sub.add_parser("idle")
    i.add_argument("--variant", action="append", required=True, help="NAME=PROBE_COPY[,friends=on|off]")
    i.add_argument("--folder", required=True)
    i.add_argument("--rounds", type=int, default=9)
    i.add_argument("--secs", type=float, default=60)
    i.add_argument("--settle", type=float, default=5)
    i.add_argument("--workdir", required=True)
    i.add_argument("--report")
    a = ap.parse_args()
    sys.exit({"prepare": cmd_prepare, "compare": cmd_compare, "idle": cmd_idle}[a.cmd](a) or 0)


if __name__ == "__main__":
    main()
