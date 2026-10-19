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

Only the tag in this repository carries the app prefix. When a release job creates the GitHub release, the old
repository gets the plain tag at its default branch's head; that tag marks the release, it does not hold its source.
The source of every release is the prefixed tag here.

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
    `LAUNCH_PERF_BASELINE_RELEASE=latest` (or a release such as `26.10.11-1`) downloads that release's source from
    `casimir-engineering/shenzhen-pdf` and builds it; `LAUNCH_PERF_BASELINE_SRC=<dir>` builds an unpacked source tree
    instead. Without either the gate stops and says so. The `pdf.yml` and `release-pdf.yml` jobs set
    `LAUNCH_PERF_BASELINE_RELEASE=latest` themselves while there is no `pdf/` tag before the commit they test.
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

## ShenzhenPDF

```sh
apps/pdf/portable/cut-release.sh --prepare-only "summary"   # on a release branch: sets MAC_VERSION, MAC_BUILD, notes
# merge to main, then:
apps/pdf/portable/cut-release.sh --publish                  # on main: tests, signed build, tag pdf/<v>-<b>, release
```

In this repository `cut-release.sh` tags `pdf/<version>-<build>`, publishes from `main` and pushes `main` and that
tag to this repository's `origin`; the GitHub release `<version>-<build>` and its DMG go to
`casimir-engineering/shenzhen-pdf`. Instead of `--publish` on a Mac, push the `pdf/<version>-<build>` tag yourself
and start the release job (`.github/workflows/release-pdf.yml`) for it: it runs the release tests, makes the signed
build and creates the same GitHub release. Use one or the other for a release, not both.

## Shenzhen Files

Set `SHORT_VERSION`, `RELEASE_BUILD` and `BUNDLE_VERSION` in `apps/files/package/make-app.sh`, write the release
notes `apps/files/docs/release-<SHORT_VERSION>-<RELEASE_BUILD>.md` and follow `apps/files/package/README.md`
§ Release procedure. The tag is `files/<SHORT_VERSION>-<RELEASE_BUILD>` here; the release
`<SHORT_VERSION>-<RELEASE_BUILD>` with `ShenzhenFiles-mac-arm64.dmg` goes to `casimir-engineering/shenzhen-files`.
On a Mac, `package/sign-and-notarize.sh` builds the signed DMG and uploads it. The release job
(`.github/workflows/release-files.yml`) runs it with `--prepare-only --skip-install`, which only builds and checks
the DMG, then creates the GitHub release itself with those notes and checks the uploaded file's digest. It stops if
the tag does not match `make-app.sh` or the notes file is missing.

## Shenzhen 3D

Raise `version` in `apps/3d/package.json` (and `package-lock.json`), write the release notes
`apps/3d/docs/MAC-<version>.md`, then follow `apps/3d/docs/UPDATES.md`. The tag is `3d/preview-<version>` here (or
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
