#pragma once

/* spdf_win_chrome_field_ui.h -- the toolbar's find group, which field has the
 * keyboard, the sidebar's rows and segments, and how a search STARTS.
 *
 * Split out of spdf_win_chrome_actions.h for the reason
 * tools/file-size-limits.md gives, and along the seam that appeared when the
 * chrome became typeable: the file next door decides what a point MEANS and
 * performs the commands that change the DOCUMENT, and this one holds the
 * things that change what the CHROME is showing about it -- where the keyboard
 * is, what the query is, which match is current, which section and which row
 * was clicked.
 *
 * Header-only and included from spdf_win_main.cpp after `struct app` and
 * spdf_win_chrome_scene.h and BEFORE spdf_win_chrome_actions.h, whose
 * chrome_perform() calls every function here. Same arrangement as
 * spdf_win_chrome_tabs_ui.h and spdf_win_chrome_canvas_ui.h beside it. The
 * minimap's pointer handlers come in through spdf_win_search_map_ui.h, so
 * spdf_win_main.cpp's include list did not have to grow.
 *
 * HOW A SEARCH STARTS, and the four ways in -- all of them one function,
 * chrome_find_start(), so they cannot drift:
 *
 *   typing        a printable character with no field focused REPLACES the
 *                 query with it and gives the field the keyboard
 *                 (documentTypeToSearchKeyDown, ShenzhenPDFMac.mm:10169);
 *   Ctrl+F        with a live selection searches for the selection, whitespace
 *                 collapsed (focusFind :12134, GTK spdf_search_focus);
 *   Ctrl+V        with nothing focused searches for the clipboard text
 *                 (paste: :12151, GTK clipboard_text_ready);
 *   the field     every keystroke, as before.
 *
 * Every start also (a) shows the Search section, as macOS's
 * showSearchSidebarForFind does on every startFind, and (b) arms the REVEAL:
 * when the search settles, the view jumps to the first match -- or, with the
 * "search jumps to the nearest result" setting on (the default), to the match
 * nearest the reader's position (:10653, spdf_win_search_nearest_match). The
 * reveal runs at paint time, because that is when results arrive.
 */

#include "spdf_win_annot.h"    /* the Comments section's rows */
#include "spdf_win_annot_model.h" /* spdf_win_annot_bounds_have_area */
#include "spdf_win_settings.h" /* searchJumpsToNearestResult, from the process-wide settings */
#include "spdf_win_menu.h"      /* SPDF_WIN_MENU_ID_BASE, for chrome_post_command */
#include "spdf_win_search_map_ui.h"
#include "spdf_win_selection.h" /* spdf_win_clipboard_get_utf8 */
#include "spdf_win_sidebar_view.h"

#include <wctype.h>

/* GIVE A FIELD THE KEYBOARD. Returns 1 when the focus moved, which is a repaint
 * (the focus ring) even though nothing else changed.
 *
 * Taking focus SEEDS the page field from the current page, so a reader who
 * clicks it and types Return without touching anything else goes nowhere rather
 * than to page 0 -- and so the number they are about to overwrite is selected in
 * the ordinary sense of "the field shows what it is replacing". */
static int chrome_focus(app* a, int focus) {
    if (a->focus == focus) return 0;
    /* THE TWO DOCUMENT FIELDS CANNOT BE FOCUSED WITH NO DOCUMENT, BY ANY ROUTE.
     * The painter draws them disabled then and the input router refuses a click
     * on them (spdf_win_chrome_empty.h), so leaving the KEYBOARD able to focus
     * them would put an accent focus ring on a control drawn dead -- the same
     * lie in a smaller frame. Ctrl+F and Ctrl+G therefore do nothing on an empty
     * window; macOS keeps focusFind: on -validateMenuItem:'s always-enabled
     * whitelist (:16317-16325) even though it disables the field itself
     * (:10232), and this port takes the field's word for it. A deliberate
     * divergence, and the one that leaves nothing on screen contradicting
     * itself. */
    if (!a->canvas && (focus == SPDF_WIN_FOCUS_FIND || focus == SPDF_WIN_FOCUS_PAGE)) return 0;
    a->focus = focus;
    if (focus == SPDF_WIN_FOCUS_PAGE) {
        int page = a->canvas ? spdf_win_canvas_current_page(a->canvas) + 1 : 1;
        _snwprintf_s(a->page_text, _TRUNCATE, L"%d", page);
        a->page_caret = (int)wcslen(a->page_text);
    }
    return 1;
}

