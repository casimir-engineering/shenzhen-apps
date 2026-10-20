"""Shenzhen Files: apps/files, released on casimir-engineering/shenzhen-files as <version>-<build> with
ShenzhenFiles-mac-arm64.dmg."""
import os
import re
import shutil

from base import Release
from common import IDENTITY, TEAM_REQUIREMENT, Failure, git, notarize, run, say, staple
from macshared import gatekeeper_check, latest_release_json, previous_app, publish_common, run_mac_update_e2e, write_json

SLUG = "casimir-engineering/shenzhen-files"
ASSET = "ShenzhenFiles-mac-arm64.dmg"
APP = "Shenzhen Files.app"


class FilesRelease(Release):
    app = "files"
    title = "Shenzhen Files"

    def parse_version(self, version):
        m = re.fullmatch(r"(\d{2}\.[1-9]\d*\.[1-9]\d*)-([1-9]\d*)", version)
        if not m:
            raise Failure(f"a Shenzhen Files version reads YY.M.D-N (26.10.20-1), not {version}")
        self.version, self.build_number = m.group(1), m.group(2)
        self.tag = version

    def committed_version(self):
        script = git(self.repo, "show", f"{self.commit}:apps/files/package/make-app.sh")
        values = dict(re.findall(r'^(SHORT_VERSION|RELEASE_BUILD)="([^"]*)"$', script, re.M))
        return f"{values.get('SHORT_VERSION')}-{values.get('RELEASE_BUILD')}"

    def notes_path(self, tag):
        return os.path.join(self.repo, "apps/files/docs", f"release-{tag}.md")

    @property
    def files_dir(self):
        return os.path.join(self.wt, "apps/files")

    def env(self):
        return {"SZF_RELEASE_VERSION": self.tag if self.tag != self.committed_version() else None,
                "MAKEFLAGS": None, "MFLAGS": None}

    def app_path(self, signed=True):
        """The signed app (sign stage), or the one the build assembled, which signing never touches."""
        return os.path.join(self.out, "dist" if signed else "build", APP)

    def preflight(self):
        result = super().preflight()
        if self.opts.publish:
            readme = git(self.repo, "show", f"{self.commit}:apps/files/README.md")
            if f"Latest <b>{self.tag}</b>" not in readme:
                raise Failure(f"apps/files/README.md does not say Latest <b>{self.tag}</b>")
        return result

    # ---- stages ------------------------------------------------------------------------------------------------

    def build(self):
        """Friends from apps/pdf, Nautilus (meson and ninja, in the cached worktree, so only what changed is rebuilt),
        then the app bundle (package/make-app.sh)."""
        log = self.log("build")
        env = self.env()
        run(["tools/setup-friends.sh"], cwd=self.files_dir, env=env, log=log)
        run(["tools/setup-nautilus-tree.sh"], cwd=self.files_dir, env=env, log=log)
        built = self.app_path(signed=False)
        shutil.rmtree(os.path.dirname(built), ignore_errors=True)
        os.makedirs(os.path.dirname(built))
        run(["package/make-app.sh", built], cwd=self.files_dir, env=env, log=log)
        tag = run(["/usr/libexec/PlistBuddy", "-c", "Print :SZFReleaseTag",
                   os.path.join(built, "Contents/Info.plist")], capture=True).strip()
        if tag != self.tag:
            raise Failure(f"the app bundle says {tag}, not {self.tag}")
        return {"files": [os.path.join(built, "Contents/MacOS/nautilus")]}

    def sign(self):
        """Every Mach-O with the Developer ID, hardened runtime and a secure timestamp (package/bundle-dylibs.sh)."""
        log = self.log("sign")
        env = dict(self.env(), MAC_SIGN_IDENTITY=IDENTITY)
        app = self.app_path()
        shutil.rmtree(os.path.dirname(app), ignore_errors=True)
        os.makedirs(os.path.dirname(app))
        run(["ditto", self.app_path(signed=False), app], log=log)
        run(["package/bundle-dylibs.sh", app], cwd=self.files_dir, env=env, log=log)
        run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app], log=log)
        for item in (app, os.path.join(app, "Contents/Helpers/Shenzhen Friends.app")):
            run(["codesign", "--verify", "--strict", f"-R={TEAM_REQUIREMENT}", item], log=log)
        return {"files": [os.path.join(app, "Contents/MacOS/nautilus")]}

    def package(self):
        log = self.log("package")
        folder = os.path.join(self.out, "package")
        os.makedirs(folder, exist_ok=True)
        dmg = os.path.join(folder, ASSET)
        if os.path.exists(dmg):
            os.remove(dmg)
        run(["package/make-dmg.sh", self.app_path(), dmg], cwd=self.files_dir,
            env=dict(self.env(), DMG_LAYOUT_DS_STORE=os.path.join(self.files_dir, "package/dmg-layout.DS_Store")),
            log=log)
        run(["codesign", "--force", "--timestamp", "--sign", IDENTITY, dmg], log=log)
        return {"files": [dmg]}

    def notarize(self):
        dmg = os.path.join(self.out, "package", ASSET)
        result = notarize([dmg], os.path.join(self.run_dir, "notary.json"), self.log("notarize"))
        return {"files": [dmg], "submission": result[dmg]["id"]}

    def staple(self):
        log = self.log("staple")
        final = os.path.join(self.out, "final")
        os.makedirs(final, exist_ok=True)
        dmg = os.path.join(final, ASSET)
        shutil.copyfile(os.path.join(self.out, "package", ASSET), dmg)
        staple(dmg, log)
        run(["codesign", "--verify", "--strict", dmg], log=log)
        gatekeeper_check(dmg, APP, os.path.join(self.run_dir, "gatekeeper"), log)
        return {"files": [dmg]}

    SUITES = (("files/friends-adapter", ["tools/test-friends-adapter.sh"]),
              ("files/friends-shortcut", ["tools/test-macos-friends-shortcut.sh"]))

    def tests(self):
        names = [name for name, _ in self.SUITES]
        missing = self.missing(names)
        say(f"tests: {len(names) - len(missing)} of {len(names)} suites passed on this commit already"
            + (f"; running {len(missing)}" if missing else ""))
        folder = os.path.join(self.logs, "tests")
        os.makedirs(folder, exist_ok=True)
        failed = []
        for name, cmd in self.SUITES:
            if name not in missing:
                continue
            log = os.path.join(folder, name.split("/")[1] + ".log")
            if not self.stamped(name, cmd, self.files_dir, env={"MAKEFLAGS": None, "MFLAGS": None}, log=log):
                failed.append(name)
                say(f"tests: {name} FAILED ({log})")
        return failed

    def verify(self):
        dmg = os.path.join(self.out, "final", ASSET)
        old = previous_app(self, SLUG, ASSET, APP)
        run_mac_update_e2e(self, "files", old, dmg, old["release_json"], "verify")
        return {"files": [dmg], "previous": old["tag"]}

    def publish(self):
        dmg = os.path.join(self.out, "final", ASSET)
        release = publish_common(self, "apps/files", SLUG, title=self.tag, files=[dmg], prerelease=False, latest=True)
        return {"url": release.get("html_url")}

    def live_check(self):
        dmg = os.path.join(self.out, "final", ASSET)
        live = latest_release_json(SLUG, self.log("live-check"))
        if live.get("tag_name") != self.tag:
            raise Failure(f"GitHub's latest {SLUG} release is {live.get('tag_name')}, not {self.tag}")
        shape = write_json(os.path.join(self.run_dir, "live-release.json"), live)
        old = previous_app(self, SLUG, ASSET, APP)
        run_mac_update_e2e(self, "files", old, dmg, shape, "live-check")
        return {}
