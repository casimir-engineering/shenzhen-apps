# Portable Shenzhen PDF

`portable/` contains the shared MuPDF-backed core plus the native macOS and
Linux frontends for Shenzhen PDF. The goal is a small, native reader on each
desktop platform: the portable layer owns document work, and each frontend owns
the platform UI instead of emulating the Windows application.

## Layout

- `core/`: platform-neutral APIs for opening documents, rendering pages,
  searching, extracting selected text, loading outlines/comments, rotating
  pages, detecting text before OCR, and saving edited PDFs.
- `mac/`: native AppKit application bundle frontend.
- `linux/`: native GTK frontend using the same core API and YAML state shapes.
- `docs/`: direct-GitHub release, updater, and portability notes.

## Frontend Snapshot

The macOS frontend is the most mature portable frontend today. Recent work has
focused on making it feel like a fast daily reader: restored tab/window
sessions, resident per-tab document caches, current-page-first rendering,
background preloading, responsive live zoom/resize behavior, smoother trackpad
panning, detachable tabs, presentation mode, native window arrangement
shortcuts, default-reader setup, and high quality PDF printing through the
macOS print pipeline.

The Linux GTK frontend shares the portable core, data formats, rendering/search
paths, OCR/translation integration points, and much of the reader model. Some of
the latest UI polish is macOS-specific, but the GTK target remains a first-class
portable frontend rather than a compatibility shim.

## Reader Features

- Compact tabbed UI with drag/drop open, recent documents, favorites, restored
  sessions, remembered zoom/scroll/page state, and command palette support.
- Continuous and single-page modes, fit width/height/page, actual size, custom
  zoom memory, smooth zooming, panning, and scroll-wheel page navigation.
- `Cmd+F`/`Ctrl+F` search with match counters, highlights, keyboard navigation,
  regex mode, per-document memory, and minimap result markers.
- macOS Search sidebar that appears while searching, groups contextual result
  snippets by chapter, and keeps selection synced with next/previous navigation.
- Chapters and comments side panels with filtering and jump behavior.
- Right-side document map with page separations, viewport rectangle,
  proportional dragging, search markers, remembered visibility/width, and
  special handling for long documents and single-page PDFs.
- OCR via OCRmyPDF/Tesseract with installer flow, progress log, language
  selection, Chinese traineddata support, backup creation, save-back, and
  automatic reload.
- Offline translation via Argos Translate with language package installation and
  translated PDFs saved next to the original.
- Human-readable YAML state under the platform application-support/config
  directory: `settings.yaml`, `session.yaml`, `documents.yaml`,
  `favorites.yaml`, and (macOS) `bookmarks.yaml`; recents live inside
  `settings.yaml`. Legacy `.json` files are auto-migrated on launch, with the
  originals kept as `<name>.json.migrated-backup`.

## macOS

Build the app:

```sh
make -C portable mac-app
```

Build and install locally:

```sh
make -C portable install
```

Build a DMG:

```sh
make -C portable dmg
```

Common artifacts:

```text
dist/ShenzhenPDF.app
dist/ShenzhenPDF-mac-arm64.dmg
/Applications/ShenzhenPDF.app
```

Readable state files live under:

```text
~/Library/Application Support/ShenzhenPDF/
```

Collection is packaged as a small, separately signed helper in
`Contents/Helpers/ShenzhenPDF Collection.app`. Its source list lives in
`mac/companion/sources.mk`: it shares PDFKit and the Markdown renderer, without
linking the reader or MuPDF. `make -C portable mac-collection-companion-link-tests`
checks this exact source set headlessly, including encrypted previews over the
private credential pipe. The helper starts only when Collection is opened.

Local development builds are ad-hoc signed. Public direct-download releases
should be Developer ID signed and notarized.

## Linux

Ubuntu/Debian:

```sh
sudo apt install build-essential pkg-config libgtk-3-dev libssl-dev
make -C portable linux
./portable/build/ShenzhenPDF-gtk
```

