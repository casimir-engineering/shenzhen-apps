# Phase 3 · W5 — Finder Drag & Drop: integration notes

## TL;DR for the integrator

- **Files changed:** `src/nautilus-dnd.c`, `src/nautilus-dnd.h`. Nothing else.
- **No meson change required.** All the AppKit access is done through
  `objc_msgSend`/`sel_registerName` resolved with `dlsym(RTLD_DEFAULT, …)` in
  the plain C file, so no new framework link and no `.m` file. `<dlfcn.h>` is
  the only added include (darwin-only). The W5 section of
  `nautilus-macos-bridge.h` is left empty as reserved — **no bridge seam was
  added.**
- **No new build symbols to audit** in the dylib closure: `objc_msgSend` lives
  in `/usr/lib/libobjc.A.dylib`, already loaded by GTK's macOS backend; AppKit
  (`NSPasteboard`, `NSString`, …) is already loaded too.
- Everything is guarded by `#ifdef __APPLE__`, matching the existing patch-set
  convention (`nautilus-application.c`, `nautilus-files-view.c` use the same
  guard).

## What was wrong (root causes, with GTK source citations)

GTK paths below are from `gtk4 4.22.4` (Homebrew), unpacked read-only to
`scratch-w5/gtk4-4.22.4/` via `brew unpack gtk4`.

### Type-bridging table (definitive answer to question 1)

`GdkFileList` **is** the designed type and GTK-macos bridges it, but via the
generic serializer path, not a native file-URL writer:

- `gdk/gdkcontentserializer.c:1042-1051` registers `GDK_TYPE_FILE_LIST` (and
  `G_TYPE_FILE`) → `text/uri-list` using `file_uri_serializer`.
- `file_uri_serializer` (`gdk/gdkcontentserializer.c:822-869`) writes each URI
  followed by `"\r\n"` — including a **trailing** CRLF after the last one
  (RFC 2483 uri-list format).
- On macOS, `text/uri-list` maps to `NSPasteboardTypeFileURL` +
  `NSPasteboardTypeURL` (`gdk/macos/gdkmacospasteboard.c:66-72`,
  `_gdk_macos_pasteboard_to_ns_type`), and the drag pasteboard item hands
  AppKit the **verbatim serialized bytes** as the data for those types
  (`GdkMacosPasteboardItemDataProvider -pasteboard:item:provideDataForType:`,
  `gdkmacospasteboard.c:452-499`).

