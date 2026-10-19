#pragma once

/* Internal to the Windows frontend, like spdf_win_headless.h next to it.
 * Header-only so no build source list outside this directory needs a new .cpp,
 * and included from spdf_win_main.cpp AFTER `struct app` because it depends on
 * it.
 *
 * The --render-window-png path: the continuous canvas, scrolled and zoomed,
 * composed into a WIC bitmap and written as a PNG, with the geometry it used
 * printed to stdout. Split out of spdf_win_main.cpp for the same reason
 * spdf_win_headless.h was -- to keep that file inside the size ratchet
 * (tools/file-size-limits.md) -- when the chrome model pushed it over.
 *
 * This path is how fit modes and scroll were checked for the whole port before
 * anyone could open a window, and it is still how they are checked: it and the
 * window call the same spdf_win_paint(), and the window's client area has been
 * measured byte-identical to what this produces at the same size and dpi
 * (portable/docs/windows-native-observations.md). Its printed geometry is the
 * oracle the pixel cases crop against, so the format of those two `frame` lines
 * is load-bearing -- portable/win/tests/run-tests-native.d2d.sh parses them.
 */

/* Everything --render-window-png can be told. Defaults are the window's own:
 * fit-width, no extra scroll, 96 dpi. */
struct viewport_opts {
    spdf_win_zoom_mode mode;
    float zoom;      /* > 0 overrides the mode */
    float scroll_x;  /* added to the top of `page` */
    float scroll_y;
    float dpi_scale;
    float zoom_at_x; /* < 0 means "no zoom-at step" */
    float zoom_at_y;
    float zoom_factor;
    /* Render N frames, scrolling a viewport height between each. One
     * invocation is one process, so this is the only way to observe anything
     * that is supposed to happen BETWEEN frames -- notably whether the worker
     * pool had the next page ready. Only the last frame is written. */
    int frames;
    /* Compose the window CHROME too -- tab strip, toolbar, sidebar, minimap --
     * and lay the canvas out inside what is left, exactly as the window does.
     *
     * This exists so the chrome is verifiable at all. spdf_win_paint() draws the
     * chrome through the same ID2D1RenderTarget as the pages and never touches
     * an HWND, so with this flag the offscreen path produces the whole window's
     * pixels. Without it the headless frame is a bare canvas, which is what
     * every pre-chrome pixel case compares and must keep comparing. */
    int chrome;
    /* With --chrome: the sidebar section to show when there is no query,
     * 1 for Comments; 0 (the zeroed default) leaves the window's own choice,
     * which the resolve cascade turns into Comments anyway on a document with
     * comments and no chapters. Filled by a `--sidebar-section N` flag in
     * spdf_win_main.cpp's option parser (a one-line patch requested of the
     * wiring pass; the field is harmless until it lands). */
    int sidebar_section;
};

/* One more machine-readable line, emitted only when chrome is on, so a caller
 * can crop a window capture to precisely the region the pages were drawn into.
 * portable/win/verify-phase1.ps1 parses it. */
static void print_chrome_geometry(const char* label, const SpdfWinChromeLayout* l) {
    printf("%s chrome canvas=%.0f,%.0f,%.0f,%.0f tabstrip=%.0f toolbar=%.0f sidebar=%.0f minimap=%.0f\n", label,
           l->canvas.x, l->canvas.y, l->canvas.w, l->canvas.h, l->tabstrip.h, l->toolbar.h, l->sidebar.w,
           l->minimap.w);
}

/* One machine-readable block per frame, on stdout. The consumer is a script
 * that crops the macOS reference render to the same source rectangle, so the
 * numbers here are the interface: change them and the comparison silently
 * starts measuring something else. */
