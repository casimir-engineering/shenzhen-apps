# Linux GTK4 Parity — Spec & Plan

Date: 2026-07-19. Branch: `linux-gtk4-parity`. Owner decisions captured 2026-07-19.

## Goal

Replace the frozen GTK3 frontend (`portable/linux/ShenzhenPDFGtk.c`, last touched
2026-06-18) with a GTK4 + libadwaita frontend at **full feature and interface
parity** with `portable/mac/` as of HEAD, validated with a capture matrix on the
dev machine (Ubuntu 25.10, GNOME 49, Wayland, GTK 4.20, libadwaita 1.8).

## Owner decisions

1. **Look & feel:** GNOME-native widgets/styling, same layout and information
   architecture as the Mac app.
2. **Distribution:** distro packages (deb first) + ported Mac-style auto-updater.
   Flatpak later only if benchmarked launch-neutral. Updater verifies releases
   with **minisign** (keypair generated during this effort; pubkey pinned in
   the binary, secret key stays on the owner's machine, never committed).
3. **Approach:** new GTK4 shell in modules, porting proven logic (render
   pipeline, zoom anchoring, minimap, search, OCR/translate) out of the GTK3
   file. GTK3 file retired at the end.
4. **Done bar:** all audit gaps closed + validated capture matrix committed to
   `portable/docs/` (like the June 2026 session).
5. **Launch speed is a headline requirement.** The app must *feel instant*.
   Measured reality (dev machine, 2026-07-19): an *empty* AdwApplicationWindow
   maps in ~285 ms — cold GTK4 init can never feel instant. Two-track strategy:
   - **Resident mode (the instant path):** GApplication uniqueness makes any
     open-while-running a D-Bus forward (measured 30 ms) + tab open + render.
     The app holds itself alive after the last window closes (small RSS: docs
     closed, caches dropped) and installs a login autostart entry. Setting
     `instantLaunchResident` (default on) controls both; disabling releases
     the hold and removes the autostart file. Budget: **≤100 ms from invoke
     to visible page** for every open after login.
   - **Cold path (once per login):** budget **≤350 ms to first page visible**.
     Force the measured-fastest GSK renderer (gl: startup 370→238 ms,
     present 692→455 ms vs default) via g_setenv default-only in main; trim
     the ~170 ms we currently spend above the empty-window floor (icon
     lookups, tab-bar construction, deferred everything); keep doc-open +
     first render ahead of window map. No synchronous I/O on the launch path;
     sidebar/minimap/metadata deferred; lazy OCR/translate init; updater
     check off-path (existing Mac rule). All measured via
     `SPDF_LAUNCH_PROFILE=1` (same env var as Mac).

## Architecture

`portable/linux/gtk4/` — C modules, GTK4 + libadwaita, sharing
`portable/core/shenzhen_pdf_core.{c,h}` and the Mac app's JSON state schemas
(`settings.json` — which also holds `recentlyOpened` —, `session.json`,
`documents.json`, `favorites.json`; byte-compatible).

| Module | Role (Mac counterpart) |
|---|---|
| `spdf_app.c` | `AdwApplication`, launch path, session restore, multi-window, `.desktop`/`xdg-mime` default-reader registration + prompt |
| `spdf_window.c` | `AdwApplicationWindow`, `AdwTabView`/`AdwTabBar` (drag reorder, detach, continuous-drag reattach, middle-click close, overflow), header bar, presentation mode + `gtk_application_inhibit` sleep prevention |
| `spdf_docview.c` | Custom canvas widget (GtkWidget snapshot/GdkTexture, no GtkImage-per-page): continuous layout, scroll clamping, anchored Ctrl+wheel/pinch zoom, cursor regions (I-beam/hand), click-vs-drag links, selection |
| `spdf_render.c` | Worker render pipeline: persistent worker docs, display-list cache, render tokens, 96 MB byte cap, crop-to-viewport, priority current page |
| `spdf_minimap.c` | Minimap with thumbnails, viewport drag, click-jump, hit markers, new strip-scroll model (Mac `db9515802`) |
| `spdf_search.c` | Type-anywhere incremental search + live count, regex/multiline, paste-to-search, selection-to-search, Escape/nearest-match behavior, scrollbar heat-map, per-tab query persistence |
| `spdf_sidebar.c` | Outline/TOC, comments, chapter-grouped search results with snippets |
| `spdf_palette.c` | Ctrl+K palette: favorites, cross-doc search, **all runnable commands** |
| `spdf_annot.c` | Highlights/comments CRUD, page rotate, single-page export |
| `spdf_ocr.c` / `spdf_translate.c` | Ported flows incl. toolchain auto-install (apt/dnf/pacman/zypper) and post-freeze translate refinements |
| `spdf_state.c` | JSON state read/write, workarea-clamped window restore |
| `spdf_watcher.c` | `GFileMonitor` auto-reload + read-only shadow-copy tabs (orange dot) |
| `spdf_print.c` | `GtkPrintOperation` with Fit / Actual Size / Custom scaling |
| `spdf_props.c` | Document properties panel (Ctrl+I), grouped like `SPDFMacPropertiesPanel` |
| `spdf_updater.c` | Daily GitHub Releases check, minisign verification, atomic swap + rollback, off launch path |
| `spdf_shortcuts.c` | Accels via `GtkApplication` actions + F1 cheat sheet |

Keyboard model: Mac `Cmd` → `Ctrl` (existing convention, e.g. Ctrl+Shift+T,
Ctrl+K, Ctrl+I, F5, F1).

## Parity gaps being closed (from 2026-07-19 audit)

Missing subsystems: printing, file watcher, auto-updater, default-reader
registration, sleep prevention, scrollbar heat-map, properties panel,
read-only shadow copy. Post-freeze Mac features: continuous-drag tab reattach,
middle-click close, paste/selection-to-search, command palette commands,
minimap strip-scroll, Escape/nearest-match search refinements, cursor regions,
click-vs-drag links, dark-mode tuning, translate pipeline refinements.
Known GTK3 defects fixed by design: toolbar ~1440 px minimum width (header bar
collapses into menus), window restore not clamped to workarea (clamp in
`spdf_state.c`), zoom-anchor drift on pixel-capped giant sheets.

## GTK4 notes (from migration audit)

Event signals → `GtkGestureClick`/`GtkEventControllerMotion|Scroll|Key`;
GtkMenu → `GMenu` + `GtkPopoverMenu` + `GAction`; `gtk_dialog_run` → async
dialogs (`GtkAlertDialog`/`GtkFileDialog`); GtkClipboard → `GdkClipboard`;
GtkImage-per-page → custom widget + `GdkTexture`; `GtkAccelGroup` →
`gtk_application_set_accels_for_action`; cairo drawing survives inside
`GtkDrawingArea` draw funcs (minimap, markers). `GtkGestureZoom` code ports
as-is.

## Build & packaging

- Toolchain container: `portable/linux/dev/Dockerfile` (Ubuntu 25.10 = host).
- Makefile target `linux-gtk4` (pkg-config `gtk4 libadwaita-1 openssl`,
  static in-tree MuPDF, same `mupdf-libs` prerequisite). GTK3 frontend and
  its `linux` target retired 2026-07-20 (see gtk4-parity-journal.md).
- `portable/linux/dev/build.sh` wraps the docker invocation.
- Deb packaging (`portable/linux/pkg/`): binary, `.desktop`, icon, MIME
  associations; versioned like the Mac release (26.x.y-b).
- Release signing: `minisign -S` step in `cut-release.sh` (Linux artifacts),
  pinned pubkey constant in `spdf_updater.c`.

### Auto-updater (Wave C, implemented in `spdf_updater.c`)

- **Assets the release must ship:** `ShenzhenPDF-linux-amd64.deb` (system
  installs) and `ShenzhenPDF-linux-amd64.tar.gz` containing the
  `ShenzhenPDF-gtk4` binary (user-local installs under `$HOME`), each with a
  detached `<asset>.minisig` signed by the key in
  `portable/linux/pkg/minisign.pub`. Both minisign modes verify ("ED"
  prehashed BLAKE2b-512 — the `minisign -S` default — and legacy "Ed");
  nothing is installed unless the signature verifies against the pinned key
  (keyid + Ed25519 via OpenSSL + global-signature check). Transport is a
  runtime-probed `curl` (else `wget`) via GSubprocess — no new build deps;
  the deb should `Recommends: curl`.
- **Install/rollback divergences from the Mac updater:** a deb install is
  root-owned, so install goes through `pkexec dpkg -i`; there is no
  automated `.old` rollback for the deb path — the previous release's `.deb`
  is retained in `~/.cache/shenzhenpdf/updates/<tag>/` for a manual
  `dpkg -i`. User-local installs get the Mac-style atomic swap
  (`rename` to `.old`, rename new into place, restore on failure) plus a
  bounded `--updater-health-probe` launch check that rolls the swap back if
  the new binary cannot start. Both paths record `pendingTag` in
  `update.json`; the next launch confirms it (`updateOk`, `.old` deleted,
  one-time banner) or logs the failed take and keeps `.old`.
- **State:** `autoUpdateEnabled` / `skippedUpdateVersion` stay in
  settings.json (spdf_state.c); the flock'd `update.json` (+`update.lock`)
  carries lastUpdateCheck / etag / highestVersionSeen / deferredTag /
  remindAfter / pendingTag / updateOk / lease{Pid,Timestamp}.
- **cut-release.sh TODO:** bump `SPDF_APP_VERSION` / `SPDF_APP_BUILD` in
  `portable/linux/gtk4/spdf_app.h` (new sixth bump location), build the two
  Linux assets, `minisign -S` them, and attach all four files to the GitHub
  release.

## Validation

- Unit tests where logic is pure C (tab strip geometry, search grouping,
  updater version compare/verify — mirroring `portable/mac/tests/`).
- GUI capture matrix on the dev machine (GDK_BACKEND=x11 under XWayland,
  xdotool input, ImageMagick `import` captures) covering at least the June
  matrix + every new subsystem; results + PNGs in
  `portable/docs/gtk4-captures/` and a session journal
  `portable/docs/gtk4-parity-journal.md`.
- Launch-time capture: `SPDF_LAUNCH_PROFILE=1` output recorded cold/warm,
  budget pass/fail stated in the journal.

## Execution waves

- **Wave 0** (this commit): toolchain image, spec, keypair, Makefile target,
  module scaffold that builds.
- **Wave A** — shell + canvas + render + state: opens PDFs, tabs, scroll/zoom,
  session restore. Launch profiling in from day one.
- **Wave B** — search + minimap + sidebars + palette + properties + annots.
- **Wave C** — printing, watcher/shadow-copy, updater, default reader, sleep
  inhibit, OCR/translate, cursor regions, dark mode.
- **Wave D** — launch-speed tuning to budget, defect fixes, capture matrix,
  deb packaging, readme/platform-support update, retire GTK3 file.

Each wave: agents implement module-sized chunks against this spec; integrator
(main session) builds in the container, fixes seams, commits per feature.
