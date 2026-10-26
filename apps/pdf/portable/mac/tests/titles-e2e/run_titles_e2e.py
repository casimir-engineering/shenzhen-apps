#!/usr/bin/env python3
"""Documents named by UUIDs get real names and groups, end to end through the real app, off screen, with a model stub.

usage: run_titles_e2e.py --app <ShenzhenPDF.app> --work <new folder>

The owner asked the assistant to "rename the docs with UUIDs" and to empty General into groups; documents it could
not rename (read-only ones) stayed UUIDs and saving them failed. This replays that on a test profile.

A copy of the app (its own bundle identifier, LSUIElement, ad hoc signed so the harness can be inserted) runs from
--work with a test profile of its own (SPDF_STATE_DIR, a home, Collection on, Downloads): never the owner's state or
Keychain. tools/updater-e2e/szut.m keeps every window off screen and sends the model's requests to titles_stub.py on
127.0.0.1; driver.m looks through the tabs, types the requests into the chat and saves pictures. The profile has, in
General, six PDFs named by UUIDs (three writable, two read-only, one writable file in a folder that can't be
changed) and one with a real name, and a group of two others. Two launches:

  sort      "Rename the docs whose names are UUIDs ... and sort General into groups"; then "Save the read-only ones
            as PDFs in Downloads".
  relaunch  the names come back with the tabs; the read-only datasheet closed and opened again from its file gets its
            name back from Collection.

Exit status 0 when every check passes.
"""
import argparse
import json
import os
import plistlib
import re
import signal
import stat
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../../../../.."))
SZUT = os.path.join(REPO, "tools/updater-e2e/szut.m")
NODIALOGS = os.path.join(REPO, "tools/updater-e2e/nodialogs.py")
UUID = re.compile(r"[0-9a-f]{32}", re.I)

