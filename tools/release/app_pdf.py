"""ShenzhenPDF: apps/pdf, released on casimir-engineering/shenzhen-pdf as <version>-<build> with
ShenzhenPDF-mac-arm64.dmg."""
import hashlib
import os
import re
import shutil
import subprocess
import time

import pdfsuites
from base import Release
from common import (CACHE, IDENTITY, JOBS, TEAM_ID, TEAM_REQUIREMENT, Failure, durations, git, notarize,
                    record_duration, run, say, staple, wait_for_load, with_env)
from jobs import POOL, Job, graph
from macshared import (check_displayed_release, gatekeeper_check, latest_release_json, previous_app, publish_common,
                       run_mac_update_e2e, write_json)

SLUG = "casimir-engineering/shenzhen-pdf"
ASSET = "ShenzhenPDF-mac-arm64.dmg"
VOLUME = "Shenzhen PDF"
# A timed suite (pdfsuites.TIMED) runs after every other suite holding most of the pool (TIMED_CPUS), so little the run
# starts (another app's build, a VM, a phone build) runs beside it; holding it, it also waits until the load average is
# below this many runnable threads, for TIMED_WAIT seconds at most (other work on this Mac). It is not run a second
# time when it fails: its budgets need a quiet machine, which a second run at the end would not have either; rerunning
# the release runs it again.
TIMED_LOAD = float(os.environ.get("SHENZHEN_TIMED_LOAD") or (os.cpu_count() or 8) * 0.6)
TIMED_WAIT = 60
TIMED_CPUS = POOL.cpus * 2 // 3
# What one suite holds of the pool: a suite compiles, then runs a test that often starts helpers of its own.
SUITE_CPUS = 2
# What a suite run a second time holds: a third of the pool, so at most three run again at once, on a quiet machine.
RETRY_CPUS = POOL.cpus // 3


