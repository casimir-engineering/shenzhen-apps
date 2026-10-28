# Hosting Shenzhen Friends in Shenzhen Files

Preparation for wave 6: how this repository's tree and app are rebuilt, where Friends plugs into Nautilus, and
the proposed structure for the GTK views, the Nautilus host adapter and the packaging. Written 2026-10-13 on the
local `friends` branch. The Friends contract lives in shenzhen-pdf (branch `friends/m1`):
`portable/docs/plans/shenzhen-friends.md` (§ Containment and porting), `portable/friends/README.md`,
`portable/friends/PROTOCOL.md` (version 1.0) and `portable/friends/mac/SZFriendsHost.h`.

## 1. Rebuilding the integrated tree and the app

### Pins

| What | Value | Source |
|---|---|---|
| Upstream base | `d95ce4060b39911fb68c0cb3626e47f52bd9d0b8`, upstream `main`, "Post-release version bump" (2026-06-28), meson version 51.beta | shallow root of the original working tree (`~/Projects/nautilus-mac/nautilus/.git/shallow`) |
| Local base commit | `46d27d6d0c850836c9b44a6a10deea67885ce532` "Prioritize copied files over Finder previews", now `patches/base-46d27d6-prioritize-copied-files.patch` | the original tree's `HEAD` |
| Port patch | `patches/macos-port-full.patch` (88 files: 64 modified, 24 new) | this repository |
| Meson options | `--prefix=<repo>/install --buildtype=debugoptimized -Dmacos_port=true -Dextensions=false -Dselinux=disabled -Dcloudproviders=disabled -Dtests=none -Dintrospection=false` | the 26.9.14-1 release build's `meson-logs/meson-log.txt` and `docs/phase3-conventions.md` |
| `PKG_CONFIG_PATH` | `/opt/homebrew/opt/icu4c@78/lib/pkgconfig:/opt/homebrew/opt/libarchive/lib/pkgconfig` | same |

