# Nautilus → macOS Port: Execution Plan

**Goal:** a perfect port of Nautilus (GNOME Files) for macOS — deep macOS integration first, speed second, shipped as a styled DMG (shenzhen-pdf style) third.

**Repo layout:** upstream shallow clone at `nautilus/` (version **51.beta**, Meson, C11, GTK4 + libadwaita). All patches, scripts, and packaging live in this repo *outside* the clone where possible; unavoidable source patches are kept as a small, documented patch set (see Phase 1).

---

## 1. Executive summary of the strategy

Build the real Nautilus sources on macOS against Homebrew GTK4/libadwaita using Meson. This is **validated as viable** — not speculative:

- **GTK4 has a first-class native macOS backend.** Confirmed installed on this machine: `gtk4 4.22.4` with `gtk4-macos.pc` present. No X11/XQuartz anywhere. All X11/Wayland code in Nautilus (`nautilus-window.c`, `nautilus-sidebar.c`, `nautilus-previewer.c`, `nautilus-pathbar.c`, `nautilus-list-base.c`, `nautilus-file-operations.c`, `nautilus-application.c`) is behind `#ifdef GDK_WINDOWING_X11 / GDK_WINDOWING_WAYLAND` and **compiles out automatically** on the macOS backend. Zero patches needed for windowing.
- **Core requirements already satisfied:** glib 2.88.2 (needs ≥ 2.84 ✓), gtk4 4.22.4 (needs ≥ 4.22 ✓), libadwaita 1.9.2 (needs ≥ 1.8.alpha ✓), icu4c@78 (needs ≥ 56 ✓) are already installed. gnome-autoar, tinysparql, blueprint-compiler are in Homebrew but not installed yet (exact versions verified: 0.4.5, 3.11.1, 0.20.4 — all satisfy Nautilus's minimums).
- **Four dependencies have no Homebrew formula:** `glycin-2`/`glycin-gtk4-2`, `gnome-desktop-4`, `libportal`/`libportal-gtk4`, and `gvfs`. Strategy: **do not build them from source. Patch them out** and replace with macOS-native equivalents. This is deliberate: every code path these libraries serve (portal-based "Open With", sandboxed thumbnailers, portal FileChooser provider) is exactly what deep macOS integration replaces with NSWorkspace / QuickLook anyway. A verbatim `meson setup` was run on this machine; the first hard error is `Dependency "glycin-2" not found` (captured live), confirming this is the first wall.
- **GIO abstracts most of the OS.** `g_file_trash` verified working on this macOS host (`gio trash` succeeded, file landed in `~/.Trash`). GLib's file monitoring on macOS uses its **kqueue** backend (note: not FSEvents — the kqueue monitor is what stock GLib ships on Darwin; it works per-directory, which matches Nautilus's per-directory monitors). Search falls back to Nautilus's built-in `simple` recursive engine (upstream already multiplexes 4 providers: localsearch/model/recent/simple), later upgraded to a Spotlight (`NSMetadataQuery`) provider.
- **Packaging** reuses the shenzhen-pdf recipe (§4): hand-assembled `.app` (PlistBuddy-stamped Info.plist, `iconutil` icon), `install_name_tool` dylib rewriting into `Contents/Frameworks` (generalized to a transitive `otool -L` walker for the ~100 GTK dylibs), ad-hoc codesign for dev / Developer ID + notarytool + stapler for release, `hdiutil` UDZO DMG with the 600×400 background + Applications-symlink layout.

**Host ground truth (verified on this machine):** macOS 26.5.1 (darwin 25), Apple Silicon arm64, Homebrew 6.0.9 at `/opt/homebrew`, meson 1.11.1, ninja 1.13.2, pkgconf 2.5.1, Apple clang 21.

---

## 2. Dependency matrix

Every dependency from `nautilus/meson.build` (lines 102–139), with its live status on this machine:

