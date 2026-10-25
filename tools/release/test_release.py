#!/usr/bin/env python3
"""Tests for tools/release.sh's machinery that a dry run does not reach: stage stamps and resuming, test stamps, the
source tag on a release repository, publishing a GitHub release (against a stand-in for gh that keeps releases
in a JSON file), and reading the version each kind of build shows (displayed.py). Nothing leaves the machine.

    python3 tools/release/test_release.py
"""
import io
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True  # nothing left in the worktree
TMP = tempfile.mkdtemp(prefix="release-tests.")
os.environ["SHENZHEN_RELEASE_GIT_URL_BASE"] = "file://" + os.path.join(TMP, "remotes") + "/"
os.environ["SHENZHEN_BUILD_CACHE"] = os.path.join(TMP, "cache")
os.environ["FAKE_GH_STATE"] = os.path.join(TMP, "gh-state.json")
sys.path.insert(0, HERE)

import common  # noqa: E402
import displayed  # noqa: E402

FAKE_GH = r'''#!/usr/bin/env python3
# A stand-in for gh: releases live in $FAKE_GH_STATE; every call is appended to its "calls".
import fcntl, hashlib, json, os, re, sys
path = os.environ["FAKE_GH_STATE"]
lock = open(path + ".lock", "w")
fcntl.flock(lock, fcntl.LOCK_EX)  # parallel uploads run several of these at once
state = json.load(open(path))
args = sys.argv[1:]
state["calls"].append(args)
def save():
    json.dump(state, open(path, "w"), indent=1)
def fail(message, code=1):
    save(); sys.stderr.write(message + "\n"); sys.exit(code)
if args[:2] == ["auth", "status"]:
    save(); sys.exit(0)
if args[:2] == ["release", "upload"]:
    tag, file, repo = args[2], args[3], args[args.index("--repo") + 1]
    release = next(r for r in state["releases"][repo] if r["tag_name"] == tag)
    data = open(file, "rb").read()
    release["assets"] = [a for a in release["assets"] if a["name"] != os.path.basename(file)]
    state["next"] += 1
    release["assets"].append({"id": state["next"], "name": os.path.basename(file), "size": len(data),
                              "state": "uploaded", "digest": "sha256:" + hashlib.sha256(data).hexdigest()})
    save(); sys.exit(0)
if args[0] == "api":
    method = args[args.index("--method") + 1] if "--method" in args else "GET"
    target = next(a for a in args[1:] if a.startswith("repos/"))
    body = json.load(open(args[args.index("--input") + 1])) if "--input" in args else {}
    m = re.fullmatch(r"repos/([^/]+/[^/]+)/releases(?:/(assets/)?(\d+|latest))?(\?.*)?", target)
    if not m:
        fail("HTTP 404: " + target)
    repo, asset, ident = m.group(1), m.group(2), m.group(3)
    releases = state["releases"].setdefault(repo, [])
    if asset and method == "DELETE":
        for r in releases:
            r["assets"] = [a for a in r["assets"] if str(a["id"]) != ident]
        save(); sys.exit(0)
    if ident is None and method == "GET":
        print(json.dumps(sorted(releases, key=lambda r: -r["id"]))); save(); sys.exit(0)
    if ident is None and method == "POST":
        state["next"] += 1
        release = dict(id=state["next"], assets=[], html_url="https://example.invalid/" + body["tag_name"], **body)
        releases.append(release)
        print(json.dumps(release)); save(); sys.exit(0)
    if ident == "latest":
        published = [r for r in releases if not r["draft"] and not r["prerelease"]]
        print(json.dumps(max(published, key=lambda r: r["id"]))); save(); sys.exit(0)
    release = next((r for r in releases if str(r["id"]) == ident), None)
    if not release:
        fail("HTTP 404: " + target)
    if method == "PATCH":
        release.update({k: v for k, v in body.items() if k != "make_latest"})
    print(json.dumps(release)); save(); sys.exit(0)
fail("fake gh: unexpected " + " ".join(args), 2)
'''

passed = failed = 0


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"ok   {name}")
    else:
        failed += 1
        print(f"FAIL {name} {detail}")


def sh(*cmd, cwd=None, env=None):
    return subprocess.run(cmd, cwd=cwd, env={**os.environ, **(env or {})}, check=True, capture_output=True,
                          text=True).stdout.strip()


def git_identity():
    return {"GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid", "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@example.invalid"}


