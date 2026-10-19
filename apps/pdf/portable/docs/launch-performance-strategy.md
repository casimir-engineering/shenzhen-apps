# Launch Performance Strategy

Goal: make Shenzhen PDF launch and open PDFs at least as fast as Preview while preserving the exact visible UX.

Status: strategy pass. No launch behavior has been changed in this document.

## Guardrails

- The first visible document must look the same: same zoom, page position, tab state, sidebar/minimap visibility, restored window state, and first crisp page quality.
- No placeholder-only or visibly lower-resolution first page as the final first paint.
- Any lazy work must either be invisible or use exact cached data.
- New behavior must be measurable against Preview and against the current Shenzhen PDF build.
- Optimizations should shrink `ShenzhenPDFMac.mm`, not add more launch logic to it.

## Findings

1. App size and dyld work are larger than Preview.
   - `/Applications/ShenzhenPDF.app` is about 45 MB.
   - The main binary is about 40 MB.
   - Preview is about 7.6 MB on this machine.
   - The main binary has a very large `__TEXT/__const` segment, mostly from statically linked MuPDF resources.
   - The app also links and bundles `libcrypto.3.dylib`, so dyld has extra launch work before app code starts.

2. Mac launch shows the window before document work, but document usability is still blocked by synchronous work.
   - `applicationDidFinishLaunching` builds menu/window, shows the window, then dispatches `performStartupDocumentWork`.
   - `loadSelectedTab` opens the active document synchronously and calls `renderDocumentAndScrollToPage`.

3. First document layout touches every page.
   - `renderDocumentAndScrollToPage` renders the preferred page, then creates placeholders for all pages.
   - Each placeholder calls `placeholderPageAtIndex` with a live document.
   - `placeholderPageAtIndex` calls `spdf_page_size`, which loads and bounds that page if not already cached.
   - On a 117-page document, first open can synchronously load/bound 117 pages before the first usable document display.

4. Layout stabilization is repeated.
   - Cold `loadSelectedTab` calls `stabilizeDocumentLayoutWithRestoreOrigin` twice synchronously and once asynchronously.
   - This may be protecting scroll restoration, but it is a clear target for measurement and simplification.

5. Post-first-paint work is too eager.
   - `schedulePostFirstPaintWorkForGeneration` runs after `kAfterFirstPaintDelay = 0.05`.
   - It queues nearby renders, outline load, comments load, inactive-tab preloading, and search restore in one burst.
   - Inactive-tab preload opens every inactive document and, for each, later opens the same file a second time to render the preferred page.

6. Persistent JSON is currently small on this machine.
   - Current `settings.json`, `session.json`, `documents.json`, and `favorites.json` total under 10 KB.
   - JSON is probably not the current bottleneck, but Mac favorites can still be made lazy like GTK.

## Strategy

### Phase 1: Measure Launch Precisely

Add disabled-by-default diagnostics before changing behavior:

- `portable/mac/SPDFMacDiagnostics.h`
- `portable/mac/SPDFMacDiagnostics.mm`

Measure:

- process start to `applicationDidFinishLaunching`
- menu/window build time
- first window order-front time
- startup document work start
- `spdf_open`
- first-page render
- all-page geometry/placeholder creation
- first document display
- each layout stabilization pass
- minimap update
- sidebar rebuild
- post-first-paint jobs
- inactive-tab preload timing

Use environment flags:

- `SPDF_MAC_PERF=1`
- `SPDF_MAC_PERF_LOG=/tmp/spdf-mac-launch.ndjson`

Acceptance:

- Diagnostics off: no allocations/log formatting on the hot path.
- Diagnostics on: one structured line per phase, enough to compare with Preview and with future builds.

### Phase 2: Exact Page-Geometry Cache

The highest-value no-UX-compromise optimization is to avoid loading every page on launch when exact geometry is already known.

Add a persistent per-document page-geometry cache:

- Store page count, page width/height array, file size, mtime, and maybe a lightweight fingerprint in `documents.json`.
- Invalidate on file attribute mismatch.
- Populate after a document has been fully opened once.
- For restored documents with valid cached geometry, build placeholder pages from exact cached sizes without calling `spdf_page_size` for every page.

