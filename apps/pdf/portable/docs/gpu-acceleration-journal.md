# GPU Acceleration Exploration Journal

Scope: investigate whether Shenzhen PDF can use Metal on macOS and Vulkan on Linux without changing visual behavior.

Status: read-only exploration complete. No GPU implementation has been started.

## Source State

- Release anchor: `26.6.8-2` is the current release tag.
- The tagged release commit includes the validated Mac tab-drag, zoom-scroll, non-continuous pan, command palette, launch-performance, and zoom/page-turn fixes.
- This journal intentionally lives after the release tag until the GPU work becomes a new implementation branch.

## Agent Reports

1. Mac/Metal expert report
   - Current Mac path: MuPDF rasterizes into CPU RGBA buffers, the app wraps those into `NSBitmapImageRep`/`NSImage`, and `SPDFDocumentView` draws images/crops with AppKit.
   - Metal can help compose already-rendered page, minimap, and viewport-crop bitmaps during pan/zoom.
   - Metal cannot speed up `spdf_render_page_rgba` or `spdf_render_page_region_rgba` in the current architecture, because those are MuPDF CPU pixmap renders.
   - Recommended first prototype: feature-flagged Metal display path with AppKit fallback, page textures first, viewport-crop textures second, visual parity screenshots before optimization.

2. Linux/Vulkan expert report
   - Current Linux path: MuPDF CPU RGBA -> `GdkPixbuf` -> Cairo image surface -> `GtkImage`.
   - Vulkan can remove some Pixbuf/Cairo/presentation overhead and make cached-page movement smoother.
   - GTK 3 integration is high-risk because there is no clean native Vulkan presenter in the current UI structure; a Vulkan canvas would need to recreate geometry, scrolling, hit testing, clipping, and fallback.
   - Recommended first prototype: profiling first, then optional current-page Vulkan presenter only if measurements show significant copy/composite overhead.

3. Core/MuPDF expert report
   - The portable core is bitmap-only today.
   - MuPDF APIs present in this repo do not expose a ready GPU rasterization backend.
   - The reusable low-risk MuPDF feature is display-list caching, already used by the Windows engine.
   - A true GPU/vector rasterizer would be R&D: it would require a new `fz_device` or display-list interpreter with PDF transparency, masks, shadings, images, Type3 fonts, ICC, overprint, and extensive diff testing.

## Current Rendering Architecture

- `portable/core/shenzhen_pdf_core.c`
  - `spdf_render_page_rgba` renders a full page through MuPDF into an `fz_pixmap`, then copies samples into owned RGBA memory.
  - `spdf_render_page_region_rgba` renders a crop/region into an `fz_pixmap`, then copies samples into owned RGBA memory.
- `portable/mac/ShenzhenPDFMac.mm`
  - Wraps RGBA buffers into `NSBitmapImageRep`/`NSImage`.
  - Manages render queues, viewport crop renders, minimap renders, cache byte budgets, and live zoom/pan scheduling.
- `portable/mac/SPDFMacDocumentView.mm`
  - Computes page geometry and draws page backgrounds, shadows, full-page images, minimap fallback images, viewport crop overlays, highlights, selections, and comments through AppKit.
- `portable/linux/ShenzhenPDFGtk.c`
  - Wraps RGBA buffers into `GdkPixbuf`, copies into Cairo surfaces, decorates overlays, and displays each page as `GtkImage`.
  - Linux currently renders full pages; it does not yet use the core region renderer for high-zoom viewport tiles.
- `src/EngineMupdf.*`
  - Windows already uses MuPDF display lists as a CPU-side parse/replay cache. This is the best existing pattern to port into the portable core.

## Ranked Options

1. Instrumentation first
   - Add timing for MuPDF raster, pixel conversion/copy, platform image wrapping, texture/upload if present, draw time, live-zoom frame cadence, pan cadence, and memory pressure.
   - Reason: we need to know whether current pain is CPU rasterization, copies, AppKit/Cairo drawing, cache churn, or event scheduling.
   - Risk: low if behind diagnostics logging/signposts and disabled by default.

