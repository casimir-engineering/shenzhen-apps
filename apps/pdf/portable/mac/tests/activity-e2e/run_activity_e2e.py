#!/usr/bin/env python3
"""Last opened and last viewed, end to end through the real app, off screen, with a model stub.

usage: run_activity_e2e.py --app <ShenzhenPDF.app> --work <new folder>

A copy of the app (its own bundle identifier, LSUIElement, ad hoc signed so the harness can be inserted) runs from
--work with test profiles of its own (SPDF_STATE_DIR and a home): never the owner's state or Keychain.
tools/updater-e2e/szut.m keeps every window off screen and sends the model's requests to activity_stub.py on
127.0.0.1; driver.m opens and switches documents as the menus and tab strip do, says whether the app is frontmost,
types into the chat and saves pictures. Three launches:

  record    a new profile: five documents opened, two viewed (in front over 2 s), one flicked past, two opened while
            another app was in front; Command-Q.
  relaunch  the same profile: the tabs come back, the one in front is viewed again, the others stay unseen; the
            assistant is asked when each was last viewed.
  aged      a profile with 100 tabs whose dates the test aged (real and estimated); the owner's request "close any
            document I have not viewed since a week", Undo, the request again and File > Reopen Last Closed.

Checks on activity.yaml, the tool results the model saw and the tabs left open. Exit status 0 when all pass.
"""
import argparse
import datetime
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../../../../.."))
SZUT = os.path.join(REPO, "tools/updater-e2e/szut.m")
NODIALOGS = os.path.join(REPO, "tools/updater-e2e/nodialogs.py")
DAY = 86400.0

QUESTIONS = {
    "when": "When did I last view each open document?",
    "close": "Now close any document I have not viewed since a week",
    "undo": "Undo that.",
}

SETTINGS = """schema_version: 1
model: e2e/stub-model
language: en
enabled: true
connection_configured: true
automatic_analysis: false
show_settings_on_launch: false
onboarding_revision: 2
onboarding_step: 0
model_context_tokens: 200000
web_search_enabled: false
python_enabled: false
subagents_enabled: false
"""
READER_SETTINGS = ("version: 1\nshowShortcutHelpOnLaunch: false\nautoUpdateEnabled: false\n"
                   "defaultReaderPromptDismissed: true\nfullDiskAccessPromptDismissed: true\npermissionsWizardShown: true\n"
                   "friends:\n  enabled: false\n  settingsIntroduced: 1\n")