static void print_geometry(const char* label, spdf_win_canvas* canvas, const spdf_win_scene* scene) {
    printf("%s viewport=%ux%u zoom=%.6f scroll=%.4f,%.4f content=%.4f,%.4f page=%d cache=%zu sync=%d started=%llu\n",
           label, scene->target_px_w, scene->target_px_h, (double)spdf_win_canvas_zoom(canvas),
           (double)spdf_win_canvas_scroll_x(canvas), (double)spdf_win_canvas_scroll_y(canvas),
           (double)spdf_win_canvas_content_w(canvas), (double)spdf_win_canvas_content_h(canvas),
           spdf_win_canvas_current_page(canvas), spdf_win_canvas_cache_bytes(canvas),
           spdf_win_canvas_sync_renders(canvas), spdf_win_canvas_prefetched(canvas));
    for (int i = 0; i < scene->page_count; ++i) {
        const spdf_win_page_draw* d = &scene->pages[i];
        printf("%s draw page=%d dest=%.4f,%.4f size=%.4f,%.4f bitmap=%dx%d\n", label, d->page_index, (double)d->dest_x,
               (double)d->dest_y, (double)d->dest_w, (double)d->dest_h, d->bitmap ? d->bitmap->width : 0,
               d->bitmap ? d->bitmap->height : 0);
    }
}

