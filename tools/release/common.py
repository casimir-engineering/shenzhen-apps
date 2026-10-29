"""What tools/release.sh shares between the apps: commands and their logs, stage stamps and timings, locks, the cached
build worktree, Apple's notary service and GitHub."""
import concurrent.futures
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time

CACHE = os.path.expanduser(os.environ.get("SHENZHEN_BUILD_CACHE") or "~/Library/Caches/shenzhen-build")
IDENTITY = os.environ.get("MAC_SIGN_IDENTITY") or \
    "Developer ID Application: INTUITION Robotique & Technologies (66LJ4BV7Q3)"
PROFILE = os.environ.get("NOTARY_PROFILE") or "shenzhenpdf-notary"
TEAM_ID = "66LJ4BV7Q3"
TEAM_REQUIREMENT = f'anchor apple generic and certificate leaf[subject.OU] = "{TEAM_ID}"'
JOBS = os.cpu_count() or 8
TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Where the release repositories are pushed; test_release.py points it at local bare repositories.
GIT_URL_BASE = os.environ.get("SHENZHEN_RELEASE_GIT_URL_BASE") or "https://github.com/"

_print_lock = threading.Lock()


class Failure(Exception):
    """A stage could not do its job; the message says what and where its log is."""


def say(text):
    with _print_lock:
        print(f"[{time.strftime('%H:%M:%S')}] {text}", flush=True)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 22), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tail(path, lines=25):
    try:
        with open(path, errors="replace") as f:
            return "".join(f.readlines()[-lines:])
    except OSError:
        return ""


