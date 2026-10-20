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

from base import Release
from common import (CACHE, IDENTITY, PROFILE, TEAM_REQUIREMENT, Failure, app_from_dmg, download_asset, gh_api, git,
                    notarize, parallel, prepare_worktree, publish_release, push_source_tag, retry, run, say, sha256)
from macshared import push_monorepo_tag, write_json

OWNER = "casimir-engineering"
APP = "Shenzhen 3D.app"


def file_name(version, ext):
    return f"Shenzhen-3D-{version}-Apple-Silicon.{ext}"


class ThreeDRelease(Release):
    app = "3d"
    title = "Shenzhen 3D"
    order = ("build", "package", "sign", "notarize", "staple", "platforms", "verify", "publish", "live-check")
    before_notarize = ("build", "package", "sign")

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

    def node_modules(self, owner, log):
        """node_modules for package-lock.json, cloned (APFS copy-on-write) from the cache when another worktree or run
        installed the same lock already; otherwise npm ci from npm's own cache, and kept for the next."""
        app_dir = self.app_dir(owner)
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
        """node_modules (by lock), the Friends helper and the client addon built from apps/pdf in the same tree."""
        log = self.log("build")
        for owner in self.owners:
            if owner != OWNER:
                self.derive_private(log)
            self.node_modules(owner, log)
            run(["scripts/friends/setup-friends.sh"], cwd=self.app_dir(owner), env={"MAKEFLAGS": None}, log=log)
        return {}

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
            run(["node", "electron/package-mac.mjs", f"--release-owner={owner}", *forbid,
                 f"--version={self.version}", f"--output={out}"], cwd=self.app_dir(owner), log=log)
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
              ("3d/friends", ["npm", "run", "test:friends"]))

    def tests(self):
        names = [n for n, _ in self.SUITES]
        missing = self.missing(names)
        say(f"tests: {len(names) - len(missing)} of {len(names)} suites passed on this commit already"
            + (f"; running {len(missing)}" if missing else ""))
        folder = os.path.join(self.logs, "tests")
        os.makedirs(folder, exist_ok=True)
        failed = []
        for name, cmd in self.SUITES:
            if name in missing:
                log = os.path.join(folder, name.split("/")[1] + ".log")
                if not self.stamped(name, cmd, self.app_dir(OWNER), env={"MAKEFLAGS": None}, log=log):
                    failed.append(name)
                    say(f"tests: {name} FAILED ({log})")
        return failed

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
        say(f"{stage}: {owner}'s {old['tag']} updates to {self.tag} (tools/updater-e2e)")
        code = run(["node", os.path.join(self.wt, "tools/updater-e2e/update-e2e-3d.mjs"), f"--owner={owner}",
                    f"--fixture={fixture}", f"--artifacts={self.notarized(owner)}", f"--shape={shape}",
                    f"--notes={notes}", f"--work={os.path.join(work_root, 'run')}", f"--expect-access={access}",
                    f"--relaunch-app={relaunch}"] + (["--live"] if live else []), cwd=app_dir, log=log, check=False)
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

    def verify(self):
        for owner in self.owners:
            self.update_test(owner, "verify")
        return {"files": [f for o in self.owners for f in self.final_files(o)]}

    def platforms(self):
        """--platforms all: the web build, Android, the iOS Simulator, and the Linux and Windows installers built in the
        Parallels VMs (resumed for the build and suspended again) by scripts/friends/tauri-vm.sh, which takes its
        SZF_VM_* settings from the environment. Files land in the run's platforms/ folder under their release names."""
        log = self.log("platforms")
        app_dir = self.app_dir(OWNER)
        out = os.path.join(self.out, "platforms")
        shutil.rmtree(out, ignore_errors=True)
        os.makedirs(out)
        v = self.version
        web = os.path.join(out, f"shenzhen-3d-{v}-web.zip")
        dist = os.path.join(app_dir, "dist")
        with zipfile.ZipFile(web, "w", zipfile.ZIP_DEFLATED) as z:
            for folder, _, names in os.walk(dist):
                for name in sorted(names):
                    full = os.path.join(folder, name)
                    z.write(full, os.path.relpath(full, dist))
        no_frontend = write_json(os.path.join(self.run_dir, "no-frontend-build.json"),
                                 {"build": {"beforeBuildCommand": ""}})
        # Cargo's output is kept per target in the cache, shared by every worktree.
        cargo = lambda triple: {"CARGO_TARGET_DIR": os.path.join(CACHE, "cargo", triple)}  # noqa: E731
        run(["node", "scripts/platform-build.mjs", "android", "--friends", "--apk", "--aab", "--target", "aarch64",
             "--ci", "--config", no_frontend], cwd=app_dir, env=cargo("aarch64-linux-android"), log=log)
        outputs = os.path.join(app_dir, "src-tauri/gen/android/app/build/outputs")
        apk = sorted(glob.glob(os.path.join(outputs, "apk/**/*.apk"), recursive=True))
        aab = sorted(glob.glob(os.path.join(outputs, "bundle/**/*.aab"), recursive=True))
        if not apk or not aab:
            raise Failure(f"the Android build left no APK or AAB under {outputs}")
        shutil.copyfile(apk[-1], os.path.join(out, f"shenzhen-3d-{v}-android-arm64-development.apk"))
        shutil.copyfile(aab[-1], os.path.join(out, f"shenzhen-3d-{v}-android-arm64-unsigned.aab"))
        run(["node", "scripts/platform-build.mjs", "ios", "--friends", "--target", "aarch64-sim", "--ci",
             "--archive-only", "--config", no_frontend], cwd=app_dir, env=cargo("aarch64-apple-ios-sim"), log=log)
        sims = glob.glob(os.path.join(app_dir, "src-tauri/gen/apple/build/**/*.app"), recursive=True)
        if not sims:
            raise Failure("the iOS Simulator build left no .app")
        run(["tar", "-czf", os.path.join(out, f"shenzhen-3d-{v}-ios-arm64-simulator.tar.gz"), "-C",
             os.path.dirname(sims[0]), os.path.basename(sims[0])], log=log)
        keep = os.path.join(self.run_dir, "vm-installers")
        shutil.rmtree(keep, ignore_errors=True)
        os.makedirs(keep)
        pdf = os.path.join(self.wt, "apps/pdf")
        for kind, vm in (("linux-vm", "Ubuntu 24.04 (with Rosetta)"), ("windows-vm", "Windows 11")):
            run(["prlctl", "resume", vm], log=log, check=False)
            try:
                run(["scripts/friends/tauri-vm.sh", "package", kind, pdf, vm], cwd=app_dir,
                    env={"SZF_VM_KEEP": keep}, log=log)
            finally:
                run(["prlctl", "suspend", vm], log=log, check=False)
        names = {"*_x64-setup.exe": f"Shenzhen-3D-{v}-Windows-x64-Setup.exe",
                 "*_x64_en-US.msi": f"Shenzhen-3D-{v}-Windows-x64.msi",
                 "*_aarch64.AppImage": f"Shenzhen-3D-{v}-Linux-arm64.AppImage",
                 "*_arm64.deb": f"Shenzhen-3D-{v}-Linux-arm64.deb",
                 "*.aarch64.rpm": f"Shenzhen-3D-{v}-Linux-arm64.rpm"}
        for pattern, name in names.items():
            found = glob.glob(os.path.join(keep, "**", pattern), recursive=True)
            if not found:
                raise Failure(f"the VM builds left no {pattern} in {keep}")
            shutil.copyfile(found[0], os.path.join(out, name))
        return {"files": sorted(glob.glob(os.path.join(out, "*")))}

    def release_files(self, owner):
        files = list(self.final_files(owner))
        if self.opts.platforms == "all" and owner == OWNER:
            files += sorted(glob.glob(os.path.join(self.out, "platforms", "*")))
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
