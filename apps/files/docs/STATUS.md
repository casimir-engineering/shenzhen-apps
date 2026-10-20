# Shenzhen Files (Nautilus → macOS) — Integrated Build Status

**Date:** 2026-09-14 · **Version:** 26.9.14 build 1 (upstream 51.beta) · arm64,
`debugoptimized`, `-Dmacos_port=true` · Homebrew GTK 4.22.4 / GLib 2.88.2.

Single integrated tree at `nautilus/` (uncommitted working-tree patches).
Deliverables: `build/src/nautilus`, `install/`, `dist/Shenzhen Files.app`,
`dist/ShenzhenFiles-mac-arm64.dmg` (46 MiB), patch record in `patches/`.
Published: https://github.com/casimir-engineering/shenzhen-files
(releases carry the DMG; the self-updater consumes `releases/latest`).

---

## Rebrand + self-update + first public release (2026-07-19, W14)

The app now ships as **Shenzhen Files**, styled after the Shenzhen PDF
product line (`~/Projects/shenzhen-pdf`), with its auto-update mechanism
ported over:

| Item | State |
|---|---|
| Identity | `Shenzhen Files.app`, bundle id `com.intuition.shenzhenfiles` (mirrors `com.intuition.shenzhenpdf`), CFBundleName/DisplayName "Shenzhen Files"; release identity is date-based `YY.M.DD-BUILD` in `SZFReleaseTag`, while the numeric `CFBundleVersion` remains globally increasing for macOS cache ordering |
| Menu bar | Verified via System Events on the installed bundle: Apple · **Shenzhen Files** · File · Edit · View · Go · Window · Help; app menu = About Shenzhen Files / Check Permissions… / Finder Integration… / **Check for Updates…** / Settings… / … / Quit Shenzhen Files |
| Window + location entry | Cmd-T is application-scoped on macOS: it creates a starting-location window after the last window closes, and otherwise opens a tab in the active browser window. Trimmed plain text in the location field becomes a current-folder search; absolute, home-relative, explicit relative, separator-containing, and URI inputs retain navigation semantics. |
| Mounted volumes | `src/nautilus-macos-volumes.m` supplies the startup disk, external disks, disk images, and network volumes missing from GLib's Darwin volume monitor. One shared volume monitor feeds every window's sidebar: NSWorkspace did-mount, did-unmount and did-rename-volume notifications plus Disk Arbitration callbacks are coalesced, the list is rescanned off the main thread, and each sidebar rebuilds once per real change: a volume caught halfway through unmounting is left out of a scan instead of showing for a moment as an extra "Macintosh HD" row (see "Follow-ups to the three fixes" below), and a share or folder whose name has precomposed accented or Hangul characters is listed too (see "Precomposed mount point names" below). Measured with real disk images and a real WebDAV network volume, every subscriber sees a mount, unmount, eject or rename at most 63 ms after the command that made it returns (renames usually before it returns); before 2026-10-13 a newly mounted volume never appeared until a window was opened (see "Volume hot-plug fixed" below). The sidebar merges the volumes into the mounts section without GIO duplicates and provides Finder-like eject/unmount controls through `NSWorkspace`. Before eject, every active or inactive tab on the target volume is redirected to Home; the app waits for all replacement views to become idle, closes its directory enumerators, and only then asks macOS to eject. A timeout or failed navigation leaves the volume mounted and reports the error. |
| Open With | GLib exposes macOS application bundles as `file://` URLs; normalizing them before `NSWorkspace iconForFile:` restores real chooser icons. Explicit choices feed a per-content-type Frequently Used section (4 shown / 8 retained / 64 types), ranked by count then recency and atomically persisted as mode `0600` without filenames. |
| Logo / icon | `package/AppIcon-source-v7.png` and generated `AppIcon.icns` are restored byte-for-byte to the approved pre-updater geometry (SHA-256 `6197e998…`): folder breathing room and the large, legible white **深圳** signature fully contained inside it. Bundled launches leave `NSApplication.applicationIconImage` alone so LaunchServices supplies the same native enclosure and optical scale as neighboring Dock icons; update-time forced registration plus the globally increasing bundle build refreshes the cached artwork. |
| Self-updater | `src/nautilus-macos-updater.m` — port of shenzhen-pdf `SPDFUpdater.mm` (silent daily check with flock'd 24h gate in `~/Library/Application Support/Shenzhen Files/update.json`, hourly re-arm + wake/day-change catch-ups, Install/Skip/Later alert, download panel, DMG mount + extract, detached `--post-update` helper doing the move-aside two-rename swap + relaunch + `.old` rollback handshake). The verified app is moved into owner-only persistent staging beside the installed bundle before the parent exits; helper launch errors are handled, stale LaunchServices process records are rejected with a real PID liveness check, and the launch handshake requires the exact version plus build. Relaunch forces LaunchServices registration so the updated bundle and icon replace cached versions. Compiled **with ARC** as its own static lib (`libnautilus-macos-updater.a`) — the MRC bridge flags crash it (verified: SIGSEGV in the JSON parse without ARC). Trust model now matches shenzhen-pdf: offline Developer ID + notarization verification (Team ID pin 66LJ4BV7Q3, hardened-runtime + bundle-id pins); the GitHub sha256 digest is a corruption heuristic |
| Updater incident + corrected validation | **Published builds through `26.9.12-1` are affected.** Foundation `NSTask` made the helper a process-group leader, so unconditional `setsid()` returned `EPERM`; `26.9.14-1` accepts only that exact expected case. The first `26.9.14-1` asset then exposed a second test defect: its fixture used identical source/destination versions, allowing `NSBundle`'s stale path cache to make post-rename identity verification fail on a real old→new update. The amended verifier parses the `Info.plist` bytes currently on disk, and its enforced test now stamps the disposable source `0.0.0-0` / build `1` before updating to the candidate. The amended notarized DMG passed installed `26.8.27-2` → `26.9.14-1` updates through both a GitHub-hosted pre-amendment feed and the actual production `releases/latest` API/asset, including digest/notarization verification, DMG extraction, persistent staging, readiness, swap, exact-path relaunch, `update_ok`, executable and icon hashes, and complete `.old`/staging cleanup. |
| Repo / release | Public repo `casimir-engineering/shenzhen-files` (package/, patches/, docs/, tools/ — upstream tree reproduced via `patches/macos-port-full.patch`); first release `26.7.19-1` ("26.7.19-1 - First release", shenzhen-pdf's format) with the DMG attached |
| Installed | `/Applications/Shenzhen Files.app` (**Developer ID signed + notarized**, team 66LJ4BV7Q3); old `/Applications/Nautilus.app` **removed**. ⚠ New bundle id + name = TCC resets: **Full Disk Access (and Accessibility for the save-panel handoff) must be re-granted** to Shenzhen Files. Config still lives under `~/.config/nautilus` (internal name unchanged) so preferences/integration state carry over |

Port-controlled user-visible strings (FDA walkthrough, Finder-integration
first-run + prefs, services error) now say "Shenzhen Files"; the GLib
application id stays `org.gnome.Nautilus` (D-Bus, gschema paths) —
`MACOS_BUNDLE_ID` in `nautilus-macos-integration.m` carries the
LaunchServices-facing id for the default-handler integration.

---

## What works (verified this pass)

| Area | Status | How verified |
|---|---|---|
| Integrated build | **Clean** `ninja -C build` | No warnings from port code; W7's `-Wno-error=missing-prototypes` **not needed** (removed — W5's prototypes compile clean) |
| Launch (dev + bundle) | **PASS** | Clean stderr except the one known `gdk_macos_monitor_get_workarea` GTK critical per window |
| Native menu bar | **PASS** | System Events dump: Apple · nautilus · File · Edit · View · Go · Window · Help |
| FDA first-launch prompt | **PASS** | Shows over first window on both dev and **bundle** first launch (`docs/phase6-bundle-fda-prompt.png`); bundle TCC probe returns "denied" → prompt shows |
| FDA menu item + `app.fda-prompt` | **PASS** | "Grant Full Disk Access…" present in Help menu; action fires the dialog via `gdbus … org.gtk.Actions.Activate fda-prompt` |
| Paste from Finder | **FIXED (build/static verification)** | `paste_files()` now tries every file representation (Nautilus clipboard, `GDK_TYPE_FILE_LIST`, `GFile`, then `text/uri-list`) before considering `GDK_TYPE_TEXTURE`. Finder's preview texture can therefore no longer turn a copied file— including one from a read-only location—into a pasted PNG. Image-only clipboard pastes remain supported as the fallback. |
| Copy into `$HOME` (W7 fix) | **PASS** | `FileOperations2.CopyURIs` into `$HOME` succeeds — no "destination is read-only" dialog (firmlink readonly fix holds) |
| FileOperations2 D-Bus | **PASS** | `CopyURIs` into a temp dir and into `$HOME` both land files |
| QuickLook thumbnails | **PASS** | Grid shows real thumbnails; 10/10 cached to `thumbnails/x-large/`; warm relaunch issues 0 QL requests |
| Spotlight search | **PASS** | `spotlight:` provider starts/queries/stops per keystroke against the correct scope; hits stream into the view (searched "STATUS" in the repo dir) |
| Toolbar search button | **FIXED (headless test; the button itself needs checklist O)** | The magnifier at the right of the toolbar searches the current folder and its subfolders in the current tab, like Cmd-F, and stays pressed while the search is open; clicking it again closes the search. During Search Everywhere it is hidden, as upstream hides its folder search toggle. Search Everywhere is in the menu bar (Find ▸ Search Everywhere, ⇧⌘F) and on the "No Results Found" page. Until 2026-10-13 the button started Search Everywhere; see "Toolbar search button searches the current folder" below. |
| Backspace goes back | **FIXED (headless test; the keys in a window need checklist Q)** | In the file list and the sidebar, the Delete key goes back like the toolbar's Back button. Cmd-Delete still moves the selection to the Trash and Cmd-Shift-Delete still deletes it. While renaming, editing the path or typing a search, Delete still deletes text; while a search is open it edits the search, also when the file list has the focus. See "Backspace goes back" below. |
| Cmd-J (Friends) and Cmd-K (Search Commands) | **ADDED 2026-10-20 (real key events on a hidden window; eyes-on checklist R)** | `tools/test-macos-friends-shortcut.sh` (exit 0, 73 checks, "test-nautilus-friends-shortcut passed") posts Cmd+J, Cmd+K, letters, arrows, Return and Escape as NSEvents to the app's event queue, so they go through GDK, GTK and AppKit's menu key equivalents as typed keys do, on a mapped window with the real Friends button whose NSWindows are never ordered on screen. Cmd+J opens the dropdown with the keyboard in its search field and closes it from that field, one toggle per press (also with GTK's binding removed: the View menu's key equivalent alone toggles); "friends" + Return in Cmd+K opens Friends; "friend", "nearby", "add by id", "chat" list Open Friends; with Friends off Cmd+J runs nothing and Cmd+K lists no Friends command. With the wiring stubbed out (the tree before this change) the same test fails 11 checks (exit 1). `tools/test-friends-adapter.sh` passes too and checks that a build without Friends has no Friends row in the shortcuts dialog. No earlier Cmd-J or Cmd-K binding existed in Files. |
| QuickLook space-bar preview | **FIXED (headless controller tests; panel needs checklist L)** | `QLPreviewPanel` opens on selection + space without taking the keyboard, so space, Escape and Cmd-Y close it and arrow keys move the selection while it follows. Until 2026-10-13 the panel was made key, Quick Look closed itself on the second space and the Files window never got the keyboard back; see "Quick Look keyboard focus fixed" below. |
| Apps, packages and archives | **FIXED (headless tests; menus and dialogs need checklist K)** | Opening an app (double-click, Enter, Cmd-O, search results, Starred, sidebar bookmarks) launches it through `NSWorkspace`; other packages (`.rtfd`, `.pages`, …) open with their default app, and Show Package Contents browses inside. Archives offer Extract and Extract to… in the context menu and the File menu; double-click still opens them with their default app. Until 2026-10-13 apps opened like folders and no file counted as an archive; see "Opening apps and extracting archives fixed" below. |
| Trash / Show in Finder (W2) | **PASS (native fixture + bridge)** | Native files now move through `NSFileManager trashItemAtURL`, so the operation and the sidebar's Finder Trash window use the same system Trash; a real fixture landed under `~/.Trash` and disappeared from its source. Remote locations keep the GIO fallback. `nautilus_macos_trash_open_in_finder`, `show_in_finder`, and `show_in_finder_files` drive Finder. |
| Permanent delete | **PASS (build/static verification)** | Edit ▸ **Delete Permanently…** exposes `Cmd-Shift-Backspace`, with a bubble-phase shortcut fallback and shortcut-help entry. It activates Nautilus's existing direct-delete path, whose destructive dialog requires explicit confirmation before deletion. |
| Open With chooser icons (.icns) | **PASS** | New NSWorkspace→GdkTexture bridge renders real app icons (Safari/TextEdit verified) instead of generic ones |
| Starring / ontology in bundle | **PASS** | Bundle honors launcher-set `NAUTILUS_DATADIR`; tag DB (`meta.db`) created from bundled ontology — the relocatability fix works |
| Finder-like Dock lifecycle | **PASS (scripted E2E)** | `scratch-fonts/verify-lifecycle.sh` on the installed bundle: close last window (Cmd-W) → window gone, process alive (still alive 14 s later, past the upstream 12 s inactivity timeout); `reopen` Apple event (= Dock-icon click) and `open -a Nautilus` both open a NEW window; `quit` Apple event (= Dock ▸ Quit) and the Cmd-Q accelerator both exit the process within seconds. 10/10 checks + 2 extra-path checks pass |
| Reopen window centered on Dock's screen | **PASS (scripted E2E, 2 displays)** | `scratch-fonts/verify-center.sh`: mouse on external display → reopened window centered there (Δ 0/15.5 px, Dock-migration inset); mouse on built-in display → Δ 0.0/0.0 px. Screen = the one under `[NSEvent mouseLocation]`; move via `gdk_macos_surface_get_native_window()` + `setFrameOrigin:` one idle after `map` |
| Cold-launch first window on mouse's screen | **PASS (scripted E2E, 2 displays)** | `scratch-fonts/verify-coldlaunch.sh` (`open -g`, no focus steal): external Δ 0/0.5 px, built-in Δ 0/0 px, file-open launch Δ 15/29.5 px — all on the correct screen. Root cause: GDK's placement feeds AppKit bottom-left mouse coords into a top-left-coords monitor lookup (y flipped → wrong screen). Fix: mouse screen captured at startup, first window armed with the shared centering machinery (one-shot) |
| Font rendering (13 pt Medium fix) | **PASS (pixel evidence)** | Before/after/native comparison `scratch-fonts/evidence_before_after.png`; "Starred" @1x ink coverage: before 167 lit / 73 solid px → after 230 lit / 109 solid px (Finder-normalized sizes). See "Font rendering root cause" below |
| LaunchServices file-type icons (W11) | **PASS (headless)** | `scratch-fileicon/test-fileicon`: `.kicad_pro` renders the KiCad document icon (PNG dump verified); per-extension cache — 6 AppKit calls for 6 types, second pass 100% hits (1 µs vs 75 ms); themed/thumbnail precedence honored (txt/zip/pdf/py untouched) |
| W11 icon scaling fix (HiDPI) | **PASS (headless)** | Reported bug: `.drawio` grid icon rendered scale× oversized, overflowing the cell over the label. Root cause: the hook returned the size×scale device-pixel texture directly; its intrinsic size was consumed as logical points by `NautilusImage`'s fallback path. Fixed in `nautilus-file.c` by snapshotting into a size-pt logical box (same technique as thumbnails). Harness: full grid (48/64/96/168/256) + list (16/32/64) ladder × scale 1/2 — bridge px exact and wrapped intrinsic == logical pt on all 16 rungs, plus default-grid-zoom regression checks |
| "Open in Terminal" (W11) | **PASS (bridge)** | `nautilus_macos_open_in_terminal` resolved Terminal.app and opened one window cd'd at the target (closed immediately); menu wiring static-verified, GUI click needs eyes-on |
| Session-bus routing (dev) | **PASS** | `run-nautilus.sh` now derives `DBUS_SESSION_BUS_ADDRESS` from the launchd socket (Homebrew GLib ignores the launchd var); CLI verbs + D-Bus introspection work |
| Per-folder view metadata persists (sort, columns, zoom…) | **PASS (full loop, installed bundle)** | Full write→quit→relaunch→restore loop verified against `/Applications/Nautilus.app` (scrambled mtimes so name/size/date orders all differ): header click wrote `user.nautilus-metadata-nautilus-icon-view-sort-by=date_modified` to the folder; a fresh process restored the Modified sort indicator + row order. Earlier "doesn't work" report root-caused: the tested Nautilus **process** predated the fix (started Jul 16 19:52, fix installed Jul 17 16:54) — the Dock-lifecycle keeps the old process alive across window close/reopen, so a full Cmd-Q quit is required to pick up a new binary after install. | Root cause: upstream persists per-folder state in the GIO `metadata::` namespace, which is backed by gvfsd-metadata — a daemon that doesn't exist on macOS, so every write failed silently ("Setting attribute … not supported") and every session fell back to defaults. Fix (darwin-gated, centralized in `nautilus-vfs-file.c` set + `nautilus-file.c` read): metadata now round-trips through GIO's `xattr::` namespace → native `user.nautilus-metadata-*` extended attributes. xattrs survive same-volume moves/renames and are copied with files; list-valued keys (visible columns, column order, emblems) are stored `;`-joined since xattrs are plain strings (`nautilus_metadata_key_is_list()` drives the split). `NAUTILUS_FILE_DEFAULT_ATTRIBUTES` gains `xattr::*` on darwin so folder loads fetch it. **Everything using nautilus_file_[gs]et_metadata now persists**: sort column + direction (list & grid), list-view visible columns + column order, custom icons/emblems. Sort restore goes through `real_set_sort_state` (blocked handler) → does NOT trigger the header-click scroll-to-top. Verified: header click → `user.nautilus-metadata-nautilus-icon-view-sort-by=date_modified` on the folder; relaunch → Modified column restored as sort indicator; user confirmed on their machine |
| List view: date/size columns sort descending on first click | **PASS (scripted)** | First click on Modified/Created/Accessed/Recency/Trashed On/Size/Starred header now sorts descending (newest/largest first, Finder behavior); second click toggles to ascending. Mechanism: `on_sorter_changed` in `nautilus-list-view.c` detects "switched to a new column whose NautilusColumn :default-sort-order is DESCENDING while GTK made it ascending" and re-sets the direction (handler blocked). `size` and `trashed_on` gained the DESCENDING declaration in `nautilus-column-utilities.c` (dates/recency/starred already had it, previously unused). Restores/menu go through `real_set_sort_state` (never inverted, exact); indicator arrow matches order. Verified scripted: click 1 → newest-first (⌄), click 2 → oldest-first (^), persisted xattr tracked (true→false) |
| List view: header-click sort scrolls to top | **PASS (scripted, both directions)** | Clicking a column header (Name/Size/Modified) jumps the list to row 0 instead of staying on an arbitrary slice of the re-sorted list (Finder behavior). Hook: `on_sorter_changed` in `nautilus-list-view.c` — fires only for user header clicks; programmatic sort changes (directory load / sort-state restore) go through `real_set_sort_state`, which blocks the handler, so navigation position-restore is unaffected. The jump is deferred to an idle callback: scrolling synchronously inside the sorter's "changed" emission anchored the view on the OLD position-0 item, which could land at the bottom of the new order (user-reported bottom-jump bug, fixed). Verified scripted: scroll mid-list → Size click (asc) → top; scroll again → Size click (desc) → top. Unconditional (not darwin-gated) |
| DMG | **PASS** | Mounts with `.background/`, `Applications` symlink, and `Shenzhen Files.app`; Finder uses a two-representation TIFF background (600×400 at 72 dpi plus 1200×800 at 144 dpi) for native Retina sharpness instead of scaling the 1x PNG. |
| Bundle relocatability | **PASS** | Launches under `env -i HOME=$HOME …/nautilus-launcher`; `bundle-dylibs.sh` audit: all load commands `@executable_path`/system |

### Performance (regression check vs `docs/perf.md` baseline)

| Metric | Baseline | This build | Δ | Verdict |
|---|---|---|---|---|
| Cold start → window | 481 ms | 509 ms | +5.8% | OK (<20%) |
| Warm start → window | 275 ms | 321 ms | +16.6% | OK (<20%) |
| 10k listing quiesce | 1175 ms | 1320 ms | +12.3% | OK (<20%); still 0.63× Finder (2098 ms) |
| Thumbnail throughput | 0 (stub) | **129 thumbs/s** (500 imgs, real QL backend) | n/a | new capability |

No >20% regression. Snapshot refreshed to the integrated binary
(`bench/snapshot-install/bin/nautilus`, sha `44c619c9…`). New result files in
`bench/results/`. Warm start's +16.6% is within noise for n=5 on a shared
machine; not optimized (out of scope).

---

## Finder Integration (W12) — opt-in, fully revertible

New darwin-only module (`src/nautilus-macos-integration.m`) with a
Settings ▸ **Finder Integration** page, an app-name-menu "Finder
Integration…" item (below "Check Permissions…"), and a one-time first-run
choice dialog. **Everything defaults to OFF; nothing applies at startup**
(startup only registers the passive NSServices provider and reads status).
State keyfile: `~/.config/nautilus/macos-integration.ini` — it records both
what was changed *and* the pre-change system value, so revert restores the
user's original configuration, not a hardcoded default.

| Toggle | Apply | Revert |
|---|---|---|
| **Open Folders by Default** | Saves the current `public.folder` handler bundle id, then `-[NSWorkspace setDefaultApplicationAtURL:toOpenContentType:]` (UTTypeFolder). Errors from recent macOS (parameter/permission refusals were reported on 26.x) surface verbatim in the UI; nothing is recorded as enabled on failure. | Restores the saved previous handler (Finder if none was recorded — the factory state). |
| **Sync Sidebar Favorites** | One-shot two-way sync: Finder favorites (LSSharedFileList, read) → `~/.config/gtk-3.0/bookmarks` (file:// items only), and Nautilus bookmarks → shared favorites (`LSSharedFileListInsertItemURL`; never raw `.sfl3/.sfl4` writes). Records exactly the URIs it added on each side. If the shared-list API is write-broken it degrades to import-only and reports that in the status line. Re-toggle to re-sync (no continuous daemon). | Removes **only** the recorded URIs from both sides; user-created entries (before or after the sync) are never touched. |
| **Hide Finder Desktop** | Reads and saves `com.apple.finder CreateDesktop` (including "key absent"), sets it FALSE via CFPreferences, relaunches Finder (SIGTERM — what `killall Finder` sends). Finder is relaunched *only* on an explicit toggle, never at install/startup. | Restores the saved value (or removes the key if it was absent) + relaunches Finder. |

Plus: **Revert All** button, a live status line (LaunchServices +
CFPreferences reads, not stored state), and a passive `NSServices`
"Open in Nautilus" entry in Info.plist (provider registered at startup;
routes Finder's Services-menu selections through `GApplication::open`).

**First-run choice (DMG installs):** one AdwAlertDialog, once ever
(`integration-choice-made` flag written *before* the dialog is scheduled,
same crash-safe pattern as the FDA prompt): "Use as a Standalone App"
(default, does nothing) vs "Set Up Finder Integration…" (opens the
preferences page; user still flips individual toggles — nothing
auto-applies).

**Test facilities:** `NAUTILUS_INTEGRATION_DRY_RUN=1` logs every system
mutation ("DRY-RUN: …") instead of executing it; keyfile/bookmarks
bookkeeping (inside `$XDG_CONFIG_HOME`) still runs so harnesses can verify
round trips. `NAUTILUS_INTEGRATION_MOCK_FAVORITES=<file>` substitutes a
text file for the shared favorites list. Harness:
`scratch-integration/build-and-run.sh` (26 checks, all passing; read-only
probe on this machine: LSSharedFileList favorites readable, 7 items).

**Known limits (by design / platform):** Finder's "Reveal in …" from other
apps, the Dock's Trash, and system Open/Save panels cannot be replaced —
those are hardwired to Finder. The favorites sync is one-shot, not
continuous. The default-handler write may be refused by recent macOS
policy; the error is shown and nothing is left half-applied.

**LIVE STATE ON THIS MACHINE (applied 2026-07-14, user-requested "do the
swap", via `scratch-integration/integration-cli` — real engine compiled
standalone, no GUI launched):**

- **Favorites sync: ON.** 7 Finder favorites imported into
  `~/.config/gtk-3.0/bookmarks`; 1 bookmark (`file:///Users/raph/Projects`)
  exported to the shared list before the export API errored on a
  symlinked-path bookmark, so the engine degraded to import-only
  (`export-supported=false` recorded). Revert data (imported/exported URI
  lists) is in the keyfile.
- **Default folder handler: FAILED — still `com.apple.finder`.** Both
  `-[NSWorkspace setDefaultApplicationAtURL:toOpenContentType:]`
  (NSCocoaErrorDomain 256, underlying NSOSStatusErrorDomain −50 paramErr)
  and legacy `LSSetDefaultRoleHandlerForContentType` (−50) refuse
  `public.folder` on this macOS (26.x hardwires Finder; no consent dialog
  is ever shown). Not a bundle problem — `org.gnome.Nautilus` IS in
  `LSCopyAllRoleHandlersForContentType("public.folder")`. The keyfile keeps
  `previous-handler=com.apple.finder` but `enabled` stays off; the UI
  surfaces the same error if the user flips the toggle.
- **Hide Finder desktop: ON.** `com.apple.finder CreateDesktop=0`, Finder
  relaunched (pid 695 → 28407). Pre-change state "key absent" recorded
  (`had-previous-value=false`), so revert deletes the key.

Keyfile: `~/.config/nautilus/macos-integration.ini`. Revert per-toggle in
Settings ▸ Finder Integration, Revert All, or
`scratch-integration/integration-cli revert <favorites|desktop|all>`.

---

## "Choose in Nautilus" Save/Open-panel handoff (W13) — PROTOTYPE, opt-in, Accessibility-gated

New darwin-only module (`src/nautilus-macos-savepanel-handoff.m`, bridge
section W13). When another app shows a native NSSavePanel/NSOpenPanel, a
system-wide hotkey lets the user pick a destination folder in Nautilus;
Nautilus then drives that panel to the chosen folder via the Accessibility
API (the panel's built-in "Go to Folder"). **The user still completes
Save/Open in the native panel** — this NAVIGATES the panel only, so the
sandbox/Powerbox security model is untouched (we never read or write the
file on the app's behalf). This is the Accessibility approach from the
multi-model review finding #12; the rejected visual-reskin/overlay idea is
NOT attempted.

**Status: prototype, proven end-to-end against TextEdit's Save panel only.**
Off by default. Two gates must both hold before the hotkey does anything:
the `[savepanel-handoff] enabled` toggle in
`~/.config/nautilus/macos-integration.ini`, and the Accessibility
(`AXIsProcessTrusted`) permission the USER grants in System Settings.

**Architecture**

| Piece | Choice | Notes |
|---|---|---|
| Global hotkey | Carbon `RegisterEventHotKey` (⌃⌥⌘G, hardcoded for the prototype) | Chosen over a CGEventTap: `RegisterEventHotKey` needs no extra permission beyond being a normal app, fires reliably even when another app is frontmost, and is still functional on macOS 26. A CGEventTap would duplicate what the OS hotkey API already does and can be silently disabled by the system. Armed ONLY when the toggle is ON (launch-time `..._init()` reads the keyfile; the prefs switch arms/disarms live). |
| Panel detection | `AXUIElementCreateApplication(frontPid)` → scan `AXWindows` and each window's `AXSheet` children | TextEdit's save panel is a **sheet** (`AXRole=AXSheet`) whose **`AXIdentifier="save-panel"`** (NSOpenPanel → `"open-panel"`). Secondary signature used as a fallback when the panel window carries no identifier: presence of the **`OKButton`** and the **`where popup`** (the "Where:" `AXPopUpButton`). Distinctive save-panel children observed: `saveAsNameTextField`, `where popup`, `NS_OPEN_SAVE_DISCLOSURE_TRIANGLE`, `CancelButton`/`OKButton`, `ContentTypesPopup`. |
| Folder chooser | GTK's `GtkFileDialog` select-folder (prototype) | Returns a POSIX path with the least fragility. The intended real UX is a full Nautilus browsing window whose "Choose" returns the displayed folder — the `GtkFileDialog` is a documented stand-in, not the final design. |
| AX drive sequence | activate target → expand panel (`NS_OPEN_SAVE_DISCLOSURE_TRIANGLE` if collapsed) → open "Go to Folder" (⌘⇧G) → type path → guarded Return | See below. |

**AX drive sequence (the load-bearing part)**

1. `activateWithOptions:` the target app so keystrokes land on its panel.
2. If the panel is collapsed, `AXPress` its disclosure triangle.
3. Post **⌘⇧G** as a proper modifier **chord** (Cmd down → Shift down → G
   down/up → Shift up → Cmd up). A bare G-with-combined-flags shortcut
   leaves the window-server modifier state inconsistent and silently
   swallows the path keystrokes that follow — this was the single biggest
   gotcha found during bring-up.
4. Type the path as **CGEvent unicode-string** keystrokes (chunked; no
   per-key layout dependence). Setting `AXValue` on the field directly
   fills it visually but the panel's completion logic never sees it and
   Return then does nothing — the text must arrive as real key events.
   The Go-to-Folder field (`AXIdentifier="PathTextField"` inside the
   `GoToWindow` sheet) is first responder the instant the sheet opens, so
   we do **not** re-focus it (re-focusing resets the field editor).
5. **Guard:** read the app's `AXFocusedUIElement` and post Return **only**
   if it is the `PathTextField`. This makes it impossible for Return to hit
   the panel's default Save/Open button by mistake.
6. Commit with a Return keystroke.

**End-to-end result (TextEdit, this pass)**

Verified twice — once with a standalone AX prototype, once through the
**compiled bridge** linked into a headless harness
(`scratch-savepanel/test-handoff` → the real
`nautilus_macos_savepanel_drive`). Harness launched TextEdit, opened the
Save panel (Cmd-S on an untitled doc), called the bridge with target
`~/Projects`, and asserted navigation:

```
frontmost-panel-pid=74599
DRIVE OK: Where: popup = "Projects"
== independent AX re-read of Where popup
where-popup: value=Projects
```

Both the bridge's own evidence and an independent AX re-read of the panel's
"Where:" popup report **`Projects`** (was `Documents` before). One proof
screenshot was captured. TextEdit was then closed without saving and the
process killed; `pgrep` confirms nothing left running. Disabled-state
verified: with the toggle OFF, `..._init()` arms nothing (no "armed" log);
only after enabling does the hotkey register.

**USER steps to use it**

1. Install/launch the bundled `Nautilus.app` (Accessibility is checked
   against the *responsible* process — see the dev-vs-bundle caveat below).
2. Grant Accessibility: System Settings ▸ Privacy & Security ▸
   Accessibility ▸ enable **Nautilus**. (Toggling the feature on opens this
   pane automatically if the permission is missing.)
3. Settings ▸ Finder Integration ▸ **Choose in Nautilus (Prototype)** ▸
   turn on **Enable Save/Open Panel Handoff**.
4. In any app, invoke Save/Open so its native panel appears, then press
   **⌃⌥⌘G**. Pick a folder in the Nautilus chooser. The native panel jumps
   to that folder. Finish Save/Open in the native panel as usual.

**Dev-vs-bundle caveat (same shape as the FDA work):** `AXIsProcessTrusted`
and CGEvent posting are attributed to the *responsible process*. A dev
build run from a terminal/IDE inherits the terminal's Accessibility grant,
not "Nautilus"'s; the test harness this pass ran AX-trusted for exactly
that reason. The permission the USER sees and grants is for the
Finder/LaunchServices-launched `.app`. With ad-hoc signing the recorded
identity can change across rebuilds, so macOS may ask for the grant again
after a reinstall.

**Honest fragility assessment (what will break beyond TextEdit)**

- **Sandboxed apps (the common case for App Store apps):** their Save/Open
  panel is hosted out-of-process by
  `com.apple.appkit.xpc.openAndSavePanelService`. The panel is still
  reachable through the *owning* app's AX element in the cases tested, but
  this is NOT validated here — the AX tree shape, the identifiers, and
  whether ⌘⇧G/keystrokes route correctly to a remote-view panel are all
  unproven. **Assume sandboxed apps may not work** until tested.
- **Non-AppKit panels:** Electron/Chromium, Qt, Java, and other toolkits
  draw their own file dialogs that are NOT NSSavePanel and carry none of
  the `save-panel`/`PathTextField`/`where popup` identifiers. The detector
  will simply not find a panel and the hotkey no-ops. iOS-style/Catalyst
  panels are also untested.
- **Sheet vs window panels:** handled for the sheet case (TextEdit) and the
  standalone-window case (detector checks both), but apps that host the
  panel in a nonstandard container may be missed.
- **Timing/races:** the sequence uses fixed `usleep` settle delays
  (activation, disclosure animation, sheet open, keystroke pacing). On a
  slow/loaded machine these can be too short; there is no
  wait-for-condition polling yet. Focus stealers (a notification grabbing
  focus mid-sequence) can also derail it — observed during testing when an
  unrelated app took focus between steps.
- **Localization/layout:** ⌘⇧G is the Go-to-Folder shortcut on English
  systems; a different keyboard layout or a remapped shortcut would break
  step 3. Path typing is unicode-string based so it is layout-independent,
  but the shortcut is not.
- **Permission not granted:** every AX read/write fails closed —
  `nautilus_macos_savepanel_drive` returns an error, the hotkey effectively
  no-ops, and nothing crashes. The prefs toggle detects this and points the
  user at the Accessibility pane.
- **"Go to Folder" quirks:** a nonexistent path leaves the panel where it
  was (the field just won't accept it); the prototype does not pre-validate
  the chosen path (the GTK chooser only returns real folders, so this is
  moot in the hotkey path but relevant if the API is reused).

---

## Finder-like Dock lifecycle (user request, 2026-07-15)

Requirement: "if I close nautilus it stays open in the dock (unless cmd+q),
and when I click on the icon it opens a new window."

**Mechanism (all in existing files; no new sources):**

- **Survive last-window-close:** `nautilus_application_startup` takes one
  `g_application_hold()` on darwin (`macos_lifecycle_take_hold`), so the
  GApplication use count never reaches zero when the last `NautilusWindow`
  is destroyed. The Dock icon stays active, D-Bus services stay up.
- **Explicit quit still quits:** `action_quit` (the `app.quit` GAction —
  reached by the Cmd-Q accelerator, the app-menu Quit item, and Dock ▸
  Quit: GTK's quartz delegate maps `applicationShouldTerminate:` to the
  `quit` action) now releases that hold and zeroes the inactivity timeout
  before closing windows, so the process exits as soon as the last window
  dies — but any in-flight file-operation holds still finish first
  (upstream persistence semantics preserved).
- **Dock-icon click opens a window:** GTK's `GtkApplicationQuartzDelegate`
  does NOT implement `applicationShouldHandleReopen:hasVisibleWindows:`
  (verified against gtk 4.22.4 sources), so the reopen Apple event did
  nothing with zero windows. `nautilus_macos_lifecycle_install_reopen_handler`
  (`nautilus-macos-menu.m`, W1 seam) `class_addMethod`s the missing
  selector onto the installed delegate's class — no swizzling needed since
  nothing is overridden, and it defers to a future GTK implementation if
  one appears. With zero GTK windows it calls `g_application_activate()`
  (Nautilus's activate opens a new window at `$HOME`) and returns NO; with
  windows present it returns YES so AppKit deminiaturizes/raises normally.

**Verified E2E** (`scratch-fonts/verify-lifecycle.sh`, installed bundle):
launch → Cmd-W → window gone + process alive (>14 s, i.e. the hold, not
the 12 s inactivity grace) → `reopen` event opens a fresh window →
Cmd-W again → `quit` Apple event exits. Plus: `open -a Nautilus` reopen
path and the Cmd-Q accelerator path. 12/12 checks pass; `pgrep` clean
after each run.

**Reopen-window placement (follow-up, 2026-07-16):** the window opened by
a Dock-icon click appears CENTERED on the screen the Dock was clicked on.

- *Which screen:* at reopen time the pointer is by definition on the Dock
  icon just clicked, so the target is the `NSScreen` whose frame contains
  `[NSEvent mouseLocation]` (`macos_mouse_screen_visible_frame`, captured
  BEFORE `g_application_activate()` so later focus changes can't skew it).
  Single-display setups degrade to "center on the only screen"; the
  multi-display case is the same code path (mouse↔screen matching).
- *How it moves:* GTK4 has no `gtk_window_move`, so positioning is done at
  the AppKit level. NSWindow timing: GDK creates/places the NSWindow
  during realize/present, so the handler hooks the new `GtkWindow`'s
  `map` signal (one-shot, destroy-notify guards the never-mapped leak
  case) and then defers the actual move by ONE GLib idle — after GDK's
  own cascade placement (`_gdk_macos_display_position_toplevel`) has
  finished, with no fixed sleeps. The idle fetches the `NSWindow` via the
  public `gdk_macos_surface_get_native_window()` and `setFrameOrigin:`s
  it centered in the target screen's `visibleFrame` (menu bar/Dock insets
  respected). GDK observes the move via `windowDidMove:` →
  `_gdk_macos_surface_configure`, so its coordinate bookkeeping stays
  consistent. Only the reopen-with-no-windows path does this (`open -a`
  with the app running lands on the same reopen event); normal window
  placement is untouched.
- *Verified E2E* (`scratch-fonts/verify-center.sh`, installed bundle, real
  two-display setup): close last window → warp mouse to the external
  display (3440×1440 at CG −1928,−1440) → `reopen` event → window center
  (−208,−704.5) vs screen visibleFrame center (−208,−720): Δx=0,
  Δy=15.5 px (Dock had migrated displays with the pointer, shifting the
  comparison snapshot's inset — the app centered exactly on the
  visibleFrame it saw). Repeat on the built-in display (1800×1169):
  Δx=0.0, Δy=0.0. Quit event exits; `pgrep` clean.

**Cold-launch placement (follow-up, 2026-07-16):** user report: "cold
launch opens the window on a different screen; afterwards it is ok." The
reopen-path centering only armed on the reopen Apple event; a FRESH
process's first window was placed by GDK itself, and GDK picks the wrong
monitor on multi-display setups: `_gdk_macos_display_position_toplevel`
(gdkmacosdisplay-wm.c, gtk 4.22.4) feeds raw AppKit bottom-left-origin
`[NSEvent mouseLocation]` into
`_gdk_macos_display_get_monitor_at_display_coords()`, which expects GDK
top-left display coords — the y axis is flipped, so the lookup lands on
the wrong screen whenever displays are stacked/offset vertically.

- Fix: same placement rule, same machinery, armed for the first window.
  `nautilus_macos_launch_placement_capture()` (W1 seam) snapshots the
  mouse screen's visibleFrame at the TOP of `nautilus_application_startup`
  — before GTK startup takes its time, so a moving pointer can't skew the
  target — and `nautilus_macos_launch_placement_apply()` in
  `nautilus_application_create_window` arms the shared map+idle centering
  for that window. One-shot per process: later windows (Cmd-N, tabs,
  session paths) keep normal placement; the reopen path keeps its own
  fresh capture. Position only — maximized/fullscreen windows are left
  untouched (guard in the centering idle). File-open launches (`open`
  with a path / Services) funnel through the same `create_window`, so
  they center too.
- *Verified E2E* (`scratch-fonts/verify-coldlaunch.sh`, installed bundle,
  two displays, low-disruption `open -g` — placement logic runs without
  activating/stealing focus): mouse on external display → cold launch →
  window center (−208,−719.5) vs visibleFrame center (−208,−720):
  Δ 0/0.5 px; mouse on built-in display → Δ 0.0/0.0 px; file-open cold
  launch (`open -g -a Nautilus ~/Downloads`, external display) →
  Δ 15/29.5 px (GDK cascade offset absorbed within tolerance, correct
  screen). All sessions quit cleanly; `pgrep` clean.

**Placement flash fix (follow-up, 2026-07-16 pm):** user report: the
window briefly (~50 ms) appeared at GDK's wrong-screen position before
jumping to the centered one. Root cause: the centering ran one GLib idle
after `map`, but GDK's delayed orderFront (first buffer swap) wins that
race. Fix: the move is now SYNCHRONOUS in the `map` handler — at that
point GtkWindow.map's class closure has already run `gdk_toplevel_present`
(NSWindow exists at final size, GDK placement applied) but the NSWindow is
only ordered front at the FIRST BUFFER SWAP (`show_on_next_swap`,
gdkmacossurface.c), which happens later in the frame cycle. The reopen
path additionally arms via a one-shot `GtkApplication::window-added`
handler BEFORE `g_application_activate()` (activation paints the window
before returning, so post-activate arming was itself too late). Evidence:
the placement debug line logs `[nswindow isVisible]` at move time —
`was visible before move: no` on BOTH paths on the installed bundle
(cold launch Δ 0/0 px built-in; reopen Δ 0/15.5 px external), i.e. the
first frame the user ever sees is the centered one. No transparency
tricks needed; windows never start hidden.

---

## Font rendering root cause (user report: "like they are not antialiased")

**What it is NOT (each empirically excluded, `scratch-fonts/`):**

- *Wrong Pango backend* — `pango_cairo_font_map_get_default()` is
  `PangoCairoCoreTextFontMap`; `.AppleSystemUIFont 12` loads as a
  `PangoCairoCoreTextFont` (real SF Pro; string widths match native AppKit
  rendering to 0.4%).
- *Missing antialiasing* — glyphs are grayscale-antialiased (GTK requests
  `CAIRO_ANTIALIAS_GRAY`; intermediate alpha levels present in captures).
- *Scale/resolution bug* — 1 px hairlines render pixel-sharp at 1x and 2x;
  no resampling blur anywhere.
- *GSK renderer* — ngl (default) and cairo renderers produce pixel-identical
  text (same lit/solid counts on the same glyph runs).
- *xft settings* — `gtk-font-rendering` defaults to AUTOMATIC, which
  ignores the `gtk-xft-*` keys entirely; a manual-mode experiment with
  metric hinting made spacing worse (integer-rounded advances), not better.

**What it IS (two compounding causes):**

1. **12 pt vs the native 13 pt.** GDK's macOS settings backend hardcodes
   the system font as `"<family> 12"` (the AppKit "views" size, with a
   source comment admitting it may need tweaking); real macOS UI text
   (Finder sidebar/lists) is 13 pt. Every label rendered one point smaller
   than the OS look.
2. **CoreText font smoothing (stem darkening) is off.** cairo's quartz
   glyph rasterizer calls `CGContextSetShouldSmoothFonts(FALSE)` for
   `CAIRO_ANTIALIAS_GRAY` — smoothing is only enabled for
   `CAIRO_ANTIALIAS_SUBPIXEL`, which GTK never requests (GSK doesn't do
   subpixel AA). AppKit text gets stem darkening; GTK text does not, so SF
   Pro renders visibly thinner/wispier — on a non-Retina display it reads
   as "not antialiased". This cannot be turned on app-wide through public
   GTK API (per-widget `gtk_widget_set_font_options` doesn't inherit).

**Fix shipped (darwin-gated, `macos_setup_font_rendering()` in
`nautilus-application.c` startup):**

- `gtk-font-name = ".AppleSystemUIFont 13"` set **programmatically** —
  required, because an application-set GtkSettings value outranks the GDK
  backend xsetting while a bundled `settings.ini` loses to it (verified:
  an ini override changed nothing; `g_object_set` works).
- Default text weight Medium (500) via a `window { font-weight: 500; }`
  CSS provider, as weight compensation for the missing stem darkening.
  Set on the window node so it *inherits*; theme rules that set
  font-weight directly (headings, `.title-*`, bold labels) still override
  inherited values, so bold stays bold.

**Result** (1x display, where the problem is worst): "Starred" sidebar
label ink 167 lit / 73 solid px → 230 lit / 109 solid px; native Finder
equivalent ≈ same-size text with comparable solidity. Visual strip:
`scratch-fonts/evidence_before_after.png` (before / after / Finder).
Retina rendering was already acceptable and simply scales up. Remaining
gap vs AppKit (true stem darkening) is a GTK/cairo stack limitation,
documented above.

---

## macOS window chrome — Finder-style traffic lights (2026-07-16)

User request: "make the app a bit more mac os like" (mockup: traffic
lights top-left above the sidebar, toolbar spanning only the content
area). Changes:

- **Window controls moved to the sidebar header, top-left.** The sidebar
  `AdwHeaderBar` (in `nautilus-window.blp`) now hosts ONLY the window
  controls (`show-title: false`, `.flat`); `gtk-decoration-layout` is set
  to `close,minimize,maximize:` at startup (`macos_setup_window_chrome()`
  in `nautilus-application.c`), which also puts dialog buttons on the
  left, per platform convention.
- **Main menu + "Search Everywhere" moved into the content toolbar** as
  new `NautilusToolbar` end children (hamburger rightmost), behind new
  properties `show-app-menu-button` / `show-global-search-button` /
  `app-menu-model` (all off/NULL by default so the file chooser's toolbar
  is unaffected). Since 2026-10-13 that search button searches the current
  folder instead, behind `show-end-search-button`; see "Toolbar search
  button searches the current folder (2026-10-13)".
- **Traffic-light styling (CSS provider, darwin startup):** still
  GTK-drawn (`use-native-controls` stays FALSE — the GTK #7964 deadlock
  was re-checked against GTK 4.22.4 release notes; upstream !9354 landed
  but the hang persisted in the previous pass, so no native re-enable).
  Metrics were measured off a native window at 1x: **14 px circle
  (12 px + 1 px ring), 23 px center-to-center, 13 px edge inset** —
  verified pixel-exact at 1x and 2x by screenshot measurement
  (`scratch-fonts/measure-lights.swift`). Colors #ff5f57/#febc2e/#28c840,
  glyphs only on cluster hover, neutral gray on `:backdrop` (matches
  native unfocused windows). **The circle must stay on the button's inner
  image node** — styling the button node stretches with the headerbar and
  distorts the circles into tall ellipses (regression caught and reverted
  during this pass).
- **Collapsed/narrow fallback:** the `max-width: 682sp` breakpoint keeps
  working — at 600 px the sidebar becomes an overlay and the controls stay
  in its header (screenshot-verified); with the sidebar hidden libadwaita's
  split-header coordination recreates the controls in the content header
  (this is the same recreate path the existing
  `macos_split_view_controls_notify_cb` hook already re-disables native
  controls on, so they stay GTK-drawn there too). Eyes-on item added to
  the QA checklist below.
- **Click behavior verified scripted** (window-server clicks on the
  GTK-drawn buttons, dev build): green zoom → window zoomed to full
  screen-frame and back; yellow → miniaturized; red → window closed,
  process stayed alive (Dock lifecycle hold) and exited within 1 s of
  SIGTERM — **main loop not wedged**, i.e. the GTK-drawn buttons do not
  reproduce the native-controls deadlock.
- Not attempted: NSVisualEffectView vibrancy (future polish, fragile).

---

## Finder-style slow second click renames (2026-07-22)

User request: "Add the second slow click to rename files like in the Finder."
Click a file once to select it; a second, separate primary click on the
file's NAME LABEL (not the icon) that lands after the double-click interval
opens the inline rename popover — exactly Finder's rename gesture. A fast
second click is still a double-click (opens). Darwin-gated throughout.

- **Hook points:** the cells attach a non-claiming `GtkGestureClick`
  (primary button, bubble phase) to their name label —
  `setup_cell_slow_click_rename()` in `nautilus-list-base.c`, called from
  `nautilus_name_cell_init` (list view; `label` template child newly bound)
  and `nautilus_grid_cell_init` (grid view). All state + logic live in
  `NautilusListBase` (private struct), so both views share one
  implementation and at most one pending trigger exists per view.
- **Arming rules:** press must be a single (n_press==1) unmodified primary
  click on the name label of an item that was ALREADY the single selected
  item BEFORE the press (checked at press time, before GtkListBase mutates
  selection — so the click that selects never arms, and multi-selection
  never arms); a clean release then re-verifies the selection and arms a
  one-shot timeout. The timeout re-verifies (same model, item still the
  single selection) and activates the existing `view.rename` GAction — the
  same action as F2, so popover, validation, and batch/single dispatch are
  identical.
- **Cancel rules:** the pending trigger is cancelled by any further press
  anywhere in the view (item or background — a double-click's second press
  lands here, so double-click always wins), any keypress (capture-phase key
  controller), any selection change (model `selection-changed`), any scroll
  (h/v adjustment `value-changed`), navigation (`setup_directory`), and
  view dispose. A drag never arms: the click gesture is cancelled before
  release, and the press-time candidate flag is dropped in `stopped`.
  Right/middle clicks never reach the gesture (primary-only); Ctrl/Shift/
  Alt/Cmd-modified clicks are disqualified at press; single-click-to-open
  mode disables the whole feature.
- **Timing source:** the system double-click interval — the
  `com.apple.mouse.doubleClickThreshold` preference backing NSEvent's
  `doubleClickInterval` (0.5 s AppKit fallback, clamped 0.15–2 s), read via
  CFPreferences. GDK's macOS backend does NOT map it into
  `gtk-double-click-time` (checked GTK 4.22.4: no `doubleClickInterval`
  anywhere), so on first use it is synced INTO `GtkSettings
  gtk-double-click-time` — GTK's own double-click (open) detection and the
  rename delay now share one clock that matches the user's system setting.
  Rename fires at gtk-double-click-time + 100 ms margin after the release.
- **Verified (scripted GUI session, `scratch-rename/verify-slowrename.sh`,
  15/15 checks):** window located via CGWindowList, name labels located by
  OCR of a window screenshot (GTK's macOS AX tree exposes only the window,
  not the labels), guarded window-server clicks, assertions on the
  `slow-rename:` g_debug lines and on-disk results. List view: selecting
  click doesn't arm; slow second click armed (delay 600 ms = synced 500 ms
  + margin) and fired; typed replacement committed → `zzz.txt` (base name
  was preselected, extension kept). Double-click on a selected folder:
  pending trigger cancelled by the second press, folder opened, no rename.
  Grid view: same arm/fire pass on `inner-file.txt`, Esc closes popover
  without renaming, second pass commits `yyy.txt`; click on the ICON of the
  selected grid item does not arm. Session quit via Cmd-Q, `pgrep` clean.

---

## What's degraded / limitations

- **Trash browsing:** the sidebar Trash item opens Finder's Trash (no
  `trash:///` GVfs backend; `~/.Trash` is TCC-blocked without FDA). Trashing
  files works.
- **Network view:** hidden on darwin (no GVfs).
- **Window buttons are GTK-drawn, not native traffic lights:** deliberate
  workaround for GTK #7964 — on macOS 26.5 a click on the native AppKit
  buttons wedges the main thread in `NSButtonCell trackMouse` (app left
  running with no window, unable to relaunch). Native controls are force-
  disabled per window in `nautilus-application.c`; revisit when GTK fixes
  the hit-test (still broken on GTK 4.22.4 — upstream !9354 shipped but
  does not cure it, so native controls were NOT re-enabled in the
  2026-07-16 chrome pass; the traffic lights are CSS-styled GTK controls,
  see the "macOS window chrome" section). See `docs/phase6-known-issues.md` #4.
- **No NSVisualEffectView translucency/vibrancy** behind the sidebar —
  deliberately not attempted (fragile with GTK-rendered surfaces); possible
  future polish.
- **Stateful menu checkmarks:** Show Hidden / sort radios work but show no
  checkmark in the native menu (GTK quartz limitation). See
  `docs/phase6-known-issues.md` #5.
- **One GTK critical per window** on launch (harmless; issue #1).
- **Set-as-default in Open With:** hidden on darwin — `GOsxAppInfo` cannot
  change the LaunchServices default handler.
- **Early-SIGTERM segfault:** could **not** be reproduced (22/22 clean TERM
  exits); documented as a watch item in `docs/phase6-known-issues.md` #2.
  (Note: the user-reported "quit unexpectedly" dialogs turned out to be a
  different, now-fixed startup crash — see issue #6, not this one.)
- **Packages as single items: what is left** (2026-10-13): opening, the
  context menu, Paste Into Folder, the sidebar, drag and drop, the list
  view's expanders and "folders first" treat apps and other packages as
  single items (see "Follow-ups to the three fixes" below). Typing an app's
  path in the location entry still browses into it (Finder selects it in
  its folder). Files dropped onto an app open only when the app declares it
  opens all of them, as in Finder, but Finder's Option-Command override,
  which hands an app any file, is not available.
- **Extracting needs a UTF-8 locale:** libarchive converts entry names to
  the locale's character set, so in the "C" locale every archive with a
  non-ASCII name fails ("Pathname can't be converted from UTF-8 to current
  locale"). The bundle's launcher sets `LANG=en_US.UTF-8` when it is unset,
  so the app is fine; a dev binary started without `LANG` is not.
- **Disc images are not offered Extract:** autoar does not list ISO images
  (on GNOME either); they open with DiskImageMounter.

---

## Human-QA checklist (consolidated — items no agent could verify)

These need real eyes/hands: AX cannot see AdwDialog internals, cross-process
drags are TCC-blocked for automation, and some flows need a real bundle
install. Run the **bundle** (`dist/Nautilus.app`) where noted.

### A. Menu bar & shortcuts (W1 — solo QA)

- [ ] **Cmd-Shift-W** (Close Window) key equivalent — menu click verified;
      key combo unverified under automation.
- [ ] Cmd-, (Preferences dialog opens), Cmd-T (new tab), Cmd-F (search
      focus), Cmd-R (reload), Get Info (Cmd-I), Cmd-1/Cmd-2 (icon/list view
      switch), Enter Location (Cmd-Shift-G / Cmd-L popover) — all actions
      registered; AX-invisible dialogs/popovers need eyes-on.
- [ ] Cmd-Z / Cmd-Shift-Z inside a rename/location text entry keeps GtkText
      undo (not file undo).

### B. Selection actions (W2 — GUI items)

- [ ] Double-click opens a file with the LaunchServices default app.
- [ ] Right-click → Open With shows real app icons (now bridged) and opens
      the chosen app.
- [ ] "Show in Finder" reveals the selection in Finder.
- [ ] Sidebar Trash opens Finder's Trash window.
- [ ] Space-bar QuickLook toggles the panel; arrow keys page selection
      (detailed steps in L).
- [ ] Get Info / Properties dialog populates.
- [ ] Star / unstar a file, restart, confirm the star persists (tag DB).
- [ ] **Slow-click rename feel** (2026-07-22): select a file, then click its
      name once — after ~0.6 s the rename popover opens with the base name
      preselected; a normal double-click must still open. Try list + grid,
      and check a click-then-drag does NOT pop the rename afterward.
      (All script-verified; this item is about the interaction feel.)

### C. Finder drag & drop (W5 — real-drag checklist)

Full matrix in `docs/phase3-w5-qa-checklist.md`. Byte-level behavior is
proven; the actual inter-app drags are not. Priorities:

- [ ] **Drag OUT single file** to Finder Desktop — copied, name intact
      (incl. spaces / `%` / `#`).
- [ ] **Drag OUT multiple files** — all copied (legacy `NSFilenamesPboardType`
      augmentation; most-likely-to-regress case).
- [ ] **Drag IN single/multiple** from Finder onto the view — copied with
      correct names (URI-repair path; 2.1/2.5 in the W5 checklist).
- [ ] Drag IN onto a folder item, sidebar place, path-bar crumb.
- [ ] In-app drags (view→subfolder, →sidebar, →tab) still move/copy correctly.

### D. Paste from Finder (integration item — new)

- [ ] Copy files in **Finder** (Cmd-C), focus Nautilus, **Cmd-V** — files
      land in the current folder with correct names (composes the darwin
      `paste_files` fallback with W5's `text/uri-list` deserializer).
- [ ] In-app copy/paste still works (fast local path unchanged).

### E. FDA flow (restart-after-grant)

- [ ] Bundle first launch shows the "Grant Full Disk Access" prompt
      (verified via screenshot; confirm the full flow by hand).
- [ ] "Open System Settings…" deep-links to Privacy & Security → Full Disk
      Access.
- [ ] Enable Nautilus there, **quit and relaunch**, confirm the prompt no
      longer appears and Trash/Desktop/Documents are readable.
- [ ] "Don't Ask Again" persists (`~/.config/nautilus/macos-fda.ini`);
      Help → "Grant Full Disk Access…" still reopens the dialog afterward.

### F. File-type icons & Open in Terminal (W11 — GUI items)

- [ ] Browse a folder containing a `.kicad_pro` file (e.g.
      `/tmp/icons-test`) — the file shows the **KiCad document icon** (grid
      and list view), not the generic blank-file icon.
- [ ] A file with a made-up extension (`.qwoiejqwe`) shows the native macOS
      generic document icon (white page) instead of the flat themed one.
- [ ] Plain `.txt` / `.zip` files keep their themed icons; images/PDFs keep
      QuickLook thumbnails (no regression from the icon fallback).
- [ ] **Icon scaling at all zoom levels (regression QA for the oversized
      `.drawio` icon bug):** on a Retina display, view a `.drawio` (or other
      LaunchServices-icon) file in grid view and step through every zoom
      level (Cmd-minus/Cmd-plus, 48→256 pt) and list view sizes — the icon
      must stay inside its cell, same footprint as themed icons/thumbnails,
      label below (never overlapping). Verified headless for scale 1 and 2
      (`scratch-fileicon/test-fileicon` sections 5–6); eyes-on GUI pass
      still wanted.
- [ ] Scroll a large directory (~10k files) — no per-row stutter (icons are
      cached per extension+size).
- [ ] Right-click the view **background** → "Open in Terminal" opens
      Terminal.app cd'd at the current folder.
- [ ] Right-click a **single selected folder** → "Open in Terminal" opens
      Terminal.app cd'd at that folder; item hidden for files/multi-selection
      and for non-local locations.

### G2. "Choose in Nautilus" Save/Open-panel handoff (W13 — prototype, eyes-on)

Automated E2E against TextEdit passed (see the W13 section); these need a
real bundle + the user's Accessibility grant, which no agent can supply:

- [ ] Launch the **bundle**, grant Accessibility (Settings ▸ Privacy &
      Security ▸ Accessibility ▸ Nautilus), then Settings ▸ Finder
      Integration ▸ enable **Save/Open Panel Handoff**.
- [ ] In **TextEdit**: new doc → Cmd-S → press **⌃⌥⌘G** → pick a folder in
      the Nautilus chooser → confirm the native Save panel now shows that
      folder. Finish the save in the native panel; the file lands there.
- [ ] Repeat with an **Open** panel (e.g. TextEdit → Cmd-O) — folder
      navigation should work the same.
- [ ] With the toggle **OFF**, ⌃⌥⌘G does nothing (hotkey not armed).
- [ ] With Accessibility **not** granted, enabling the toggle opens the
      Accessibility pane and the hotkey no-ops (no crash) until granted.
- [ ] Try a **sandboxed** app's Save panel (e.g. a Mac App Store app,
      Preview, or Pages) — EXPECTED TO BE FRAGILE/UNPROVEN; record whether
      it works, partially works, or does nothing.
- [ ] Try a **non-AppKit** app (VS Code / any Electron app, a Qt/Java app) —
      EXPECTED: detector finds no panel, hotkey no-ops. Confirm it fails
      gracefully.

### H. Dock lifecycle & font rendering (2026-07-15 fixes — eyes-on)

- [ ] Close the last window with the **red close button** (not Cmd-W) —
      app stays in the Dock; click the Dock icon — a new window opens at
      Home. (Cmd-W, `reopen`/`open -a`, Cmd-Q, and the quit Apple event
      are already script-verified.)
- [ ] With two displays: close the last window, click the Dock icon on
      the OTHER display — the new window opens centered on that display
      (script-verified via mouse-warp + reopen event on both displays;
      confirm with a real Dock click).
- [ ] With two displays and Nautilus NOT running: click the Dock icon —
      the first window opens centered on the display the Dock was clicked
      on (cold-launch path; script-verified on both displays, confirm
      with a real Dock click).
- [ ] Preferences ▸ General ▸ Starting Folder: pick a folder — quit,
      relaunch from the Dock: the window opens there; Cmd-N opens there
      too. Reset button restores Home. Delete the chosen folder on disk,
      relaunch — opens Home (fallback, script-verified).
- [ ] Right-click the Dock icon ▸ Quit — app quits (script-verified via
      the quit Apple event; confirm the actual menu click).
- [ ] Cmd-Q while a large copy is in progress — the windows close and the
      app finishes the operation before exiting (operation holds are
      honored).
- [ ] Text everywhere (sidebar, list view, dialogs, menus) reads at
      Finder-like size/weight; nothing looks fake-bold. Check that real
      bold text (dialog headings, `.title` labels) is still visibly
      bolder than body text.
- [ ] Check on both the Retina laptop panel and the 1x ultrawide; the 1x
      display was where the old thin/fuzzy rendering was most visible.

### I. macOS window chrome (2026-07-16 — eyes-on)

- [ ] Traffic lights (top-left, in the sidebar header) look native: same
      size/spacing as a Finder window next to it, crisp circles on the 1x
      ultrawide, red/yellow/green when focused, all gray when the window
      is unfocused, glyphs appear when hovering the cluster.
- [ ] Click each: red closes the window (app stays in Dock), yellow
      minimizes, green zooms/restores (script-verified via synthetic
      clicks; confirm by hand — this is the GTK #7964-sensitive path,
      buttons must never freeze the app).
- [ ] Narrow the window below ~680 px: the sidebar collapses to an
      overlay; with the overlay dismissed the traffic lights must appear
      in the main toolbar (left of back/forward) and keep working.
- [ ] Hamburger menu (top-right of the toolbar) opens the main menu. The
      magnifier next to it searches the current folder (checklist O; it
      started Search Everywhere before 2026-10-13).
- [ ] Dialogs (Preferences, Properties, About) show their window buttons
      on the LEFT (mac convention) and styled as traffic lights.

### J. Volume hot-plug (2026-10-13 — eyes-on)

The shared monitor is covered by `tools/test-macos-volumes.sh`; the sidebar
rows themselves need a display, so check them by hand on a build from this
branch.

- [ ] With two windows open, plug in a USB disk (or double-click a `.dmg`):
      it appears under the mounts section of both sidebars within a second,
      once each.
- [ ] Rename it in Finder: both sidebars show the new name.
- [ ] Eject it from Finder, then mount it again and eject it with the
      sidebar's eject button while one tab is inside it: the tab moves to
      Home, the row disappears from both windows.
- [ ] Connect to a server (Finder, Cmd-K) and disconnect: the network
      volume comes and goes in both sidebars.

### K. Apps, packages and archives (2026-10-13 — eyes-on)

`tools/test-macos-apps-archives.sh` covers the decisions, the NSWorkspace
launch and extraction; the menus and dialogs need a display. On a build from
this branch:

- [ ] In `/Applications`, double-click an app (e.g. Calculator), then select
      it and press Enter, then Cmd-O: it launches each time and the window
      stays in `/Applications`.
- [ ] Select two apps and press Enter: both launch.
- [ ] Right-click an app: the menu starts with Open, then Show Package
      Contents; there is no Open With… and no Open in New Tab. Show Package
      Contents shows `Contents` in the same tab; Back returns.
- [ ] Right-click a document package (TextEdit: Format ▸ Make Rich Text,
      add an image, save as `.rtfd`): Open opens it in TextEdit, Show
      Package Contents browses it.
- [ ] Search for an app (Cmd-F) and double-click the result; star an app
      and open it from Starred: it launches.
- [ ] Drag an app into the sidebar's bookmarks and click it: it launches;
      right-click ▸ Open in New Tab shows its contents.
- [ ] Make an empty folder named `Broken.app` and double-click it: one
      dialog, "Unable to open “Broken.app”", with macOS's explanation, and
      no second alert from macOS.
- [ ] Download an app you have never opened (quarantined) and double-click
      it: macOS's "downloaded from the Internet" prompt appears; Cancel shows
      nothing more, Open launches it.
- [ ] Right-click a `.zip`, a `.tar.gz` and a `.7z`: Extract and Extract to…
      are there, under Open With Archive Utility, and Compress… is further
      down. Extract creates the folder next to the archive; Extract to… asks
      for a folder. In a read-only folder (a mounted DMG) only Extract to…
      is offered. The File menu has Compress…, Extract and Extract to…,
      greyed out when they do not apply.
- [ ] Double-click a `.zip`: it still opens in Archive Utility.
- [ ] Right-click an app: no Extract.
- [ ] Drag a file from the desktop over an app in the Files window, in grid
      view and then in list view, and hold it still for two seconds: the app
      does not launch and the window stays where it is. Hold it over a
      folder instead: the folder opens. (Dropping onto apps: checklist N.)

### L. Quick Look keyboard focus (2026-10-13 — eyes-on)

The focus controller is covered by `tools/test-macos-quicklook.sh`; the real
panel needs a display. Use a build from this branch and a folder with a few
images and a PDF.

- [ ] Select an image and press space: the panel opens and the Files window
      keeps its colored traffic lights (it is still the active window).
- [ ] Press space again: the panel closes. Type the first letters of another
      file's name: that file is selected.
- [ ] Press space, then the arrow keys: the selection moves in the file view
      (by row in grid view) and the panel shows each file. Press Escape: the
      panel closes and the last file shown is selected.
- [ ] Press Cmd-Y: the panel opens; Cmd-Y again closes it. File ▸ Quick Look
      shows ⌘Y.
- [ ] Select two files and press space: Left/Right page between them inside
      the panel; space closes it.
- [ ] Press space, click inside the panel (it becomes the active window),
      press space: the panel closes, the Files window is active again, and
      typing a name selects that file.
- [ ] Repeat the previous step closing with Escape, with Cmd-W, and with the
      panel's close button: the same each time.
- [ ] Press space, click inside the panel, press Down: the selection moves
      and the panel follows. Press Return: the Files window becomes active and
      opens the file, as Return does there.
- [ ] With the panel open, click another file in the Files window: the panel
      shows it and stays above the window; space closes it.
- [ ] With the panel open, click the empty background so nothing is
      selected: space and Escape still close the panel.
- [ ] Press space, click inside the panel, switch to another app and back,
      press space: the panel closes and the Files window is active.

### M. The three fixes together (2026-10-13 — eyes-on)

On a build of `files-fixes`, after K and L:

- [ ] Select an app and press space: Quick Look shows it and the Files window
      stays active. Press space again: the panel closes. Press Enter: the app
      launches.
- [ ] Select a `.zip`, press space, then space again: the panel closes.
      Right-click the zip: Extract and Extract to… are there.
- [ ] Open the File menu: Get Info, Rename… and Quick Look (⌘Y), then
      Compress…, Extract and Extract to… in their own group.
- [ ] With the Quick Look panel open, attach a disk image (double-click a
      `.dmg` in Finder): the volume appears in the sidebar at once, and space
      still closes the panel.

### N. Follow-ups: ejecting together, drops onto apps, list view (2026-10-13 — eyes-on)

`tools/test-macos-volumes.sh` and `tools/test-macos-apps-archives.sh` cover
the volume list, the drop decisions, opening dropped files in a throwaway
app, the expanders and the sort order; the rows, highlights and dialogs need
a display. On a build of `files-fixes`, with two windows open:

- [ ] Eject a disk with two partitions (or select two mounted disk images in
      Finder and eject both): both rows leave both sidebars, and no
      "Macintosh HD" row appears for a moment.
- [ ] Connect to a server share whose name has an accented or Korean
      character (Finder ▸ Go ▸ Connect to Server, e.g. a NAS share named
      "Données"): it appears once in both sidebars, and leaves both when
      you disconnect it.
- [ ] Drag TextEdit and Calculator into the sidebar's bookmarks. Move a
      `.txt` file from the desktop slowly up and down across both rows a few
      times: TextEdit is highlighted whenever the file is over it,
      Calculator never is. Press Escape.
- [ ] In `/Applications`, drag a `.txt` file from the desktop onto TextEdit,
      in grid view and then in list view: TextEdit is highlighted, and on
      release it opens the file. The file is still on the desktop, and Show
      Package Contents on TextEdit shows nothing new in it.
- [ ] Drag two images from Finder onto Preview in the Files window: Preview
      opens both, and they stay where they were in Finder.
- [ ] Drag a `.txt` file over Calculator: Calculator is not highlighted (it
      opens no documents). Press Escape.
- [ ] Drag a file over an `.rtfd` document: it is not highlighted. Press
      Escape.
- [ ] Drag TextEdit into the sidebar's bookmarks. Drop a `.txt` file onto
      that bookmark: TextEdit opens it. Drag another file over the bookmark
      and hold it still for two seconds: the window stays where it is.
      Hold it over a folder's bookmark instead: the folder opens.
- [ ] Drop a file onto an app downloaded from the internet that has never
      been opened: macOS asks first; Cancel shows nothing more.
- [ ] In a copy of an app you can throw away, use Show Package Contents and
      drop a file onto the empty background of the window: it is copied
      inside, as Finder does in a package window.
- [ ] Turn on Preferences ▸ Expandable Folders in List View and switch to
      the list view: apps and `.rtfd` documents have no expander; folders
      do.
- [ ] With Preferences ▸ Sort Folders Before Files on, sort
      `/Applications` by name: the folders (e.g. Utilities) come first, then
      the apps in name order.

### O. Toolbar search button (2026-10-13 — eyes-on)

`tools/test-macos-search-button.sh` checks the button's wiring in the UI the
app loads and the folder search it opens; the button itself needs a
display. On a build of `fix-search-scope`:

- [ ] Hover the magnifier at the right of the toolbar: the tooltip says
      "Search Current Folder". There is no second search button next to the
      path bar.
- [ ] In a folder with subfolders, click the magnifier: the search field
      replaces the path bar, says "Search current folder" and has the
      keyboard; the magnifier looks pressed. Type a name that only exists
      in a subfolder: it is found. Nothing outside the folder is listed.
- [ ] With two tabs open, start the search in one: the other tab is not
      searching. Switch back and forth: the magnifier looks pressed only on
      the searching tab.
- [ ] Click the magnifier again: the search closes and the folder is shown
      as before, with the file you selected in the results still selected.
- [ ] Press Cmd-F: the same search opens as with the magnifier. Press Cmd-F
      again while it is open: the text is selected, the search stays open.
- [ ] Find ▸ Search Everywhere (⇧⌘F) searches everywhere; while it is open
      the magnifier is not shown (Escape closes the search). Close it: the
      magnifier is back, not pressed.
- [ ] Search a folder for a name that is not there: "No Results Found"
      offers Search Everywhere, which searches everywhere.
- [ ] In Starred, click the magnifier and type: the list is narrowed to the
      matching starred items; nothing from elsewhere is added.
- [ ] VoiceOver (Cmd-F5) reads the magnifier as "Search Current Folder,
      toggle button".

### P. Shenzhen Friends in Files (2026-10-13, wave 6b — eyes-on)

`tools/test-friends-adapter.sh` covers the adapter's decisions without the
app; these need the real app. Use a copy of a `friends-host` build, never the
installed app, and ShenzhenPDF closed unless an item says otherwise.

- [ ] Launch with Friends on (the default): every window shows the
      two-people button right of the traffic lights, at the end of the
      sidebar's header bar, just before the main view, once the window has
      appeared (wave 6d). A new window (Cmd-N) has one too. Narrow the
      window below the breakpoint: the button moves to the start of the
      main header bar, right after the traffic lights and the sidebar
      toggle. Show the sidebar there: the button goes into the sidebar's
      bar with the traffic lights; hide it or widen the window: it moves
      back. Never two buttons. Open the Friends popover and narrow or widen
      the window across the breakpoint: the popover follows the button or
      closes, and never stays pointing at an empty place. A badge and a
      drop on the button work in both places.
- [ ] With Friends on, in every one of those places, the magnifier is
      still the last button before the main menu at the right of the main
      bar, and it searches the current folder as in checklist O (wave 6e).
- [ ] Preferences ▸ Friends: "Enable Shenzhen Friends" is on, with the
      disclosure under it and Friends' own settings below. Turn it off: the
      button leaves every window at once and the settings below go. Turn it
      on: the buttons come back.
- [ ] With Preferences ▸ Friends open, turn on System Settings ▸
      Accessibility ▸ Display ▸ Increase Contrast: the disclosure under the
      switch turns darker (lighter in dark mode), as the group's
      description above it does; turn it off: both go back (wave 6e).
- [ ] Quit with Friends off, relaunch: Activity Monitor shows no
      "Shenzhen Friends" process started by Files.
- [ ] Drop a file from Finder onto the Friends button: the file arrives
      under its own name.
- [ ] In a conversation, `#` lists the selected files first ("Selected
      in …"), then this folder's files newest first, never a folder or a
      symbolic link (make one with `ln -s` in Terminal: it is not listed,
      even when selected); "Show in Shenzhen Files" on a received file opens
      its folder with the file selected, in the window already showing
      that folder.

### Q. Backspace goes back (2026-10-16 — eyes-on)

`tools/test-macos-window-shortcuts.sh` checks the keys each window binds;
pressing them needs a display. On a build of `files-fixes`:

- [ ] Open a folder, then a subfolder. Click a file in the list and press
      Delete: the window goes back to the first folder. Press it again with
      no earlier folder: nothing happens.
- [ ] Click a sidebar item, open another place, then press Delete with the
      sidebar focused: the window goes back.
- [ ] Select a file and press Cmd-Delete: it moves to the Trash, the window
      stays in the folder. Undo (Cmd-Z) brings it back.
- [ ] Rename a file (Return), press Delete: a character is deleted, the
      window stays. Same in the path entry (Cmd-L) and the search field
      (Cmd-F), including when the search field is empty.
- [ ] Press Cmd-F, type a few letters, then click a result (or press Down)
      so the list has the focus, and press Delete: the last letter goes,
      the search stays open, the window does not go back. Same during
      Search Everywhere (⇧⌘F).
- [ ] Help ▸ Keyboard Shortcuts lists Delete (⌫) under Go Back.

### R. Cmd-J and Cmd-K (2026-10-20 — eyes-on)

`tools/test-macos-friends-shortcut.sh` presses the keys on a window that is
never shown; on the app, with Friends on:

- [ ] Cmd-J opens Friends with the cursor in its search field; Cmd-J again
      (cursor still there) closes it. Hovering the Friends button shows
      "Friends (Beta) · ⌘J". View ▸ Friends (Beta) shows ⌘J and does the same.
- [ ] Open Add by ID (or a conversation), close with Cmd-J, reopen with
      Cmd-J: it reopens on that page.
- [ ] Cmd-K opens Search Commands with the cursor in its field. Type
      "friends", press Return: Friends opens. "nearby", "add by id" and
      "chat" list Open Friends; Down and Return run the selected command;
      Escape closes. Help ▸ Search Commands… shows ⌘K.
- [ ] "visible", Return: Friends opens on Nearby and you become visible
      (with the helper running); when already visible, nothing changes.
- [ ] Turn Friends off in Preferences: Cmd-J does nothing, View ▸ Friends is
      greyed out, and Cmd-K lists no Friends command.
- [ ] Help ▸ Keyboard Shortcuts lists Show/Hide Friends (⌘J) and Search
      Commands (⌘K).

### G. DMG drag-install (packaging)

- [ ] Open `dist/Nautilus-mac-arm64.dmg`: window shows background art, app
      icon, and Applications-symlink slot.
- [ ] Drag `Nautilus.app` to Applications; launch from **/Applications** (or
      a clean second account / VM) — app opens to `$HOME`.
- [ ] Finder "Open With → Nautilus" and `open -a Nautilus ~/somedir` route a
      folder into a Nautilus window (LaunchServices `::open` path).

---

## Integration changes applied (this pass)

1. **FDA onboarding** — one-shot deferred idle in
   `nautilus_application_window_added` + `app.fda-prompt` `GSimpleAction` +
   "Grant Full Disk Access…" in the Help menu (app-name menu is synthesized
   by GTK's quartz backend from a fixed template with no public extension
   point, so the documented Help-menu fallback was used).
2. **Paste from Finder** — darwin `text/uri-list` fallback branch in
   `paste_files()`, calling the idempotent `nautilus_dnd_init_macos()` so the
   URI-repair deserializer is registered even before any drag.
3. **`NAUTILUS_DATADIR` relocatability** — darwin runtime env override in
   `nautilus-tag-manager.c` `setup_database()`; launcher exports
   `NAUTILUS_DATADIR` at `Resources/share/nautilus`.
4. **Open With .icns icons** — `nautilus_macos_app_icon_texture()` bridge
   (NSWorkspace `iconForFile:` → `GdkTexture`), consumed in
   `nautilus-app-chooser-widget.c` for `GOsxAppInfo` rows (cached per app).
5. **Dev bus wiring** — `run-nautilus.sh` derives `DBUS_SESSION_BUS_ADDRESS`
   from the launchd socket (Homebrew GLib has no launchd bus support).
6. Dropped W7's isolated `-Wno-error=missing-prototypes` — shared build is
   clean without it.
7. **LaunchServices file-type icons (W11)** — files whose themed icon would
   resolve to the generic `application-x-generic` (plus `.app` bundles) get
   the NSWorkspace `iconForFile:` icon instead, cached per
   extension+size (`nautilus-macos-fileicon.m`; hook in `nautilus-file.c`
   `nautilus_file_get_icon_paintable`, generic-ness test in
   `nautilus-icon-info.c`). Thumbnails and specific themed icons keep
   precedence.
8. **"Open in Terminal" (W11)** — darwin context-menu items (background +
   single-folder selection) mirroring the Copy Path pattern in
   `nautilus-files-view.c`; bridge `nautilus_macos_open_in_terminal()`
   (`nautilus-macos-terminal.m`) hands Terminal.app the directory URL via
   LaunchServices.
10. **"Choose in Nautilus" Save/Open-panel handoff (W13, prototype)** —
    `nautilus-macos-savepanel-handoff.m`: Carbon ⌃⌥⌘G global hotkey (armed
    only when the opt-in toggle is ON), AX panel detection, GTK folder
    chooser, and an AX "Go to Folder" drive sequence that navigates another
    app's native Save/Open panel to the chosen folder. Opt-in, off by
    default, Accessibility-gated; toggle in Settings ▸ Finder Integration ▸
    "Choose in Nautilus (Prototype)", persisted in the `[savepanel-handoff]`
    group of `macos-integration.ini`. Startup arms via
    `nautilus_macos_savepanel_handoff_init()` in
    `nautilus_application_startup`. Added `ApplicationServices` + `Carbon`
    frameworks. Proven E2E against TextEdit only — see the W13 section for
    the fragility assessment.
11. **Finder-like Dock lifecycle (2026-07-15)** — startup
    `g_application_hold()` + quit-action release/zero-timeout in
    `nautilus-application.c`; missing
    `applicationShouldHandleReopen:hasVisibleWindows:` added to GTK's
    NSApp delegate at runtime in `nautilus-macos-menu.m` (bridge seam
    `nautilus_macos_lifecycle_install_reopen_handler`). Follow-ups
    (2026-07-16): the reopened window is centered on the screen under the
    mouse (= the Dock the user clicked) via
    `gdk_macos_surface_get_native_window()` + `setFrameOrigin:`, applied
    synchronously in the window's `map` handler (before GDK's
    first-buffer-swap orderFront, so the first visible frame is already
    centered — no wrong-screen flash; the reopen path arms via a one-shot
    `window-added` handler before activate); and the FIRST window of a
    cold launch gets the same treatment (`launch_placement_capture` at
    startup + one-shot `launch_placement_apply` in `create_window`),
    fixing GDK's y-flipped monitor-under-mouse lookup. See the dedicated
    section above.
14. **Context-menu layout tweaks (2026-07-16 pm, user request)** — in
    `nautilus-files-view.c` (darwin blocks, shared .ui untouched):
    upstream "Copy to…" removed from the selection menu ("Move to…"
    stays); "Copy Path" moved out of the cut/copy sections into its own
    one-item separator-delimited GMenu section directly below — selection
    menu: Cut / Copy / Move to… | **Copy Path** | Rename…-group;
    background menu: Paste / Paste as Link / Select All / Visible
    Columns… | **Copy Path** | Properties-group. Screenshot-verified
    (`scratch-fonts/selmenu_new.png`, `bgmenu_new.png`).
12. **Font rendering fix (2026-07-15)** — `macos_setup_font_rendering()`
    in `nautilus-application.c`: programmatic `gtk-font-name
    ".AppleSystemUIFont 13"` + inherited Medium default weight. Root
    cause (12 pt default + cairo-quartz disabling CoreText stem
    darkening for grayscale AA) documented in the dedicated section above.
13. **Startup Back/Forward crash fix (2026-07-16)** — the intermittent
    "Nautilus quit unexpectedly" SIGSEGV (4 crash reports; all within
    0.4–2.4 s of launch) was an upstream Nautilus bug: the slot's
    Back/Forward `GSimpleAction`s are enabled-by-default before the first
    location finishes its async load, and
    `nautilus_window_slot_back_or_forward()` dereferences the still-NULL
    `content_view` via `nautilus_files_view_is_searching()`. Fixed in
    `nautilus-window-slot.c` (sync the enabled state at slot init +
    NULL-guard `content_view`); deterministic lldb repro before/after.
    See `docs/phase6-known-issues.md` #6.
15. **Custom starting folder (2026-07-16 pm, user request)** — new
    GSettings key `starting-location` (org.gnome.nautilus.preferences,
    type 's', default '' = home; `NAUTILUS_PREFERENCES_STARTING_LOCATION`)
    resolved by `nautilus_application_get_starting_location()` in
    `nautilus-application.c` and honored by all no-explicit-location
    window paths: `nautilus_application_activate` (cold launch, Dock
    reopen), `action_new_window` (Cmd-N), and `--new-window`. Paths that
    don't exist or aren't folders fall back to home with a warning
    (folder deleted later = safe). Explicit-location paths (CLI args,
    Services, file-open) untouched. UI: darwin-gated "Starting Folder"
    AdwActionRow in Preferences ▸ General (subtitle shows the choice,
    `~`-abbreviated; folder-picker via GtkFileDialog select-folder;
    reset-to-Home button appears only for a custom value) —
    `setup_starting_folder_row()` in `nautilus-preferences-dialog.c`,
    shared .blp untouched. Verified against the isolated install prefix
    (keyfile backend): key `~/Downloads` → first window titled
    "Downloads"; key `/nonexistent/xyz` → window titled "Home" plus the
    fallback warning in the log.
13. **macOS window chrome (2026-07-16)** — Finder-style layout: window
    controls in the sidebar header top-left (`nautilus-window.blp`),
    decoration layout `close,minimize,maximize:`, native-metric CSS
    traffic lights (14 px / 23 px c2c, hover glyphs, gray backdrop) via
    `macos_setup_window_chrome()` in `nautilus-application.c`; main menu
    + Search Everywhere moved into the content toolbar behind new
    opt-in `NautilusToolbar` properties (the search button searches the
    current folder since 2026-10-13). Controls remain GTK-drawn
    (native ones still deadlock, see #9). Details in the dedicated
    section above.
9. **Native window-controls hang fix (GTK #7964)** — force
   `use-native-controls = FALSE` on every `GtkWindowControls` per toplevel
   (`macos_setup_native_window_controls` in `nautilus-application.c`,
   re-applied on map and on sidebar show/collapse). Cures the "stuck
   running with no window, cannot close or reopen" zombie: on macOS 26.5 a
   click on the native traffic lights wedged the main thread in AppKit's
   `NSButtonCell trackMouse` modal loop (GDK steals the mouse-up), and the
   wedged process kept the bundle ID registered so relaunches were blocked.
   Window buttons are now GTK-drawn. See `docs/phase6-known-issues.md` #4.

## Notarized release (2026-07-20)

Gatekeeper hard-blocked the first (ad-hoc) download ("Apple could not verify…").
Fixed by adopting shenzhen-pdf's actual release signing: Developer ID
Application (INTUITION Robotique & Technologies, 66LJ4BV7Q3, login keychain)
+ `notarytool` keychain profile `shenzhenpdf-notary`, no entitlements,
hardened runtime + secure timestamp on every Mach-O. One command now does the
whole chain: `package/sign-and-notarize.sh` (prompt-probe → sign 80 Mach-Os →
DMG → notarize → staple → Gatekeeper-simulate on a quarantined copy → clobber
release asset → digest re-check → install). Verified 2026-07-20: notary
submission `8b882586-68c2-47a8-97ed-e08176e9dc4f` **Accepted**; `spctl` says
"accepted / Notarized Developer ID" for the DMG, for a quarantined app copy
(0081 flag), and for the installed app; GitHub digest matches the local DMG.

Keychain lesson (cost a prompt-loop): the Developer ID private key is labeled
"Raphaël Casimir" in the login keychain; its partition list was fine but its
application ACL lacked `/usr/bin/codesign`, so every codesign call prompted
and password entry never stuck. Fix was one-time, via Keychain Access ▸ key ▸
Access Control (no CLI exists for app ACLs). The sign-and-notarize.sh probe
(10-s timeout on a throwaway binary) guards against ever looping on this again.

TCC note: the identity change (ad-hoc → Developer ID) resets TCC once more —
re-grant Full Disk Access (and Accessibility for the save-panel handoff).
Future updates keep the same identity, so grants now persist across releases.

## Hardened-runtime startup crash fixed (2026-07-21)

The first notarized 26.7.19-1 download crashed at startup (SIGABRT in
libtinysparql `ensure_init_parser`, via `nautilus_tag_manager_init`). Root
cause: libtinysparql loads its parser/collation module
(`libtracker-parser-libicu.so`) from a compile-time-baked absolute Homebrew
path with no env override, and the port never bundled it — so it relied on
the dev machine's Homebrew, and under the hardened runtime's Library
Validation the ad-hoc-signed Homebrew module can't be dlopen'd at all. Fix:
bundle the module (`make-app.sh`), binary-patch libtinysparql's baked path to
`@executable_path/../Resources/lib/tinysparql-3.0` and re-sign the module with
our Team ID (`bundle-dylibs.sh`), plus a darwin preflight in
`nautilus-tag-manager.c` that degrades to "starring disabled" instead of
aborting if the module is ever unloadable. `sign-and-notarize.sh` now runs a
launch smoke test on the quarantined copy so this class of bug can't ship
again. Re-notarized (submission `b666c1f7-…`, Accepted) and re-released; the
quarantined download launches cleanly and the tag DB initializes. See
docs/phase6-known-issues.md §7.

## Release 26.7.22-1 (2026-07-22)

Second public release. Accumulated since 26.7.19-1 (whose asset had been
clobbered in place during the signing/crash iterations): Developer ID +
notarization (Gatekeeper-clean downloads), the hardened-runtime tinysparql
startup-crash fix with graceful starring degradation, the paste crash fix
(GDK-macOS NULL-provider clipboard clear) + Finder-paste URI-repair ordering
fix, and Finder-style slow-click rename. Version bumped in
package/make-app.sh (SHORT_VERSION), package/Info.plist.template, README
badge; the self-updater reads CFBundleShortVersionString/CFBundleVersion from
the bundle, so the built app self-reports 26.7.22-1 (post-update handshake
compares the tag's YY.M.DD against exactly that). 26.7.19-1 stays intact as a
historical release; releases/latest now serves 26.7.22-1.

## Paste crash fixed: clipboard clear on cut-paste (2026-07-22)

User crash on the installed app: cut/copy a file, paste it back into the
same folder → SIGSEGV in `-[GdkMacosPasteboardItemDataProvider types]`.
Root cause is an upstream GDK-macOS bug: `gdk_clipboard_set_content
(clipboard, NULL)` — the documented "release the clipboard claim" call —
reaches the macOS backend's claim path with a nil content provider, and
`types` dereferences it (gtk 4.22.4, `gdk/macos/gdkmacospasteboard.c:324`;
worsened by `gdk_content_formats_get_mime_types` leaving its out-param
uninitialized on the precondition failure, so stack garbage becomes the
loop count). Nautilus clears the clipboard this way in two places: the
colliding-URIs check when pasting into the source folder, and after every
cut-paste. Fix: `nautilus_clipboard_clear()` (darwin-gated) claims with an
empty union provider instead of NULL — same clear semantics, valid
provider, pasteboard verified empty afterwards. While regression-testing,
paste-from-Finder was found broken unless a drag had already happened
(URI-repair deserializer registered too late) — `paste_files()` now
registers it up front. Scripted lldb repro before/after + regression
matrix (copy/cut/collision/Finder paste) in
`docs/phase6-known-issues.md` §8. Upstream-reportable GDK bug documented
there. Release re-signed/notarized and 26.7.19-1 asset re-published.

## Volume hot-plug fixed (2026-10-13)

Owner report: a volume that is connected or disconnected does not show up in
the sidebar until a window is closed and reopened, sometimes not until the app
is relaunched. The Mounted volumes row above claimed a `/Volumes` watch gave
hot-plug refresh.

**Root cause.** Each window's sidebar created its own
`g_file_monitor_directory ("/Volumes", G_FILE_MONITOR_WATCH_MOUNTS)`, which on
macOS is GLib's kqueue backend (`GKqueueFileMonitor`, GLib 2.88.2), and rebuilt
on every event by enumerating mounted volumes. A mount adds one entry to
`/Volumes`: the mount point directory, created before the file system is
mounted on it. GLib reports entry changes only, so the sidebar rebuilt at that
moment, found no such volume yet, and got no second event when the mount
completed (the kqueue write it causes changes no entry). The volume stayed
missing until something else rebuilt the sidebar, such as opening a window. A
headless reproduction with the unmodified bridge code and the same monitor
(3 attach/detach cycles of a throwaway disk image) rebuilt the sidebar twice per
attach, both times at mount-point creation, and the volume was missing all
three times although it was mounted; a forced rebuild, as a new window does,
then listed it. No case that needed a relaunch was found. A probe of every
event source during a disk-image attach, rename
and detach and a NetFS WebDAV mount (the way Finder mounts network volumes)
showed:

| Event | When, after the mount point appears | Volume listed by `NSFileManager` then? |
|---|---|---|
| kqueue on `/Volumes`, then GLib `created` (what the sidebar rebuilt on) | +0 ms, +6–8 ms | no (mount not done yet) |
| Disk Arbitration `DAVolumePath` change (disk image) | +16 ms | yes |
| NSWorkspace did-mount (disk image / WebDAV) | +17 ms / +41 ms | yes |
| NSWorkspace did-rename-volume | on rename | not yet: the mount table still had the old mount point for ~3 ms |
| NSWorkspace did-unmount, Disk Arbitration disappeared | on unmount | gone |

Unmounting removes the mount point after the file system is gone, so the old
monitor did report removals of volumes it was showing; the missing additions
are what made it look broken both ways. Every window also re-enumerated volumes
on the main thread, including `getFileSystemInfoForPath`, which blocks on an
unresponsive network volume.

**Fix** (`src/nautilus-macos-volumes.m`, `src/nautilus-sidebar.c`,
`src/nautilus-macos-bridge.h` section W15). `NautilusMacosVolumeMonitor` is one
process-wide source. It listens to NSWorkspace did-mount, did-unmount and
did-rename-volume (every volume kind, network included) and to Disk
Arbitration disk appeared/disappeared and volume path/name changes, which are
delivered on a private serial queue and so do not depend on the main run loop.
Events from both are funnelled onto that queue and coalesced: one scan 50 ms
after the first event of a burst, and a settle scan 600 ms after the last one,
for changes the first scan saw half-done, such as the rename lag above. The scan
runs on the queue, and the result is applied on the main context as an idle
source. There it is diffed against the previous snapshot, pairing volumes by
mount point and then by file system id, so a rename is reported as a change and
not as a removal plus an addition. The monitor emits `volume-added`,
`volume-removed` and `volume-changed`, then `changed`, only for real changes.
Every sidebar connects to `changed` and rebuilds from the cached snapshot,
which never blocks. The per-window `/Volumes` monitor is gone. After its own
eject the sidebar asks the monitor for a rescan, because the NSWorkspace
notification waits for the main thread, which the synchronous eject has just
blocked. The tabs-to-Home preparation before eject is unchanged.

`g_main_context_invoke()` was tried first and rejected: called from a queue
thread while the main thread does not hold the default context, it acquires
the context and runs the callback on the queue. The tests caught this, and the
monitor now always attaches an idle source.

**Tests.** `nautilus/test/displayless/test-macos-volumes.c`, run by
`tools/test-macos-volumes.sh`. The script configures `build-tests/` with
`-Dtests=headless`, builds only that target, serves a throwaway WebDAV share
with the system Apache, runs the test, and detaches or unmounts anything an
aborted run leaves behind. Upstream's test meson files now leave out the
Tracker tests when `localsearch` is missing instead of refusing to configure.
No test opens a window. While the test volumes are mounted, Finder may show
them on the desktop.

| Test | Checks |
|---|---|
| `/macos-volumes/monitor/workspace-events` | NSWorkspace alone: a real disk image attach and detach are each reported once, within 1 s of `hdiutil` returning, and the sidebar's merged list (GIO mounts plus the monitor's volumes) gains and loses the mount point exactly once |
| `/macos-volumes/monitor/disk-arbitration-events` | the same with Disk Arbitration alone and no CFRunLoop turning |
| `/macos-volumes/monitor/shared-two-subscribers` | two subscribers on the shared monitor (two windows) each get the attach once and the sidebar-style eject (`nautilus_macos_unmount_volume` + refresh) once, although both sources report them |
| `/macos-volumes/monitor/rename` | `diskutil rename`: one `volume-changed` to the new mount point, no removal or addition, merged list follows |
| `/macos-volumes/monitor/network-volume` | a NetFS WebDAV mount under `/Volumes` and its unmount are each reported once within 1 s |

Every signal handler asserts it runs on the main thread. With delivery switched
back to `g_main_context_invoke()`, the shared-subscribers test fails on that
assertion.

| Command (2026-10-13, macOS 26.5.1 arm64) | Exit | Result |
|---|---|---|
| `tools/setup-nautilus-tree.sh` | 0 | tree matches the regenerated patch; build and install |
| `tools/setup-nautilus-tree.sh` from scratch in a fresh worktree (new upstream fetch) | 0 | 79 patched paths verified; `diff -rq` identical to the working tree |
| `tools/test-macos-volumes.sh` (twice, plus once in the fresh worktree) | 0 | 6/6 pass; every event at most 63 ms after its command returned, renames and WebDAV unmounts 25–56 ms before |
| test binary 5 more times in a row | 0 | 6/6 each time, worst latency 47 ms |
| test binary under `libMainThreadChecker.dylib` | 0 | no reports (a sanity probe calling `-[NSView init]` off the main thread is reported) |
| `meson setup -Dtests=all`, `ninja test/display/test-macos-sidebar` | 0 | configures without `localsearch`; the display test compiles (not run: it needs a display) |
| `package/make-app.sh`, `package/bundle-dylibs.sh` (ad hoc), `codesign --verify --deep --strict` | 0 | bundle links DiskArbitration; not launched |

The sidebar rows themselves are not exercised by an automated test, because
that needs a display; see checklist J above.

## Opening apps and extracting archives fixed (2026-10-13)

Owner reports: "When you click on an app it should launch it, not open it like
an archive", and "On archives, right-click should show the uncompress option".

### Apps opened like folders

**What happened.** Double-clicking `Calculator.app` (or pressing Enter, or
Cmd-O) showed its `Contents` folder in the window, as for an archive or a plain
folder. A displayless probe of the unmodified tree (`probe-activation`, built
against the base tree, no window) printed the activation decision for a
throwaway app bundle, a folder and three archives:

```
Marker.app     content-type=public.folder           is_directory=1 opens_in_view=1 is_archive=0 -> OPEN_IN_VIEW (browse into it)
Plain Folder   content-type=public.folder           is_directory=1 opens_in_view=1 is_archive=0 -> OPEN_IN_VIEW (browse into it)
t.zip          content-type=public.zip-archive      is_directory=0 opens_in_view=0 is_archive=0 -> OPEN_IN_APPLICATION
t.tar.gz       content-type=org.gnu.gnu-zip-archive is_directory=0 opens_in_view=0 is_archive=0 -> OPEN_IN_APPLICATION
x.7z           content-type=org.7-zip.7-zip-archive is_directory=0 opens_in_view=0 is_archive=0 -> OPEN_IN_APPLICATION
```

**Root cause.** GIO describes every folder, packages included, with the
content type `public.folder`; it never asks LaunchServices whether a folder is
a file package, and neither did the port (only the icon code special-cased the
`.app` suffix). `get_activation_action()` in `nautilus-mime-actions.c` found
the bundle not an archive and not launchable (it is not a regular file), and
`nautilus_file_opens_in_view()` true, so it opened it in the view.

**Fix** (`src/nautilus-macos-packages.m`, new; bridge section W16;
`nautilus-file.c`, `nautilus-mime-actions.c`, `nautilus-files-view.c`,
`nautilus-sidebar.c`, `nautilus-window-slot.c`, `nautilus-application.c`).

- A folder is a package when LaunchServices says so: `NSURLIsPackageKey` (the
  answer `-[NSWorkspace isFilePackageAtPath:]` gives) and, for apps,
  `NSURLIsApplicationKey`, on the path with symbolic links resolved (a link to
  an app is "public.symlink" to LaunchServices). `.app`, `.bundle`, `.plugin`,
  `.pkg`, `.rtfd`, `.pages`, `.photoslibrary`, `.xcodeproj`, `.kext`, `.appex`
  are packages; `.framework`, `.lproj` and folders with dots in their names are
  folders, as in Finder. The lookup costs about 20–45 µs, so the answer is kept
  on the `NautilusFile` until its path or modification time changes.
- `nautilus_file_opens_in_view()` is false for packages, so they are not
  browsed into and get no Open in New Tab/Window. `get_activation_action()`
  returns a new `ACTIVATION_ACTION_OPEN_MACOS_PACKAGE` for them, before the
  archive check. Activation collects them and hands them to
  `nautilus_macos_open_packages()`: an app is launched with
  `openApplicationAtURL:configuration:completionHandler:`, any other package is
  opened with its default app through `openURL:configuration:completionHandler:`
  (a `.rtfd` in TextEdit, a Photos library in Photos). Several selected apps
  are each launched and count towards the "open many items" confirmation. Both
  calls return at once; the result comes back on the main context as an idle
  source. `promptsUserIfNeeded` is off, so failures come back to Nautilus
  instead of LaunchServices showing its own alert as well; per the AppKit
  header this does not affect Gatekeeper, which still asks before a downloaded
  app first opens. A failure is shown in Nautilus's OK dialog ("Unable to open
  “Broken.app”" with macOS's explanation, e.g. "The application “Broken.app”
  could not be launched because it is corrupt."); a package no app claims says
  "No app on this Mac is set to open it." and how to look inside; a declined
  prompt shows nothing. A path that is not a package is refused, never passed
  to `openURL:`, which would show a folder in Finder.
- **Show Package Contents** is in the context menu right under Open when every
  selected item is a package: one opens in the current tab, several in new
  tabs. Apps have no Open With… and packages no Paste Into Folder, as in
  Finder.
- Search results, Starred and Recent use the same activation path (Recent has
  no GVfs backend on macOS; the check uses the activation location, so its
  items would resolve to their targets). Clicking an app in the sidebar
  launches it; Open in New Tab/Window from the sidebar shows its contents.

### No Extract for archives

**Root cause.** `nautilus_file_is_archive()` passed the content type to
`autoar_check_mime_type_supported()`, which compares it with its list of MIME
types using `g_content_type_equals()`. On macOS the content type is a UTI
(`public.zip-archive`), and GLib's macOS `g_content_type_equals()` compares
UTIs, so no file was ever an archive. "Extract" and "Extract to…" require every
selected file to be an archive, so they stayed disabled, and the context menu
hides disabled items. No port `#ifdef` hid them. Even GLib's own
`g_content_type_get_mime_type()` was not enough: it gives `application/x-gzip`
and `application/x-bzip2`, which autoar does not list, and nothing for `.tgz`,
`.tbz2`, `.txz`, `.tzst`, `.cpio` or `.xar`.

**Fix.** On macOS `nautilus_file_is_archive()` asks autoar about the MIME types
of the UTI: all of its MIME tags from `UTType` (gzip also carries
`application/gzip`, bzip2 `application/x-bzip`), plus the freedesktop name for
the archive UTIs macOS describes without a usable one (`org.gnu.gnu-zip-tar-archive`
→ `application/x-compressed-tar`, `public.tar-bzip2-archive`,
`org.tukaani.tar-xz-archive`, `com.facebook.zstandard-tar-archive`,
`com.rarlab.rar-archive` → `application/vnd.rar`, `public.cpio-archive`,
`com.apple.xar-archive`). Exact UTIs only: following conformance would make
`.docx`, `.epub` and `.jar` archives, which GNOME does not treat them as either.
Answers are cached per content type. The extract actions themselves are
upstream's: Extract (here) where the folder is writable and not a search, else
Extract to…; the native File menu now also has Compress…, Extract and Extract
to…. Double-click keeps opening an archive with its default app (Archive
Utility here); it extracts instead when that app is Shenzhen Files, which
macOS names by bundle identifier rather than `org.gnome.Nautilus.desktop`
(files view and window slot).

### Tests

`nautilus/test/displayless/test-macos-apps-archives.c`, run by
`tools/test-macos-apps-archives.sh` (configures `build-tests/` with
`-Dtests=headless` if needed, builds the test, its marker app and the
GSettings schemas, runs it, and unregisters and deletes the fixtures even after
an aborted run). The only apps it launches are its own throwaway bundles, whose
executable (`macos-test-marker-app.m`) is `LSBackgroundOnly`, shows nothing,
appends "launched <pid>" next to its bundle and quits. The test sets the locale
the way the app gets it (the launcher's `LANG=en_US.UTF-8`, then
`setlocale`). No window is opened.

| Test | Checks |
|---|---|
| `/macos-apps-archives/packages/classification` | apps (incl. a non-ASCII name, an empty `.app`, a symlink to an app, Calculator), document packages (`.rtfd`, `.bundle`, `.plugin`, `.pkg`, `.photoslibrary`, `.pages`) and non-packages (folders, `.framework`, `.lproj`, dotted and non-ASCII folder names, `/Applications`, a text file, a zip, a missing path) |
| `/macos-apps-archives/packages/activation-decision` | exactly one way of opening per item: apps launch, document packages open with their app, folders browse, a text file opens with its app; Show Package Contents applies exactly to packages, which are never archives; zip, tar.gz and 7z do what their default app implies (open with Archive Utility here) |
| `/macos-apps-archives/packages/drag-hover` | (added on `files-fixes`) a drag paused over an app, a symlink to an app, an empty `.app`, an `.rtfd` or a `.bundle` does not open it; folders, `.framework`, dotted and non-ASCII folders do; a text file and a zip do not |
| `/macos-apps-archives/packages/app-id-is-self` | an unbundled binary is never "self" |
| `/macos-apps-archives/packages/launch-one` | `nautilus_macos_open_packages()` launches a throwaway app: no error, the report arrives on the main thread only through the main context, the app records its launch |
| `/macos-apps-archives/packages/launch-several` | two apps in one call are both launched, one report each, one destroy |
| `/macos-apps-archives/packages/open-errors` | an empty `.app` (macOS: "could not be launched because it is corrupt"), a missing app (not found), a plain folder (refused without NSWorkspace) and, if no app on the Mac claims `.bundle`, an unclaimed package (no app can open it, nothing launched) |
| `/macos-apps-archives/archives/mime-types` | the UTI → MIME mapping; autoar rejects the raw UTI (the bug); a `.docx` UTI maps to no zip type |
| `/macos-apps-archives/archives/detection` | 22 archives are detected (zip, tar, tar.gz, tgz, tar.bz2, tbz2, tar.xz, txz, tar.zst, tzst, tar.lzma, tar.lz, tar.Z, 7z, cpio, xar, rar, gz, bz2, xz, names with spaces and non-ASCII); `.txt`, `.docx`, `.epub`, `.jar`, `.iso`, a folder, an app and an `.rtfd` are not |
| `/macos-apps-archives/archives/extraction` | Nautilus's extract operation on bsdtar-made zip, non-ASCII zip, tar.gz with spaces, non-ASCII 7z, tar, tar.bz2, txz, tar.zst, gz, bz2 and xz: output folder names and file contents, including `sub dir/über 文件.txt` |
| `/macos-apps-archives/archives/compress-round-trip` | Nautilus's compress operation makes zip, tar.xz and 7z of a non-ASCII folder, each is detected as an archive and extracts back |

With `nautilus_file_is_archive()` reverted to the raw UTI, the detection test
fails on `Archive.zip`; with the package checks removed from
`get_activation_action()` and `nautilus_file_opens_in_view()`, the decision
test fails on `Decision.app`. Two findings from writing it: archives with
non-ASCII names do not extract in the "C" locale (see limitations), and
libarchive refuses a compressed one-word text file as an mtree specification
("Missing type keyword"), independent of this port, so the fixtures use two
lines of text.

| Command (2026-10-13, macOS 26.5.1 arm64) | Exit | Result |
|---|---|---|
| `tools/setup-nautilus-tree.sh --check` | 0 | tree matches the regenerated patch (85 patched paths; only this fix's 14 files changed in it) |
| `tools/setup-nautilus-tree.sh` from scratch in a fresh worktree of this branch (new upstream fetch) | 0 | 85 patched paths verified; `diff -rq` identical to the working tree; `--check` 0 there |
| `tools/test-macos-apps-archives.sh` (4 times, plus once in the fresh worktree) | 0 | 10/10 pass in 2–3.5 s; no test app left registered with LaunchServices or running |
| test binary under `libMainThreadChecker.dylib` | 0 | 10/10, no reports |
| `tools/test-macos-volumes.sh` | 0 | 6/6 pass |
| `package/make-app.sh`, `package/bundle-dylibs.sh` (ad hoc), `codesign --verify --deep --strict` | 0 | valid on disk; the binary contains the new code; not launched |

The menus, the dialogs and real apps from `/Applications` need a display and
the owner's apps; see checklist K above.

## Quick Look keyboard focus fixed (2026-10-13)

Owner report: after pressing space to open Quick Look, pressing space again
does not bring the focus back to Shenzhen Files.

**Root cause.** `nautilus_macos_preview_files()` opened the panel with
`makeKeyAndOrderFront:`, so the panel became the key window and the Files
window lost the keyboard.

1. GDK hands a key event to GTK only when it was sent to a GdkMacosWindow
   (`_gdk_macos_display_translate()` in GTK 4.22.4's
   `gdk/macos/gdkmacosdisplay-translate.c`). With the panel key, the second
   space never reached the file view's `view.preview-selection` shortcut. The
   port's toggle-close path, the only code that made the Files window key
   again (`[[NSApp mainWindow] makeKeyWindow]` in
   `nautilus_macos_preview_hide()`), therefore could not run.
2. The key went to the panel instead. QuickLookUI, disassembled on this
   machine (macOS 26.5.1), routes key events from `-[QLPreviewPanel
   sendEvent:]` to `-[QLPreviewPanelController handleEvent:]`, which maps them
   to built-in actions. Space is action 3 (`closeWithEffect:… canToggle:YES
   force:YES`); Escape and Cmd-W are action 4 (close). `-_canOverrideUserAction:`
   (mask `0x02ffe7fe`) excludes both, so Quick Look closes the panel itself
   and never offers these keys to the delegate's `previewPanel:handleEvent:`,
   which was the port's only hook.
3. Nothing then gave the keyboard back. GDK does not reclaim it:
   `select_key_in_idle_cb()` leaves a foreign key window alone and only
   re-keys surfaces that cannot be minimized. The owner's report, and the
   comment the original author left in `nautilus_macos_preview_hide()` ("GTK
   does not reclaim key status by itself"), show that AppKit does not
   reliably make the Files window key either when the panel leaves the
   screen. That last point was not reproduced here: it needs a visible panel.

The same disassembly shows the way out: `-[QLPreviewPanel orderFront:]` is
`-_orderFrontAndMakeKey:NO`, and `-_setupPanelWindow` makes the panel a
floating panel, so it stays above the Files window while that window is key,
as in Finder.

**Fix** (`src/nautilus-macos-previewer.m`, `src/nautilus-previewer.c`,
`src/nautilus-files-view.c`, `src/nautilus-application.c`,
`src/nautilus-macos-bridge.h` section W17).

- The panel opens with `orderFront:` and the Files window keeps the keyboard.
  Space and Escape in the file view close the panel while it is open. This is
  a capture-phase shortcut placed before the existing space shortcut; it
  consumes the key only while the panel is showing, so it also works with
  nothing selected, when `view.preview-selection` is disabled. File ▸ Quick
  Look (Cmd-Y) toggles the panel; as a menu key equivalent it works whichever
  window has the keyboard. Space and Cmd-Y now close the panel whatever it
  shows, as in Finder; before, they closed it only if it showed the file the
  key was pressed on.
- The panel gets the keyboard only when the user clicks into it. The
  controller records the Files window the panel was opened from (the slot's
  `gdk_macos_surface_get_native_window()`; it moves to another window when
  that window's selection changes what the panel shows). It watches the
  panel's resign-key, will-close and occlusion notifications and
  `endPreviewPanelControl:`. On the next idle, if the app is active and no
  window has the keyboard, it makes the Files window key, and the C side puts
  GTK's focus back on the file view. `makeKeyWindow` reaches GTK through
  GdkMacosWindow's `windowDidBecomeKey:`, the normal focus-in path. Closing
  from the Files side while the panel has the keyboard (Cmd-Y through the
  menu) gives it back at once, without waiting for the closing animation.
- Keys Quick Look offers its delegate while it has the keyboard: arrows move
  the selection as before (Left/Right page inside the panel when it holds a
  multiple selection); Cmd-Y closes; Return, Cmd-O, Cmd-arrows and plain
  typing give the keyboard back to the Files window and deliver the same key
  there (a copy of the NSEvent addressed to that window, posted at the front
  of the queue, where GDK picks it up for GTK). Other command and control keys
  stay with Quick Look and the menu bar.
- Non-local URIs are still skipped; the selected index is now mapped onto
  the remaining items (it used to point at the wrong item when a non-local one
  came first). Paths become NSURLs through `stringWithFileSystemRepresentation:`,
  which accepts any bytes.

The controller is plain C over `NautilusMacosPreviewBackend`; the AppKit
backend at the end of the file is the only code that touches the panel and
windows.

Known limit: a space pressed during Quick Look's closing animation (about a
quarter of a second) is lost, because Quick Look ignores an open request while
the panel is still on screen (`-_openWithEffect:willOpen:toFullscreen:`
returns early when `isOnScreen`).

**Tests.** `nautilus/test/displayless/test-macos-quicklook.m`, run by
`tools/test-macos-quicklook.sh`, which configures `build-tests/` with
`-Dtests=headless` like the volume script and builds only that target. A fake
backend models AppKit and Quick Look: which window is key, whether the panel
is on screen and has the keyboard, the panel taking the keyboard when clicked,
and Quick Look closing the panel itself while AppKit gives the keyboard to no
window (what the owner saw) or to the Files window. No window, panel or
NSApplication is created.

| Tests | Checks |
|---|---|
| `files-keyboard/*` (8) | Space opens the panel without taking the keyboard; space again closes it and the Files window stays key; a third space reopens it. Escape and space are consumed only while the panel is open. A selection change reloads the panel in place; the panel follows another window's selection. With no Files window the panel takes the keyboard. Non-local URIs are skipped and the index is mapped. |
| `panel-keyboard/*` (7) | After a click into the panel, Quick Look closing itself gives the keyboard back to the Files window once (one focus callback), also while the panel is still fading out; nothing extra happens when AppKit already did it. Cmd-Y from the menu gives it back at once. Clicking back into the Files window keeps the panel open. Nothing happens while the app is inactive, and the restore still works after reactivation. A Files window closed meanwhile is left alone. |
| `panel-keys/*` (4) | A 25-case key classification table. Arrows move the selection from an idle, never while the panel is dispatching the key; Left/Right stay with the panel when it has several items. Return gives the keyboard and the key itself to the Files window. Real NSEvents through the installed delegate (Down, a key-up, Cmd-C, a letter, Cmd-Y). |

Making the panel key on open again fails
`files-keyboard/space-opens-without-taking-keyboard`; removing the restore
after Quick Look closes itself fails the `panel-keyboard` tests. Both runs
exit 134.

| Command (2026-10-13, macOS 26.5.1 arm64) | Exit | Result |
|---|---|---|
| `tools/setup-nautilus-tree.sh --check` | 0 | tree matches the regenerated patch; only the 7 Quick Look paths differ from the volume-fix patch |
| `tools/setup-nautilus-tree.sh` | 0 | build and install, no new warnings |
| `tools/test-macos-quicklook.sh` | 0 | 19/19 |
| the same with the panel made key on open / with the restore removed | 134 / 134 | the tests above fail |
| `tools/setup-nautilus-tree.sh` from scratch in a fresh worktree (new upstream fetch) | 0 | 80 patched paths verified; `diff -rq` identical to the working tree |
| `tools/test-macos-quicklook.sh` in the fresh worktree, then the binary 5 more times | 0 | 19/19 each time |
| `tools/test-macos-volumes.sh` | 0 | 6/6, the volume fix is unaffected |
| `package/make-app.sh`, `package/bundle-dylibs.sh` (ad hoc), `codesign --verify --deep --strict` | 0 | bundle contains the File ▸ Quick Look item; not launched |

Not covered automatically: the real panel (opening without taking the
keyboard, staying above the window, Quick Look's own key handling), GTK
receiving the focus-in, and the re-delivered key reaching the file view. See
checklist L above.

## Three fixes combined on `files-fixes` (2026-10-13)

Branch `files-fixes` holds the volume hot-plug fix (its base,
`fix-volume-hotplug`), the apps and archives fix (`fix-open-apps-archives`)
and the Quick Look fix (`fix-quicklook-space`), plus one defect found while
reviewing them. All three owner reports from this round are covered: an app
launches when opened, archives offer Extract, and a second space closes Quick
Look and leaves Shenzhen Files active.

**How they were combined.** The four fix commits were cherry-picked. Each
branch had regenerated `patches/macos-port-full.patch` from its own tree, so
the patch was rebuilt instead: both branches' `nautilus/` changes were applied
to the `fix-volume-hotplug` tree and the patch regenerated from the result.
Four files carry both fixes:

- `nautilus-application.c`: the File menu gets both the archive group
  (Compress…, Extract, Extract to…) and the Quick Look item.
- `nautilus-macos-bridge.h`: the packages section stays W16; the Quick Look
  section, also numbered W16 on its own branch, follows it as W17.
- `test/displayless/meson.build`: both tests are kept.
- `nautilus-files-view.c`: the hunks do not overlap.

In this file both fix sections are kept, and the Quick Look checklist is L
because K is the apps checklist. Compared with `fix-volume-hotplug`, the
regenerated patch (86 paths) changes exactly 19 files: the 14 of the apps fix
and the 7 of the Quick Look fix (4 shared), plus `nautilus-list-base.c` and
`nautilus-list-base-private.h` for the review fix. The other 67 entries are
unchanged. The patch is still generated the way the earlier ones were: new
files marked intent-to-add in a scratch index, `git diff` in `nautilus/`, and
blank context lines written as empty lines.

**Defect found in review and fixed: a paused drag launched the app under
it.** In the file view, a drag that rests on a folder for the hover timeout
opens it by activating it (`open-folder-on-dnd-hover`, on by default). The
check was `nautilus_file_is_directory()`, and an app bundle is a directory.
Once apps launched on activation, dragging a file across `/Applications` and
pausing on an app launched it, and pausing on an `.rtfd` opened it in
TextEdit. Before the apps fix the same pause browsed into the bundle.
`hover_timer()` now also requires
`nautilus_list_base_file_opens_on_drag_hover()`: a directory that activation
opens in the view. That leaves out apps and other packages, as in Finder. The
new test `/macos-apps-archives/packages/drag-hover` fails on `Decision.app`
when the decision is put back to `nautilus_file_is_directory()`. The timer
itself needs a real drag; it is in checklist K. The review also put
`nautilus-file.h` back to upstream spacing on a line the apps fix had
changed for no reason.

**Checked in review and found correct:**

- Plain folders, `.framework`, `.lproj` and folders with dots in their names
  still browse (the decision test). In the file chooser modes a package
  counts as a file, so double-clicking an app there picks it instead of
  launching it (from reading `nautilus_window_slot_handle_activate_files()`;
  not tested).
- Archives still follow the Mac's default app on double-click, and extract
  only when that app is Shenzhen Files. Only exact archive UTIs count.
  `.iso` gets no Extract because autoar itself rejects disc images:
  `autoar_check_mime_type_supported("application/x-cd-image")` returns FALSE
  here.
- The Quick Look data source is unchanged: the same item list and the same
  index, except that the index is now mapped correctly when non-local items
  are skipped.
- Main thread: NSWorkspace opens packages asynchronously and reports back
  through an idle source. The LaunchServices package check is synchronous,
  about 20–45 µs locally, and cached on the file. The Quick Look focus logic
  runs from idles and panel notifications on the main thread.
- No leaks in the new code: under `leaks --atExit`, the Quick Look test has
  0 leaks, and the apps package tests have 25 leaks of 160 bytes, all from the
  test's own `g_spawn_sync()` cleanup in `main()`.

**Open, not fixed here** (the first two are fixed in "Follow-ups to the
three fixes" below):

- Dropping files onto an app still moves them into the bundle. Finder opens
  them with the app instead. This was already the case before the fix.
  Refusing drops onto packages in `nautilus_dnd_get_preferred_action()`
  would be the smallest safe change.
- In the sidebar, a drag held over an app's bookmark still shows the app's
  contents. It does not launch it.
- When Quick Look offers Cmd-Y, or a space it declined, to its delegate, the
  panel is closed (`orderOut:`) synchronously while it is still dispatching
  that key. Normally the File menu takes Cmd-Y first. Checklist L covers the
  real panel.
- The remaining items under "Packages are still folders…" (now "Packages
  as single items: what is left") in the limitations, and the manual
  checklists J, K, L and M.

| Command (2026-10-13, macOS 26.5.1 arm64) | Exit | Result |
|---|---|---|
| `git cherry-pick` of `be88277`, `148772d` (clean), `954d337`, `445f07d` (patch and this file resolved as above) | 0 | |
| `tools/setup-nautilus-tree.sh --check` | 0 | 86 patched paths match the regenerated patch |
| `tools/setup-nautilus-tree.sh` (build and install) | 0 | no warnings in the changed files |
| every `tools/test-*.sh`, 3 rounds, before the review fix | 0 | apps 10/10, Quick Look 19/19, volumes 6/6 in every round |
| `tools/test-macos-apps-archives.sh` with the drag-hover decision put back to `nautilus_file_is_directory()` | 1 | `drag-hover` fails on `Decision.app` |
| every `tools/test-*.sh`, 3 rounds, with the review fix | 0 | apps 11/11, Quick Look 19/19, volumes 6/6 in every round; worst volume event 59 ms after its command |
| `tools/setup-nautilus-tree.sh` from scratch in a second fresh worktree of `files-fixes` (new upstream fetch), then `--check` | 0 / 0 | 86 patched paths verified; `diff -rq` identical to the working tree |
| every `tools/test-*.sh` in that worktree, 3 rounds | 0 | apps 11/11, Quick Look 19/19, volumes 6/6 in every round; worst volume event 58 ms |
| apps and Quick Look test binaries under `libMainThreadChecker.dylib` | 0 / 0 | no reports (a probe creating an `NSView` off the main thread is reported) |
| `package/make-app.sh`, `package/bundle-dylibs.sh` (ad hoc), `codesign --verify --deep --strict` | 0 / 0 / 0 | ad hoc signature; the binary contains code from all three fixes (`nautilus_macos_open_packages`, `nautilus_macos_preview_toggle`, `nautilus_macos_volume_monitor_refresh`, `nautilus_list_base_file_opens_on_drag_hover`); not launched |
| after all runs | | no test app registered with LaunchServices or running, no test disk image or WebDAV share mounted |

## Follow-ups to the three fixes (2026-10-13)

The volume verifier, the apps fixer and the merge reviewer reported four
defects left by the fixes above. All four are fixed on `files-fixes`, each
with a displayless test that fails when the fix is taken out. The screens
themselves (rows, highlights, dialogs) are in checklist N.

### Volumes leaving together showed an extra row

**What happened** (found by the volume verifier). When two volumes unmounted
at the same moment (a disk with two partitions, or two disk images ejected
together), every sidebar showed an extra "Macintosh HD" row for about 50 ms
and rebuilt twice. The "Mounted volumes" row at the top promised one rebuild
per real change.

**Root cause.** `nautilus_macos_get_mounted_volumes()` asks NSFileManager for
the mounted volumes and their names in one call. NSFileManager reads the
mount list first and the resource values after, so a volume that unmounts in
between is still listed, but its mount point is by then an empty folder on
the startup disk: the name read for it is the startup disk's ("Macintosh
HD"), and `statfs` either reports the startup disk's Data volume
(`f_mntonname` "/System/Volumes/Data", whose fs id the entry then carried) or
fails because the folder was removed meanwhile (no fs id). The monitor paired
that entry with the real volume by mount point and emitted `volume-changed`,
so every sidebar rebuilt with the wrong row, then again when the next scan
dropped it. Calling the unmodified function in a loop while a two-partition
image and then two images were detached gave 4 wrong entries in each of 3
runs (2000–2900 scans per run), for example `/Volumes/SZF Pair 9c4bb listed
as "Macintosh HD" (fs id none)`. Through the monitor, the same detaches
produced `volume-changed … -> "Macintosh HD" (fs id none)` in 2 of 6 runs.
A plain probe of NSFileManager (about 15 µs per call) caught 2–4 such entries
during every single detach, so the window is short but always there.

**Fix** (`src/nautilus-macos-volumes.m`). Each entry is checked last, after
its name and flags were read: it is kept only if `statfs` succeeds and names
that path as the mount point. If the volume is mounted then, it was mounted
when its name was read. The comparison also accepts the path as NSFileManager
listed it, because standardizing drops "/private": a volume mounted at
"/private/var/folders/…" is listed as "/var/folders/…", and a plain comparison
would have dropped that real volume. The fs id now comes from the same
`statfs`, so it is never NULL (header comment updated). Both spellings it
compared were decomposed, which dropped volumes whose mount point the kernel
spells precomposed; see "Precomposed mount point names" below.

| Test (`tools/test-macos-volumes.sh`) | Checks |
|---|---|
| `/macos-volumes/enumeration/simultaneous-detach` | a thread calls `nautilus_macos_get_mounted_volumes()` in a loop (about 2000 scans while detaching) while a two-partition image (one partition named "SZF Pär 文件 …") is detached, then two more images with two `hdiutil detach` at once; every entry at a test mount point must carry that volume's own name and fs id |
| `/macos-volumes/enumeration/custom-mount-point` | a volume mounted in the scratch folder (`/private/var/folders/…`) is still listed once, with its fs id |
| `/macos-volumes/monitor/simultaneous-detach` | the shared monitor while the two-partition image and two images are detached by three commands at once: each volume is removed once, as itself (name and fs id), within 1 s; no `volume-added` or `volume-changed` for them; at every `changed` the snapshot holds no wrong row; at least one and at most one `changed` per volume that left |

With the old function the first test fails in 3 of 3 runs and the third in 2
of 6.

### Drops onto apps moved the files into the bundle

**Root cause.** The drop targets for items (a file or folder in the grid or
list view, `on_item_drag_enter()` and `on_item_drop()` in
`nautilus-list-base.c`; a sidebar row, the window's `drag-action-requested`
and `drag-perform-drop` handlers in `nautilus-window.c`) apply
`nautilus_dnd_get_preferred_action()`, whose rule is that a writable folder
takes the files. An app bundle is a writable folder, so a file dropped onto
TextEdit was moved into `TextEdit.app` (or copied, across volumes). The
test confirms that these folder rules still accept such a drop.

**Fix** (`src/nautilus-dnd.c`, `src/nautilus-list-base.c`,
`src/nautilus-window.c`, `src/nautilus-macos-packages.m`, bridge section W16).

- `nautilus_dnd_get_item_drop()` says what an item does with a drop: an app
  opens the files, another package (an `.rtfd` document, a Photos library,
  a `.bundle`) refuses them, anything else keeps upstream's rules. It uses the
  package kind cached on the file; a sidebar row's file is often not loaded,
  and then LaunchServices is asked about its location directly.
- `nautilus_dnd_get_item_preferred_action()` offers copy over an app (the
  files stay where they are) only when the app declares that it opens every
  dropped file (`LSCanURLAcceptURL` with default acceptance, the check Finder
  makes before it highlights an app) and every file is local and not the app
  itself; otherwise 0. An item that refuses is not highlighted, and the drop
  goes to the folder the view shows, as in Finder. Text and images dropped
  onto an app are refused. LaunchServices takes about 0.1 ms per file
  (measured with TextEdit, Calculator and a test app), and the sidebar asks
  on every pointer motion, so the last answer was kept for a second, keyed
  on the app and every dropped URI (now one answer per app; see "Precomposed
  mount point names" below).
- On drop, `nautilus_dnd_open_with_app()` passes the local files to the new
  `nautilus_macos_open_with_application()`: `-[NSWorkspace openURLs:
  withApplicationAtURL:configuration:completionHandler:]`, asynchronous, with
  `promptsUserIfNeeded` off as for launching (Gatekeeper still asks before a
  downloaded app first opens). The result comes back on the main context as
  an idle source. A failure is shown in Nautilus's dialog, "Unable to open
  “notes.txt” with “TextEdit.app”" (or "Unable to open 3 items with …") with
  macOS's explanation; a declined prompt shows nothing. A path that is not an
  app is refused without asking NSWorkspace.
- A view's background, the path bar and tabs stand for the folder being
  shown and keep the folder rules, also inside an app shown with Show Package
  Contents, where Finder copies dropped files into the package too.

The test app (`Drop Target.app`, the existing marker executable) exports its
own type for `.szfdrop` and declares it as a document type with rank
Alternate. LaunchServices ignored a document type that named only the
extension: `LSCanURLAcceptURL` said no. The test registers the app with
`lsregister -f` before asking, and unregisters it afterwards with the others.

### A drag held over an app's sidebar bookmark showed its contents

**Root cause.** `hover_timer()` in `nautilus-sidebar.c` opens any row a drag
rests on for `HOVER_TIMEOUT` (500 ms). The file view's timer got
`nautilus_list_base_file_opens_on_drag_hover()` in the merge review; the
sidebar's did not. An app's row accepted drops as a folder, and still does
when the app opens the dragged files, so it stays active during a drag and
the timer showed its contents.

**Fix.** The sidebar's timer skips rows for which
`nautilus_dnd_item_opens_on_drag_hover()` is false: apps and other packages,
the same rule as the file view, also when the row's file is not loaded.

### List view: expanders and "folders first"

**Root cause.** `create_model_func()` in `nautilus-view-model.c` gives every
directory a child model, which is what makes GtkTreeListModel show an
expander, and `nautilus_file_compare_for_sort_internal()` sorts every
directory first when folders come first. Apps and packages are directories.

**Fix.** Both skip packages (`nautilus_file_is_macos_package()`), so a package
has no expander and sorts by name among the files, as with Finder's "Keep
folders on top". A folders-first sort asks for every comparison, so the
package-kind cache in `nautilus-file.c` is now checked against the file's
name (by identity), link target and modification time, without building its
path; the folder does not matter, since what an item is depends on its own
name and contents.

### Tests

New in `test/displayless/test-macos-apps-archives.c`:

| Test | Checks |
|---|---|
| `/macos-apps-archives/packages/drop-decision` | apps (incl. a link to one, a non-ASCII name, an empty `.app`) open dropped files; `.rtfd`, `.bundle`, `.photoslibrary`, `.pages` refuse; folders, `.framework`, dotted and non-ASCII folders, a text file and a zip keep the folder rules; the same for files not loaded. The drop target app takes one or two of its documents and a drop whose files are not known yet (copy), but not a text file, its document plus a text file, itself or a web address (0); an app declaring no documents and an empty `.app` take nothing; packages take nothing; folders get exactly the folder rules' action |
| `/macos-apps-archives/packages/sidebar-drag-hover` | apps, a link to one, packages: no opening on hover; folders: opening; also for files not loaded |
| `/macos-apps-archives/packages/drop-open-with` | `nautilus_dnd_open_with_app()` hands both documents (one named "Ünïcode 文件 2.szfdrop") to the throwaway app, which records them; the app itself and a web address in the drop are left out; the documents keep their place and contents and the bundle's file list is unchanged; a drop with nothing local opens nothing. The bridge reports once, on the main thread through the main context; a plain folder ("“Plain Folder” is not an app."), a missing app ("no longer exists") and a damaged app (macOS: "could not be launched because it is corrupt") are errors, and the folder is unchanged |
| `/macos-apps-archives/packages/list-view-expanders` | a tree-mode `NautilusViewModel`: apps and packages are not expandable, folders (incl. `.framework`) are, files are not |
| `/macos-apps-archives/packages/folders-first-sort` | folders first: "Zoo Folder" and "Zz.framework" before "Zebra.app"; "alpha.txt" before "Zebra.app" and "Zebra Notes.rtfd"; reversed keeps folders first and reverses the rest; without folders first, names alone |

Taking each piece out (`run-mutant.sh` in the follow-up worktree's scratch
folder: one replacement, run the script, put the file back) makes the
matching test fail, exit 1:

| Put back to the old behaviour | Fails |
|---|---|
| `nautilus_dnd_get_item_drop()` always "folder rules" | `drop-decision`: "drop onto Decision.app: default (folder rules), expected open with the app" |
| the app accepts any file | `drop-decision`: "dropping a text file onto Drop Target.app: action 1, expected 0" |
| the sidebar opens every row on hover | `sidebar-drag-hover` |
| packages get a child model | `list-view-expanders` |
| packages sort as folders | `folders-first-sort`: "sort/Zoo Folder should sort before sort/Zebra.app" |

| Command (2026-10-13, macOS 26.5.1 arm64) | Exit | Result |
|---|---|---|
| `patches/macos-port-full.patch` regenerated the way the earlier ones were (new files intent-to-add in a scratch index, `git diff`, blank context lines empty), then `tools/setup-nautilus-tree.sh --check` | 0 | 87 patched paths; compared with `7dd3f36` exactly 12 entries differ: the 10 source files above (`nautilus-view-model.c` is new in the patch) and the two tests |
| the same for the first commit, `cacd23d` (volume fix only), plus building the volume test | 0 / 0 | 86 patched paths |
| `tools/setup-nautilus-tree.sh` (build and install) | 0 | no warnings in the changed code (the build's remaining warnings, in `nautilus-window.c` and `nautilus-file-operations.c`, were there at `7dd3f36`) |
| the new volume tests built against the old `nautilus_macos_get_mounted_volumes()` | 134 | enumeration test failed 3 of 3 runs; monitor test failed 2 of 6 runs (exit 0 in the other 4) |
| the five mutants above | 1 each | the matching test fails |
| every `tools/test-*.sh`, 3 rounds | 0 | apps 16/16, Quick Look 19/19, volumes 9/9 in every round; worst volume event 61 ms after its command; simultaneous detach: 2–3 `changed` for 4 volumes, no wrong row; volume listing loop: 1979–2621 scans while detaching, 0 wrong entries |
| `tools/setup-nautilus-tree.sh` from scratch in a fresh worktree of `d3a387f` (new upstream fetch from GitLab), then `--check` | 0 / 0 | 87 patched paths verified; `diff -rq` (without `.git`) identical to the working tree |
| every `tools/test-*.sh` in that worktree, 3 rounds | 0 | apps 16/16, Quick Look 19/19, volumes 9/9 in every round; worst volume event 57 ms; volume listing loop: 1327–2374 scans while detaching, 0 wrong entries |
| apps test binary under `libMainThreadChecker.dylib` | 0 | 16/16, no reports (a probe creating an `NSView` off the main thread is reported) |
| `package/make-app.sh`, `package/bundle-dylibs.sh` (ad hoc, `MAC_SIGN_IDENTITY` unset), `codesign --verify --deep --strict` | 0 / 0 / 0 | ad hoc signature; the binary contains `nautilus_macos_open_with_application`, `nautilus_macos_application_accepts_files`, `nautilus_dnd_open_with_app`, `nautilus_dnd_get_item_drop` and `nautilus_dnd_item_opens_on_drag_hover`; not launched |
| after all runs | | no test app registered with LaunchServices or running, no test disk image or WebDAV share mounted |

Not covered automatically: the sidebar rows during a real eject, the
highlight and the drop itself in a real drag (from Finder too), the error
dialog, real apps from `/Applications`, the hover timers, and the expanders
and sort order on screen. See checklist N.

## Precomposed mount point names (2026-10-13)

The verifier of the follow-ups found that the half-unmounted fix (`cacd23d`)
left out every volume whose mount point name is spelled with precomposed
characters, so such a volume never appeared in any sidebar: a network share
named "Données" or "공유", for example. The same review found two minor
points in the drop code; both are handled here too.

### Volumes with precomposed names were missing

**Root cause.** `nautilus_macos_get_mounted_volumes()` keeps a listed volume
only if `statfs` names its path as the mount point (see "Volumes leaving
together showed an extra row" above). It compared `f_mntonname` with two
spellings of the path, the standardized one and the one NSFileManager
listed, both made by `-[NSString fileSystemRepresentation]`, which
decomposes accented and Hangul characters (NFD: "é" becomes "e" plus a
combining accent, a Hangul syllable becomes its letters). The kernel keeps a
mount point as its folder was created. NetFS creates a share's mount point
from the share name as given, so "SZF Partagé 공유" stays precomposed (NFC)
in the mount table, and so does a folder created with a precomposed name.
`statfs` itself succeeds (APFS finds a name in either form), but no spelling
matched byte for byte, and the volume was skipped on every scan. Probed on a
volume mounted at a folder named "Données NFC 공유":

| Spelling | "é" | "공" |
|---|---|---|
| `f_mntonname` (the mount table) | `c3 a9` (NFC) | `ea b3 b5` (NFC) |
| `-[NSURL fileSystemRepresentation]` of the listed URL | `c3 a9` | `ea b3 b5` |
| `-[NSString fileSystemRepresentation]` of its path, standardized or not | `65 cc 81` (NFD) | `e1 84 80 e1 85 a9 e1 86 bc` (NFD) |

Disk images formatted HFS+ or APFS were not affected: Disk Arbitration
creates their mount points under `/Volumes` decomposed (probed with volumes
named "Données"), which is why the existing tests, with a partition named
"SZF Pär 文件 …", passed. FAT and exFAT disks were not measured (FAT refuses
such names, and creating an exFAT image was not permitted here); the fix
covers them whichever form their mount point has.

**Fix** (`src/nautilus-macos-volumes.m`). The comparison also accepts
`-[NSURL fileSystemRepresentation]` of the listed URL, which keeps the bytes
NSFileManager read from the mount table. The two decomposed spellings stay,
for "/private" (see above) and for mount points the kernel spells
decomposed. The volume's path in the list is unchanged (decomposed, as
before `cacd23d`), so the sidebar rows, ejecting and the monitor's pairing
by mount point see the same paths as before.

**Tests** (`tools/test-macos-volumes.sh`, now 12):

| Test | Checks |
|---|---|
| `/macos-volumes/enumeration/custom-mount-point-precomposed` | a volume mounted in a scratch folder named "Données NFC 공유", written precomposed: the mount table spells it precomposed (asserted, so the case is really exercised); listed once, with its fs id; the shared monitor adds it once within 1 s and the merged list has one row for it; after the detach it is removed once and has no row |
| `/macos-volumes/enumeration/custom-mount-point-decomposed` | the same with "Données NFD 공유" written decomposed, which the mount table keeps decomposed |
| `/macos-volumes/enumeration/custom-mount-point` | the existing test ("mount point"), now with the monitor checks too |
| `/macos-volumes/monitor/network-volume-precomposed` | a second throwaway WebDAV share, "SZF Partagé 공유 <n>" written precomposed, mounted through NetFS like the existing network test: the mount table spells its mount point precomposed (asserted); added once within 1 s, one row in the merged list by path and by name; after the unmount it is removed once and has no row |

The test now compares volume names and paths in one normalization form in
its recorder and merged-list counts, so one folder listed under two
spellings would count twice. The script serves both shares from one Apache
and unmounts any leftover share by server address, which also catches the
precomposed one after an aborted run (it did after the failing runs below).

### Drop answers kept per app

**What the review found.** `app_accepts_dropped()` kept only the last
answer. The sidebar asks about every row on each pointer motion
(`update_possible_drop_targets()` emits `drag-action-requested` for each
row), so with two app bookmarks the answers replaced each other and
LaunchServices was asked on every motion for every app row.

**Fix** (`src/nautilus-dnd.c`, `src/nautilus-sidebar.c`,
`src/nautilus-list-base.c`). The answers for the drag in progress are kept
in a small map, one per app path, each for a second. The map is dropped
when other files are dragged and when the drag ends:
`nautilus_dnd_item_drag_ended()` is called when a drag leaves the sidebar or
ends there (`drag_leave_callback()`, `stop_drop_feedback()`), and when it
leaves or drops on an item in the file view (`on_item_drag_leave()`,
`on_item_drop()`).

**Test** (`tools/test-macos-apps-archives.sh`, now 17):
`/macos-apps-archives/packages/drop-answers-cached` asks about three app
rows (Drop Target.app and a second throwaway app that open `.szfdrop`
documents, and Decision.app, which opens none) for one dropped document,
then moves the document away; asked now, LaunchServices refuses it
(checked). Five rounds of the three rows in turn, 1–2 ms later, keep their
first answers. After `nautilus_dnd_item_drag_ended()` the next answer is a
fresh "no"; with the document back, that "no" is kept within the second and
replaced by "yes" a second later; a different dropped file is asked about
at once, and so is the first drop when it comes back.

| Put back | Fails |
|---|---|
| `180dd8c`'s single remembered answer (with a `nautilus_dnd_item_drag_ended()` that does nothing) | `drop-answers-cached`: "dropping a document (kept answer) onto Drop Target.app: action 0, expected 1" |
| answers never expire | `drop-answers-cached`: "dropping a document that is back (a second later) onto Drop Target.app: action 0, expected 1" |
| `nautilus_dnd_item_drag_ended()` does nothing | `drop-answers-cached`: "dropping a document that was moved away onto Drop Target.app: action 1, expected 0" |
| answers not reset for other files | `drop-decision`: "dropping a text file onto Drop Target.app: action 1, expected 0" |

### `nautilus-dnd.h`

Every macOS-only declaration in `nautilus-dnd.h`, including the
`NautilusDndItemDrop` enum, was already inside its `#ifdef __APPLE__` block,
like the definitions in `nautilus-dnd.c`, and the new
`nautilus_dnd_item_drag_ended()` is there too. `unifdef -U__APPLE__
src/nautilus-dnd.h` differs from upstream's header only by one blank line,
and the callers in `nautilus-window.c`, `nautilus-list-base.c`,
`nautilus-sidebar.c` and `nautilus-files-view.c` are guarded as well. No
change was needed.

### Evidence

| Command (2026-10-13, macOS 26.5.1 arm64) | Exit | Result |
|---|---|---|
| the new and changed volume tests, one run each, built against `180dd8c`'s `nautilus-macos-volumes.m` (blob `faac841`, taken from its patch) | 134 / 134 / 0 / 0 / 0 | `custom-mount-point-precomposed`: "assertion failed (listed == 1): (0 == 1)"; `network-volume-precomposed`: "assertion failed (recorder.added == 1): (0 == 1)"; `custom-mount-point-decomposed`, `custom-mount-point` and `network-volume` pass, as expected |
| the same tests with the fix | 0 | all pass; the mount table spells both precomposed cases precomposed and the decomposed case decomposed |
| the four drop-cache mutants above | 1 each | the matching test fails |
| `patches/macos-port-full.patch` regenerated the way the earlier ones were (new files intent-to-add in a scratch index, `git diff`, blank context lines empty), then `tools/setup-nautilus-tree.sh --check` | 0 | 87 patched paths; compared with `180dd8c` exactly 7 entries differ: `nautilus-macos-volumes.m`, `nautilus-dnd.c`, `nautilus-dnd.h`, `nautilus-sidebar.c`, `nautilus-list-base.c` and the two tests |
| `tools/setup-nautilus-tree.sh` (build and install) | 0 | no warnings in the changed files; the build's other warnings (`nautilus-window.c`, `nautilus-file-operations.c`, `nautilus-module.c`) are in code this change does not touch |
| every `tools/test-*.sh`, 3 rounds | 0 | apps 17/17, Quick Look 19/19, volumes 12/12 in every round; worst volume event 60 ms after its command; volume listing loop: 1049–2110 scans while detaching, 0 wrong entries; simultaneous detach: 2–3 `changed` for 4 volumes |
| `tools/setup-nautilus-tree.sh` from scratch in a fresh worktree of `d7f1481` (new upstream fetch from GitLab), then `--check` | 0 / 0 | 87 patched paths verified; `diff -rq` (without `.git`) identical to the working tree |
| every `tools/test-*.sh` in that worktree, 3 rounds | 0 | apps 17/17, Quick Look 19/19, volumes 12/12 in every round; worst volume event 61 ms; volume listing loop: 1236–2323 scans while detaching, 0 wrong entries |
| `package/make-app.sh`, `package/bundle-dylibs.sh` (ad hoc, `MAC_SIGN_IDENTITY` unset), `codesign --verify --deep --strict` | 0 / 0 / 0 | ad hoc signature; the binary contains `nautilus_dnd_item_drag_ended`; not launched |
| after all runs | | no test disk image or WebDAV share mounted, no test app registered with LaunchServices or running; the fresh worktree removed |

Not covered automatically: a real NAS or SMB share with such a name, the
sidebar rows themselves, and the highlight over several app bookmarks in a
real drag. See checklist N.

## Toolbar search button searches the current folder (2026-10-13)

Owner report: clicking the search icon (the magnifier at the right of the
toolbar) starts "Search Everywhere"; it should search the current folder and
its subfolders, like Cmd-F.

### What the button and Cmd-F did

- **Cmd-F** is the menu bar's Find item, `slot.focus-search` with `<Meta>f`
  (the macOS menu in `nautilus-application.c`; the tab also binds Ctrl-F).
  It turns the tab's `search-visible` action on and selects the search text.
  The search field's location is bound to the tab's location
  (`nautilus-window-slot.c`), so the query it builds (`create_query()` in
  `nautilus-query-editor.c`) is rooted at the folder the tab shows. The files
  view runs it in a search directory with the folder engine (the directory's
  own listing, a recursive walk, and Spotlight on local disks), and
  subfolders are searched as Preferences ▸ Search in Subfolders says
  (`recursive-search`; the default, "On This Device Only", searches
  subfolders on this Mac's disks, and network shares only when it is set to
  "All Locations").
- **The magnifier** was `global_search_button`, a toggle on
  `slot.search-global`. `action_search_global()` drops the location from the
  query, shows the "Search Everywhere" page and switches the search
  directory to the global engine.
- Upstream's own folder search toggle (a folder with a magnifier, "Search
  Current Folder") sat next to the path bar and did the Cmd-F search, but it
  was easy to miss beside the path, and the magnifier is where Finder has its
  search field.

**Root cause.** Upstream puts its Search Everywhere toggle in the sidebar
header, top left, beside the "Files" title. The macOS window chrome change of
2026-07-16 gave that header to the window controls and moved the toggle to the
end of the content toolbar, Finder's search position, with its magnifier icon
and its `slot.search-global` action unchanged. The control people reach for
to search therefore searched everywhere.

### Fix

- `nautilus-toolbar.blp`: the end button, now `end_search_button`, is a
  toggle on `slot.search-visible` with its pressed state bound to the tab's
  `search-visible`: the same action and binding as upstream's "Search
  Current Folder" toggle. Its tooltip and accessible label are "Search
  Current Folder", the words upstream uses for that toggle and for Cmd-F in
  the shortcuts window. Where the end button is shown, the toggle next to the
  path bar (`search_button_stack`) is hidden, so the toolbar has one folder
  search button, not two.
- `nautilus-toolbar.c`: the port's `show-global-search-button` property is
  now `show-end-search-button` (off by default; the file chooser's toolbar
  does not set it). `nautilus-window.blp` sets it; the comments say what the
  button does.
- No C behaviour changed: Cmd-F, the tab's actions and the menu bar are as
  they were. Search Everywhere stays in the menu bar (Find ▸ Search
  Everywhere, ⇧⌘F; Ctrl-Shift-F in the tab) and on the "No Results Found"
  page of a folder search. The blueprints have no preprocessor; the line
  added to upstream's toolbar blueprint does nothing unless the property is
  set, so `search_button_stack` behaves as upstream wherever the end button
  is not shown.

**Behaviour now.** A click opens the search field in the current tab,
rooted at the folder it shows, with the keyboard in the field; the button
stays pressed while that tab shows a search, and a second click closes it
(the folder comes back with the selected result still selected), as the
upstream toggle does. Cmd-F opens the same search; pressed again while the
search is open, it selects the text and leaves the search open, as before.
While Search Everywhere is open the button also looks pressed (the tab's
search is visible), and a click closes that search, like Escape; a second
click then searches the folder.

**Where there is no folder**, the button does what Cmd-F does there, which
is upstream's rule: the query is rooted at the place the tab shows and the
search narrows what that place lists, without going into subfolders of the
listed items or anywhere else. On macOS the only such place a tab can show
is Starred: Recent and Other Locations are hidden from the sidebar (no GVfs),
and Trash opens in Finder. The test checks the rule for Recent, Starred and
Other Locations anyway. Search results themselves keep the real folder as
the root (`nautilus_query_editor_set_location()` resolves the search
directory to its folder).

### Tests

`nautilus/test/displayless/test-macos-search-button.c`, run by
`tools/test-macos-search-button.sh`, which configures `build-tests/` with
`-Dtests=headless` like the other scripts and builds only that test and the
GSettings schemas. Opening a GTK display on macOS makes the process a
foreground app (`_gdk_macos_display_open()` calls `TransformProcessType` and
activates it), so the test creates no widget and checks the route in two
halves:

| Test | Checks |
|---|---|
| `toolbar/end-button-searches-current-folder` | In the toolbar UI the app loads (compiled from the blueprint into the nautilus resource): `end_search_button` is a `GtkToggleButton` on `slot.search-visible`, the same action and the same `active` binding (`search-visible` of the tab) as upstream's `search_button`; tooltip and accessible label "Search Current Folder"; shown by `show-end-search-button` |
| `toolbar/one-folder-search-toggle` | no toolbar object uses `slot.search-global`; exactly two use `slot.search-visible`; `search_button_stack` is hidden while `show-end-search-button` is set (`invert-boolean`) |
| `window/shows-end-button` | the window's toolbar sets `show-end-search-button`, has no `show-global-search-button`, and nothing in the window UI uses `slot.search-global` |
| `search/rooted-and-recursive` | the query the search field builds for a tab showing a real throwaway folder (folder file loaded, as the tab holds it) is not global and is recursive under the default settings; run through a real search directory watched like the files view watches it, it finds the matches in the folder, in a subfolder and two levels down, and not a match in a sibling folder or a non-matching file |
| `search/from-results-keeps-folder` | a search directory reports the folder as its search location |
| `search/places-without-folder` | for `recent:///`, `starred:///` and `x-network-view:///` the query stays rooted at that place (never global) and the place has its own listing for the search to narrow |

Warnings are not fatal in this test, because the engine warns that
Localsearch is missing on macOS (the app logs the same); any other warning is
counted and fails the search tests.

### Evidence

| Command (2026-10-13, macOS 26.5.1 arm64) | Exit | Result |
|---|---|---|
| `tools/test-macos-search-button.sh` with the end button put back on `slot.search-global` | 1 | `end-button-searches-current-folder`: `("slot.search-global" == "slot.search-visible")` |
| `patches/macos-port-full.patch` regenerated the way the earlier ones were (new files intent-to-add in a scratch index, `git diff`, blank context lines empty; the same recipe reproduces `363b70d`'s patch byte for byte from its tree), then `tools/setup-nautilus-tree.sh --check` | 0 | 88 patched paths; compared with `363b70d` exactly 5 entries differ: `nautilus-toolbar.c`, `nautilus-toolbar.blp`, `nautilus-window.blp`, `test/displayless/meson.build` and the new test |
| `tools/setup-nautilus-tree.sh` (build and install) | 0 | no warnings in the changed files; the build's other warnings (`nautilus-window.c`, `nautilus-file-operations.c`, `nautilus-module.c`) are in code this change does not touch |
| every `tools/test-*.sh`, 3 rounds | 0 | apps 17/17, Quick Look 19/19, search button 6/6, volumes 12/12 in every round; worst volume event 61 ms after its command |
| `tools/setup-nautilus-tree.sh` from scratch in a fresh worktree of `8d70be5` (new upstream fetch from GitLab), then `--check` | 0 / 0 | 88 patched paths verified; `diff -rq` (without `.git`) identical to the working tree |
| every `tools/test-*.sh` in that worktree, once | 0 | apps 17/17, Quick Look 19/19, search button 6/6, volumes 12/12; worst volume event 60 ms |
| `package/make-app.sh`, `package/bundle-dylibs.sh` (ad hoc, `MAC_SIGN_IDENTITY` unset), `codesign --verify --deep --strict` | 0 / 0 / 0 | ad hoc signature; the binary's resource contains `show-end-search-button`; not launched |
| after all runs | | no test disk image or WebDAV share mounted, no test app registered with LaunchServices or running; the fresh worktree removed |

Not covered automatically: the button on screen (pressed state, tooltip,
VoiceOver, the search field taking the keyboard) and Starred in a real
window. See checklist O.

## Shenzhen Friends packaging (2026-10-13, wave 6a)

Shenzhen Files.app now carries the Shenzhen Friends helper built from
shenzhen-pdf, as `docs/friends-integration.md` § 3.2 and § 3.4 propose.
Nothing in the app starts it yet: the Nautilus host adapter and the GTK views
are wave 6b. Branch `friends-host`, from `files-fixes` (`363b70d`).

| Piece | What it does |
|---|---|
| `friends.lock` | `url`, `commit` (`8f3d7a755`, shenzhen-pdf `friends/m1`) and `helper_build_number` `26101101`: that commit's own helper number, from its `MAC_VERSION` 26.10.11 and `MAC_BUILD` 1, never Files' release date, because the running helper hands over to the embedded one with the higher number |
| `tools/friends-lock.sh` | Parses the lock (never sources it) and names the checkout, for the three scripts below |
| `tools/setup-friends.sh` | Idempotent. Fetches exactly the pinned commit into `friends-src/` (gitignored, detached), or uses `SZF_FRIENDS_ROOT`; either must be detached at the pin with no local changes, so a working copy on a branch is refused. Refuses a lock whose number disagrees with the commit's `MAC_VERSION`/`MAC_BUILD`. Builds `friends-helper-bundle` ad hoc with the lock's version keys (remaking only the bundle step when an earlier build carries other ones), and `friends-gtk-lib` once the pinned commit has `portable/friends/gtk/`; this wave it says it skipped it. `--check` verifies and changes nothing |
| `package/make-app.sh` | Refuses to start unless `setup-friends.sh --check` passes; copies the helper into `Contents/Helpers/`, drops its own animal set, stamps `CFBundleShortVersionString` 26.10.11 and `CFBundleVersion` = `SZFriendsBuildNumber` = 26101101 from the lock; copies `manifest.json`, `svg/*.svg`, `pdf/*.pdf` and `Acknowledgements.txt` into `Contents/Resources/Friends/`; ends with the Friends bundle check |
| `package/bundle-dylibs.sh` | Checks that the helper links only `/usr/lib` and `/System/Library`, signs it on its own line after the libraries and before `MacOS/nautilus` and the app (same flags as the app), and ends with the check in `--signed` mode |
| `package/check-friends-bundle.sh` | ShenzhenPDF's `MAC_FRIENDS_BUNDLE_CHECK` for this bundle: identifier `com.intuition.shenzhenfriends`, version keys, minimum macOS equal to the app's, no animal set in the helper, animal set and acknowledgements identical to the pinned checkout, usage strings and `_szfriends._tcp` in both Info.plists, system libraries only; `--signed` adds `codesign --verify --strict` on the helper and `--deep --strict` on the app |
| `package/Info.plist.template` | `NSLocalNetworkUsageDescription` ("Shenzhen Friends uses your local network to find people near you and send them messages and files."), `NSBluetoothAlwaysUsageDescription` ("Shenzhen Friends uses Bluetooth to find people near you, and to reach them when Wi-Fi can't."), `NSBonjourServices` `_szfriends._tcp`. macOS names Shenzhen Files in these prompts because it starts the helper, so the strings name the feature as Files' Settings will |
| README, LICENSE, `package/README.md` | Build step, the GPL-3.0 combination and the Friends notices |

**Tests.** `tools/test-setup-friends.sh` runs the script against a small
fake shenzhen-pdf (fetched over `file://`, its `friends-helper-bundle` a
stand-in that logs each build): malformed locks refused before any fetch; a
failed fetch leaves no `friends-src/` or staging directory; the first run
fetches the pin detached and builds once, ad hoc, with the lock's keys; a
rerun with the URL unreachable fetches and builds nothing; `--check` builds
nothing and fails on a missing helper; a helper built with other keys is
remade once; an existing `friends-src/` at another commit is refused and
left alone; a lock number that disagrees with the commit is refused;
`SZF_FRIENDS_ROOT` at another commit, on a branch, with an edited or an
untracked file, not a checkout, or below its top is refused without
building; the GTK views library is built when the commit has
`portable/friends/gtk/`. `package/test-friends-bundle.sh` packages the app,
checks it, and plants one defect per copy (helper build number, identifier,
minimum macOS, the app's Local Network string and Bonjour service, the
helper's Bluetooth string, its own animal set, a missing animal, a stale
manifest, edited acknowledgements, a non-system library, a file added after
signing); each must fail the check, and `bundle-dylibs.sh` must stop on the
non-system library.

| Command (2026-10-13, macOS 26.5.1 arm64, in the `friends-host` worktree) | Exit | Result |
|---|---|---|
| `NAUTILUS_UPSTREAM=file://…/shenzhen-files/nautilus tools/setup-nautilus-tree.sh` | 0 | tree, configure, build, install in 18.5 s; fetched from the main checkout's tree instead of GitLab |
| `SZF_FRIENDS_ROOT=<detached shenzhen-pdf worktree at 8f3d7a755> tools/setup-friends.sh` | 0 | helper 26.10.11 (26101101); `friends-gtk-lib` skipped with its message |
| `tools/test-setup-friends.sh` | 0 | `SetupFriendsTests passed`, 3.4 s |
| 12 mutants of `setup-friends.sh` and `friends-lock.sh` (branch, untracked, commit, top-of-checkout and build-number checks removed, no `-W` remake, not ad hoc, no GTK build, `--check` building, number format, unknown key, staging left behind) | 1 each | the test names the failing case |
| `SZF_FRIENDS_URL=file:///Users/raph/Projects/shenzhen-pdf tools/setup-friends.sh` (fresh `friends-src/`) | 0 | fetch, checkout (369 MB with the build) and helper build in 10.9 s |
| the same with the URL unreachable | 0 | 0.3 s; nothing fetched, make had nothing to do |
| `package/test-friends-bundle.sh`, from the shenzhen-pdf worktree and then from `friends-src/` | 0, 0 | `FriendsBundleTests passed`, 33–35 s; 13 defects caught |
| 5 mutants of the packaging (no helper `codesign` line, helper keeps its animal set, no library check in `bundle-dylibs.sh`, no acknowledgements, another Bonjour type) | 1 each | the test fails |
| `codesign --verify --deep --strict --verbose=2 "dist/Shenzhen Files.app"` | 0 | app and helper ad hoc; helper `com.intuition.shenzhenfriends`, 26.10.11 / 26101101; app still 26.9.14 / 26091401 / `26.9.14-1`; 146 MB |
| shenzhen-pdf `portable/release/verify-mac-artifact.sh --friends-usage-keys` on that app | 0 | both Info.plists carry the strings and the Bonjour service |

The app was not launched, nothing was installed or published, and the
detached shenzhen-pdf worktree was removed. Not run: Developer ID signing
(the helper line then uses the hardened runtime and a timestamp, like the
app), the DMG, and the updater gates. The nested helper makes the first
release that carries it updater-affecting, so every gate in `AGENTS.md`
applies to it. `8f3d7a755` is not on GitHub yet, so a fresh
`tools/setup-friends.sh` without `SZF_FRIENDS_URL` or `SZF_FRIENDS_ROOT`
fails at the fetch until `friends/m1` is pushed.

## Shenzhen Friends host adapter (2026-10-13, wave 6b)

Shenzhen Files now shows Shenzhen Friends: a two-people button at the top
right of every window, just left of the main menu (moved in wave 6d, below),
and a Friends page in
Preferences. It is `patches/friends-host-adapter.patch`, applied after the
port patch so the port stays free of Friends, built against the GTK views
of the shenzhen-pdf commit in `friends.lock`. That is `363bf5153`, which
carries the views' pages (list, conversation, details, profile, Settings),
so the dropdown and the Settings section are filled. The results table
below is from the first build, against `ba8105288`, whose pages were still
empty frames; the wave 6c section after it was run against `363bf5153`.
`docs/friends-integration.md` § 3.3 lists what was built and § 3.6 what
was decided and what is still open.

| Piece | What it does |
|---|---|
| `meson_options.txt`, `meson.build` | `friends_root` (default empty: no Friends code at all). When set: the views' archive, json-glib and `-DNAUTILUS_FRIENDS=1`; configure stops when the path is relative, `macos_port` is off or the archive is missing |
| `src/nautilus-friends.c` | When Friends runs: at launch, while on, one worker thread sets the signing policy, reads the bundle and starts the helper; after the first window's first frame, one link for the process and one button per browser window; off: the link sends `disable` and removes the buttons; on again: they come back; shutdown frees the link without `disable` |
| `src/nautilus-friends-host.c` | The host description: `com.intuition.shenzhenfiles`, "Shenzhen Files" (also the "Show in" name), no in-place formats, `#` placeholder "Search selected files and this folder"; buttons into the window's toolbar; received files shown selected in their folder; Finder drops repaired before the first one |
| `src/nautilus-friends-items.c` | `#`: matching selected files first, then the folder's other matching files newest first, at most 30; regular files only, never a link (wave 6c), hidden files only when selected |
| `src/nautilus-friends-preferences.c` | The Friends page: the switch bound to `friends-enabled` (new key, on by default), the disclosure, and the views' section while Friends is attached |
| `src/nautilus-macos-friends.m` | The helper at `Contents/Helpers/Shenzhen Friends.app` and its version keys; `NAUTILUS_FRIENDS_HELPER` for development runs without a team; the Team ID and peer check for `szfriends_set_signing_policy()`, nothing when ad hoc |
| toolbar, window | `friends_slot`, shown only with a button in it; `show-friends-button` on in the browser window only. In wave 6b the slot sat right of the search button and left of the main menu; wave 6d moved the button next to the window buttons (below) |
| `tools/setup-nautilus-tree.sh` | Applies and verifies the adapter patch after the port patch (also on a tree made before it existed) and passes `-Dfriends_root` from `tools/friends-lock.sh` after `setup-friends.sh --check`; an existing `build/` must have the same `friends_root` |
| `tools/test-friends-adapter.sh` | The tests below |

**Tests.** `tools/test-friends-adapter.sh` builds `src/nautilus` without
`friends_root` (it must define no Friends symbol and not link json-glib) and
with it (it must define the views', the client library's and the adapter's
entry points), then runs two programs under a temporary `TMPDIR` it always
removes. `test/friends/test-nautilus-friends` needs no display, helper or
network: the host description field by field and accepted by the views'
`szfriends_gtk_link_new`; where received files go and that Open and Show do
the same; the lifecycle through counting fakes (spawn only at launch and only
while on, nothing before the first paint even when toggled, buttons for every
window after it, off and on again, closed windows forgotten, shutdown without
`disable`); `#` on a scratch folder loaded through `NautilusDirectory` (order,
query with case, accents and blanks, hidden files, a folder, a package, a
pipe, links into the folder and out of it, selected or not, and a dangling
link, the limit, the answer never synchronous and never after
cancellation); the bundle reader on scratch bundles (embedded and
development helpers, the override refused without permission, malformed
version keys); the signing policy on this test's own linker signature and the
peer check on its own audit token. `test-nautilus-friends-toolbar` opens
GDK's display behind the views' interposer (no Dock icon, no focus, no window
mapped) and puts real Friends buttons into real toolbars through a real link
with no helper: placement just left of the main menu, wide, narrow and dark,
`show-friends-button` off, the button gone after `link_stop (link, TRUE)` with
the empty slot hidden, back after a restart; the Preferences page's switch,
its binding both ways and its plain-text title; the views' section shown only
while attached. It renders seven PNGs.

| Command (2026-10-13, macOS 26.5.1 arm64, `friends-host` worktree, `SZF_FRIENDS_ROOT` = detached shenzhen-pdf worktree at `ba8105288`) | Exit | Result |
|---|---|---|
| `tools/setup-friends.sh` | 0 | helper 26.10.11 (26101101) and `libszfriends_gtk.a` |
| `NAUTILUS_UPSTREAM=…/shenzhen-files/nautilus tools/setup-nautilus-tree.sh --tree-only` on a fresh copy, then `--check` | 0, 0 | 97 patched paths; identical to the working tree |
| a tree with the port patch only: `--check`, then `--tree-only`, then `--check` | 1, 0, 0 | `--check` names the missing adapter patch; the default run applies it |
| an adapter file edited: `--check` and `--tree-only` | 1, 1 | names the file and blob; nothing touched |
| `tools/test-friends-adapter.sh` from empty build directories | 0 | 24 s; `test-nautilus-friends passed` (15 cases), `test-nautilus-friends-toolbar passed` |
| 28 mutants of the adapter (dropped checks in the host description, received files, `#` order, filters, matching, limit and timing, lifecycle conditions, bundle and verifier rules, the slot's placement and visibility, the switch's binding and markup, the settings section) | 27 fail, 1 passes | the one that passes removes the verifier's own token-length check, which Security.framework applies as well |
| `tools/setup-nautilus-tree.sh` | 0 | configure with `-Dfriends_root`, build, install |
| `package/make-app.sh`, then `package/bundle-dylibs.sh` (ad hoc) | 0, 0 | Friends bundle checks pass; `libjson-glib-1.0.0.dylib` bundled |
| `codesign --verify --deep --strict --verbose=2 "dist/Shenzhen Files.app"` | 0 | `com.intuition.shenzhenfiles`, ad hoc; `MacOS/nautilus` defines 191 `szfriends_gtk_*` symbols and the adapter's entry points |
| `package/test-friends-bundle.sh <scratch app>` | 0 | `FriendsBundleTests passed`, 28 s |

Nothing was launched, installed or published. The renders were checked by
eye: the button sits just left of the main menu in light, dark and narrow
bars, the bar without Friends keeps its spacing, and the Preferences page
reads correctly in both themes. Not covered automatically: the first-paint
hook and the buttons in real `NautilusWindow`s (a window needs a running
`NautilusApplication`), real Finder drops, and launch time with Friends on
and off; see checklist P.

## Shenzhen Friends host adapter fixes (2026-10-13, wave 6c)

Two fixes from the wave 6b reviews, built against shenzhen-pdf `363bf5153`:

- `#` no longer offers symbolic links. It used to follow a link to the file
  it points to and offer that file under the link's own name and kind, so a
  link named `Report.pdf` in the folder could send any file the person can
  read, from anywhere on the Mac, past the helper's refusal of links and the
  views' drop verdict (security review, medium). The adapter now looks at
  the file itself (`lstat`): a link is left out, selected or not, wherever
  it points, as the drop verdict and the helper do.
- The Preferences disclosure is two sentences, as in ShenzhenPDF: "… and
  when Shenzhen Files is open. It never sees your name, messages or files."
  With a comma, "when Shenzhen Files is open, never your name" read as one
  clause, and the reader could not tell what the server sees.

**Tests.** `/friends/items/order-and-filter` adds two links named like
documents (`Picked.pdf`, selected, and `Report.pdf`, not selected) to a file
in another scratch folder, next to the link into the folder and the
dangling link, and searches for links by name. The Preferences probe checks
the disclosure's exact words and that it is plain text. With the tests
changed and the fixes not yet made, both failed.

| Command (2026-10-13, macOS 26.5.1 arm64, `friends-host` worktree, `SZF_FRIENDS_ROOT` = clean shenzhen-pdf worktree at `363bf5153`) | Exit | Result |
|---|---|---|
| `tools/test-friends-adapter.sh`, tests changed, fixes not made (scratch build directories) | 1 | `order-and-filter` fails: `Picked.pdf` and `Report.pdf` offered with the outside file's path, `link-to-a` with `a.pdf`'s; the toolbar probe, run by hand, reports the disclosure |
| the same with the fixes | 0 | `test-nautilus-friends` OK (15 cases), `test-nautilus-friends-toolbar passed` |
| the committed patch regenerated from the unchanged tree (friends-integration.md § 3.3 says how) | 0 | byte for byte the committed patch, so the recipe is the one it was made with |
| `patches/friends-host-adapter.patch` regenerated after the fixes; `HEAD`, the port patch and the adapter patch applied to a scratch index | 0 | identical to `nautilus/`, nothing untracked |
| `tools/setup-nautilus-tree.sh --check`, then `tools/setup-nautilus-tree.sh` | 0, 0 | 97 patched paths; only the adapter's sources recompiled; installed |
| `tools/test-friends-adapter.sh` | 0 | as above, in the default build directories; 7 renders |
| `tools/test-macos-quicklook.sh`, `test-macos-apps-archives.sh`, `test-macos-volumes.sh` (`BUILD_TESTS` in a scratch directory) | 0, 0, 0 | no test disk image or share left mounted |
| `tools/test-setup-friends.sh` (without `SZF_FRIENDS_ROOT`: its cases set their own) | 0 | `SetupFriendsTests passed` |
| `package/make-app.sh`, then `package/bundle-dylibs.sh` (ad hoc) | 0, 0 | Friends bundle checks pass, before and after signing |
| `codesign --verify --deep --strict --verbose=2 "dist/Shenzhen Files.app"` | 0 | ad hoc, 146 MB; `MacOS/nautilus` defines 442 `szfriends_gtk_*` symbols and carries the new disclosure, not the old one; helper 26101101 |
| `package/test-friends-bundle.sh <scratch app>` | 0 | `FriendsBundleTests passed`, 26 s, 13 defects caught |

Nothing was launched, installed or published. The Preferences renders were
checked by eye in light and dark: the disclosure reads as two sentences in
three lines under the switch. The `#` picker itself still needs the real app
(checklist P).

## Shenzhen Friends button placement (2026-10-13, wave 6d)

The Friends button moved from the right end of the main header bar, beside
the main menu, to where the owner asked for it: right of the window buttons
(traffic lights), at the end of the sidebar's header bar, just before the
edge with the main view. While the sidebar is hidden (a narrow window
collapses the split view, which hides it), the button moves to the start of
the main header bar, right after the window buttons and the sidebar toggle,
and it comes back when the sidebar shows. The sidebar shown over the files
in a narrow window counts as shown: its header bar then covers the start of
the main one, so the button goes with the window buttons instead of staying
underneath. It is one widget moved between two places, so a window never
has two, and its badge, drop target and open popover move with it. This
replaces the wave 6b placement above.

The Preferences disclosure is no longer `dim-label` (3.2:1 on the light
page, under the 4.5:1 that body text needs). It is secondary text as the
Friends views draw it, the text colour at 70%: 4.9:1 in light, 8.3:1 in
dark. `friends.lock` now pins shenzhen-pdf `8a21840b6`; its helper build
number is still 26101101 (`portable/Makefile` has not changed since
`363bf5153`). The adapter patch's blank context lines lost their single
space, as in the port patch, so `git diff --check` is clean on it
(`docs/friends-integration.md` § 3.3 has the recipe).

| Piece | What it does |
|---|---|
| `src/nautilus-friends-placement.c` | `nautilus_friends_place_button`: follows the split view's `show-sidebar` and moves the window's button between a slot packed last in the sidebar's header bar and the toolbar's slot; each slot is shown only while it holds the button |
| window | the sidebar's header bar is now `sidebar_header_bar`; `nautilus_window_set_friends_button` and `_get_` go through the placement |
| toolbar | `friends_slot` moved to the bar's start, between the sidebar toggle and the history controls |
| `nautilus-application.c`/`.h` | the traffic-light chrome setup is public (`nautilus_application_setup_macos_window_chrome`), so the probe draws header bars as the app does |
| `src/nautilus-friends-preferences.c` | the disclosure at 70% opacity instead of `dim-label` |

**Tests.** `test-nautilus-friends-toolbar` now builds a window like
`nautilus-window.blp` (split view, sidebar header bar, `NautilusToolbar`,
the narrow breakpoint's setters) with the app's traffic-light chrome and
GTK-drawn window buttons, and gives the real views' button to the real
placement code. It checks, with the sidebar shown (wide and dark), hidden
(wide and dark), narrow with the sidebar hidden and shown over the files,
and wide again: exactly one place holds the button, it is right of the
shown window buttons, at the end of the sidebar's bar or right after the
sidebar toggle with the path bar after it, no empty slot shows, the drop
target is still on it, and the open popover is still the button's after
each move. With Friends off there is no button anywhere and, on again, it
is back in the sidebar's bar. The Preferences check measures the
disclosure's strongest text pixel against the page in both themes. Red
checks: with the placement forced into the old slot left of the main menu,
15 checks fail; with `dim-label` back, the light disclosure reads 3.21:1
and fails.

| Command (2026-10-13, macOS 26.5.1 arm64, `friends-host` worktree, `SZF_FRIENDS_ROOT` = clean shenzhen-pdf worktree at `8a21840b6`) | Exit | Result |
|---|---|---|
| `tools/setup-friends.sh` | 0 | helper 26.10.11 (26101101) and `libszfriends_gtk.a`, 5 s |
| `tools/test-friends-adapter.sh` (scratch build directories), placement forced into the old slot / `dim-label` back | 1, 1 | 15 placement failures / "3.21:1, under 4.5:1" |
| the same with the changes | 0 | `test-nautilus-friends` OK, `test-nautilus-friends-toolbar passed`, 10 renders |
| `patches/friends-host-adapter.patch` regenerated (§ 3.3 recipe); a fresh copy of the repository, `tools/setup-nautilus-tree.sh --tree-only` from this tree's upstream history, then `--check` | 0, 0 | 98 patched paths; `diff -rq` identical to `nautilus/` |
| `tools/setup-nautilus-tree.sh --check`, then `tools/setup-nautilus-tree.sh` (after `meson configure build -Dfriends_root=…`) | 0, 0 | configure, build, install |
| `tools/test-macos-quicklook.sh`, `test-macos-apps-archives.sh`, `test-macos-volumes.sh` (`BUILD_TESTS` in a scratch directory) | 0, 0, 0 | no test disk image or share left mounted |
| `tools/test-setup-friends.sh` | 0 | `SetupFriendsTests passed` |
| `package/make-app.sh`, then `package/bundle-dylibs.sh` (ad hoc) | 0, 0 | Friends bundle checks pass, before and after signing |
| `codesign --verify --deep --strict --verbose=2 "dist/Shenzhen Files.app"` | 0 | ad hoc, 146 MB; `MacOS/nautilus` defines 475 `szfriends_gtk_*` symbols and `nautilus_friends_place_button`; helper 26101101 |
| `package/test-friends-bundle.sh <scratch copy of the app>` | 0 | `FriendsBundleTests passed`, 23 s |

Nothing was launched, installed or published. The renders were checked by
eye: the button right of the traffic lights at the sidebar's edge (light,
dark), at the start of the main bar after the traffic lights with the
sidebar hidden, after the sidebar toggle in a narrow window, in the
sidebar's bar over the dimmed files, and no button with Friends off. Not
covered automatically: a real `NautilusWindow` (it needs a running
`NautilusApplication`), the breakpoint itself (an unmapped window never
gets the frame an `AdwBreakpointBin` waits for, so the probe applies its
setters), the sidebar's slide animation, and the popover reappearing at the
new place on a real display (checklist P).

## Shenzhen Friends with the toolbar search fix (2026-10-13, wave 6e)

`files-fixes` (`f46880b`, the toolbar's search button searches the current
folder) is merged into `friends-host`. The port patch's toolbar and window
changes moved the adapter patch's context, so the adapter was rebased onto
the new port patch and `patches/friends-host-adapter.patch` regenerated
(`docs/friends-integration.md` § 3.3). Only `nautilus-window.blp`
conflicted: the window's toolbar now sets `show-end-search-button` (the
fix's property) and `show-friends-button`. Nothing moved on screen from
wave 6d: the Friends button is at the end of the sidebar's header bar, or
at the start of the main bar, after the window buttons and the sidebar
toggle, while the sidebar is hidden; the magnifier is at the other end of
the main bar, just before the main menu. The two checklists both arrived
as O: the search button's stays O, Shenzhen Friends in Files is now P.

The Preferences disclosure now follows libadwaita's high contrast (Increase
Contrast in macOS). It was the label at a fixed 70% opacity, which no
setting could change; it is now the style class `friends-disclosure`, the
text colour at 70%, and under `prefers-contrast: more` at libadwaita's own
secondary strength there (`--dim-opacity`, 90%), as the group's description
above it already was. The page's stylesheet has its `prefers-contrast`
bound to `AdwStyleManager:high-contrast`, since GTK does not apply the
system's contrast to a provider of its own. Measured on the render:
4.87:1 light and 8.28:1 dark as before, 8.99:1 and 12.81:1 with high
contrast.

`friends.lock` now pins shenzhen-pdf `7f746c11a` (wave 6d). Its helper
build number stays 26101101: the lead decided that the number moves with
ShenzhenPDF releases, and that a tie between unreleased builds, which keeps
the running helper, is acceptable (§ 3.6 of the integration document).

| Piece | What changed |
|---|---|
| `nautilus-window.blp` (adapter) | the toolbar sets `show-end-search-button` and `show-friends-button` |
| `src/nautilus-friends-preferences.c` | the disclosure takes the `friends-disclosure` class from a provider whose `prefers-contrast` follows libadwaita, instead of `gtk_widget_set_opacity (0.7)` |
| `test-nautilus-friends-placement.c` | the probe's toolbar sets `show-end-search-button`; in every state, the search button must end the main bar, after the path bar and just before the main menu, and the port's toggle next to the path bar must stay hidden |
| `test-nautilus-friends-preferences.c` | the page rendered again with high contrast on (libadwaita's own test override of the system setting): the disclosure must read at 7:1 or more and stronger than without |

**Red checks.** The disclosure back at a fixed 70% opacity: "light, high
contrast: 4.87:1 (4.87:1 without), under 7:1" and the same in dark, exit 1.
The class without the binding to libadwaita: the same two failures. The
toolbar's `friends_slot` moved to the bar's end, between the magnifier and
the main menu: 15 placement failures, among them "the search button ends
the main bar, … just before the menu" in each state with the sidebar
hidden.

| Command (2026-10-13, macOS 26.5.1 arm64, `friends-host` worktree, `SZF_FRIENDS_ROOT` = clean shenzhen-pdf worktree at `7f746c11a`) | Exit | Result |
|---|---|---|
| `git merge --no-ff files-fixes` | 1, then committed | conflict in `docs/STATUS.md` only, both sides kept |
| `tools/setup-friends.sh` | 0 | helper 26.10.11 (26101101) and `libszfriends_gtk.a` from `7f746c11a` |
| adapter rebased in a scratch clone of `nautilus/` (old port + adapter, cherry-picked onto the new port) | | one conflict, `nautilus-window.blp`, resolved as above |
| `tools/setup-nautilus-tree.sh --tree-only` on a fresh `nautilus/` (upstream from the previous tree's history), then `--check` after regenerating the patch | 0, 0 | 99 patched paths; same files as the rebased clone |
| `meson configure build -Dfriends_root=…`, then `tools/setup-nautilus-tree.sh` | 0, 0 | configure, build, install |
| `tools/test-friends-adapter.sh` (scratch build directories) | 0 | `test-nautilus-friends` OK, `test-nautilus-friends-toolbar passed`, 12 renders |
| `tools/test-macos-apps-archives.sh`, `-quicklook.sh`, `-search-button.sh`, `-volumes.sh` (`BUILD_TESTS` in a scratch directory) | 0, 0, 0, 0 | 1/1 each; no test disk image or share left mounted |
| `tools/test-setup-friends.sh` (`SZF_FRIENDS_ROOT` unset) | 0 | `SetupFriendsTests passed` |
| `package/make-app.sh`, then `package/bundle-dylibs.sh` (ad hoc) | 0, 0 | Friends bundle checks pass, before and after signing |
| `codesign --verify --deep --strict --verbose=2 "dist/Shenzhen Files.app"` | 0 | valid on disk, satisfies its Designated Requirement; 146 MB; helper 26101101 |
| `package/test-friends-bundle.sh <scratch copy of the app>` | 0 | `FriendsBundleTests passed` |

Nothing was launched, installed or published. The renders were checked by
eye: the Friends button where wave 6d put it, the magnifier just before the
main menu in each, and the disclosure darker (light) or lighter (dark) with
high contrast. Not covered automatically: Increase Contrast itself, which
libadwaita reads from macOS (checklist P).

## Blueprints after a reconfigure; shenzhen-pdf `e8a4cd024` (2026-10-13)

`friends.lock` now pins shenzhen-pdf `e8a4cd024` (one connection icon per
method). With it, `tools/test-friends-adapter.sh` failed 29 placement
checks, "no second search button" and the search button's position in
every state, and printed that `NautilusToolbar` has no property
`show-global-search-button`. Neither the toolbar nor the probe was at fault,
and the Friends popover pages were not being counted: the views use none of
the icons the probe looks for. The repository's `build-tests-friends/`
(and `build-tests-nofriends/`, `build-tests/`) still had the window and
toolbar UI from before the search fix, compiled at 16:27 from blueprints
changed at 20:28; the same test with fresh build directories passed.

**Cause.** Upstream compiles all blueprints in one target whose declared
output is the directory `src/resources`. A reconfigure (here
`meson configure -Dfriends_root=…`, which the test runs every time, and a
`friends.lock` move) rewrites `nautilus.gresource.xml` in that directory and
then runs `ninja -t restat`, which records the directory's new time as the
blueprints' build time. Blueprints changed before the reconfigure were from
then on taken as compiled, and the resource kept the old UI. `build/` was
only right by chance: an app packaged from a build reconfigured after a
patch could have shipped the old window.

**Fix** (`patches/macos-port-full.patch`, now 90 paths):
`src/resources/ui/meson.build` compiles each blueprint in its own target
(`blueprint-compiler compile --minify`) with its `.ui` file as the output,
and `src/resources/meson.build` includes it in place of the batch target.
The 33 compiled files are byte for byte the ones `batch-compile` made.
Existing build directories heal on their next build.

**Test.** `tools/test-macos-blueprints.sh` builds the resource from a
scratch copy of `nautilus/`, changes the window blueprint's default width,
runs `meson setup --reconfigure` and builds the resource again: the compiled
window must have the new width. With the batch target back: "after the
reconfigure, the compiled window UI is still the old one", exit 1.

`tools/test-setup-friends.sh` now exports a `SZF_FRIENDS_ROOT` of its own
that does not exist, and the two runs that called `setup-friends.sh`
without clearing it (the failed fetch and the rerun) use
`env -u SZF_FRIENDS_ROOT`, so a value exported by the caller no longer
reaches them. The failed fetch must also say it was fetching. With either
`env -u` removed, the script fails ("output lacks: fetching shenzhen-pdf",
and "exit 1, expected 0" on the rerun).

Evidence (macOS 26.5.1 arm64, `friends-host` worktree, `SZF_FRIENDS_ROOT` =
clean shenzhen-pdf worktree at `e8a4cd024`); every command exited 0:

- `tools/test-friends-adapter.sh` with scratch build directories, before the
  fix: passed; on the repository's stale build directories: 29 failures.
- `tools/setup-nautilus-tree.sh --check`; a tree made from the two patches
  on a clone of the base commit is identical to `nautilus/`.
- `meson configure build -Dfriends_root=…`, `tools/setup-nautilus-tree.sh`:
  all 33 blueprints compiled again, `build/` window UI sets
  `show-end-search-button`.
- `tools/test-friends-adapter.sh` on the repository's build directories:
  `test-nautilus-friends` OK, `test-nautilus-friends-toolbar passed`.
- `tools/test-macos-apps-archives.sh`, `-blueprints.sh`, `-quicklook.sh`,
  `-search-button.sh`, `-volumes.sh`; `tools/test-setup-friends.sh`, also
  with `SZF_FRIENDS_ROOT` exported.
- `package/make-app.sh`, `package/bundle-dylibs.sh` (ad hoc),
  `codesign --verify --deep --strict "dist/Shenzhen Files.app"`,
  `package/test-friends-bundle.sh` (`FriendsBundleTests passed`); the
  packaged `nautilus` carries `show-end-search-button` and no
  `show-global-search-button`.

Nothing was launched, installed or published.

---

## Folders with many subfolders load as fast as in 26.9.14 again (2026-10-14)

### What was slower

Found by the launch-performance comparison against the release line
(`master`, 26.9.14-1), measured headlessly (no window on screen) from process
start to the files view's end of loading. With "folders first" on (View
settings), a folder of 5000 subfolders took 0.12-0.18 s longer to load than
with 26.9.14 (main thread +20%, slower in 11 of 11 interleaved rounds), one
of 2000 folders named like `com.example.project-1` 60-85 ms longer, one of
2000 `.rtfd` documents and 2000 folders 0.14 s longer. With "folders first"
off, and for launch to the first window, small folders and folders of files,
nothing changed.

Cause: since apps and other packages sort with the files under "folders
first", the sort asks `nautilus_file_is_macos_package()`
about every folder it compares. The answer is cached per file, but the first
one for each folder was a LaunchServices lookup (`NSURLIsPackageKey`, plus a
symbolic link resolution of every path component): 30-45 µs a folder, on the
main thread, before the view could show the folder.

### Fix

`nautilus_macos_get_package_kind()` answers most items from one
`getattrlist()` and, for a folder with an extension, the type of that
extension, a few µs:

- a file is never a package;
- a folder with the bundle bit set, or with a `Contents` folder (plug-ins,
  `.osax`, `.spreporter`, … are packages through what their `Contents`
  say), is still classified by LaunchServices;
- any other folder is a package only when its extension's type conforms to
  `com.apple.package`, and an app when it conforms to
  `com.apple.application-bundle`.

Before relying on them, the rules were compared with LaunchServices' own
answer for the folders under `/Applications`, `/System/Library`, `/Library`
and `/usr/share`: 12 000 without an extension (the bundle-bit rule), 80 000
with one (6 174 packages; the `Contents` and type rules), and the 4 824 the
type rule calls packages (app or document). None differed. A symbolic link is still
resolved and classified by LaunchServices; a real folder no longer resolves
its path.

### Tests

`test-macos-apps-archives` (`tools/test-macos-apps-archives.sh`):

| Test | Checks |
|---|---|
| `packages/classification` (extended) | a folder with no extension and the bundle bit is a package; a folder with an extension no app declares but a `Contents/PkgInfo` is a package; a link to a plain folder is not |
| `packages/folders-first-sort-without-launchservices` (new) | loading and sorting, folders first, 300 plain folders, 100 folders named `com.example.folder-N`, an `.rtfd`, an `.app`, a bundle-bit folder and a folder with `Contents` asks LaunchServices exactly twice (the last two); the folders come first, then the three packages by name, the `.app` an application |

Each check fails when its rule is taken out: no fast path (404 lookups), no
`Contents` rule (`Plug.szfthing` not a package), no type rule (`Empty.app`
not a package), no bundle-bit rule, apps reported as documents.

### Evidence

| Command (2026-10-14, macOS 26.5 arm64, load average 5-7 from other builds) | Exit | Result |
|---|---|---|
| `tools/test-macos-apps-archives.sh` | 0 | 18/18 |
| the same with each rule taken out (above) | 1 | the expected test fails |
| `tools/test-macos-search-button.sh` | 0 | 6/6 |
| `patches/macos-port-full.patch` regenerated the usual way, then `tools/setup-nautilus-tree.sh --check` | 0 | the recipe reproduces `f46880b`'s patch byte for byte from its tree; only `nautilus-macos-packages.m`, `nautilus-macos-bridge.h` and the test differ |
| headless launch probe, 11 interleaved rounds per folder, release line vs `f46880b` vs this fix: median [range] ms from process start to end of loading, main-thread CPU | 0 | 5000 folders: 779 [763-854] / 885 [847-1132] / 804 [785-889], main 629 / 749 / 644; 2000 dotted folders: 709 / 769 / 719, main 576 / 638 / 591; 2000 `.rtfd` + 2000 folders: 767 / 922 / 799, main 620 / 761 / 657; 46 items: 532 / 538 / 535; 10 000 files: 1019 / 1008 / 1005 |

What remains is a few µs a folder for the attributes (about 2% of a folder's
loading cost on the main thread, 15-35 ms for a folder with thousands of
subfolders, under 0.2 ms for one with fifty).

---

## Launch-performance gate (2026-10-14)

`tools/test-macos-launch-performance.sh` compares a built app with the last
release, both launched in the same minutes, and fails when the candidate is
slower. Nothing appears on screen and the installed Shenzhen Files is never
started, stopped or read from.

- **Baseline:** `--baseline APP`, or built from `--baseline-ref` (default:
  the newest release tag before `HEAD`) in a worktree under `build-perf/`,
  kept for later runs.
- **How each launch is measured:** a copy of each app (another bundle id, not
  named `.app`, so the updater stays off; made with `ditto` so file times,
  and with them GTK's icon caches, stay valid) runs `Contents/MacOS/nautilus`
  with `tools/perf/szf_launch_probe.c` inserted. The probe keeps it out of
  the Dock (the `TransformProcessType` interposer of shenzhen-pdf's
  `szfriends_gtk_quiet.c`), refuses window ordering and activation, stops the
  run if any window of it is on screen, and records the display open, the
  first window's map, its first frame and the files view's end of loading,
  with wall time, main-thread and process CPU time and memory footprint.
  Each run has its own XDG, GSettings (keyfile) and Friends state, and the
  settings of a returning user with "folders first" on.
- **Two phases:** launch on a 46-item folder, then a folder of 3000
  subfolders (1500 plain, 1000 dotted, 500 `.rtfd`). Rounds alternate the
  two apps (ABBA). A metric fails when the median of the per-round
  differences exceeds its allowance (`GATES` in `tools/perf/launch_perf.py`)
  and the candidate was slower in at least 3 of 4 rounds, so load from other
  work slows both alike and cancels out.
- **`--self-test`:** the baseline against itself must pass, and with 25 ms
  of main-thread work added at the display open it must fail.
- `tools/perf/launch_perf.py idle` measures memory and CPU over an idle
  minute (app and Friends helper); `tools/perf/launch_profile.py` turns
  `compare --samples` (until the map, or `--samples loaded`) into
  per-function main-thread time and the difference between builds.

### Results (macOS 26.5 arm64, load average 5-7 from parallel builds)

Medians [range] of interleaved rounds; Δ is the median of per-round
differences against the release line (`master` = 26.9.14-1), with how many
rounds were slower. "Fixed" is this branch.

| Measurement | 26.9.14-1 | `files-fixes` | `friends-host` | fixed, Friends off | fixed, Friends on |
|---|---|---|---|---|---|
| Window maps, ms (46 items, 21 rounds) | 248 [220-265] | 235 (15 rounds) | 251 (15 rounds) | 241, Δ -3.1, 10/21 | 243, Δ +4.4, 12/21 |
| Main thread until the map, ms | 178.9 | Δ -0.9, 6/15 | Δ +3.9, 10/15 | Δ -1.2, 10/21 | Δ +3.3, 13/21 |
| 46 items listed, ms | 543 [499-614] | Δ -1.2, 6/15 | Δ +10.5, 13/15 | Δ -7.2, 9/21 | Δ +4.4, 12/21 |
| 3000 subfolders listed, ms (11 rounds) | 703 [669-742] | Δ +99.5, 11/11 | Δ +108.4, 11/11 | Δ +6.5, 9/11 | Δ +6.1, 7/11 |
| … main thread, ms | 578 | Δ +90.9, 11/11 | Δ +100.8, 11/11 | Δ +13.8, 8/11 | Δ -4.9, 4/11 |
| 10 000 files listed, ms (9 rounds) | 1024 [979-1118] | Δ +4.0 | – | Δ -8.3, 4/9 | Δ -7.0, 3/9 |
| Memory after listing 46 items, MB | 377.0 | +0.1 | +0.2 | -0.2 | +0.1 |
| Idle minute: app CPU, ms / wakeups (9 rounds) | 11.8 / 87 | 12.7 / 86 | 12.5 / 86 | 13.1 / 84 | 12.8 / 84 |
| Idle: app footprint, MB | 99.6 | 100.6 | 99.5 | 101.0 | 99.6 |
| Idle: Friends helper | none | none | none (off), 5.2 MB, 0 ms, 0 wakeups (on) | none | 5.2 MB, 0.0 ms CPU, 0 wakeups |

Gate runs: this branch against 26.9.14-1, 21 rounds: passed both phases.
`friends-host` before the fix, 15 rounds: launch passed, folders failed
(`loaded_main_cpu_ms` +83.5 ms, 15/15). Self-test: passed (the 25 ms
injection failed on `map_main_cpu_ms` +24.8 ms, 15/15).

Friends on against Friends off, same build, 30 rounds: main thread until the
map +1.2 ms (19/30; spread over everything, the helper starting in parallel),
until the folder is listed +6.1 ms (19/30). About 3 ms of the latter is GTK
reloading every icon theme after the first frame, when the Friends views add
their icon resource path (`szfriends_gtk_style_ensure()` in shenzhen-pdf).

The per-blueprint resources of `1a569b0` change nothing at run time: the 33
compiled `.ui` files are byte for byte what `batch-compile --minify` makes.
The shared volume monitor costs 0.6 ms of main thread at launch and saves
the 0.9 ms the per-window volume listing took.

## Backspace goes back (2026-10-16)

### What was missing

In the file list and the sidebar, the Delete key (BackSpace) did nothing;
going back needed the toolbar's Back button or Cmd-[. Owner request: the
Delete key goes back.

### Fix

The window's bubble-phase shortcuts (Cmd-Z/X/C/V/A, Cmd-Up, Cmd-Delete, …)
move out of `macos_setup_window()` in `nautilus-application.c` into
`nautilus-macos-window-shortcuts.c` (`nautilus_macos_window_shortcuts_new()`),
unchanged, plus `BackSpace` → `slot.back`. Because the controller runs in
the bubble phase on the window, the focused widget has the key first:

- text fields (rename, path entry, search field) delete a character, since
  GtkText consumes Backspace; while a search is open every key goes to the
  search field (`nautilus_window_slot_handle_event()`), so Delete edits the
  search there, also when it is empty (not so when the file list had the
  focus: the binding ran first; fixed in "Delete in an open search, …"
  below);
- Cmd-Delete and Cmd-Shift-Delete keep their own bindings (and their menu
  key equivalents), so they still trash and delete;
- Fn-Delete (forward Delete) keeps upstream's Move to Trash in the files
  view;
- with no earlier folder, `slot.back` is disabled and Delete does nothing.

Help ▸ Keyboard Shortcuts lists Delete next to Alt-Left under Go Back.
No change on the launch path beyond building the same controller from a
table in another file.

### Tests

`nautilus/test/displayless/test-macos-window-shortcuts.c`, run by
`tools/test-macos-window-shortcuts.sh` (`build-tests/`, `-Dtests=headless`,
builds only that test). It creates no widget and reads the controller each
window gets:

| Test | Checks |
|---|---|
| `backspace/goes-back` | BackSpace with no modifier is bound to exactly `slot.back` |
| `backspace/cmd-still-trashes` | Cmd-BackSpace is bound to exactly `view.move-to-trash`, Cmd-Shift-BackSpace to `view.delete-permanently-shortcut` |
| `backspace/forward-delete-is-not-back` | plain Delete is not bound by the window |
| `backspace/text-fields-keep-it` | the controller runs in the bubble phase, local scope: after the focused widget |

### Evidence

| Command (2026-10-16, macOS 26.5 arm64, load average 12-16 from other builds) | Exit | Result |
|---|---|---|
| `tools/test-macos-window-shortcuts.sh` | 0 | 4/4 |
| the same with the `BackSpace` line taken out | 1 | `goes-back`: `(found->len == 1): (0 == 1)` |
| `tools/test-macos-search-button.sh`, `-volumes.sh`, `-apps-archives.sh`, `-quicklook.sh` | 0 | all pass |
| `patches/macos-port-full.patch` regenerated the usual way (the recipe reproduces `3fba3e2`'s patch byte for byte from its tree), then `tools/setup-nautilus-tree.sh --check` | 0 | 91 patched paths; changed: `src/meson.build`, `nautilus-application.c`, `shortcuts-dialog.blp`, `test/displayless/meson.build`, and the three new files |
| `tools/test-macos-launch-performance.sh` (from `friends-host`, which has it) with `--candidate` this branch's ad hoc `dist/` app and `--baseline` the 26.9.14-1 release build | 0 | launch gate and folders gate (3000 subfolders), 15 interleaved rounds each: PASSED, no metric slower beyond its allowance |

With Homebrew's glib 2.90, which defines `g_set_date_time` itself, this
commit's tree only built with a guard in `nautilus-date-utilities.h` (the
one `baseline_compat` applies in the launch gate), added for these runs and
not committed. `f115b0f` (next entry) puts that guard in the patch, so no
local edit is needed from there on.

Not covered automatically: pressing the keys in a window. See checklist Q.

---

## Folders with thousands of subfolders: the package question leaves the main thread; GLib 2.90 builds (2026-10-16)

### What was slower

The folders phase of the launch-performance gate (`friends-host`'s
`tools/test-macos-launch-performance.sh`: 3000 subfolders, 1500 plain, 1000
named like `com.example.project-N`, 500 `.rtfd`, "folders first" on) failed
for `files-fixes` against 26.9.14-1: main-thread CPU to the end of loading
+34-38 ms, allowance 30. The launch phase passed.

Each commit since 26.9.14-1 that changes the patch was built from its own
patch in a fresh build directory, all against the same Homebrew libraries
(glib 2.90.1, with the guard below), and the six launched in rotating order,
12 rounds, load average 8.0 (6.8-10.2) from other builds. Main-thread CPU to
the end of loading, median of the per-round differences against 26.9.14-1:

| Build | Δ main thread | slower in |
|---|---|---|
| `cacd23d` (before packages were told apart) | +1.3 ms | 7/12 |
| `d3a387f` (packages sort with the files) | +92.9 ms | 12/12 |
| `f46880b` | +95.4 ms | 12/12 |
| `3fba3e2` (folders told apart without LaunchServices) | +17.4 ms | 11/12 |
| `e884b5e` | +18.0 ms | 10/12 |

Cause: `d3a387f`'s folders-first sort asks, on the main thread, whether each
subfolder is a package; `3fba3e2` made the answer cheaper, about 7.7 µs a
folder (23 ms for the 3000; the type lookup of a dotted name is most of it
and cannot run in parallel: it takes a lock). Nothing after `3fba3e2`
changed it. Under load the 23 ms grow past the 30 ms allowance.

### Fix

`nautilus-macos-listing.c` replaces `g_file_enumerator_next_files_async()`
for a folder's file list (`nautilus-directory-async.c`). When a listing
starts with "folders first" on and the folder has a local path, another
thread reads the folder itself and answers for every subfolder, in the
order GIO lists them (chunks of 1000 names by inode), about four times as
fast as GIO lists them. Each batch of `GFileInfo`s waits for its answers
(about 1 ms over the whole 3000) and carries them; `update_info_internal()`
keeps them like an answer it worked out itself, with the same name,
activation URI and modification-time checks. A link, or a subfolder that
appeared after the other thread read the folder, is answered where it is
asked, as before. With "folders first" off, or no local path, the listing is
GIO's own call and nothing is asked.

Answering on the listing thread itself was tried first and does not help:
the view waits for the listing, and the main thread used as much CPU as
before (40 interleaved rounds, +0.4 ms against `e884b5e`).

`f115b0f`: Homebrew's glib 2.90 declares `g_set_date_time()`, which
`nautilus-date-utilities.h` defined too, so the tree no longer compiled.
The copy is now inside `#if !GLIB_CHECK_VERSION (2, 90, 0)`; the local edit
described under "Backspace goes back" is no longer needed.

### Tests

`nautilus/test/displayless/test-macos-package-listing.c`, run by
`tools/test-macos-apps-archives.sh` after `test-macos-apps-archives`:

| Test | Checks |
|---|---|
| `folders-first/answered-while-listing` | loading 200 plain and 100 dotted folders, `Has.contents` (a folder with `Contents`), `Notes.rtfd`, `Tool.app`, `Bundled` (bundle bit), a link to the app and a text file asks LaunchServices twice while listing (`Bundled`, `Has.contents`); sorting them folders first then works out one answer (the link) and asks LaunchServices once; 301 folders come first, then the four packages and the file, apps told apart |
| `folders-first-off/asks-nothing-while-listing` | with "folders first" off, loading asks nothing, and every folder is worked out when the sort asks |
| `changed-folder-asked-again` | an answer from the listing is used as is, and worked out again once the folder's modification time moves on |

Without the `update_info_internal()` half, or with the listing back on
GIO's call, the test fails (`worked_out (1 == 0)`).

### Evidence

| Command (2026-10-16, macOS 26.5 arm64, load average 6-10 from other builds) | Exit | Result |
|---|---|---|
| `tools/setup-nautilus-tree.sh --check` after each change (patch regenerated the usual way; the recipe reproduces `e884b5e`'s patch byte for byte from its tree) | 0 | `f115b0f`: only `nautilus-date-utilities.h` differs; `999eeb2`: `nautilus-directory-async.c`, `nautilus-file.c`, `nautilus-file.h`, `src/meson.build`, `test/displayless/meson.build` and the three new files |
| `tools/test-macos-apps-archives.sh` | 0 | 18/18 and 3/3 |
| `tools/test-macos-window-shortcuts.sh` | 0 | 4/4 |
| `tools/test-macos-launch-performance.sh` (copied from `friends-host`) `--candidate dist/` (this branch) `--baseline` 26.9.14-1 built from its patch with the same libraries | 0 | launch gate, 15 rounds, load 8.5: loaded main thread −0.3 ms, loaded +0.6 ms, map main thread −1.7 ms; folders gate, 15 rounds, load 7.7: loaded main thread −2.4 ms [IQR −8.6, +8.0] (allowance 35.7), loaded −2.2 ms, footprint +2.0 MB; PASSED both |
| the folders gate, `e884b5e` against the same baseline, same minutes (load 8.5) | 0 | loaded main thread +28.1 ms (14/15 rounds), loaded +23.8 ms |

The other thread's work shows in the process's CPU time (folders gate
`loaded_proc_cpu_ms` +18.6 ms), not on the main thread.

Not covered automatically: a folder of thousands of subfolders opened in a
window. A network volume no longer gets a second read; see the next entry.

---

## Delete in an open search, the search button during Search Everywhere, network folders read once (2026-10-16)

### What was wrong

- **Delete went back instead of editing an open search** when the file list
  had the focus (Cmd-F, type, click a result or press Down, press Delete):
  the window went back to the previous folder and the search was lost. The
  window hands keys to the search field from its own bubble-phase key
  controller, but GTK 4.22 runs a widget's controllers newest first
  (`gtk_widget_add_controller()` prepends, `gtk_widget_run_controllers()`
  walks from the head), and the shortcuts controller is added in
  `macos_setup_window()`, after the window's own. So the `BackSpace` →
  `slot.back` binding ran first. The "Backspace goes back" entry assumed
  the opposite order.
- **During Search Everywhere the toolbar's magnifier looked pressed and
  said "Search Current Folder"** while the results came from everywhere,
  and clicking it ended the search instead. Upstream swaps its own folder
  search toggle for a placeholder in that mode; the macOS end button was
  left out.
- **On a network volume the other listing thread read every folder a second
  time** (the previous entry), which costs as much as the listing there.

### Fix

- `nautilus-macos-window-shortcuts.c`: Delete is bound to a callback,
  `nautilus_macos_window_shortcuts_delete_key()`. While a search is open in
  the window's current tab (`macos_search_open()` in
  `nautilus-application.c`, the slot's search-visible) it returns FALSE, so
  the window's key controller gives the key to the search field; otherwise
  it activates `slot.back` exactly as the binding did (nothing happens, and
  the key goes on, when there is no earlier folder). The other shortcuts and
  the controller order are unchanged.
- `nautilus-toolbar.blp`: the end button sits in `end_search_button_stack`
  with an empty placeholder, like upstream's toggle; `toolbar_update_appearance()`
  shows the placeholder while search-global is on, next to the line that
  does it for upstream's toggle. Escape still closes the search.
- `nautilus-macos-listing.c`: before reading the folder, the other thread
  checks the volume (`statfs()`, `MNT_LOCAL`). On a network or other remote
  volume, or one it cannot check, it reads nothing and records no answers;
  the sort asks about each folder as it did before `999eeb2`.

Nothing new on the launch path: the volume check runs on the other thread,
the Delete callback only when Delete is pressed.

`test-macos-search-button.c` was 765 lines; its UI half (the compiled-UI
reader and the toolbar and window checks) moved, unchanged apart from the
new parent link and checks, to `test-macos-search-button-ui.c`, built into
the same test.

### Tests

| Test | Checks |
|---|---|
| `test-macos-window-shortcuts` `backspace/goes-back` | Delete is bound to one callback (not straight to `slot.back`); with no search open it goes back, and with nothing to go back to it passes the key on |
| `backspace/edits-open-search` (new) | with a search open the Delete callback returns FALSE and does not go back; no binding of Delete to `slot.back` |
| `test-macos-search-button` `toolbar/toggles-make-way-for-search-everywhere` (new) | the end button and upstream's toggle each sit in a `GtkStack` with an `AdwBin` placeholder beside them |
| `toolbar/end-button-searches-current-folder` | as before; the visibility binding is now on the end button's stack |
| `test-macos-package-listing` `network-volume/read-once` (new) | with the volume check stubbed to "network", loading 30 folders, three packages, a folder with `Contents`, a link and a file reads the folder no second time and asks LaunchServices nothing; the sort then works out every folder (35) and sorts as before |
| `folders-first/answered-while-listing` | also: on the local scratch volume the other thread reads the folder once |

What a displayless test cannot show (the keys and the button in a window)
is in checklists O and Q.

### Evidence

| Command (2026-10-16, macOS 26.5 arm64, Homebrew glib 2.90.1) | Exit | Result |
|---|---|---|
| `tools/test-macos-window-shortcuts.sh` | 0 | 5/5 |
| the same with the search check taken out of `nautilus_macos_window_shortcuts_delete_key()` | 1 | `edits-open-search`: should be FALSE |
| the same with Delete bound to `slot.back` again | 1 | `goes-back`: `("slot.back" == "(callback)")` |
| `tools/test-macos-search-button.sh` | 0 | 7/7 |
| its new test against the old `nautilus-toolbar.blp` | 1 | `toggles-make-way-for-search-everywhere`: `'placeholder' should not be NULL` |
| `tools/test-macos-apps-archives.sh` | 0 | 18/18 and 4/4 |
| the same with the volume check ignored (every volume treated as local) | 1 | `network-volume/read-once`: `(reads == 0): (1 == 0)` |
| `tools/test-macos-volumes.sh`, `tools/test-macos-quicklook.sh` | 0 / 0 | 12/12, 19/19 |
| `patches/macos-port-full.patch` regenerated the usual way (the recipe reproduces `b8d43d5`'s patch byte for byte from its tree), then `tools/setup-nautilus-tree.sh --check` | 0 | 96 patched paths; changed: `nautilus-application.c`, `nautilus-macos-listing.c`/`.h`, `nautilus-macos-window-shortcuts.c`/`.h`, `nautilus-toolbar.c`, `nautilus-toolbar.blp`, `test/displayless/meson.build`, the three tests and the new `test-macos-search-button-ui.c` |
| `tools/setup-nautilus-tree.sh` (build and install), `package/make-app.sh`, `package/bundle-dylibs.sh` (ad hoc) | 0 | no warnings in the changed files |
| `tools/test-macos-launch-performance.sh` (copied from `friends-host`) `--candidate dist/` (this change) `--baseline-ref 26.9.14-1`, both apps carrying the same `libglib-2.0.0.dylib` (2.90.1, same UUID) | 0 | launch gate, 15 rounds, load 8.5: map main thread +0.1 ms, loaded main thread +1.4 ms, loaded +0.7 ms; folders gate (3000 subfolders), 15 rounds, load 6.9: loaded main thread +1.5 ms [IQR −6.3, +7.8], loaded +0.4 ms, footprint +0.7 MB; PASSED both |

The other listing thread's CPU shows in the process's time as before
(folders gate `loaded_proc_cpu_ms` +21.3 ms), not on the main thread.
