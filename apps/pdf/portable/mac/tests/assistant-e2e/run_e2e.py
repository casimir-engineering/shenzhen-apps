#!/usr/bin/env python3
"""The assistant end to end, through the real app, off screen.

usage: run_e2e.py --app <ShenzhenPDF.app> --document <PDF with plates on pages 4 and 5> --work <new folder>
                  [--python <assistant Python environment to copy>]
       run_e2e.py --scenario long --app <ShenzhenPDF.app> --work <new folder>   (run_e2e_long.py: the owner's long
                  requests, Continue, Downloads write-only, and the end of the chat)

A copy of the app (its own bundle identifier, so its preferences are its own; LSUIElement and ad hoc signed so the
harness can be inserted) runs from --work with a test profile: SPDF_STATE_DIR and a home of its own, so its chats,
Collection, Downloads and Python are the test's. tools/updater-e2e/szut.m keeps every window off screen, refuses the
Keychain and LaunchServices, and sends the model's requests to model_stub.py on 127.0.0.1; driver.m clicks, types,
drops files and saves pictures. Python, the sandbox, the documents and every file the assistant makes are real.

Checks, in result.json and on stdout: the plates measured from their embedded images; a CSV, a PNG and a PDF report in
the test Downloads folder with cards in the chat, the PDF also in the test Collection; files and a folder dropped on
chat A read through Python, the file beside them and a link out of the folder refused; a part of chat A reads its
folder; chat B is refused chat A's folder. Nothing it starts outlives it.
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

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run_e2e_long  # noqa: E402
REPO = os.path.abspath(os.path.join(HERE, "../../../../../.."))
SZUT = os.path.join(REPO, "tools/updater-e2e/szut.m")
NODIALOGS = os.path.join(REPO, "tools/updater-e2e/nodialogs.py")

QUESTIONS = {
    "gray": "Using Python, measure the mean gray, as % of full scale, of the square inscribed in the circular "
            "diffuser scene on the plates on pages 4 and 5.",
    "files": "Make a CSV and a PNG plot of the result, and a short PDF report.",
    "attached": "Read the attached files with Python, and also try %@.",
    "parts": "Use parts: count the files in the attached folder.",
    "other": "From the other chat, read %@ with Python.",
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
python_enabled: true
subagents_enabled: true
"""

# A one-page PDF with a line of text, small enough to read at a glance.
SMALL_PDF = (b"%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
             b"3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 120]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>"
             b"endobj\n4 0 obj<</Length 52>>stream\nBT /F1 14 Tf 20 60 Td (Attached plate notes) Tj ET\nendstream\n"
             b"endobj\n5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n")


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
    plist["CFBundleIdentifier"] = "com.intuition.shenzhenpdf.assistant-e2e"
    plist["LSUIElement"] = True
    with open(info, "wb") as f:
        plistlib.dump(plist, f)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", copy], check=True, capture_output=True)
    return copy


def prepare_files(work):
    attach = os.path.join(work, "attach")
    folder = os.path.join(attach, "Captures")
    os.makedirs(os.path.join(folder, "sub"))
    with open(os.path.join(attach, "plate-notes.pdf"), "wb") as f:
        f.write(SMALL_PDF)
    with open(os.path.join(attach, "levels.csv"), "w") as f:
        f.write("page,condition\n4,IR 10%\n5,IR 100%\n")
    with open(os.path.join(attach, "capture.bin"), "wb") as f:
        f.write(bytes(range(256)) * 16)
    with open(os.path.join(attach, "sibling-secret.txt"), "w") as f:
        f.write("SIBLING-SECRET-7731")
    with open(os.path.join(folder, "frame-001.raw"), "wb") as f:
        f.write(b"\x00\x01" * 512)
    with open(os.path.join(folder, "notes.txt"), "w") as f:
        f.write("frames from the 15 October capture\n")
    with open(os.path.join(folder, "sub", "more.csv"), "w") as f:
        f.write("a,b\n1,2\n")
    secret = os.path.join(work, "outside-secret.txt")
    with open(secret, "w") as f:
        f.write("OUTSIDE-SECRET-4410")
    os.symlink(secret, os.path.join(folder, "leak"))
    return {"files": [os.path.join(attach, n) for n in ("plate-notes.pdf", "levels.csv", "capture.bin")],
            "folder": folder, "sibling": os.path.join(attach, "sibling-secret.txt")}


def check(results, name, condition, detail=""):
    results.append({"check": name, "pass": bool(condition), "detail": detail})
    print(("PASS " if condition else "FAIL ") + name + (f" ({detail})" if detail and not condition else ""))


def stdout(tool):
    try:
        return json.loads(tool).get("stdout", "") or tool
    except ValueError:
        return tool