| Dependency (required version) | On this Mac now | macOS status | Action |
|---|---|---|---|
| glib / gio / gio-unix / gmodule ≥ 2.84 | **installed 2.88.2** | works (gio-unix exists on macOS) | none |
| gtk4 ≥ 4.22.0 | **installed 4.22.4** (incl. `gtk4-macos.pc`) | works, native quartz backend | none |
| libadwaita-1 ≥ 1.8.alpha | **installed 1.9.2** | works (Adwaita look, not native — accepted for v1) | none |
| icu-uc / icu-i18n ≥ 56 | **installed icu4c@78** (keg-only) | works | add to `PKG_CONFIG_PATH` |
| gnome-autoar-0 ≥ 0.4.4 | missing | **brew has 0.4.5** | `brew install gnome-autoar` |
| tinysparql-3.0 ≥ 3.8 | missing | **brew has 3.11.1** | `brew install tinysparql` (used by tag-manager with a *local* store — no daemon needed; verified in `nautilus-tag-manager.c:682` it uses `tracker_sparql_connection_new` on a local DB, so starring works on macOS) |
| blueprint-compiler ≥ 0.19 | missing | **brew has 0.20.4** | `brew install blueprint-compiler` |
| glycin-2 / glycin-gtk4-2 ≥ 2 | missing | **no formula** (Rust lib) | **patch out** — used in only 2 files: `nautilus-icon-info.c` (texture-load fallback → replace with `gdk_texture_new_from_...`/gdk-pixbuf) and `nautilus-properties.c` (image preview + mime list → gdk-pixbuf) |
| gnome-desktop-4 ≥ 43 | missing | **no formula**; its thumbnailer spawns bwrap-sandboxed helpers (Linux-only) | **patch out** — used only by `nautilus-thumbnails.c`; replace backend with QuickLook (`QLThumbnailGenerator`) shim (Phase 1 stub, Phase 3 real) |
| libportal / libportal-gtk4 ≥ 0.7/0.5 | missing | **no formula**; portals don't exist on macOS | **patch out** — `nautilus-files-view.c` (OpenURI/compose-email/set-wallpaper → NSWorkspace / remove), `nautilus-mime-actions.c`, `nautilus-application.c` |
| libgxdp (meson subproject wrap) | fetches OK; configures on macOS with **0 build targets** (no wayland/x11) | portal-helper lib, macOS-irrelevant | **patch out** its two use sites (`nautilus-application.c:1018` `gxdp_init_gtk`, `nautilus-portal.c`) together with the portal-FileChooser feature below |
| Nautilus-as-portal-FileChooser (`nautilus-portal.c`, `nautilus-portal-request.c`, `xdg-desktop-portal-dbus` codegen) | n/a | GNOME-only feature (Nautilus *provides* the file chooser portal) | **compile out on darwin** via meson conditional |
| libselinux (feature, default enabled) | n/a | Linux-only | `-Dselinux=disabled` |
| cloudproviders (feature, default enabled) | n/a | no formula, Linux desktop feature | `-Dcloudproviders=disabled` |
| gexiv2-0.16, gdk-pixbuf, gstreamer-tag/pbutils | gexiv2 0.16.1 + gdk-pixbuf **installed**; gstreamer in brew (1.28.5) | only needed for `-Dextensions=true` (image/audio-video properties pages) | `-Dextensions=false` for v1; re-enable later (Phase 6 stretch) |
| gvfs (runtime expectation, not a build dep) | **no formula** | local files/trashing work via GIO without it; `trash:///` *browsing*, `network:///`, mtp/smb **won't** | hide network view; Trash strategy in Phase 3 |
| D-Bus session bus (runtime) | brew has dbus 1.16.2, not installed | no session bus by default on macOS; Nautilus owns `org.gnome.Nautilus` + `org.freedesktop.FileManager1` | dev: `brew install dbus` + launchd agent; app: tolerate-missing-bus patch (Phase 2), bundled private bus only if needed |
| desktop-file-utils, adwaita-icon-theme, shared-mime-info, hicolor-icon-theme, gsettings-desktop-schemas | **all installed** | work | none (bundled later in Phase 5) |

**Meson option set for macOS:** `-Dextensions=false -Dselinux=disabled -Dcloudproviders=disabled -Dtests=none -Dintrospection=false` — plus one new option we add in our patch set: `-Dmacos_port=true` (gates the darwin conditionals so the patch set stays upstreamable).

