# Releasing

Each app is released on its own: its own version, its own tags in this repository, its own release job. The GitHub
releases, and the update feeds installed apps read, stay on the repositories they have always been on:

| App | Version lives in | Tag here | GitHub release | Installed apps read |
| --- | --- | --- | --- | --- |
| ShenzhenPDF | `apps/pdf/portable/Makefile` | `pdf/26.10.20-1` | `26.10.20-1` | `releases/latest` |
| Shenzhen Files | `apps/files/package/make-app.sh` | `files/26.10.20-1` | `26.10.20-1` | `releases/latest` |
| Shenzhen 3D | `apps/3d/package.json` | `3d/preview-0.1.10` | `preview-0.1.10` | the `latest` feed |
| Friends host | (deployed, not released) | `friends-server/26.10.20-1` | none | |

The GitHub releases are made on `casimir-engineering/shenzhen-pdf`, `casimir-engineering/shenzhen-files` and
`casimir-engineering/shenzhen-3D`. Shenzhen 3D also publishes a second copy of each release, built for its own
owner, to the repository named by the `SHENZHEN_3D_MIRROR_OWNER` variable. Release names keep their old form
(`26.10.20-1`, `preview-0.1.10`): that is what installed apps compare, so they keep updating unchanged.

Only the tag in this repository carries the app prefix. `tools/release.sh` gives the old repository the plain tag at a
commit that holds the app's source as it was built (`apps/<app>` of the released commit, laid out as that repository
always was), so the release's Source code archives are what was built; [below](#source-code-on-the-release-repositories)
says how. Releases made before it, and the release jobs, put the plain tag at the old repository's default branch head:
there it marks the release and does not hold its source. Either way the prefixed tag here is the released commit.

This repository starts from a single commit and has none of the earlier releases' tags. The full history of each app
up to that commit, and the tags of every release made before it, are in `casimir-engineering/shenzhen-pdf`,
`casimir-engineering/shenzhen-files` and `casimir-engineering/shenzhen-3D`; look there for the source of an older
release.

## Before the first release from this repository

This repository has no release tags of its own yet; the earlier releases are tagged only in the original
repositories. Three things depend on that until each app's first release here:

- **Friends helper build number.** `tools/check-friends-number.sh` fails while the last commit to set `MAC_VERSION`
  or `MAC_BUILD` is this repository's first commit: that commit brought in all of Friends at once, and Friends had
  changed after the number was last raised (26.10.11 build 1). Preparing the first ShenzhenPDF release clears it.
- **Build numbers.** `cut-release.sh` counts the release tags on `casimir-engineering/shenzhen-pdf` as well as the
  `pdf/` tags here, so a release made the same day as one published before this repository existed gets the next
  build number, never the same one.
- **Launch performance baselines.** The gates compare with the previous release, which they find by its tag here.
  Without one, name it:
  - ShenzhenPDF (`make -C apps/pdf/portable mac-launch-performance-tests`, also part of the release tests):
    `LAUNCH_PERF_BASELINE_RELEASE=latest` (or a release such as `26.10.11-1`) uses the app in that release's DMG from
    `casimir-engineering/shenzhen-pdf`, downloaded once and checked against GitHub's digest;
    `LAUNCH_PERF_BASELINE_DMG=<dmg>` or `LAUNCH_PERF_BASELINE_APP=<app>` one you have. The previous release is never
    built from source: the gate measures the app people run. Without any of these the gate stops and says so.
    `tools/release.sh` and the `pdf.yml` and `release-pdf.yml` jobs set `LAUNCH_PERF_BASELINE_RELEASE=latest`.
  - Shenzhen Files (`apps/files/tools/test-macos-launch-performance.sh`): `--baseline-release latest` (or a release
    such as `26.9.14-1`) uses the app in that release's DMG from `casimir-engineering/shenzhen-files`;
    `--baseline APP` an app you have.
  - Shenzhen 3D has no release gate; its renderer benchmark (`apps/3d/tests/perf/README.md`) takes the earlier source
    with `--baseline-src=<dir>`.

Once an app has a release tag here, its gate finds the previous release by tag again.

## Before every release

