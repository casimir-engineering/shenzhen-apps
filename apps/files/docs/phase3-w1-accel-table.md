# Phase 3 — W1 accelerator table (upstream → macOS)

Mechanism: every accelerator that funnels through
`nautilus_application_set_accelerator(s)` is rewritten on `__APPLE__` by
`macos_remap_accel()` — `<Control>`/`<Ctrl>`/`<Ctl>`/`<Primary>` →
`<Meta>` (= Cmd in GDK's macOS backend). Two exceptions (`win.undo`,
`win.redo`) keep their upstream Ctrl accels app-level and get their Cmd
bindings from a per-window bubble-phase `GtkShortcutController`
(`macos_setup_window()`), so text entries keep native Cmd-Z behaviour.
Text-editing-sensitive combos (Cmd-X/C/V/A, Cmd-Up/Down, Cmd-Backspace…)
are also bound in that bubble controller instead of NSMenuItem key
equivalents, so a focused GtkText always wins.

Verified = exercised end-to-end via synthesized keystrokes/menu clicks with
on-disk / window-count / defaults evidence.

| Action | Upstream | macOS binding | Path | Verified |
|---|---|---|---|---|
| app.clone-window (New Window) | `<Primary>n` | Cmd-N | app accel (remap) | yes — window count 1→2 |
| app.quit | `<Primary>q` | Cmd-Q | app accel (remap) | yes — process exited |
| app.preferences | `<Primary>comma` | Cmd-, | app accel (remap) | registered; dialog not AX-visible |
| app.help | `F1` | F1 | unchanged | menu item present |
| win.new-tab | `<control>t` | Cmd-T | app accel (remap) + menu equiv | registered |
| win.close-current-view (Close Tab/Window) | `<control>w` | Cmd-W | app accel (remap) + menu equiv | yes — window closed |
| window.close (Close Window) | — | Cmd-Shift-W | menu key equivalent only | menu click verified; key equiv needs solo QA |
| win.undo | `<control>z` | Cmd-Z (bubble) + Ctrl-Z kept | bubble controller | yes — undo of paste ran (confirm dialog) |
| win.redo | `<shift><control>z` | Cmd-Shift-Z (bubble) + Ctrl-Shift-Z kept | bubble controller | yes — copies restored |
| view.cut | (menu) | Cmd-X | bubble controller | enablement verified |
| view.copy | (menu) | Cmd-C | bubble controller | yes — pasteboard armed |
| view.paste | (menu) | Cmd-V | bubble controller | yes — files duplicated on disk |
| view.select-all | (menu) | Cmd-A | bubble controller | yes — Copy enablement flipped |
| view.move-to-trash | `Delete` (kept) | Cmd-Backspace + Delete | bubble + menu equiv | yes — files left dir |
| view.new-folder | `<control><shift>n` (view-local, kept) | Cmd-Shift-N | menu key equivalent | yes — folder created |
| view.show-hidden-files | `<control>h` (view-local, kept) | Cmd-Shift-. | menu key equivalent (+Cmd-> bubble alias) | yes — defaults key toggled |
| view.zoom-in | `<control>equal\|plus\|KP_Add` | Cmd-= / Cmd-+ / Cmd-KP+ | menu equiv + bubble | registered |
| view.zoom-out | `<control>minus\|KP_Subtract` | Cmd-- | menu equiv + bubble | registered |
| view.zoom-standard | `<control>0\|KP_0` | Cmd-0 | menu equiv + bubble | registered |
| view.open-with-default-application | (menu) | Cmd-O, Cmd-Down | menu equiv + bubble | registered |
| view.properties (Get Info) | `<Primary>i` (dialog) | Cmd-I | menu key equivalent | registered |
| slot.focus-search | `<control>f` (slot-local, kept) | Cmd-F | menu key equivalent | registered |
| slot.search-global | `<control><shift>f` (slot-local, kept) | Cmd-Shift-F | menu key equivalent | registered |
| slot.reload | `F5\|<ctrl>r` (slot-local, kept) | Cmd-R + F5 | menu key equivalent | registered |
| slot.back | `<alt>Left` (kept) | Cmd-[ + Alt-Left | menu key equivalent | yes — title changed back |
| slot.forward | `<alt>Right` (kept) | Cmd-] + Alt-Right | menu key equivalent | registered |
| slot.up (Enclosing Folder) | `<alt>Up` (kept) | Cmd-Up + Alt-Up | bubble controller | yes — navigated to parent |
| win.go-home | `<alt>Home` (kept) | Cmd-Shift-H + Alt-Home | menu key equivalent | menu item present |
| slot.files-view-mode grid/list | `<control>1` / `<control>2` (slot-local, kept) | Cmd-1 icons / Cmd-2 list (Finder order) | menu key equivalents | registered |
| win.macos-edit-location (Enter Location) | n/a (new) | Cmd-Shift-G + Cmd-L | menu equiv + bubble | registered (popover not AX-visible) |
| slot.bookmark-current-directory | `<Primary>d` | Cmd-D | bubble controller | registered |
| win.restore-tab | `<shift><control>t` | Cmd-Shift-T | app accel (remap) + menu equiv | registered |
| win.toggle-sidebar | `F9` | F9 | unchanged | menu item present |
| win.tab-move-left/right | `<shift><control>Page_Up/Down` | unchanged (Ctrl) | app accel, exempt by design | — |
| win.current-location-menu | `F10` | unchanged | app accel | — |
| tab switch | `<alt>1..9` | Option-1..9 (unchanged) | app accel | — |

## Collision / OS-reserved decisions

- **Cmd-H** (upstream `<control>h` = show hidden): NOT remapped — Cmd-H is
  OS-reserved (Hide app; AppKit injects its own Hide item). Show Hidden Files
  moved to **Cmd-Shift-.** (the Finder-native combo). The view-local Ctrl-H
  binding still exists for muscle memory.
- **Cmd-M**: left to AppKit's window-submenu Minimize (`window.minimize`
  key equivalent matches the native binding; AppKit also injects its own).
- **Cmd-W vs old Ctrl-W**: Cmd-W = Close Tab (closes window when it's the last
  tab, upstream behaviour); Close Window gets Cmd-Shift-W (Finder/Safari
  convention).
- **Cmd-1 / Cmd-2**: swapped to Finder order (1 = icons/grid, 2 = list);
  upstream Ctrl-1 = list / Ctrl-2 = grid stays untouched in the slot-local
  controller.
- **Cmd-[ / Cmd-]** chosen for Back/Forward (browser/Finder convention);
  Alt(-Option)-Left/Right still work.
- **Cmd-D** = Bookmark current location (browser convention; no conflict —
  Finder's Cmd-D "Duplicate" maps to nothing here; duplicate is available via
  copy/paste).
- **Cmd-Z in text fields**: solved via bubble-phase binding rather than accel
  remap (see header comment in nautilus-application.c) so rename popover /
  location entry / search entry keep GtkText's own undo.
- **Cmd-Up/Down**: Cmd-Up = parent folder, Cmd-Down = open selection (Finder
  parity), both bubble-phase so text-entry cursor motion is unaffected.
