"""Steps ShenzhenPDF and Shenzhen Files (and partly Shenzhen 3D) take alike: the Gatekeeper check of a stapled DMG,
the previous release's app, the updater test, and publishing."""
import json
import os
import shutil
import time

from common import (CACHE, Failure, app_from_dmg, download_asset, end_test_processes, forget_registrations, gh_api, git,
                    publish_release, push_source_tag, run, say)
from jobs import POOL


def write_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=1)
    return path


def gatekeeper_window(cpus=0):
    """What an updater test or a Gatekeeper check holds while it runs: the updater tests fail on any Gatekeeper prompt
    the unified log shows during their run, whichever process it was for (tools/updater-e2e/nodialogs.py), so the
    apps' tests of that kind, and the checks that hand Gatekeeper a quarantined copy, take turns when tools/release.sh
    builds several apps at once. An updater test also holds `cpus` of the pool (none for a check made inside a stage
    that holds some already)."""
    # An updater test is on its app's longest path: served before the test suites and platform builds waiting.
    return POOL.take(cpus=cpus, mem=cpus / 2, locks=("gatekeeper",), priority=-1000 if cpus else 0)


def gatekeeper_check(dmg, app_name, work, log):
    """A browser download, simulated: the app copied out of the stapled DMG (attached hidden), quarantined, must be
    accepted by Gatekeeper as Notarized Developer ID."""
    with gatekeeper_window():
        return _gatekeeper_check(dmg, app_name, work, log)


def _gatekeeper_check(dmg, app_name, work, log):
    run(["spctl", "-a", "-t", "open", "--context", "context:primary-signature", "-vv", dmg], log=log)
    shutil.rmtree(work, ignore_errors=True)
    mount = os.path.join(work, "volume")
    os.makedirs(mount)
    run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, dmg], log=log)
    try:
        run(["ditto", os.path.join(mount, app_name), os.path.join(work, app_name)], log=log)
    finally:
        run(["hdiutil", "detach", mount], log=log, check=False)
    app = os.path.join(work, app_name)
    stamp = f"0081;{int(time.time()):x};Safari;{os.urandom(16).hex().upper()}"
    run(["xattr", "-w", "com.apple.quarantine", stamp, app], log=log)
    verdict = run(["spctl", "-a", "-vv", app], log=log, capture=True, check=False)
    with open(log) as f:
        text = f.read()
    if "Notarized Developer ID" not in text.split("$ spctl -a -vv")[-1]:
        raise Failure(f"Gatekeeper did not accept the quarantined {app_name} as Notarized Developer ID; log: {log}")
    shutil.rmtree(work, ignore_errors=True)
    forget_registrations(work, log)  # the quarantined copy was registered when spctl looked at it
    return verdict


def check_displayed_release(release, dmg, app_name):
    """The app in the final DMG shows release.tag in About and the update dialog (displayed.py), or the run stops."""
    import displayed
    app = app_from_dmg(dmg, os.path.join(release.run_dir, "displayed", "app"), app_name, release.log("verify"))
    displayed.require(f"{app_name} in {os.path.basename(dmg)}", release.tag, displayed.mac_release_app(app))
    say(f"verify: {app_name} shows {release.tag}")


def latest_release_json(slug, log):
    return gh_api(f"repos/{slug}/releases/latest", log=log)


def previous_app(release, slug, asset, app_name):
    """The newest published release of `slug` other than this one: its JSON (saved for the updater test), and its app
    from its DMG, downloaded once into the cache and checked against GitHub's digest."""
    log = release.log("previous-release")
    listing = gh_api(f"repos/{slug}/releases?per_page=20", log=log)
    previous = next((r for r in listing if not r.get("draft") and not r.get("prerelease")
                     and r.get("tag_name") != release.tag), None)
    if not previous:
        raise Failure(f"{slug} has no published release before {release.tag}")
    tag = previous["tag_name"]
    folder = os.path.join(CACHE, "releases", slug, tag)
    dmg = download_asset(slug, previous, asset, folder, log)
    app = app_from_dmg(dmg, os.path.join(folder, "app"), app_name, log)
    shape = write_json(os.path.join(release.run_dir, "previous-release.json"), previous)
    return {"tag": tag, "app": app, "dmg": dmg, "release_json": shape}


def run_mac_update_e2e(release, kind, old, new_dmg, shape, stage):
    """tools/updater-e2e/mac-update-e2e.py: the published app `old` updates itself to `new_dmg`, hidden."""
    work = os.path.join(release.run_dir, "updater-e2e", f"{stage}-{time.strftime('%H%M%S')}")
    os.makedirs(os.path.dirname(work), exist_ok=True)
    log = release.log(stage)
    with gatekeeper_window(cpus=4):
        say(f"{stage}: {kind} {old['tag']} updates to {release.tag} (tools/updater-e2e)")
        try:
            code = run(["python3", "-I", os.path.join(release.wt, "tools/updater-e2e/mac-update-e2e.py"), "--kind",
                        kind, "--old-app", old["app"], "--new-dmg", new_dmg, "--notes", release.notes(), "--tag",
                        release.tag, "--shape", shape, "--work", work], log=log, check=False)
        finally:
            end_test_processes(work, log)
    if code != 0:
        raise Failure(f"updating from {old['tag']} to {release.tag} failed: {os.path.join(work, 'result.json')}")
    return work


def push_monorepo_tag(release, prefix):
    """The app-prefixed tag in this repository (pdf/26.10.20-1) at the released commit, pushed to origin."""
    log = release.log("publish")
    name = f"{prefix}/{release.tag}"
    local = git(release.repo, "rev-parse", "-q", "--verify", f"refs/tags/{name}^{{commit}}", check=False)
    if local and local != release.commit:
        raise Failure(f"the tag {name} is at {local[:12]}, not {release.short}")
    if not local:
        run(["git", "-C", release.repo, "tag", name, release.commit], log=log)
    remote = run(["git", "-C", release.repo, "ls-remote", "--tags", "origin", f"refs/tags/{name}",
                  f"refs/tags/{name}^{{}}"], log=log, capture=True)
    shas = dict(reversed(line.split("\t")) for line in remote.splitlines() if "\t" in line)
    at = shas.get(f"refs/tags/{name}^{{}}") or shas.get(f"refs/tags/{name}")
    if at and at != release.commit:
        raise Failure(f"origin's tag {name} is at {at[:12]}, not {release.short}")
    if not at:
        run(["git", "-C", release.repo, "push", "--quiet", "origin", f"refs/tags/{name}"], log=log)
    say(f"publish: {name} on origin at {release.short}")


def publish_common(release, app_dir, slug, *, title, files, prerelease, latest, notes=None):
    """The monorepo tag, the source tag on `slug`, then the GitHub release with its assets."""
    log = release.log("publish")
    push_monorepo_tag(release, release.app)
    push_source_tag(release.repo, app_dir, release.commit, slug, release.tag, log)
    return publish_release(slug, release.tag, title=title, notes_file=notes or release.notes(), files=files,
                           prerelease=prerelease, latest=latest, log=log)
