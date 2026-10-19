# W7 integration notes — "destination is read-only" in $HOME

## Summary

On macOS, copy/move/paste/new-folder into the user's own home (and anything
else on the APFS Data volume) failed with the dialog **"The destination is
read-only."** Root cause is a GLib mis-derivation of
`filesystem::readonly` on macOS firmlinked volumes. Fixed entirely within
Nautilus, in **unowned files** — no sibling-owned file needed editing.

## Files changed (all unowned by W1–W6)

- `src/nautilus-file-utilities.c` / `.h` — new centralized helper
  `nautilus_filesystem_is_readonly (GFile *location, GFileInfo *fs_info)`.
- `src/nautilus-file-operations.c` — `verify_destination()` now calls the
  helper instead of reading the attribute directly (this is the pre-flight
  that produced the user-facing dialog).
- `src/nautilus-directory-async.c` — `got_filesystem_info()` caches the
  corrected value into `NautilusFile.details.filesystem_readonly`
  (defense-in-depth; see "menu sensitivity" below).

## No sibling edits required

The task flagged that Paste menu-item sensitivity might live in W2-owned
`nautilus-files-view.c` and need a change. **It does not.** Verified:

- The cached `NautilusFile.details.filesystem_readonly` field has **no
  reader** anywhere in `src/` — it is only written
  (`nautilus-directory-async.c:3684`) and propagated parent→child
  (`nautilus-file.c:4454`). It never gates any menu.
- Paste sensitivity (`can_paste_into_file`, `nautilus_files_view_is_read_only`
  in `nautilus-files-view.c`) is gated by `nautilus_file_can_write()`, which
  derives from `G_FILE_ATTRIBUTE_ACCESS_CAN_WRITE`
  (`nautilus-file.c:2560-2563`). That attribute is access(2)-based and is
  **correct** on macOS:
  `gio info -a access::can-write ~` → `TRUE`;
  on a genuinely read-only dest → `FALSE`.

So the Paste item was never grayed out by this bug; the only functional
consumer of the buggy signal was the file-operations pre-flight.

## GLib upstream bug (precise detail, for a future patch / bundled-GLib decision)

GLib 2.88.2, `gio/glocalfile.c`, `get_mount_info()` (lines ~789–864):

1. It `g_lstat()`s the path and keys a cache by `buf.st_dev`
   (`glocalfile.c:817`).
2. It resolves the mount point with `find_mountpoint_for(path, dev, …)`
   (`glocalfile.c:830`), which walks parents **until `st_dev` changes**
   (`glocalfile.c:1743-1760`).
3. It looks up that mount point via `g_unix_mount_entry_at()` and copies its
   read-only flag (`glocalfile.c:834-838`).

On macOS the Data volume is firmlinked into the sealed system volume: `/`
(the read-only system volume, `/dev/disk3s1s1`, `MNT_RDONLY=1`) and
`/System/Volumes/Data` (`/dev/disk3s5`, `MNT_RDONLY=0`) **share the same
`st_dev`** (verified: both `16777234`). `/Users` is a firmlink onto the Data
volume but still reports that shared `st_dev`. Because
`find_mountpoint_for` only stops when `st_dev` *changes*, walking up from
`/Users/raph` never crosses a device boundary and climbs all the way to `/`.
GLib then matches the `/` unix-mount entry, which is `MNT_RDONLY`, and returns
`filesystem::readonly = TRUE` for a fully writable path.

Reproduce with stock tooling:

```
$ gio info -f -a filesystem::readonly ~
  filesystem::readonly: TRUE        # WRONG
$ stat -f "%N %d" / /Users /System/Volumes/Data
/ 16777234
/Users 16777234
/System/Volumes/Data 16777234       # all identical st_dev
$ statfs("/Users/raph").f_flags & MNT_RDONLY   ->  0   # actually writable
```

The kernel's own per-path answer via `statfs(2)` / `f_mntonname` +
`MNT_RDONLY` is correct (`/Users/raph` → `mnton=/System/Volumes/Data`,
`MNT_RDONLY=0`). GLib's device-based longest-walk heuristic is the bug: on
APFS-firmlinked layouts `st_dev` is not a reliable mount discriminator.

**Recommendation:** worth filing upstream against GLib
(`g_local_file_query_filesystem_info` / `get_mount_info`) — on Darwin it
should consult `statfs().f_flags & MNT_RDONLY` (or match by `f_mntonname`
rather than by `st_dev`). Until then we override inside Nautilus and do **not**
patch Homebrew GLib.

## Build note (my build dir only)

`build-w7` was configured with `-Dc_args=-Wno-error=missing-prototypes`.
This was **not** for my change — it works around an in-progress
`-Werror=missing-prototypes` failure in W5's `nautilus-dnd.c`
(`nautilus_dnd_init_macos` has no prototype yet). It only affects my isolated
build dir; nothing to integrate.
