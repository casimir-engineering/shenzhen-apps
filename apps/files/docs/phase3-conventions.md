# Phase 3 conventions — contract for the five parallel feature workers

Foundation state (already landed, do not redo): the meson build gates an
Objective-C toolchain + Apple framework linkage on `-Dmacos_port=true`, and
every darwin-only Phase 3 source file is **already created and registered**
in `src/meson.build`. All stubs compile and the binary launches. Your job is
to fill in your stubs and wire up your call sites — **never touch shared
build files**.

## 1. File-ownership map

Each worker may edit **only** the files in its row (plus create scratch
files under `docs/` for notes). If you believe you need to edit a file
outside your row, stop and escalate to the integrator instead.

| Worker | Feature | Owned files (all under `nautilus/src/` unless noted) |
|---|---|---|
| **W1** | Menu bar + LaunchServices | `nautilus-application.c`, `nautilus-macos-menu.m`, accel/menu definitions under `resources/ui/` and `resources/` (gresource-listed UI files) |
| **W2** | Selection actions (Trash / Open With / QuickLook preview) | `nautilus-files-view.c`, `nautilus-mime-actions.c`, `nautilus-app-chooser.c`, `nautilus-sidebar.c`, `nautilus-previewer.c`, `nautilus-macos-trash.m`, `nautilus-macos-openwith.m`, `nautilus-macos-previewer.m` |
| **W3** | QuickLook thumbnails | `nautilus-thumbnails-macos.c`, `nautilus-macos-thumbnailer.m` |
| **W4** | Spotlight search | `nautilus-search-engine.c`, `nautilus-search-engine-*.c/h`, `nautilus-search-engine-spotlight.c` (exists as an empty stub, **already registered in meson** — do not touch meson), `nautilus-macos-spotlight.m` |
| **W5** | Finder drag & drop | `nautilus-dnd.c`, `nautilus-files-view-dnd.c` |

Known overlap hazard: W1 and W2 both border `nautilus-files-view.c`
action-town. The split is: W2 owns `nautilus-files-view.c`; W1 keeps menu
work in `nautilus-application.c` + UI resources and references existing
GAction names only. If W1 needs a new action *implemented* in the files
view, W1 specifies it and W2 lands it.

If W4 needs a header for `nautilus-search-engine-spotlight.c`, declare the
constructor in the C file's own top or append it to `nautilus-macos-bridge.h`
in the W4 section — do **not** create a new `.h` (it would need a meson
registration).

## 2. Shared header rule — `src/nautilus-macos-bridge.h`

The one shared seam. It is **append-only** and split into clearly-delimited
sections, one per worker (`Section W1` … `Section W5`):

- Append new prototypes **only inside your own section**.
- Never reorder, rename, or edit another worker's section — not even
  whitespace (this keeps the sections merge-conflict-free).
- Pure C prototypes only: no Objective-C types. GLib / GdkPixbuf /
  GdkTexture types are fine.
- Signature changes to *existing* seams are allowed inside your own section
  only if you also update all call sites you own; if another worker calls
  your seam, coordinate through the integrator.
- Every non-static function in a `.m` file must have its prototype here
  (Objective-C files don't get `-Werror=missing-prototypes`, but the C call
  sites need the declarations).

## 3. Build isolation rule

- The shared `build/` directory is **reserved for the integrator**. Never
  run ninja/meson against it.
- Each worker configures their **own** build dir at the repo root:
  `build-w1`, `build-w2`, `build-w3`, `build-w4`, `build-w5`.

Exact setup (from `/Users/raph/Projects/nautilus-mac`; replace `N`):

```bash
export PKG_CONFIG_PATH="/opt/homebrew/opt/icu4c@78/lib/pkgconfig:/opt/homebrew/opt/libarchive/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

meson setup build-wN nautilus \
  --prefix="$PWD/install" \
  --buildtype=debugoptimized \
  -Dmacos_port=true \
  -Dextensions=false \
  -Dselinux=disabled \
  -Dcloudproviders=disabled \
  -Dtests=none \
  -Dintrospection=false

ninja -C build-wN
```

