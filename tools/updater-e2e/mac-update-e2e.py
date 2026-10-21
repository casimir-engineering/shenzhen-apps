#!/usr/bin/env python3
"""The released ShenzhenPDF / Shenzhen Files build updates itself to the new release, served by a local copy of
GitHub, hidden. Its own updater code runs unchanged (libszut.dylib only replaces the network, hides the UI and keeps
it inside the work directory); the copy is re-signed ad hoc so the library can be inserted, which changes no code.

usage: mac-update-e2e.py --kind pdf|files --old-app APP --new-dmg DMG --notes NOTES --tag TAG --work DIR
                         --shape RELEASE_JSON

Stages, each recorded in DIR/result.json:
  1 install   the old app at DIR/Applications, ad hoc, LSUIElement (no Dock icon)
  2 update    launch it with a fresh profile: its daily check reads releases/latest, offers TAG, downloads the DMG
              through GitHub's redirect, verifies, extracts, quits, and its --post-update helper swaps the bundle
  3 verify    the bundle at the old path is the DMG's app (CDHash), signed, notarized, Gatekeeper accepts it
  4 handshake the installed new app, run hidden (ad hoc, own bundle id), confirms the tag: update_ok, .old removed

However the run ends (a failed check, an error, SIGTERM or SIGINT), whatever still runs from DIR is ended by its exact
executable path (sweep.py), including a copy the helper reopened with launchd as its parent, and the run fails.
"""
import argparse, hashlib, json, os, plistlib, shutil, signal, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nodialogs  # LaunchServices registrations and the Gatekeeper prompt check; see nodialogs.py

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = None  # set once this run's work directory exists
STARTED = time.time()  # the run's window in the unified log
KINDS = {
    "pdf": dict(app="ShenzhenPDF.app", repo="casimir-engineering/shenzhen-pdf", asset="ShenzhenPDF-mac-arm64.dmg",
                exe="Contents/MacOS/ShenzhenPDF", support="ShenzhenPDF", nested=[]),
    "files": dict(app="Shenzhen Files.app", repo="casimir-engineering/shenzhen-files",
                  asset="ShenzhenFiles-mac-arm64.dmg", exe="Contents/MacOS/nautilus-launcher",
                  support="Shenzhen Files", nested=["Contents/MacOS/nautilus"]),
}

def run(*cmd, check=True, **kw):
    return subprocess.run(cmd, check=check, capture_output=True, text=True, **kw)

def plist(app):
    with open(os.path.join(app, "Contents/Info.plist"), "rb") as f:
        return plistlib.load(f)

def cdhash(path):
    out = run("codesign", "-dvvv", path, check=False).stderr
    return next((l.split("=", 1)[1] for l in out.splitlines() if l.startswith("CDHash=")), None)

def adhoc(app, nested, extra_plist):
    info_path = os.path.join(app, "Contents/Info.plist")
    with open(info_path, "rb") as f:
        info = plistlib.load(f)
    info.update(extra_plist.get("set", {}))
    for key in extra_plist.get("delete", []):
        info.pop(key, None)
    with open(info_path, "wb") as f:
        plistlib.dump(info, f)
    for n in nested:
        run("codesign", "--force", "--sign", "-", os.path.join(app, n))
    run("codesign", "--force", "--sign", "-", app)

def our_pids(work):
    out = run("ps", "-axo", "pid=,command=").stdout
    pids = []
    for line in out.splitlines():
        pid, _, cmd = line.strip().partition(" ")
        if work in cmd and "mac-update-e2e.py" not in cmd and int(pid) != os.getpid():
            pids.append(int(pid))
    return pids

def stop(work):
    """Ends only the processes this test started: their command lines name the work directory."""
    for pid in our_pids(work):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    time.sleep(2)
    for pid in our_pids(work):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

def events(log):
    if not os.path.exists(log):
        return []
    out = []
    for line in open(log):
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out