2. Portable display-list caching
   - Add optional per-page MuPDF display-list caching in the portable core, modeled after Windows.
   - Reason: this can reduce repeated parse/page interpretation costs while preserving CPU raster fidelity.
   - Risk: medium-low; needs cache invalidation for annotations/comments and memory budgeting.

3. Remove avoidable bitmap copies
   - Let platform callers adopt/free core bitmap memory or render into caller-owned buffers.
   - Reason: current Mac and Linux paths copy CPU pixels multiple times before display.
   - Risk: medium-low; ownership bugs are the main hazard.

4. Unify tiling/crop rendering
   - Mac already uses viewport crops for large/high-zoom pages; Linux should use `spdf_render_page_region_rgba` for the same cases.
   - Reason: avoids huge full-page renders/uploads at high zoom.
   - Risk: medium; geometry parity and cache invalidation must be precise.

5. Metal presenter on Mac
   - Use Metal to draw already-rendered CPU bitmaps as textures while preserving AppKit fallback.
   - Reason: likely helps live pan/zoom smoothness and high-zoom movement with lower CPU draw overhead.
   - Risk: medium-high; color, interpolation, flipped coordinates, overlay parity, texture memory accounting, and stale generation races.

6. Vulkan presenter on Linux
   - Optional only after measurements; GTK 3 integration is invasive.
   - Reason: can reduce Pixbuf/Cairo presentation overhead, but not CPU rasterization.
   - Risk: high; swapchain, Wayland/X11, dependencies, and replacing `GtkImage` layout/event behavior are substantial.

7. True GPU PDF/vector renderer
   - Not recommended for this product round.
   - Reason: visual fidelity risk is extreme, and MuPDF in this repo does not hand us this backend.
   - Risk: very high.

## Proposed Implementation Plan

Phase 0: keep release stable
- Do not mix GPU experiments into the `26.6.8-2` release tag.
- Create a new branch for profiling/GPU exploration.

Phase 1: measurement
- Add disabled-by-default diagnostics.
- Mac: use `os_signpost` or lightweight timers around core render, bitmap wrapping, crop render, draw, live zoom, pan, minimap update.
- Linux: use GLib timers/logging around core render, Pixbuf/Cairo conversion, GTK image update, scroll update, background render.
- Acceptance: no behavior change when diagnostics are off, no measurable launch regression.

Phase 2: portable core improvements before GPU
- Prototype display-list caching for portable core full-page and crop rendering.
- Add copy-reduction API or direct platform buffer ownership.
- Acceptance: pixel-identical output on a representative PDF set, memory bounded, Mac/Linux builds clean, Windows unaffected.

Phase 3: Mac Metal presenter spike
- Add a feature flag, for example an advanced setting or environment variable.
- Start with current visible page only, existing CPU image source, and exact AppKit fallback.
- Keep overlays in AppKit first or in a separate transparent overlay to reduce parity risk.
- Acceptance: screenshots match current AppKit path at 100%, fit page, fit width, high zoom, Retina, selection/highlight/comment, presentation mode.

Phase 4: Linux rendering modernization
- Before Vulkan, port region/tile rendering and cache discipline from Mac to Linux.
- Reassess with measurements.
- If still worthwhile, prototype a single-canvas GPU presenter behind a flag. Consider GTK 4/GSK or OpenGL/EGL as alternatives before committing to raw Vulkan in GTK 3.

## Implementation Agent Plans

Mac first branch
- Create `portable/mac/SPDFMacDiagnostics.h` and `portable/mac/SPDFMacDiagnostics.mm`.
  - Own disabled-by-default diagnostics with `SPDF_MAC_PERF=1`, optional `SPDF_MAC_PERF_LOG=/tmp/spdf-perf.ndjson`, `os_signpost`, and scoped timers.
  - Disabled path must allocate nothing and do no string formatting.
