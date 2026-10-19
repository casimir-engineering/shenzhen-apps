# Phase 3 · W5 — Finder Drag & Drop: human QA checklist

Static analysis + scratch-app pasteboard probes prove the byte-level behavior
below; a real inter-application drag still needs a human (synthesizing a
cross-process drag is TCC-blocked for the agent). Run each case against the
`build-w5` binary via `./run-nautilus.sh` and record PASS/FAIL.

```bash
NAUTILUS_BIN="$PWD/build-w5/src/nautilus" ./run-nautilus.sh ~/some/test/dir
```

Seed a test dir with a couple of files, at least one with a **space** and one
with a **`%`/`#`** in its name (these exercise the URI-encoding paths):

```bash
mkdir -p ~/w5-qa && printf a > "~/w5-qa/alpha one.txt" && printf b > ~/w5-qa/beta.txt
printf c > "~/w5-qa/50% off #1.txt"; mkdir -p ~/w5-qa/folder
```

Optional: watch the debug channel for the drag path in a second terminal:

```bash
G_MESSAGES_DEBUG=nautilus-macos-bridge,nautilus-dnd \
  NAUTILUS_BIN="$PWD/build-w5/src/nautilus" ./run-nautilus.sh ~/w5-qa
```

---

## 1. Drag OUT — Nautilus → Finder / other macOS apps

| # | Action | Expected | P/F |
|---|--------|----------|-----|
| 1.1 | Drag a **single** file from the Nautilus view onto the Finder Desktop | File is **copied** to the Desktop; name (incl. spaces/`%`/`#`) intact | |
| 1.2 | Drag a single file into an **open Finder window** of another folder | Copied there; original stays | |
| 1.3 | Drag a single file onto a **Finder Dock icon** target (e.g. a folder in the Dock, or TextEdit) | App receives the file (opens / accepts it) | |
| 1.4 | Select **multiple** files, drag them onto the Finder Desktop | **All** selected files copied (this relies on the legacy `NSFilenamesPboardType` augmentation — verify none are dropped) | |
| 1.5 | Drag a **folder** out to Finder | Whole folder copied recursively | |
| 1.6 | Drag a file into a **text editor** that accepts file drops (e.g. drop onto a document area expecting a path) | Receives the file URL / path, no stray `\r\n` or `%0D%0A` suffix | |
| 1.7 | Drag a file from a **`recent:`/`starred:`** view out to Finder | Uses the file's real activation location (not the virtual URI); real file copied | |

Notes:
- macOS default for a cross-volume/foreign-app drop is **copy**; Nautilus never
  deletes the source on drag-out. Move-out is not offered (matches Finder for
  inter-app drags).
- 1.4 is the case most likely to regress if the augmentation timing changes —
  test with 3+ files and confirm the count on the Desktop.

## 2. Drag IN — Finder → Nautilus

| # | Action | Expected | P/F |
|---|--------|----------|-----|
| 2.1 | Drag a **single** file from Finder onto the Nautilus **view background** | Copied into the displayed folder; correct name | |
| 2.2 | Drag a file from Finder onto a **folder item** in the Nautilus view | Copied **into** that folder (folder highlights on hover) | |
| 2.3 | Drag a file from Finder and hover a folder item ~0.5s without releasing | Folder auto-opens (hover-to-navigate), then drop lands inside | |
| 2.4 | Drag **multiple** files from Finder into the view | All copied | |
| 2.5 | Drag a file with a **space / `%` / `#`** in its name from Finder in | Copied with the exact original name (URI-repair path) | |
| 2.6 | Drag a file from Finder onto a **sidebar** bookmark/place | Copied into that location | |
| 2.7 | Drag a file from Finder onto a **path-bar** breadcrumb | Copied into that ancestor folder | |
| 2.8 | Hold **⌥ (Option)** while dragging from Finder in | Still a copy (mask already copy); no crash | |
| 2.9 | Drag from Finder in, then release over a **non-writable** target | Rejected cleanly (no error dialog spam, no crash) | |

Notes:
- Without the fix, every Finder → Nautilus drop produced GFiles with a **NULL
  path** (mangled `file%3A///…` URIs) and silently failed. 2.1/2.5 are the
  direct regression checks.
- Copy-vs-move: a cross-app drop from Finder arrives with the full
  copy+move+link mask and **no** `GdkDrag`. W5 narrows it to Nautilus's
  preferred action (same-filesystem + deletable source → move; else copy)
  instead of rejecting the ambiguous mask. Verify a drop from the **same**
  volume into a subfolder behaves like Finder (move within a volume is only
  offered when it makes sense; copy otherwise).

## 3. In-app DnD (regression — must still work)

| # | Action | Expected | P/F |
|---|--------|----------|-----|
| 3.1 | Drag a file **within the view** onto a subfolder | Moved (same fs) into it | |
| 3.2 | Drag a file **to the sidebar** (a bookmarked place) | Copied/moved per location | |
| 3.3 | Drag a file **to a path-bar** breadcrumb | Moved/copied into that ancestor | |
| 3.4 | Drag onto the **tab bar** / another tab's location | Lands in that tab's folder | |
| 3.5 | Drag **text** (e.g. selected text from another app) into the view | Creates a `.txt` with that content (copy) | |
| 3.6 | Drag an **image** (GdkTexture, e.g. from a browser) into the view | Saves "Dropped Image" (copy) | |
| 3.7 | Drag a file **onto itself / its own folder** | No-op (no accidental move) | |

In-app drags transfer the `GdkFileList` GValue directly and never touch the
pasteboard (de)serializers, so 3.x should be unchanged by W5. Confirm the
serializer/deserializer overrides didn't perturb them.

## 4. Sanity / degraded modes

| # | Check | Expected | P/F |
|---|-------|----------|-----|
| 4.1 | Launch with `NAUTILUS_NO_DBUS=1` and repeat a couple of 1.x / 2.x cases | DnD unaffected by bus state | |
| 4.2 | Drag a **non-native** file out (e.g. from a `recent:`/remote view with no local path) | GTK's default single-URI item is left as-is; no crash, no bogus legacy list | |
| 4.3 | Watch the console during drags | No `g_critical`/`g_warning` from DnD; at most a `g_debug` "failed to augment" if AppKit symbols are missing (should not happen) | |

---

## What static analysis already proved (no human needed)

Scratch harness in `scratch-w5/` (GTK4 client writing/reading a real
`NSPasteboard`, plus Swift readers that mimic Finder):

- GTK-macOS maps `text/uri-list` ⇄ `public.file-url`/`public.url` and exports
  the serialized bytes **verbatim** as the URL data.
- **Drag-out, single file:** with the trailing-CRLF-free serializer,
  `readObjects(forClasses:[NSURL])` returns exactly the dropped file with the
  correct path. Without it, AppKit reads a URL with a `%0D%0A` suffix → Finder
  rejects. (`pbread` before/after.)
- **Drag-out, multi file:** GTK emits a single pasteboard item, so Finder saw
  only one file. Adding a pasteboard-level `NSFilenamesPboardType` plist makes
  AppKit re-expose **one `public.file-url` item per file**;
  `readObjects(NSURL)` then returns all of them. (`gtk-clip-write-dlsym` +
  `pbread`.)
- **Drag-in:** a Finder-written pasteboard (`pbwrite`) read back through GTK's
  `text/uri-list → GdkFileList` deserializer yields `file%3A///…` URIs with
  NULL paths; the W5 deserializer override repairs them to real native paths,
  verified including the `50% off #1.txt` edge case. (`gtk-clip-read` vs
  `gtk-clip-read-fixed`.)
