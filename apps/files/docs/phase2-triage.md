# Phase 2 — First launch & runtime triage

Status of the macOS-port Nautilus (`51.beta`) after Phase 2. Binary:
`build/src/nautilus` (arm64). Launch via `./run-nautilus.sh`.

## Summary

The binary launches reliably into a browsable window of `$HOME`, with icons
rendering, both **with** and **without** a session D-Bus. `--version`,
`--new-window`, `--select`, and `--quit` all work. A normal
launch → browse → quit cycle produces **no console criticals** — only one
intentional `g_message` and one harmless GTK-internal `Gdk-CRITICAL` (see
below). The `G_APPLICATION_NON_UNIQUE` fallback was **not** needed.

## What was verified (this phase)

| Area | Result | Evidence |
|---|---|---|
| Launch to `$HOME` (with bus) | PASS | `docs/phase2-first-launch.png` |
| Launch to `$HOME` (no bus) | PASS, no crash | `docs/phase2-nobus-launch.png` |
| Bare launch (no args) → Home | PASS | `/tmp/phase2-noargs.png` |
| Open specific dir (`nautilus /tmp/naut-test`) | PASS, pathbar + icons correct | `/tmp/phase2-testdir.png` |
| `--new-window <dir>` | PASS (2nd window created) | window enumeration |
| `--select <file>` | PASS (routed to instance) | window enumeration |
| `--quit` | PASS (clean shutdown, no zombie) | — |
| Starred view (`starred:///`) | PASS, "No Starred Files", no tag-manager crash | `/tmp/phase2-starred.png` |
| Network view (`x-network-view:///`) | Empty & broken (gvfs) → **hidden on darwin** | `/tmp/phase2-networkview.png` |
| Icon theme (Adwaita + hicolor) | PASS, all folder/file/special icons render | screenshots |

## Console output during a clean launch-browse-quit cycle

```
** Message: Localsearch indexer is not available on macOS; skipping
(org.gnome.Nautilus): Gdk-CRITICAL **: gdk_macos_monitor_get_workarea: assertion 'GDK_IS_MACOS_MONITOR (self)' failed
```

- **`Localsearch indexer …`** — intentional. Emitted once by our darwin guard
  in `nautilus-localsearch-utilities.c` instead of the old repeated
  Tracker/Miner connection warnings.
- **`gdk_macos_monitor_get_workarea` Gdk-CRITICAL** — see "Known issues" #1.

## Fixes applied this phase (all `#ifdef __APPLE__`-guarded where behavioural)

1. **SIGTRAP on startup — Tracker3 schema abort.**
   `nautilus-global-preferences.c` unconditionally did
   `g_settings_new ("org.freedesktop.Tracker3.Miner.Files")`. That schema is not
   shipped by the `tinysparql` Homebrew formula (library only), so GLib aborted.
   Now guarded: on darwin we only create it if `check_schema_available()` says
   so; otherwise `localsearch_preferences` stays NULL and the two readers
   (`get_tracker_locations`) short-circuit.
2. **Localsearch miner connection.**
   `nautilus-localsearch-utilities.c` no longer tries to reach
   `org.freedesktop.Tracker3.Miner.Files` over the (absent) bus on darwin. It
   logs a single `g_message` and reports `G_IO_ERROR_NOT_SUPPORTED`, so the
   `localsearch` search provider cleanly reports `should_search == FALSE` and
   the `simple` engine takes over. Kills the previous warning spam.
3. **No-bus D-Bus launcher crash.**
   `nautilus-dbus-launcher.c` `proxy_ready()` dereferenced a NULL proxy when
   there is no session bus (three `GLib-GIO-CRITICAL`s). Now returns early if
   the bus proxy is NULL, and the per-app "Error creating proxy" messages are
   downgraded to `g_debug` on darwin (they are expected — no GNOME
   Settings/Disks/Console services exist on macOS).
4. **No-bus `update_dbus_opened_locations` critical.**
   `nautilus-application.c` asserted a non-NULL D-Bus object path even when
   `dbus_register` was skipped (no bus). Now returns early if `fdb_manager` is
   NULL (nothing to publish).
5. **gvfs network view hidden on darwin.**
   `nautilus-sidebar.c` — the "Network" sidebar row (backed by
   `x-network-view:///` → gvfs `network:///`) is removed on darwin. This both
   (a) hides a permanently-empty/broken view and (b) eliminated the launch-time
   `Could not mount 'network:///': volume doesn't implement mount` warning,
   which was triggered by building that row. Re-add with a native
   (SMB / `NSNetServiceBrowser`) provider in Phase 3.
6. **Properties dialog use-after-dispose (latent upstream bug).**
   `nautilus-properties.c` `real_dispose` cleared `icon_cancellable` without
   cancelling it, risking a callback into a disposed widget during a slow
   custom-icon load. Added the one-line `g_cancellable_cancel`. Not observed at
   runtime (needs GUI interaction) but cheap and correct.

## Known issues / carried forward

### 1. `Gdk-CRITICAL: gdk_macos_monitor_get_workarea assertion 'GDK_IS_MACOS_MONITOR (self)'`
- **Where:** GTK4 itself (Homebrew `gtk4 4.22.4`), macOS/quartz backend — *not*
  Nautilus source. Fires once per window creation, when the window default size
  is set before the surface is attached to a real monitor.
- **Impact:** none observed — the window still opens, sizes, and positions
  correctly. It is a `CRITICAL` only because GTK uses `g_return_val_if_fail`.
- **Action:** not fixable from Nautilus without patching GTK. Left as-is; flag
  for a GTK-macOS upstream report. If it becomes noisy, a Phase 3 option is to
  set the default size after `map` rather than before.

### 2. GUI click-through interactions — UNTESTED (cannot be driven programmatically)
The following require real mouse/keyboard interaction and were **not** exercised
this phase (no fake "PASS"):
- Copy / cut / paste of files
- Rename (inline + dialog)
- Move to Trash / delete
- Drag & drop (in-app and to/from Finder)
- Double-click to open files with default apps
- Context menus, Properties dialog population, Open With
- Star / unstar a file (tag manager write path — only the empty view was seen)
- Space-bar preview (no QuickLook yet — Phase 3)

These are the acceptance items that need a human or a UI-automation harness.
Phase 3 workers should treat them as unverified.

### 3. Trash / Network browsing
- Trash *item* still points at `trash:///` (no gvfs backend). Not yet reworked —
  Phase 3 task 2 (delegate to Finder / Full Disk Access).
- Network view hidden (see fix #5).

## Reproduction environment
- macOS 26 (darwin 25), Apple Silicon arm64.
- Dev session bus: `launchctl ... org.freedesktop.dbus-session.plist`, found via
  `DBUS_LAUNCHD_SESSION_BUS_SOCKET`.
- Runtime env encapsulated in `run-nautilus.sh` (XDG_DATA_DIRS,
  GSETTINGS_SCHEMA_DIR, dev-bus discovery). `NAUTILUS_NO_DBUS=1` forces no-bus.
