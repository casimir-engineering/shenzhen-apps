# Phase 6 — Known issues (integrated build)

Carried-forward and newly-investigated issues after the integration pass.
Binary: `build/src/nautilus` (arm64, `debugoptimized`, `-Dmacos_port=true`).

## 1. `Gdk-CRITICAL: gdk_macos_monitor_get_workarea assertion 'GDK_IS_MACOS_MONITOR (self)'`

- **Severity:** cosmetic (console noise only).
- **Where:** GTK4 itself (Homebrew `gtk4 4.22.4`, quartz backend), *not*
  Nautilus source. Fires once per window creation when the window default
  size is set before the surface is attached to a monitor.
- **Impact:** none — the window opens, sizes, and positions correctly. It is
  a `CRITICAL` only because GTK uses `g_return_val_if_fail`. This is the one
  expected line on every clean launch.
- **Action:** not fixable from Nautilus without patching GTK. Flag for a
  GTK-macOS upstream report.

## 2. Early-SIGTERM teardown segfault (exit 139) — NOT REPRODUCED

- **Severity:** unresolved but non-reproducing; left as a watch item.
- **History:** the packaging worker saw a single exit-139 (SIGSEGV) at
  ~7 s during teardown, once, and could not reproduce it.
- **Integration repro attempt (this pass):** launched
  `build/src/nautilus --new-window /tmp/int-qa/images` and sent `SIGTERM`
  after a delay, then `wait`ed on the exit code. Two sweeps:
  - **Coarse:** 10 runs, delays 5–8 s (the reported window). All 10 exited
    **143** (128 + SIGTERM) — clean signal teardown, no segfault.
  - **Fine:** 12 runs, delays 0.3 → 7.9 s spanning the whole startup curve.
    All 12 exited **143**. No 139/134/138/133.
  - No new crash report appeared in `~/Library/Logs/DiagnosticReports`
    (latest is the pre-integration `nautilus-2026-07-10-010350.ips`, an
    unrelated startup `g_settings` SIGTRAP from an earlier session, see #3).
- **Assessment:** 22/22 SIGTERM runs terminated cleanly. Nautilus installs
  no custom `SIGTERM`/`SIGINT` handler (`rg 'g_unix_signal_add'` in `src/`
  is empty), so `SIGTERM` is the default disposition — the process dies
  immediately without running GApplication shutdown/destructors. That is
  why an early TERM cannot hit a teardown-ordering bug: the destructors
  never run. The original exit-139 was most plausibly a `--quit`/window-close
  teardown path (which *does* run destructors) racing a still-in-flight
  async operation (a thumbnail QL completion or a directory-monitor
  cancellable), not a signal path. It remains unreproduced and is not on
  the critical path.
- **Action:** watch item. If it resurfaces, capture the `.ips` and inspect
  the faulting thread for a callback into a disposed object (likely a
  `GCancellable`/`GTask` completion after its owner was finalized — cf. the
  Phase-2 `nautilus-properties.c` `icon_cancellable` fix pattern). The W3
  thumbnailer notes its requests are "not cancellable mid-flight"
  (`docs/phase3-w3-thumbnails.md`), which is the most likely suspect for a
  quit-during-thumbnailing race.

## 3. Startup `g_settings` SIGTRAP when schemas are not on the GSettings path

- **Severity:** environmental, not a code regression.
- **What:** running `build/src/nautilus` **directly** (not through
  `run-nautilus.sh`) aborts in `nautilus_global_preferences_init` →
  `g_settings_new` → `g_log_abort` (captured in
  `nautilus-2026-07-10-010350.ips`). This is the classic "schema not found"
  instant-abort: the compiled `org.gnome.nautilus` schema is only found when
  `GSETTINGS_SCHEMA_DIR` / `XDG_DATA_DIRS` point at the install prefix.
- **Action:** none — always launch via `run-nautilus.sh` (dev) or the bundle
  launcher (which sets the env). Documented here so the stray `.ips` is not
  mistaken for issue #2.

## 4. Native traffic-light click wedged the main thread (GTK #7964) — FIXED (worked around)

- **Severity:** critical (was): app left "running with no window, cannot
  close or reopen" after clicking a native window button.
- **What:** libadwaita 1.9 force-enables native macOS window controls
  (`GtkWindowControls:use-native-controls`) on every header bar. On
  macOS 26.5 GDK's hit-test for those AppKit buttons
  (`over_native_window_buttons`, `gdkmacosdisplay-translate.c`) fails to
  claim the mouse-down, so AppKit runs `NSButtonCell
  -trackMouse:inRect:ofView:untilMouseUp:` — a modal loop whose matching
  mouse-up GTK's quartz event source has already stolen into its own queue.
  The loop never returns: main thread wedges inside AppKit, GLib main loop
  frozen. A close-button hit tears the window down first, leaving the
  wedged zombie process owning the `org.gnome.Nautilus` LaunchServices
  registration, which blocks every subsequent launch of
  `/Applications/Nautilus.app`. Upstream GTK issue #7964; the upstream fix
  (!9354) is already in Homebrew GTK 4.22.4 and does **not** cure it on
  macOS 26.5.
- **Fix:** `nautilus-application.c` (`macos_setup_native_window_controls`,
  applied from `window_added` for every toplevel): recursively force
  `use-native-controls = FALSE` on all `GtkWindowControls`, re-applied on
  `map` and on `AdwOverlaySplitView` sidebar changes (libadwaita recreates
  the controls there). GTK then draws its own CSS window buttons, which
  never enter AppKit's tracking loop. NSWindow's real traffic lights are
  `setHidden:YES` (verified via lldb: all three `standardWindowButton`s
  hidden; AX still reports a 16×16 close element because the AX attribute
  reflects the style mask, not visibility).
- **Note:** if a stuck instance from an old build is present, kill it
  (`pkill -x nautilus`) before launching the fixed bundle — LaunchServices
  refuses a second instance while the zombie holds the bundle ID.
- **Revisit:** when GTK ships a working #7964 fix for macOS 26, the
  override can be dropped to restore the native look.

## 5. Stateful native-menu items show no checkmark

- **Severity:** cosmetic (from W1's notes, unchanged by integration).
- Show Hidden Files and the sort radio items work but display no checkmark in
  the native NSMenu — GTK's quartz menu tracker cannot observe `view.*`/
  `win.*` action *state*. Upstreamable GTK fix. The items still function.

## 6. Startup SIGSEGV: Back/Forward during initial location load — FIXED (2026-07-16)

- **Severity:** was critical — this is the "Nautilus quit unexpectedly"
  crash-reporter dialog the user saw intermittently.
- **Crash signature** (4 `.ips` hits: 2026-07-09 23:35, 07-10 02:54,
  07-16 11:37 and 11:44 — the last two on the installed
  `/Applications/Nautilus.app`):
  `EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS at 0x38`, faulting frame
  `nautilus_files_view_is_searching + 12` ←
  `nautilus_window_slot_back_or_forward` ← `g_simple_action_activate`
  (`slot.back`) ← key-event dispatch. Every hit is **0.4–2.4 s after
  process launch** (`procLaunch` vs `captureTime` in the .ips).
- **Root cause (upstream Nautilus bug, not port code; two parts):**
  1. The slot's `back`/`forward`/`back-n`/`forward-n` `GSimpleAction`s are
     created **enabled** (GSimpleAction default) and are first synced with
     real history only when `update_back_forward_actions()` runs after the
     initial location finishes loading. During the first ~0.5–2 s of a
     window's life `slot.back` is activatable despite empty history.
  2. `nautilus_window_slot_back_or_forward()` starts with
     `nautilus_files_view_is_searching (self->content_view)`, and
     `content_view` is NULL until `got_file_info_for_view_selection_callback`
     creates the first view — exactly the same startup window.
     `is_searching` dereferences `self->directory` at struct offset 0x38,
     matching the fault address. Any Back activation in that window
     (Alt+Left, a "Back" media key, key events trailing a launcher hotkey)
     segfaults the main thread.
- **Fix** (`src/nautilus-window-slot.c`):
  - `nautilus_window_slot_init`: call `update_back_forward_actions()`
    right after the action entries are added, so Back/Forward start
    **disabled** until there is real history.
  - `nautilus_window_slot_back_or_forward`: NULL-guard `content_view`
    before the `is_searching` check (defense for the
    `restore_navigation_state` path — restore-closed-tab /
    back-in-new-tab re-enable the actions while the new slot's view is
    still NULL).
- **Repro before/after** (lldb, deterministic, no GUI interaction needed):
  break on `create_and_bind_new_content_view` (the instant before the
  first view exists), then evaluate
  `nautilus_window_slot_back_or_forward(slot, TRUE, 0)`.
  Unfixed `build/src/nautilus`: `slot.back` enabled = 1 and the call dies
  with `EXC_BAD_ACCESS address=0x38` (exact user crash). Fixed binary:
  `slot.back` enabled = 0 and the call returns cleanly.
- **Upstreamable:** yes — both halves apply to GNOME nautilus unmodified.

## 7. Startup SIGABRT under hardened runtime: bundled tracker parser module — FIXED (2026-07-21)

- **Symptom:** the Developer ID-signed + notarized 26.7.19-1 build, once
  downloaded (quarantined) and installed, aborted ~2 s after launch.
  Crash: `abort()` ← `g_assertion_message_expr` ← `ensure_init_parser+248`
  ← `tracker_collation_init` ← `tracker_db_interface_sqlite_reset_collator`
  ← … ← `tracker_direct_connection_new` ← `nautilus_tag_manager_init`
  ← `nautilus_application_init` ← main
  (incident `4ECAD4A3-…`, pid 35533). The ad-hoc builds never hit it.
- **Root cause (two faults, the second unmasked by signing):**
  1. libtinysparql loads its collation/parser module
     `libtracker-parser-libicu.so` via `g_module_open()` at a **hard-coded
     absolute path baked at compile time** — `PRIVATE_LIBDIR` =
     `<brew>/Cellar/tinysparql/<ver>/lib/tinysparql-3.0` (see
     `src/common/tracker-parser.c: ensure_init_parser`; there is NO env
     override). The port never bundled that module, so the path only exists
     on a machine with Homebrew's tinysparql. On the dev machine it did, so
     ad-hoc builds "worked for days" — but it would crash on any clean Mac.
     `ensure_init_parser` `g_assert(module != NULL)`s on failure, aborting
     the whole process from *inside* the library (uncatchable via GError).
  2. The **hardened runtime enables Library Validation** (we ship no
     entitlements, matching Shenzhen PDF). Even where the Homebrew module
     path exists, that module is **ad-hoc signed** (no Team ID), so
     `dlopen` is refused → `g_module_open` returns NULL → same assert. This
     is why the crash appeared exactly when we moved to Developer ID +
     hardened runtime. (It was NOT `DYLD_*` env stripping — the launcher
     sets no `DYLD_*` vars.)
- **Fix (structural, keeps signing/notarization):**
  - `package/make-app.sh` bundles `libtracker-parser-libicu.so` into
    `Contents/Resources/lib/tinysparql-3.0/`.
  - `package/bundle-dylibs.sh` binary-patches the baked lookup string in the
    bundled `libtinysparql-3.0.0.dylib` from the absolute Homebrew Cellar
    path to `@executable_path/../Resources/lib/tinysparql-3.0` (the
    replacement is shorter, so it fits in place, NUL-padded — no Mach-O
    resize; done BEFORE signing). `dlopen` resolves `@executable_path` even
    under the hardened runtime; the BFS then rewrites the module's own
    deps to `@executable_path/../Frameworks` and re-signs it with our Team
    ID, so Library Validation accepts it.
  - Safety net (`nautilus-tag-manager.c`, darwin-only): a preflight
    `g_module_open` of the bundled module before handing control to
    libtinysparql. If it ever fails to load again, `setup_database` returns
    a GError and starring degrades to disabled with a `g_warning`, instead
    of the library aborting the app. (A `g_assert` inside a dependency can't
    be caught after the fact; this is why the preflight, not a try/catch.)
  - `package/sign-and-notarize.sh` gained a **launch smoke test**: it
    background-launches the quarantined app copy, waits, and fails the
    release if a new crash report appears or the process isn't alive — the
    exact check whose absence let this ship.
- **Verified 2026-07-21:** notarized quarantined copy (App-Translocated by
  Gatekeeper, as a real download would be) launches and stays alive with no
  new crash; `~/Library/Application Support/nautilus/tags/meta.db` is created
  (starring works); module loads from inside the bundle.
- **Upstreamable:** the packaging fix is port-specific. The
  `ensure_init_parser` hard-abort is arguably a tinysparql robustness bug
  (a missing optional module should not abort the host app).

## 8. Paste crash: cut + paste into the same folder (GDK-macOS NULL-provider clipboard clear) — FIXED (2026-07-22)

- **Severity:** was critical — user-reported crash of the installed
  `/Applications/Shenzhen Files.app` on Cmd-C/Cmd-V of a file (incident
  `4FD0229C-6193-4F2D-92A3-4AED17A739F6`, `nautilus-2026-07-22-180556.ips`).
- **Crash signature:** `EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS at 0x0`,
  main thread: `-[GdkMacosPasteboardItemDataProvider types]+84` ←
  `-[GdkMacosPasteboardItem initForClipboard:withContentProvider:]` ←
  `_gdk_macos_clipboard_claim` ← `gdk_clipboard_set_content` ←
  `nautilus_clipboard_clear_if_colliding_uris` ←
  `nautilus_files_view_move_copy_items` ← `paste_value_received_callback`.
- **Trigger:** pasting when the clipboard operation is a MOVE and the URIs
  collide — i.e. **cut a file, then paste into the folder that still
  contains it** (`clear_if_colliding_uris` matches the clipboard URIs
  against the paste items and clears the clipboard). The same
  `gdk_clipboard_set_content (clipboard, NULL)` "clear" also runs after
  every successful cut-paste (`handle_clipboard_data`, MOVE branch).
- **Root cause (upstream GDK-macOS bug, gtk 4.22.4):**
  `gdk_clipboard_set_content (clipboard, NULL)` is the documented way to
  release a clipboard claim (gdkclipboard.c explicitly allows
  provider == NULL and claims locally with empty formats). The macOS
  backend's claim vfunc forwards the provider unconditionally:
  `_gdk_macos_clipboard_claim()` → `_gdk_macos_clipboard_send_to_pasteboard()`
  (`gdk/macos/gdkmacosclipboard.c:121-124`) →
  `-[GdkMacosPasteboardItem initForClipboard:withContentProvider:nil]` →
  `-[GdkMacosPasteboardItemDataProvider types]`
  (`gdk/macos/gdkmacospasteboard.c:317-341`), which calls
  `gdk_content_provider_ref_storable_formats (nil)`. That fails its
  precondition and returns NULL; the follow-up
  `gdk_content_formats_get_mime_types (NULL, &n_mime_types)` early-returns
  **without initializing the out-param**, so the loop indexes the NULL
  `mime_types` array with stack garbage as the count → NULL read at
  `types+84` (`ldr x0, [x22, x24, lsl #3]` with x22 = 0, disassembly of the
  Homebrew arm64 dylib matches the .ips offset exactly). Whether it crashes
  depends on the stack garbage being nonzero — trivial test programs can
  survive with four `Gdk-CRITICAL`s, but Nautilus's paste path crashes
  reliably. Linux backends (X11/Wayland) handle the NULL provider, so
  upstream Nautilus never sees this.
- **Repro (dev build, scripted, no GUI interaction):** launch
  `run-nautilus.sh` on a folder with one file, drive
  `view.select-all` → `view.cut` → `view.paste` via
  `gtk_widget_activate_action` from lldb, and (to remove the
  stack-garbage lottery) force `*n_mime_types = 7` at the
  `gdk_content_formats_get_mime_types(NULL, …)` early-return. Pre-fix
  binary: exact user crash (`EXC_BAD_ACCESS address=0x0` at `types+84`,
  full user stack reproduced). Fixed binary: the conditional breakpoint
  never fires (formats pointer is never NULL) and the session survives.
- **Fix (port-side, `src/nautilus-clipboard.c`):** new
  `nautilus_clipboard_clear()` used by both NULL-clear call sites
  (`nautilus-clipboard.c` collision path, `nautilus-files-view.c`
  post-cut-paste path). On darwin it claims the clipboard with an **empty
  union content provider** (`gdk_content_provider_new_union (NULL, 0)`)
  instead of NULL — same claim path, valid provider with empty formats, so
  the pasteboard is still cleared (verified: `pbpaste` empty, no warnings);
  elsewhere it keeps the standard NULL clear.
- **Also fixed while regression-testing:** paste-from-Finder ran GTK's
  stock `text/uri-list` deserializer if no in-app drag had happened yet
  (the URI-repair override was only registered in the darwin-only
  uri-list fallback branch, but remote file content also advertises the
  `GdkFileList`/`GFile` gtypes, so the fallback rarely ran).
  `paste_files()` now registers `nautilus_dnd_init_macos()` up front;
  without it a Finder paste produced parentless `file%3A///…` GFiles and
  died with a `g_object_ref` critical in the undo bookkeeping
  (`nautilus_file_undo_info_ext_new`, src_dir NULL) without copying
  anything.
- **Regression-checked (fixed build, scripted via lldb-driven GActions):**
  copy→paste into another folder (file copied, original kept);
  cut→paste into another folder (file moved, clipboard cleared silently);
  cut→paste into the SAME folder (the crash path — survives, file intact,
  clipboard cleared); paste of a Finder-style `public.file-url`+
  `NSFilenamesPboardType` pasteboard written by an external process (file
  copied, no criticals; one flaky no-op observed twice during bring-up
  before the deserializer-registration fix, 4/4 clean after).
- **Upstreamable:** yes, GDK bug — `_gdk_macos_clipboard_claim` must
  tolerate a NULL provider (skip `send_to_pasteboard` and just
  `clearContents`, matching the "release our claim" semantics), and/or
  `-[GdkMacosPasteboardItemDataProvider types]` must guard a nil
  `_contentProvider`. Exact lines: `gdk/macos/gdkmacosclipboard.c:123`
  (unconditional `send_to_pasteboard (self, provider)` for local claims)
  and `gdk/macos/gdkmacospasteboard.c:324-326` (nil-provider deref in
  `types`). The Nautilus-side workaround (empty provider instead of NULL)
  is harmless everywhere and could also be upstreamed as a hardening.