def run(cmd, *, cwd=None, env=None, log=None, check=True, capture=False, timeout=None):
    """Runs `cmd` (a list) with nothing on stdin, so nothing ever waits on a prompt. Its output is appended to `log`
    (stdout is returned instead when `capture`). `env` adds to the environment; a value of None removes the name."""
    full = dict(os.environ)
    for key, value in (env or {}).items():
        if value is None:
            full.pop(key, None)
        else:
            full[key] = str(value)
    out = open(log, "a") if log else open(os.devnull, "w")
    started = time.time()
    with out:
        out.write(f"\n$ {shlex.join(str(c) for c in cmd)}\n")
        out.flush()
        try:
            p = subprocess.run([str(c) for c in cmd], cwd=cwd, env=full, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE if capture else out, stderr=out, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise Failure(f"{os.path.basename(str(cmd[0]))} took longer than {timeout} s" +
                          (f"; log: {log}" if log else ""))
        finally:
            if log:
                note_command(log, cmd, started)
        out.write(f"# exit {p.returncode} after {time.time() - started:.1f} s\n")
    if p.returncode in (-signal.SIGINT, 128 + signal.SIGINT):
        # Ctrl-C, or SIGINT to the run's process group, reaches the command first: that stops the run, it is not
        # the command failing. Raised in a parallel() job too, so a test sweep stops instead of calling the
        # interrupted suite FAILED and going on to the next one.
        raise KeyboardInterrupt
    if check and p.returncode != 0:
        detail = f"; log: {log}" if log else ""
        raise Failure(f"{' '.join(os.path.basename(str(c)) if i == 0 else str(c) for i, c in enumerate(cmd[:3]))}"
                      f"{' ...' if len(cmd) > 3 else ''} exited with {p.returncode}{detail}")
    return p.stdout if capture else p.returncode


def note_command(log, cmd, started):
    """One line per command in commands.tsv beside its log: when it started, how long it took, the log and the
    command. The run's timing table (Stages.summary) says how long each stage took; this says where the time went
    inside it."""
    seconds = time.time() - started
    line = "\t".join((time.strftime("%H:%M:%S", time.localtime(started)), f"{seconds:.1f}", os.path.basename(log),
                      shlex.join(str(c) for c in cmd)[:400].replace("\t", " ").replace("\n", " ")))
    with _print_lock:
        with open(os.path.join(os.path.dirname(log), "commands.tsv"), "a") as f:
            f.write(line + "\n")


def end_test_processes(path, log):
    """An updater test may leave nothing running: a test copy the updater reopened runs with launchd as its parent and
    can hold an installed app's single-instance lock. Ends whatever still runs from `path` (the test's work directory),
    by exact executable path (tools/updater-e2e/sweep.py), never by name, and fails the stage if anything did."""
    code = run([sys.executable, "-I", os.path.join(TOOLS, "updater-e2e", "sweep.py"), "--grace=10", "--kill", path],
               log=log, check=False)
    if code != 0:
        raise Failure(f"the updater test left processes running from {path}; they were ended (log: {log})")
    forget_registrations(path, log)


def forget_registrations(path, log):
    """Test copies keep the release's bundle identifier and register with LaunchServices when they run; one left there
    (unnotarized, modified, or quarantined) can be offered for opening the app, and Gatekeeper then puts its "damaged"
    dialog on the person's screen. Unregisters every app under `path`; fails the stage if LaunchServices still knows
    one (tools/updater-e2e/nodialogs.py)."""
    code = run([sys.executable, "-I", os.path.join(TOOLS, "updater-e2e", "nodialogs.py"), "unregister", path],
               log=log, check=False)
    if code != 0:
        raise Failure(f"LaunchServices still knows test copies under {path} (log: {log})")


def git(repo, *args, check=True):
    p = subprocess.run(["git", "-C", repo, *args], stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if check and p.returncode != 0:
        raise Failure(f"git {' '.join(args)}: {p.stderr.strip()}")
    return p.stdout.strip() if p.returncode == 0 else None


def retry(what, fn, attempts=5, transient=lambda error: True, wait=15):
    """fn() until it returns, `attempts` times at most while the error is transient, waiting longer each time."""
    for attempt in range(1, attempts + 1):
        try:
            return fn()
        except Failure as error:
            if attempt == attempts or not transient(error):
                raise
            say(f"{what}: {error}; trying again in {wait * attempt} s ({attempt + 1} of {attempts})")
            time.sleep(wait * attempt)


class Lock:
    """A directory that only one release of an app holds at a time; one left by a process that is gone is taken."""

    def __init__(self, path, what):
        self.path, self.what = path, what

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        for _ in range(2):
            try:
                os.mkdir(self.path)
                with open(os.path.join(self.path, "pid"), "w") as f:
                    f.write(str(os.getpid()))
                return self
            except FileExistsError:
                try:
                    pid = int(open(os.path.join(self.path, "pid")).read().strip())
                    os.kill(pid, 0)
                except (OSError, ValueError):
                    shutil.rmtree(self.path, ignore_errors=True)
                    continue
                raise Failure(f"another {self.what} is running (process {pid}); {self.path}")
        raise Failure(f"could not take {self.path}")

    def __exit__(self, *exc):
        shutil.rmtree(self.path, ignore_errors=True)


class Stages:
    """Stage stamps and timings for one run: run/<stage>.json records a finished stage with the files it made and their
    sha256, so a rerun skips it while those files are intact. Running a stage again drops the stamps of the stages
    after it in `order`, which consumed what it made."""

    def __init__(self, folder, order, identity):
        self.folder, self.order, self.identity = folder, list(order), identity
        os.makedirs(folder, exist_ok=True)
        self.timings = []
        self.lock = threading.Lock()

    def _path(self, name):
        return os.path.join(self.folder, name + ".json")

    def cached(self, name):
        try:
            data = json.load(open(self._path(name)))
        except (OSError, ValueError):
            return None
        if data.get("identity") != self.identity:
            return None
        for path, digest in data.get("files", {}).items():
            if not os.path.exists(path) or (digest and sha256(path) != digest):
                return None
        return data

    def drop_after(self, name):
        if name not in self.order:
            return
        for later in self.order[self.order.index(name) + 1:]:
            try:
                os.remove(self._path(later))
            except FileNotFoundError:
                pass

    def note(self, name, status, seconds, earlier=None):
        with self.lock:
            self.timings.append({"stage": name, "status": status, "seconds": seconds, "earlier": earlier})

    def run(self, name, fn, *, stamp=True):
        """Runs `fn` as stage `name` unless an earlier run finished it; returns what it returned (a dict whose "files"
        are recorded with their digests)."""
        if stamp:
            data = self.cached(name)
            if data:
                self.note(name, "done earlier", 0.0, data.get("seconds"))
                say(f"{name}: done by an earlier run ({data.get('seconds', 0):.0f} s then); skipped")
                return data.get("result", {})
            self.drop_after(name)
        say(f"{name}: started")
        start = time.time()
        try:
            result = fn() or {}
        except BaseException:
            self.note(name, "FAILED", time.time() - start)
            raise
        seconds = time.time() - start
        self.note(name, "ran", seconds)
        say(f"{name}: done in {seconds:.0f} s")
        if stamp:
            files = {path: (sha256(path) if os.path.isfile(path) else "") for path in result.get("files", [])}
            tmp = self._path(name) + ".tmp"
            with open(tmp, "w") as f:
                json.dump({"stage": name, "identity": self.identity, "seconds": seconds,
                           "finished": time.strftime("%Y-%m-%dT%H:%M:%S"), "files": files, "result": result}, f,
                          indent=1)
            os.replace(tmp, self._path(name))
        return result

    def skip(self, name, why):
        self.note(name, f"not run: {why}", 0.0)

    def summary(self, total):
        lines = ["", "Stage                 Status            Seconds"]
        for t in self.timings:
            seconds = f"{t['seconds']:8.0f}"
            if t["status"] == "done earlier" and t["earlier"] is not None:
                seconds = f"{0:8.0f}  (took {t['earlier']:.0f} s in an earlier run)"
            lines.append(f"{t['stage']:<21} {t['status']:<17} {seconds}")
        lines.append(f"{'total':<21} {'':<17} {total:8.0f}")
        return "\n".join(lines)


def parallel(jobs):
    """Runs {name: fn} at once and waits for all; raises the first failure (by name order) once every job is done."""
    errors = {}
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(jobs))) as pool:
        futures = {pool.submit(fn): name for name, fn in jobs.items()}
        for future in concurrent.futures.as_completed(futures):
            name = futures[future]
            try:
                results[name] = future.result()
            except BaseException as error:  # noqa: BLE001 -- reported below
                errors[name] = error
    for name in jobs:
        if name in errors:
            raise errors[name]
    return results


