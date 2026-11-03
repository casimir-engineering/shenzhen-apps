#!/usr/bin/env python3
"""szpdf end to end, on the real app, out of sight: every command against a copy of the built app with its own bundle
id, HOME, state folder (so its own socket) and documents, its windows far off screen (offscreen.m). It checks the
answers and, after every command, that the app never asked to come forward (the shim logs and refuses every
activation request, so a regression shows here and never takes anyone's keyboard) and that the frontmost app, read
with NSWorkspace.frontmostApplication (frontapp.m) before and after each command, never became the test copy (it may
change otherwise: someone may be using the Mac).

usage: szpdf_e2e.py <built ShenzhenPDF.app> <folder with offscreen.dylib and frontapp> [rounds]
Run through `make -f Makefile -f mac/tests/szpdf-e2e/szpdf-e2e.mk mac-szpdf-e2e`. Exits non-zero on any failure.
"""
import json, os, plistlib, shutil, signal, subprocess, sys, tempfile, time

APP_SRC, TOOLS = os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])
BUNDLE_ID = "com.intuition.shenzhenpdf.szpdf-e2e"
ROUNDS = int(sys.argv[3]) if len(sys.argv) > 3 else 1
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
FRONT_EVENTS = ("refused_activate", "makeKeyAndOrderFront", "orderFrontRegardless", "orderFront")
# A short root: the socket path must fit in 104 bytes.
ROOT = os.path.realpath(tempfile.mkdtemp(prefix="sze", dir="/tmp"))
OUT, DOCS, STATE, HOME = (os.path.join(ROOT, n) for n in ("out", "docs", "st", "home"))
results, offenders = [], []


def check(name, ok, detail=""):
    results.append(bool(ok))
    print(("PASS " if ok else "FAIL ") + name + (f"  [{str(detail)[:1200]}]" if detail and not ok else ""), flush=True)


def front():
    return subprocess.run([os.path.join(TOOLS, "frontapp")], capture_output=True, text=True).stdout.strip()


def log_events(since=0):
    path = os.path.join(ROOT, "offscreen.jsonl")
    return [json.loads(line) for line in open(path)][since:] if os.path.exists(path) else []


def coming_forward(since):
    return [e for e in log_events(since) if e["event"] in FRONT_EVENTS and
            not (e["event"] == "orderFront" and not e.get("title"))]


def test_pids():
    out = subprocess.run(["pgrep", "-f", os.path.join(ROOT, "app")], capture_output=True, text=True).stdout
    return [int(p) for p in out.split()]


def szpdf_command(*args):
    return [os.path.join(APP, "Contents/MacOS/szpdf"), *args]


ENV = dict(os.environ, SPDF_STATE_DIR=STATE)


def sz(name, *args):
    mark, before = len(log_events()), front()
    p = subprocess.run(szpdf_command(*args), capture_output=True, text=True, env=ENV, cwd=DOCS, timeout=180)
    time.sleep(0.3)
    after, events = front(), coming_forward(mark)
    with open(os.path.join(OUT, name + ".json"), "w") as f:
        f.write(p.stdout + (("\n# stderr\n" + p.stderr) if p.stderr else ""))
    # The frontmost app may change because someone is using the Mac; it must never become the test copy.
    if events or (before != after and after.startswith(BUNDLE_ID + " ")):
        offenders.append({"command": name, "before": before, "after": after, "events": events})
    try:
        return p.returncode, json.loads(p.stdout)
    except ValueError:
        return p.returncode, {"raw": p.stdout, "stderr": p.stderr}