---

## 3. What must be patched (survey results)

Grouped by subsystem, from a full grep of `src/`:

1. **Windowing (X11/Wayland):** already `#ifdef`-guarded everywhere → no work.
2. **glycin:** `nautilus-icon-info.c`, `nautilus-properties.c` + `meson.build` dep. Small, mechanical.
3. **libportal + libgxdp + portal-FileChooser:** `nautilus-files-view.c`, `nautilus-mime-actions.c`, `nautilus-application.c`, `nautilus-portal.c`, `nautilus-portal-request.c`, `src/meson.build` (drop the `xdg-desktop-portal-dbus` codegen + 2 sources on darwin).
4. **gnome-desktop thumbnails:** `nautilus-thumbnails.c` uses `GnomeDesktopThumbnailFactory` (~6 call sites). Introduce `nautilus-thumbnails-macos.c` implementing the same internal contract.
5. **D-Bus consumers (keep, but must tolerate no bus):** `nautilus-dbus-manager.c` (org.gnome.Nautilus FileOperations service), `nautilus-freedesktop-dbus.c` (`g_bus_own_name_on_connection` for FileManager1), `nautilus-shell-search-provider.c` (GNOME Shell only — no-op on mac), `nautilus-previewer.c` (talks to Sushi over D-Bus — replaced by QuickLook in Phase 3), `nautilus-dbus-launcher.c`, `nautilus-file-operations-dbus-data.c`. These all use GDBus over a session bus; none should crash when the bus is absent — verify and guard.
6. **Compiler flags:** upstream sets `-Werror=shadow`, `-Werror=missing-prototypes`, etc. Apple clang 21 accepted the meson probe run cleanly; if any fire during compile, append `-Wno-error=<flag>` via `CFLAGS` rather than patching meson.build.
7. **POSIX:** essentially clean — the only flagged use is `O_PATH` in `nautilus-file-utilities.c:1173` (Linux-only flag; replace with `O_RDONLY|O_NOFOLLOW` or `#ifdef` fallback on darwin). `malloc_trim` is already probed by meson (`HAVE_MALLOC_TRIM`) and absent on macOS → auto-disabled.

---

## 4. The shenzhen-pdf packaging recipe (read and distilled)

From `portable/Makefile`, `portable/build-mac-release.sh`, `portable/mac/Info.plist`, `portable/mac/dmg-background.swift` (+ `.png`/`@2x.png`):

