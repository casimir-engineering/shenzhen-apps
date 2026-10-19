# Phase 3 — W1 integration notes (menu bar, Cmd shortcuts, LaunchServices)

Worker: W1. Scope: PLAN.md §5 Phase 3 tasks 1 (native menu bar + Cmd accelerators)
and 8 (LaunchServices document handling).

Files W1 edited (all inside `nautilus/`):

- `src/nautilus-application.c` — darwin accel remap helper, GMenu menubar model,
  per-window bubble-phase Cmd shortcut controller, `win.macos-edit-location`
  helper action. All additions `#ifdef __APPLE__`.
- `src/resources/menu/nautilus-pathbar-context-menu.ui` — popover accel labels
  (`<Meta>` so popovers display ⌘ on macOS).
- `src/resources/ui/nautilus-view-controls.blp` — same, for Show Hidden Files.
- `src/resources/ui/shortcuts-dialog.blp` — shortcuts dialog now shows the
  macOS (⌘) bindings.

No changes to `nautilus-macos-bridge.h` / `nautilus-macos-menu.m` beyond what
already existed (`nautilus_macos_menu_init()` stays a no-op seam; the menubar is
expressed entirely as a GMenu model in nautilus-application.c, which the GTK
quartz backend renders natively).

## Changes needed in sibling-owned files (for the integrator — W1 did NOT edit these)

### 1. `src/nautilus-files-view.c` — paste from Finder is a silent no-op (owner: W5/clipboard)

`paste_files()` (~line 2812) decides how to read the clipboard by checking
`gdk_content_formats_contain_gtype()` for `NAUTILUS_TYPE_CLIPBOARD`,
`GDK_TYPE_FILE_LIST`, `G_TYPE_FILE` — and does nothing when none match.
On macOS, *external* pasteboard content (files copied in Finder) is exposed by
GDK as mime types only (`text/uri-list`, etc. — see
`load_offer_formats()` in gdk/macos/gdkmacospasteboard.c); GTypes are only
present while the content is app-local. Result: Edit ▸ Paste / Cmd-V works for
in-app copies (verified) but silently ignores files copied in Finder.

Suggested fix in `paste_files()`: add a fallback branch that checks
`gdk_content_formats_contain_mime_type (formats, "text/uri-list")` (and/or
unions the deserializers via `gdk_content_formats_union_deserialize_gtypes()`)
and then reads `GDK_TYPE_FILE_LIST` — GDK's deserializer converts
`text/uri-list` to a file list. In-app paste keeps the fast local path.

### 2. Undo/redo — works, no change needed, but note the modal

`Edit ▸ Undo` of a copy/paste prompts the upstream *"Permanently Delete n
Selected Items?"* AdwAlertDialog (undoing a copy deletes the copies). The
dialog renders in-window (no separate NSWindow) and is invisible to
Accessibility automation — QA scripts must expect it. Undo (Cmd-Z) and redo
(Cmd-Shift-Z) verified working end-to-end on disk.

## Notes for the packaging worker

- Task C needs **no packaging additions**: GTK's quartz backend
  (`GtkApplicationQuartzDelegate application:openFiles:`) converts opened
  files/folders to `GFile`s and calls `g_application_open()`;
  `NautilusApplication` already has `G_APPLICATION_HANDLES_OPEN` and its
  `::open` handler opens folder GFiles. `public.folder` in
  `Info.plist.template` is sufficient. No `CFBundleURLTypes` needed
  (`nautilus://` was not implemented — out of scope per brief).
- End-to-end LaunchServices delivery (`open -a Nautilus ~/somedir`, Finder
  "Open With") is only testable once the .app bundle exists — QA item for the
  packaging phase. CLI `::open` routing already works.
- GLib on macOS persists GSettings through the **NSUserDefaults (nextstep)
  backend**, and the defaults domain follows the process/bundle. Un-bundled
  dev binaries write to the `nautilus` domain
  (`~/Library/Preferences/nautilus.plist`); once bundled, settings will land
  under the bundle identifier instead, so dev-run settings won't carry over.
  Also: the Homebrew `gsettings` CLI writes/reads **its own** domain
  (`gsettings.plist`) — do not use it to verify the app's settings; use
  `defaults read nautilus <key-path>`.

## Backend quirks and QA checklist items

- Known/expected: one `gdk_macos_monitor_get_workarea` Gdk-CRITICAL per window.
- Stateful menu items (Show Hidden Files, sort radio items) show **no
  checkmark** in the native menubar: GTK's quartz menu tracker observes the
  application muxer, which cannot see `view.*`/`win.*` action *state* (it
  resolves enablement + activation through the focus widget instead, so the
  items do work). Cosmetic GTK backend limitation; upstreamable fix would be in
  gtk/gtkapplication-quartz-menu.c (`didChangeToggled`).
- `File ▸ Close Window` (Cmd-Shift-W): menu item verified working; the key
  equivalent could not be verified under parallel-worker focus contention —
  re-check in solo QA.
- Not verifiable programmatically in this environment (parallel workers fight
  over frontmost + AX can't see AdwDialog internals): Settings dialog opening
  via Cmd-comma, Cmd-T new tab count, Cmd-F search focus, Cmd-R reload effect,
  Get Info dialog, Cmd-1/Cmd-2 view-mode switch, Enter Location popover
  (Cmd-Shift-G / Cmd-L). All their actions/accels are registered (see accel
  table) and their siblings in the same dispatch paths are verified; needs
  eyes-on QA.
- Deliberately NOT remapped to Cmd: `win.tab-move-left/right`
  (Ctrl-Shift-PgUp/PgDn upstream — kept on Ctrl; Cmd-Shift-PgUp has no macOS
  precedent), `<alt>1..9` tab switching (Alt = Option works fine),
  function-key accels (F1 help, F5 reload alias, F9 sidebar, F10 location
  menu). Widget-local `<control>` shortcuts inside sibling-owned files
  (e.g. `view.select-pattern` Ctrl-S, `view.current-directory-console`
  Ctrl-period, slot Ctrl-1/2) still work on the physical Ctrl key; their
  primary macOS equivalents are covered via the menubar/bubble controller
  where they matter.

## Testing artifacts

- `docs/phase3-w1-menubar-dump.txt` — full System Events dump of the native
  menu bar tree (all six menus + AppKit-injected app/Window menu items).
- `docs/phase3-w1-menu-keyequivs.txt` — per-item key equivalents as AppKit
  reports them (AXMenuItemCmdChar/CmdModifiers).
- `docs/phase3-w1-accel-table.md` — before → after accelerator table and
  collision decisions.