Why the extra base patch: since commit `2ec197e` the port patch has been generated against `46d27d6`, not
against upstream. Its `src/nautilus-files-view.c` hunk expects blob `2e390ad`, the file after `46d27d6`. The
README's former instructions, a plain `git apply` on a fresh upstream clone, therefore failed (`patch failed:
src/nautilus-files-view.c:2811`); the README now points at the setup script. `46d27d6` existed only in the original local clone and was never recorded in
this repository. It is now, and the setup script commits it with its original author, committer and dates, so
`HEAD` is bit-for-bit `46d27d6`.

In the Shenzhen repository, where Shenzhen Files is `apps/files` beside ShenzhenPDF in `apps/pdf`, Friends is not
pinned: `tools/setup-friends.sh` builds it from `apps/pdf` as it is, with the version keys of
`apps/pdf/portable/Makefile`, and `-Dfriends_root` points there (`tools/friends-lock.sh`, "Two modes").
`SZF_FRIENDS_MODE=pinned` builds the `friends.lock` pin there too.

### `tools/setup-nautilus-tree.sh`

Idempotent: each step is skipped when already done, and an existing `nautilus/` is never deleted or reset.

1. **tree.** Shallow-fetches exactly `d95ce40` (default GNOME GitLab; `NAUTILUS_UPSTREAM` overrides it, and the
   GitHub mirror works too), commits the base patch with `git am`, checks `HEAD == 46d27d6`, applies the port patch
   in a staging directory, then `patches/friends-host-adapter.patch` (§ 3.3) when it exists, checks every touched
   file against the post-image blob id of the last patch touching it, then moves the result to `nautilus/`. A tree
   made before the adapter patch existed, and otherwise unchanged, gets it applied. On later runs it re-verifies:
   the patches' post-images, `HEAD`, and no other changed or untracked path. A tree with local work stops the
   script (exit 1) unless `--allow-modified` is given.
2. **configure.** `meson setup build nautilus <options above>`, plus `-Dfriends_root=` the checkout
   `friends.lock` names, after `tools/setup-friends.sh --check`. If `build/` exists, its options must match.
3. **build.** `ninja -C build`.
4. **install.** `meson install -C build --no-rebuild` into `install/`, which `package/make-app.sh` reads.

Flags: `--check` (verify only), `--tree-only`, `--allow-modified`.

### What was run (2026-10-13)

| Command | Exit | Result |
|---|---|---|
| `tools/setup-nautilus-tree.sh --tree-only` | 0 | tree created and verified, 79 patched paths |
| `tools/setup-nautilus-tree.sh --check` | 0 | `HEAD 46d27d6…`. `diff -rq` against the 26.9.14-1 working tree (`~/Projects/nautilus-mac/nautilus`): identical apart from `.git` and its unused `subprojects/libgxdp` checkout |
| `tools/setup-nautilus-tree.sh` | 0 | configure, 294 ninja steps, install; 11.5 s wall |
| `tools/setup-nautilus-tree.sh` again | 0 | 1.5 s; skips the tree and configure steps. Ninja re-runs 8 steps because upstream regenerates `config.h` on every run |
| one patched file edited, then `--check` and a default run | 1, 1 | names the file and blob; nothing touched. Restored, `--check` returns 0 |
| an untracked file added, then `--check` | 1 | "changed, but not part of the port patch" |
| fresh copy of the repo, `--tree-only`, with `NAUTILUS_UPSTREAM` set to GitLab and then to GitHub | 0, 0 | same tree |
| `./package/make-app.sh` | 0 | `dist/Shenzhen Files.app` assembled (3.6 s) |
| `./package/bundle-dylibs.sh` (no `MAC_SIGN_IDENTITY`, so ad-hoc) | 0 | 63 dylibs copied, 78 Mach-Os rewritten, audit OK, libtinysparql path patched, signed ad-hoc (8.9 s) |
| `codesign --verify --deep --strict --verbose=2 "dist/Shenzhen Files.app"` | 0 | valid on disk; `Signature=adhoc`, identifier `com.intuition.shenzhenfiles`, 26.9.14 / 26091401 / `26.9.14-1` |

The bundle (144 MB) has the same `Contents/Frameworks` list and directory tree as the 26.9.14-1 release build in
`~/Projects/nautilus-mac/dist`. It was not launched, and nothing was installed or published.

**Homebrew.** Nothing was installed. `libportal` is missing on this Mac and not needed: with `-Dmacos_port=true`
the patched `meson.build` requests glycin, gnome-desktop, libportal and libgxdp only when `macos_port` is false.
Used: gtk4 4.22.4, libadwaita 1.9.2, glib 2.88.2, meson 1.11.1, ninja 1.13.2, gnome-autoar 0.4.5,
tinysparql 3.11.1, blueprint-compiler 0.20.4, icu4c@78 78.3, libarchive 3.8.7, json-glib 1.10.8, librsvg 2.62.3,
Apple clang 21, macOS 26.5.1 arm64. The README's dependency list no longer names libportal.

## 2. Integration map

Paths are relative to `nautilus/src/` unless stated. Line numbers are in the reconstructed tree.

| Friends needs | Where in Shenzhen Files | Notes |
|---|---|---|
| **Button right of the window buttons** | `resources/ui/nautilus-window.blp`: the sidebar's `Adw.ToolbarView` has its own `[top] Adw.HeaderBar` (flat, no title) that holds only the window buttons, drawn as traffic lights at its start (`nautilus_application_setup_macos_window_chrome` in `nautilus-application.c` sets the decoration layout `close,minimize,maximize:`). Its end is the edge between the sidebar and the main view. When the sidebar is hidden, libadwaita's split-header coordination shows the window buttons at the start of the content header bar instead, followed by the toolbar's `[start]` children `show_sidebar_button` and `history_controls_stack` (`nautilus-toolbar.blp`). | The button is the last item of the sidebar's header bar while the sidebar shows, so it sits right of the traffic lights and just before the main view. While the sidebar is hidden (a narrow window collapses the split view and hides it) it moves to an `Adw.Bin friends_slot` at the start of the content toolbar, declared between `show_sidebar_button` and `history_controls_stack`: right after the window buttons and the sidebar toggle. The toolbar slot is gated by a new `show-friends-button` property, off by default like `show-app-menu-button`, so other toolbar users are unaffected. |
| Toolbar C side | `nautilus-toolbar.c`: `struct _NautilusToolbar` (38–75), property enum (77–90), `nautilus_toolbar_class_init` (520; template children bound from 572), `nautilus_toolbar_init` (277) | Add `PROP_SHOW_FRIENDS_BUTTON`, bind `friends_slot`, and `nautilus_toolbar_set_friends_button (NautilusToolbar *, GtkWidget *)`. The toolbar's `window-slot` property already tracks the active tab. |
| Which header bars | `resources/ui/nautilus-window.blp`: `Adw.OverlaySplitView split_view`, the sidebar's `Adw.HeaderBar` (give it an id, `sidebar_header_bar`), and `$NautilusToolbar toolbar` in the content `Adw.ToolbarView`; narrow breakpoint (max-width 682sp) collapses the split view (which hides the sidebar) and shows the sidebar toggle | Set `show-friends-button: true` on the toolbar. The window follows `split_view`'s `show-sidebar` and moves its one button between the two bars. `nautilus-window.c` binds `split_view`, `toolbar` and `toast_overlay`. |
| **Badge** | none in libadwaita 1.9.2 (no public `AdwIndicatorBin`) | The view draws it: a `GtkOverlay` around the button with a pill `GtkLabel` from the `badge` snapshot (`label`, `accessibility_label`). |
| **Popover for the views** | the button is a `GtkMenuButton` with `gtk_menu_button_set_popover()` | The popover holds an `AdwNavigationView`, one `AdwNavigationPage` per view (list, conversation, details, profile), each an `AdwToolbarView` and `AdwHeaderBar` (back arrow top left, centred title). Set `pop-on-escape` false: Escape closes, never goes back. 400 px wide; height follows the window, at most 640 px. |
| **Launch hook** | `nautilus-application.c`: `nautilus_application_startup` (1993); the `#ifdef __APPLE__` block after the chain-up ends with `nautilus_macos_savepanel_handoff_init ()` (2121) | Add `nautilus_friends_startup (self)` after it: set the signing policy, then, when `friends-enabled` is on, spawn the helper from a `GTask` thread (`szfriends_spawn_helper()` refuses the main thread on macOS). Create and start the client only after the first window maps, so nothing Friends-related runs on the main thread before first paint. |
| Per-window button | `nautilus_application_window_added` (2376), which calls `macos_setup_window()` (2397) | Create one button per `NautilusWindow` and hand it to the window, which places it (above). Every window shares one client: Nautilus windows live in one process, unlike ShenzhenPDF's one process per window. |
| Shutdown | `on_application_shutdown` (1293); `nautilus-main.c` `main` (52) runs `--post-update` before any GTK setup | Call `szfriends_client_stop (client, FALSE)` and free it. The updater helper path never reaches Friends. |
| **Selection and current folder (`#`)** | `nautilus_window_slot_get_selection` (`nautilus-window-slot.c:899`, `GList` of `NautilusFile` owned by the slot; notified through its `selection` property, 2931), `nautilus_window_slot_get_location` (2990), `nautilus_window_slot_get_current_view` (3104); `nautilus_files_view_get_selection` (`nautilus-files-view.c:1055`, transfer full); `nautilus_directory_get` (`nautilus-directory.c:462`) with `nautilus_directory_get_file_list` (1534); the window's `active-slot` property (`nautilus-window.c`, `PROP_ACTIVE_SLOT`) | The window comes from `gtk_widget_get_root (button)`. Items: the selected regular files first, then this folder's files matching the query. Folders are skipped because they can't be sent yet. `nautilus_file_get_location` and `g_file_get_path` give the path, `nautilus_file_get_display_name` the title. No revision: plain files. |
| **Drags from the files view** | `on_item_drag_prepare` (`nautilus-list-base.c:720`) returns `gdk_content_provider_new_typed (GDK_TYPE_FILE_LIST, …)` with each file's activation location (786). `get_paintable_for_drag_selection` (`nautilus-dnd.c:719`) also calls `schedule_drag_pasteboard_augmentation` (330), which adds `NSFilenamesPboardType` so AppKit apps see every file. | Inside the app the drop gets the `GdkFileList` value directly. ShenzhenPDF's AppKit Friends button receives Files' drags through the augmented pasteboard. |
| **Drags from Finder** | GDK's macOS backend turns `public.file-url` into `text/uri-list`; `nautilus_dnd_init_macos` (`nautilus-dnd.c:365`) registers a deserializer that repairs GTK's `file%3A///…` URIs (`file_for_dropped_uri`, 110) into a `GdkFileList` | It runs lazily from Nautilus's own DnD entry points, so the Friends adapter must call it before the first drop on the button. Drop targets accept `GDK_TYPE_FILE_LIST` with `gtk_drop_target_set_preload (TRUE)`, which lets the view refuse folders while hovering, as `nautilus-list-base.c` (1214–1217, 1714–1717) and `nautilus-pathbar.c` (1333) already do. GTK 4.22's macOS backend has no file-promise support, so drags that only offer promises (Mail attachments, Photos) won't arrive. |
| **Open or reveal a received file** | `nautilus_application_open_location (app, parent, file, NULL)` (`nautilus-application.c:594`, as `--select` uses it): a Files window on the parent folder with the file selected, reusing a window already showing it. `nautilus_mime_activate_files` (`nautilus-mime-actions.h:40`) opens with the default app. | Proposal: `reveal_in` "Shenzhen Files", `open_formats` empty, so every received file offers "Show in Shenzhen Files" and lands selected in a Files window. That is what "received files open in Files" means for a file manager. Opening with the default app stays one double-click away. |
| **Preferences** | `nautilus-preferences-dialog.c`: `nautilus_preferences_dialog_show` (666) adds the macOS "Finder Integration" page with `adw_preferences_dialog_add` (687), built by `finder_integration_build_page` (533). Keys are in `data/org.gnome.nautilus.gschema.xml`, schema `org.gnome.nautilus.preferences` (79), with names in `nautilus-global-preferences.h`. GLib's NSUserDefaults backend stores them under the bundle id `com.intuition.shenzhenfiles`. | Add `<key type="b" name="friends-enabled"><default>true</default>` (Friends is on by default) and `NAUTILUS_PREFERENCES_FRIENDS_ENABLED`. Add a "Friends" page the same way: an `AdwSwitchRow` "Enable Shenzhen Friends" bound with `g_settings_bind`, the host's disclosure, and the shared settings section. `changed::friends-enabled` starts or stops the link and adds or removes the buttons in every window. |
| **Bundle layout** | `package/make-app.sh` builds `Contents/{MacOS/{nautilus,nautilus-launcher},Frameworks,Resources/{AppIcon.icns,share,lib,etc}}`. `bundle-dylibs.sh` walks `MacOS/nautilus`, `Frameworks` and `Resources/lib` only, and signs Mach-Os under `Frameworks` and `Resources/lib` (310–318), then `MacOS/nautilus` (320), then the app (321). `sign-and-notarize.sh` signs only through `bundle-dylibs.sh` (141). | Helper: `Contents/Helpers/Shenzhen Friends.app`, copied after the executables block (67–71). Animal set: `Contents/Resources/Friends/animals/{manifest.json,svg/,pdf/}` and `Contents/Resources/Friends/Acknowledgements.txt`. That is where `+[SZFriendsAnimalSet bundledSet]` looks from `Host.app/Contents/Helpers/Helper.app` (`avatars/SZFriendsAnimalSet.m:72–80`). Signing: one line between 318 and 320, `codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Helpers/Shenzhen Friends.app"`. With `MAC_SIGN_IDENTITY` that line uses hardened runtime and a timestamp, like ShenzhenPDF's `MAC_CODESIGN_APP` for the helper. |