1. **App bundle assembled by hand in Make** (no Xcode project): `mkdir -p Contents/{MacOS,Resources,Frameworks}`; copy a template `Info.plist`; stamp identity with `/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier/:CFBundleShortVersionString/:CFBundleVersion"`. The plist template carries: `CFBundleExecutable`, `CFBundleIconFile`/`CFBundleIconName`, `LSMinimumSystemVersion`, `NSHighResolutionCapable`, `NSPrincipalClass=NSApplication`, `LSApplicationCategoryType`, and `CFBundleDocumentTypes` (we'll declare `public.folder` instead of PDF).
2. **Icon:** PNGs → `.iconset` dir (sizes 16→1024 via `sips -z`) → `iconutil -c icns` → `Contents/Resources/AppIcon.icns`; `actool` used when available (optional).
3. **Dylib bundling:** after linking, `otool -L` the binary; copy each external dylib into `Contents/Frameworks/`; `install_name_tool -change <old> @executable_path/../Frameworks/<name>` on the binary. shenzhen-pdf does this for exactly one dylib (libcrypto); **we generalize it to a transitive walker script** (BFS over `otool -L` of every copied dylib, rewriting ids with `install_name_tool -id` and refs with `-change`, until closure) — this is the standard gtk-mac-bundler pattern, ~80 lines of bash/python.
4. **Codesign:** ad-hoc (`codesign --force --sign -`, nested dylibs first, then the app) for local/dev; for release, `codesign --force --timestamp --options runtime --sign "Developer ID Application: …"`, then `hdiutil`-DMG, `xcrun notarytool submit --wait --keychain-profile <p>`, `xcrun stapler staple` + `validate`, and verification via `codesign --verify --deep --strict` + `spctl -a -t execute` / `-t open --context context:primary-signature` on the DMG. `build-mac-release.sh` is a thin wrapper that sources a git-ignored `.release.env` (`MAC_SIGN_IDENTITY`, `NOTARY_PROFILE`), sanity-checks the identity exists in the keychain, then drives the Make targets.
5. **DMG:** `hdiutil create -volname "<Name>" -srcfolder <staging> -ov -format UDZO out.dmg` (verified: the shipped DMG is UDZO). Background art is generated by `dmg-background.swift` (600×400 pt canvas @1x and @2x, gradient + accent arrow; app icon slot at (150,200), Applications slot at (450,200)). **Caveat found while reading the repo:** the *styled* DMG layout step (Applications symlink + `.background` + Finder view options) is not in the committed Makefile — the shipped DMG has it, the Makefile produces a plain one. So our Phase 5 writes the full layout script explicitly: staging dir containing `Nautilus.app`, `ln -s /Applications`, hidden `.background/dmg-background.png`; create a UDRW image, mount, apply Finder view settings (icon size 128, background picture, icon positions matching the swift art's 150/450 slots) via `osascript`, detach, `hdiutil convert -format UDZO`.

---

## 5. Phased roadmap

Worker-dispatch notes: each phase lists **[P]** parallelizable tasks (independent workers) and **[S]** serial spine tasks. A phase's acceptance criteria must pass before dependent phases start, but Phase 5 scaffolding can begin as soon as Phase 2 produces a launching binary.

### Phase 0 — Toolchain bring-up (serial, ~minutes)

**Goal:** all brew deps present; `meson setup` reaches its *first source-level* failure (not a dependency failure).

Tasks:
1. [S] Install missing packages (exact commands in §7). Do **not** reinstall what's present.
2. [S] Export `PKG_CONFIG_PATH` for keg-only icu4c@78.
3. [S] Set up dev D-Bus: `brew install dbus && brew services start dbus` (gives a launchd session bus; GLib on macOS finds it via `DBUS_LAUNCHD_SESSION_BUS_SOCKET`).
4. [S] Re-run the §7 meson line; record the error output as `docs/phase1-errors.txt` for the Phase 1 workers.

Acceptance: `meson setup` no longer fails on gnome-autoar/tinysparql/blueprint-compiler; remaining failures are only glycin-2, gnome-desktop-4, libportal (the patch-out targets).

### Phase 1 — Compile & link (the patch set)

**Goal:** `ninja -C build` completes; `build/src/nautilus` binary exists and links.

Convention: all patches guarded by `#ifdef __APPLE__` or the new `-Dmacos_port` meson option; keep a `patches/` dir with one patch per subsystem so the set survives upstream rebases.

Tasks (files/areas from §3):
1. [S] **Build glue owner:** add `macos_port` meson option; make `glycin`, `gnome_desktop`, `libportal*`, `libgxdp` deps conditional; drop `nautilus-portal.c` / `nautilus-portal-request.c` / portal codegen from `src/meson.build` on darwin. This worker owns the build dir and integrates the others' patches.
2. [P] **glycin removal:** `nautilus-icon-info.c` (replace `GlyLoader` path with `gdk_texture_new_from_file`/pixbuf), `nautilus-properties.c` (preview via GdkTexture; mime list via `gdk_pixbuf_get_formats`).
3. [P] **portal removal:** stub/replace `xdp_portal_open_uri` → `gtk_show_uri`; `xdp_portal_compose_email` → `mailto:` URI; `set_wallpaper` → remove the menu action on darwin; delete `gxdp_init_gtk` call in `nautilus-application.c`.
4. [P] **thumbnail shim:** `nautilus-thumbnails-macos.c` implementing the internal API of `nautilus-thumbnails.c` (`can_thumbnail`, queue, max size). Phase-1 version may return "no thumbnail" for everything — icons still render.
5. [P] **POSIX sweep:** fix `O_PATH` in `nautilus-file-utilities.c`; fix whatever `docs/phase1-errors.txt` and successive `ninja` runs surface; add `-Wno-error=` CFLAGS as needed.

Acceptance: clean `ninja -C build` on arm64; `otool -L build/src/nautilus` shows only /opt/homebrew + system libs; no glycin/portal/gnome-desktop symbols.

### Phase 2 — First launch & runtime fixes

**Goal:** `./build/src/nautilus` opens a window showing $HOME reliably.

Tasks:
1. [S] `meson install` to a local prefix; compile gsettings schemas (`glib-compile-schemas <prefix>/share/glib-2.0/schemas` — must include `org.gnome.nautilus.gschema.xml`, gtk4's and gsettings-desktop-schemas'); run with `GSETTINGS_SCHEMA_DIR` + `XDG_DATA_DIRS=<prefix>/share:/opt/homebrew/share` set. Missing schemas are the classic instant-abort — fix first.
2. [S] **No-bus tolerance:** run with the brew bus stopped; every `g_bus_*` consumer from §3.5 must degrade to a warning, not a crash; if `g_application_register` fails without a bus, fall back to `G_APPLICATION_NON_UNIQUE` on darwin (macOS single-instances app bundles via LaunchServices anyway).
3. [P] Icon theme sanity: adwaita-icon-theme + hicolor visible via `XDG_DATA_DIRS`; run `gtk4-update-icon-cache`.
4. [P] Runtime triage: click through grid/list views, navigation, file ops (copy/move/rename/delete-to-trash — trashing verified working at GIO level), sidebar; file crashes as Phase 2 bugs; hide the network view (gvfs-less) behind the darwin flag.

Acceptance: launch to browsable $HOME with icons; copy/rename/trash a file; survives launch with no session bus; no console error-spam beyond warnings.

### Phase 3 — macOS integration (the headline phase — max parallelism)

**Goal:** feels like a Mac app. Every task below is independently dispatchable **[P]**; each lands as ObjC (`.m`) helpers compiled on darwin only (meson: `add_languages('objc')`, link `-framework AppKit -framework QuickLookThumbnailing -framework Quartz`).

1. **Menu bar & shortcuts:** GTK4's macOS backend renders `gtk_application_set_menubar` as the native NSMenu bar — build a GMenu model (File/Edit/View/Go/Window/Help) mapping existing GActions; remap primary accelerators to Cmd (GTK uses `<Meta>` = Cmd on macOS; audit every `<Control>` accel in `src/resources/ui/` and the shortcut manager). Cmd-C/V for copy/paste files, Cmd-Backspace = trash, Cmd-Up = parent, Cmd-, = preferences, Cmd-W/Q.
2. **Trash:** "Move to Trash" already works (GIO). For *browsing*: `trash:///` has no backend without gvfs, and note — verified on this host — even `ls ~/.Trash` is TCC-blocked ("Operation not permitted") without Full Disk Access. v1 behavior: sidebar Trash item opens Finder's Trash (`NSWorkspace`-activate Finder trash / AppleScript), plus an in-app banner explaining; stretch: direct `~/.Trash` browsing when the user grants Full Disk Access.
3. **Open With / default apps:** replace the GAppInfo app-chooser contents on darwin with `NSWorkspace` (`URLsForApplicationsToOpenContentType:`, `openURLs:withApplicationAtURL:`); "Show in Finder" context item via `activateFileViewerSelectingURLs`.
4. **QuickLook space-bar preview:** replace the Sushi D-Bus previewer (`nautilus-previewer.c`) with `QLPreviewPanel` (Quartz framework); space toggles the panel on the current selection.
5. **QuickLook thumbnails:** upgrade the Phase-1 stub to `QLThumbnailGenerator` (async, delivers CGImage → GdkTexture); cache to Nautilus's existing thumbnail mtime logic. This gives PDF/video/office thumbnails "for free" via the system.
6. **Spotlight search provider:** add `nautilus-search-engine-spotlight.[cm]` implementing `NautilusSearchProvider` over `NSMetadataQuery` scoped to the searched directory; register it alongside `simple` in `nautilus-search-engine.c` (the engine already multiplexes providers and dedups hits — clean insertion point); keep `simple` as fallback.
7. **Finder drag & drop:** verify GTK4-macOS DnD interop with Finder both directions (`text/uri-list` ↔ `NSFilenamesPboardType`/`public.file-url`); fix gaps in `nautilus-dnd.c` / `nautilus-files-view-dnd.c`.
8. **URL/document handling:** Info.plist `CFBundleDocumentTypes` for `public.folder` so "Open With → Nautilus" works from Finder; handle `GApplication::open` for paths handed over by LaunchServices; optional `nautilus://` scheme.

Acceptance (per task, literal checks): native menu bar visible with working Cmd shortcuts; space-bar QuickLook on a PDF; thumbnails for images+PDFs in grid view; search returns Spotlight hits in <1s in a large dir; drag a file from Nautilus onto Finder desktop and back; Finder "Open With" shows Nautilus for folders.

### Phase 4 — Performance

**Goal:** startup and browsing subjectively instant; measured, not vibes.

1. [P] **Benchmarks first:** scripted timing harness — cold/warm start to first frame; `ls` a 10k-file dir vs Finder (time-to-fully-populated); thumbnail throughput on 500 images. Record baselines in `docs/perf.md`.
2. [P] Startup: profile with Instruments (Time Profiler); usual suspects — icon-cache misses, schema lookups, gresource decompression; consider `-Dbuildtype=release` LTO.
3. [P] Directory listing: Nautilus's async enumerator batch sizes were tuned for Linux; profile `nautilus-directory-async.c` attribute set (each extra GIO attribute is a stat-class syscall on macOS); trim per-file attributes fetched on first paint.
4. [P] Thumbnail pipeline: bound concurrent `QLThumbnailGenerator` requests; prioritize viewport.

Acceptance: cold start < 1.5s, warm < 0.5s; 10k-dir fully listed within 1.5× Finder; scrolling a thumbnail grid stays at 60fps (no main-thread I/O).

### Phase 5 — Packaging (.app + DMG) — can start right after Phase 2, parallel to 3/4

**Goal:** a relocatable `Nautilus.app` and a styled, mountable DMG on a clean machine.

1. [S] `package/make-app.sh`: meson install into `Nautilus.app/Contents/Resources` layout; binary to `Contents/MacOS/nautilus`; Info.plist template + PlistBuddy stamping (shenzhen-pdf pattern §4.1); icon via iconset→`iconutil` (§4.2). Bundle *runtime data*: compiled gsettings schemas (nautilus + gtk4 + gsettings-desktop-schemas), Adwaita+hicolor icon themes + icon cache, gdk-pixbuf loaders **with regenerated `loaders.cache`** (paths must be relative/`@executable_path`), GLib GIO modules, shared-mime-info database (`update-mime-database` output), locales. Launcher: prefer a tiny C/ObjC exec-wrapper (or shell launcher) exporting `XDG_DATA_DIRS`, `GSETTINGS_SCHEMA_DIR`, `GDK_PIXBUF_MODULE_FILE` relative to the bundle.
2. [P] `package/bundle-dylibs.sh`: the transitive `otool -L` walker (§4.3) — copy closure into `Contents/Frameworks`, rewrite ids + references; assert no `/opt/homebrew` strings remain (`otool -L` audit loop).
3. [P] DMG: generate background via a `dmg-background.swift` fork (Nautilus branding, same 600×400/(150,200)/(450,200) geometry); staged layout + UDRW→Finder-layout-osascript→UDZO pipeline (§4.5).
4. [S] Codesign ad-hoc (nested-first, then app — §4.4); document the Developer ID/notarytool/stapler path in the script but gate it on env vars, exactly like `build-mac-release.sh`.

Acceptance: on a machine/account **without Homebrew paths in env** (test: `env -i HOME=$HOME /Vol/.../Nautilus.app/Contents/MacOS/<launcher>` and ideally a clean VM/second account), the app launches from `/Applications` after drag-install from the DMG; `codesign --verify --deep --strict` passes; DMG mounts showing background + arrow + both icons positioned.

### Phase 6 — Polish & QA loop

1. [P] Re-enable `-Dextensions=true` for the image-properties page (gexiv2 installed; audio-video needs `brew install gstreamer`).
2. [P] libadwaita skinning pass: optional macOS-ish CSS (SF-symbols-adjacent icons, window-control spacing); accept Adwaita default if time-boxed out.
3. [P] Full keyboard/menu audit vs Finder muscle-memory; VoiceOver smoke test.
4. [S] Bug-bash loop against acceptance criteria of phases 2–5; tag v0.1; produce final DMG.

---

## 6. Risks & fallbacks

1. **GTK4-macOS backend gaps** (menu bar quirks, DnD pasteboard types, HiDPI on external displays). *Fallback:* every Phase 3 task has a degraded mode — in-window hamburger menu instead of NSMenu, uri-list-only DnD, etc. Ship v1 degraded rather than blocking.
2. **No session D-Bus in a shipped .app** breaks single-instance + the internal FileOperations service. *Fallback ladder:* (a) tolerate-missing-bus patch + `G_APPLICATION_NON_UNIQUE` (Phase 2 — preferred); (b) bundle `dbus-daemon` spawned by the launcher (Inkscape/GIMP precedent) if some internal service proves load-bearing.
3. **Trash browsing** — no `trash:///` backend without gvfs *and* `~/.Trash` is TCC-protected (verified). *Fallback:* trashing works; sidebar Trash delegates to Finder for v1. Don't burn time here.
4. **Patch-out scope creep** (glycin/portal/gnome-desktop removals touching more call sites than surveyed). *Mitigation:* survey says 2 files (glycin), ~4 (portal), 1 (thumbnails); if a removal cascades, prefer a stub header providing no-op symbols over invasive edits. If gnome-autoar somehow fails on macOS despite having a formula, archive extract/compress can be stubbed and the compress menu hidden (`-D` conditional) — it's not in the v1 critical path.
5. **Relocatability bugs** (dylib closure misses, absolute paths baked into caches — pixbuf loaders, gio modules, icon cache). *Mitigation:* Phase 5 acceptance mandates the `env -i` + clean-account test; the audit loop greps the whole bundle for `/opt/homebrew`.
6. **libadwaita looks alien on macOS.** *Accepted for v1* (explicitly, per priorities); Phase 6 CSS pass is best-effort.

---

## 7. Exact commands (Phase 0)

```bash
# Already installed (do NOT reinstall): glib gtk4 libadwaita gexiv2 gdk-pixbuf pango cairo \
#   graphene meson ninja pkgconf gobject-introspection desktop-file-utils adwaita-icon-theme \
#   hicolor-icon-theme shared-mime-info gsettings-desktop-schemas icu4c@78 appstream

brew install gnome-autoar tinysparql blueprint-compiler dbus
# optional, only for -Dextensions=true later: brew install gstreamer

brew services start dbus     # dev-time session bus (launchd agent)

export PKG_CONFIG_PATH="/opt/homebrew/opt/icu4c@78/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

cd /Users/raph/Projects/nautilus-mac
meson setup build nautilus \
  --prefix="$PWD/install" \
  --buildtype=debugoptimized \
  -Dextensions=false \
  -Dselinux=disabled \
  -Dcloudproviders=disabled \
  -Dtests=none \
  -Dintrospection=false
# (after Phase 1 lands the option:)  -Dmacos_port=true

ninja -C build && meson install -C build
glib-compile-schemas "$PWD/install/share/glib-2.0/schemas"

XDG_DATA_DIRS="$PWD/install/share:/opt/homebrew/share" \
GSETTINGS_SCHEMA_DIR="$PWD/install/share/glib-2.0/schemas" \
./build/src/nautilus
```

Note: `meson setup` fetches the `libgxdp` subproject from gitlab.gnome.org on first run (already cached at `nautilus/subprojects/libgxdp` from the survey run; no network needed). The live first-error wall from this machine (pre-Phase-1): `glycin-2 not found` at `meson.build:116` — gnome-desktop-4 and libportal are next in dependency order; all three are Phase 1 patch-out targets, not install targets.
