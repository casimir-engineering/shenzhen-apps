#pragma once

/* The PAINT-TIME half of the Windows frontend's app glue: what the chrome model
 * is filled from, and the one callback spdf_win_window.h calls before every
 * frame.
 *
 * SPLIT OUT OF spdf_win_chrome_actions.h, which is where all of this used to
 * live, when the scroller work pushed that file past the 500-line cap. The seam
 * is a real one rather than a convenience: everything here runs on the PAINT
 * path and knows only how to describe the document to the chrome, while what is
 * left next door runs on the INPUT path and knows how to change the document.
 * The two touch at exactly two functions -- chrome_scroll_into(), which the
 * router needs because the scroller fractions are geometry, and
 * chrome_fit_for_zoom_mode(), which the fit cycle needs -- and both are here,
 * because a value's definition belongs with the code that produces it.
 *
 * Header-only and included from spdf_win_main.cpp AFTER `struct app`, exactly
 * like spdf_win_tabs_app.h, spdf_win_headless_viewport.h and
 * spdf_win_chrome_actions.h beside it, and BEFORE spdf_win_chrome_actions.h,
 * which calls the two functions named above. Not part of the port's public
 * surface.
 *
 * THE SIDEBAR IS DECIDED HERE, ONCE PER PAINT, the way mac rebuildSidebar
 * (ShenzhenPDFMac.mm:9552-9580) decides it: the panel exists only while the
 * document has something to list -- chapters, comments (none on Windows yet) or
 * a live search -- AND the reader wants it; the section shown is the chosen one
 * if it has content, else the first that does. Both answers are published
 * through spdf_win_sidebar_view.h's side channels so the input router's layout
 * (spdf_win_chrome_actions.h chrome_layout_for_input) reads the same ones the
 * painter drew with; the model fields the painter reads are set directly.
 */

/* For spdf_win_chrome_content_set_document(): scene_for_window tells the panels
 * which document is selected. Included here rather than relying on it arriving
 * through spdf_win_main.cpp's include order, which is what left this header
 * depending on a declaration it never asked for. */
#include "spdf_win_annot.h"
#include "spdf_win_md_code.h" /* the code pills' geometry, published per paint */       /* the comment cache, markers and Comments rows */
#include "spdf_win_chrome_content.h"
#include "spdf_win_chrome_find.h" /* spdf_win_find_apply_overlays */
#include "spdf_win_search_map.h"  /* spdf_win_map_marks_publish */
#include "spdf_win_sidebar_view.h"

/* --- state the paint path owns and the input path reads --------------------
 *
 * Statics rather than fields on `app`: the struct belongs to another file, and
 * there is one app per process. spdf_win_chrome_field_ui.h (included after this
 * header, same translation unit) reads all four. */

/* The Search section's rows, built from the find session; created on the first
 * paint that shows the section, freed never -- it lives as long as the process
 * and is one struct plus its arena. */
static SpdfWinSidebarResultsBuilder* g_results_builder;
/* The list rect the results were laid out in, client px, for the wheel. */
static SpdfWinChromeRect g_results_list;
/* The same for the Comments section's list. */
static SpdfWinChromeRect g_comments_list;
/* One per scene_for_window: the comment cache's frame clock
 * (spdf_win_annot_sync defers a new document's load to a later frame). */
static unsigned g_paint_frame;
/* Armed by every way a search STARTS (spdf_win_chrome_field_ui.h
 * chrome_find_start); consumed by chrome_find_reveal_if_pending() below once
 * the search settles. */
static int g_find_reveal_pending;
/* The DPI scale of the last paint, for the one input-side hit that needs
 * points -> pixels without a layout in hand (the results rows). */
static float g_chrome_dpi = 1.0f;
/* Defined in spdf_win_chrome_field_ui.h; declared here so the paint path can
 * run the reveal at the moment results have arrived. */