QUESTIONS = {
    "sort": "Rename the docs whose names are UUIDs, put the type of doc in the name (datasheet for example), and sort "
            "General into groups that make sense. General must be empty in the end.",
    "save": "Save the read-only ones as PDFs in Downloads.",
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

# file name, first page, how the file is kept, the name and group the owner wants.
DOCUMENTS = [
    ("dc1b3a737e85d8e2fb6486cbbd108a8b", ["MSK12C02-BDM", "Toggle switch specification", "Shenzhen Shouhan Technology"],
     "writable", "MSK12C02 - toggle switch - datasheet", "Switches and Sensors"),
    ("2f6fa8b5ebba154de171778d8d99b38f", ["Part No. : LTE-C9901", "IR emitter and detector", "Lite-On"],
     "read-only", "LTE-C9901 - IR emitter and detector - datasheet", "Switches and Sensors"),
    ("6c1e0a4f9b2d4e7a8c3b5d1f0e9a7c26", ["GDL6150LMSTN1", "Fingerprint sensor approval sheet"],
     "read-only", "GDL6150 - fingerprint sensor - datasheet", "Switches and Sensors"),
    ("137954b7a34ca916486ee6d9eb91a4d6", ["Mothership - Architecture", "Block diagram 2026-10"],
     "writable", "Mothership - architecture block diagram", "Mothership"),
    ("8896891714d6072232b4d64cf0cd1fc0", ["USB PCB 3744028", "Final inspection report"],
     "locked folder", "USB PCB 3744028 - final inspection report", "Mothership"),
    ("d07820bf72e5bd84d463f3efe04cdbce", ["OV50X50-4B COB", "Camera module datasheet"],
     "writable", "OV50X50 - camera module - datasheet", "Camera Module"),
    ("Camera bring-up notes", ["Camera bring-up notes", "Day 3"], "writable", None, "Camera Module"),
]
GROUPED = [("Remote buttons", ["Remote buttons"]), ("Remote battery holder", ["Remote battery holder"])]


def pdf(lines):
    text = " ".join(f"({line}) Tj 0 -34 Td" for line in lines)
    stream = f"BT /F1 24 Tf 40 760 Td {text} ET".encode()
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


def q(text):
    return json.dumps(text)


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
    plist["CFBundleIdentifier"] = "com.intuition.shenzhenpdf.titles-e2e"
    plist["LSUIElement"] = True
    with open(info, "wb") as f:
        plistlib.dump(plist, f)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", copy], check=True, capture_output=True)
    return copy


def make_profile(work):
    """The test profile: state with Collection on, a home, and the documents (paths as the app will see them)."""
    state, home = os.path.join(work, "profile", "state"), os.path.join(work, "profile", "home")
    os.makedirs(os.path.join(state, "Collection"))
    os.makedirs(home)
    with open(os.path.join(state, "ai-settings.yaml"), "w") as f:
        f.write(SETTINGS)
    with open(os.path.join(state, "settings.yaml"), "w") as f:
        f.write(READER_SETTINGS)
    with open(os.path.join(state, "Collection", "manifest.json"), "w") as f:
        json.dump({"format": 1, "settings": {"choice": "enabled"}, "documents": {}}, f)
    folder = os.path.join(work, "profile", "documents")
    locked = os.path.join(folder, "Inspection reports")
    os.makedirs(locked)
    documents = []
    for name, lines, kept, title, group in DOCUMENTS:
        path = os.path.join(locked if kept == "locked folder" else folder, name + ".pdf")
        with open(path, "wb") as f:
            f.write(pdf(lines))
        if kept == "read-only":
            os.chmod(path, 0o444)
        documents.append({"path": path, "kept": kept, "title": title, "group": group, "uuid": title is not None})
    os.chmod(locked, 0o555)
    grouped = []
    for name, lines in GROUPED:
        path = os.path.join(folder, name + ".pdf")
        with open(path, "wb") as f:
            f.write(pdf(lines))
        grouped.append(path)
    # The session the owner had: the UUID documents in General among others, two in a group of their own.
    lines = ["version: 2", "windows:", f"  - focusedAt: {time.time() - 978307200 - 60:.0f}",
             "    frame:", "      height: 900", "      width: 1500", "      x: 0", "      y: 0",
             '    id: "E2E-TITLES-WINDOW"', "    selectedTab: 0", "    tabs:"]
    for path in grouped:
        lines += [f"      - path: {q(path)}", f"        title: {q(os.path.splitext(os.path.basename(path))[0])}",
                  "        page: 1", "        group:", "          collapsed: false", '          color: "Teal"',
                  "          explicitGeneral: false", "          hidden: false", '          id: "REMOTE-PARTS"',
                  '          name: "Remote Parts"']
    for document in documents:
        lines += [f"      - path: {q(document['path'])}",
                  f"        title: {q(os.path.splitext(os.path.basename(document['path']))[0])}", "        page: 1",
                  f"        readOnly: {'true' if document['kept'] == 'read-only' else 'false'}"]
    with open(os.path.join(state, "session.yaml"), "w") as f:
        f.write("\n".join(lines) + "\n")
    return state, home, documents, grouped


def run_phase(work, app, state, home, port, phase, plan_extra, out):
    plan = os.path.join(work, f"plan-{phase}.json")
    with open(plan, "w") as f:
        json.dump({"phase": phase, "questions": QUESTIONS, **plan_extra}, f)
    env = {"PATH": "/usr/bin:/bin", "HOME": home, "CFFIXED_USER_HOME": home,
           "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "SPDF_STATE_DIR": state,
           "SZFRIENDS_STATE_DIR": os.path.join(state, "friends"),
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


def standard(path):
    """Collection keys paths by -[NSString stringByStandardizingPath], which drops /private from /private/tmp."""
    for prefix in ("/private/tmp/", "/private/var/"):
        if path.startswith(prefix):
            return path[len("/private"):]
    return path


def renamed_path(document):
    return os.path.join(os.path.dirname(document["path"]), document["title"] + ".pdf")


def verify_sort(checks, state, home, documents, grouped, result):
    before = {row["path"]: row for row in result.get("before", [])}
    check(checks, "before: the six UUID documents show their UUIDs in the tab strip, in General",
          all(UUID.fullmatch(before.get(d["path"], {}).get("strip", "")) and before[d["path"]]["general"]
              for d in documents if d["uuid"]), json.dumps(list(before.values()))[:600])
    rows = result.get("sortTabs", [])
    by_path = {row["path"]: row for row in rows}
    sort = result.get("sort", {})
    names = [c.get("name") for c in sort.get("calls", [])]
    check(checks, "the request is done in six steps: list, read the six (one reply), rename the six (one reply), list, "
                  "three groups (one reply), check General",
          names == ["list_workspace"] + ["read_pages"] * 6 + ["rename_document"] * 6 + ["list_workspace"] +
          ["organize_groups"] * 3 + ["list_workspace"], str(names))
    renames = [json.loads(t) for t in sort.get("tools", [])[7:13]]
    check(checks, "every rename_document call succeeds", renames and all(r.get("renamed") for r in renames),
          json.dumps(renames)[:800])
    for document in documents:
        if not document["uuid"]:
            continue
        base = os.path.basename(document["path"])
        if document["kept"] == "writable":
            target = renamed_path(document)
            row = by_path.get(target, {})
            check(checks, f"{document['title']}: the writable file is renamed and its tab shows the new name",
                  os.path.exists(target) and not os.path.exists(document["path"]) and row.get("strip") == document["title"]
                  and not row.get("displayName"), json.dumps(row))
        else:
            row = by_path.get(document["path"], {})
            check(checks, f"{document['title']}: the {document['kept']} file keeps its name, its tab shows the new one",
                  os.path.exists(document["path"]) and row.get("strip") == document["title"]
                  and row.get("stripFull") == document["title"] and row.get("displayName") == document["title"],
                  json.dumps(row))
    check(checks, "the window title shows the given name of the read-only datasheet in front",
          result.get("windowTitle", "").startswith(documents[1]["title"] + " - "), result.get("windowTitle", ""))
    check(checks, "no tab shows a UUID any more", rows and not any(UUID.search(r["strip"]) for r in rows),
          json.dumps([r["strip"] for r in rows]))
    final = {d["path"] if (not d["uuid"] or d["kept"] != "writable") else renamed_path(d): d for d in documents}
    check(checks, "General is empty", rows and not any(r["general"] for r in rows if r["path"] not in grouped),
          json.dumps([(r["strip"], r["group"]) for r in rows]))
    check(checks, "every document is in the group that fits it",
          all(by_path.get(path, {}).get("group") == d["group"] for path, d in final.items()),
          json.dumps({by_path.get(p, {}).get("strip", p): by_path.get(p, {}).get("group") for p in final}))
    check(checks, "the group that was there is untouched",
          all(by_path.get(p, {}).get("group") == "Remote Parts" for p in grouped))
    manifest = json.load(open(os.path.join(state, "Collection", "manifest.json")))
    kept_names = {standard(doc.get("path", "")): doc.get("displayName") for doc in manifest.get("documents", {}).values()}
    check(checks, "Collection keeps the given names of the files that kept theirs",
          all(kept_names.get(standard(d["path"])) == d["title"] for d in documents if d["uuid"] and d["kept"] != "writable"),
          json.dumps(kept_names)[:600])
    answer = sort.get("answer", "")
    check(checks, "the assistant says plainly which files kept their names and why",
          "keeps its name, 2f6fa8b5ebba154de171778d8d99b38f.pdf, because it is read-only" in answer
          and "because the folder it is in can't be changed" in answer and "General is empty." in answer, answer[:900])
    save = result.get("save", {})
    jobs = [json.loads(t) for t, c in zip(save.get("tools", []), save.get("calls", [])) if c.get("name") == "document_job"]
    folder = os.path.join(state, "Downloads")  # the assistant's Downloads in a test profile (SPDFMacAIOutputFiles.mm)
    downloads = sorted(os.listdir(folder)) if os.path.isdir(folder) else []
    wanted = sorted(d["title"] + ".pdf" for d in documents if d["kept"] == "read-only")
    check(checks, "both read-only documents are saved to Downloads by document_job, without showing them first",
          len(jobs) == 2 and all(j.get("completed") for j in jobs) and all(w in downloads for w in wanted)
          and "show_document" not in [c.get("name") for c in save.get("calls", [])],
          json.dumps({"jobs": jobs, "downloads": downloads})[:800])


def verify_relaunch(checks, documents, result, reopen):
    titles = {d["path"]: d["title"] for d in documents if d["uuid"] and d["kept"] != "writable"}
    restored = {row["path"]: row for row in result.get("restored", [])}
    check(checks, "after a relaunch the tabs show the given names again",
          all(restored.get(p, {}).get("strip") == t for p, t in titles.items()),
          json.dumps({p: restored.get(p, {}).get("strip") for p in titles}))
    closed = [r["path"] for r in result.get("closed", [])]
    reopened = {row["path"]: row for row in result.get("reopened", [])}
    check(checks, "closed and opened again from its file, the read-only datasheet gets its name back from Collection",
          reopen not in closed and reopened.get(reopen, {}).get("strip") == titles[reopen]
          and result.get("reopenedWindowTitle", "").startswith(titles[reopen]),
          json.dumps({"row": reopened.get(reopen), "window": result.get("reopenedWindowTitle")}))


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
    build(os.path.join(HERE, "driver.m"), os.path.join(work, "driver.dylib"), "AppKit")
    with open(os.path.join(work, "routes.json"), "w") as f:
        f.write("{}")
    port_file = os.path.join(work, "stub.port")
    stub = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "titles_stub.py"), port_file,
                             os.path.join(work, "stub.log")])
    checks = []
    started = time.time()
    state = home = None
    try:
        while not os.path.exists(port_file) or not open(port_file).read():
            time.sleep(0.1)
        port = open(port_file).read()
        state, home, documents, grouped = make_profile(work)
        sort = run_phase(work, app, state, home, port, "sort", {"focus": documents[1]["path"]}, out)
        verify_sort(checks, state, home, documents, grouped, sort)
        reopen = documents[1]["path"]
        relaunch = run_phase(work, app, state, home, port, "relaunch", {"reopen": reopen}, out)
        verify_relaunch(checks, documents, relaunch, reopen)
    finally:
        if stub.poll() is None:
            os.kill(stub.pid, signal.SIGKILL)
            stub.wait()
        subprocess.run([sys.executable, NODIALOGS, "unregister", work])
        locked = os.path.join(work, "profile", "documents", "Inspection reports")
        if os.path.isdir(locked):
            os.chmod(locked, stat.S_IRWXU)  # so the work folder can be removed
    with open(os.path.join(work, "checks.json"), "w") as f:
        json.dump({"seconds": round(time.time() - started), "checks": checks}, f, indent=1)
    failed = [c for c in checks if not c["pass"]]
    print(f"{len(checks) - len(failed)} of {len(checks)} checks passed; pictures in {out}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