# ---- the build worktree -------------------------------------------------------------------------------------------

def prepare_worktree(repo, path, commit, log):
    """A worktree of `repo` at `path`, detached at `commit`, that stays between releases with its ignored build
    output: switching commits rewrites only the files that differ, so make, ninja and cargo rebuild only what changed.
    Untracked files that are not ignored are removed; nothing else is."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if not os.path.exists(os.path.join(path, ".git")):
        git(repo, "worktree", "prune")
        if os.path.exists(path):
            raise Failure(f"{path} exists but is not a worktree of {repo}; move it away")
        run(["git", "-C", repo, "worktree", "add", "--detach", path, commit], log=log)
    else:
        if git(path, "rev-parse", "HEAD") != commit:
            if git(path, "cat-file", "-e", commit + "^{commit}", check=False) is None:
                run(["git", "-C", path, "fetch", "--no-tags", "--quiet", repo, commit], log=log)
            run(["git", "-C", path, "checkout", "--detach", "--force", "--quiet", commit], log=log)
        run(["git", "-C", path, "clean", "-fd", "--quiet"], log=log)
    status = git(path, "status", "--porcelain=v1")
    if status:
        raise Failure(f"the build worktree {path} is not clean after checkout:\n{status}")
    return path


# ---- Apple's notary service ---------------------------------------------------------------------------------------

_PERMANENT = ("Unable to find", "No Keychain password item", "HTTP status code: 401", "HTTP status code: 403",
              "Invalid", "invalid")


def _notary_transient(error):
    return not any(word in str(error) for word in _PERMANENT)


def notarize(paths, state_file, log):
    """Submits every file in `paths` to Apple's notary service at once and waits for all verdicts in parallel; returns
    {path: submission}. A submission is recorded in `state_file` (by the file's sha256) as soon as it is made, so a
    rerun waits for it again instead of uploading again. Network errors are retried."""
    lock = threading.Lock()
    try:
        state = json.load(open(state_file))
    except (OSError, ValueError):
        state = {}

    def save():
        with lock:
            tmp = state_file + ".tmp"
            with open(tmp, "w") as f:
                json.dump(state, f, indent=1)
            os.replace(tmp, state_file)

    def one(path):
        name = os.path.basename(path)
        digest = sha256(path)
        record = state.get(digest)
        if not record or record.get("status") in ("Invalid", "Rejected"):
            # An upload the network resets is tried again without S3 transfer acceleration, which some networks cut;
            # NOTARY_NO_S3_ACCELERATION=1 goes without it from the start.
            plain = [os.environ.get("NOTARY_NO_S3_ACCELERATION") == "1"]

            def submit():
                extra = ["--no-s3-acceleration"] if plain[0] else []
                try:
                    out = run(["xcrun", "notarytool", "submit", path, "--keychain-profile", PROFILE, "--output-format",
                               "json", "--no-wait", *extra], log=log, capture=True)
                except Failure:
                    plain[0] = True
                    raise
                return json.loads(out)["id"]
            submission = retry(f"notarize {name}: upload", submit, transient=_notary_transient)
            record = {"id": submission, "file": path, "status": "In Progress", "submitted": time.time()}
            with lock:
                state[digest] = record
            save()
            say(f"notarize: {name} uploaded (submission {submission})")
        else:
            say(f"notarize: {name} was uploaded by an earlier run (submission {record['id']}); waiting for it")

        def wait():
            out = run(["xcrun", "notarytool", "wait", record["id"], "--keychain-profile", PROFILE, "--output-format",
                       "json", "--timeout", "2h"], log=log, capture=True, check=False)
            try:
                return json.loads(out)
            except ValueError:
                raise Failure(f"notarytool wait {record['id']} gave no answer; log: {log}")
        verdict = retry(f"notarize {name}: wait", wait, transient=_notary_transient)
        record["status"] = verdict.get("status")
        save()
        notary_log = os.path.splitext(path)[0] + f".notary-{record['id']}.json"
        retry(f"notarize {name}: log", lambda: run(["xcrun", "notarytool", "log", record["id"], "--keychain-profile",
                                                    PROFILE, notary_log], log=log))
        if record["status"] != "Accepted":
            raise Failure(f"Apple's notary service answered {record['status']} for {name} "
                          f"(submission {record['id']}); its log: {notary_log}")
        submitted = json.load(open(notary_log)).get("sha256")
        if submitted and submitted != digest:
            raise Failure(f"the notarized {name} is not this file: Apple has sha256 {submitted}, the file {digest}")
        say(f"notarize: {name} accepted")
        return {"id": record["id"], "log": notary_log, "sha256": digest}

    return parallel({path: (lambda p=path: one(p)) for path in paths})


def staple(path, log):
    retry(f"staple {os.path.basename(path)}", lambda: run(["xcrun", "stapler", "staple", path], log=log), attempts=4)
    run(["xcrun", "stapler", "validate", path], log=log)


# ---- GitHub -------------------------------------------------------------------------------------------------------

def _gh_transient(error):
    text = str(error)
    return not any(code in text for code in ("HTTP 401", "HTTP 403", "HTTP 404", "HTTP 422"))


def gh_api(path, *, method="GET", data=None, log=None, paginate=False):
    """`gh api` with JSON in and out; transient errors are retried."""
    cmd = ["gh", "api", "-H", "Accept: application/vnd.github+json", "--method", method, path]
    if paginate:
        cmd.append("--paginate")
    tmp = None
    if data is not None:
        import tempfile
        fd, tmp = tempfile.mkstemp(suffix=".json")
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
        cmd += ["--input", tmp]

    def call():
        p = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True)
        if log:
            with open(log, "a") as f:
                f.write(f"\n$ {shlex.join(cmd)}\n{p.stderr}")
        if p.returncode != 0:
            raise Failure(f"gh api {method} {path}: {p.stderr.strip() or p.stdout.strip()[:300]}")
        return json.loads(p.stdout) if p.stdout.strip() else None
    try:
        return retry(f"GitHub {method} {path}", call, attempts=4, transient=_gh_transient, wait=5)
    finally:
        if tmp:
            os.remove(tmp)


def release_by_tag(repo, tag, log=None):
    """The release named `tag` on `repo`, drafts included (GitHub only finds a draft by listing), or None."""
    for release in gh_api(f"repos/{repo}/releases?per_page=100", log=log) or []:
        if release.get("tag_name") == tag:
            return release
    return None


def download_asset(repo, release, name, folder, log=None):
    """Asset `name` of `release` in `folder`, downloaded once and checked against GitHub's digest."""
    asset = next((a for a in release.get("assets", []) if a.get("name") == name), None)
    if not asset:
        raise Failure(f"{repo} {release.get('tag_name')} has no asset {name}")
    want = (asset.get("digest") or "").removeprefix("sha256:")
    path = os.path.join(folder, name)
    if os.path.isfile(path) and (not want or sha256(path) == want):
        return path
    os.makedirs(folder, exist_ok=True)
    partial = path + ".part"
    retry(f"download {name}", lambda: _download(repo, asset, partial))
    got = sha256(partial)
    if want and got != want:
        os.remove(partial)
        raise Failure(f"{name} of {repo} {release.get('tag_name')} downloaded as sha256 {got}; GitHub says {want}")
    os.replace(partial, path)
    return path


def _download(repo, asset, partial):
    with open(partial, "wb") as out:
        p = subprocess.run(["gh", "api", "-H", "Accept: application/octet-stream",
                            f"repos/{repo}/releases/assets/{asset['id']}"], stdin=subprocess.DEVNULL, stdout=out,
                           stderr=subprocess.PIPE, text=False)
    if p.returncode != 0:
        raise Failure(f"downloading {asset['name']}: {p.stderr.decode(errors='replace').strip()}")


def app_from_dmg(dmg, dest, name, log):
    """Copies the app `name` out of `dmg` (attached hidden, read-only) to `dest`; returns its path."""
    app = os.path.join(dest, name)
    marker = os.path.join(dest, ".from-dmg")
    digest = sha256(dmg)
    if os.path.isdir(app) and os.path.isfile(marker) and open(marker).read().strip() == digest:
        return app
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(dest)
    mount = dest + ".volume"
    os.makedirs(mount, exist_ok=True)
    run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, dmg], log=log)
    try:
        run(["ditto", os.path.join(mount, name), app], log=log)
    finally:
        run(["hdiutil", "detach", mount], log=log, check=False)
        try:
            os.rmdir(mount)
        except OSError:
            pass
    with open(marker, "w") as f:
        f.write(digest + "\n")
    return app