def setup():
    bin_dir = os.path.join(TMP, "bin")
    os.makedirs(bin_dir)
    with open(os.path.join(bin_dir, "gh"), "w") as f:
        f.write(FAKE_GH)
    os.chmod(os.path.join(bin_dir, "gh"), 0o755)
    os.environ["PATH"] = bin_dir + os.pathsep + os.environ["PATH"]
    # The monorepo: apps/pdf, plus tools/test-stamp.sh; its origin is a local bare repository.
    mono = os.path.join(TMP, "mono")
    os.makedirs(os.path.join(mono, "apps/pdf/portable"))
    os.makedirs(os.path.join(mono, "tools"))
    open(os.path.join(mono, "apps/pdf/portable/readme.md"), "w").write("ShenzhenPDF\n")
    open(os.path.join(mono, "apps/other.txt"), "w").write("not ShenzhenPDF\n")
    shutil.copy(os.path.join(os.path.dirname(HERE), "test-stamp.sh"), os.path.join(mono, "tools/test-stamp.sh"))
    sh("git", "init", "-q", "-b", "main", mono)
    sh("git", "add", "-A", cwd=mono)
    sh("git", "commit", "-q", "-m", "one", cwd=mono, env=git_identity())
    sh("git", "init", "-q", "--bare", os.path.join(TMP, "origin.git"))
    sh("git", "remote", "add", "origin", os.path.join(TMP, "origin.git"), cwd=mono)
    sh("git", "push", "-q", "origin", "main", cwd=mono)
    # The release repository: its own history, with the previous release tag.
    old = os.path.join(TMP, "old")
    os.makedirs(old)
    open(os.path.join(old, "readme.md"), "w").write("ShenzhenPDF, before\n")
    sh("git", "init", "-q", "-b", "master", old)
    sh("git", "add", "-A", cwd=old)
    sh("git", "commit", "-q", "-m", "standalone", cwd=old, env=git_identity())
    sh("git", "tag", "26.10.20-1", cwd=old)
    remote = os.path.join(TMP, "remotes/casimir-engineering/shenzhen-pdf.git")
    os.makedirs(os.path.dirname(remote))
    sh("git", "clone", "-q", "--bare", old, remote)
    previous = {"id": 1, "tag_name": "26.10.20-1", "draft": False, "prerelease": False, "assets": [],
                "html_url": "https://example.invalid/26.10.20-1"}
    json.dump({"calls": [], "next": 100, "releases": {"casimir-engineering/shenzhen-pdf": [previous]}},
              open(os.environ["FAKE_GH_STATE"], "w"))
    return mono, remote, sh("git", "rev-parse", "26.10.20-1", cwd=old)


def test_stages():
    folder = os.path.join(TMP, "stamps")
    out = os.path.join(TMP, "out.bin")
    runs = []

    def make(name, content):
        def fn():
            runs.append(name)
            open(out if name == "a" else out + name, "w").write(content)
            return {"files": [out if name == "a" else out + name]}
        return fn
    stages = common.Stages(folder, ["a", "b", "c"], "id-1")
    stages.run("a", make("a", "1"))
    stages.run("b", make("b", "1"))
    stages.run("c", make("c", "1"))
    stages = common.Stages(folder, ["a", "b", "c"], "id-1")
    stages.run("a", make("a", "1"))
    stages.run("b", make("b", "1"))
    check("a rerun skips stages whose output is intact", runs == ["a", "b", "c"], runs)
    open(out + "b", "w").write("changed")
    stages.run("b", make("b", "2"))
    check("a stage whose output changed runs again", runs[-1] == "b", runs)
    check("running a stage again drops the stamps after it", stages.cached("c") is None)
    other = common.Stages(folder, ["a", "b", "c"], "id-2")
    check("another commit or version does not reuse the stamps", other.cached("a") is None)


def test_interrupted_command():
    log = os.path.join(TMP, "interrupt.log")
    check("a failing command is a failure, not an interruption",
          common.run(["sh", "-c", "exit 3"], log=log, check=False) == 3)
    for name, cmd in (("killed by SIGINT", ["sh", "-c", "kill -INT $$"]),
                      ("exiting 130 after a SIGINT", ["bash", "-c", "exit 130"])):
        try:
            common.run(cmd, log=log, check=False)
            check(f"a command {name} stops the run", False)
        except KeyboardInterrupt:
            check(f"a command {name} stops the run", True)
    ran = []

    def sweep():
        for suite in ("first", "interrupted", "after"):
            ran.append(suite)
            common.run(["sh", "-c", "kill -INT $$" if suite == "interrupted" else "true"], log=log, check=False)
    try:
        common.parallel({"notarize": lambda: None, "tests": sweep})
        check("an interrupted test sweep stops the run", False)
    except KeyboardInterrupt:
        check("an interrupted test sweep stops the run", True)
    check("no suite runs after the interrupted one", ran == ["first", "interrupted"], ran)