static int chrome_find_reveal_if_pending(app* a);
/* Defined in spdf_win_md_commands.h, which main.cpp includes after this header
 * because it calls show_selected_tab(). Declared here for the same reason as
 * the line above: the toolbar's A−/A＋ pill exists only on a Markdown tab, so
 * both the paint path (chrome_inputs_for, below) and the input path
 * (chrome_layout_for_input) need the answer, and both run before that header
 * is reached. One test, one definition. */
static int spdf_win_md_selected_tab_is_markdown(app* a);

/* The canvas's zoom mode in the vocabulary the toolbar speaks.
 *
 * Two enums rather than one because spdf_win_chrome.h must not include
 * spdf_win_canvas.h -- the chrome is drawn in tests that have no canvas, no
 * document and no MuPDF -- so this is the seam, and it is four lines now that
 * the canvas has the Fit Height mode macOS always had
 * (SPDF_WIN_ZOOM_FIT_HEIGHT). */
static int chrome_fit_for_zoom_mode(spdf_win_zoom_mode mode) {
    switch (mode) {
        case SPDF_WIN_ZOOM_FIT_WIDTH: return SPDF_WIN_CHROME_FIT_WIDTH;
        case SPDF_WIN_ZOOM_FIT_HEIGHT: return SPDF_WIN_CHROME_FIT_HEIGHT;
        case SPDF_WIN_ZOOM_FIT_PAGE: return SPDF_WIN_CHROME_FIT_PAGE;
        case SPDF_WIN_ZOOM_ACTUAL: return SPDF_WIN_CHROME_FIT_ACTUAL;
        default: return SPDF_WIN_CHROME_FIT_CUSTOM;
    }
}

/* The scroller fractions, straight from the canvas into the model the painters
 * and the router read. Kept out of chrome_inputs_for() below because
 * SpdfWinChromeModelInputs belongs to spdf_win_chrome_model.h, whose build
 * function would have to learn about them; assigning after the build is a
 * two-line seam instead, and the model documents these fields as the window
 * layer's to fill. */
static void chrome_scroll_into(app* a, SpdfWinChromeModel* m) {
    spdf_win_canvas_scroll scroll;
    spdf_win_canvas_scroll_state(a->canvas, &scroll);
    m->v_pos = scroll.v_pos;
    m->v_visible = scroll.v_visible;
    m->h_pos = scroll.h_pos;
    m->h_visible = scroll.h_visible;
    m->h_scrollable = scroll.h_scrollable;
}

/* Everything the chrome shows about the document, read from the canvas ONCE per
 * paint and handed to the model. The painters never reach for any of it
 * themselves: spdf_win_chrome_paint.h's whole arrangement is that a painter works
 * from a hand-built model with no app behind it, which is what lets the window's
 * appearance be pixel-tested offscreen. */
