# Shenzhen

The source of the Shenzhen apps and of Shenzhen Friends, in one repository.

| Path | What it is | Released from |
| --- | --- | --- |
| `apps/pdf` | ShenzhenPDF | `casimir-engineering/shenzhen-pdf` |
| `apps/pdf/portable/friends` | Shenzhen Friends: helper, client, views, Rust core, Tauri plugin | in every app |
| `apps/pdf/portable/server/friends` | The Friends host (server) | deployed from `friends-server/…` tags |
| `apps/files` | Shenzhen Files, the macOS port of GNOME Files, kept as patches | `casimir-engineering/shenzhen-files` |
| `apps/3d` | Shenzhen 3D, the CAD, mesh and drawing viewer (web, Electron, Tauri) | `casimir-engineering/shenzhen-3D` |
| `tools/` | Scripts for the whole repository: the Friends build number check, CI signing | |
| `docs/` | [Releasing](docs/RELEASING.md), [Friends in this repository](docs/FRIENDS.md) | |

Each app keeps its own version, its own tags (`pdf/…`, `files/…`, `3d/…`) and its own release job. Releases and
update feeds are still published on the three existing GitHub repositories, so installed apps keep updating as
before. One command releases an app, unattended: `tools/release.sh <pdf|files|3d> <version> --publish`; see
[docs/RELEASING.md](docs/RELEASING.md).

## Building

Every app builds from its own directory, as it did in its own repository. The root `Makefile` wraps the common
commands; `make help` lists them.

### ShenzhenPDF

```sh
make -C apps/pdf/portable mac-app            # dist/ShenzhenPDF.app
make -C apps/pdf/portable friends-suite      # Friends tests (set FRIENDS_TEST_COTURN for the relay ones)
LAUNCH_PERF_BASELINE_RELEASE=latest make -C apps/pdf/portable mac-launch-performance-tests LAUNCH_PERF_ROUNDS=3
```

`apps/pdf/portable/README.md` has the rest, including the GTK and Windows builds. The launch performance gate
compares with the previous release; until this repository has a `pdf/` release tag, name it as above
([docs/RELEASING.md](docs/RELEASING.md#before-the-first-release-from-this-repository)).

### Shenzhen Files

Needs the Homebrew packages listed in `apps/files/README.md`.

```sh
apps/files/tools/setup-friends.sh            # builds Friends from apps/pdf in this tree
apps/files/tools/setup-nautilus-tree.sh      # upstream Nautilus + patches/, built into apps/files/install
apps/files/package/make-app.sh               # apps/files/dist/Shenzhen Files.app
apps/files/tools/test-friends-adapter.sh     # the Friends host adapter, with and without Friends
```

### Shenzhen 3D

```sh
cd apps/3d
npm ci
npm test && npm run test:electron
scripts/friends/setup-friends.sh             # builds Friends from apps/pdf in this tree
npm run test:friends
```

`apps/3d/docs/BUILDING.md` covers the Electron and Tauri packages.

## Shenzhen Friends

Shenzhen Files and Shenzhen 3D build Friends from `apps/pdf/portable/friends` in the same checkout: nothing is
pinned or fetched. Their old pinned mode (`friends.lock`) still works for anyone building the old standalone
repositories, and `SZF_FRIENDS_MODE=pinned` selects it here. [docs/FRIENDS.md](docs/FRIENDS.md) explains the helper
build number rule and the plan to move Friends to a top-level `friends/`.

## Licence

ShenzhenPDF, Shenzhen Files and Shenzhen 3D are free software under the GNU General Public License, version 3
(Shenzhen 3D and Shenzhen Files: version 3 or any later version). ShenzhenPDF includes MuPDF, which is under the
GNU Affero General Public License, version 3. See `apps/pdf/COPYING`, `apps/files/LICENSE` and `apps/3d/LICENSE`, and
the notices in each app, for the details and for third-party components.

## History

This repository starts from a single commit holding the three apps as they were when they were brought together.
Their full histories, with every earlier release tag, stay in the original repositories:
[casimir-engineering/shenzhen-pdf](https://github.com/casimir-engineering/shenzhen-pdf),
[casimir-engineering/shenzhen-files](https://github.com/casimir-engineering/shenzhen-files) and
[casimir-engineering/shenzhen-3D](https://github.com/casimir-engineering/shenzhen-3D). Those repositories also keep
publishing the releases and update feeds (see [docs/RELEASING.md](docs/RELEASING.md)).