def test_tests_leave_apps_alone():
    repo = os.path.dirname(os.path.dirname(HERE))
    guard = os.path.join(repo, "tools", "check-tests-leave-apps-alone.sh")
    root = os.path.join(TMP, "apps-alone")
    allowed = ["apps/3d/electron/test-identity.test.cjs", "apps/files/package/updater-helper-process-test.swift",
               "tools/updater-e2e/sweep.py", "tools/updater-e2e/szut.m"]
    for path in allowed:
        os.makedirs(os.path.dirname(os.path.join(root, path)), exist_ok=True)
        shutil.copyfile(os.path.join(repo, path), os.path.join(root, path))
    os.makedirs(os.path.join(root, "apps/pdf/tests"))
    script = os.path.join(root, "apps/pdf/tests/run-app.sh")
    open(script, "w").write('"$APP_UNDER_TEST/Contents/MacOS/ShenzhenPDF" & pid=$!\nkill "$pid"\n')
    sh("git", "init", "-q", root)
    result = lambda: subprocess.run([guard, "--root", root], capture_output=True, text=True)  # noqa: E731
    check("a test acting on what it started passes", result().returncode == 0, result().stdout + result().stderr)
    # Spelled in pieces so this file does not trip the guard itself.
    for name, line in (("quitting an app by name", "osa" + "script -e 'quit app \"ShenzhenPDF\"'"),
                       ("killing by name", "kill" + "all ShenzhenPDF"),
                       ("opening by bundle id", "open" + " -b com.intuition.shenzhenpdf"),
                       ("naming the installed copy", 'cp -R "/Appli' + 'cations/ShenzhenPDF.app" .')):
        open(script, "w").write(line + "\n")
        out = result()
        check(f"a test {name} is refused", out.returncode == 1 and "apps/pdf/tests/run-app.sh:1:" in out.stdout,
              out.stdout + out.stderr)
    open(script, "w").write("true\n")
    swift = os.path.join(root, allowed[1])
    open(swift, "w").write("// no lookups left\n")
    out = result()
    check("an allowed file that no longer matches must leave the list", out.returncode == 1 and allowed[1] in out.stdout,
          out.stdout + out.stderr)


def test_test_stamps(mono):
    stamp = os.path.join(mono, "tools/test-stamp.sh")
    ok = lambda *args: subprocess.run([stamp, *args], cwd=mono, capture_output=True).returncode == 0  # noqa: E731
    sh(stamp, "run", "pdf/suite", "--", "true", cwd=mono)
    check("a passing suite is recorded", ok("check", "pdf/suite"))
    check("a failing one is not", not ok("run", "pdf/bad", "--", "false") and not ok("check", "pdf/bad"))
    open(os.path.join(mono, "apps/dirty.txt"), "w").write("x")
    check("uncommitted changes find no stamp", not ok("check", "pdf/suite"))
    sh(stamp, "record", "pdf/dirty", cwd=mono)
    os.remove(os.path.join(mono, "apps/dirty.txt"))
    check("and record none", not ok("check", "pdf/dirty"))
    check("list names the recorded suites", sh(stamp, "list", cwd=mono) == "pdf/suite")
    open(os.path.join(mono, "apps/other.txt"), "a").write("changed\n")
    sh("git", "commit", "-q", "-am", "outside apps/pdf", cwd=mono, env=git_identity())
    check("a commit outside the app's sources keeps its stamps", ok("check", "pdf/suite"))
    open(os.path.join(mono, "apps/pdf/portable/readme.md"), "a").write("changed\n")
    sh("git", "commit", "-q", "-am", "inside apps/pdf", cwd=mono, env=git_identity())
    check("a commit inside them does not", not ok("check", "pdf/suite"))


def test_source_tag(mono, remote, previous):
    log = os.path.join(TMP, "publish.log")
    commit = sh("git", "rev-parse", "HEAD", cwd=mono)
    source = common.push_source_tag(mono, "apps/pdf", commit, "casimir-engineering/shenzhen-pdf", "26.10.20-99", log)
    tree = sh("git", "rev-parse", f"{commit}:apps/pdf", cwd=mono)
    check("the release repository's tag holds apps/pdf of the commit",
          sh("git", "rev-parse", "26.10.20-99^{tree}", cwd=remote) == tree)
    check("its parent is the previous release tag's commit",
          sh("git", "rev-parse", "26.10.20-99^", cwd=remote) == previous)
    check("its message names the commit", commit in sh("git", "log", "-1", "--format=%B", "26.10.20-99", cwd=remote))
    check("pushing it again is accepted as done",
          common.push_source_tag(mono, "apps/pdf", commit, "casimir-engineering/shenzhen-pdf", "26.10.20-99",
                                 log) == source)
    check("the default branch is untouched", sh("git", "rev-parse", "master", cwd=remote) == previous)