## 3. Wave 6 proposal

### 3.1 Shared GTK views: shenzhen-pdf `portable/friends/gtk/`

A fifth area next to `mac/`, owned by a "gtk views" area. It is C (C11, GLib style), GTK 4.22 and libadwaita 1.9,
and json-glib to parse frames, as the Friends README says (cJSON stays inside the client library). It renders
PROTOCOL.md snapshots and sends intents only through `client/szfriends_client.h`. It never includes `service/`,
`mac/`, AppKit or any `SPDF` symbol; extend `tests/containment-check.sh` with those rules for `gtk/`. Strings come
from snapshots and are set as plain text, never Pango markup. Rich-text segments become `PangoAttrList`s. Files
stay under 500 lines.

| File | Mirrors (`mac/`) | Role |
|---|---|---|
| `szfriends_gtk.h` | `SZFriendsHelperLink.h`, `SZFriendsDropdownController.h`, `SZFriendsSettingsSection.h` | public API below |
| `szfriends_gtk_host.h` | `SZFriendsHost.h` | host callbacks struct |
| `szfriends_gtk_link.c` | `SZFriendsHelperLink.m`, `SZFriendsClientTransport.m` | one client per process. `g_unix_fd_add_full` on `szfriends_client_fd()`, re-armed on every state change because the fd changes across reconnects. A `g_timeout` from `szfriends_client_next_tick_ms()`. Resubscribes after each READY, routes replies by id, delivers `connection_lost` once. |
| `szfriends_gtk_snapshot.c` | | json-glib parsing of each view into plain structs, testable without a display |
| `szfriends_gtk_button.c` | `SZFriendsTitleButton.m` | menu button, badge overlay, `GtkDropTarget` (`GDK_TYPE_FILE_LIST` plus host types) and `GtkDropControllerMotion` spring-loading after 500 ms; "Send 2 files to…" when released on the button |
| `szfriends_gtk_dropdown.c` | `SZFriendsDropdownController.m`, `SZFriendsDropdownContent.m` | `GtkPopover` and `AdwNavigationView`; keeps the view stack, drafts and scroll per window; Cmd+[ pops |
| `szfriends_gtk_list_page.c`, `_row.c`, `_row_actions.c` | `SZFriendsListPage.m`, `SZFriendsRowView.m`, `SZFriendsRowActions.m`, `SZFriendsArming.m` | list, Friends/Nearby tabs, inline Accept/Decline/Block with the armed "Block?" pill, footer |
| `szfriends_gtk_nearby_page.c` | `SZFriendsNearbyPane.m` | visibility card, countdown, per-method states |
| `szfriends_gtk_conversation_page.c`, `_message.c`, `_composer.c` | `SZFriendsConversationPage.m`, `SZFriendsMessageItemView.m`, `SZFriendsComposerView.m` | history (`GtkListView`), transfer items, `#` picker, drops on the list and on the composer |
| `szfriends_gtk_details_page.c`, `_profile_page.c` | `SZFriendsDetailsPage.m`, `SZFriendsProfilePage.m`, `SZFriendsCropView.m` | details, verification, automatic acceptance, profile, animal picker, own photo with crop |
| `szfriends_gtk_settings_section.c` | `SZFriendsSettingsSection.m` | the `settings` snapshot as `AdwPreferencesGroup` rows |
| `szfriends_gtk_avatars.c` | `avatars/SZFriendsAnimalSet.m` (data only) | reads `Resources/Friends/animals/manifest.json`, draws `svg/` with `GtkSvg` (GTK 4.22) or librsvg on the manifest's circle colour |
| `szfriends_gtk_drops.c` | `SZFriendsDrops.m` | `GdkFileList` to `szfriends_file`, refusing folders with the helper's drag strings |
| `szfriends_gtk.gresource.xml`, `icons/szfriends-people-symbolic.svg`, `szfriends_gtk.css` | `SZFriendsIcons.m`, `SZFriendsUI.m` | two-people icon drawn from the same paths as the AppKit icon; styles via `@define-color szfriends_*` |
| `gtk.mk` | `views.mk` | `friends-gtk-lib` builds `$(FRIENDS_BUILD)/gtk/libszfriends_gtk.a` (views, client objects and `cJSON.o`) with `pkg-config --cflags gtk4 libadwaita-1 json-glib-1.0`. `friends-gtk-check`. |
| `tests/` | `mac/tests/` | see Tests below |

Host struct, the C binding of `SZFriendsHost.h`:

```c
typedef struct {
    char *title, *detail, *kind_label; /* "Site photos.pdf", "Selected in Downloads", "PDF" */
    char *path;                        /* readable file holding exactly the bytes meant */
    char *revision_json;               /* PROTOCOL.md file.revision, NULL for a plain file */
} SZFriendsGtkItem;

typedef void (*SZFriendsGtkItemsReady) (GPtrArray *items /* SZFriendsGtkItem *, transfer full */, gpointer data);

typedef struct {
    gsize struct_size;   /* sizeof (SZFriendsGtkHost) when compiled; later fields read as NULL for older hosts */
    gpointer host_data;
    /* hello.client and embedded_helper */
    const char *app_id, *app_name, *app_version, *reveal_in_name;
    const char *helper_path, *helper_version;
    guint64 helper_build_number;
    const char *const *capabilities;   /* NULL-terminated: Shenzhen Files sends "attach.items", "drop.files" */
    const char *const *open_formats;   /* NULL-terminated lowercase extensions; empty in Shenzhen Files */
    const char *attach_empty;          /* the `#` row when nothing matches */
    /* placement: one button per window */
    void (*install_button) (gpointer host_data, GtkWindow *window, GtkWidget *button);
    void (*remove_button)  (gpointer host_data, GtkWindow *window, GtkWidget *button);
    /* `#`, best first; may complete later */
    void (*attachable_items) (gpointer host_data, GtkWindow *window, const char *query,
                              GCancellable *cancellable, SZFriendsGtkItemsReady ready, gpointer ready_data);
    /* drops beyond GdkFileList (ShenzhenPDF Linux: its tab type); NULL in Shenzhen Files */
    const GType *extra_drop_types;
    gsize n_extra_drop_types;
    GPtrArray *(*items_from_drop) (gpointer host_data, const GValue *value);
    gboolean (*button_accepts_drop) (gpointer host_data, GdkDrop *drop); /* optional veto */
    /* received files */
    void (*open_received_file) (gpointer host_data, GtkWindow *window, const char *path);
    void (*reveal_file)        (gpointer host_data, GtkWindow *window, const char *path);
    /* appearance: CSS at application priority, plus metrics */
    const char *appearance_css;
    int title_bar_button_size, dropdown_width, dropdown_max_height;
    /* optional, NULL in Shenzhen Files: Markdown, `/` assistant, global-search export */
    GtkWidget *(*render_markdown) (gpointer host_data, const char *markdown, int width);
    gpointer (*assistant) (gpointer host_data);
    void (*services_available) (gpointer host_data, gpointer services);
    void (*services_unavailable) (gpointer host_data);
} SZFriendsGtkHost;
```

Public API (`szfriends_gtk.h`):

```c
void              szfriends_gtk_spawn_helper_async (const char *helper_path); /* GTask thread, never waits */
SZFriendsGtkLink *szfriends_gtk_link_new    (const SZFriendsGtkHost *host);   /* copies host; one per process */
void              szfriends_gtk_link_start  (SZFriendsGtkLink *link);
void              szfriends_gtk_link_stop   (SZFriendsGtkLink *link, gboolean friends_disabled);
void              szfriends_gtk_link_free   (SZFriendsGtkLink *link);
GtkWidget        *szfriends_gtk_button_new  (SZFriendsGtkLink *link, GtkWindow *window);
GtkWidget        *szfriends_gtk_settings_section_new (SZFriendsGtkLink *link);
```

**Tests (`friends-gtk-check`).**

- Display-free: parse every `fixtures/snapshots/*.json` into the view structs; build intents from them; classify
  drops (files, folders, mixtures).
- Against the fake helper (`client/fake`, `FRIENDS_FAKE_HELPER_EXE`): link reconnects, resubscription, and reply
  routing, including `connection_lost`.
- Widget probes render offscreen with `gtk_widget_snapshot` and a `GskRenderer` realized without mapping a window.
  They need a logged-in GUI session (GTK's macOS backend talks to the WindowServer). They never show a window and
  never launch either app.

### 3.2 Consuming it from Shenzhen Files: a pinned path

**Recommended: a pinned path, not a submodule.** A submodule would pull all of shenzhen-pdf (mupdf, ext/, website)
into a GPL-3.0-or-later repository that tracks upstream by patches. A pin matches how `nautilus/` is handled here.

- `friends.lock` (committed) holds `url=https://github.com/casimir-engineering/shenzhen-pdf.git`, `commit=<sha>`,
  `helper_build_number=<YYMMDDBB>`.
- `tools/setup-friends.sh` (new, idempotent, same rules as the nautilus script) fetches that commit into
  `friends-src/` (gitignored), or verifies `SZF_FRIENDS_ROOT` when it points at an existing checkout at that
  commit. It then runs
  `make -C friends-src/portable friends-gtk-lib friends-helper-bundle FRIENDS_HELPER_SHORT_VERSION=… FRIENDS_HELPER_BUNDLE_VERSION=…`.
  It never builds in a live shenzhen-pdf working copy that other agents are using.
- `tools/setup-nautilus-tree.sh` applies `patches/friends-host-adapter.patch` after the port patch when it exists,
  verified the same way, and passes `-Dfriends_root=<abs path>` to meson.

### 3.3 Nautilus host adapter: `patches/friends-host-adapter.patch`

A separate patch so the port patch stays Friends-free and the two rebase independently. It applies on top of
`macos-port-full.patch`, and `friends_root == ''` compiles Friends out.

- `meson_options.txt`: `friends_root` (string, default `''`).
- `meson.build`: when set, `json_glib = dependency('json-glib-1.0')` and
  `friends_dep = declare_dependency(link_args: friends_root / 'portable/build/friends/gtk/libszfriends_gtk.a', include_directories: include_directories(friends_root / 'portable/friends'), dependencies: [json_glib])`,
  plus `-DNAUTILUS_FRIENDS=1`. The main project may use absolute paths outside its tree; a meson subproject could
  not reach `client/` and `ext/cjson`.
- `src/meson.build`: `nautilus-friends.c`/`.h` (C: builds the `SZFriendsGtkHost`, owns the link, follows
  `friends-enabled`, installs buttons) and `nautilus-macos-friends.m` (helper path and version from
  `NSBundle.mainBundle`, `Contents/Helpers/Shenzhen Friends.app`; the app's own Team ID via
  `SecCodeCopySelf`/`SecCodeCopySigningInformation`; the `szfriends_peer_verifier` for
  `szfriends_set_signing_policy()`; skipped when ad-hoc so dev runs keep `SZFRIENDS_STATE_DIR`). Dev runs without
  a bundle take the helper from `NAUTILUS_FRIENDS_HELPER`, like `NAUTILUS_DOCK_ICON`, or don't spawn.
- `data/org.gnome.nautilus.gschema.xml` and `nautilus-global-preferences.h`: `friends-enabled`.
- `nautilus-application.c`: the startup, window_added and shutdown hooks from § 2.
- `nautilus-toolbar.blp`/`.c` and `nautilus-window.blp`: `friends_slot`, `show-friends-button`,
  `nautilus_toolbar_set_friends_button`, and the sidebar header bar's id for the button's place there.
- `nautilus-preferences-dialog.c`: the "Friends" page.
- Host callbacks:
  - `attachable_items`: selection, then folder files, from § 2.
  - `open_received_file` and `reveal_file`: `nautilus_application_open_location` on the parent with the file
    selected.
  - Setup calls `nautilus_dnd_init_macos ()` before the first drop.
  - Identity: `app_id` `com.intuition.shenzhenfiles`, `app_name` "Shenzhen Files", `toolkit` `gtk4`, `reveal_in`
    "Shenzhen Files".
  - `/`, Markdown and search export: NULL.
- Host strings (README § Four layers): `#` row when nothing matches "No matching files"; Settings switch
  "Enable Shenzhen Friends". Disclosure (M1): "Shenzhen Files connects to the Friends server whenever it is open
  and Friends is on. The server sees your network address, your Friends ID and when Shenzhen Files is open. It
  never sees your name, messages or files." What the server sees and what it never sees are two sentences, in
  both apps (wave 6c): joined by a comma, "when Shenzhen Files is open, never your name" read as one clause.

**As built (waves 6b to 6e, 2026-10-13, branch `friends-host`).** The patch is generated against the port
patch's state and `tools/setup-nautilus-tree.sh` applies and verifies it (§ 1). To regenerate it after editing
`nautilus/`, work in `nautilus/` with a scratch index (`GIT_INDEX_FILE=<scratch>/index`): `git read-tree HEAD`,
`git apply --cached ../patches/macos-port-full.patch`, `git add -N` the adapter's new files (the ones `git status`
then lists as untracked), and `git diff | sed 's/^ $//' > ../patches/friends-host-adapter.patch`: blank context
lines lose their single space, as in the port patch, so `git diff --check` stays clean on the patch (since wave
6d; `git apply` reads an empty line as a blank context line). The real index is never touched;
`tools/setup-nautilus-tree.sh --check` then confirms the tree matches. Where the adapter differs from, or adds
to, the plan above:

- Files. `src/nautilus-friends.h` is all the application includes: startup, window added, shutdown, the
  Preferences page, and the button's placement (`nautilus_friends_place_button` and `_placed_button`, which
  `nautilus-window.c` calls), empty inlines without `-Dfriends_root`. The rest is `nautilus-friends.c`
  (lifecycle), `nautilus-friends-host.c` (the host struct, buttons, received files, the `#` request),
  `nautilus-friends-placement.c` (where a window's button sits), `nautilus-friends-items.c` (`#` items),
  `nautilus-friends-preferences.c`, `nautilus-friends-private.h` (for the tests) and `nautilus-macos-friends.m`
  (bundle and signing, plain Core Foundation since the bridge block is not ARC).
- Meson. `friends_dep` carries `-DNAUTILUS_FRIENDS=1`, the include directory, the archive as a link argument,
  json-glib, gtk4 and libadwaita; the executable has the archive as a `link_depends`, so a rebuilt archive
  relinks. Configure stops with a message when `friends_root` is relative, `macos_port` is off, or the archive
  is missing ("run tools/setup-friends.sh first").
- Placement (wave 6d, replacing the button just left of the main menu). While the sidebar shows, the button is
  the last item of the sidebar's header bar: right of the traffic lights, just before the edge with the main view.
  While it is hidden it is at the start of the content toolbar, right after the window buttons and the sidebar
  toggle (`friends_slot`, declared between `show_sidebar_button` and `history_controls_stack`). The toolbar's search
  button (`end_search_button`, from the port's search fix merged in wave 6e) stays at the other end of that bar,
  just before the main menu, wherever the Friends button is. The window follows
  `split_view`'s `show-sidebar`: a narrow window collapses the split view, which hides the sidebar, so the button
  goes to the toolbar; it comes back when the sidebar shows. The sidebar shown over the files in a narrow window
  counts as shown: its header bar then covers the start of the main one, window buttons and toggle included, so
  the button goes with the window buttons rather than under the sidebar. It is one widget, moved and never copied
  (held by a reference while it has no parent), so a window never has two, and its badge, drop target and open
  popover (the menu button's child) move with it. Each slot is shown only while it holds the button, so a bar
  without it keeps its spacing exactly; the toolbar's slot also needs `show-friends-button`, which only the browser
  window's toolbar sets. `nautilus_window_set_friends_button` and `_get_` call `nautilus_friends_place_button` and
  `_placed_button` with the window's split view, sidebar header bar and toolbar.
- Lifecycle. At startup the main thread reads `friends-enabled` and, when it is on, starts one `GTask` thread:
  the signing policy (once per process), the bundle read, then `szfriends_spawn_helper()`. The link is created
  after the first window's first frame (`GdkFrameClock::after-paint`, then an idle), once per process, and
  `szfriends_gtk_link_add_window` gives every browser window its button. Turned off: `link_stop (link, TRUE)`.
  Turned on again: the same link starts again and the buttons come back. Shutdown: `szfriends_gtk_link_free`,
  which does not send `disable`. The lifecycle reaches the views only through a table of functions, so the tests
  count every call.
- Host. `capabilities` NULL, so the views claim `attach.items` and `drop.files` themselves; `open_formats` is an
  empty list. `open_received_file` and `reveal_file` both open the file's folder with the file selected through
  `nautilus_application_open_location`, which reuses a window already showing that folder.
  `nautilus_dnd_init_macos ()` runs in `install_button`, before any drop on a button can happen.
- `#`. The selected files that match the query, in selection order, then the folder's other matching files,
  newest first (ties by name), at most 30. Matching is a case- and accent-insensitive substring of the name, as in
  ShenzhenPDF. Only regular files, a hidden file only when selected. Folders, packages, pipes and devices are left
  out, and so is every symbolic link, selected or not, wherever it points (`lstat`), as the views' drop verdict
  and the helper refuse them: offered as its target, a link sent a file from anywhere under the link's own name
  (fixed in wave 6c). Detail "Selected in Downloads" or "In Downloads"; kind label from ShenzhenPDF's table,
  else the extension in capitals, else "File". The answer comes from the folder's `call_when_ready` (an idle when
  the tab shows no folder), never from inside the call and never after cancellation; the array frees its items.
- Bundle. `NAUTILUS_FRIENDS_HELPER` (a standalone `Shenzhen Friends.app`) counts only when the app embeds no
  helper and the build has no Team ID; it then also names that helper's own animal set. `helper_version` and
  `helper_build_number` are sent together or not at all.
- Preferences. A "Friends" page (icon `system-users-symbolic`, two people): the group "Shenzhen Friends (Beta)" with
  "Send files and messages to people you add, when they are nearby with ShenzhenPDF or Shenzhen Files open.", the
  switch (plain-text title, `g_settings_bind`), the disclosure under it, and a second group that holds the views'
  Settings section only while Friends is attached. The disclosure is secondary text as the views draw it: the
  style class `friends-disclosure`, the text colour at 70%, 4.9:1 on the light page and 8.3:1 on the dark one.
  `dim-label` (55%) measured 3.2:1 in light, under the 4.5:1 body text needs (wave 6d). With libadwaita's high
  contrast on (Increase Contrast in macOS) the class takes libadwaita's `--dim-opacity` there, 90%: 9.0:1 in light
  and 12.8:1 in dark (wave 6e). It is a colour from a stylesheet, not an opacity on the widget, so it can follow the
  setting; the page's provider has its `prefers-contrast` bound to `AdwStyleManager:high-contrast`, since GTK does
  not apply the system's contrast to a provider of its own.
- Links (wave 8, shenzhen-pdf `portable/friends/PROTOCOL.md` § Links). `package/Info.plist.template` registers
  `shenzhenfiles:`. GTK hands `shenzhenfiles://friends/link#<payload>` to the application's `open` like a file;
  `nautilus_application_open` passes every URI to `nautilus_friends_open_uri` first and opens no location for a
  link (and the starting location when a link alone launched the app, so the link has a button to open from).
  `nautilus-friends-links.c` checks the URL on its bytes, as ShenzhenPDF checks `shenzhenpdf:`: at most 512 bytes,
  host `friends`, path `/link`, nothing else, `f.` or `d.` and canonical unpadded base64url of exactly that kind's
  layout. A URL that fails is dropped without a word; one that passes waits for Friends to attach and opens the
  window's dropdown on the link page, where nothing happens until the person presses the helper's card; while
  Friends is off an alert offers Preferences, and the link opens once Friends is on. The files view's selection
  menu gets "Copy Download Link" with its expiry choice (For 7 Days, For 1 Day, For 30 Days) for one selected
  regular file, never a link, while the helper offers links; the result shows as a toast. The menu is built before
  the helper may start or stop offering links, so the item is always in it and shows only while its actions
  (`app.friends-download-links` on the submenu, `app.friends-copy-download-link` on each choice, both
  `hidden-when` `action-disabled`) are enabled. `nautilus-friends.c` enables them exactly while
  `nautilus_friends_offers_links`, re-checked on attach, detach and every link state change (the helper's
  welcome, which lists `links`, comes before ready). That covers every change of the offer: the helper's list of
  capabilities is fixed for its process, and the client takes it from the welcome only (a second welcome is
  ignored), so the offer changes only with a new connection. The views give hosts no watch yet (shenzhen-pdf
  `7e49dfb3a`), so the adapter uses their internal `szfriends_gtk_link_add_state_watch` (`gtk/szfriends_gtk_link.h`).
- Notifications (shenzhen-pdf `portable/friends/PROTOCOL.md` § Notifications, ADR 0017). The helper posts them;
  Files tells it where a click goes and what the person is looking at. The host sets `url_scheme`
  `shenzhenfiles` (sent as `client.url_scheme`); the views claim `notifications.focus`, and `notifications.ask` on
  macOS, and send `set_focus` themselves. A click opens `shenzhenfiles://friends/conversation/<conversation_id>`
  (or `shenzhenfiles://friends` for a computer asking to join) through the same `open` path as links:
  `nautilus_friends_route` accepts an id of 1 to 64 of `[A-Za-z0-9_-]` and drops anything else without a word;
  other paths under `friends/` go the links' way, as before. A route waits for Friends to attach (a cold launch)
  and then opens the active window's dropdown on that conversation, or the list (`szfriends_gtk_show_conversation`);
  while Friends is off in Files it opens nothing and asks nothing: the person clicked a notification, not a link.
  The calls into the views (`szfriends_gtk_show_link`, `szfriends_gtk_link_offers_links`,
  `szfriends_gtk_copy_download_link`) compile only when `gtk/szfriends_gtk.h` defines `SZFRIENDS_GTK_LINKS`, so the
  patch also builds against views older than links.
- Tests. `tools/test-friends-adapter.sh` builds Files without and with Friends, checks the symbols of each, runs
  `test/friends/test-nautilus-friends` (no display, helper or network) and `test-nautilus-friends-toolbar`, which
  checks the button's place in a window built like `nautilus-window.blp` (sidebar shown, hidden, narrow with the
  sidebar hidden and shown over the files, dark, Friends off), that the search button ends the main bar in every
  one of those states, and the Preferences page (the disclosure's contrast measured on the render, light and dark,
  with and without high contrast), and renders both offscreen. It also builds the selection menu as
  `nautilus-files-view.c` does (`gtk_popover_menu_new_from_model`, the actions on `app`) and checks, through
  GTK's own menu widgets, that Copy Download Link shows and hides with the offer while the menu exists, and that
  clicking it opens the expiry choice (its submenu action does nothing) and a choice asks for one link.
  `docs/STATUS.md` has the results.
- Cmd+J and Cmd+K (2026-10-20, branch `feat/friends-shortcut`). Before this, nothing in Files bound J or K
  (checked in `nautilus/src`: accelerators, shortcut controllers, menu items, key handlers). `nautilus-friends-shortcut.c`
  gives every browser window `win.friends`, bound to `<Primary>j` (Cmd+J after `macos_remap_accel`), enabled exactly
  while the window has a Friends button, so it does nothing while Friends is off or not attached. It toggles the
  window's dropdown through the views' `szfriends_gtk_dropdown_*`; opening puts the keyboard in the list's search
  field when the list is on top (also on the popover's `map`), and a dropdown that kept another page keeps that
  page's focus. The key reaches it once per press wherever the keyboard is, the dropdown's own search field
  included: GDK gives every key to GTK first and passes it to `[NSApp sendEvent:]`, where the View menu's "Friends
  ⌘J" key equivalent lives, only when GTK left it unhandled (`gdkmacoseventsource.c`); GTK runs application
  accelerators from a capture-phase controller on the window; and a popover's keys go to its toplevel (popups
  cannot become key on macOS, and `gtkmain.c` rewrites popup key events for the toplevel), so no controller on the
  popover is needed. The button's tooltip gets " · ⌘J" after the views' name ("Friends (Beta) · ⌘J"), re-added whenever the views set it
  (they do on every badge change); before the helper's strings arrive the views set no tooltip, and neither does
  the host. Cmd+K is `nautilus-command-palette.c`, built with or without Friends: an `AdwDialog` over the window
  with a search field and Files' commands (New Window, New Tab, New Folder, Enter Location…, Find, Search
  Everywhere, Show Hidden Files, Preferences…, Keyboard Shortcuts, each with the menu bar's shortcut), plus, while
  the window has a Friends button, Open Friends (⌘J), Add by ID… (the dropdown's profile page, as the list's Add
  by ID does), Make Myself Visible (the dropdown on Nearby; once Nearby's first snapshot is in, the host presses
  Nearby's own visibility button when it offers `start_visibility`, so the views' path sends the intent, with any
  confirmation the helper asks for) and Friends Preferences… (`nautilus_preferences_dialog_show_page`, page
  `friends`). Every word typed must start a word of a command's title or keywords, ignoring case and accents. Help
  ▸ Search Commands… (⌘K) and the shortcuts dialog list both keys; the dialog's Friends row is cut out of builds
  without `friends_root` (`src/resources/ui/meson.build`). `tools/test-macos-friends-shortcut.sh` presses the keys
  as real NSEvents on a mapped window that never reaches the screen; results in `docs/STATUS.md`.

### 3.4 Packaging

Built in wave 6a (`docs/STATUS.md`, Shenzhen Friends packaging); the adapter needed no packaging change.

- `friends.lock` pins the shenzhen-pdf commit and its helper build number; `tools/friends-lock.sh` parses it for
  every script; `tools/setup-friends.sh` fetches or checks that commit and builds `friends-helper-bundle` and
  `friends-gtk-lib` there (§ 3.2).
- `package/Info.plist.template`: `CFBundleURLTypes` with `shenzhenfiles` (links, § 3.3, checked by
  `tools/test-friends-adapter.sh`), `NSLocalNetworkUsageDescription`, `NSBluetoothAlwaysUsageDescription` (the same
  "Friends uses …" sentences as the embedded helper) and `NSBonjourServices` = `_szfriends._tcp`. macOS holds the app responsible for
  the helper it starts. `LSMinimumSystemVersion` is 12.0 in both.
- `package/make-app.sh` refuses to start unless `setup-friends.sh --check` passes. It copies the helper into
  `Contents/Helpers/`, drops the helper's own animal set, stamps `CFBundleShortVersionString`, `CFBundleVersion`
  and `SZFriendsBuildNumber` from `friends.lock`, copies the animal set and `Acknowledgements.txt` into
  `Resources/Friends/`, and ends with `package/check-friends-bundle.sh`.
- `package/bundle-dylibs.sh` checks that the helper links system libraries only, signs it on its own line before
  `MacOS/nautilus` and the app (hardened runtime and a timestamp with `MAC_SIGN_IDENTITY`), and ends with the
  check in `--signed` mode. The json-glib library that `MacOS/nautilus` links with Friends is bundled like every
  other library it needs.
- `tools/setup-nautilus-tree.sh` applies `patches/friends-host-adapter.patch` and passes `-Dfriends_root` (§ 1).
- Tests: `package/test-friends-bundle.sh` (planted packaging defects) and `tools/test-setup-friends.sh`.
- Notices: README and LICENSE note the Friends components. Acknowledgements ship in `Resources/Friends/` and in
  the helper.

### 3.5 What Shenzhen Files' build needs from shenzhen-pdf

| Item | Path in shenzhen-pdf | Used for |
|---|---|---|
| C client library | `portable/friends/client/*.c`, `szfriends_client.h` (protocol 1.0) | linked into `libszfriends_gtk.a` |
| cJSON 1.7.19 | `ext/cjson/` built by `friends/deps/deps.mk` (`FRIENDS_CJSON_OBJ`; nesting limit compiled in) | the client library |
| GTK views | `portable/friends/gtk/` (new, § 3.1) | `libszfriends_gtk.a` and its headers |
| Helper bundle | `make -C portable friends-helper-bundle` → `portable/build/friends/Shenzhen Friends.app` (`com.intuition.shenzhenfriends`; static libsodium 1.0.22, system frameworks only) | `Contents/Helpers/` |
| Animal set | `portable/friends/avatars/animals/{manifest.json,svg/,pdf/}` (set 1, 24 animals) | `Contents/Resources/Friends/animals/` |
| Acknowledgements | `portable/friends/ACKNOWLEDGEMENTS.txt` | `Contents/Resources/Friends/Acknowledgements.txt` |
| Fixtures and fake helper | `portable/friends/fixtures/`, `client/fake/` | GTK view development and tests |

### 3.6 Decisions and what is still open

1. **Helper build number across apps.** Decided: `friends.lock` carries the pinned shenzhen-pdf commit's own
   helper number (YYMMDDBB from its `MAC_VERSION` and `MAC_BUILD`), `setup-friends.sh` refuses any other, and
   `make-app.sh` stamps it into the embedded helper. The adapter reads it back from that helper's
   `CFBundleVersion` and `CFBundleShortVersionString` and sends both in the hello. Decided (wave 6e): the number
   moves with ShenzhenPDF releases only. Unreleased commits keep the last release's number, so a Files build
   pinned between releases ties with ShenzhenPDF and the running helper stays; that is accepted for unreleased
   builds.
2. **One identity per Mac user.** Both apps embed the helper as `com.intuition.shenzhenfriends` in
   `Contents/Helpers/Shenzhen Friends.app`, and a team-signed Files talks only to a helper of its own team. Open:
   reading the Keychain item without a prompt from both apps' helpers needs Developer ID builds of both; only ad
   hoc builds exist so far.
3. **Licence.** Decided: the combined app is distributed under GPL-3.0 terms (README).
4. **Updater gates.** Unchanged: the updater deep-verifies nested code (`kSecCSCheckNestedCode`), so the first
   release carrying the helper is updater-affecting and every gate in `AGENTS.md` applies.
5. **GTK on macOS.** Decided in the views (shenzhen-pdf `gtk/`): the popover has autohide off, so it stays open
   while files are dragged in, and the views close it on a click elsewhere in the window, on the button, or on
   Escape once focus is inside it. Open: spring-loading during a real drag from Finder, checked so far only by
   driving the same entry points; file promises (Mail, Photos) still do not arrive.
6. **Launch gate.** Decided: with Friends on, the launch path reads one setting and starts one worker thread;
   everything else waits for the first frame. With Friends off, nothing of Friends runs after reading the setting.
   Open: the launch-time measurement with Friends on and off, on a copy of the app, never the installed one.
7. **"The current folder" in `#`.** Decided: its regular files after the selection, newest first (§ 3.3, as
   built).
8. **Usage strings.** Decided: the app and the embedded helper carry the same "Friends uses …" sentences, so the
   prompt reads the same whichever bundle macOS names.
9. **Existing caveats left as they are.** `NAUTILUS_DATADIR` is baked to `<repo>/install` (package/README.md).
   `config.h` is regenerated on every ninja run.
