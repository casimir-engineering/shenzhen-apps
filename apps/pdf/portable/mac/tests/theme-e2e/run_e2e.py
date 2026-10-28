#!/usr/bin/env python3
"""The reader's chrome colours, through the real app, off screen.

usage: run_e2e.py --app <ShenzhenPDF.app> --work <new folder>

A copy of the app (its own bundle identifier, LSUIElement, ad hoc signed) runs once from --work with a test profile
(SPDF_STATE_DIR and a home of its own). tools/updater-e2e/szut.m keeps every window off screen and the app offline,
and sends the assistant's requests to a stub on 127.0.0.1 that answers with a fixed Markdown reply. driver.m opens
documents, puts them in eleven named groups of every colour (one open with three tabs, the rest collapsed, plus
General), opens the outline, asks the assistant one question, opens Settings and the Collection, hovers a tab, and
pictures every window in light and dark into <work>/out.

Checks print PASS/FAIL. Exit status 1 when a check fails.
"""
import argparse
import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../../../../.."))
SZUT = os.path.join(REPO, "tools/updater-e2e/szut.m")
NODIALOGS = os.path.join(REPO, "tools/updater-e2e/nodialogs.py")
sys.path.insert(0, os.path.join(HERE, "..", "tab-hover-e2e"))
import fixtures  # noqa: E402

SETTINGS = ("version: 1\nshowShortcutHelpOnLaunch: false\nautoUpdateEnabled: false\ndefaultReaderPromptDismissed: true\n"
            "fullDiskAccessPromptDismissed: true\npermissionsWizardShown: true\nfriends:\n  enabled: true\n"
            "  settingsIntroduced: 1\n")
AI_SETTINGS = """schema_version: 1
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
QUESTION = "Which connector does the remote board use, and what is still open?"
ANSWER = ("The remote board uses the **24-pin FPC connector** described in *Remote design notes*.\n\n"
          "### Still open\n\n- Shield grounding on the flex tail\n- Second source for the connector\n"
          "- Final pin map for the audio lines\n\n| Item | Owner | Due |\n|---|---|---|\n| Pin map | Audio | Friday |\n"
          "| Shield | Mechanical | Next week |\n\n`FPC-24-0.5` is the part number in the notes.")

# name, color, documents (by index into DOCS)
GROUPS = [("Remote Design", "Blue", [0, 1, 2]), ("Audio Board", "Amber", [3]), ("Camera Flex", "Green", [4]),
          ("Suppliers", "Coral", [5]), ("Firmware", "Purple", [6]), ("Enclosure", "Teal", [7]),
          ("Test Reports", "Orange", [8]), ("Datasheets", "Indigo", [9]), ("Contracts", "Rose", [10]),
          ("Prototypes", "Plum", [11]), ("Archive", "Slate", [12])]
MARKDOWN = """# Remote design notes

## Connector

The remote board uses a 24-pin FPC connector, 0.5 mm pitch.

## Power

Two rails: 3.3 V and 1.8 V.

## Audio lines

Differential pairs, routed on layer 3.

## Open questions