static int run_viewport(app* a, spdf_win_d2d* d2d, const wchar_t* wpath, int page_index, unsigned px_w, unsigned px_h,
                        const viewport_opts* opts, const wchar_t* out_png) {
    spdf_win_scene scene;
    HRESULT hr;

    if (px_w == 0 || px_h == 0) {
        report(L"The viewport must have a non-zero width and height.", false);
        return 64;
    }
    if (!open_document(a, wpath, page_index, false)) return 1;

    /* Chrome first when asked for, because it decides how big the canvas is --
     * the same order spdf_win_main.cpp's scene_for_window uses, so the two paths
     * cannot disagree about the canvas size. */
    SpdfWinChromeLayout chrome_layout;
    SpdfWinChromeModelInputs chrome_inputs;
    unsigned canvas_w = px_w, canvas_h = px_h;
    int chrome_h_scrollable = 0;
    if (opts->chrome) {
        chrome_inputs_for(a, &chrome_inputs, opts->dpi_scale);
        spdf_win_chrome_model_build(&a->chrome, &a->chrome_tabs, a->tabs, &chrome_inputs);
        chrome_scroll_into(a, &a->chrome);
        spdf_win_chrome_layout(&a->chrome, px_w, px_h, opts->dpi_scale, &chrome_layout);
        /* Latched for the frame, exactly as scene_for_window does and for the
         * same reason: the canvas is about to be sized against THIS layout, so
         * the model the painter finally reads must not disagree about whether
         * there is a horizontal trough. */
        chrome_h_scrollable = a->chrome.h_scrollable;
        canvas_w = (unsigned)chrome_layout.canvas.w;
        canvas_h = (unsigned)chrome_layout.canvas.h;
    }

    spdf_win_canvas_set_viewport(a->canvas, canvas_w, canvas_h, opts->dpi_scale);
    if (opts->zoom > 0.0f) spdf_win_canvas_set_zoom_at(a->canvas, opts->zoom, 0.0f, 0.0f);
    else spdf_win_canvas_set_zoom_mode(a->canvas, opts->mode);

    /* A SECOND PASS, ONLY FOR THE HORIZONTAL TROUGH, AND ONLY HERE.
     *
     * Whether the content overflows sideways is not knowable until the zoom has
     * been applied, and the zoom cannot be applied until the canvas has a
     * viewport, which needs the layout, which needs to know about the trough.
     * The window resolves that circle in TIME -- scene_for_window() reads a
     * canvas that already carries the previous frame's zoom, so the trough
     * appears on the paint that follows the zoom, one frame later at worst. A
     * one-shot render has no next frame, so without this it could never show a
     * horizontal scroller at all. Re-laying out costs one idempotent
     * set_viewport and happens only when the verdict actually changed.
     *
     * The geometry line is printed AFTER this, exactly once: it is the oracle
     * portable/win/tests/run-tests-native.d2d.sh and verify-phase1.ps1 crop
     * against, and printing a pre-settle rect there would silently point them at
     * the wrong rectangle. */
    if (opts->chrome) {
        chrome_scroll_into(a, &a->chrome);
        if (a->chrome.h_scrollable != chrome_h_scrollable) {
            chrome_h_scrollable = a->chrome.h_scrollable;
            spdf_win_chrome_layout(&a->chrome, px_w, px_h, opts->dpi_scale, &chrome_layout);
            spdf_win_canvas_set_viewport(a->canvas, (unsigned)chrome_layout.canvas.w,
                                         (unsigned)chrome_layout.canvas.h, opts->dpi_scale);
        }
        print_chrome_geometry("frame", &chrome_layout);
    }

    /* Anchor on the page, then apply the offset. Expressing the scroll
     * relative to a page rather than in absolute canvas pixels is what makes a
     * case like "the boundary between page 0 and page 1" mean the same thing
     * at every zoom and on every document. */
    spdf_win_canvas_scroll_to_page(a->canvas, page_index);
    spdf_win_canvas_scroll_by(a->canvas, opts->scroll_x, opts->scroll_y);

    memset(&scene, 0, sizeof(scene));
    /* spdf_win_canvas_build_scene() overwrites target_px_w/h with the CANVAS
     * viewport, so the chrome has to be given the client size separately. */
    if (opts->chrome) {
        scene.chrome = &a->chrome;
        scene.client_px_w = px_w;
        scene.client_px_h = px_h;
    }
    if (opts->zoom_at_x >= 0.0f) {
        /* Render the pre-zoom scene first so the anchor can be checked: the
         * document point under (zoom_at_x, zoom_at_y) is derivable from these
         * numbers, and must land back on the same viewport pixel afterwards. */
        spdf_win_canvas_build_scene(a->canvas, &scene);
        print_geometry("pre", a->canvas, &scene);
        spdf_win_canvas_zoom_at(a->canvas, opts->zoom_factor, opts->zoom_at_x, opts->zoom_at_y);
        memset(&scene, 0, sizeof(scene));
        if (opts->chrome) {
            scene.chrome = &a->chrome;
            scene.client_px_w = px_w;
            scene.client_px_h = px_h;
        }
    }
    spdf_win_canvas_build_scene(a->canvas, &scene);
    /* So --render-window-png --chrome shows highlights too. See the note in
     * spdf_win_chrome_scene.h; this is the same call on the scene that is
     * actually written out. */
    spdf_win_find_apply_overlays(&scene);
    print_geometry("frame", a->canvas, &scene);

    /* Extra frames, each a viewport further down, with the pool given a moment
     * to land its prefetch in between -- the wait a real reader's hand supplies
     * for free and a back-to-back loop does not. `sync=` on each frame is the
     * measurement: 0 means every visible page was already in the cache. */
    for (int frame = 1; frame < opts->frames; ++frame) {
        char label[32];
        spdf_win_canvas_scroll_by(a->canvas, 0.0f, (float)px_h);
        spdf_win_canvas_settle(a->canvas, 4000);
        memset(&scene, 0, sizeof(scene));
        spdf_win_canvas_build_scene(a->canvas, &scene);
        spdf_win_find_apply_overlays(&scene);
        _snprintf_s(label, sizeof(label), _TRUNCATE, "frame%d", frame);
        print_geometry(label, a->canvas, &scene);
    }

    /* Rebuild the model now the canvas has settled, so the toolbar's page, zoom
     * and fit readouts describe the frame about to be written -- the same second
     * build scene_for_window does, for the same reason. */
    if (opts->chrome) {
        /* LET AN ASYNC SEARCH LAND BEFORE THE ONE FRAME THIS PROCESS WILL EVER
         * DRAW.
         *
         * The window gets this free: it polls, the search delivers in batches,
         * and each batch invalidates, so highlights appear over the next few
         * frames. A single --render-window-png invocation has no next frame, so
         * without a settle it composes the instant the query was set and shows
         * the search field and the Search sidebar section but NOT a single
         * highlight -- which reads as "the overlays are not wired" when they are.
         *
         * It matters beyond convenience: spdf_win_paint() needing no desktop is
         * what makes the chrome pixel-testable offscreen, and that property is
         * worth nothing for find if the offscreen path can never show a match.
         *
         * Bounded, and it polls rather than sleeps blindly: a search that never
         * finishes costs the timeout once, not a hang. The same shape as
         * spdf_win_canvas_settle() above it. */
        SpdfWinFindSession* find;
        int spins = 0;
        int section = 0;

        chrome_inputs_for(a, &chrome_inputs, opts->dpi_scale);
        spdf_win_chrome_model_build(&a->chrome, &a->chrome_tabs, a->tabs, &chrome_inputs);
        chrome_scroll_into(a, &a->chrome);
        a->chrome.h_scrollable = chrome_h_scrollable;

        /* FIND, AND THE ORDER HERE IS THE WHOLE POINT.
         *
         * Two things conspire on this path and each is invisible alone.
         *
         * First, spdf_win_chrome_model_build() takes the document from the
         * selected TAB, and this path has no tabs -- it opened one document
         * directly -- so it calls spdf_win_find_fill_model(model, NULL), which
         * hands the session a NULL path and DISCARDS whatever search was
         * running. Any settle done before that build is thrown away by it. So
         * the path is set after the build, never before.
         *
         * Second, the window gets its results free -- it polls, results arrive
         * in batches, each batch invalidates, highlights appear over the next
         * few frames -- but a single --render-window-png invocation has no next
         * frame. Without a settle it composes the instant the query was set and
         * shows the search field and the Search sidebar section but NOT ONE
         * highlight, which reads as "the overlays were never wired" when they
         * are. That matters beyond convenience: spdf_win_paint() needing no
         * desktop is what makes the chrome pixel-testable offscreen, and that is
         * worth nothing for find if the offscreen path can never show a match.
         *
         * Hence: build, then set the document, then settle, then re-fill so the
         * counter reflects what the settle earned. The second fill is cheap and
         * does not restart anything -- spdf_win_find_set() only restarts when
         * the document or the query actually changed. */
        spdf_win_find_fill_model(&a->chrome, a->path);
        find = spdf_win_find_shared();
        while (find && spdf_win_find_searching(find) && spins < 500) {
            spdf_win_find_poll(find);
            Sleep(10);
            ++spins;
        }
        if (find) spdf_win_find_poll(find);
        spdf_win_find_fill_model(&a->chrome, a->path);

        /* THE SEARCH SECTION, OFFSCREEN. The window decides the sidebar per paint
         * in scene_for_window (chrome_sidebar_decide, chrome_publish_search);
         * this path built its model directly and so never chose a section or
         * published the results the sidebar painter reads. With a query, do
         * what a search START does in the window (spdf_win_chrome_field_ui.h):
         * show the Search section -- then resolve and publish exactly as the
         * window would, so the compose proves the results list and the strip
         * markers with no desktop. Without a query this is the Chapters
         * section it always was. */
        if (a->find_text[0]) spdf_win_sidebar_set_section(2);
        else if (opts->sidebar_section > 0) spdf_win_sidebar_set_section(opts->sidebar_section);
        section = chrome_sidebar_decide(a, NULL);
        a->chrome.sidebar_section = section;
        a->chrome.sidebar_has_content = spdf_win_sidebar_effective_visible();
        chrome_publish_search(a, &chrome_layout, section, opts->dpi_scale);

        /* Re-derive the overlays now the matches exist. The earlier call, right
         * after build_scene, ran against an empty result set. scene->pages is
         * still the list build_scene produced, so this recomputes rather than
         * re-laying out. */
        spdf_win_find_apply_overlays(&scene);
        /* THE COMMENTS, OFFSCREEN: the markers over the pages and, with
         * --sidebar-section 1, the Comments list -- after find, as the window
         * orders them (spdf_win_chrome_scene.h chrome_publish_comments). The
         * cache loads on this one frame: with no window there is no next one. */
        chrome_publish_comments(a, &scene, &chrome_layout, section, opts->dpi_scale);
    }
    hr = spdf_win_render_scene_to_png(d2d, px_w, px_h, &scene, out_png);
    if (FAILED(hr)) {
        wchar_t message[256];
        _snwprintf_s(message, _TRUNCATE, L"Compose to %s failed (hr=0x%08lX)", out_png, (unsigned long)hr);
        report(message, false);
        return 1;
    }
    wprintf(L"wrote %s\n", out_png);
    return 0;
}