Files:

- `portable/core/shenzhen_pdf_core.h`
- `portable/core/shenzhen_pdf_core.c`
- `portable/mac/SPDFMacPageGeometryCache.h`
- `portable/mac/SPDFMacPageGeometryCache.mm`
- narrow call-site changes in `ShenzhenPDFMac.mm`

Important constraint:

- For brand-new documents without geometry cache, keep current exact behavior until we can prove a faster PDF page-tree geometry path is exact. Do not approximate geometry if it would move the scrollbar, minimap, or restored position.

Expected impact:

- Restored documents and recently opened documents should avoid all-page synchronous page-size loading.
- First page remains exactly rendered at the same quality and position.

### Phase 3: Simplify Cold Layout Stabilization

Measure the three stabilization passes, then reduce them only if equivalent:

- Keep one immediate layout/scroll restoration pass.
- Keep one async pass only if the first layout occurs before final split/minimap/sidebar constraints settle.
- Remove duplicate synchronous stabilization if metrics and screenshots prove no scroll/minimap regression.

Acceptance:

- Restored page position identical across continuous and non-continuous modes.
- No minimap viewport mismatch.
- No first-page top-stick regression.
- No tab cross-position contamination.

### Phase 4: Stage Post-First-Paint Work

Replace the single 50 ms burst with tiers:

- Tier 0: first visible page and exact visible viewport.
- Tier 1: nearby visible pages needed for immediate scroll.
- Tier 2: outline/comments and search restore.
- Tier 3: inactive-tab metadata only.
- Tier 4: inactive-tab preferred-page rastering, CPU capped and delayed until the app is idle.

Do not open the same inactive file twice during preload:

- Open once per worker task.
- Build placeholders and render preferred page from the same worker document.
- Apply results in generation-checked main-thread steps.

Acceptance:

- Active tab remains immediately responsive after first paint.
- Tab statuses still update for moved/deleted files.
- Switching to a background tab still has the same visual result; it just should not slow the active launch.

### Phase 5: Binary and Link Hygiene

Investigate launch-size reductions that do not change rendering:

- Generate dSYM and strip the shipped app binary.
- Add dead-strip linker options if safe.
- Measure cold launch before and after strip/dead-strip.
- Keep the executable free of mutable Homebrew runtime dependencies.
- Do not remove MuPDF fonts/resources unless pixel-diff tests prove no document-rendering regression.

Acceptance:

- Bundle launches and codesigns cleanly.
- The direct-GitHub signed/notarized DMG pipeline still works.
- Rendering output unchanged.

### Phase 6: Portable Display Lists and Copy Reduction

After launch measurement and geometry caching:

- Port Windows-style MuPDF display-list caching into the portable core.
- Reduce `spdf_bitmap` to `NSBitmapImageRep` copy overhead by allowing platform ownership/adoption or caller-owned buffers.
- Keep this after geometry caching because first launch of restored documents is currently blocked earlier by page-size discovery.

## Validation Matrix

Compare current build, optimized build, and Preview on:

- Sample Datasheet PDF
- 117-page sample catalogue
- Block diagram PDF
- a small one-page PDF
- an image-heavy PDF

Measure:

- process launch to first window
- launch to first crisp page
- launch to usable scroll/zoom
- CPU burst after first paint
- time until background tab preloads settle

Manual UX checks:

- restored tabs and selected tab
- restored scroll position
- continuous and non-continuous modes
- minimap viewport
- sidebar chapter/comment display
- find/search restore
- tab switching
- Finder-open while already running
- full-screen launch and presentation mode

## Proposed First Implementation Slice

1. Add Mac launch diagnostics.
2. Add page-geometry cache structs and persistence.
3. Use cached exact geometry to build placeholder pages on restored/recent documents.
4. Measure launch before/after on the same PDFs.
5. Only then touch stabilization and post-first-paint scheduling.

This should target Preview-like launch without degrading first-page quality or changing visible layout.
