# Updating from the published release

These tests run the **published** previous build of each app, unchanged, against a local copy of GitHub that serves
the new release, and check that it finds, downloads, verifies and installs it. Nothing reaches the screen, no request
leaves the machine, and nothing outside the test's work directory is touched. Run them before publishing a release,
with the signed and notarized candidate.

## ShenzhenPDF and Shenzhen Files

```sh
python3 tools/updater-e2e/mac-update-e2e.py --kind pdf|files --old-app <published app> --new-dmg <candidate DMG> \
  --notes <release notes> --tag <YY.M.D-N> --shape <releases/latest JSON> --work <new directory>
```

`--old-app` is the app from the previous release's DMG; `--shape` is that release's `releases/latest` answer
(`gh api repos/casimir-engineering/<repo>/releases/latest`), rewritten for the candidate. The copy is signed ad hoc
and gets `LSUIElement`, so `szut.m` (built into the work directory) can be inserted. The library answers every request
from the local copy (the asset through GitHub's 302), keeps windows off screen, answers alerts with their first
button, drops distributed notifications, and lets the updater see and quit only processes inside the work directory:
the published helpers force-quit every running copy of their app after 20 s otherwise. Stages, each in `result.json`:
the old app's daily check offers the tag and installs it; the bundle at its path is the DMG's app (CDHash, files),
notarized; the new app's first launch confirms the tag (`update_ok`) and removes `.old`. The copies are unregistered
from LaunchServices at the end.

## Shenzhen 3D

```sh
cd apps/3d
node ../../tools/updater-e2e/prep-3d-fixture.mjs <published Shenzhen 3D.app> <dir>   # then sign it again with the
                                                                                    # Developer ID (Squirrel checks it)
node ../../tools/updater-e2e/update-e2e-3d.mjs --owner=<owner> --fixture=<signed fixture> --artifacts=<notarized
  output> --shape=<releases JSON> --notes=<notes> --work=<new directory> --expect-access=public|private
  [--relaunch-app=<hidden, signed copy of the candidate>] [--expect-owner=<owner>] [--next-app=<signed newer copy>] [--live]
```

The fixture is the published app with `electron/hidden-hook.cjs` loaded before its main and `LSBackgroundOnly`; its
updater code is the release's. The updater's session goes through a local proxy to the local copy of GitHub; global
fetch (the GitHub access check of private builds) goes there too; safeStorage is an in-memory stand-in. The copies
run with `CFFIXED_USER_HOME` in the work directory, so Squirrel's cache and ShipIt state stay there, apart from any
Shenzhen 3D that is running; this run's ShipIt job is removed afterwards (a running one stops the test). With `--relaunch-app`, the installed
version then starts with the same profile and checks its own feed: without any credential for a public build, with
the connected one for a private build.

Moving a private channel to the public one (`apps/3d/docs/UPDATES.md`): `--owner` is the private owner, whose release
carries the public candidate, `--expect-owner` the public owner and `--expect-access=public`. The relaunched candidate
must then read only the public owner's releases, with no credential and none saved. With `--next-app` (a later version:
`prep-3d-fixture.mjs <candidate> <dir> --version=<newer>`, then signed with the Developer ID) the public owner lists it
too, and the relaunched candidate must install it in place of itself. `--live` uses the real GitHub instead of the
local copy, once the releases are published: the released app connects with the GitHub CLI login, and `--artifacts`
holds the published Mac assets for the hash checks. With `--next-app` the install replaces the relaunch copy, so make
a new one for each run.