static void chrome_inputs_for(app* a, SpdfWinChromeModelInputs* in, float dpi_scale) {
    spdf_win_chrome_model_inputs_init(in);
    in->dark = (a->render_flags & SPDF_RENDER_DARK_THEME) != 0;
    /* The EFFECTIVE visibility, decided by scene_for_window before the build
     * and published for the router (spdf_win_sidebar_view.h). */
    in->show_sidebar = a->show_sidebar && spdf_win_sidebar_effective_visible();
    /* NO MINIMAP WITHOUT A DOCUMENT, which is macOS's own force
     * (-setMinimapActuallyVisible: is `visible && [self hasActiveDocument]`,
     * ShenzhenPDFMac.mm:9137, and showEmptyDocumentViewWithMessage: calls it with
     * NO at :5267). The empty window used to draw a bare strip down its right
     * edge with nothing in it -- and the same test greys the Map switch beside
     * it, so the switch and the strip now agree. The ROUTER's model applies the
     * identical clause (chrome_layout_for_input), because show_minimap IS
     * geometry: it takes the strip's width out of the canvas. */
    in->show_minimap = a->show_minimap && a->canvas != NULL;
    in->sidebar_w = a->sidebar_w;
    in->minimap_w = a->minimap_w;
    in->hot_tab = a->hot_tab;
    in->hot_close = a->hot_close;
    in->drag_tab = a->drag_tab;
    in->drop_slot = a->drop_slot;
    in->focus = a->focus;
    /* NULL unless the page field is the one being typed into, which is what
     * tells the toolbar to show the typed text rather than the current page.
     * See SpdfWinChromeModel::page_text. */
    in->page_text = a->focus == SPDF_WIN_FOCUS_PAGE ? a->page_text : NULL;
    in->sidebar_row_count = a->sidebar_rows;
    in->markdown = spdf_win_md_selected_tab_is_markdown(a);
    in->zoom_dpi_scale = dpi_scale > 0.0f ? dpi_scale : 1.0f;
    if (!a->canvas) return;
    /* 0-BASED out of the canvas and 0-BASED into the model. The `+ 1` that makes
     * it a human's page number happens once, in the toolbar painter. */
    in->page_index = spdf_win_canvas_current_page(a->canvas);
    in->page_count = spdf_win_canvas_page_count(a->canvas);
    in->zoom = spdf_win_canvas_zoom(a->canvas);
    in->fit_mode = chrome_fit_for_zoom_mode(spdf_win_canvas_zoom_mode(a->canvas));
}

/* THE COMMENT CACHE, synced to the selected tab's document for this paint. A
 * document seen for the first time is loaded on the NEXT frame, which this
 * asks for, so the first page is on screen before the annotation walk begins
 * (spdf_win_annot.h). Returns the comment count known so far. */
static int chrome_annot_sync(app* a) {
    char err[256] = {0};
    const char* path = NULL;
    spdf_document* doc = NULL;
    int deferred = 0;
    if (a->canvas && a->tabs) {
        int sel = spdf_win_tabs_selected_index(a->tabs);
        if (sel >= 0) {
            path = spdf_win_tabs_path(a->tabs, sel);
            doc = (spdf_document*)spdf_win_tabs_document(a->tabs, sel, err, sizeof(err));
        }
    } else if (a->canvas) {
        /* The headless paths open one document directly and have no tabs. */
        path = a->path;
        doc = a->doc;
    }
    int count = spdf_win_annot_sync(doc, path, g_paint_frame, &deferred);
    if (deferred) {
        /* Windowed: ask for the next frame, which loads. Headless
         * (--render-window-png): there is no next frame and no launch budget
         * to protect, so the one frame there is carries the markers. */
        if (a->window) spdf_win_window_invalidate(a->window);
        else count = spdf_win_annot_count(doc, path);
    }
    return count;
}

/* WHAT THE SIDEBAR HAS TO LIST, and therefore whether it exists and which
 * section it shows. Resolves the content provider -- which loads the outline
 * on the first call that needs it -- only while the reader wants the panel, so
 * a hidden sidebar still costs nothing (spdf_win_chrome_content.h rule 2).
 * Publishes the effective visibility and returns the resolved section. */
static int chrome_sidebar_decide(app* a, int* out_has_chapters) {
    int has_chapters = 0;
    int has_comments = 0;
    int has_search = a->find_text[0] != L'\0';
    int section;
    if (a->canvas && a->show_sidebar) {
        const SpdfWinChromePanelsContent* content = spdf_win_chrome_content_current();
        const SpdfWinSidebarContent* sb = content ? content->sidebar : NULL;
        /* Not loaded yet means not known yet: keep the panel rather than blink
         * it away for the one frame before the outline is read. */
        has_chapters = sb ? (!sb->loaded || sb->total_count > 0) : 0;
        /* Comments: the cache is what the markers are drawn from anyway, so
         * asking it here costs nothing the paint was not going to pay. */
        has_comments = chrome_annot_sync(a) > 0;
    }
    spdf_win_sidebar_set_effective_visible(a->canvas != NULL && (has_chapters || has_comments || has_search));
    section = spdf_win_sidebar_resolve_section(spdf_win_sidebar_section(), has_chapters, has_comments, has_search);
    if (out_has_chapters) *out_has_chapters = has_chapters;
    return section;
}