def publish_release(repo, tag, *, title, notes_file, files, prerelease, latest, log):
    """Creates release `tag` on `repo` as a draft (its tag must already exist there), uploads `files` in parallel,
    checks every asset against GitHub's sha256 digest and size in the release JSON, then publishes it. An existing
    published release with exactly these assets is accepted as done; one with other bytes fails."""
    with open(notes_file) as f:
        body = f.read()
    want = {os.path.basename(p): (p, sha256(p), os.path.getsize(p)) for p in files}

    def mismatches(release):
        got = {a["name"]: a for a in release.get("assets", [])}
        bad = []
        for name, (_, digest, size) in want.items():
            a = got.get(name)
            if not a or a.get("state") != "uploaded" or a.get("size") != size or a.get("digest") != "sha256:" + digest:
                bad.append(name)
        return bad, got

    release = release_by_tag(repo, tag, log)
    if release and not release.get("draft"):
        bad, _ = mismatches(release)
        if bad:
            raise Failure(f"{repo} already has a published release {tag} with other assets: {', '.join(bad)}")
        say(f"publish: {repo} {tag} is already published with these assets")
        return release
    if not release:
        release = gh_api(f"repos/{repo}/releases", method="POST", log=log,
                         data={"tag_name": tag, "name": title, "body": body, "draft": True,
                               "prerelease": prerelease})
    else:
        release = gh_api(f"repos/{repo}/releases/{release['id']}", method="PATCH", log=log,
                         data={"name": title, "body": body, "draft": True, "prerelease": prerelease})
    rid = release["id"]
    _, existing = mismatches(release)

    def upload(name):
        path, digest, size = want[name]
        a = existing.get(name)
        if a and a.get("state") == "uploaded" and a.get("digest") == "sha256:" + digest and a.get("size") == size:
            return
        if a:
            gh_api(f"repos/{repo}/releases/assets/{a['id']}", method="DELETE", log=log)

        def send():
            run(["gh", "release", "upload", tag, path, "--repo", repo, "--clobber"], log=log)
        retry(f"upload {name}", send, attempts=4)
        say(f"publish: {name} uploaded to {repo}")

    parallel({name: (lambda n=name: upload(n)) for name in want})
    release = gh_api(f"repos/{repo}/releases/{rid}", log=log)
    bad, _ = mismatches(release)
    if bad:
        raise Failure(f"{repo} {tag}: GitHub's digest or size differs from the built file for {', '.join(bad)}")
    say(f"publish: GitHub's sha256 digests match all {len(want)} files on {repo} {tag}")
    release = gh_api(f"repos/{repo}/releases/{rid}", method="PATCH", log=log,
                     data={"draft": False, "prerelease": prerelease, "make_latest": "true" if latest else "false"})
    bad, _ = mismatches(release)
    if release.get("draft") or bad:
        raise Failure(f"{repo} {tag} did not publish with its assets intact")
    return release


