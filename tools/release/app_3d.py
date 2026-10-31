"""Shenzhen 3D: apps/3d, released on <owner>/shenzhen-3D as preview-<version> (or v<version>) with the Electron Mac
app's DMG, ZIP, their blockmaps and latest-mac.yml, which the updater reads; with --platforms all also the Tauri builds
for Windows, Linux, Android and iOS and the web build; with --private-copy a second copy for the owner named by
SHENZHEN_3D_MIRROR_OWNER, built from a derived tree."""
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import time
import zipfile

import displayed
from base import Release
from common import (CACHE, IDENTITY, PROFILE, TEAM_ID, TEAM_REQUIREMENT, Failure, app_from_dmg, download_asset,
                    end_test_processes, gh_api, git, notarize, prepare_worktree, publish_release,
                    push_source_tag, retry, run, say, sha256)
from jobs import Job, graph, raise_first
from macshared import gatekeeper_window, push_monorepo_tag, write_json

OWNER = "casimir-engineering"
# The phone builds are not on the release's longest path (the Mac app's packaging and notarization are): they yield
# the cores to it.
PHONE_NICE = 10
APP = "Shenzhen 3D.app"


def file_name(version, ext):
    return f"Shenzhen-3D-{version}-Apple-Silicon.{ext}"


class ThreeDRelease(Release):
    app = "3d"
    title = "Shenzhen 3D"
    order = ("build", "platforms", "package", "sign", "notarize", "staple", "verify", "publish", "live-check")
    before_notarize = ("build", "package", "sign")
    stage_load = {"build": (4, 4), "package": (6, 4), "sign": (1, 1), "staple": (2, 2)}
    # The suites start once the app is packaged, beside notarization: packaging rebuilds the Friends addon that
    # test:friends loads, in the same tree.
    tests_after = "package"
    # The other platforms use only the build (node_modules, the frontend): packaging the Mac app again keeps them.
    needs = {"platforms": ["build"], "package": ["build"], "sign": ["package"], "notarize": ["sign"],
             "staple": ["notarize"], "verify": ["staple", "platforms"], "publish": ["verify"],
             "live-check": ["publish"]}

    def parse_version(self, version):
        m = re.fullmatch(r"(preview-|v)?(\d+\.\d+\.\d+)", version)
        if not m:
            raise Failure(f"a Shenzhen 3D version reads preview-X.Y.Z, vX.Y.Z or X.Y.Z, not {version}")
        self.version = m.group(2)
        self.tag = (m.group(1) or "preview-") + self.version
        self.prerelease = self.tag.startswith("preview-")
        mirror = os.environ.get("SHENZHEN_3D_MIRROR_OWNER", "").strip()
        self.owners = [OWNER] + ([mirror] if self.opts.private_copy else [])
        if self.opts.private_copy:
            for name in ("SHENZHEN_3D_MIRROR_OWNER", "SHENZHEN_3D_PRIVATE_RULES", "SHENZHEN_3D_MIRROR_AUTHOR"):
                if not os.environ.get(name):
                    raise Failure(f"--private-copy needs {name} (docs/RELEASING.md, Shenzhen 3D)")
        self.mirror = mirror or None

    def committed_version(self):
        pkg = json.loads(git(self.repo, "show", f"{self.commit}:apps/3d/package.json"))
        return ("preview-" if self.tag.startswith("preview-") else "v") + pkg["version"]

    def notes_path(self, tag):
        return os.path.join(self.repo, "apps/3d/docs", f"MAC-{tag.split('-', 1)[-1].lstrip('v')}.md")

    # ---- trees: the public one, and the private copy derived from it ----------------------------------------------

    def tree(self, owner):
        return self.wt if owner == OWNER else self.wt + "-private"

    def app_dir(self, owner):
        return os.path.join(self.tree(owner), "apps/3d")

    def derive_private(self, log):
        """The private copy: the build worktree at this commit with SHENZHEN_3D_PRIVATE_RULES applied to apps/3d's text
        files (lines `old==>new`, or `regex:pattern==>new`, in order) and PRIVATE_RELEASE_OWNER naming the mirror's
        owner, committed locally (never pushed) with the source commit's dates, so the same commit derives the same
        tree and its build counts as clean."""
        tree = self.tree(self.mirror)
        prepare_worktree(self.repo, tree, self.commit, log)
        rules = []
        for line in open(os.environ["SHENZHEN_3D_PRIVATE_RULES"], "rb").read().splitlines():
            if not line.strip():
                continue
            lhs, _, rhs = line.partition(b"==>")
            if lhs.startswith(b"regex:"):
                rules.append((re.compile(lhs[6:]), rhs))
            else:
                rules.append((re.compile(re.escape(lhs)), rhs.replace(b"\\", b"\\\\")))
        root = os.path.join(tree, "apps/3d")
        for folder, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if d not in ("node_modules", ".git", "artifacts", "dist", "target")]
            for name in files:
                path = os.path.join(folder, name)
                if os.path.islink(path):
                    continue
                data = open(path, "rb").read()
                if b"\0" in data[:8192]:
                    continue
                new = data
                for pattern, replacement in rules:
                    new = pattern.sub(replacement, new)
                if new != data:
                    open(path, "wb").write(new)
        channel = os.path.join(root, "electron/release-channel.cjs")
        text = open(channel).read()
        if "const PRIVATE_RELEASE_OWNER = null;" not in text:
            raise Failure("electron/release-channel.cjs no longer sets PRIVATE_RELEASE_OWNER = null")
        open(channel, "w").write(text.replace("const PRIVATE_RELEASE_OWNER = null;",
                                              f'const PRIVATE_RELEASE_OWNER = "{self.mirror}";'))
        name, email = re.fullmatch(r"\s*(.*?)\s*<([^>]+)>\s*", os.environ["SHENZHEN_3D_MIRROR_AUTHOR"]).groups()
        date = git(self.repo, "log", "-1", "--format=%aI", self.commit)
        env = {"GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email, "GIT_COMMITTER_NAME": name,
               "GIT_COMMITTER_EMAIL": email, "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date}
        run(["git", "-C", tree, "add", "-A", "apps/3d"], log=log)
        run(["git", "-C", tree, "commit", "--quiet", "--no-verify", "-m", self.tag], env=env, log=log)
        return tree

    def node_modules(self, owner, log, app_dir=None):
        """node_modules for package-lock.json, cloned (APFS copy-on-write) from the cache when another worktree or run
        installed the same lock already; otherwise npm ci from npm's own cache, and kept for the next."""
        app_dir = app_dir or self.app_dir(owner)
        lock = hashlib.sha256(open(os.path.join(app_dir, "package-lock.json"), "rb").read()).hexdigest()[:16]
        modules = os.path.join(app_dir, "node_modules")
        marker = os.path.join(modules, ".shenzhen-lock")
        if os.path.isfile(marker) and open(marker).read().strip() == lock:
            return
        cached = os.path.join(CACHE, "node_modules", f"3d-{lock}", "node_modules")
        shutil.rmtree(modules, ignore_errors=True)
        if os.path.isfile(os.path.join(cached, ".shenzhen-lock")):
            run(["cp", "-c", "-R", cached, modules], log=log)
            run(["npm", "run", "prepare:assets"], cwd=app_dir, log=log)
            return
        run(["npm", "ci", "--prefer-offline", "--no-audit", "--no-fund"], cwd=app_dir, log=log)
        with open(marker, "w") as f:
            f.write(lock + "\n")
        shutil.rmtree(os.path.dirname(cached), ignore_errors=True)
        os.makedirs(os.path.dirname(cached))
        run(["cp", "-c", "-R", modules, cached], log=log)

    def original(self, owner):
        return os.path.join(self.app_dir(owner), "artifacts/electron", f"release-{self.tag}-{owner}-{self.short}")

    def notarized(self, owner):
        return os.path.join(self.app_dir(owner), "artifacts/electron",
                            f"release-{self.tag}-{owner}-notarized-{self.short}")

    def final_files(self, owner):
        folder = self.notarized(owner)
        names = [file_name(self.version, e) for e in ("dmg", "zip")]
        return [os.path.join(folder, n) for n in names + [n + ".blockmap" for n in names] +
                ["latest-mac.yml", "build-info.json"]]

    # ---- stages ------------------------------------------------------------------------------------------------

    def build(self):
        """node_modules (by lock), the Friends helper and the client addon built from apps/pdf in the same tree, and
        the frontend (dist/, npm run build, showing this version): packaging and every other platform use this one
        build of it, so nothing rewrites dist/ while they read it."""
        log = self.log("build")
        files = []
        for owner in self.owners:
            if owner != OWNER:
                self.derive_private(log)
            self.node_modules(owner, log)
            run(["scripts/friends/setup-friends.sh"], cwd=self.app_dir(owner), env={"MAKEFLAGS": None}, log=log)
            run(["npm", "run", "build"], cwd=self.app_dir(owner), env={"SHENZHEN_3D_VERSION": self.version}, log=log)
            files.append(os.path.join(self.app_dir(owner), "dist", "index.html"))
        return {"files": files}

    def package(self):
        """electron/package-mac.mjs per owner: the frontend build, the native addons, the signed app (Developer ID,
        hardened runtime), its ZIP and its DMG (recompressed as LZMA), checked against the feed."""
        log = self.log("package")
        files = []
        for owner in self.owners:
            out = self.original(owner)
            shutil.rmtree(out, ignore_errors=True)
            stale = glob.glob(os.path.join(self.app_dir(owner), "artifacts/electron", "*"))
            for folder in stale:
                if os.path.basename(folder).startswith("release-") and self.short not in folder:
                    shutil.rmtree(folder, ignore_errors=True)
            forbid = [f"--forbid-owner={o}" for o in {OWNER, self.mirror} - {owner, None}]
            # SZF_PARALLEL_CODESIGN: electron-builder's seven hundred signatures several at once
            # (electron/codesign-parallel.py): three minutes of waiting on Apple's timestamp server becomes forty
            # seconds; the same signatures.
            run(["node", "electron/package-mac.mjs", f"--release-owner={owner}", *forbid, "--frontend-built",
                 f"--version={self.version}", f"--output={out}"], cwd=self.app_dir(owner),
                env={"SZF_PARALLEL_CODESIGN": "1"}, log=log, stamp=True)
            files += [os.path.join(out, file_name(self.version, e)) for e in ("zip", "dmg")]
        return {"files": files}

    def sign(self):
        """electron-builder signed while packaging; this checks every owner's app and its Friends helper."""
        log = self.log("sign")
        for owner in self.owners:
            app = os.path.join(self.original(owner), "mac-arm64", APP)
            run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app], log=log)
            for item in (app, os.path.join(app, "Contents/Helpers/Shenzhen Friends.app")):
                run(["codesign", "--verify", "--strict", f"-R={TEAM_REQUIREMENT}", item], log=log)
        return {"files": [os.path.join(self.original(o), file_name(self.version, e))
                          for o in self.owners for e in ("zip", "dmg")]}

    def notarize(self):
        """Every owner's DMG, submitted together. Apple's ticket for a DMG covers the app inside it, so the app staples
        from it and the ZIP the updater downloads, made again from the stapled app, needs no upload of its own."""
        paths = [os.path.join(self.original(o), file_name(self.version, "dmg")) for o in self.owners]
        result = notarize(paths, os.path.join(self.run_dir, "notary.json"), self.log("notarize"))
        return {"files": paths, "submissions": {p: r["id"] for p, r in result.items()}}

    def staple(self):
        """electron/notarize-finalize.mjs per owner: the app stapled and zipped again for the updater, the original DMG
        stapled, blockmaps and latest-mac.yml for the final bytes, every artifact checked."""
        log = self.log("staple")
        submissions = self.stages.cached("notarize")["result"]["submissions"]
        files = []
        for owner in self.owners:
            original, out = self.original(owner), self.notarized(owner)
            shutil.rmtree(out, ignore_errors=True)
            os.makedirs(out)
            common = ["node", "electron/notarize-finalize.mjs", f"--original={original}", f"--output={out}",
                      f"--profile={PROFILE}"]
            dmg_id = submissions[os.path.join(original, file_name(self.version, "dmg"))]
            for phase in (["--phase=package", f"--dmg-submission={dmg_id}", "--dmg-from-original"],
                          ["--phase=verify-zip"], ["--phase=finalize", f"--dmg-submission={dmg_id}"]):
                run(common + phase, cwd=self.app_dir(owner), log=log)
            files += self.final_files(owner)
        return {"files": files}

    SUITES = (("3d/unit", ["npm", "test"]), ("3d/electron", ["npm", "run", "test:electron"]),
              ("3d/friends", ["npm", "run", "test:friends"]),
              # The owner's relay rule, release-blocking for every app that embeds the helper (ADR 0020).
              ("3d/friends-relay-rule", ["make", "-C", "../pdf/portable", "friends-relay-rule-check"]))
    # test:electron and test:friends start Electron copies of their own; while they run, the unified log can show a
    # Gatekeeper rejection ("Terminating process due to Gatekeeper rejection"), which fails any updater test running
    # at the same time (seen twice when the apps were released at once): they never overlap one.
    suite_locks = {"3d/electron": ("gatekeeper",), "3d/friends": ("gatekeeper", "friends-build"),
                   "3d/friends-relay-rule": ("friends-build",)}

    def tests(self):
        names = [n for n, _ in self.SUITES]
        missing = self.missing(names)
        say(f"tests: {len(names) - len(missing)} of {len(names)} suites passed on this commit already"
            + (f"; running {len(missing)}" if missing else ""))
        folder = os.path.join(self.logs, "tests")
        os.makedirs(folder, exist_ok=True)
        return self.run_suites([(name, cmd) for name, cmd in self.SUITES if name in missing], self.app_dir(OWNER),
                               {"MAKEFLAGS": None}, folder)

    def sign_for_test(self, app, log):
        """Signs a test copy inside out with the Developer ID, as the release is signed: the Friends helper on its own
        without entitlements, then every other Mach-O and bundle deepest first, executables and apps with
        electron-builder's entitlements. Squirrel checks the update against this signature, as it does for people."""
        entitlements = os.path.join(self.app_dir(OWNER), "node_modules/app-builder-lib/templates/entitlements.mac.plist")
        helper = os.path.join(app, "Contents/Helpers/Shenzhen Friends.app")

        def macho(path):
            with open(path, "rb") as f:
                return f.read(4) in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe")

        def main_executable(path):
            """Signed with its bundle: an app's CFBundleExecutable, or a framework's binary."""
            parent = os.path.dirname(path)
            if parent.endswith("/Contents/MacOS"):
                info = os.path.join(os.path.dirname(parent), "Info.plist")
                name = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleExecutable", info],
                                      capture_output=True, text=True).stdout.strip()
                return os.path.basename(path) == name
            framework = re.search(r"/([^/]+)\.framework/Versions/[^/]+$", parent)
            return bool(framework) and framework.group(1) == os.path.basename(path)

        def sign(path, ent):
            run(["codesign", "--force", "--options", "runtime", "--timestamp=none", "--sign", IDENTITY]
                + (["--entitlements", entitlements] if ent else []) + [path], log=log)

        if os.path.isdir(helper):
            sign(helper, False)
        items = []
        for folder, dirs, files in os.walk(app):
            if folder == helper or folder.startswith(helper + "/"):
                dirs[:] = []
                continue
            for name in files:
                path = os.path.join(folder, name)
                if not os.path.islink(path) and macho(path) and not main_executable(path):
                    executable = "executable" in subprocess.run(["file", "-b", path], capture_output=True,
                                                                text=True).stdout
                    items.append((path, executable))
            for name in dirs:
                path = os.path.join(folder, name)
                if name.endswith((".app", ".framework")) and path != helper:
                    items.append((path, name.endswith(".app")))
        for path, ent in sorted(items, key=lambda item: -item[0].count("/")):
            sign(path, ent)
        sign(app, True)
        run(["codesign", "--verify", "--deep", "--strict", app], log=log)

    def previous(self, owner, log):
        listing = gh_api(f"repos/{owner}/shenzhen-3D/releases?per_page=30", log=log)
        previous = next((r for r in listing if not r.get("draft") and r.get("tag_name") != self.tag), None)
        if not previous:
            raise Failure(f"{owner}/shenzhen-3D has no release before {self.tag}")
        tag = previous["tag_name"]
        version = tag.split("-", 1)[-1].lstrip("v")
        folder = os.path.join(CACHE, "releases", f"{owner}/shenzhen-3D", tag)
        dmg = download_asset(f"{owner}/shenzhen-3D", previous, file_name(version, "dmg"), folder, log)
        app = app_from_dmg(dmg, os.path.join(folder, "app"), APP, log)
        return {"tag": tag, "app": app, "listing": listing}

    def update_test(self, owner, stage, listing_override=None, live=False):
        log = self.log(stage)
        work_root = os.path.join(self.run_dir, "updater-e2e", f"{stage}-{owner}-{time.strftime('%H%M%S')}")
        os.makedirs(work_root)
        old = self.previous(owner, log)
        listing = listing_override or [r for r in old["listing"] if r.get("tag_name") != self.tag]
        shape = write_json(os.path.join(work_root, "releases.json"), listing)
        app_dir = self.app_dir(owner)
        fixture = run(["node", os.path.join(self.wt, "tools/updater-e2e/prep-3d-fixture.mjs"), old["app"],
                       os.path.join(work_root, "fixture")], cwd=app_dir, log=log, capture=True).strip().splitlines()[-1]
        self.sign_for_test(fixture, log)
        candidate = os.path.join(self.notarized(owner), "mac-arm64", APP)
        relaunch = run(["node", os.path.join(self.wt, "tools/updater-e2e/prep-3d-fixture.mjs"), candidate,
                        os.path.join(work_root, "relaunch")], cwd=app_dir, log=log, capture=True).strip().splitlines()[-1]
        self.sign_for_test(relaunch, log)
        access = "public" if owner == OWNER else "private"
        notes = self.notes() if owner == OWNER else self.private_notes()
        with gatekeeper_window(cpus=4):
            say(f"{stage}: {owner}'s {old['tag']} updates to {self.tag} (tools/updater-e2e)")
            try:
                code = run(["node", os.path.join(self.wt, "tools/updater-e2e/update-e2e-3d.mjs"), f"--owner={owner}",
                            f"--fixture={fixture}", f"--artifacts={self.notarized(owner)}", f"--shape={shape}",
                            f"--notes={notes}", f"--work={os.path.join(work_root, 'run')}",
                            f"--expect-access={access}", f"--relaunch-app={relaunch}"] + (["--live"] if live else []),
                           cwd=app_dir, log=log, check=False)
            finally:
                end_test_processes(work_root, log)
        if code != 0:
            raise Failure(f"{owner}: updating from {old['tag']} to {self.tag} failed: "
                          f"{os.path.join(work_root, 'run', 'result.json')}")

    def private_notes(self):
        """The release notes with the private copy's rules applied, as its tree has them."""
        path = os.path.join(self.run_dir, "notes-private.md")
        if not os.path.exists(path):
            derived = self.notes_path(self.tag).replace(self.repo, self.tree(self.mirror))
            shutil.copyfile(derived if os.path.isfile(derived) else self.notes(), path)
        return path

    def check_displayed_versions(self):
        """Every build this run made shows self.version, read from the build itself (displayed.py says where): the
        Mac app per owner, and with --platforms all the web build, the APK, both iOS builds and the Windows and Linux
        installers."""
        for owner in self.owners:
            app = os.path.join(self.notarized(owner), "mac-arm64", APP)
            displayed.require(f"{owner}'s Mac app", self.version, displayed.mac_electron_app(app))
        if self.opts.platforms != "all":
            return
        out, v = os.path.join(self.out, "platforms"), self.version
        badging = lambda path: displayed.android_badging(  # noqa: E731
            run([self.android_tool("aapt2"), "dump", "badging", path], log=self.log("verify"), capture=True))
        checks = {
            f"shenzhen-3d-{v}-web.zip": displayed.web_zip,
            f"shenzhen-3d-{v}-android-arm64-development.apk": badging,
            f"shenzhen-3d-{v}-ios-arm64-simulator.tar.gz": displayed.ios_simulator_tar,
            f"shenzhen-3d-{v}-ios-registered-devices.ipa": displayed.ios_ipa,
            f"Shenzhen-3D-{v}-Windows-x64-Setup.exe": displayed.windows_installer,
            f"Shenzhen-3D-{v}-Windows-x64.msi": lambda path: displayed.windows_msi(
                path, os.path.join(self.run_dir, "displayed", "msi")),
            f"Shenzhen-3D-{v}-Linux-arm64.deb": lambda path: [("Version", displayed.deb_version(path))],
            f"Shenzhen-3D-{v}-Linux-arm64.rpm": lambda path: [("Version", displayed.rpm_version(path))],
        }
        for name, read in checks.items():
            if not os.path.isfile(os.path.join(out, name)):
                raise Failure(f"{name} is missing from {out}")
            displayed.require(name, v, read(os.path.join(out, name)))
        say(f"verify: every build shows {v}")

    def verify(self):
        self.check_displayed_versions()
        for owner in self.owners:
            self.update_test(owner, "verify")
        return {"files": [f for o in self.owners for f in self.final_files(o)]}

    # The Parallels VMs' settings for scripts/friends/tauri-vm.sh, per VM: the release Mac's own guests, with what
    # each one keeps for building. SZF_VM_LINUX_<NAME> and SZF_VM_WINDOWS_<NAME> in the environment override them
    # (SZF_VM_LINUX_ENV for SZF_VM_ENV, and so on).
    VMS = {
        "linux": ("linux-vm", "Ubuntu 24.04 (with Rosetta)", "package", {
            "SZF_VM_ENV": "/opt/shenzhen3d-build-0.1.9-4f7dbf54/environment.sh",
            "SZF_VM_TAURI_CLI": "/opt/shenzhen3d-build-0.1.9-4f7dbf54/source/node_modules",
            "SZF_VM_AS_ROOT": "1"}),
        "windows": ("windows-vm", "Windows 11", "installers", {
            "SZF_VM_NODE": r"C:\Shenzhen3D-build-0.1.9-4f7dbf54\tools\node-v24.22.0-win-arm64\node.exe",
            "SZF_VM_TAURI_CLI": r"C:\Shenzhen3D-build-0.1.9-4f7dbf54\source\node_modules",
            "SZF_VM_TARGET": "x86_64-pc-windows-msvc"}),
    }
    # The Android debug key every published APK is signed with (docs/UPDATES.md, Android): an APK signed with another
    # key cannot update the installed app.
    ANDROID_CERT = "3cba6bd5760eed14ae08b4c911b49aea18a8ae17d61722554b67f9c2c12e04ad"

    def vm_env(self, kind, keep):
        _, _, _, defaults = self.VMS[kind]
        env = {"SZF_VM_KEEP": keep}
        for name, value in defaults.items():
            env[name] = os.environ.get(name.replace("SZF_VM_", f"SZF_VM_{kind.upper()}_"), value)
        return env

    def vendor(self, log):
        """The crates the Linux guest builds from (its clock may be off, which fails crates.io's certificate): one
        `cargo vendor` of the app's Friends build, the core and the plugin (host-build.sh vendor), kept in the cache by
        the Friends lock's content."""
        app_dir = self.app_dir(OWNER)
        lock = os.path.join(app_dir, "src-tauri/friends/Cargo.lock")
        key = hashlib.sha256(open(lock, "rb").read()).hexdigest()[:16]
        out = os.path.join(CACHE, "cargo-vendor", f"3d-{key}")
        if os.path.isfile(os.path.join(out, ".complete")):
            return out
        shutil.rmtree(out, ignore_errors=True)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        host_build = os.path.join(self.wt, "apps/pdf/portable/friends/tauri/tools/host-build.sh")
        run(["bash", host_build, "vendor", os.path.join(app_dir, "src-tauri"), lock, out], log=log)
        open(os.path.join(out, ".complete"), "w").close()
        return out

    def android_tool(self, name):
        """A tool from the Android SDK's newest build-tools."""
        sdk = os.environ.get("ANDROID_HOME") or os.path.expanduser("~/Library/Android/sdk")
        tools = os.path.join(sdk, "build-tools")
        version = sorted((d for d in os.listdir(tools) if d[:1].isdigit()),
                         key=lambda d: [int(x) if x.isdigit() else 0 for x in re.split(r"[.-]", d)])[-1]
        return os.path.join(tools, version, name)

    def android(self, app_dir, out, cargo_env, no_frontend, log):
        """The release APK and AAB, the native library stripped; the APK aligned for 16 KB pages and signed with the
        Android debug key every published APK carries, then checked: that key, this version and versionCode."""
        # Gradle and apksigner need a JDK (17, docs/PLATFORMS.md); macOS has none of its own.
        java = os.environ.get("JAVA_HOME")
        if not java:
            jdks = [p for p in ("/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home",
                                "/Applications/Android Studio.app/Contents/jbr/Contents/Home")
                    if os.path.isfile(os.path.join(p, "bin/java"))]
            if not jdks:
                raise Failure("no JDK for the Android build: set JAVA_HOME (JDK 17)")
            java = jdks[0]
        java_env = {"JAVA_HOME": java, "PATH": os.path.join(java, "bin") + os.pathsep + os.environ["PATH"]}
        outputs = os.path.join(app_dir, "src-tauri/gen/android/app/build/outputs")
        shutil.rmtree(outputs, ignore_errors=True)
        run(["node", "scripts/platform-build.mjs", "android", "--friends", "--apk", "--aab", "--target", "aarch64",
             "--ci", "--config", no_frontend], cwd=app_dir,
            env={**cargo_env, **java_env, "CARGO_PROFILE_RELEASE_STRIP": "symbols"}, log=log,
            nice=PHONE_NICE)
        apk = sorted(glob.glob(os.path.join(outputs, "apk/**/*-release-unsigned.apk"), recursive=True))
        aab = sorted(glob.glob(os.path.join(outputs, "bundle/**/*.aab"), recursive=True))
        if len(apk) != 1 or len(aab) != 1:
            raise Failure(f"the Android build left {len(apk)} unsigned APKs and {len(aab)} AABs under {outputs}")
        tool = self.android_tool
        keystore = os.path.expanduser("~/.android/debug.keystore")
        aligned = os.path.join(self.run_dir, "android-aligned.apk")
        signed = os.path.join(out, f"shenzhen-3d-{self.version}-android-arm64-development.apk")
        run([tool("zipalign"), "-P", "16", "-f", "4", apk[0], aligned], log=log)
        # The debug key's well-known passwords. No JAR (v1) signature: Android reads v2 and v3 from API 24, the app's
        # floor, and the v1 files were a digest of every entry (about 55 KB of the APK).
        run([tool("apksigner"), "sign", "--v1-signing-enabled", "false", "--ks", keystore, "--ks-pass", "pass:android",
             "--ks-key-alias", "androiddebugkey", "--key-pass", "pass:android", "--out", signed, aligned], env=java_env,
            log=log)
        os.remove(aligned)
        for leftover in glob.glob(signed + ".idsig"):
            os.remove(leftover)
        certs = run([tool("apksigner"), "verify", "--print-certs", signed], env=java_env, log=log, capture=True)
        if f"SHA-256 digest: {self.ANDROID_CERT}" not in certs:
            raise Failure(f"{signed} is not signed with the Android debug key the published APKs carry")
        badging = run([tool("aapt2"), "dump", "badging", signed], log=log, capture=True)
        m = re.search(r"versionCode='(\d+)' versionName='([^']+)'", badging)
        if not m or m.group(2) != self.version:
            raise Failure(f"{signed} says {m.groups() if m else 'no version'}, not {self.version}")
        say(f"platforms: Android {self.version} (versionCode {m.group(1)}), signed with the debug key")
        shutil.copyfile(aab[0], os.path.join(out, f"shenzhen-3d-{self.version}-android-arm64-unsigned.aab"))

    def ios_simulator(self, app_dir, out, cargo_env, no_frontend, log):
        """The simulator app, as a tar.gz that keeps its modes."""
        build = os.path.join(app_dir, "src-tauri/gen/apple/build")
        shutil.rmtree(build, ignore_errors=True)
        run(["node", "scripts/platform-build.mjs", "ios", "--friends", "--target", "aarch64-sim", "--ci",
             "--archive-only", "--config", no_frontend], cwd=app_dir, env=cargo_env("aarch64-apple-ios-sim"), log=log,
            nice=PHONE_NICE)
        sims = sorted(glob.glob(os.path.join(build, "**/*.app"), recursive=True), key=len)
        if not sims:
            raise Failure(f"the iOS Simulator build left no .app under {build}")
        run(["tar", "-czf", os.path.join(out, f"shenzhen-3d-{self.version}-ios-arm64-simulator.tar.gz"), "-C",
             os.path.dirname(sims[0]), os.path.basename(sims[0])], log=log)

    def ios_devices(self, app_dir, out, cargo_env, no_frontend, log):
        """The registered-devices .ipa, signed for development with the team's profile, which lists the devices it
        installs on."""
        build = os.path.join(app_dir, "src-tauri/gen/apple/build")
        shutil.rmtree(build, ignore_errors=True)
        run(["node", "scripts/platform-build.mjs", "ios", "--friends", "--target", "aarch64", "--ci",
             "--export-method", "debugging", "--config", no_frontend], cwd=app_dir,
            env={**cargo_env("aarch64-apple-ios"), "APPLE_DEVELOPMENT_TEAM": TEAM_ID}, log=log, nice=PHONE_NICE)
        ipas = glob.glob(os.path.join(build, "**/*.ipa"), recursive=True)
        if len(ipas) != 1:
            raise Failure(f"the iOS device build left {len(ipas)} .ipa files under {build}")
        shutil.copyfile(ipas[0], os.path.join(out, f"shenzhen-3d-{self.version}-ios-registered-devices.ipa"))

    # The guest directories tauri-vm.sh keeps between releases (SZF_VM_PERSIST): the tree, synced by what changed,
    # and cargo's output, so a release compiles only what changed since the last one.
    VM_PERSIST = {"linux": "/var/tmp/szf3d-release", "windows": "C:\\szf3d-release"}

    def phone_tree(self, name, log):
        """A worktree of its own for a phone build (Android, iOS), at this commit, with node_modules and this run's
        dist/: platform-build.mjs swaps src-tauri/Cargo.lock and the generated projects' files while it builds, so two
        builds never share a tree. Kept in the cache between releases with their Gradle and Xcode output."""
        tree = os.path.join(CACHE, "worktrees", f"3d-{name}")
        prepare_worktree(self.repo, tree, self.commit, log)
        app_dir = os.path.join(tree, "apps/3d")
        self.node_modules(OWNER, log, app_dir=app_dir)
        dist = os.path.join(app_dir, "dist")
        shutil.rmtree(dist, ignore_errors=True)
        run(["cp", "-c", "-R", os.path.join(self.app_dir(OWNER), "dist"), dist], log=log)
        return app_dir

    def vm_build(self, kind, keep, vendor, log):
        """The Linux or Windows installers in their Parallels VM: one that was suspended is resumed for the build and
        suspended after, one already running stays running."""
        app_dir = self.app_dir(OWNER)
        platform, vm, mode, _ = self.VMS[kind]
        env = self.vm_env(kind, keep)
        env.setdefault("SZF_VM_PERSIST", os.environ.get(f"SZF_VM_{kind.upper()}_PERSIST", self.VM_PERSIST[kind]))
        if kind == "linux":
            env["SZF_VM_VENDOR"] = vendor
        was_running = run(["prlctl", "status", vm], log=log, capture=True).strip().endswith(" running")
        if not was_running:
            say(f"platforms: {vm}: resumed for the {kind} installers")
            run(["prlctl", "resume", vm], log=log, check=False)
        try:
            retry(f"platforms: {kind} installers", lambda: run(
                ["scripts/friends/tauri-vm.sh", mode, platform, os.path.join(self.wt, "apps/pdf"), vm], cwd=app_dir,
                env=env, log=log), attempts=2)
        finally:
            if not was_running:
                run(["prlctl", "suspend", vm], log=log, check=False)

    def platforms(self):
        """--platforms all: the web build, Android, the iOS Simulator app, the registered-devices .ipa, and the Linux
        and Windows installers built in the Parallels VMs by scripts/friends/tauri-vm.sh, all at once, each in a lane of
        its own (each phone build in a worktree of its own, each VM with its build kept between releases); then
        release-updates.mjs signs the Windows and Linux installers with the updater key and writes latest.json and
        manifest.plist. Files land in the run's platforms/ folder under their release names. Runs beside the Mac
        app's packaging, notarization and tests: it needs only the build."""
        out = os.path.join(self.out, "platforms")
        shutil.rmtree(out, ignore_errors=True)
        os.makedirs(out)
        v = self.version
        dist = os.path.join(self.app_dir(OWNER), "dist")
        no_frontend = write_json(os.path.join(self.run_dir, "no-frontend-build.json"),
                                 {"build": {"beforeBuildCommand": ""}})
        # Cargo's output stays in each phone build's own worktree (src-tauri/target), one Rust target each: a target
        # directory shared with another tree would not run again the build scripts that write the generated Android
        # sources (TauriActivity.kt) into the tree.
        cargo = lambda triple: {"CARGO_TARGET_DIR": None}  # noqa: E731
        keep = os.path.join(self.run_dir, "vm-installers")
        shutil.rmtree(keep, ignore_errors=True)
        os.makedirs(keep)

        def web():
            with zipfile.ZipFile(os.path.join(out, f"shenzhen-3d-{v}-web.zip"), "w", zipfile.ZIP_DEFLATED) as z:
                for folder, _, names in os.walk(dist):
                    for name in sorted(names):
                        full = os.path.join(folder, name)
                        z.write(full, os.path.relpath(full, dist))

        def android():
            log = self.log("platforms-android")
            self.android(self.phone_tree("android", log), out, cargo("aarch64-linux-android"), no_frontend, log)

        def ios_simulator():
            log = self.log("platforms-ios-simulator")
            self.ios_simulator(self.phone_tree("ios-simulator", log), out, cargo, no_frontend, log)

        def ios_devices():
            log = self.log("platforms-ios-devices")
            self.ios_devices(self.phone_tree("ios-devices", log), out, cargo, no_frontend, log)

        def vendor():
            self.vendored = self.vendor(self.log("platforms-linux"))

        # The VMs first: their builds are the longest. The phones hold three cores each (they run niced: the Mac app's
        # stages and ShenzhenPDF's suites come first), the Windows VM four of its eight.
        lanes = {
            "web": Job(web, cpus=1, mem=0.5),
            "android": Job(android, cpus=3, mem=6),
            "ios-simulator": Job(ios_simulator, cpus=3, mem=6),
            "ios-devices": Job(ios_devices, cpus=3, mem=6),
            "vendor": Job(vendor, cpus=1, mem=1, priority=-2),
            "linux": Job(lambda: self.vm_build("linux", keep, self.vendored, self.log("platforms-linux")),
                         deps=["vendor"], cpus=2, mem=3, priority=-2),
            "windows": Job(lambda: self.vm_build("windows", keep, None, self.log("platforms-windows")),
                           cpus=4, mem=16, priority=-2),
        }
        results = graph(lanes)
        for name, (ok, value, seconds) in sorted(results.items()):
            say(f"platforms: {name} {'done' if ok else 'FAILED'} in {seconds:.0f} s")
        raise_first(results)
        log = self.log("platforms")
        app_dir = self.app_dir(OWNER)
        names = {"*_x64-setup.exe": f"Shenzhen-3D-{v}-Windows-x64-Setup.exe",
                 "*_x64_en-US.msi": f"Shenzhen-3D-{v}-Windows-x64.msi",
                 "*_aarch64.AppImage": f"Shenzhen-3D-{v}-Linux-arm64.AppImage",
                 "*_arm64.deb": f"Shenzhen-3D-{v}-Linux-arm64.deb",
                 "*.aarch64.rpm": f"Shenzhen-3D-{v}-Linux-arm64.rpm"}
        for pattern, name in names.items():
            found = glob.glob(os.path.join(keep, "**", pattern), recursive=True)
            if len(found) != 1 or f"{v}" not in os.path.basename(found[0]):
                raise Failure(f"the VM builds left {found or 'no file'} for {pattern} in {keep}")
            shutil.copyfile(found[0], os.path.join(out, name))
        # What Friends needs from the Windows installers (scripts/friends/windows-installer-check.mjs): the helper
        # beside the app in both, for x64, with this tree's build stamp and no Visual C++ runtime DLL to find.
        run(["node", "scripts/friends/windows-installer-check.mjs",
             "--setup", os.path.join(out, f"Shenzhen-3D-{v}-Windows-x64-Setup.exe"),
             "--msi", os.path.join(out, f"Shenzhen-3D-{v}-Windows-x64.msi")], cwd=app_dir, log=log)
        # The updater key signs the installers the Windows and Linux apps install in place; latest.json and
        # manifest.plist announce them. The key stays where it is: release-updates.mjs reads it, nothing prints it.
        updates = os.path.join(app_dir, "scripts/updates/release-updates.mjs")
        run(["node", updates, "--dir", out, "--tag", self.tag], cwd=app_dir, log=log)
        run(["node", updates, "--verify", "--dir", out, "--tag", self.tag], cwd=app_dir, log=log)
        files = sorted(f for f in glob.glob(os.path.join(out, "*"))
                       if not f.endswith(".sig") and os.path.basename(f) != "SHA256SUMS.txt")
        return {"files": files}

    def alongside(self):
        if self.opts.platforms != "all":
            return {}
        return {"platforms": lambda: self.stages.run("platforms", self.platforms)}

    def release_files(self, owner):
        files = list(self.final_files(owner))
        if self.opts.platforms == "all" and owner == OWNER:
            # Not the .sig files (latest.json carries the signatures) nor release-updates.mjs's SHA256SUMS.txt,
            # which the one below, over every file published, replaces.
            files += sorted(f for f in glob.glob(os.path.join(self.out, "platforms", "*"))
                            if not f.endswith(".sig") and os.path.basename(f) != "SHA256SUMS.txt")
        sums = os.path.join(self.run_dir, f"SHA256SUMS-{owner}.txt")
        with open(sums, "w") as f:
            for path in files:
                f.write(f"{sha256(path)}  {os.path.basename(path)}\n")
        named = os.path.join(self.run_dir, owner, "SHA256SUMS.txt")
        os.makedirs(os.path.dirname(named), exist_ok=True)
        shutil.copyfile(sums, named)
        return files + [named]

    def publish(self):
        log = self.log("publish")
        push_monorepo_tag(self, "3d")
        urls = {}
        for owner in self.owners:
            slug = f"{owner}/shenzhen-3D"
            if owner == OWNER:
                push_source_tag(self.repo, "apps/3d", self.commit, slug, self.tag, log)
                notes = self.notes()
            else:
                derived = git(self.tree(owner), "rev-parse", "HEAD")
                push_source_tag(self.tree(owner), "apps/3d", derived, slug, self.tag, log, message=self.tag,
                                author=os.environ["SHENZHEN_3D_MIRROR_AUTHOR"])
                notes = self.private_notes()
            release = publish_release(slug, self.tag, title=f"Shenzhen 3D {self.version}", notes_file=notes,
                                      files=self.release_files(owner), prerelease=self.prerelease,
                                      latest=not self.prerelease, log=log)
            urls[owner] = release.get("html_url")
        return {"urls": urls}

    def live_check(self):
        """Once: the previous release updates to this one from GitHub itself (update-e2e-3d.mjs --live), hidden."""
        listing = gh_api(f"repos/{OWNER}/shenzhen-3D/releases?per_page=30", log=self.log("live-check"))
        if not any(r.get("tag_name") == self.tag and not r.get("draft") for r in listing):
            raise Failure(f"{OWNER}/shenzhen-3D does not list {self.tag}")
        self.update_test(OWNER, "live-check", listing_override=[r for r in listing if r.get("tag_name") != self.tag],
                         live=True)
        return {}