/* The Comments section's rows for this paint, and the markers' geometry and
 * overlays over the pages the canvas just placed. `scene` may carry no pages
 * (no document, or nothing built), in which case only the rows are published. */
static void chrome_publish_comments(app* a, spdf_win_scene* scene, const SpdfWinChromeLayout* layout, int section,
                                    float dpi) {
    g_comments_list = spdf_win_chrome_zero();
    if (!a->canvas) {
        spdf_win_sidebar_comments_publish(NULL);
        spdf_win_annot_publish_geometry(NULL, 0.0f, 0.0f, 1.0f);
        spdf_win_md_code_frame(NULL, NULL, NULL, 0.0f, 0.0f, 1.0f);
        return;
    }
    chrome_annot_sync(a);
    if (section == 1 && !spdf_win_chrome_rect_empty(layout->sidebar)) {
        SpdfWinSidebarLayout sb;
        spdf_win_sidebar_layout(layout->sidebar, 1, dpi, &sb);
        g_comments_list = sb.list;
        spdf_win_sidebar_comments_publish(spdf_win_annot_sidebar_build(a->filter_text, sb.list.h, dpi));
    } else {
        spdf_win_sidebar_comments_publish(NULL);
    }
    if (!scene) return;
    /* Marks in CLIENT px for the router (the canvas rect's origin added);
     * overlays in canvas-local px like every other producer's. Third in the
     * chain find -> selection -> comments, the mac's draw order (:485, :492). */
    spdf_win_annot_publish_geometry(scene, layout->canvas.x, layout->canvas.y, spdf_win_canvas_zoom(a->canvas));

    /* And the code box's pills, from the same document and the same rectangle.
     * spdf_win_md_code_frame() carries the policy -- rebuild only when the path
     * or the options generation changed, clear when there is no document -- so
     * this call site holds none of it. */
    {
        char md_err[256] = {0};
        const char* md_path = NULL;
        spdf_document* md_doc = NULL;
        if (a->tabs) {
            int sel = spdf_win_tabs_selected_index(a->tabs);
            if (sel >= 0) {
                md_path = spdf_win_tabs_path(a->tabs, sel);
                md_doc = (spdf_document*)spdf_win_tabs_document(a->tabs, sel, md_err, sizeof(md_err));
            }
        } else {
            md_path = a->path;
            md_doc = a->doc;
        }
        spdf_win_md_code_frame(md_doc, md_path, scene, layout->canvas.x, layout->canvas.y,
                               spdf_win_canvas_zoom(a->canvas));
    }
    spdf_win_annot_apply_overlays(scene, spdf_win_canvas_zoom(a->canvas));
}

/* The Search section's rows for this paint, and the strip's markers -- both
 * published for painters that cannot reach the session. `layout` is this
 * frame's, so the list height the reveal-scroll uses is the one the rows are
 * drawn into. */
static void chrome_publish_search(app* a, const SpdfWinChromeLayout* layout, int section, float dpi) {
    SpdfWinFindSession* s = spdf_win_find_shared();
    int n = 0, active = -1;
    const SpdfWinFindPageMark* marks = s ? spdf_win_find_page_marks(s, &n, &active) : NULL;
    spdf_win_map_marks_publish(marks, n, active);

    g_results_list = spdf_win_chrome_zero();
    if (section == 2 && s && !spdf_win_chrome_rect_empty(layout->sidebar)) {
        SpdfWinSidebarLayout sb;
        if (!g_results_builder) g_results_builder = spdf_win_sidebar_results_builder_new();
        spdf_win_sidebar_layout(layout->sidebar, 2, dpi, &sb);
        g_results_list = sb.list;
        spdf_win_sidebar_results_publish(
            spdf_win_sidebar_results_build(g_results_builder, s, a->chrome.searching, sb.list.h, dpi));
    } else {
        spdf_win_sidebar_results_publish(NULL);
    }
}