def verify(out, state, result):
    checks = []
    gray = result.get("gray", {})
    tools = " ".join(gray.get("tools", []))
    check(checks, "the plates are measured from their embedded images",
          "mean_gray_percent" in tools and "page-4-image-1.png" in tools and '\\"lossless\\": true' in tools
          and "%" in gray.get("answer", ""), gray.get("answer", "")[:300])
    downloads = os.path.join(state, "Downloads")
    kept = sorted(os.listdir(downloads)) if os.path.isdir(downloads) else []
    for name in ("diffuser_gray.csv", "diffuser_gray.png", "diffuser_gray_report.pdf"):
        check(checks, f"{name} is in the test Downloads folder", name in kept, str(kept))
    files = result.get("files", {})
    shown = [a["name"] for c in files.get("activity", []) if c.get("cardKind") == "assistant.output"
             for a in c.get("attachments", [])]
    shown += [c["caption"] for c in files.get("activity", []) if c.get("status") == "Saved to Downloads"]
    check(checks, "each saved file shows in the chat with Open and Show in Finder",
          sorted(shown) == ["diffuser_gray.csv", "diffuser_gray.png", "diffuser_gray_report.pdf"], str(shown))
    manifest = os.path.join(state, "Collection", "manifest.json")
    collection = open(manifest).read() if os.path.exists(manifest) else ""
    check(checks, "the PDF report is in the test Collection, made by the assistant",
          "diffuser_gray_report.pdf" in collection and "Made by the assistant" in collection)
    chips = result.get("chips", {}).get("grants", [])
    check(checks, "three files and a folder dropped on chat A are its attachments",
          len(chips) == 4 and sum(g["kind"] == "folder" for g in chips) == 1, json.dumps(chips)[:300])
    attached = " ".join(stdout(t) for t in result.get("attached", {}).get("tools", []))
    check(checks, "chat A's Python reads the dropped files and folder",
          "FILE plate-notes.pdf" in attached and "FILE levels.csv" in attached and "FILE capture.bin 4096" in attached
          and "frame-001.raw" in attached and "sub/more.csv" in attached, attached[:400])
    check(checks, "the file beside the dropped ones and their folder are refused",
          "REFUSED sibling-secret.txt PermissionError" in attached and "REFUSED attach PermissionError" in attached
          and "SIBLING-SECRET" not in attached and "LEAK" not in attached, attached[:600])
    check(checks, "a link out of the dropped folder is never followed", "OUTSIDE-SECRET" not in attached)
    parts = result.get("parts", {})
    check(checks, "a part of chat A reads its folder",
          "frame-001.raw" in parts.get("answer", "") or "frame-001.raw" in " ".join(parts.get("tools", [])),
          parts.get("answer", "")[:300])
    other = result.get("other", {})
    check(checks, "chat B is refused chat A's folder",
          "not attached to this chat" in " ".join(other.get("tools", [])) and not other.get("grants"),
          json.dumps(other)[:400])
    return checks


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--document")
    parser.add_argument("--scenario", choices=["plates", "long"], default="plates")
    parser.add_argument("--work", required=True)
    parser.add_argument("--python", default=os.path.expanduser(
        "~/Library/Application Support/ShenzhenPDF/assistant-python"))
    args = parser.parse_args()
    work = os.path.abspath(args.work)
    os.makedirs(work)
    out, home, state = (os.path.join(work, n) for n in ("out", "home", "state"))
    for folder in (out, home, state):
        os.makedirs(folder)
    with open(os.path.join(state, "ai-settings.yaml"), "w") as f:
        f.write(SETTINGS)
    # The assistant's Python for this profile: a copy, so nothing of the person's install is touched.
    shutil.copytree(args.python, os.path.join(state, "assistant-python"), symlinks=True)
    if args.scenario == "long":
        plan = run_e2e_long.prepare(work, state)
    else:
        document = os.path.join(work, "documents", os.path.basename(args.document))
        os.makedirs(os.path.dirname(document))
        shutil.copyfile(args.document, document)
        plan = {"document": document, "questions": QUESTIONS, "attach": prepare_files(work)}
    with open(os.path.join(work, "plan.json"), "w") as f:
        json.dump(plan, f)
    app = prepare_app(args.app, work)
    build(SZUT, os.path.join(work, "szut.dylib"), "AppKit", "CoreServices", "Security")
    build(os.path.join(HERE, "driver.m"), os.path.join(work, "driver.dylib"), "AppKit")
    with open(os.path.join(work, "routes.json"), "w") as f:
        f.write("{}")
    port_file = os.path.join(work, "stub.port")
    stub = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "model_stub.py"), port_file,
                             os.path.join(work, "stub.log")])
    processes = [stub]
    started = time.time()
    try:
        while not os.path.exists(port_file) or not open(port_file).read():
            time.sleep(0.1)
        port = open(port_file).read()
        env = {"PATH": "/usr/bin:/bin", "HOME": home, "CFFIXED_USER_HOME": home, "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
               "SPDF_STATE_DIR": state, "SPDF_NO_ACTIVATE": "1", "SZUT_ROOT": work,
               "SZUT_LOG": os.path.join(work, "szut.jsonl"), "SZUT_ROUTES": os.path.join(work, "routes.json"),
               "SZUT_FORWARD": f"https://openrouter.ai/api/=http://127.0.0.1:{port}/api/",
               "DYLD_INSERT_LIBRARIES": os.path.join(work, "szut.dylib") + ":" + os.path.join(work, "driver.dylib"),
               "SPDF_E2E_PLAN": os.path.join(work, "plan.json"), "SPDF_E2E_OUT": out}
        executable = os.path.join(app, "Contents", "MacOS", "ShenzhenPDF")
        with open(os.path.join(work, "app.log"), "w") as log:
            process = subprocess.Popen([executable], env=env, stdout=log, stderr=subprocess.STDOUT)
            processes.append(process)
            try:
                process.wait(timeout=1200)
            except subprocess.TimeoutExpired:
                print("FAIL the app did not finish within 20 minutes")
    finally:
        for process in processes:
            if process.poll() is None:
                os.kill(process.pid, signal.SIGKILL)
                process.wait()
        subprocess.run([sys.executable, NODIALOGS, "unregister", work])
    result_file = os.path.join(out, "result.json")
    result = json.load(open(result_file)) if os.path.exists(result_file) else {}
    checks = run_e2e_long.verify(check, out, state, result) if args.scenario == "long" else verify(out, state, result)
    with open(os.path.join(work, "checks.json"), "w") as f:
        json.dump({"seconds": round(time.time() - started), "checks": checks}, f, indent=1)
    failed = [c for c in checks if not c["pass"]]
    print(f"{len(checks) - len(failed)} of {len(checks)} checks passed; pictures in {out}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
