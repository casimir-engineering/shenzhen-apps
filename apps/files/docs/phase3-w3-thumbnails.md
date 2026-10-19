# Phase 3 W3 — QuickLook thumbnails (PLAN §5 Phase 3 task 5)

Status: **landed & verified**. Grid/list views show real QuickLook
thumbnails (images, PDF; movies/office docs accepted too), written through
to the freedesktop thumbnail cache so restarts are warm.

## Files edited (W3-owned only)

- `nautilus/src/nautilus-macos-thumbnailer.m` — QLThumbnailGenerator backend.
- `nautilus/src/nautilus-thumbnails-macos.c` — backend seam wired to the
  bridge; cache + fail-marker write-back; UTI→MIME normalization in
  `nautilus_thumbnail_is_mimetype_limited_by_size()`.
- `nautilus/src/nautilus-macos-bridge.h` — W3 section only: added
  `nautilus_macos_thumbnail_debug_stats()` (test/bench instrumentation).

Out-of-tree (not in the clone): `scratch-w3/` harness,
`docs/phase3-w3-thumbnails-grid.png` evidence, this note.

## Design decisions

- **Representation type = `.thumbnail` only** (not `.all`). The seam
  contract is one callback per request and the result is cached to disk;
  `.all` delivers interim low-quality/icon representations (multiple
  callbacks, risk of caching a generic icon). With `.thumbnail`, QuickLook
  fails cleanly when it cannot produce a real thumbnail → fail marker.
- **Sizing: request `size×size` at `scale:1.0`, pixels.** The freedesktop
  cache is pixel-based, and the caller passes
  `nautilus_thumbnail_get_max_size()` which already folds in the max
  monitor scale (512 px on this Retina host → `x-large` cache dir). GTK
  handles display scaling; requesting `scale:2.0` would double the pixel
  size and violate the cache-size directory contract.
- **CGImage→GdkPixbuf: CGBitmapContext render into RGBA8888**, buffer handed
  to `gdk_pixbuf_new_from_data` (no copy), alpha un-premultiplied in place
  (CG only draws premultiplied; pixbuf/PNG need straight). Chosen over
  CGImageDestination-PNG + `gdk_pixbuf_new_from_stream` to avoid a full PNG
  encode+decode per thumbnail; conversion runs on QuickLook's completion
  queue, off the GTK thread.
- **can_thumbnail:** QL has no public capability query → accept broad UTI
  families (`public.image`, `public.audiovisual-content`, `com.adobe.pdf`,
  RTF, MS Office/OOXML/ODF/iWork), resolved via `UTType`. Content types
  from GIO on macOS are UTIs ("public.jpeg"); MIME strings from Nautilus's
  hardcoded fallbacks are also handled, with filename-extension fallback
  for generic/dynamic types. Anything accepted that QL then rejects errors
  once and is fail-marked.

## Failure bookkeeping (no retry loops)

On generation failure a 1×1 PNG marker with `Thumb::URI`/`Thumb::MTime` is
written to `<cache>/thumbnails/fail/gnome-thumbnail-factory/<md5(uri)>.png`
— the exact location GIO's `thumbnail::*` reader checks. Consequences,
all harness-verified:

- GIO reports `G_FILE_ATTRIBUTE_THUMBNAILING_FAILED` (+ valid) →
  `file->details->thumbnailing_failed` via existing nautilus-file.c code.
- `nautilus_can_thumbnail()` returns FALSE while a valid marker exists
  (mirrors `gnome_desktop_thumbnail_factory_can_thumbnail`), so
  NautilusImage never re-requests; an mtime change re-enables.

## Cache write-back

Successful thumbnails are saved as PNG with `tEXt::Thumb::URI`,
`tEXt::Thumb::MTime` (+ `tEXt::Software`) to
`<cache>/thumbnails/<size-dir>/<md5(uri)>.png` (atomic
`g_file_set_contents_full`, 0600, dirs 0700). Writes happen in a GTask
worker thread at low priority. The in-memory pixbuf also gets
`tEXt::Thumb::MTime` set (required by `nautilus_file_set_thumbnail`).
`<cache>` is `g_get_user_cache_dir()` — `$XDG_CACHE_HOME` or `~/.cache`
with Homebrew GLib — the same dir GIO's attribute reader uses, so the
existing Phase-1 read path picks cached thumbnails up on restart
(verified: relaunch issues **zero** QuickLook requests).

## Concurrency bound

FIFO + in-flight counter in the .m, cap = 6 (PLAN Phase 4.4 wants 4–8).
All queue state is main-thread-only (no locks); completions re-pump the
queue from the delivery idle. **Phase 4 seam:** viewport prioritization
goes in `pump_request_queue()`/the FIFO — single choke point, comment in
the file. `nautilus_macos_thumbnail_debug_stats()` exposes
in-flight/queued/peak for benchmarks.

## Verification results

Standalone harness (`scratch-w3/run-harness.sh`, compiles the real
`.m` + `.c` from the clone; isolated `XDG_CACHE_HOME`): **49/49 PASS** —
type acceptance (MIME + UTI + extension fallback), pixbufs ≤512 px with
aspect preserved (284×512 portrait case), delivery exactly-once on the
main thread, cache file MD5 name + tEXt attributes, GIO
`thumbnail::path/is-valid/failed` round-trip, corrupt-jpg errors once +
no-retry, 500-burst cap respected (peak in-flight 6, queue drains).

**Phase 4 baseline datapoint (M-series arm64, 512 px, cap 6):**
500-image burst = **1.98 s cold** (253 thumbs/s; freshly generated JPGs,
cold QL agent cache), **1.01–1.54 s warm** re-runs. Thumbnail throughput
is not the grid bottleneck.

In-app (`build-w3/src/nautilus /tmp/w3-thumbs`, no-bus mode since W4's
instance owned the bus name): grid shows real thumbnails for
jpg/png/pdf, generic icons for `.bin` (rejected up front) and
`corrupt.jpg` (failed once, marker written) — screenshot
`docs/phase3-w3-thumbnails-grid.png`, debug log confirms 5 requests, 4
cache writes + 1 fail marker; warm relaunch = 0 requests.

## Integration notes for other workers / integrator

- No dedup of concurrent requests for the same file (upstream's hash-queue
  did this). Two cells requesting the same URI → two QL requests; writes
  are atomic so the cache stays consistent. Cheap to add in the .m FIFO if
  it shows up in Phase 4 profiles.
- Requests are not cancellable mid-flight; `GCancellable` is honored at
  delivery (`nautilus_create_thumbnail_finish` returns CANCELLED). QL
  request cancellation is another Phase 4 option at the same seam.
- `nautilus_thumbnail_is_mimetype_limited_by_size()` now converts UTI
  content types to MIME before consulting gdk-pixbuf's format table —
  relevant to anyone relying on the big-image size limit
  (`nautilus-file.c`, `nautilus-image.c` both call it).
- W2's QLPreviewPanel work is independent (different framework surface);
  no shared state.