/* THE PAINT-TIME GLUE. Chrome first, because it decides how big the canvas is.
 *
 * The model is rebuilt per paint rather than cached: it is a few dozen bytes plus
 * one UTF-16 conversion per tab, and a cached copy is how a closed tab keeps
 * being drawn -- or how a page indicator keeps reading 4 after the reader has
 * scrolled to 40. `a->chrome_tabs` owns the titles the model borrows and must
 * therefore live as long as the paint, which is why it is a field on `app`. */
static int scene_for_window(void* user, spdf_win_scene* scene) {
    app* a = (app*)user;
    SpdfWinChromeModelInputs inputs;
    SpdfWinChromeLayout chrome_layout;
    unsigned client_w, client_h;
    int h_scrollable_this_frame;
    int section, has_chapters = 0;

    client_w = scene->client_px_w ? scene->client_px_w : scene->target_px_w;
    client_h = scene->client_px_h ? scene->client_px_h : scene->target_px_h;
    g_chrome_dpi = scene->dpi_scale > 0.0f ? scene->dpi_scale : 1.0f;
    ++g_paint_frame;

    /* NO DOCUMENT: still a window, not a blank one.
     *
     * Reached two ways -- a bare launch with nothing to restore, and the moment
     * after the last tab closed while the pump drains. Returning 0 here used to
     * paint an empty gutter-coloured client with no chrome at all, which for the
     * bare-launch case would read as "the app is broken" rather than "open
     * something". So the chrome is built exactly as below (zero tabs, controls
     * greyed by the model's has_document rule) and one line in the canvas region
     * says what to do. Every canvas call is skipped; nothing here needs one.
     *
     * target_px_w/h are set to the CANVAS region's size because that is what
     * spdf_win_canvas_build_scene() would have done and what draw_message()
     * lays the text out against -- inside the translate spdf_win_paint applies
     * for chrome, so the hint centres in the document area, not the client.
     *
     * No document means no sidebar (mac hasSidebar requires _doc), which
     * chrome_sidebar_decide publishes before the build reads it. */
    if (!a->canvas) {
        /* Release the panels' content: with no selected document the sidebar
         * and minimap must not keep showing the one that just closed. */
        spdf_win_chrome_content_set_document(NULL, 0);
        section = chrome_sidebar_decide(a, NULL);
        chrome_inputs_for(a, &inputs, scene->dpi_scale);
        spdf_win_chrome_model_build(&a->chrome, &a->chrome_tabs, a->tabs, &inputs);
        chrome_scroll_into(a, &a->chrome); /* NULL-safe: reports "nothing to scroll" */
        a->chrome.sidebar_section = section;
        scene->chrome = &a->chrome;
        spdf_win_chrome_layout(&a->chrome, client_w, client_h, scene->dpi_scale, &chrome_layout);
        scene->target_px_w = (unsigned)chrome_layout.canvas.w;
        scene->target_px_h = (unsigned)chrome_layout.canvas.h;
        /* The READING theme is the scene's, not the model's, and it is normally
         * spdf_win_canvas_build_scene() that copies it across from the canvas's
         * render flags. With no canvas nobody does, so the painter picked the
         * light palette for the gutter and chrome while the model -- which had
         * the flag -- drew the dark theme's sun glyph and DWM darkened the
         * caption. Measured on a dark machine: a light window under a dark title
         * bar. Set it from the same flags the canvas would have carried. */
        scene->dark = (a->render_flags & SPDF_RENDER_DARK_THEME) != 0;
        a->sidebar_rows = 0;
        a->chrome.sidebar_row_count = 0;
        chrome_publish_search(a, &chrome_layout, section, g_chrome_dpi);
        chrome_publish_comments(a, NULL, &chrome_layout, section, g_chrome_dpi);
        /* THE HEADLINE ONLY, now that the canvas has a button.
         *
         * This line used to be the whole empty state: "No document open —
         * Ctrl+O to open one, or drop a PDF here". Naming a shortcut is not an
         * affordance, and it was the ONLY thing on that window a reader could
         * act on -- everything else was drawn live and was not. The call to
         * action is a real button now and the drop hint sits under it, both from
         * spdf_win_chrome_empty.h, so what is left here is the STATE. macOS's
         * own placeholder is exactly this long: @"Open a document"
         * (ShenzhenPDFMac.mm:861).
         *
         * `a->status` still outranks it, and that is why this stays a message
         * rather than moving into the chrome painter with the button: an error
         * from a failed open has to be able to take this line. */
        scene->message = a->status[0] ? a->status : L"No document open";
        return 1;
    }

    /* Tell the panels which document is selected and where the reader is in it
     * BEFORE anything asks them what they have to list. The app is the only
     * thing that knows both; left to itself the content bridge guesses from the
     * process command line, so the sidebar listed the LAUNCH document's outline
     * and the minimap its thumbnails even after a Ctrl+Tab, next to a canvas
     * showing the right pages. Passing the live current page also makes the
     * minimap's current-page outline follow scrolling instead of pinning to the
     * page the window opened on.
     *
     * Cheap by construction: same path is a strcmp and two stores. */
    {
        int sel = a->tabs ? spdf_win_tabs_selected_index(a->tabs) : -1;
        const char* sel_path = sel < 0 ? NULL : spdf_win_tabs_path(a->tabs, sel);
        spdf_win_chrome_content_set_document(sel_path ? sel_path : a->path,
                                            spdf_win_canvas_current_page(a->canvas));
        spdf_win_chrome_content_set_filter(a->filter_text);
    }
    section = chrome_sidebar_decide(a, &has_chapters);

    /* Built twice, and deliberately. The first build only has to be right about
     * GEOMETRY, because it decides the canvas rect; the readouts it carries are
     * whatever the canvas said BEFORE this frame's viewport and fit were applied.
     * The second build, after the canvas has settled, is the one the painter
     * reads -- so a resize that re-fits the zoom shows the zoom it re-fitted to,
     * not the one it had a frame ago. Neither build can change the layout: every
     * field spdf_win_chrome_layout() looks at is identical in the two. */
    chrome_inputs_for(a, &inputs, scene->dpi_scale);
    spdf_win_chrome_model_build(&a->chrome, &a->chrome_tabs, a->tabs, &inputs);
    chrome_scroll_into(a, &a->chrome);
    a->chrome.sidebar_section = section;
    scene->chrome = &a->chrome;
    spdf_win_chrome_layout(&a->chrome, client_w, client_h, scene->dpi_scale, &chrome_layout);
    /* WHETHER THERE IS A HORIZONTAL TROUGH IS DECIDED ONCE PER FRAME, HERE.
     *
     * `h_scrollable` is the one model field spdf_win_chrome_layout() reads, and
     * the trough it adds comes out of the canvas's HEIGHT. Under fit-page or
     * fit-height that height feeds back into the zoom, which feeds back into the
     * content width, which feeds back into h_scrollable -- so re-asking the
     * canvas after the viewport has been set could return a different answer
     * from the one this frame's canvas rect was computed with, and the painter
     * would draw a trough into space the pages were told they could have.
     * Latching the first answer for the frame makes the layout and the viewport
     * agree exactly; a trough that has just become necessary appears on the next
     * paint, which is what a scrollbar does anyway. */
    h_scrollable_this_frame = a->chrome.h_scrollable;

    /* The canvas is laid out against the CANVAS REGION, not the client area, so
     * fit-width fits the space the reader can actually see. spdf_win_paint()
     * translates the page rects into that region, so everything downstream keeps
     * working in canvas-local coordinates. */
    spdf_win_canvas_set_viewport(a->canvas, (unsigned)chrome_layout.canvas.w, (unsigned)chrome_layout.canvas.h,
                                 scene->dpi_scale);
    if (a->pending_page > 0) {
        spdf_win_canvas_scroll_to_page(a->canvas, a->pending_page);
        a->pending_page = -1;
    }
    /* A search that has just settled moves the view to its match NOW, before
     * the second build reads the scroll position -- the first build's
     * fill_model is what polled the results in. */
    chrome_find_reveal_if_pending(a);
    chrome_inputs_for(a, &inputs, scene->dpi_scale);
    spdf_win_chrome_model_build(&a->chrome, &a->chrome_tabs, a->tabs, &inputs);
    chrome_scroll_into(a, &a->chrome);
    a->chrome.h_scrollable = h_scrollable_this_frame;
    a->chrome.sidebar_section = section;
    a->chrome.sidebar_has_content = spdf_win_sidebar_effective_visible();

    /* HOW MANY ROWS THE LIST IS SHOWING, cached for the input router, which
     * has no way to ask -- resolving the content provider on a mouse move
     * would put the outline load on the pointer's path. Read only while the
     * sidebar is VISIBLE, because spdf_win_chrome_content_current() is what
     * loads the outline and spdf_win_chrome_content.h's rule 2 is that nothing
     * runs for a panel nobody is looking at. The Search section's rows are the
     * published view's business (spdf_win_chrome_field_ui.h chrome_sidebar_row),
     * so the count here is the Chapters list's. */
    if (a->chrome.show_sidebar && section == 0) {
        const SpdfWinChromePanelsContent* content = spdf_win_chrome_content_current();
        a->sidebar_rows = content && content->sidebar ? content->sidebar->row_count : 0;
    } else {
        a->sidebar_rows = 0;
    }
    a->chrome.sidebar_row_count = a->sidebar_rows;
    chrome_publish_search(a, &chrome_layout, section, g_chrome_dpi);

    /* Search highlights, AFTER build_scene because that is what fills
     * scene->pages, which is what the overlay rects are derived from. Reads only
     * pages/page_count/target_px_h/dpi_scale and writes only overlays; a no-op
     * with no live query, and it does not even create a session then.
     *
     * TWO OVERLAY PRODUCERS, AND THE ORDER IS macOS'S DRAW ORDER: find's
     * highlights (SPDFMacDocumentView.mm:467), find's active ring (:475), then
     * the selection (:485). find OVERWRITES scene->overlays -- it says so at its
     * declaration -- and the selection compositor takes whatever is there as an
     * immutable base and APPENDS after it, so the two compose only in this
     * order. Reversed, the selection vanishes on the next keystroke of a query.
     * Both calls come after spdf_win_canvas_build_scene(), which is what fills
     * scene->pages and therefore what both derive their rects from. */
    if (spdf_win_canvas_build_scene(a->canvas, scene)) {
        spdf_win_find_apply_overlays(scene);
        spdf_win_canvas_apply_selection_overlays(a->canvas, scene);
        chrome_publish_comments(a, scene, &chrome_layout, section, g_chrome_dpi);
        return 1;
    }
    spdf_win_find_apply_overlays(scene);
    spdf_win_canvas_apply_selection_overlays(a->canvas, scene);
    chrome_publish_comments(a, scene, &chrome_layout, section, g_chrome_dpi);
    /* THE APP'S STATUS OUTRANKS THE CANVAS'S, AND ONLY WHEN IT HAS ONE. This
     * used to assign unconditionally, which threw away the message
     * build_scene had just put on the scene whenever the app had nothing to
     * say -- harmless while the only frame with no page draws was a broken
     * document, and wrong the moment a frame can also mean "the first page is
     * still rendering" (spdf_win_canvas_set_first_frame_budget). */
    if (a->status[0]) scene->message = a->status;
    return 1;
}