/* Hand the find bridge whatever is in the field now. One place, so the callers
 * that change the query cannot disagree about which argument is stale. A live
 * query also selects the Search section, which macOS does on every startFind
 * (showSearchSidebarForFind); an emptied one lets the section resolve back. */
static void chrome_find_push(app* a) {
    spdf_win_find_set_query(a->find_text[0] ? a->find_text : NULL, a->find_regex);
    if (a->find_text[0]) spdf_win_sidebar_set_section(2);
}

/* Runs of whitespace become one space, the ends are trimmed -- Mac
 * SPDFTextByCollapsingWhitespace, GTK collapse_whitespace -- so a selection that
 * wrapped across a line break searches as one phrase. UTF-16 in and out,
 * capped to the find field's capacity. Returns the length. */
static int chrome_collapse_whitespace(const wchar_t* in, wchar_t* out, int cap) {
    int n = 0, pending = 0;
    if (!in || cap <= 0) return 0;
    for (; *in && n < cap - 1; ++in) {
        if (iswspace(*in)) {
            if (n > 0) pending = 1;
            continue;
        }
        if (pending) {
            out[n++] = L' ';
            pending = 0;
            if (n >= cap - 1) break;
        }
        out[n++] = *in;
    }
    out[n] = L'\0';
    return n;
}

/* THE ONE WAY A SEARCH STARTS FROM OUTSIDE THE FIELD. Replaces the query, puts
 * the caret at its end, gives the field the keyboard, pushes it to the session
 * and arms the reveal. */
static int chrome_find_start(app* a, const wchar_t* text) {
    if (!a->canvas || !text || !text[0]) return 0;
    wcsncpy_s(a->find_text, text, _TRUNCATE);
    a->find_caret = (int)wcslen(a->find_text);
    a->focus = SPDF_WIN_FOCUS_FIND;
    chrome_find_push(a);
    g_find_reveal_pending = 1;
    return 1;
}

/* Type anywhere: the first printable character with the document focused
 * becomes the query. Control characters, and a window with no document, are
 * declined so the keymap can keep them. */
static int chrome_type_to_search(app* a, unsigned unit) {
    wchar_t text[2];
    if (!a->canvas || !spdf_win_text_is_printable(unit)) return 0;
    text[0] = (wchar_t)unit;
    text[1] = L'\0';
    return chrome_find_start(a, text);
}

/* Ctrl+F. */
static int chrome_find_seed_from_selection(app* a) {
    const char* utf8 = a->canvas ? spdf_win_canvas_selection_text(a->canvas) : NULL;
    wchar_t wide[512];
    wchar_t query[256];
    if (utf8 && utf8[0] &&
        MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, (int)(sizeof(wide) / sizeof(wide[0]))) > 0 &&
        chrome_collapse_whitespace(wide, query, (int)(sizeof(query) / sizeof(query[0]))) > 0 &&
        wcscmp(query, a->find_text) != 0)
        return chrome_find_start(a, query);
    return chrome_focus(a, SPDF_WIN_FOCUS_FIND);
}

/* Paste INTO the focused field: the field's own paste, which on macOS the field
 * editor performs before paste: ever reaches the document. Printable units
 * only, digits only for the page field, exactly what typing them would do.
 * Spelled out here rather than through spdf_win_chrome_commands.h's field
 * helpers because that header is included after this one. */
static int chrome_paste_into_field(app* a, const wchar_t* wide) {
    wchar_t* text;
    int cap;
    int* caret;
    int changed = 0;
    const wchar_t* p;
    switch (a->focus) {
        case SPDF_WIN_FOCUS_FIND:
            text = a->find_text;
            cap = (int)(sizeof(a->find_text) / sizeof(a->find_text[0]));
            caret = &a->find_caret;
            break;
        case SPDF_WIN_FOCUS_PAGE:
            text = a->page_text;
            cap = (int)(sizeof(a->page_text) / sizeof(a->page_text[0]));
            caret = &a->page_caret;
            break;
        case SPDF_WIN_FOCUS_SIDEBAR_FILTER:
            text = a->filter_text;
            cap = (int)(sizeof(a->filter_text) / sizeof(a->filter_text[0]));
            caret = &a->filter_caret;
            break;
        default: return 0;
    }
    for (p = wide; *p; ++p) {
        if (!spdf_win_text_is_printable(*p)) continue;
        if (a->focus == SPDF_WIN_FOCUS_PAGE && !spdf_win_text_is_digit(*p)) continue;
        changed |= spdf_win_text_insert(text, cap, caret, *p);
    }
    if (!changed) return 0;
    if (a->focus == SPDF_WIN_FOCUS_FIND) chrome_find_push(a);
    else if (a->focus == SPDF_WIN_FOCUS_SIDEBAR_FILTER) spdf_win_chrome_content_set_filter(a->filter_text);
    return 1;
}

