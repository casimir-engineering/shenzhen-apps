# ShenzhenPDF — Architecture & Implementation Notes

A practical map of how the app is built and *why* it's built that way, with the
non‑obvious lessons that were expensive to learn. Read this before touching the
rendering, scrolling, zoom, or minimap code — most of the subtle behaviour there
is load‑bearing.

---

## 1. What it is

ShenzhenPDF is a fast, native PDF reader built on **mupdf**. It has:

- A **portable C core** (`portable/core/shenzhen_pdf_core.{c,h}`) wrapping mupdf:
  open documents, query page sizes/counts, render a page or a *region* of a page
  to an RGBA bitmap, search, outline, comments, destinations. Rendering is
  cancellable via a `spdf_render_token` (an `fz_cookie` under the hood).
- A **macOS front‑end** (`portable/mac/`, ObjC++) — the primary, most complete
  target. ~21k LOC, dominated by `ShenzhenPDFMac.mm` (~14.7k LOC).
- A **GTK/Linux front‑end** (`portable/linux/`, C) kept at rough parity.

The two front‑ends share only the C core. UI logic is **not** shared; the Linux
port re‑implements behaviour against the same core.

### Build & run (macOS)

```
make -C portable mac-app      # builds ../dist/ShenzhenPDF.app (ad-hoc signed)
make -C portable install      # ditto to /Applications + lsregister
```

Run the binary directly (e.g. to pass env vars) with:
`"/Applications/ShenzhenPDF.app/Contents/MacOS/ShenzhenPDF"`.

Useful diagnostic env vars:
- `SPDF_ZOOM_PROFILE=1` — `spdf_zoom_profile_log` + `SPDFScopedProfileLog`
  print any instrumented main‑thread op over its threshold (e.g. `drawRect`,
  `updateMinimap`, `evictDistantRenderedPageImages`, the `ADOPT-PAGE`/`ADOPT-CROP`
  markers). The first stop for "why is X slow".
- `SPDF_LAUNCH_PROFILE=1` — launch timing. The first line stamps the kernel
  spawn time, so every later `@…` stamp reads as time‑since‑spawn.
- `SPDF_RENDER_WORKERS=N` — force foreground render concurrency (A/B the
  memory‑bandwidth hypothesis).
- `SPDF_STATE_DIR=<path>` — use this directory instead of
  `~/Library/Application Support/ShenzhenPDF` for settings.yaml, session.yaml
  and every other state file. **Set this for any measurement or test launch**:
  the app rewrites settings and session on every launch and quit, so an
  un‑redirected profiling run silently replaces the real session with its own.
  Everything that reads or writes state must go through
  `spdf_mac_support_directory()` for this to hold.
- `SPDF_NO_ACTIVATE=1` — skip the launch‑time `activateIgnoringOtherApps:`, so
  `open -g -j -n -a <app> --env … <doc>` really does launch hidden and in the
  background instead of stealing focus. Launch only; user‑initiated window
  raises still activate.

A non‑disruptive launch measurement is therefore:

```
open -g -j -n -a dist/ShenzhenPDF.app --stderr /tmp/launch.log \
  --env SPDF_LAUNCH_PROFILE=1 --env SPDF_NO_ACTIVATE=1 \
  --env SPDF_STATE_DIR=/tmp/spdf-scratch  <document>
```

Note that passing the document to `open` (as above) exercises the
LaunchServices `odoc` path — what Finder does — while `--args <document>`
exercises the command‑line path. They differ; measure the one you mean.

---

## 2. macOS file map