def prepare():
    app = os.path.join(ROOT, "app", "SZPDF E2E.app")
    for folder in (os.path.dirname(app), HOME, STATE, OUT, DOCS, os.path.join(HOME, "Library")):
        os.makedirs(folder, exist_ok=True)
    subprocess.run(["rsync", "-a", "--exclude", "Contents/Helpers/Shenzhen Friends.app", APP_SRC + "/", app + "/"],
                   check=True)
    info_path = os.path.join(app, "Contents", "Info.plist")
    with open(info_path, "rb") as f:
        info = plistlib.load(f)
    info.update(CFBundleIdentifier=BUNDLE_ID, CFBundleName="SZPDF E2E",
                CFBundleDisplayName="SZPDF E2E", LSUIElement=True)
    for key in ("CFBundleURLTypes", "CFBundleDocumentTypes", "UTExportedTypeDeclarations", "UTImportedTypeDeclarations",
                "NSServices"):
        info.pop(key, None)
    info["LSEnvironment"] = {"HOME": HOME, "CFFIXED_USER_HOME": HOME, "SPDF_STATE_DIR": STATE,
                             "DYLD_INSERT_LIBRARIES": os.path.join(TOOLS, "offscreen.dylib"),
                             "OFFSCREEN_LOG": os.path.join(ROOT, "offscreen.jsonl")}
    with open(info_path, "wb") as f:
        plistlib.dump(info, f)
    with open(os.path.join(STATE, "settings.yaml"), "w") as f:
        f.write("version: 1\nshowShortcutHelpOnLaunch: false\nautoUpdateEnabled: false\n"
                "defaultReaderPromptDismissed: true\nfullDiskAccessPromptDismissed: true\npermissionsWizardShown: true\n"
                "commentAuthor: Test Owner\nfriends:\n  enabled: false\n  settingsIntroduced: 1\n")
    with open(os.path.join(STATE, "ai-settings.yaml"), "w") as f:
        f.write("enabled: false\nautomatic_analysis: false\nonboarding_revision: 2\n")
    os.makedirs(os.path.join(STATE, "Collection"), exist_ok=True)
    with open(os.path.join(STATE, "Collection", "manifest.json"), "w") as f:
        f.write('{"documents":{},"settings":{"choice":"disabled"}}')
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", app], check=True, capture_output=True)
    return app


def write_documents():
    parts = ["# Camera flex bring-up\n\nNotes from the first boards.\n\n## Power\n"]
    parts += [f"\nParagraph {i} about power: the board needs two pull-ups on SDA before power-on.\n" for i in range(1, 25)]
    parts += ["\n## Wiring\n\nUse 4.7 kΩ on SDA and SCL.\n\n### Pull-ups\n\nCheck the pull-ups twice.\n"]
    parts += [f"\nRegister {i:02X} holds setting {i}.\n" for i in range(40)]
    with open(MD, "w") as f:
        f.write("".join(parts))
    with open(os.path.join(DOCS, "bringup - comments.md"), "w") as f:
        f.write("# Comments on bringup.md\n\n---\n\n**Line 57** · ## Wiring\n\n> **Use 4.7 kΩ on SDA and SCL.**\n\n"
                "**Raph** · 2026-11-01 15:20 <!-- at: 2026-11-01T15:20:28+08:00 -->\n\nCheck the value.\n")
    code, made = sz("00-export-pdf", "export-pdf", MD, PDF)
    check("export-pdf makes the PDF used below (no app needed)", code == 0 and made.get("pageCount", 0) >= 2, made)