def push_source_tag(repo_dir, app_dir, commit, slug, tag, log, message=None, author=None):
    """Points the plain tag `tag` on github.com/`slug` at a commit whose tree is `app_dir` of `commit`: the app's own
    source, as its standalone repository lays it out, so the release's Source code archives are what was built. Its
    parent is the commit of that repository's newest release tag, so the release tags form one line of history there.
    The objects are fetched into, and the commit made in, a bare mirror under the cache that borrows this repository's
    objects (alternates), so only what changed is uploaded. Returns the commit."""
    mirror = os.path.join(CACHE, "source-mirrors", slug.replace("/", "__") + ".git")
    url = f"{GIT_URL_BASE}{slug}.git"
    if not os.path.isdir(mirror):
        run(["git", "init", "--bare", "--quiet", mirror], log=log)
    alternates = os.path.join(mirror, "objects", "info", "alternates")
    objects = os.path.abspath(os.path.join(repo_dir, git(repo_dir, "rev-parse", "--git-common-dir"), "objects"))
    os.makedirs(os.path.dirname(alternates), exist_ok=True)
    with open(alternates, "w") as f:
        f.write(objects + "\n")
    tree = git(repo_dir, "rev-parse", f"{commit}:{app_dir}")
    remote = run(["git", "ls-remote", "--tags", url], log=log, capture=True)
    existing = {}
    for line in remote.splitlines():
        sha, ref = line.split("\t")
        existing[ref] = sha
    peeled = existing.get(f"refs/tags/{tag}^{{}}") or existing.get(f"refs/tags/{tag}")
    if peeled:
        run(["git", "-C", mirror, "fetch", "--quiet", "--depth", "1", url, f"refs/tags/{tag}"], log=log)
        if git(mirror, "rev-parse", f"{peeled}^{{tree}}") != tree:
            raise Failure(f"{slug} already has a tag {tag} whose source differs from {app_dir} at {commit[:12]}")
        say(f"publish: {slug} tag {tag} already holds this source")
        return peeled
    tags = [ref[len("refs/tags/"):] for ref in existing if ref.startswith("refs/tags/") and not ref.endswith("^{}")]
    listing = gh_api(f"repos/{slug}/releases?per_page=20", log=log) or []
    parent_tag = next((r["tag_name"] for r in listing if not r.get("draft") and r.get("tag_name") in tags), None)
    parent = None
    if parent_tag:
        run(["git", "-C", mirror, "fetch", "--quiet", "--depth", "1", url, f"refs/tags/{parent_tag}"], log=log)
        parent = git(mirror, "rev-parse", "FETCH_HEAD^{commit}")
    if message is None:
        subject = git(repo_dir, "log", "-1", "--format=%s", commit)
        message = (f"{tag}: {app_dir} of casimir-engineering/shenzhen-apps {commit}\n\n"
                   f"The source this release was built from: {app_dir} of that commit ({subject}).\n")
    if author:
        name, email = re.fullmatch(r"\s*(.*?)\s*<([^>]+)>\s*", author).groups()
    else:
        name = git(repo_dir, "log", "-1", "--format=%an", commit)
        email = git(repo_dir, "log", "-1", "--format=%ae", commit)
    env = {"GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email,
           "GIT_AUTHOR_DATE": git(repo_dir, "log", "-1", "--format=%aI", commit)}
    env.update({"GIT_COMMITTER_NAME": env["GIT_AUTHOR_NAME"], "GIT_COMMITTER_EMAIL": env["GIT_AUTHOR_EMAIL"],
                "GIT_COMMITTER_DATE": env["GIT_AUTHOR_DATE"]})
    cmd = ["git", "-C", mirror, "commit-tree", tree, "-m", message] + (["-p", parent] if parent else [])
    source = run(cmd, log=log, capture=True, env=env).strip()
    retry(f"push {slug} {tag}", lambda: run(["git", "-C", mirror, "push", "--quiet", url,
                                            f"{source}:refs/tags/{tag}"], log=log), attempts=4)
    say(f"publish: {slug} tag {tag} -> {source[:12]} ({app_dir} of {commit[:12]})")
    return source
