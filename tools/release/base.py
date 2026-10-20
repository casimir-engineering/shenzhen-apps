"""The flow every app's release follows, and what the apps share; app_pdf.py, app_files.py and app_3d.py fill in
the stages."""
import os
import shutil
import time

from common import CACHE, Failure, Lock, Stages, git, parallel, prepare_worktree, run, say


class Release:
    """One app's release of one version from one commit. Subclasses set `app`, `title` and the stage methods."""

    app = None
    # Stamped stages in order: running one again drops the stamps of those after it.
    order = ("build", "sign", "package", "notarize", "staple", "platforms", "verify", "publish", "live-check")
    # The stages before notarization, in the order they run (Shenzhen 3D signs while packaging, then checks).
    before_notarize = ("build", "sign", "package")

    def __init__(self, repo, version, opts):
        self.repo, self.opts = repo, opts
        self.commit = git(repo, "rev-parse", "HEAD")
        self.short = self.commit[:12]
        self.parse_version(version)
        self.run_dir = os.path.join(CACHE, "runs", self.app, self.tag, self.short)
        self.out = os.path.join(self.run_dir, "out")
        self.logs = os.path.join(self.run_dir, "logs")
        os.makedirs(self.out, exist_ok=True)
        os.makedirs(self.logs, exist_ok=True)
        self.wt = os.path.join(CACHE, "worktrees", self.app)
        self.stages = Stages(os.path.join(self.run_dir, "stamps"), self.order,
                             f"{self.app} {self.tag} {self.commit} {opts.platforms} {int(opts.private_copy)}")
        self.test_failures = []
        self.problems = []

    def log(self, stage):
        return os.path.join(self.logs, stage + ".log")

    # ---- what every app shares --------------------------------------------------------------------------------

    def parse_version(self, version):
        raise NotImplementedError

    def committed_version(self):
        """The version the commit itself says (Makefile, make-app.sh, package.json)."""
        raise NotImplementedError

    def preflight(self):
        log = self.log("preflight")
        status = git(self.repo, "status", "--porcelain=v1")
        if status:
            raise Failure("this worktree has uncommitted changes; a release builds HEAD as committed. Commit or stash "
                          "them first:\n" + status)
        run([os.path.join(self.repo, "tools", "check-friends-number.sh")], cwd=self.repo, log=log)
        committed = self.committed_version()
        if committed != self.tag:
            if self.opts.publish:
                raise Failure(f"{self.tag} is not the version this commit sets ({committed}); prepare the release "
                              "first (docs/RELEASING.md)")
            say(f"preflight: building {self.tag} although the commit sets {committed}: a dry run only")
        if self.opts.publish:
            run(["git", "-C", self.repo, "fetch", "--quiet", "origin", "main"], log=log)
            if git(self.repo, "merge-base", "--is-ancestor", self.commit, "origin/main", check=False) is None:
                raise Failure(f"{self.short} is not on origin/main: merge and push it before publishing")
            run(["gh", "auth", "status", "-h", "github.com"], log=log)
        out = run(["security", "find-identity", "-v", "-p", "codesigning"], log=log, capture=True)
        if self.identity_name() not in out:
            raise Failure(f"the signing identity is not in the keychain: {self.identity_name()}")
        run(["xcrun", "notarytool", "history", "--keychain-profile", self.profile(), "--output-format", "json"],
            log=log, capture=True)
        self.check_notes()
        return {}

    def identity_name(self):
        from common import IDENTITY
        return IDENTITY

    def profile(self):
        from common import PROFILE
        return PROFILE

    def notes(self):
        """The release notes for this version, copied into the run when first asked for. In a dry run of a version
        that has none, the committed version's notes stand in."""
        copy = os.path.join(self.run_dir, "notes.md")
        if os.path.isfile(copy):
            return copy
        path = self.notes_path(self.tag)
        if not os.path.isfile(path):
            if self.opts.publish:
                raise Failure(f"the release notes are missing: {path}")
            fallback = self.notes_path(self.committed_version())
            if not os.path.isfile(fallback):
                raise Failure(f"no release notes: neither {path} nor {fallback}")
            say(f"preflight: no notes for {self.tag}; the dry run uses {os.path.relpath(fallback, self.repo)}")
            path = fallback
        shutil.copyfile(path, copy)
        return copy

    def check_notes(self):
        if os.path.exists(os.path.join(self.run_dir, "notes.md")):
            os.remove(os.path.join(self.run_dir, "notes.md"))
        self.notes()

    def worktree(self):
        prepare_worktree(self.repo, self.wt, self.commit, self.log("worktree"))
        return {}

    def tests_stage(self):
        failed = self.tests()
        self.test_failures = failed or []
        if self.test_failures:
            say(f"tests: FAILED: {', '.join(self.test_failures)} (logs in {self.logs})")
        return {"failed": self.test_failures}

    def stamped(self, suite, cmd, cwd, env=None, log=None):
        """Runs one suite through tools/test-stamp.sh: skipped when it passed on this commit; True when it passes."""
        stamp = os.path.join(self.wt, "tools", "test-stamp.sh")
        return run([stamp, "run", suite, "--", *cmd], cwd=cwd, env=env, log=log or self.log("tests"),
                   check=False) == 0

    def missing(self, suites):
        """The suites that have not passed on this commit (the build worktree holds it, clean)."""
        stamp = os.path.join(self.wt, "tools", "test-stamp.sh")
        passed = set(run([stamp, "list"], cwd=self.wt, capture=True).split())
        return [s for s in suites if s not in passed]

    # ---- the flow ----------------------------------------------------------------------------------------------

    def flow(self):
        s = self.stages
        s.run("preflight", self.preflight, stamp=False)
        s.run("worktree", self.worktree, stamp=False)
        for name in self.before_notarize:
            s.run(name, getattr(self, name))
        # Apple's verdict takes minutes of waiting on the network: the test suites run meanwhile.
        parallel({"notarize": lambda: s.run("notarize", self.notarize),
                  "tests": lambda: s.run("tests", self.tests_stage, stamp=False)})
        if self.test_failures and self.opts.publish:
            raise Failure(f"test suites failed: {', '.join(self.test_failures)}; nothing was published")
        s.run("staple", self.staple)
        if self.opts.platforms == "all":
            s.run("platforms", self.platforms)
        try:
            s.run("verify", self.verify)
        except Failure as error:
            # A dry run reports every check it can; a publish stops at the first.
            if self.opts.publish:
                raise
            self.problems.append(f"verify: {error}")
            say(f"verify: FAILED: {error}")
        if not self.opts.publish:
            s.skip("publish", "dry run")
            return
        s.run("publish", self.publish)
        s.run("live-check", self.live_check)

    def main(self):
        start = time.time()
        ok = False
        say(f"{self.title} {self.tag} from {self.short}" + (" (publishing)" if self.opts.publish else " (dry run)"))
        say(f"work and logs: {self.run_dir}")
        try:
            with Lock(os.path.join(CACHE, "locks", self.app), f"release of {self.app}"):
                self.flow()
            ok = not self.test_failures and not self.problems
        except Failure as error:
            say(f"FAILED: {error}")
        except KeyboardInterrupt:
            say("interrupted; run the same command again to resume")
        finally:
            print(self.stages.summary(time.time() - start), flush=True)
        if self.test_failures:
            say(f"not releasable: test suites failed: {', '.join(self.test_failures)}")
        for problem in self.problems:
            say(f"not releasable: {problem}")
        say(("done: " if ok else "stopped: ") + self.run_dir)
        return 0 if ok else 1