- Create `portable/mac/SPDFMacPageRenderer.h` and `portable/mac/SPDFMacPageRenderer.mm`.
  - Move full-page render wrapper, crop render wrapper, `spdf_bitmap` to `NSBitmapImageRep`/`NSImage` wrapping, and render metrics out of `ShenzhenPDFMac.mm`.
- Modify `portable/core/shenzhen_pdf_core.h` and `portable/core/shenzhen_pdf_core.c`.
  - Add optional `spdf_render_stats` and `_with_stats` variants for full-page and region rendering.
  - Existing APIs delegate with `stats=NULL`.
- Modify `portable/mac/SPDFMacDocumentView.mm` and `portable/mac/ShenzhenPDFMac.mm` only at call sites.
  - Record draw, live zoom, pan, crop scheduling, render queue wait/apply, and cache eviction timings.
  - Do not add diagnostics machinery to `ShenzhenPDFMac.mm`.
- For the later Metal spike, create `SPDFMacPagePresenter.*` and `SPDFMacMetalPresenter.*`.
  - Feature flag `SPDF_MAC_METAL=1`.
  - AppKit fallback remains default.
  - Metal draws page backgrounds, shadows, full-page textures, and viewport-crop textures under AppKit overlays.
  - Add `-framework Metal` and `-framework QuartzCore` only when the spike starts.

Linux first branch
- Create `portable/linux/ShenzhenPDFGtkPerf.h` and `portable/linux/ShenzhenPDFGtkPerf.c`.
  - Own env-gated diagnostics with `SHENZHENPDF_GTK_PERF=1`, optional `SHENZHENPDF_GTK_PERF_FILE=/tmp/spdf-gtk.log`.
  - Log compact structured lines for render, copy, apply, scroll, background queue, and eviction timings.
- Create `portable/linux/ShenzhenPDFGtkRender.h` and `portable/linux/ShenzhenPDFGtkRender.c`.
  - Own render request/output structs, bitmap-to-surface conversion, search/selection overlay drawing, Pixbuf fallback, and optional direct-Cairo backend.
  - Default backend remains current Pixbuf/Cairo path.
- Create `portable/linux/ShenzhenPDFGtkPageView.h` and `portable/linux/ShenzhenPDFGtkPageView.c`.
  - Move page slot creation, page-index widget data, render-state helpers, sizing, clearing, and distant-surface eviction out of `ShenzhenPDFGtk.c`.
- Modify `portable/linux/ShenzhenPDFGtk.c` only to assemble requests and call the new modules.
- Modify `portable/Makefile` to include the new Linux sources.
- Do not enable Vulkan in this branch.

Validation for implementation branches
- Run clang-format on touched `.c`, `.h`, and `.mm` files.
- Run `git diff --check`.
- Mac: `clang++ -std=c++17 -fobjc-arc -Icore -I../mupdf/include -fsyntax-only mac/*.mm`, `make -C portable mac-app`, app version smoke, diagnostics-off smoke, diagnostics-on log smoke.
- Linux: syntax check with GTK cflags, `make -C portable linux`, version smoke, diagnostics-on log smoke.
- Manual Mac validation: normal PDF, long PDF, high zoom, continuous and single-page modes, quick zoom in/out, pan, tab switch during in-flight render, minimap drag, oversized page crop, search highlights, selection, comments, links, context menu, presentation.
- Manual Linux validation: small PDF, long 100+ page PDF, image-heavy PDF, continuous and single page, fit width/page, 400% zoom, search highlights, selection, comments, minimap, presentation.

## Decision

Do not start with Metal/Vulkan as the first performance task. Start with instrumentation, display-list caching, copy reduction, and Linux tiling. Metal is a plausible Mac compositor after that. Vulkan on current GTK 3 is a later, higher-risk experiment.