def test_publish():
    log = os.path.join(TMP, "publish.log")
    notes = os.path.join(TMP, "notes.md")
    open(notes, "w").write("- A highlight\n\n---\n\nDetails.\n")
    files = [os.path.join(TMP, "ShenzhenPDF-mac-arm64.dmg"), os.path.join(TMP, "extra.json")]
    open(files[0], "wb").write(os.urandom(4096))
    open(files[1], "w").write("{}\n")
    slug = "casimir-engineering/shenzhen-pdf"
    release = common.publish_release(slug, "26.10.20-99", title="26.10.20-99", notes_file=notes, files=files,
                                     prerelease=False, latest=True, log=log)
    state = json.load(open(os.environ["FAKE_GH_STATE"]))
    calls = [" ".join(c) for c in state["calls"]]
    check("the release is published", release["draft"] is False and release["tag_name"] == "26.10.20-99")
    check("it was a draft until its assets were checked",
          any("--method POST" in c for c in calls) and
          calls.index(next(c for c in calls if '--method PATCH' in c)) > calls.index(
              next(c for c in calls if c.startswith("release upload"))))
    check("every asset uploaded, digests checked, nothing downloaded",
          sum(c.startswith("release upload") for c in calls) == 2 and not any("download" in c for c in calls))
    count = len(state["calls"])
    common.publish_release(slug, "26.10.20-99", title="26.10.20-99", notes_file=notes, files=files,
                           prerelease=False, latest=True, log=log)
    state = json.load(open(os.environ["FAKE_GH_STATE"]))
    check("publishing again with the same bytes uploads nothing",
          not any(" ".join(c).startswith("release upload") for c in state["calls"][count:]))
    open(files[0], "wb").write(os.urandom(4096))
    try:
        common.publish_release(slug, "26.10.20-99", title="26.10.20-99", notes_file=notes, files=files,
                               prerelease=False, latest=True, log=log)
        check("other bytes for a published release stop the run", False)
    except common.Failure:
        check("other bytes for a published release stop the run", True)


def fake_asar(path, files):
    """An app.asar holding `files` ({name or dir/name: bytes})."""
    tree, blob = {"files": {}}, b""
    for name, data in files.items():
        node = tree
        for part in name.split("/")[:-1]:
            node = node["files"].setdefault(part, {"files": {}})
        node["files"][name.split("/")[-1]] = {"size": len(data), "offset": str(len(blob))}
        blob += data
    header = json.dumps(tree).encode()
    header += b"\0" * ((4 - len(header) % 4) % 4)
    pickle = struct.pack("<II", len(header) + 4, len(json.dumps(tree).encode())) + header
    with open(path, "wb") as f:
        f.write(struct.pack("<II", 4, len(pickle)) + pickle + blob)


def fake_version_info(version):
    """Bytes holding a VERSIONINFO ProductVersion string, as a Windows executable's resources do."""
    key, value = "ProductVersion".encode("utf-16-le") + b"\0\0", (version + "\0").encode("utf-16-le")
    body = key + b"\0" * ((4 - (6 + len(key)) % 4) % 4) + value
    return b"MZ" + b"\0" * 62 + struct.pack("<HHH", 6 + len(body), len(version) + 1, 1) + body


def fake_rpm(path, version):
    def header(entries):
        index, store = b"", b""
        for tag, value in entries:
            index += struct.pack(">IIII", tag, 6, len(store), 1)
            store += value.encode() + b"\0"
        return b"\x8e\xad\xe8\x01\0\0\0\0" + struct.pack(">II", len(entries), len(store)) + index + store
    signature = header([])
    signature += b"\0" * ((8 - len(signature) % 8) % 8)
    with open(path, "wb") as f:
        f.write(b"\xed\xab\xee\xdb" + b"\0" * 92 + signature + header([(1000, "shenzhen-3d"), (1001, version)]))