def pdf(title):
    stream = f"BT /F1 28 Tf 40 700 Td ({title}) Tj ET".encode()
    objects = [b"<</Type/Catalog/Pages 2 0 R>>", b"<</Type/Pages/Kids[3 0 R]/Count 1>>",
               b"<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>",
               b"<</Length %d>>stream\n" % len(stream) + stream + b"\nendstream",
               b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>"]
    out, offsets = bytearray(b"%PDF-1.4\n"), []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    out += b"".join(b"%010d 00000 n \n" % o for o in offsets)
    out += b"trailer<</Size %d/Root 1 0 R>>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    return bytes(out)


def write_documents(folder, names):
    os.makedirs(folder, exist_ok=True)
    paths = []
    for name in names:
        path = os.path.join(folder, name + ".pdf")
        with open(path, "wb") as f:
            f.write(pdf(name))
        paths.append(path)
    return paths


def q(text):
    return json.dumps(text)


def write_session(state, paths, groups, selected):
    lines = ["version: 2", "windows:", f"  - focusedAt: {time.time() - 978307200 - 60:.0f}",
             "    frame:", "      height: 900", "      width: 1400", "      x: 0", "      y: 0",
             '    id: "E2E-AGED-WINDOW"', f"    selectedTab: {selected}", "    tabs:"]
    for index, path in enumerate(paths):
        gid, name, color = groups[index]
        lines += [f"      - path: {q(path)}", f"        title: {q(os.path.splitext(os.path.basename(path))[0])}",
                  "        page: 1", "        lastViewedAt: 0", "        group:", "          collapsed: false",
                  f"          color: {q(color)}", "          explicitGeneral: false", "          hidden: false",
                  f"          id: {q(gid)}", f"          name: {q(name)}"]
    with open(os.path.join(state, "session.yaml"), "w") as f:
        f.write("\n".join(lines) + "\n")


def write_activity(state, documents, recorded_since):
    lines = ["version: 1", f"backfilledAt: {recorded_since:.0f}", f"recordedSince: {recorded_since:.0f}", "documents:"]
    for path, entry in documents.items():
        lines.append(f"  {q(standard(path))}:")
        for key in ("opened", "viewed"):
            if key in entry:
                lines.append(f"    {key}: {entry[key]:.0f}")
        if entry.get("estimate"):
            lines.append("    estimate:")
            for key, value in entry["estimate"].items():
                lines.append(f"      {key}: {value:.0f}")
    with open(os.path.join(state, "activity.yaml"), "w") as f:
        f.write("\n".join(lines) + "\n")


def standard(path):
    """The app keys dates by -[NSString stringByStandardizingPath], which drops /private from /private/tmp."""
    for prefix in ("/private/tmp/", "/private/var/", "/private/etc/"):
        if path.startswith(prefix):
            return path[len("/private"):]
    return path


def read_activity(state):
    """activity.yaml as the app writes it, keyed by the test's own paths: block mappings, quoted keys, numbers."""
    root, stack = {}, [(-1, None)]
    path = os.path.join(state, "activity.yaml")
    if not os.path.exists(path):
        return {}
    stack = [(-1, root)]
    for line in open(path):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        match = re.match(r'\s*("(?:[^"\\]|\\.)*"|[^:]+):\s*(.*)$', line.rstrip("\n"))
        key, value = match.group(1), match.group(2)
        key = json.loads(key) if key.startswith('"') else key
        while stack[-1][0] >= indent:
            stack.pop()
        parent = stack[-1][1]
        if value == "":
            parent[key] = {}
            stack.append((indent, parent[key]))
        else:
            parent[key] = json.loads(value) if value[0] in '"-0123456789tfn' else value
    documents = root.get("documents", {})
    root["documents"] = {key if key.startswith("/private/") else "/private" + key if key.startswith(("/tmp/", "/var/"))
                         else key: value for key, value in documents.items()}
    return root


def check(results, name, condition, detail=""):
    results.append({"check": name, "pass": bool(condition), "detail": detail})
    print(("PASS " if condition else "FAIL ") + name + (f" ({detail})" if detail and not condition else ""), flush=True)


def build(source, output, *frameworks):
    command = ["clang", "-dynamiclib", "-fobjc-arc", "-arch", "arm64", source, "-o", output]
    for framework in frameworks:
        command += ["-framework", framework]
    subprocess.run(command, check=True)


def prepare_app(app, work):
    copy = os.path.join(work, "app", "ShenzhenPDF E2E.app")
    os.makedirs(os.path.dirname(copy))
    subprocess.run(["ditto", app, copy], check=True)
    info = os.path.join(copy, "Contents", "Info.plist")
    with open(info, "rb") as f:
        plist = plistlib.load(f)
    plist["CFBundleIdentifier"] = "com.intuition.shenzhenpdf.activity-e2e"
    plist["LSUIElement"] = True
    with open(info, "wb") as f:
        plistlib.dump(plist, f)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", copy], check=True, capture_output=True)
    return copy


def new_profile(work, name):
    state, home = os.path.join(work, name, "state"), os.path.join(work, name, "home")
    os.makedirs(state)
    os.makedirs(home)
    with open(os.path.join(state, "ai-settings.yaml"), "w") as f:
        f.write(SETTINGS)
    with open(os.path.join(state, "settings.yaml"), "w") as f:
        f.write(READER_SETTINGS)
    return state, home


def run_phase(work, app, state, home, port, phase, documents, out):
    plan = os.path.join(work, f"plan-{phase}.json")
    with open(plan, "w") as f:
        json.dump({"phase": phase, "documents": documents, "questions": QUESTIONS}, f)
    env = {"PATH": "/usr/bin:/bin", "HOME": home, "CFFIXED_USER_HOME": home,
           "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "SPDF_STATE_DIR": state, "SZFRIENDS_STATE_DIR": os.path.join(state, "friends"),
           "SPDF_NO_ACTIVATE": "1", "SZUT_ROOT": work, "SZUT_LOG": os.path.join(work, "szut.jsonl"),
           "SZUT_ROUTES": os.path.join(work, "routes.json"),
           "SZUT_FORWARD": f"https://openrouter.ai/api/=http://127.0.0.1:{port}/api/",
           "DYLD_INSERT_LIBRARIES": os.path.join(work, "szut.dylib") + ":" + os.path.join(work, "driver.dylib"),
           "SPDF_E2E_PLAN": plan, "SPDF_E2E_OUT": out}
    executable = os.path.join(app, "Contents", "MacOS", "ShenzhenPDF")
    with open(os.path.join(work, f"app-{phase}.log"), "w") as log:
        process = subprocess.Popen([executable], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            process.wait(timeout=600)
        except subprocess.TimeoutExpired:
            os.kill(process.pid, signal.SIGKILL)
            process.wait()
            print(f"FAIL the {phase} launch did not finish")
    result = os.path.join(out, f"{phase}.json")
    return json.load(open(result)) if os.path.exists(result) else {}


def near(value, low, high):
    return value is not None and low - 1.0 <= value <= high + 1.0


def verify_record(checks, state, documents, result):
    a, b, c, d, e = documents
    ev = result.get("events", {})
    activity = read_activity(state).get("documents", {})
    t = {name: ev.get(f"open {os.path.basename(p)}") for name, p in zip("ABCDE", documents)}
    viewed = {name: activity.get(p, {}).get("viewed") for name, p in zip("ABCDE", documents)}
    opened = {name: activity.get(p, {}).get("opened") for name, p in zip("ABCDE", documents)}
    check(checks, "every opened document has its last opened time",
          all(near(opened[n], t[n], t[n] + 1) for n in "ABCDE"), json.dumps({"opened": opened, "t": t}))
    check(checks, "A, in front for 3 s, was viewed 2 s after it came forward or later",
          near(viewed["A"], t["A"] + 2, t["B"]), f"{viewed['A']} vs open {t['A']}")
    check(checks, "B, in front under a second, was not viewed", viewed["B"] is None, str(viewed["B"]))
    check(checks, "D and E, opened while another app was in front, were not viewed",
          viewed["D"] is None and viewed["E"] is None, f"{viewed['D']} {viewed['E']}")
    check(checks, "C was viewed again when the app came back to the front, until the quit",
          near(viewed["C"], ev.get("select C.pdf", 0) + 2, ev.get("quit", 0) + 1), f"{viewed['C']} {ev}")
    check(checks, "the dates are not estimates", not any(activity.get(p, {}).get("estimate") for p in documents),
          json.dumps(activity)[:400])


def verify_relaunch(checks, state, documents, before, result):
    a, b, c, d, e = documents
    ev = result.get("events", {})
    activity = read_activity(state).get("documents", {})
    check(checks, "the five tabs come back with C in front",
          sorted(result.get("restored", [])) == sorted(documents) and result.get("restoredSelected") == c,
          json.dumps(result.get("restored")))
    check(checks, "C, in front after the relaunch, was viewed again and opened (loaded) again",
          near(activity[c].get("viewed"), ev.get("front", 0) + 2, ev.get("quit", 0) + 1)
          and activity[c].get("opened", 0) > before[c]["opened"], json.dumps(activity[c]))
    unseen = [p for p in (a, b, d, e) if activity.get(p) != before.get(p)]
    check(checks, "restored tabs nobody looked at keep their dates (not opened, not viewed)", not unseen,
          json.dumps({p: (before.get(p), activity.get(p)) for p in unseen})[:500])
    tools = result.get("when", {}).get("tools", [])
    listed = json.loads(tools[-1]) if tools else {}
    rows = {t["title"]: t for t in listed.get("tabs", [])}
    zone = datetime.datetime.now().astimezone().tzinfo

    def iso(value):
        return datetime.datetime.fromtimestamp(value, zone).isoformat(timespec="seconds") if value else None
    expected = {os.path.splitext(os.path.basename(p))[0]: (iso(activity[p].get("viewed")), iso(activity[p].get("opened")))
                for p in documents}
    got = {title: (row.get("last_viewed"), row.get("last_opened")) for title, row in rows.items()}
    # C is still in front while the assistant answers: its view goes on until the quit.
    shown = got.pop("C", (None, None))
    want = expected.pop("C")
    check(checks, "list_workspace gives the assistant each document's last viewed and last opened, local time, ISO",
          got == expected and shown[1] == want[1] and iso(ev.get("front", 0) + 1) <= (shown[0] or "") <= want[0]
          and listed.get("now", "").endswith(iso(time.time())[-6:]), json.dumps({"got": got, "want": expected,
                                                                                  "C": [shown, want]}))
    answer = result.get("when", {}).get("answer", "")
    check(checks, "the assistant answers from them", "| A |" in answer and "not viewed" in answer, answer[:300])


def aged_profile(work, now):
    state, home = new_profile(work, "aged")
    names = [f"Spec {i:03d}" for i in range(100)]
    paths = write_documents(os.path.join(work, "aged", "documents"), names)
    groups = [(f"G{i // 25}", ["Carrier PCB", "Remote Parts", "Audio Board", "Camera Module"][i // 25],
               ["Blue", "Teal", "Coral", "Plum"][i // 25]) for i in range(100)]
    write_session(state, paths, groups, selected=0)
    since = now - 2 * DAY  # this build has recorded for two days; older dates are estimates
    documents, expected_closed, unrecorded = {}, [], []
    for i, path in enumerate(paths):
        entry = {"opened": now - 10 * DAY}
        if i < 25:      # viewed (really) in the last two days
            entry = {"opened": now - 1.9 * DAY, "viewed": now - (0.2 + i * 0.06) * DAY}
        elif i < 45:    # last viewed 8 to 40 days ago, from older records
            entry = {"estimate": {"opened": now - 41 * DAY, "viewed": now - (8 + (i - 25) * 1.6) * DAY}}
            expected_closed.append(path)
        elif i < 65:    # never selected since tab activation times were recorded, 19 days ago
            entry = {"estimate": {"opened": now - 30 * DAY, "notViewedSince": now - 19 * DAY}}
            expected_closed.append(path)
        elif i < 75:    # selected three days ago (estimate): viewed this week
            entry = {"estimate": {"opened": now - 3 * DAY, "viewed": now - 3 * DAY}}
        elif i < 85:    # an old estimate, but a real view yesterday
            entry = {"viewed": now - DAY, "estimate": {"viewed": now - 20 * DAY}}
        elif i < 95:    # no record at all
            entry = None
            unrecorded.append(path)
        else:           # not viewed for three days, nothing known before: no record tells
            entry = {"estimate": {"notViewedSince": now - 3 * DAY}}
            unrecorded.append(path)
        if entry:
            documents[path] = entry
    write_activity(state, documents, since)
    return state, home, paths, expected_closed, unrecorded


def verify_aged(checks, paths, expected_closed, unrecorded, result):
    close = result.get("close", {})
    calls = [c.get("name") for c in close.get("calls", [])]
    check(checks, "the request is answered with list_workspace, list_workspace (notViewedSince) and one close_document",
          calls == ["list_workspace", "list_workspace", "close_document"], str(calls))
    left = close.get("tabs", [])
    check(checks, "exactly the 40 documents not viewed since a week are closed",
          sorted(set(paths) - set(left)) == sorted(expected_closed) and len(left) == 60,
          f"closed {sorted(set(paths) - set(left))[:5]}... left {len(left)}")
    tools = close.get("tools", [])
    listed = json.loads(tools[1]) if len(tools) > 1 else {}
    check(checks, "the 15 documents no record tells about are named, not closed",
          listed.get("notViewedSince", {}).get("noViewRecord", {}).get("count") == len(unrecorded)
          and all(p in left for p in unrecorded), json.dumps(listed.get("notViewedSince"))[:300])
    check(checks, "the assistant says what it closed and what it left",
          "Closed 40 documents" in close.get("answer", "") and "15 documents have no view record" in close.get("answer", ""),
          close.get("answer", "")[:300])
    undo = result.get("undo", {})
    check(checks, "one Undo reopens all 40 in their places", undo.get("tabs") == paths,
          f"{len(undo.get('tabs', []))} tabs")
    again = result.get("closeAgain", {}).get("tabs", [])
    reopened = result.get("reopened", {}).get("tabs", [])
    back = sorted(set(reopened) - set(again))
    check(checks, "File > Reopen Last Closed reopens the last one closed",
          len(again) == 60 and back == [expected_closed[0]], f"{back}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--work", required=True)
    args = parser.parse_args()
    work = os.path.abspath(args.work)
    os.makedirs(work)
    out = os.path.join(work, "out")
    os.makedirs(out)
    app = prepare_app(os.path.abspath(args.app), work)
    build(SZUT, os.path.join(work, "szut.dylib"), "AppKit", "CoreServices", "Security")
    build(os.path.join(HERE, "driver.m"), os.path.join(work, "driver.dylib"), "AppKit", "CoreGraphics")
    with open(os.path.join(work, "routes.json"), "w") as f:
        f.write("{}")
    port_file = os.path.join(work, "stub.port")
    stub = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "activity_stub.py"), port_file,
                             os.path.join(work, "stub.log")])
    checks = []
    started = time.time()
    try:
        while not os.path.exists(port_file) or not open(port_file).read():
            time.sleep(0.1)
        port = open(port_file).read()
        state, home = new_profile(work, "fresh")
        documents = write_documents(os.path.join(work, "fresh", "documents"), ["A", "B", "C", "D", "E"])
        record = run_phase(work, app, state, home, port, "record", documents, out)
        verify_record(checks, state, documents, record)
        before = read_activity(state).get("documents", {})
        relaunch = run_phase(work, app, state, home, port, "relaunch", documents, out)
        verify_relaunch(checks, state, documents, before, relaunch)
        state, home, paths, expected_closed, unrecorded = aged_profile(work, time.time())
        aged = run_phase(work, app, state, home, port, "aged", paths, out)
        verify_aged(checks, paths, expected_closed, unrecorded, aged)
    finally:
        if stub.poll() is None:
            os.kill(stub.pid, signal.SIGKILL)
            stub.wait()
        subprocess.run([sys.executable, NODIALOGS, "unregister", work])
    with open(os.path.join(work, "checks.json"), "w") as f:
        json.dump({"seconds": round(time.time() - started), "checks": checks}, f, indent=1)
    failed = [c for c in checks if not c["pass"]]
    print(f"{len(checks) - len(failed)} of {len(checks)} checks passed; pictures in {out}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