def main():
    ap = argparse.ArgumentParser()
    for a in ("kind", "old-app", "new-dmg", "notes", "tag", "work", "shape"):
        ap.add_argument("--" + a, required=True)
    args = ap.parse_args()
    k = KINDS[args.kind]
    work = os.path.realpath(args.work)
    os.makedirs(work, exist_ok=False)
    global WORK
    WORK = work
    nodialogs.forget_stale()  # copies of earlier runs that LaunchServices may still offer for the same identifier
    apps, home, mock = (os.path.join(work, d) for d in ("Applications", "home", "mock"))
    for d in (apps, home, mock):
        os.makedirs(d)
    log = os.path.join(work, "events.jsonl")
    LIB = os.path.join(work, "libszut.dylib")
    run("clang", "-arch", "arm64", "-mmacosx-version-min=12.0", "-dynamiclib", "-fobjc-arc", "-framework", "AppKit",
        "-framework", "Security", "-framework", "CoreServices", "-framework", "ApplicationServices",
        os.path.join(HERE, "szut.m"), "-o", LIB)
    result = {"kind": args.kind, "tag": args.tag, "stages": {}}

    def save():
        with open(os.path.join(work, "result.json"), "w") as f:
            json.dump(result, f, indent=2)

    def check(stage, name, ok, detail=None):
        result["stages"].setdefault(stage, []).append({"check": name, "ok": bool(ok), "detail": detail})
        save()
        print(("ok   " if ok else "FAIL ") + stage + ": " + name + ("" if detail is None else f" ({detail})"),
              flush=True)
        return ok

    # 1 install
    app = os.path.join(apps, k["app"])
    run("ditto", args.old_app, app)
    run("xattr", "-cr", app)
    old_info = plist(app)
    old_version = f'{old_info["CFBundleShortVersionString"]}-{old_info.get("SZFReleaseTag", old_info["CFBundleVersion"])}'
    adhoc(app, k["nested"], {"set": {"LSUIElement": True}})
    check("install", "old app copied", True, f'{old_info["CFBundleShortVersionString"]} ({old_info["CFBundleVersion"]})')

    # The mock: releases/latest as GitHub answers it, rewritten for the new release; the asset through its redirect.
    dmg = os.path.realpath(args.new_dmg)
    data = open(dmg, "rb").read()
    digest = hashlib.sha256(data).hexdigest()
    shutil.copy(dmg, os.path.join(mock, "asset.bin"))
    release = json.load(open(args.shape))
    owner_repo = k["repo"]
    download = f"https://github.com/{owner_repo}/releases/download/{args.tag}/{k['asset']}"
    redirect = ("https://release-assets.githubusercontent.com/github-production-release-asset/1/"
                "00000000-0000-0000-0000-000000000000?sp=r&sv=2018-11-09&sr=b")
    asset = dict(release["assets"][0])
    asset.update(name=k["asset"], size=len(data), digest="sha256:" + digest, browser_download_url=download,
                 id=990001, url=f"https://api.github.com/repos/{owner_repo}/releases/assets/990001",
                 state="uploaded", download_count=0)
    release.update(tag_name=args.tag, name=args.tag, draft=False, prerelease=False, body=open(args.notes).read(),
                   assets=[asset], html_url=f"https://github.com/{owner_repo}/releases/tag/{args.tag}")
    with open(os.path.join(mock, "latest.json"), "w") as f:
        json.dump(release, f)
    routes = {
        f"GET https://api.github.com/repos/{owner_repo}/releases/latest":
            {"status": 200, "file": "latest.json",
             "headers": {"Content-Type": "application/json; charset=utf-8", "ETag": '"szut-1"'}},
        f"GET {download}": {"status": 302, "location": redirect},
        f"GET {redirect}": {"status": 200, "file": "asset.bin",
                            "headers": {"Content-Type": "application/octet-stream"}},
    }
    routes_path = os.path.join(mock, "routes.json")
    with open(routes_path, "w") as f:
        json.dump(routes, f, indent=1)

    env = {
        "HOME": home, "CFFIXED_USER_HOME": home, "USER": os.environ.get("USER", ""),
        "LOGNAME": os.environ.get("USER", ""), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "DYLD_INSERT_LIBRARIES": LIB, "SZUT_ROOT": work, "SZUT_LOG": log, "SZUT_ROUTES": routes_path,
        "SPDF_STATE_DIR": os.path.join(home, "Library/Application Support", k["support"]), "SPDF_NO_ACTIVATE": "1",
        "SZFRIENDS_STATE_DIR": os.path.join(work, "friends"),
        "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + os.path.join(work, "no-bus"),
        "XDG_CONFIG_HOME": os.path.join(work, "xdg/config"), "XDG_DATA_HOME": os.path.join(work, "xdg/data"),
        "XDG_CACHE_HOME": os.path.join(work, "xdg/cache"), "XDG_STATE_HOME": os.path.join(work, "xdg/state"),
        "GSETTINGS_BACKEND": "keyfile",
    }
    support = os.path.join(home, "Library/Application Support", k["support"])

    def update_json():
        try:
            return json.load(open(os.path.join(support, "update.json")))
        except (OSError, ValueError):
            return {}

    # 2 update
    out = open(os.path.join(work, "app-old.log"), "w")
    started = time.time()
    proc = subprocess.Popen([os.path.join(app, k["exe"])], env=env, stdout=out, stderr=subprocess.STDOUT,
                            cwd=work, start_new_session=True)
    swapped = False
    deadline = started + 300
    while time.time() < deadline:
        time.sleep(1)
        try:
            v = plist(app)
        except (OSError, ValueError):
            continue
        # The build number too: a release of the same day changes only CFBundleVersion (26.10.20-1 to 26.10.20-2).
        if (v["CFBundleShortVersionString"], v["CFBundleVersion"]) != \
                (old_info["CFBundleShortVersionString"], old_info["CFBundleVersion"]) and \
                os.path.exists(app + ".old") and not our_pids(work):
            swapped = True
            break
        if proc.poll() is not None and not our_pids(work) and time.time() - started > 60 and \
                not os.path.exists(app + ".old"):
            break
    if not swapped:
        stop(work)
    nodialogs.forget([work])  # the old app and the helper's reopened copy have stopped
    ev = events(log)
    keys = [e.get("key") for e in ev if e.get("event") == "request"]
    check("update", "the old build asked GitHub for its latest release",
          f"GET https://api.github.com/repos/{owner_repo}/releases/latest" in keys, keys[:6])
    alerts = [e for e in ev if e.get("event") == "alert"]
    check("update", "it offered the new version", any(args.tag in (a.get("informative", "") + a.get("message", ""))
                                                       for a in alerts),
          [(a.get("message"), a.get("informative", "")[:300], a.get("buttons")) for a in alerts])
    check("update", "it downloaded the asset through GitHub's redirect",
          f"GET {download}" in keys and f"GET {redirect}" in keys)
    dropped = [e.get("name") for e in ev if e.get("event") == "distributed_notification_dropped"]
    if dropped:
        check("update", "app-wide notifications stayed in the test (not delivered)", True, dropped)
    helpers = [e for e in ev if e.get("event") == "inserted" and "--post-update" in e.get("args", [])]
    check("update", "its --post-update helper ran", bool(helpers), [h.get("args") for h in helpers])
    relaunch = [e for e in ev if e.get("event") == "relaunch_requested"]
    check("update", "the helper reopened the app at its own path",
          any(os.path.realpath(r.get("url", "")) == os.path.realpath(app) for r in relaunch),
          [r.get("url") for r in relaunch])
    check("update", "the bundle was replaced and the previous one kept as .old", swapped,
          f"{time.time() - started:.0f} s")
    refused_term = [e for e in ev if e.get("event") == "refused_terminate"]
    check("update", "nothing outside the test was asked to quit", not refused_term, refused_term or None)
    failures = [e for e in ev if e.get("event") == "alert" and
                any(w in e.get("message", "") + e.get("informative", "") for w in ("could not", "not installed",
                                                                                     "corrupted", "did not"))]
    check("update", "no update error was shown", not failures, failures or None)
    uj = update_json()
    check("update", "the update store waits for the new version to confirm it",
          uj.get("pendingTag") == args.tag or uj.get("update_ok") == args.tag, uj)
    if not swapped:
        result["success"] = False
        save()
        return 1

    # 3 verify: the installed bundle is the DMG's app, intact and notarized
    mnt = os.path.join(work, "dmg")
    os.makedirs(mnt)
    run("hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mnt, dmg)
    try:
        dmg_app = os.path.join(mnt, k["app"])
        check("verify", "same code as the release DMG's app (CDHash)", cdhash(app) == cdhash(dmg_app),
              (cdhash(app), cdhash(dmg_app)))
        diff = run("diff", "-rq", app, dmg_app, check=False)
        check("verify", "same files as the release DMG's app", diff.returncode == 0, diff.stdout[:500] or None)
    finally:
        run("hdiutil", "detach", mnt, check=False)
    new_info = plist(app)
    check("verify", "the installed version is the release", f'{new_info["CFBundleShortVersionString"]}-'
          f'{new_info.get("SZFReleaseTag", "").rsplit("-", 1)[-1] or new_info["CFBundleVersion"]}' == args.tag,
          (new_info["CFBundleShortVersionString"], new_info["CFBundleVersion"], new_info.get("SZFReleaseTag")))
    v = run("codesign", "--verify", "--deep", "--strict", app, check=False)
    check("verify", "codesign --verify --deep --strict", v.returncode == 0, v.stderr.strip()[:300] or None)
    g = run("spctl", "-a", "-t", "exec", "-vv", app, check=False)
    check("verify", "Gatekeeper accepts it (notarized Developer ID)",
          g.returncode == 0 and "Notarized Developer ID" in g.stderr, g.stderr.strip())
    old_app = app + ".old"
    check("verify", "the previous version waits as .old",
          (plist(old_app)["CFBundleShortVersionString"], plist(old_app)["CFBundleVersion"]) ==
          (old_info["CFBundleShortVersionString"], old_info["CFBundleVersion"]))

    # 4 handshake: the new app's first launch confirms the tag. Run hidden, as its own bundle id, opening nothing.
    # ShenzhenPDF's handshake runs under any bundle id; Shenzhen Files' only as com.intuition.shenzhenfiles, so it keeps
    # its own (the copy is unregistered from LaunchServices at the end either way).
    handshake_set = {"LSUIElement": True}
    if args.kind == "pdf":
        handshake_set["CFBundleIdentifier"] = "com.intuition.updatetest.pdf"
    adhoc(app, k["nested"], {"set": handshake_set,
                             "delete": ["CFBundleDocumentTypes", "CFBundleURLTypes", "NSServices",
                                        "UTExportedTypeDeclarations", "UTImportedTypeDeclarations"]})
    out = open(os.path.join(work, "app-new.log"), "w")
    before = len(events(log))
    proc = subprocess.Popen([os.path.join(app, k["exe"])], env=env, stdout=out, stderr=subprocess.STDOUT, cwd=work,
                            start_new_session=True)
    confirmed = False
    deadline = time.time() + 120
    while time.time() < deadline:
        time.sleep(1)
        uj = update_json()
        if uj.get("update_ok") == args.tag and not os.path.exists(old_app):
            confirmed = True
            break
    time.sleep(2)
    stop(work)
    ev = events(log)[before:]
    alerts = [e for e in ev if e.get("event") == "alert"]
    check("handshake", "the new version confirmed the update (update_ok) and removed .old", confirmed, update_json())
    check("handshake", "it said so", any(args.tag in a.get("message", "") for a in alerts),
          [a.get("message") for a in alerts])
    helper_refusals = [e for e in events(log) if e.get("event") == "refused_friends_helper"]
    if helper_refusals:
        check("handshake", "the new app's Friends helper was kept from starting in the test", True,
              len(helper_refusals))
    unexpected = [e.get("key") for e in events(log) if e.get("event") == "request" and not e.get("routed")]
    check("all", "no request left the test", True, unexpected or None)
    # LaunchServices learnt these copies when they ran. They keep the release's bundle identifier (the handshake of
    # Shenzhen Files needs it), so it could offer one of them, unnotarized or modified, for anything that opens the
    # app, and Gatekeeper would then show its "damaged" dialog on the person's screen: forget them.
    nodialogs.forget([work])
    result["success"] = all(c["ok"] for s in result["stages"].values() for c in s)
    save()
    return 0 if result["success"] else 1

def add_failure(work, name, ok, detail):
    """Records one more check in result.json after main() returned (or failed); a failing one fails the run."""
    path = os.path.join(work, "result.json")
    try:
        with open(path) as f:
            result = json.load(f)
    except (OSError, ValueError):
        result = {"stages": {}}
    result["stages"].setdefault("cleanup", []).append({"check": name, "ok": bool(ok), "detail": detail})
    if not ok:
        result["success"] = False
    with open(path, "w") as f:
        json.dump(result, f, indent=2)
    print(("ok   " if ok else "FAIL ") + f"all: {name}" + ("" if ok else f" ({detail})"), flush=True)
    return ok


def end_leftovers(work):
    """Ends what still runs from the work directory, by exact executable path; True when something was."""
    p = subprocess.run([sys.executable, "-I", os.path.join(HERE, "sweep.py"), "--grace=15", "--kill", work],
                       capture_output=True, text=True)
    if p.returncode == 0:
        return False
    add_failure(work, "nothing this run started is still running", False, (p.stdout + p.stderr).strip())
    return True


def no_dialogs(work):
    """However the run ended: its test copies keep the release's bundle identifier, so none may stay registered with
    LaunchServices (it could offer one for opening the app, and Gatekeeper would show its "damaged" dialog); and the
    unified log must show no Gatekeeper prompt during the run. True when both hold."""
    left = nodialogs.forget([work])
    ok = add_failure(work, "no test copy stays registered with LaunchServices", not left, left or None)
    prompts = nodialogs.prompts(STARTED, time.time())
    return add_failure(work, "the unified log shows no Gatekeeper prompt (syspolicyd, CoreServicesUIAgent) during the "
                       "run", not prompts, prompts[:5] or None) and ok


if __name__ == "__main__":
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda signum, _frame: sys.exit(128 + signum))
    code = 1
    try:
        code = main()
    finally:
        if WORK and end_leftovers(WORK):
            code = 1
        if WORK and not no_dialogs(WORK):
            code = 1
    sys.exit(code)