def fake_deb(path, version):
    control = io.BytesIO()
    with tarfile.open(fileobj=control, mode="w:gz") as tar:
        data = f"Package: shenzhen-3d\nVersion: {version}\n".encode()
        info = tarfile.TarInfo("./control")
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
    out = b"!<arch>\n"
    for name, data in (("debian-binary", b"2.0\n"), ("control.tar.gz", control.getvalue())):
        out += f"{name:<16}{0:<12}{0:<6}{0:<6}{100644:<8}{len(data):<10}`\n".encode() + data + b"\n" * (len(data) % 2)
    open(path, "wb").write(out)


def shows(read, version, *args):
    """True when the artifact `read` reads shows `version` everywhere (displayed.require passes)."""
    try:
        displayed.require("test", version, read(*args))
        return True
    except common.Failure:
        return False


def test_displayed():
    folder = os.path.join(TMP, "displayed")
    os.makedirs(folder)
    page = lambda v: f'<html><head><meta name="shenzhen-3d-version" content="{v}"></head></html>'.encode()  # noqa: E731

    def mac_app(name, short, package, page_version):
        app = os.path.join(folder, name, "Shenzhen 3D.app")
        os.makedirs(os.path.join(app, "Contents/Resources"))
        plistlib.dump({"CFBundleShortVersionString": short}, open(os.path.join(app, "Contents/Info.plist"), "wb"))
        fake_asar(os.path.join(app, "Contents/Resources/app.asar"),
                  {"package.json": json.dumps({"version": package}).encode(), "dist/index.html": page(page_version)})
        return app

    check("a Mac app that shows 0.2.3 everywhere passes",
          shows(displayed.mac_electron_app, "0.2.3", mac_app("good", "0.2.3", "0.2.3", "0.2.3")))
    # The Android test installs before 0.2.2: the app said 0.2.2 while the page, built from package.json, said 0.2.1.
    check("a page built as another version stops the release",
          not shows(displayed.mac_electron_app, "0.2.3", mac_app("stale-page", "0.2.3", "0.2.3", "0.2.2")))
    check("an app.asar of another version stops the release",
          not shows(displayed.mac_electron_app, "0.2.3", mac_app("stale-asar", "0.2.3", "0.2.2", "0.2.3")))
    web = os.path.join(folder, "web.zip")
    with zipfile.ZipFile(web, "w") as z:
        z.writestr("index.html", b"<html></html>")
    check("a page with no version stops the release", not shows(displayed.web_zip, "0.2.3", web))
    ipa = os.path.join(folder, "app.ipa")
    with zipfile.ZipFile(ipa, "w") as z:
        z.writestr("Payload/Shenzhen 3D.app/Info.plist", plistlib.dumps({"CFBundleShortVersionString": "0.2.2"}))
    check("an iOS build of another version stops the release", not shows(displayed.ios_ipa, "0.2.3", ipa))
    check("the iOS build's own version passes", shows(displayed.ios_ipa, "0.2.2", ipa))
    exe = os.path.join(folder, "setup.exe")
    open(exe, "wb").write(fake_version_info("0.2.3"))
    check("a Windows installer's ProductVersion is read", displayed.windows_installer(exe) == [("ProductVersion",
                                                                                               "0.2.3")])
    deb, rpm = os.path.join(folder, "app.deb"), os.path.join(folder, "app.rpm")
    fake_deb(deb, "0.2.3")
    fake_rpm(rpm, "0.2.3")
    check("a .deb's version is read", displayed.deb_version(deb) == "0.2.3")
    check("an .rpm's version is read", displayed.rpm_version(rpm) == "0.2.3")
    check("badging's versionName is read",
          displayed.android_badging("package: name='x' versionCode='2016' versionName='0.2.3'") == [("versionName",
                                                                                                    "0.2.3")])
    pdf = os.path.join(folder, "ShenzhenPDF.app")
    os.makedirs(os.path.join(pdf, "Contents"))
    plistlib.dump({"CFBundleShortVersionString": "26.10.20", "CFBundleVersion": "8", "SZFReleaseTag": "26.10.20-1"},
                  open(os.path.join(pdf, "Contents/Info.plist"), "wb"))
    check("ShenzhenPDF shows its release tag, not its build", shows(displayed.mac_release_app, "26.10.20-1", pdf))
    check("a release tag other than the release stops it", not shows(displayed.mac_release_app, "26.10.25-1", pdf))


def main():
    try:
        mono, remote, previous = setup()
        test_stages()
        test_interrupted_command()
        test_tests_leave_apps_alone()
        test_test_stamps(mono)
        test_source_tag(mono, remote, previous)
        test_publish()
        test_displayed()
    finally:
        shutil.rmtree(TMP, ignore_errors=True)
    print(f"{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