/* Ctrl+V. Into the focused field when there is one; otherwise a search. */
static int chrome_paste_search(app* a) {
    char utf8[4096];
    wchar_t wide[2048];
    wchar_t query[256];
    if (!spdf_win_clipboard_get_utf8(utf8, (int)sizeof(utf8)) || !utf8[0]) return 0;
    if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, (int)(sizeof(wide) / sizeof(wide[0]))) <= 0) return 0;
    if (a->focus != SPDF_WIN_FOCUS_NONE) return chrome_paste_into_field(a, wide);
    if (chrome_collapse_whitespace(wide, query, (int)(sizeof(query) / sizeof(query[0]))) <= 0) return 0;
    return chrome_find_start(a, query);
}

/* Put the reader on the current match: CENTRED, as macOS's scrollToPageRect
 * does, through the canvas's scroll-to-rect. */
static int chrome_find_show_current(app* a) {
    SpdfWinFindSession* s = spdf_win_find_shared();
    int page = -1;
    spdf_rect rect;
    if (!s || !a->canvas) return 0;
    if (!spdf_win_find_current_target(s, &page, &rect) || page < 0) return 0;
    spdf_win_canvas_scroll_to_rect(a->canvas, page, rect);
    return 1;
}

/* Step to the next/previous match and centre it. */
static int chrome_find_step(app* a, int delta) {
    SpdfWinFindSession* s = spdf_win_find_shared();
    if (!s || !a->canvas) return 0;
    if (spdf_win_find_step(s, delta) < 0) return 0;
    chrome_find_show_current(a);
    return 1;
}

/* THE REVEAL, at paint time. Once the search has settled, pick the match to
 * show -- the nearest to the viewport (spdf_win_search_nearest_match over the
 * matches' document-space centres, the visible page range and the viewport's
 * middle, exactly nearestFindMatchIndexToCurrentViewport :10483-10527) when
 * the setting says so, else the first -- make it current and centre it. A
 * search that found nothing simply disarms. Returns 1 when the view moved. */
static int chrome_find_reveal_if_pending(app* a) {
    SpdfWinFindSession* s = spdf_win_find_shared();
    int count, index = 0;
    if (!g_find_reveal_pending || !s || !a->canvas) return 0;
    if (spdf_win_find_searching(s)) return 0; /* not yet: results are still streaming */
    g_find_reveal_pending = 0;
    count = spdf_win_find_match_count(s);
    if (count <= 0) return 0;
    if (spdf_win_settings_shared()->search_jumps_to_nearest_result) {
        int* pages = (int*)malloc(sizeof(int) * (size_t)count);
        double* centers = (double*)malloc(sizeof(double) * (size_t)count);
        if (pages && centers) {
            int first = 0, last = 0, i;
            unsigned vw = 0, vh = 0;
            double zoom = (double)spdf_win_canvas_zoom(a->canvas);
            spdf_win_canvas_visible_range(a->canvas, &first, &last);
            spdf_win_canvas_viewport(a->canvas, &vw, &vh);
            for (i = 0; i < count; ++i) {
                SpdfWinFindMatchInfo m;
                double sx = 0.0, sy = 0.0, sw = 0.0, sh = 0.0;
                spdf_win_find_match_at(s, i, &m);
                spdf_win_canvas_page_rect(a->canvas, m.page, &sx, &sy, &sw, &sh);
                pages[i] = m.page;
                /* The same page-to-view mapping as scroll_to_rect. */
                centers[i] = sy + ((double)m.rect.y0 + (double)m.rect.y1) * 0.5 * zoom;
            }
            index = spdf_win_search_nearest_match(pages, centers, count, first, last,
                                                  (double)spdf_win_canvas_scroll_y(a->canvas) + (double)vh * 0.5);
            if (index < 0) index = 0;
        }
        free(pages);
        free(centers);
    }
    spdf_win_find_set_current(s, index);
    return chrome_find_show_current(a);
}