| File | Role |
|---|---|
| `ShenzhenPDFMac.mm` | The everything‑controller: `ShenzhenMacDelegate` owns the window, scroll view, the **render pipeline**, scroll/zoom/minimap orchestration, tabs, search, OCR, translation, the permissions wizard. Most of this doc lives here. |
| `SPDFMacDelegatePrivate.h` | The delegate's ivars (the class extension). |
| `SPDFMacDocumentView.{h,mm}` | `SPDFDocumentView` — the scrollable page canvas. Owns the **continuous layout** and `drawRect:`. |
| `SPDFMacMinimapView.{h,mm}` | `SPDFMinimapView` — the page‑thumbnail strip on the right (theme chrome and find/selection overlays in `SPDFMacMinimapViewTheme.mm` / `SPDFMacMinimapViewOverlays.mm`). |
| `SPDFMacUIHelpers.{h,mm}` | `SPDFScrollView` (custom scroll), **`SPDFDocumentClipView`** (the horizontal‑lock clip view), `SPDFWindow`, misc views, `spdf_ui_clamp_cg`. |
| `SPDFMacModels.{h,mm}` | `SPDFRenderedPage` — the per‑page model holding the various cached images. |
| `SPDFMacTabStripView.mm` | The tab bar. |
| `SPDFMacFileWatcher.mm` | FSEvents auto‑reload. |
| `SPDFMacDefaultReader.mm`, `SPDFMacSupport.mm`, `SPDFMacPrintView.mm`, `SPDFMacWindowShortcuts.mm`, `ShenzhenMacDelegate+ShortcutHelp.mm` | "Make default" handler, support utilities, printing, window‑management shortcuts, the shortcut cheat‑sheet. |

The front‑end talks to the controller through the `SPDFMacUIReader` protocol
(declared in `SPDFMacUIHelpers.h`); views call `self.reader` for everything.

---

## 3. The rendering pipeline (the heart of the app)

This is where almost all of the performance work lives. Get the mental model
right and the rest follows.

### 3.1 Per‑page model: `SPDFRenderedPage`

One instance per document page, held in `_renderedPages` (a stable
`NSMutableArray` — same object across scrolls; elements get **replaced** on
render, not mutated, except eviction which nils image fields in place). Each page
can hold several independently‑cached images:

- **`image`** — the full‑page render at the current `zoom` × `backingScale`
  ("display scale"). The crisp, normal case.
- **`viewportImage`** — a *crop*: just the visible region of the page, rendered
  at display scale. Used when a full‑page render is too big to allow (see below).
- **`baseImage`** — a low‑res whole‑page render (the "navigation base"), used as
  a fallback under the sharp content and as a zoom seed.