class PdfRelease(Release):
    app = "pdf"
    title = "ShenzhenPDF"

    def parse_version(self, version):
        m = re.fullmatch(r"(\d{2}\.[1-9]\d*\.[1-9]\d*)-([1-9]\d*)", version)
        if not m:
            raise Failure(f"a ShenzhenPDF version reads YY.M.D-N (26.10.20-1), not {version}")
        self.version, self.build_number = m.group(1), m.group(2)
        self.tag = version

    def preflight(self):
        """Also, before anything is built: every header and source the app's and its test suites' builds name is
        committed (a file left only on the disk it was written on fails every suite that compiles it)."""
        result = super().preflight()
        run([os.path.join(self.repo, "tools", "check-pdf-missing-files.py"), "--rev", self.commit], cwd=self.repo,
            log=self.log("preflight"))
        return result

    def committed_version(self):
        makefile = git(self.repo, "show", f"{self.commit}:apps/pdf/portable/Makefile")
        values = dict(re.findall(r"^(MAC_VERSION|MAC_BUILD) \?= (\S+)$", makefile, re.M))
        return f"{values.get('MAC_VERSION')}-{values.get('MAC_BUILD')}"

    def notes_path(self, tag):
        return os.path.join(self.repo, "apps/pdf/portable/docs/releases", tag + ".md")

    @property
    def portable(self):
        return os.path.join(self.wt, "apps/pdf/portable")

    def keys(self):
        """Cache keys: MuPDF's libraries by its source, Friends' third-party libraries by ext/ and their makefiles."""
        mupdf = git(self.repo, "rev-parse", f"{self.commit}:apps/pdf/mupdf")[:12]
        deps = hashlib.sha1((git(self.repo, "rev-parse", f"{self.commit}:apps/pdf/ext") +
                             git(self.repo, "rev-parse", f"{self.commit}:apps/pdf/portable/friends/deps") +
                             " release arm64 12.0").encode()).hexdigest()[:12]
        return {"MUPDF_OUT": f"build/release-macos-arm64-12.0-{mupdf}",
                "FRIENDS_DEPS": os.path.join(CACHE, "friends-deps", deps)}

    def app_path(self):
        return os.path.join(self.out, "dist", "ShenzhenPDF.app")

    # ---- stages ------------------------------------------------------------------------------------------------

    def build(self):
        """The signed app, as build-mac-release.sh builds it: release mode, a fresh build directory for the app's own
        code, and MuPDF and Friends' third-party libraries from caches keyed by their sources."""
        build_dir = os.path.join(self.run_dir, "build")
        shutil.rmtree(build_dir, ignore_errors=True)
        shutil.rmtree(os.path.join(self.out, "dist"), ignore_errors=True)
        keys = self.keys()
        clear = {name: None for name in ("SPDF_RELEASE_MODE", "MAC_ARCH", "MACOSX_DEPLOYMENT_TARGET", "MAC_BUNDLE_ID",
                                         "MAC_TEAM_ID", "PORTABLE_OPTFLAGS", "MUPDF_OUT", "MAKEFLAGS", "MFLAGS")}
        run(["make", "-C", self.portable, f"-j{JOBS}", "mac-app", "SPDF_RELEASE_MODE=1",
             f"MAC_VERSION={self.version}", f"MAC_BUILD={self.build_number}", f"MAC_RELEASE_TAG={self.tag}",
             f"MAC_SIGN_IDENTITY={IDENTITY}",
             f"BUILD={build_dir}", f"DIST={os.path.join(self.out, 'dist')}", f"MUPDF_OUT={keys['MUPDF_OUT']}",
             f"FRIENDS_DEPS_BUILD={keys['FRIENDS_DEPS']}", f"FRIENDS_DC_BUILD={keys['FRIENDS_DEPS']}"],
            env=clear, log=self.log("build"))
        app = self.app_path()
        info = os.path.join(app, "Contents/Info.plist")
        got = [run(["/usr/libexec/PlistBuddy", "-c", f"Print :{k}", info], capture=True).strip()
               for k in ("CFBundleShortVersionString", "CFBundleVersion", "SZFReleaseTag")]
        if got != [self.version, self.build_number, self.tag]:
            raise Failure(f"the built app says {got}, not {self.version} build {self.build_number} ({self.tag})")
        return {"files": [os.path.join(app, "Contents/MacOS/ShenzhenPDF")]}

    def sign(self):
        """The build signs every bundle inside out with the Developer ID (portable/Makefile); this checks it."""
        log = self.log("sign")
        app = self.app_path()
        run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app], log=log)
        helpers = os.path.join(app, "Contents/Helpers")
        for item in [app] + [os.path.join(helpers, n) for n in sorted(os.listdir(helpers))]:
            run(["codesign", "--verify", "--strict", f"-R={TEAM_REQUIREMENT}", item], log=log)
        return {"files": [os.path.join(app, "Contents/MacOS/ShenzhenPDF")]}

    def package(self):
        log = self.log("package")
        folder = os.path.join(self.out, "package")
        os.makedirs(folder, exist_ok=True)
        dmg = os.path.join(folder, ASSET)
        if os.path.exists(dmg):
            os.remove(dmg)
        run([os.path.join(self.portable, "mac/make-installer-dmg.sh"), self.app_path(), dmg, VOLUME],
            env={"DMG_LAYOUT_DS_STORE": os.path.join(self.portable, "mac/dmg-layout.DS_Store")}, log=log)
        run(["codesign", "--force", "--timestamp", "--sign", IDENTITY, dmg], log=log)
        return {"files": [dmg], "dmg": dmg}

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
        run([os.path.join(self.portable, "release/verify-mac-artifact.sh"), "--dmg", dmg, "--version", self.version,
             "--build", self.build_number, "--bundle-id", "com.intuition.shenzhenpdf", "--team-id", TEAM_ID,
             "--min-os", "12.0"], log=log)
        gatekeeper_check(dmg, "ShenzhenPDF.app", os.path.join(self.run_dir, "gatekeeper"), log)
        return {"files": [dmg], "dmg": dmg}

    def suites(self):
        out = run(["bash", "-c", '. release/release-common.sh && spdf_discover_test_targets Makefile'],
                  cwd=self.portable, capture=True)
        return [s for s in out.split() if s]

    def tests(self):
        """The suites that have not passed on this commit, side by side (pdfsuites.py plans them from the Makefile):
        first one make -j builds everything their makes would build, then each suite runs in a make of its own, as
        many at once as the pool allows, longest first. friends-tests runs as its parts at once."""
        suites = self.suites()
        missing = self.missing([f"pdf/{s}" for s in suites])
        say(f"tests: {len(suites) - len(missing)} of {len(suites)} suites passed on this commit already"
            + (f"; running {len(missing)}" if missing else ""))
        if not missing:
            return []
        env = {"MUPDF_OUT": self.keys()["MUPDF_OUT"], "LAUNCH_PERF_BASELINE_RELEASE": "latest",
               "LAUNCH_PERF_APP": self.app_path(), "MAKEFLAGS": None, "MFLAGS": None}
        if os.path.exists("/opt/homebrew/bin/turnserver"):
            env["FRIENDS_TEST_COTURN"] = "/opt/homebrew/bin/turnserver"
        token = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True).stdout.strip()
        if token:
            env["GH_TOKEN"] = token
        folder = os.path.join(self.logs, "tests")
        os.makedirs(folder, exist_ok=True)
        names = [s.split("/", 1)[1] for s in missing]
        plan = pdfsuites.Plan(self.portable, suites, with_env(env), run=names)
        # Everything the suites' makes would build before running anything, built once: two suites never write the
        # same object at the same time.
        with POOL.take(cpus=JOBS * 2 // 3, mem=8, priority=-500):
            run(["make", "-C", self.portable, f"-j{JOBS}", "-k", "test-binaries", "mupdf-libs", *plan.prebuild],
                env=env, log=os.path.join(folder, "test-binaries.log"), check=False)
        history = durations("pdf")
        passed, ran = {}, set()

        def job(name, spec, alone=False):
            def fn():
                late = [d for d in spec["after"] if not passed.get(d)]
                log = os.path.join(folder, name.replace("/", "--") + ".log")
                if late:
                    passed[name] = False
                    with open(log, "a") as f:
                        f.write(f"not run: {', '.join(late)} did not pass\n")
                    return
                ran.add(name)
                cmd = ["make", *[a for o in spec["old"] for a in ("-o", o)], *spec["goals"]]
                start = time.time()
                if name == spec["suite"]:
                    ok = self.stamped(f"pdf/{name}", cmd, self.portable, env=env, log=log)
                else:
                    ok = run(cmd, cwd=self.portable, env=env, log=log, check=False) == 0
                if not alone:
                    record_duration("pdf", name, time.time() - start)
                passed[name] = ok
                if not ok:
                    say(f"tests: {name} FAILED{' again' if alone else ''} ({log})")
                elif alone:
                    say(f"tests: {name} passed on its second run, on a quieter machine: it failed beside other work")
                    self.flaky.append(name)
            locks = [spec["lock"]] if spec["lock"] else []
            if alone:
                return Job(fn, deps=[d for d in spec["after"] if d in again], cpus=RETRY_CPUS, mem=4, locks=locks)
            if spec["suite"] in pdfsuites.TIMED:
                return Job(quiet(fn), deps=[d for d in plan.jobs if plan.jobs[d]["suite"] not in pdfsuites.TIMED],
                           cpus=TIMED_CPUS, mem=4, locks=locks)
            return Job(fn, deps=spec["after"], cpus=SUITE_CPUS, mem=1, locks=locks,
                       priority=-history.get(name, 60.0))

        def quiet(fn):
            def wrapped():
                waited = wait_for_load(TIMED_LOAD, TIMED_WAIT)
                say(f"tests: a timed suite starts with the load average at {os.getloadavg()[0]:.1f}"
                    + (f", after {waited:.0f} s waiting for it to fall" if waited >= 1 else ""))
                return fn()
            return wrapped

        again = {}
        graph({name: job(name, spec) for name, spec in plan.jobs.items()})
        # A suite that failed beside the others runs once more, three at most at a time, as a rerun of the release
        # would run it, with the jobs that did not run because it failed; still failing, it fails the release.
        retry = {name for name in plan.jobs if name in ran and not passed.get(name)
                 and plan.jobs[name]["suite"] not in pdfsuites.TIMED}
        if retry:
            again.update({name: plan.jobs[name] for name in retry})
            grew = True
            while grew:  # what waits on those, through any number of jobs
                grew = False
                for name in plan.jobs:
                    if name not in again and name not in ran and any(d in again for d in plan.jobs[name]["after"]):
                        again[name] = plan.jobs[name]
                        grew = True
            say(f"tests: running {', '.join(sorted(retry))} again, three at most at a time")
            graph({name: job(name, spec, alone=True) for name, spec in again.items()})
        failed = sorted(name for name in names if not passed.get(name))
        return failed

    def verify(self):
        """Updating from the published release to this candidate, hidden, against a local copy of GitHub."""
        dmg = os.path.join(self.out, "final", ASSET)
        check_displayed_release(self, dmg, "ShenzhenPDF.app")
        old = previous_app(self, SLUG, ASSET, "ShenzhenPDF.app")
        run_mac_update_e2e(self, "pdf", old, dmg, old["release_json"], "verify")
        return {"files": [dmg], "previous": old["tag"]}

    def publish(self):
        dmg = os.path.join(self.out, "final", ASSET)
        release = publish_common(self, "apps/pdf", SLUG, title=self.tag, files=[dmg], prerelease=False, latest=True)
        return {"url": release.get("html_url")}

    def live_check(self):
        """Once: the previous release updates to this one as GitHub now lists it."""
        dmg = os.path.join(self.out, "final", ASSET)
        live = latest_release_json(SLUG, self.log("live-check"))
        if live.get("tag_name") != self.tag:
            raise Failure(f"GitHub's latest {SLUG} release is {live.get('tag_name')}, not {self.tag}")
        shape = write_json(os.path.join(self.run_dir, "live-release.json"), live)
        old = previous_app(self, SLUG, ASSET, "ShenzhenPDF.app")
        run_mac_update_e2e(self, "pdf", old, dmg, shape, "live-check")
        return {}