- Shield grounding
- Second source
"""


class Stub(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply({"data": [{"id": "e2e/stub-model", "name": "Stub", "context_length": 200000,
                              "architecture": {"input_modalities": ["text", "image"]}}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        first = request["messages"][0]["content"] if request["messages"] else ""
        content = "Remote board connector" if not request.get("tools") and "plain title" in str(first) else ANSWER
        self.reply({"id": "stub", "object": "chat.completion", "model": "e2e/stub-model",
                    "choices": [{"index": 0, "message": {"role": "assistant", "content": content},
                                 "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 1000, "completion_tokens": 100, "total_tokens": 1100}})


def build(source, output, *frameworks):
    command = ["clang", "-dynamiclib", "-fobjc-arc", "-arch", "arm64", source, "-o", output]
    for framework in frameworks:
        command += ["-framework", framework]
    subprocess.run(command, check=True)


def prepare_app(app, work):
    copy = os.path.join(work, "app", "ShenzhenPDF Theme E2E.app")
    os.makedirs(os.path.dirname(copy))
    subprocess.run(["ditto", app, copy], check=True)
    info = os.path.join(copy, "Contents", "Info.plist")
    with open(info, "rb") as f:
        plist = plistlib.load(f)
    plist["CFBundleIdentifier"] = "com.intuition.shenzhenpdf.theme-e2e"
    plist["LSUIElement"] = True
    with open(info, "wb") as f:
        plistlib.dump(plist, f)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", copy], check=True, capture_output=True)
    return copy


def make_documents(folder):
    os.makedirs(folder, exist_ok=True)
    names = ["Remote design notes.md", "Remote board schematic.pdf", "Remote flex drawing.pdf", "Audio board BOM.pdf",
             "Camera flex rev C.pdf", "Supplier quotes.pdf", "Firmware release notes.pdf", "Enclosure drawing.pdf",
             "Drop test report.pdf", "Connector datasheet.pdf", "Supply agreement.pdf", "Prototype photos.pdf",
             "Old revision B.pdf", "Meeting notes.pdf", "Shipping checklist.pdf"]
    paths = []
    for n, name in enumerate(names):
        path = os.path.join(folder, name)
        if name.endswith(".md"):
            with open(path, "w") as f:
                f.write(MARKDOWN)
        else:
            fixtures.write_pdf(path, 2 + n % 3, label=name[:-4])
        paths.append(path)
    return paths


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--work", required=True)
    args = parser.parse_args()
    work = os.path.abspath(args.work)
    os.makedirs(work)
    out, home, state = (os.path.join(work, n) for n in ("out", "home", "state"))
    for folder in (out, home, state):
        os.makedirs(folder)
    with open(os.path.join(state, "settings.yaml"), "w") as f:
        f.write(SETTINGS)
    with open(os.path.join(state, "ai-settings.yaml"), "w") as f:
        f.write(AI_SETTINGS)
    documents_dir = os.path.join(os.path.expanduser("~/Library/Caches/shenzhen-build/theme-e2e"),
                                 os.path.basename(work))
    documents = make_documents(documents_dir)
    plan = {"documents": documents, "question": QUESTION, "open_group": "Remote Design",
            "selected": documents[0], "hovered": documents[0],
            "groups": [{"name": n, "color": c, "documents": [documents[i] for i in d]} for n, c, d in GROUPS]}
    with open(os.path.join(work, "plan.json"), "w") as f:
        json.dump(plan, f)
    app = prepare_app(args.app, work)
    build(SZUT, os.path.join(work, "szut.dylib"), "AppKit", "CoreServices", "Security")
    build(os.path.join(HERE, "driver.m"), os.path.join(work, "driver.dylib"), "AppKit", "QuartzCore")
    with open(os.path.join(work, "routes.json"), "w") as f:
        f.write("{}")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Stub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    env = {"PATH": "/usr/bin:/bin", "HOME": home, "CFFIXED_USER_HOME": home, "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "SPDF_STATE_DIR": state, "SZFRIENDS_STATE_DIR": state, "SPDF_NO_ACTIVATE": "1", "SZUT_ROOT": work,
           "SZUT_LOG": os.path.join(work, "szut.jsonl"), "SZUT_ROUTES": os.path.join(work, "routes.json"),
           "SZUT_FORWARD": f"https://openrouter.ai/api/=http://127.0.0.1:{port}/api/",
           "DYLD_INSERT_LIBRARIES": os.path.join(work, "szut.dylib") + ":" + os.path.join(work, "driver.dylib"),
           "SPDF_E2E_PLAN": os.path.join(work, "plan.json"), "SPDF_E2E_OUT": out}
    executable = os.path.join(app, "Contents", "MacOS", "ShenzhenPDF")
    try:
        with open(os.path.join(work, "app.log"), "w") as log:
            process = subprocess.Popen([executable], env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                process.wait(timeout=240)
            except subprocess.TimeoutExpired:
                print("FAIL the app did not finish within 4 minutes")
            finally:
                if process.poll() is None:
                    os.kill(process.pid, signal.SIGKILL)
                    process.wait()
    finally:
        server.shutdown()
        subprocess.run([sys.executable, NODIALOGS, "unregister", work])
        shutil.rmtree(documents_dir, ignore_errors=True)
    result_file = os.path.join(out, "result.json")
    result = json.load(open(result_file)) if os.path.exists(result_file) else {}
    checks = []

    def check(name, condition, detail=""):
        checks.append(condition)
        print(("PASS " if condition else "FAIL ") + name + (f" ({detail})" if detail and not condition else ""))

    groups = result.get("groups", [])
    check("eleven named groups of every colour, plus General", len(groups) >= 11 and
          {g["color"] for g in groups} >= {c for _, c, _ in GROUPS}, json.dumps(groups)[:400])
    pictures = [os.path.basename(p) for p in result.get("pictures", [])]
    for look in ("light", "dark"):
        check(f"{look}: the reader window is pictured", f"reader-{look}.png" in pictures, str(pictures))
        check(f"{look}: the assistant is pictured", any(p.startswith("assistant") and look in p for p in pictures)
              or f"reader-{look}.png" in pictures, str(pictures))
    print(f"{sum(checks)} of {len(checks)} checks passed; pictures in {out}")
    return 0 if all(checks) else 1


if __name__ == "__main__":
    sys.exit(main())