1. **Friends helper build number.** Run `tools/check-friends-number.sh`. If Friends changed since the number was
   last raised, raise it first by preparing a ShenzhenPDF release (below), even if that release is published later.
   The rule and why: [FRIENDS.md](FRIENDS.md#the-helper-build-number). Every release job runs the same check.
   The check fails until the first ShenzhenPDF release prepared in this repository (see above). Prepare it before
   releasing Shenzhen Files or Shenzhen 3D.
2. Update the app's README "Latest" marker and its release notes, as each app's own guide says.
3. Merge to `main`, with a clean tree.

## One command per app

```sh
tools/release.sh pdf 26.10.21-1 --publish
tools/release.sh files 26.10.21-1 --publish
tools/release.sh 3d preview-0.2.2 --publish [--private-copy] [--platforms all]
```

It releases the commit checked out where it runs (`HEAD`, committed, on `origin/main` for `--publish`) and needs no
one at the keyboard: nothing appears on screen, nothing asks a question, Finder is never scripted. Without
`--publish` it is a dry run: everything up to publishing, including the real notarization (Apple keeps the
submission; nothing is published, no tag is pushed), which also runs for a version the commit does not set, with the
committed version's notes, to try the pipeline. With `--publish` the version must be the committed one.

| Stage | ShenzhenPDF and Shenzhen Files | Shenzhen 3D |
| --- | --- | --- |
| build | the app: `make mac-app` in release mode; Friends, Nautilus and `package/make-app.sh` | `node_modules`, the Friends helper and addon |
| sign | every bundle inside out with the Developer ID, hardened runtime, secure timestamp, then checked | checked (signed by `package`) |
| package | the DMG, laid out from `DMG_LAYOUT_DS_STORE`, signed | `electron/package-mac.mjs`: frontend, signed app, ZIP and DMG |
| notarize | the DMG, and **the test suites at the same time** | every owner's DMG, and the test suites |
| staple | the DMG; Gatekeeper checks a quarantined copy of the app | the app (zipped again for the updater) and the DMG (`electron/notarize-finalize.mjs`) |
| verify | `tools/updater-e2e`: the published release updates itself to the candidate | the same, for every owner |
| publish | tags, source, the GitHub release (below) | the same, for every owner |
| live-check | the previous release updates to the published one, as GitHub now lists it | the same |

At the end it prints how long each stage took. The output, logs and stamps of a run are in
`~/Library/Caches/shenzhen-build/runs/<app>/<version>/<commit>/` (`SHENZHEN_BUILD_CACHE` moves the whole cache).

**Resuming.** A finished stage writes a stamp for that commit and version with the digests of what it made. Running
the same command again skips every stage whose output is intact and starts at the first one that is not: after a
failure, a network error or Ctrl-C, run it again. A notarization submission is recorded as soon as Apple has the file,
so a rerun waits for that submission instead of uploading again. Network errors are retried (notarytool, GitHub).

**Tests.** The suites a release needs: every `*-tests` target of `apps/pdf/portable/Makefile` (the release sweep, the
Friends suite and the launch performance gate among them); `apps/files/tools/test-friends-adapter.sh` and
`test-macos-friends-shortcut.sh`; Shenzhen 3D's `npm test`, `test:electron` and `test:friends`. Each one that passes
is recorded by `tools/test-stamp.sh` for the commit, and a suite that passed on the same commit is not run again,
whoever ran it: `make -C apps/pdf/portable friends-tests` and `mac-launch-performance-tests`, `cut-release.sh`'s sweep
and the Files test scripts record themselves too. A stamp is filed under the sources the app's suites build from
(`apps/pdf`; `apps/files` or `apps/3d` with `apps/pdf`), so a commit that changes none of them, such as another app's
release, keeps it; a worktree with uncommitted changes records nothing. The missing suites run while Apple notarizes. A
failed suite stops a publish before anything is published; a dry run carries on and says the candidate is not
releasable. The launch performance gate runs once, against the previous release's DMG.

**Caches**, in `~/Library/Caches/shenzhen-build`, shared by every worktree and kept between releases:

- `worktrees/<app>`: a worktree of this repository per app, moved to the commit being released. Only the files that
  differ are rewritten, so ignored build output stays and make, ninja (the Nautilus `build/`) and cargo rebuild only
  what changed. ShenzhenPDF's own code is still built from scratch in each run, as `build-mac-release.sh` did.
- `friends-deps/<key>` and MuPDF's `build/release-macos-arm64-12.0-<key>`: the third-party libraries, keyed by the
  content of `apps/pdf/ext` and `apps/pdf/mupdf`.
- `node_modules/3d-<lock>`: Shenzhen 3D's `node_modules` for one `package-lock.json`, cloned copy-on-write into a
  worktree that needs it; npm's own cache serves `npm ci`.
- `releases/<owner>/<repo>/<tag>`: previous releases' DMGs and apps, for the updater test and the launch gate.
- `test-stamps/<content>`: the suites that passed.

No ccache or sccache is used: neither is installed here, and the release tool installs nothing.

**Publishing**, with `--publish`, after every check above has passed:

1. the prefixed tag here (`pdf/26.10.21-1`) is pushed to `origin` at the released commit;
2. the plain tag on the release repository is pushed at the source commit described below;
3. the GitHub release is created there as a draft, its assets uploaded in parallel, then checked against the release
   JSON: every asset present, `uploaded`, its size, and GitHub's `digest` equal to the sha256 of the built file. Nothing
   is downloaded again. Only then is it published (ShenzhenPDF and Shenzhen Files as the latest release, a Shenzhen 3D
   preview as a prerelease). A release already published with exactly these assets counts as done; one with other
   bytes stops the run.

### Source code on the release repositories

Installed apps read the old repositories, so the releases stay there, but this repository holds the source. For each
release `tools/release.sh` makes one commit whose tree is `apps/<app>` of the released commit, exactly, and pushes it to
the release repository as the plain tag (`26.10.21-1`). Its parent is the commit of that repository's previous
release tag, so the release tags form one line of history there, and its message names the commit here. The GitHub
release is made on that tag, so its Source code archives are the source that was built. The commit is made in a bare
mirror under the cache that borrows this repository's objects, so a push sends only what changed since the previous
release. Nothing else on the release repositories changes: their default branches stay where they are.

This keeps the archive in the layout the app's own guides describe (the old repository's root is `apps/<app>`).
Shenzhen Files and Shenzhen 3D build Friends from `apps/pdf` of the same commit, which their archive does not hold;
the ShenzhenPDF archive of a release from the same commit, or the prefixed tag here, does.