APP = prepare()
MD, PDF = os.path.join(DOCS, "bringup.md"), os.path.join(DOCS, "bringup.pdf")
try:
    start_front = front()
    write_documents()
    code, st = sz("00-state", "state")
    check("state with nothing running", code == 0 and st["ok"] is True and st["running"] is False, st)
    code, r = sz("00-reload", "reload", MD)
    check("reload with nothing running: not-running", code == 1 and r["error"]["code"] == "not-running", r)
    code, r = sz("00-close", "close", MD)
    check("close with nothing running: not-running", code == 1 and r["error"]["code"] == "not-running", r)
    p = subprocess.run(szpdf_command("open"), capture_output=True, text=True, env=ENV)
    check("open with no file: usage, the command's usage line, exit 2", p.returncode == 2 and
          "Run \"szpdf help open\"" in p.stderr and json.loads(p.stdout)["error"]["code"] == "usage", p.stderr)
    for n in range(ROUNDS):
        code, o = sz(f"{n}-open", "open", "bringup.md", "--wait")
        window = o.get("windowId")
        check(f"{n} open --wait: rendered, final pageCount", code == 0 and o.get("rendered") is True and
              o.get("pageCount", 0) >= 2 and o.get("fileModified"), o)
        code, o = sz(f"{n}-heading-prefix", "open", "bringup.md", "--heading", "pull")
        check(f"{n} --heading by the start of a heading", code == 0 and o.get("heading") == "Pull-ups", o)
        code, o = sz(f"{n}-heading-miss", "open", "bringup.md", "--heading", "Wirng")
        check(f"{n} a missed heading lists the closest", code == 1 and o["error"]["code"] == "heading-not-found" and
              o["closest"][0]["title"] == "Wiring", o)
        sz(f"{n}-open-pdf", "open", PDF, "--page", "2")
        code, st = sz(f"{n}-state", "state")
        docs = {d["path"]: d for d in st.get("documents", [])}
        md = docs.get(MD, {})
        check(f"{n} state: loaded, heading of a background tab, nulls not missing", md.get("loaded") is True and
              md.get("heading") and md.get("pageCount") and all(k in md for k in ("reloadedAt", "upToDate")) and
              docs.get(PDF, {}).get("selected") is True, md)
        code, a = sz(f"{n}-add-md", "comment", "add", MD, "--heading", "Power", "Which rail?")
        check(f"{n} comment add (Markdown): id, signed with the app's name", code == 0 and a["comment"]["id"][0] == "m" and
              a["comment"]["author"] == "Test Owner", a)
        cid = a.get("comment", {}).get("id", "x")
        code, a = sz(f"{n}-add-pdf", "comment", "add", PDF, "--page", "1", "Looks fine.", "--author", "Claude")
        check(f"{n} comment add (PDF): id and date", code == 0 and a["comment"]["id"][0] == "p" and a["comment"]["date"], a)
        pid_ = a.get("comment", {}).get("id", "x")
        waiter = subprocess.Popen(szpdf_command("comments", MD, "--wait-new", "--timeout", "20"), env=ENV, cwd=DOCS,
                                  stdout=subprocess.PIPE, text=True)
        time.sleep(1)
        sz(f"{n}-reply", "comment", "reply", MD, cid, "The 1.8 V one.", "--author", "Claude")
        out, _ = waiter.communicate(timeout=40)
        waited = json.loads(out)
        check(f"{n} comments --wait-new wakes on the reply", waited["ok"] and not waited["timedOut"] and
              any(c["kind"] == "reply" for c in waited["changes"]), waited)
        code, waited = sz(f"{n}-wait-timeout", "comments", MD, "--wait-new", "--timeout", "1")
        check(f"{n} --wait-new times out, exit 0", code == 0 and waited["timedOut"] is True, waited)
        sz(f"{n}-resolve", "comment", "resolve", MD, cid)
        code, c = sz(f"{n}-comments", "comments", MD, "--json")
        mine = next((c_ for c_ in c.get("comments", []) if c_["id"] == cid), {})
        check(f"{n} resolve keeps the reply's seconds", mine.get("status") == "resolved" and
              mine["replies"][-1]["date"] == json.load(open(os.path.join(OUT, f"{n}-reply.json")))["comment"]["replies"][-1]["date"],
              mine)
        code, r = sz(f"{n}-reply-pdf", "comment", "reply", PDF, pid_, "Noted.")
        sz(f"{n}-resolve-pdf", "comment", "resolve", PDF, pid_)
        code, v = sz(f"{n}-version-new", "version", "new", MD)
        number = v.get("version", {}).get("number", 1)
        with open(MD, "a") as f:
            f.write(f"\nRound {n}: a new paragraph.\n")
        code, rl = sz(f"{n}-reload", "reload", MD)
        check(f"{n} reload", code == 0 and rl.get("reloaded") is True, rl)
        sz(f"{n}-version-list", "version", "list", MD)
        sz(f"{n}-comments-v", "comments", MD, "--version", str(number), "--json")
        code, cmp_ = sz(f"{n}-compare", "version", "compare", MD, str(number), str(number + 1), "--wait")
        check(f"{n} version compare: the added block", code == 0 and cmp_["blocks"][-1]["kind"] == "added" and
              "a new paragraph" in cmp_["blocks"][-1]["after"], {k: cmp_.get(k) for k in ("ok", "blocks", "error")})
        sz(f"{n}-version-new-pdf", "version", "new", PDF)
        code, o = sz(f"{n}-open-reload", "open", MD, "--heading", "Wiring", "--reload")
        check(f"{n} open --reload", code == 0 and o.get("reloaded") and o.get("rendered"), o)
        if window:
            code, s_ = sz(f"{n}-screenshot", "screenshot", str(window), os.path.join(OUT, f"{n}-window.png"))
            check(f"{n} screenshot of the window", code == 0 and s_.get("width", 0) > 300, s_)
            code, s_ = sz(f"{n}-screenshot-page", "screenshot", str(window), os.path.join(OUT, f"{n}-page.png"),
                          "--page", "1", "--scale", "1", "--region", "0,0,300,100")
            check(f"{n} screenshot --page --region of the window's document", code == 0 and s_.get("width") == 300, s_)
        for name, args in (("headings", ("headings", MD)), ("find", ("find", MD, "4.7 kΩ")), ("check", ("check", MD)),
                           ("features", ("features",)), ("schema", ("schema",)), ("version-info", ("--version",)),
                           ("export-page", ("export-page", PDF, "1", os.path.join(OUT, "pdf-page.png")))):
            code, j = sz(f"{n}-{name}", *args)
            check(f"{n} {name}", code == 0 and j.get("ok") is True, j)
        code, cl = sz(f"{n}-close", "close", PDF)
        check(f"{n} close closes only the PDF's tab", code == 0 and cl["closed"] == [PDF], cl)
        code, cl = sz(f"{n}-close-again", "close", PDF)
        check(f"{n} closing it again: not-open", code == 1 and cl["error"]["code"] == "not-open", cl)
    # A reader that runs but does not answer (here its socket is moved aside for a moment, as when it is busy or still
    # starting) is waited for, and never handed the document through Launch Services, whose "open documents" event
    # makes AppKit ask to activate the app.
    pids, mark = test_pids(), len(log_events())
    agent = os.path.join(STATE, "Agent")
    sockets = [n for n in os.listdir(agent) if n.endswith(".sock")]
    for name in sockets:
        os.rename(os.path.join(agent, name), os.path.join(agent, name + ".aside"))
    code, busy = sz("busy-open", "open", MD, "--timeout", "4")
    for name in sockets:
        os.rename(os.path.join(agent, name + ".aside"), os.path.join(agent, name))
    check("a reader that does not answer is waited for, not started again or sent the document by Launch Services",
          code == 1 and busy["error"]["code"] == "not-responding" and sorted(test_pids()) == sorted(pids) and
          not [e for e in log_events(mark) if e["event"] == "inserted"], busy)
    code, again = sz("after-busy", "open", MD, "--wait")
    check("and answers again once it can", code == 0 and again.get("opened"), again)
    with open(os.path.join(OUT, "offenders.json"), "w") as f:
        json.dump(offenders, f, indent=1)
    check("no command asked ShenzhenPDF to come forward, and the frontmost app never changed", not offenders,
          [(o["command"], [(e["event"], e.get("sel", e.get("title"))) for e in o["events"]]) for o in offenders])
    check("the test copy never became the frontmost app", not front().startswith(BUNDLE_ID + " "), front())
finally:
    for pid in test_pids():
        os.kill(pid, signal.SIGKILL)
    subprocess.run([LSREGISTER, "-u", APP], capture_output=True)
    print(f"{sum(results)}/{len(results)} passed; answers and pictures in {OUT}", flush=True)
    if all(results):
        shutil.rmtree(ROOT, ignore_errors=True)
sys.exit(0 if all(results) else 1)