So the `public.file-url` item's data is `file:///…%0D%0A` (or multiple URIs
CRLF-joined). AppKit expects a `public.file-url` item to be exactly **one bare
URL**, so `readObjects(forClasses:[NSURL])` fails → Finder rejects the drop.
Proven with `scratch-w5/pbread` before the fix ("readObjects(NSURL) → 0
url(s)").

### Single item for the whole drag (multi-file gap)

`_gdk_macos_drag_begin` (`gdk/macos/gdkmacosdrag.c:369-399`) creates **one**
`GdkMacosPasteboardItem` and begins the `NSDraggingSession` with that single
item. AppKit's file-drag convention is one `NSPasteboardItem` per file, so even
if the URL bytes were clean, Finder would still only see the first file.

### Drag-in URI mangling

For a drop coming from another app, `_gdk_macos_pasteboard_read_async`
(`gdk/macos/gdkmacospasteboard.c:177-204`) builds the `text/uri-list` by taking
each file path, prepending `file://`, and then percent-encoding the **whole
string** with `URLPathAllowedCharacterSet` — which encodes the scheme colon,
producing `file%3A///…`. GTK's `file_uri_deserializer`
(`gdk/gdkcontentdeserializer.c:834`) hands that to `g_file_new_for_uri`, and the
resulting `GFile` has a **NULL path** (`g_file_get_path` returns NULL), so every
Nautilus drop handler that turns the file list into URIs
(`nautilus_dnd_perform_drop`) produced unusable data. Proven with
`scratch-w5/pbwrite` + `gtk-clip-read` ("path=(null)").

### Non-unique action rejection (drag-in copy/move)

A cross-app drop has **no `GdkDrag`** (`gdk_drop_get_drag` → NULL), so the
`#ifdef GDK_WINDOWING_X11` workarounds in the drop handlers don't apply, and
`gdk_drop_get_actions` returns the full mask AppKit gave us. Finder's
`draggingSourceOperationMask` is typically `copy | move | link`
(`_gdk_macos_drop_update_actions`, `gdk/macos/gdkmacosdrop.c:110-131`). The old
`nautilus_dnd_perform_drop` did `if (!gdk_drag_action_is_unique(action)) return
FALSE;` (`nautilus-dnd.c`), so ambiguous masks were dropped on the floor.

## What the fix does (`nautilus-dnd.c`, all `#ifdef __APPLE__`)

1. **`nautilus_dnd_init_macos()`** (idempotent, `g_once`): registers, *after*
   `gtk_init()`, override (de)serializers for `text/uri-list`. Since GTK 4.20
   the **last** registered (de)serializer for a mime type wins
   (`gdk/gdkcontentserializer.c:404-406`, `lookup_serializer` iterates
   tail→head at :441). Called lazily from `nautilus_dnd_get_preferred_action`,
   `nautilus_dnd_perform_drop`, and `get_paintable_for_drag_selection`, all of
   which run before GDK needs the codecs.
   - `macos_file_uri_serializer`: same as GTK's but **no trailing CRLF**
     (single URI → clean bare URL; multiple → CRLF-joined for GTK readers).
   - `macos_file_uri_deserializer`: same as GTK's but repairs `file%3A///…`
     URIs (`file_for_dropped_uri`) so dropped GFiles have real native paths.
2. **Multi-file drag-out augmentation**
   (`schedule_drag_pasteboard_augmentation`, from
   `get_paintable_for_drag_selection`, which is called once per drag from
   `GtkDragSource::prepare` in `nautilus-list-base.c:on_item_drag_prepare`):
   collects the selection's **native** paths and, from a `g_idle`, adds a
   pasteboard-level `NSFilenamesPboardType` property list to the drag
   pasteboard (`Apple CFPasteboard drag`). AppKit's legacy shim then re-exposes
   the list as **one `public.file-url` item per file** (and, as a bonus,
   rewrites the first item's URL bytes to the clean single URL). If any
   selected file has no local path, it bails and leaves GTK's item untouched.
3. **`file_with_repaired_uri`** belt-and-suspenders in
   `nautilus_dnd_perform_drop`'s `GDK_TYPE_FILE_LIST` branch, in case a value
   was deserialized before the override registered.
4. **Non-unique action narrowing** in `nautilus_dnd_perform_drop`: for a
   cross-app drop with an ambiguous mask, pick Nautilus's preferred action
   (via `nautilus_dnd_get_preferred_action`) intersected with the offered mask,
   else fall back copy→move→link, instead of rejecting.

## Empirical verification (agent-run, no human)

All in `scratch-w5/` (compile lines at the top of each file):

- `pbread` / `pbwrite` / `pbshape` / `pblegacy` — Swift readers/writers that
  mimic Finder's `NSPasteboard` use.
- `gtk-clip-write[-caugment|-dlsym]` — GTK4 clients that put a `GdkFileList` on
  the pasteboard exactly like Nautilus's drag source (the macOS clipboard and
  drag pasteboards share the same `GdkMacosPasteboardItem` code, so the bytes
  are identical to a real drag), with/without the augmentation.
- `gtk-clip-read` vs `gtk-clip-read-fixed` — GTK reading a Finder-written
  pasteboard as `GdkFileList`, before/after the deserializer override.

Results: single-file drag-out URL is clean; multi-file augmentation yields all
files via `readObjects(NSURL)`; Finder→GTK read yields real native paths
including the `50% off #1.txt` edge case. Full transcript summarized in
`phase3-w5-qa-checklist.md`.

## CGEvent drag-synthesis attempt (time-boxed, ~20 min)

Outcome: **partially set up, not completed — inter-app drag remains a human QA
item.** `AXIsProcessTrusted()` returned true and synthetic
`leftMouseDown/Dragged/Up` posts worked (`scratch-w5/drag.swift`,
`winbounds.swift`). Blocker: my W5 `build-w5` instance couldn't stay the
frontmost/AX-addressable window — the shared session bus routes to a sibling
worker's Nautilus, and when I forced `NAUTILUS_NO_DBUS=1` the window opened
off-screen behind an unrelated system Touch-ID modal, so I couldn't reliably
aim the synthetic drag at a known icon rectangle without risking driving a real
inter-app drag into another worker's UI. Given the time-box and that
byte-level behavior is already proven by the pasteboard probes, I stopped here
rather than fight window management. The scratch scripts are left in place for
a human to finish 3.x with if desired:

```bash
scratch-w5/winall <pid>            # list window rects for the pid
scratch-w5/drag x1 y1 x2 y2        # synthesize a slow left-drag
```

## If you would prefer a real `.m` helper instead of dlsym

The dlsym approach was chosen specifically to avoid touching frozen meson and
to keep W5 within its two owned files. If you'd rather have the multi-file
augmentation as a proper Objective-C bridge file (cleaner, type-checked), it's
a mechanical lift:

1. Add a `Section W5` prototype to `nautilus-macos-bridge.h`:
   ```c
   /* Add a legacy NSFilenamesPboardType list to the active drag pasteboard so
    * AppKit re-exposes each path as its own public.file-url item (multi-file
    * drag-out to Finder). @paths is a NULL-terminated array of local paths. */
   void nautilus_macos_dnd_augment_drag_pasteboard (const char *const *paths);
   ```
2. New file `src/nautilus-macos-dnd.m` implementing it with straightforward
   AppKit (`[NSPasteboard pasteboardWithName:NSPasteboardNameDrag]`,
   `setPropertyList:forType:@"NSFilenamesPboardType"`).
3. **Meson one-liner** (integrator-only): add to the "Phase 3 macOS bridge"
   block in `src/meson.build` (currently ll. 291-300), alongside the other
   `.m` files:
   ```meson
       'nautilus-macos-dnd.m',
   ```
   No new framework needed — AppKit is already in `macos_frameworks`.
4. Replace `drag_pasteboard_add_filenames` + its `dlsym` typedefs in
   `nautilus-dnd.c` with a call to the new seam.

I did **not** do this, to respect "don't touch shared build files"; the dlsym
version is functionally equivalent and self-contained. Flagging it as the clean
follow-up if you're consolidating the `.m` files anyway.