### Shenzhen 3D

- Only the DMG is notarized. Apple's ticket for a submission covers every piece of code in it, so the app inside
  staples from the DMG's ticket and is zipped again for the updater; the ZIP is never uploaded to Apple. The DMG ships
  as it was submitted, holding the app as signed, and its own stapled ticket covers that app, as ShenzhenPDF's and
  Shenzhen Files' DMGs always have.
- The DMG is LZMA-compressed (`ULMO`, macOS 10.15 and later; the app needs 13.0): the same volume, about a fifth
  smaller than electron-builder's zlib image.
- `--private-copy` also builds and publishes the copy for the owner in `SHENZHEN_3D_MIRROR_OWNER`, from a tree derived
  from this commit: `SHENZHEN_3D_PRIVATE_RULES` names the file of ordered replacements applied to `apps/3d`
  (`old==>new`, or `regex:pattern==>new`), and `SHENZHEN_3D_MIRROR_AUTHOR` (`Name <email>`) signs its source commit.
  Neither lives in this repository.
- `--platforms all` also builds the web ZIP, Android and the iOS Simulator here and the Linux and Windows installers in
  the Parallels VMs (`scripts/friends/tauri-vm.sh`, with its `SZF_VM_*` settings; the VMs are resumed for the build and
  suspended after), and publishes them with the Mac assets and a `SHA256SUMS.txt`.

## Installer images without Finder

ShenzhenPDF's and Shenzhen Files' DMG scripts lay out the installer window by scripting Finder, which mounts the
image where it can be seen and needs Automation permission. Where that is not possible (a session nobody watches),
set `DMG_LAYOUT_DS_STORE` to the layout the last release's Finder wrote: `apps/pdf/portable/mac/dmg-layout.DS_Store`
or `apps/files/package/dmg-layout.DS_Store`. The image is then attached without showing in Finder and gets that
layout: the same window, background and icon positions, since the volume, app and background names are unchanged.

## ShenzhenPDF

```sh
apps/pdf/portable/cut-release.sh --prepare-only "summary"   # on a release branch: sets MAC_VERSION, MAC_BUILD, notes
# merge to main and push, then:
tools/release.sh pdf <version>-<build> --publish            # on main: everything else (above)
```

The GitHub release `<version>-<build>` and its DMG go to `casimir-engineering/shenzhen-pdf`; the tag here is
`pdf/<version>-<build>`. `cut-release.sh --publish` still works the old way (tests, a clean signed build, the release
verified by downloading it again) and `--dry-run` runs the release tests; both skip the suites that passed on the commit
already. Instead of a Mac, the release job (`.github/workflows/release-pdf.yml`) can make the same release from a pushed
`pdf/<version>-<build>` tag. Use one way for a release, not two.

## Shenzhen Files