Fedora:

```sh
sudo dnf install gcc make pkgconf-pkg-config gtk3-devel openssl-devel
make -C portable linux
./portable/build/ShenzhenPDF-gtk
```

Readable state files live under:

```text
~/.config/shenzhenpdf/
```

## Direct-GitHub Releases

Release metadata and notes are committed before a candidate is built. Prepare
the metadata on a release branch without any publishing side effects:

```sh
./portable/cut-release.sh --version 26.8.27 --build 1 --prepare-only \
  "concise release summary"
```

After reviewing that commit on `master`, explicitly publish the already-
committed metadata. The command builds a clean arm64/macOS 12.0 DMG, signs it
with Developer ID, submits it for notarization, authenticates it before mount,
verifies the app before execution, then tags and publishes:

```sh
./portable/cut-release.sh --publish
```

Publication is resumable. Rerunning `--publish` accepts refs and a GitHub
release only when they resolve to the exact prepared commit, replaces the
named DMG asset when needed, and downloads it again for a SHA-256 comparison.
Any conflicting tag or asset fails closed.

A build number is spent only once its tag reaches the remote. `--prepare-only`
stops before tagging, so a prepared-but-unpublished release can be re-prepared
at the same version and build as many times as needed; do not increment the
build number for a release that was never tagged and pushed.

`readme.md` must describe what the release ships. Preparation fails when the
README's content has not changed since the previous tag — the automated version
badge does not count — so a headline feature cannot ship undocumented. A release
that genuinely changes nothing user-visible states that with
`SPDF_README_UNCHANGED=1`.

The staged draft release is verified through `gh release view`. GitHub's REST
"get a release by tag name" endpoint never resolves a draft, because a draft
carries no server-side tag until it is published.

To build the already committed metadata without tagging, pushing, or publishing:

```sh
./portable/build-mac-release.sh
```

Signing configuration is read from the ignored `portable/.release.env`; start
from `.release.env.example`. Team ID `66LJ4BV7Q3`, bundle ID
`com.intuition.shenzhenpdf`, arm64, macOS 12.0, and release optimization flags
are pinned by the release path. Release notes are tracked under
`portable/docs/releases/`.

## Agent tools (macOS)

The optional [native CLI and MCP adapter](docs/agent-interface.md) inspect
documents and navigate to pages or highlighted passages. They are invoked
explicitly and add no service to normal reader startup.

## Notes For Contributors

- Keep cross-platform reader behavior in `core/` when possible, and keep
  platform-specific UI behavior in the frontend directories.
- Prefer the existing YAML state formats (shared codec in `core/spdf_yaml.c`)
  so macOS and Linux can continue to share document/session/favorites
  semantics.
- Treat macOS-only polish as macOS-only in docs until the GTK frontend has the
  same behavior implemented and validated.

### Refresh the public README images

The image fixtures use actual native reader and Collection components with fictional
content and isolated temporary state. They never launch the installed app or capture
the screen. Build and render them, then crop/encode the images with Pillow:

```sh
make -C portable -f Makefile -f mac/tests/workspace-probe.mk \
  mac-workspace-probe mac-readme-probe WORKSPACE_EVIDENCE_DIR=/tmp/sz-readme-evidence
python3 portable/mac/tests/refresh-readme-images.py /tmp/sz-readme-evidence
```

The cross-document AI comparison image uses an additional scripted, offline
fixture with fictional plans and the production chat/card components:

```sh
make -C portable -j8 -f Makefile -f mac/tests/workspace-probe.mk \
  mac-ai-readme-probe WORKSPACE_EVIDENCE_DIR=/tmp/sz-ai-readme
```

This writes `macos-ai-chat.png`; review it before copying it into
`docs/images/portable/`. It does not contact a model or demonstrate model accuracy.

Check both commands' exit status and review the images before committing. Screenshot
fixtures and crop recipes live under `portable/mac/tests/`; changing them does not
change the reader's runtime behavior.