Keep the `PKG_CONFIG_PATH` export in every shell that runs meson or ninja
(ninja re-runs meson when meson files change — which you shouldn't be
changing, but reconfigures also happen on wipes).

- **Never `meson install`** from a worker build dir. The shared `install/`
  prefix (schemas, icons, gresource data) is already populated and is the
  integrator's. Binaries run fine against it because UI resources are
  compiled *into* the binary via gresource.
- Run your binary through the existing wrapper:

```bash
NAUTILUS_BIN="$PWD/build-wN/src/nautilus" ./run-nautilus.sh
```

  (`--quit`, `--new-window`, paths etc. all work; `NAUTILUS_NO_DBUS=1` for
  no-bus testing. Note: only one Nautilus instance can own the session-bus
  name at a time — quit yours before another worker's test run confuses you.)

## 4. Meson is frozen

`nautilus/meson.build`, `nautilus/meson_options.txt` and
`nautilus/src/meson.build` are **owned by the integrator**. Everything you
need is pre-registered:

- Objective-C is enabled; `.m` files compile darwin-only (inside the
  `if macos_port` block).
- Frameworks already linked: AppKit, CoreServices, Quartz,
  QuickLookThumbnailing, QuickLookUI, UniformTypeIdentifiers
  (via `dependency('appleframeworks', modules: […])`).
- All bridge files and `nautilus-search-engine-spotlight.c` are in the
  single marked "Phase 3 macOS bridge" block in `src/meson.build`.

If you genuinely need another framework or source file, request it from the
integrator; do not add it yourself.

## 5. Git & patch-record rules

- **No git commits, ever** — the `nautilus/` clone stays uncommitted
  upstream + working-tree patches.
- Do not run `git add`, `git stash`, `git checkout -- <file>`, or anything
  that mutates the index/tree beyond your own file edits.
- The patch record (`patches/macos-port-full.patch`,
  `patches/phase1-new-files.txt`) is **regenerated only by the integrator**
  after merging worker output. Don't touch `patches/`.

## 6. Stub seam quick reference

Current C-callable seams (full contracts in `src/nautilus-macos-bridge.h`):

- W1: `nautilus_macos_menu_init(void)` — no-op placeholder.
- W2 trash: `gboolean nautilus_macos_trash_open_in_finder(void)`.
- W2 open-with: `GList *nautilus_macos_get_apps_for_file(const char *path)`
  (of `NautilusMacosAppCandidate*`), `gboolean
  nautilus_macos_open_file_with(const char *path, const char *app_url)`,
  `gboolean nautilus_macos_show_in_finder(const char *path)`.
- W2 preview: `void nautilus_macos_preview_files(const char *const *uris,
  int selected_index)`, `void nautilus_macos_preview_hide(void)`,
  `gboolean nautilus_macos_preview_is_showing(void)`.
- W3: `gboolean nautilus_macos_thumbnail_can_thumbnail(const char *path,
  const char *mime_type)`, `void nautilus_macos_thumbnail_generate_async(
  const char *path, int size, NautilusMacosThumbnailCallback callback,
  gpointer user_data)` — callback receives `(GdkPixbuf*, GError*, gpointer)`
  on the main loop. Backend seam markers live in
  `nautilus-thumbnails-macos.c` (`backend_can_thumbnail` /
  `backend_generate_async`).
- W4: `NautilusMacosSpotlightQuery *nautilus_macos_spotlight_query_start(
  const char *query_text, const char *scope_path,
  NautilusMacosSpotlightHitFunc hit, NautilusMacosSpotlightFinishedFunc
  finished, gpointer user_data)`, `void
  nautilus_macos_spotlight_query_stop(NautilusMacosSpotlightQuery *query)`.
- W5: no seams yet (GTK pasteboard interop expected to suffice); append to
  the W5 section if needed.

All stubs currently log via `g_debug` (domain `nautilus-macos-bridge`) and
return FALSE/NULL; async stubs call back once from an idle with a
`G_IO_ERROR_NOT_SUPPORTED` error.