Set `SHORT_VERSION`, `RELEASE_BUILD` and `BUNDLE_VERSION` in `apps/files/package/make-app.sh`, write the release
notes `apps/files/docs/release-<SHORT_VERSION>-<RELEASE_BUILD>.md`, update the README's "Latest" marker, merge and
push, then run `tools/release.sh files <SHORT_VERSION>-<RELEASE_BUILD> --publish`. The tag is
`files/<SHORT_VERSION>-<RELEASE_BUILD>` here; the release `<SHORT_VERSION>-<RELEASE_BUILD>` with
`ShenzhenFiles-mac-arm64.dmg` goes to `casimir-engineering/shenzhen-files`. `apps/files/package/README.md`
§ Release procedure describes the older way, `package/sign-and-notarize.sh`, which builds the signed DMG and uploads it
to a release made by hand. The release job
(`.github/workflows/release-files.yml`) runs it with `--prepare-only --skip-install`, which only builds and checks
the DMG, then creates the GitHub release itself with those notes and checks the uploaded file's digest. It stops if
the tag does not match `make-app.sh` or the notes file is missing.

## Shenzhen 3D

Raise `version` in `apps/3d/package.json` (and `package-lock.json`), write the release notes
`apps/3d/docs/MAC-<version>.md`, merge and push, then run `tools/release.sh 3d preview-<version> --publish`
(`apps/3d/docs/UPDATES.md` explains the feed it publishes). The tag is `3d/preview-<version>` here (or
`3d/v<version>` for a stable release). The release job (`.github/workflows/release-3d.yml`) runs the unit, Electron
and Friends tests, packages the signed Electron app once per release owner (`--release-owner=casimir-engineering`,
then the mirror's owner), notarizes its ZIP and DMG, and uploads each build to its own owner's `shenzhen-3D`, as a
draft until every asset's digest is verified. Its `prerelease` input publishes the release as a prerelease. It stops
if the tag does not match `package.json` or the notes file is missing.

The workflows that assemble large assets inside a release repository (`assemble-release-asset.yml`,
`assemble-release-zip-delta.yml`) stay in the old `shenzhen-3D` repositories: they act on that repository's own
releases and run there.

## Friends host

The host is deployed, never released. Tag the commit to deploy `friends-server/<YY.M.D>-<N>`, push the tag and start
the deploy job (`.github/workflows/deploy-friends-server.yml`) for it. It runs the host's tests and, after approval
in the `friends-host` environment, copies `apps/pdf/portable/server/friends` at that tag to the host and rebuilds
its stack, as `apps/pdf/portable/server/friends/deploy/DEPLOY.md` § 9 does by hand:

```sh
git archive friends-server/26.10.20-1:apps/pdf/portable/server/friends | ssh root@<host> \
  'rm -rf /opt/stacks/friends/src/* && tar -x -C /opt/stacks/friends/src'
```

Deploy only with the owner's approval.

## Release jobs

The `release-*.yml` and `deploy-friends-server.yml` workflows start only by hand (Actions, Run workflow), for an
existing tag of their own (`pdf/*`, `files/*`, `3d/*`, `friends-server/*`), and only in the `casimir-engineering`
organization. Pushing a tag starts nothing. The build and
test workflows (`pdf.yml`, `files.yml`, `3d.yml`, `friends-server.yml`) run on pull requests and pushes that touch
their app: `apps/<app>/**`, and for Files and 3D also what their Friends build reads from ShenzhenPDF:
`apps/pdf/portable/friends/**`, `apps/pdf/portable/Makefile` and the libraries Friends links in `apps/pdf/ext/`
(cjson, libdatachannel, libjuice, libsodium, mbedtls, miniupnpc, plog, usrsctp).

Secrets and variables, set on this repository:

- `SHENZHEN_RELEASE_TOKEN` (secret): a fine-grained token, owner `casimir-engineering`, with Contents read and write
  on `shenzhen-pdf`, `shenzhen-files` and `shenzhen-3D` only.
- `SHENZHEN_3D_MIRROR_TOKEN` (secret): a fine-grained token for the mirror's owner, Contents read and write on its
  `shenzhen-3D`.
- `SHENZHEN_3D_MIRROR_OWNER` (variable): the mirror's GitHub owner; leave it unset to skip the second copy.
- `MAC_CERTIFICATE_P12`, `MAC_CERTIFICATE_PASSWORD` (secrets): the Developer ID Application certificate, base64.
- `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` (secrets): an App Store Connect API key for notarytool.
- `FRIENDS_HOST_SSH_KEY`, `FRIENDS_HOST_KNOWN_HOSTS`, `FRIENDS_HOST_ADDRESS` (secrets of the `friends-host`
  environment, which should require the owner's approval): the deploy job's SSH access.
- `FRIENDS_INGRESS_CONTAINER` (variable): the ingress container the deploy job reloads; unset, it asks for a
  reload by hand.

A fine-grained token is limited to one owner, hence one token per owner. The jobs pass it to `gh` as `GH_TOKEN` with
`--repo` set explicitly, so nothing is published to this repository by mistake.