/* A click on a row of the sidebar's list.
 *
 * In the Chapters section `row` is the row: its page comes from the content
 * provider, which the router deliberately cannot reach -- resolving it on a
 * mouse MOVE would put an outline load on the pointer's path; on a CLICK it is
 * already warm, because the paint that drew the row resolved it.
 *
 * In the Search section the rows have three different heights and the router
 * has no view, so `row` is the LIST-LOCAL Y in device pixels (scroll included)
 * and the published view resolves it here -- with the same function the painter
 * laid the rows out with. A header row does nothing (GTK: headers are not
 * activatable); a match row makes its match current and centres it. */
static int chrome_sidebar_row(app* a, int row) {
    if (spdf_win_sidebar_section() == 2) {
        const SpdfWinSidebarResultsView* v = spdf_win_sidebar_results_current();
        SpdfWinFindSession* s = spdf_win_find_shared();
        int r = spdf_win_sidebar_results_row_at(v, (float)row, g_chrome_dpi);
        if (!v || !s || r < 0 || v->rows[r].kind != SPDF_WIN_SIDEBAR_RESULT_MATCH) return 0;
        spdf_win_find_set_current(s, v->rows[r].match_index);
        chrome_find_show_current(a);
        return 1;
    }
    if (spdf_win_sidebar_section() == 1) {
        /* Comments: the same list-local y, resolved against the published
         * rows; a header does nothing, a comment row centres its annotation
         * -- or lands on its page when the core gave it no area (GTK
         * comments_row_activated). */
        const spdf_comment_item* item =
            spdf_win_annot_item(spdf_win_annot_sidebar_comment_at((float)row, g_chrome_dpi));
        if (!a->canvas || !item) return 0;
        if (spdf_win_annot_bounds_have_area(&item->bounds))
            return spdf_win_canvas_scroll_to_rect(a->canvas, item->page_index, item->bounds);
        return spdf_win_canvas_scroll_to_page(a->canvas, item->page_index);
    }
    {
        const SpdfWinChromePanelsContent* content = spdf_win_chrome_content_current();
        const SpdfWinSidebarContent* sb = content ? content->sidebar : NULL;
        if (!a->canvas || !sb || !sb->rows || row < 0 || row >= sb->row_count) return 0;
        /* A row whose destination did not resolve (page_index < 0: a /Fit-less
         * dest, a missing target, an external URL) is drawn greyed and does
         * nothing, which is what macOS's own `page >= 0` branch does. */
        if (sb->rows[row].page_index < 0) return 0;
        return spdf_win_canvas_scroll_to_page(a->canvas, sb->rows[row].page_index);
    }
}

/* A click on the Chapters / Comments / Search control. The segment IS the
 * section number; the resolution against what the document has happens at
 * paint time, so a click on a section with nothing to list shows the honest
 * empty state for one frame and falls back. */
static int chrome_sidebar_section(app* a, int segment) {
    (void)a;
    if (segment < 0 || segment > 2) return 0;
    spdf_win_sidebar_set_section(segment);
    return 1;
}

/* A toolbar button whose handler belongs to another track (OCR, translate):
 * post the menu command the same way the app popup does, so the command
 * arrives through command_perform() like every other route in. Nothing on
 * screen changes here. */
static int chrome_post_command(app* a, int command) {
    if (!a->window) return 0;
    PostMessageW((HWND)spdf_win_window_native_handle(a->window), WM_COMMAND,
                 (WPARAM)(SPDF_WIN_MENU_ID_BASE + command), 0);
    return 0;
}

/* A wheel, routed by WHERE THE POINTER IS against what the last paint drew:
 * over the strip it scrolls the strip (spdf_win_search_map_ui.h); over the
 * Search section's list it scrolls that list; anywhere else it is the
 * document's, exactly as before. */
static int chrome_wheel(app* a, const spdf_win_input* in) {
    SpdfWinMapFrame f;
    if (spdf_win_map_frame_current(&f) && spdf_win_chrome_contains(f.panel, in->x, in->y)) return minimap_wheel(a, in);
    if (spdf_win_sidebar_section() == 2 && g_results_builder && spdf_win_chrome_contains(g_results_list, in->x, in->y))
        return spdf_win_sidebar_results_scroll_by(g_results_builder, in->dy, g_results_list.h, g_chrome_dpi);
    if (spdf_win_sidebar_section() == 1 && spdf_win_chrome_contains(g_comments_list, in->x, in->y))
        return spdf_win_annot_sidebar_scroll_by(in->dy, g_comments_list.h, g_chrome_dpi);
    return spdf_win_canvas_scroll_by(a->canvas, in->dx, in->dy);
}