- **`highQualityImage`** — a high‑quality whole‑page render for zoom seeding.
- **`minimapImage`** — the page's thumbnail for the minimap strip. **Never
  evicted** (small, persistent for the document's lifetime).
- **`zoomSeedImage`** — whatever image we hand to live‑zoom to scale during a
  pinch before the real render lands.

`drawRect:` draws the best available, in priority order
(`image ?: highQualityImage ?: baseImage ?: minimapImage`), then overlays the
sharp `viewportImage` crop on the focused region.

### 3.2 Full‑page render vs. **crop regime**

`renderDisplayScaleForPageWidth:…` returns 0 if a full‑page render at the
requested scale would exceed `kMaxRenderedPageBitmapByteLimit` (96 MB) or the max
dimension. `fullPageRenderAllowedForPage:` is just "is that > 0".

- **Normal pages** → full‑page render allowed → `image`.
- **Oversized pages** (e.g. a 10919×7539 pt schematic) → full render disallowed
  → **crop regime**: render only the visible viewport (`viewportImage`) at
  display scale, plus a capped‑scale whole‑page **navigation base**
  (`cappedFullPageDisplayScaleForPage:`, the largest scale that fits one bitmap)
  so panning inside the page shows real content instead of the tiny thumbnail.

This dual regime is *the* reason the document‑view drawing and the render
scheduling have two paths everywhere. The huge‑page handling (nav base, crop
prefetch, "neighbours of a tall page stay blank") was a large chunk of the work.

### 3.3 Render queues (concurrency & QoS matter a lot)

Set up in the controller init (~`_renderQueue = …`):

| Queue | Concurrency | QoS | Carries |
|---|---|---|---|
| `_renderQueue` | `min(3, cpu-1)` | **UserInitiated** | visible crops; full‑page renders enqueued with `forceHighPriority:YES` |
| `_backgroundRenderQueue` | 1 | Utility | full‑page renders with `forceHighPriority:NO` (visible + prefetch on the trackpad path) |
| `_zoomSeedRenderQueue` / `_cacheRenderQueue` | 1 | Utility | HQ / base zoom‑seed caches |
| `_minimapQueue` | ≤2 | Utility | minimap thumbnails |

**Lesson:** `_renderQueue` is deliberately capped at ~3. The comment there is
real — *"more than a few concurrent page renders saturates memory bandwidth and
stalls main‑thread input even though the work is off‑main."* Do not raise it.

**Counter‑intuitive routing:** the minimap‑drag scroll path enqueues visible
renders at `forceHighPriority:YES` (→ `_renderQueue`), while ordinary trackpad
scrolling uses `forceHighPriority:NO` (→ the 1‑wide Utility
`_backgroundRenderQueue`). So when chasing a scroll stall, *background render
contention was a red herring* — the trackpad path is on the gentle queue.

**The viewport renders side by side when nothing is moving.** Once an open has
painted, after an explicit jump (`goToPage:`) and when a scroll settles (the
300 ms idle tail of the maintenance tick), `spdf_queueViewportPageRendersNow`
(`SPDFMacViewportRenderPriority.mm`) sends every page intersecting the viewport
to `_renderQueue` together, withdraws ones still waiting on the background
queue (an operation cannot change queues), and demotes render‑queue work still
waiting for pages the viewport has left. Before (26.10.11) those pages came
through the maintenance tick onto the 1‑wide queue and rendered one after
another: on a 10‑page A3 vector set at Fit Page, 2x, the neighbours peeking in
at a restored page 7 were sharp ~830 ms after the open, a jump to page 30 of
40 took ~530 ms, and key‑repeat paging queued the last page behind every page
passed. The open's own page is still the synchronous first paint and nothing
runs before it; trackpad scrolling keeps the gentle queue while it moves.
`mac-page-load-tests` pins all of this.

### 3.4 Render completion: the "adoption" blocks

A render finishes on a background queue, then hops to the main queue to "adopt"
the result into the model + view. There are several adoption blocks:
`ADOPT-PAGE` (full‑page), `ADOPT-CROP` (viewport crop), base, and HQ. **These
run on the main thread, once per completed render**, so they must be cheap.

This was the single biggest source of scroll stutter. Rules now enforced:

- **Image‑only update must not invalidate layout.** Replacing a page object and
  doing `_pageView.pages = renderedPages` calls `setPages:`, which does
  `invalidateLayoutCache` (→ an O(total‑pages) layout rebuild on the next frame)
  **and** `setNeedsDisplay:YES` (whole‑view redraw). Per completion, while
  scrolling down through fresh pages, that was death. Use
  `[_pageView refreshRenderedPages:changedPageIndex:]` instead — it swaps the
  array but, because page *sizes* are unchanged, re‑points the layout cache at
  the new array (keeping it valid) and repaints only the changed page.
- **Don't touch the minimap from a render completion.** A completed full‑page
  render never changes a minimap *thumbnail* (those have their own pipeline). The
  old code called `applySearchHighlightsToCurrentPage` (which does a full
  `updateMinimap` + `_pageView.pages` reassignment) on every adoption — pure
  waste; removed. It does, however, *replace* the page object, which leaves the
  strip's `pages` snapshot holding the old one; see §7 for how a thumbnail that
  lands afterwards still reaches the strip.
- **Coalesce eviction.** `scheduleRenderAdoptionMaintenance` debounces the
  O(n) eviction sweep to ~80 ms instead of running it per completion.

### 3.5 Eviction

`evictDistantRenderedPageImages` (main thread, coalesced) frees `image`,
`viewportImage`, `highQualityImage`, `baseImage` for pages outside a keep window
(`kRenderedImageKeepRadius = 12` around the current page, plus visible±1 and all
queued pages), but **only under memory pressure** (`> kRenderedImageSoftByteLimit`,
192 MB → trims to 128 MB target). `minimapImage` is **never** evicted.

Because evicted images are nil'd *in place* on the shared page objects, the view
already sees the change — do **not** reassign `_pageView.pages` after eviction.

### 3.6 Prefetch

- Neighbour full‑page renders: `enqueueCurrentPageNeighborhoodRendersForGeneration`
  with a **zoom‑scaled radius** (`zoomScaledNeighborhoodRenderRadius`, ~2
  viewports of pages each side, capped at the keep radius). Zoomed out → wide
  radius (small pages, fast turnover); zoomed in → ±2. Memory stays balanced
  because zoomed‑out renders are individually small.
- Minimap thumbnails: a generous band around the visible strip
  (`visiblePageIndexesWithPaddingScreens:`, 2.5 strip‑heights each side).
- Both are driven from the coalesced scroll maintenance tick, *not* per scroll
  event, and the heavy passes run only every ~6th tick (~200 ms).

---

## 4. The document view (`SPDFDocumentView`)

### 4.1 Continuous layout

Always continuous (single‑page mode was removed). `ensureLayoutCache` computes,
per page, its rect in document space and caches them (`_layoutContinuousPageRects`),
invalidating only when zoom/pages/viewport‑width/backing‑scale/bounds change.
`_layoutGeneration` bumps on every rebuild — used to invalidate the
`pageIndexForVisibleRect:` memo.

**All pages are centred on the canvas midline.** The canvas is as wide as the
widest page; each page is centred within `max(viewportWidth, widestPage)`. This
is why a mixed‑size document (one giant page + normal pages) keeps every page's
centre on one vertical axis instead of bunching the small ones at the left.

### 4.2 Drawing

`drawRect:` fills the dirty rect, then iterates pages with a top‑to‑bottom cull
(`continue` above the dirty rect, `break` below it) and draws each visible page.
Notes:
- The view is `isOpaque` (it always fills its dirty rect) so AppKit skips
  backdrop compositing during scroll.
- The drop shadow is a **cached** `NSShadow` (it used to be allocated per page
  per frame — measurable on the trackpad path).

### 4.3 `pageIndexForVisibleRect:`

O(total pages) scan, **memoized** on `(rect, currentPage, layoutGeneration)` and
short‑circuited with a monotonic early‑out, because the scroll path calls it
several times per event. Don't un‑memoize it.

---

## 5. Scrolling

There are **three** ways the viewport moves, and they take different code paths.
Keeping them in sync is a recurring source of bugs.

1. **Trackpad (precise) scroll** — `SPDFScrollView scrollWheel:` →
   `scrollPreciseTrackpadEventWithDamping:`. It computes a damped delta, scrolls
   via `scrollToPoint:`, **synchronously flushes the redraw** (`displayIfNeeded`,
   to keep content locked to the scroll position), and posts
   `documentScrollPositionChanged`. It suppresses the bounds‑change notification
   around `scrollToPoint:` so `documentScrollPositionChanged` runs *once* (it
   used to double‑fire, doubling the O(n) page‑index scans).
2. **Hand‑drag pan** — `SPDFDocumentView` `continuePanWithEvent:` /
   `stepPanInertia:` → `documentViewPanToProposedOrigin:` (a reader hook that
   applies the page‑aware clamp).
3. **Minimap drag** — sets `_minimapPrecisionViewportDragActive` and scrolls via
   `scrollDocumentClipViewToDocumentOrigin:`; `documentScrollPositionChanged`
   takes an **early‑return** branch doing minimal work. This is the "gold
   standard smooth" path — when something stutters on trackpad but not on minimap
   drag, the difference is whatever the full `documentScrollPositionChanged` path
   does that the early‑return skips.

`documentScrollPositionChanged` is the hub: it detects page changes (defers the
heavy follow‑up via `schedulePageChangeFollowUp`), updates the horizontal lock,
moves the lightweight minimap indicator, and arms the coalesced maintenance tick.

### 5.1 Horizontal scroll lock (`SPDFDocumentClipView`)

The clip view exposes `horizontalLockMinX`/`horizontalLockMaxX`. `constrainBoundsRect:`
clamps `origin.x` into that range (and the precise‑scroll path re‑applies it
since `scrollToPoint:` bypasses `constrainBoundsRect:`). `updateHorizontalScrollLock`
decides, from the **dominant** page only:

- **Page fits the viewport** → `min == max == centeredX`: pinned centred, no
  horizontal panning, no rubber‑band (elasticity off). Crossing *to* this state
  from a wider page **eases** to centre (a 60 Hz timer, `stepHorizontalLockEase:`).
- **Page wider than the viewport** → `min = pageMinX`, `max = pageMaxX − clipW`:
  pan *within the page only*. (Before this was "free", which on a mixed‑size doc
  let a zoomed‑in small page scroll off its edge into empty canvas — the
  regression that prompted the range design.)
- Presentation / live‑zoom / minimap‑drag → NaN (free).

### 5.2 Page‑centred horizontal origin

`centeredHorizontalScrollOriginXForPageRect:` returns the x that centres a page
on the canvas midline (≈0 for uniform docs, so they're unaffected). Every
"scroll to a narrow page" path uses it instead of `origin.x = 0`, so narrow pages
in a wide‑canvas (mixed‑size) document are shown centred, not at the left.

---

## 6. Zoom

Live zoom (pinch / Cmd‑scroll) goes through `beginLiveZoomByFactor:centeredAtWindowPoint:`
→ `setZoomWithoutRendering:` which captures a **page anchor** (the page + the
point under the cursor), changes `_zoom`, resizes the document view, and re‑scrolls
so the anchored point stays under the cursor. During live zoom the existing
`zoomSeedImage` is scaled; the crisp re‑render lands on `finishLiveZoom`.

Gotchas:
- The horizontal lock is **released at the start of each zoom step** — otherwise
  a lock value computed for the old (smaller) canvas pins `origin.x` and drags
  the cursor‑anchored zoom toward the left as the canvas grows.
- Zoom‑seed cache warming is deferred to scroll‑idle (not per page crossing).

---

## 7. The minimap (`SPDFMinimapView`)

A vertical strip of page thumbnails with a viewport indicator and a draggable
"long‑document" scrubber.

- **Thumbnails** (`minimapImage`) are rendered on `_minimapQueue` and patched
  individually into place; they persist (never evicted).
- **The strip draws a snapshot.** `pages` is a copy of `_renderedPages`, taken
  by the full `updateMinimap`. ADOPT‑PAGE replaces page objects, so a thumbnail
  finishing after its page's full render is stored on an object the snapshot
  does not hold. The completion therefore hands the strip the live object
  (`noteThumbnailLoadedForPage:`), which swaps it into the snapshot when the
  geometry matches and patches only that slot. Before this (26.10.11), a
  restored 10‑page A3 set at page 7 showed thumbnails 1–4 and placeholders for
  5–10 until a scroll reassigned `pages`: the neighbours of page 7 render first,
  their thumbnails last. `mac-minimap-fill-tests` pins this interleaving.
- **Width cap:** an oversized page's thumbnail is capped at
  `kMinimapMaxWidthRatio` (2.5×) the *median* page width, so one giant page
  doesn't shrink the normal thumbnails to dots.
- **Indicator** tracks the scroll at display rate via the lightweight
  `updateMinimapViewportIndicator` (just the visible rect + `setNeedsDisplay`),
  separate from the full `updateMinimap`.
- **The strip cache pitfall (important):** the strip *can* be cached as one
  bitmap and translated during scroll, but for a long document that bitmap is
  many thousands of px tall, and **every rebuild and every per‑thumbnail
  `lockFocus` patch pays for the whole bitmap** (tens of ms each). So the cache
  is capped (`kLiveContentCacheMaxHeight`/`Pixels`); past that the strip draws
  the **visible slice directly** (~1 ms, only a handful of thumbnails on screen).
  Also: the selected‑page outline is a per‑frame overlay, **not** baked into the
  cached bitmap (otherwise every page crossing invalidates the cache).

---

## 8. Problems encountered — the expensive lessons

A condensed record so future‑me doesn't re‑derive these.

### The scroll‑stutter saga (the big one)
Symptom: smooth on minimap drag, stutters on trackpad — worse the further *down*
you scroll, clears going *up*, and absent at high zoom. The instinct ("it's
render/CPU performance") was **wrong every time**. The real causes, found only by
instrumenting (a gated `SPDF_SCROLL_DEBUG` timeline that logged the gap between
scroll events and what ran in it):

1. **Per‑render‑completion `updateMinimap`** (via `applySearchHighlightsToCurrentPage`
   and via a false‑idle reading in `scheduleRenderAdoptionMaintenance`). Each
   call invalidated the minimap strip cache → a full‑strip `lockFocus` rebuild on
   the next frame. Going *down* renders new pages → many completions → many
   rebuilds; going *up* the pages are cached → none. High zoom → few page
   crossings → fewer completions. **This** is why the symptom correlated with
   everything it did.
2. **The giant strip bitmap** made each rebuild/patch tens of ms (§7).
3. **`setPages:` per completion** invalidated the *document* layout cache and
   forced a whole‑view redraw — fixed with `refreshRenderedPages:`.

Method that worked: stop guessing, instrument the gap between scroll events, and
read what ran during the dropped frame. The "minimap drag is smooth" invariant
was the key — it isolated the culprit to "things the full scroll path does that
the minimap early‑return path skips".

### Other notable fixes
- **Neighbours of a tall page stayed blank** while scrolling within it: a page
  many viewports tall pins `_pageIndex`, so the page‑change‑triggered neighbour
  scheduling never re‑fired. Fixed by scheduling visible‑set + neighbourhood
  renders from the coalesced maintenance tick.
- **Cursor‑anchored zoom jumping to far‑left** on big docs: a stale horizontal
  lock pinning `origin.x` (§6).
- **Page‑switch jumped "too high"**: relative‑position remap across mismatched
  page heights; top‑align when the target is ≫ the source height.
- **Out‑of‑focus pinch never worked**: needed `kCGHIDEventTap` + Accessibility,
  not a session listen‑only tap (Input Monitoring).

---

## 9. Invariants & gotchas to remember

- **The minimap‑drag scroll path is the smoothness reference.** If trackpad
  stutters but minimap drag doesn't, the bug is in the work the full
  `documentScrollPositionChanged` path does that the early‑return branch skips —
  not in rendering.
- **Anything that runs per render completion must be O(1)‑ish.** No
  `updateMinimap`, no `setPages:`, no O(n) eviction inline.
- **`_pageView.pages = …` is expensive** (copy + layout invalidate + full
  redraw). For image‑only updates use `refreshRenderedPages:changedPageIndex:`.
- **`updateMinimap` (full) invalidates the strip cache** via the `pages`
  reassignment. Use `updateMinimapForScrolling` / `updateMinimapViewportIndicator`
  on hot paths; reserve full `updateMinimap` for idle/layout changes.
- **`minimapImage` is never evicted; everything else is** (under pressure).
- **The horizontal lock is a *range*, not a point.** Narrow → pinned centre;
  wide → page bounds; never the whole canvas.
- **Two rendering regimes** (full‑page vs crop) — most render/draw code branches
  on `fullPageRenderAllowedForPage:`. The crop regime is the oversized‑page path.
- **`_renderQueue` concurrency is capped on purpose** (memory bandwidth).
- **Opens, jumps and settled scrolls queue the viewport through
  `spdf_queueViewportPageRendersNow`** (§3.3). Left to the scroll tick, the
  viewport's pages render one after another on the 1‑wide queue.
- **Profiling first.** `SPDF_ZOOM_PROFILE=1` already instruments the main
  suspects with thresholds; reach for it before theorising.
- **Direct GitHub release signing** depends on the publisher's Developer ID
  certificate; ad-hoc signing churns the signature on every reinstall, which resets TCC grants
  (Full Disk Access / Accessibility) — relevant when the permissions wizard
  reports "not granted" after a reinstall.

## Control icon rendering

UI control icons use SF Symbols or vector drawing handlers, never pre-rendered
bitmap assets. `SPDFMacIconGeometry.h` preserves each source's natural aspect
ratio and draws it without an NSImage raster cache. Keep the hit target separate
from the glyph slot. Icon buttons redraw on geometry/backing-scale changes;
center interim layer contents rather than stretching a stale image. Sidebar
button frames align to backing pixels, including fractional panel widths. The
headless `mac-icon-rendering-tests` target verifies redraw, laziness and aspect
ratio. This policy concerns interface icons, not document images or thumbnails.
