/* Building the chrome model from the tab model. See spdf_win_chrome_model.h. */
#include "spdf_win_chrome_model.h"

#include "spdf_win_chrome_find.h"
#include "spdf_win_tabs_names.h"

#include <string.h>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

namespace {

/* The tab model stores UTF-8; the strip draws UTF-16. MultiByteToWideChar with
 * CP_UTF8 rather than a narrow conversion, for the reason the whole port calls
 * *W APIs: this machine's ANSI code page is 1252, so a narrow round trip loses
 * every character outside it -- and a tab title is exactly where a CJK or
 * accented filename shows up. Gotcha 20.
 *
 * On failure the title is left empty rather than filled with replacement
 * characters: a blank tab reads as "no title", where mojibake reads as
 * corruption of the document. */
void widen_title(const char* utf8, wchar_t* out, int out_len) {
    out[0] = L'\0';
    if (!utf8 || !utf8[0] || out_len < 2) return;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, out, out_len) == 0) out[0] = L'\0';
}

/* macOS shows a tab's DISPLAY NAME, not its path: the leaf, with a known
 * extension stripped (spdf_display_label_without_extension,
 * SPDFMacSupport.mm:18-31). The tab model's title is already a leaf, so only the
 * extension needs handling.
 *
 * Only the formats this app opens are stripped. Trimming after the last dot
 * unconditionally would turn "Rev 2.1 schematic" into "Rev 2", which is worse
 * than showing an extension. */
void strip_known_extension(wchar_t* title) {
    static const wchar_t* known[] = {L".pdf",  L".xps", L".epub", L".mobi", L".fb2", L".cbz",
                                     L".cbr",  L".cb7", L".cbt",  L".md",   L".markdown"};
    size_t len = wcslen(title);
    size_t i;
    for (i = 0; i < sizeof(known) / sizeof(known[0]); ++i) {
        size_t k = wcslen(known[i]);
        if (len > k && _wcsicmp(title + (len - k), known[i]) == 0) {
            title[len - k] = L'\0';
            return;
        }
    }
}

} /* namespace */

namespace {
int g_caption_maximized;
int g_caption_hot;
int g_caption_pressed;
int g_presentation;
} /* namespace */

void spdf_win_chrome_presentation_set(int on) { g_presentation = on ? 1 : 0; }
int spdf_win_chrome_presentation(void) { return g_presentation; }

void spdf_win_chrome_caption_set_state(int maximized, int hot, int pressed) {
    g_caption_maximized = maximized ? 1 : 0;
    /* Out-of-range values are NONE rather than garbage the painter has to
     * defend against: the enum is spdf_win_tabstrip.h's and 1..3 are the buttons. */
    g_caption_hot = (hot >= SPDF_WIN_CAPTION_MINIMIZE && hot <= SPDF_WIN_CAPTION_CLOSE) ? hot : SPDF_WIN_CAPTION_NONE;
    g_caption_pressed =
        (pressed >= SPDF_WIN_CAPTION_MINIMIZE && pressed <= SPDF_WIN_CAPTION_CLOSE) ? pressed : SPDF_WIN_CAPTION_NONE;
}

void spdf_win_chrome_caption_state(int* maximized, int* hot, int* pressed) {
    if (maximized) *maximized = g_caption_maximized;
    if (hot) *hot = g_caption_hot;
    if (pressed) *pressed = g_caption_pressed;
}

void spdf_win_chrome_model_inputs_init(SpdfWinChromeModelInputs* in) {
    if (!in) return;
    memset(in, 0, sizeof(*in));
    spdf_win_chrome_caption_state(&in->maximized, &in->caption_hot, &in->caption_pressed);
    /* Both side panels open, as macOS does for a new document
     * (ShenzhenPDFMac.mm:836-840); 0 width asks spdf_win_chrome.h for its own
     * default rather than repeating 240 and 126.5 here. */
    in->show_sidebar = 1;
    in->show_minimap = 1;
    in->hot_tab = -1;
    in->hot_close = -1;
    in->drag_tab = -1;
    in->drop_slot = -1;
    in->page_index = -1;
    in->zoom_dpi_scale = 1.0f;
    in->fit_mode = SPDF_WIN_CHROME_FIT_WIDTH; /* what the canvas opens at */
    in->presentation = g_presentation;
}

void spdf_win_chrome_model_build(SpdfWinChromeModel* model, SpdfWinChromeTabStore* store, spdf_win_tabs* tabs,
                                 const SpdfWinChromeModelInputs* in) {
    SpdfWinChromeModelInputs defaults;
    int count, i;

    if (!model || !store) return;
    memset(model, 0, sizeof(*model));
    memset(store, 0, sizeof(*store));
    if (!in) {
        spdf_win_chrome_model_inputs_init(&defaults);
        in = &defaults;
    }

    model->dark = in->dark;
    /* Presenting hides both panels whatever the reader had open; their
     * preference comes back when presentation ends (:13432, :13455). */
    model->presentation = in->presentation;
    model->show_sidebar = in->presentation ? 0 : in->show_sidebar;
    model->show_minimap = in->presentation ? 0 : in->show_minimap;
    model->sidebar_w = in->sidebar_w;
    model->minimap_w = in->minimap_w;
    model->sidebar_section = 0; /* Chapters, as macOS opens */
    model->search_active = 0;
    model->markdown = in->markdown;
    model->hot_tab = in->hot_tab;
    model->hot_close = in->hot_close;
    model->drag_tab = in->drag_tab;
    model->drop_slot = in->drop_slot;
    model->selected_tab = -1;
    model->page_index = in->page_index;
    model->page_count = in->page_count;
    model->page_text = in->page_text;
    model->focus = in->focus;
    model->sidebar_row_count = in->sidebar_row_count;
    model->sidebar_scroll_y = in->sidebar_scroll_y;
    model->zoom = in->zoom;
    model->zoom_dpi_scale = in->zoom_dpi_scale;
    model->fit_mode = in->fit_mode;
    model->maximized = in->maximized;
    model->caption_hot = in->caption_hot;
    model->caption_pressed = in->caption_pressed;

    if (!tabs) {
        /* Still fill the find state: a model with no tabs is what the window
         * builds while the last tab closes, and leaving the counter showing a
         * previous document's total there would be a lie about a document that
         * is gone. With no path the session cancels and reports nothing. */
        spdf_win_find_fill_model(model, NULL);
        return;
    }

    count = spdf_win_tabs_count(tabs);
    if (count > SPDF_WIN_CHROME_MAX_TABS) count = SPDF_WIN_CHROME_MAX_TABS;

    /* THE DISPLAY NAMES, disambiguated together: two tabs called "spec" become
     * "Alpha/spec" and "Beta/spec" (spdf_win_tabs_names.h, the mac's
     * spdf_disambiguated_display_names_for_paths). From the PATHS, as the mac
     * does; the tab model's title is the fallback for a tab with no path
     * components to speak of. */
    {
        const char* paths[SPDF_WIN_CHROME_MAX_TABS];
        static char names[SPDF_WIN_CHROME_MAX_TABS][SPDF_WIN_TABS_NAME_MAX];
        for (i = 0; i < count; ++i) paths[i] = spdf_win_tabs_path(tabs, i);
        spdf_win_tabs_display_names(paths, count, names);
        for (i = 0; i < count; ++i) {
            if (names[i][0]) {
                widen_title(names[i], store->titles[i], SPDF_WIN_CHROME_MAX_TITLE);
            } else {
                widen_title(spdf_win_tabs_title(tabs, i), store->titles[i], SPDF_WIN_CHROME_MAX_TITLE);
                strip_known_extension(store->titles[i]);
            }
        }
    }

    for (i = 0; i < count; ++i) {
        const spdf_win_tab_view* view = spdf_win_tabs_view_const(tabs, i);
        store->tabs[i].title = store->titles[i];
        /* Both flags come from the TAB MODEL, where the open hook set them: the
         * watcher probed the source's write permission at open (the orange dot,
         * SPDFMacTabStripView.mm:585) and reports a file gone for its grace
         * period (the red tab). Nothing here touches the filesystem -- a stat
         * on the paint path is what the repo's speed rule forbids -- and a tab
         * never shown carries neither, which is the truthful answer. */
        store->tabs[i].read_only = view ? view->read_only : 0;
        store->tabs[i].missing = view ? view->missing : 0;
    }
    store->count = count;

    model->tabs = store->tabs;
    model->tab_count = count;
    model->selected_tab = spdf_win_tabs_selected_index(tabs);
    if (model->selected_tab >= count) model->selected_tab = count > 0 ? count - 1 : -1;

    /* The find fields, from the shared session (spdf_win_chrome_find.h). Keyed
     * on the SELECTED tab's path, so a Ctrl+Tab re-targets the search at the
     * document the reader is now looking at rather than at the one the window
     * opened on -- the same defect spdf_win_chrome_content_set_document() exists
     * to prevent for the sidebar. Cheap on the steady path: a strcmp and a poll
     * that finds nothing, and with no query it does not even allocate a session.
     *
     * Here rather than in SpdfWinChromeModelInputs on purpose. Threading eight
     * more fields through the inputs struct would mean the window layer -- which
     * has no search state -- filling eight fields it would have to fetch from
     * this same session anyway, and the headless compose path would have to
     * repeat it. */
    spdf_win_find_fill_model(model, model->selected_tab >= 0 ? spdf_win_tabs_path(tabs, model->selected_tab) : NULL);
}

/* --- the find bridge -----------------------------------------------------
 *
 * The process-wide find session, the query the reader has typed, and the fill
 * that puts the result into the model. Here rather than in spdf_win_chrome_find.cpp
 * for a linking reason worth stating: that file is the toolbar's find PAINTER,
 * and everything it needs is inline in spdf_win_chrome_find.h. Keeping the
 * bridge out of it means a test that links the toolbar painter does not also
 * have to link the search engine, its worker thread and MuPDF behind it.
 * portable/win/tests/d2d_theme_test.c and overlay_paint_test.c are exactly that
 * test, and the difference to them is one source file instead of two.
 *
 * Here rather than in spdf_win_search.cpp for the other reason: that file is at
 * its size cap, and this half is a different thing anyway -- it reaches the
 * session only through the same public API a test does, so the engine's struct
 * stays private to its own translation unit.
 */

namespace {

SpdfWinFindSession* g_shared;

/* THE QUERY THE READER TYPED. Both halves are kept: the UTF-16 the toolbar
 * draws (and SpdfWinChromeModel::query borrows, which is why this is static
 * storage and not a stack buffer) and the UTF-8 the engine and the core want.
 *
 * This is what replaced SPDF_FIND_QUERY and SPDF_FIND_REGEX. Those were two
 * getenv calls documented as temporary at their definitions; the search field is
 * typeable now (spdf_win_chrome_text.h, routed by SPDF_WIN_CA_FOCUS_FIND) and
 * the regex flag has the toolbar checkbox and an Edit-menu item, so neither
 * environment variable has any remaining reason to exist. Do not bring them
 * back: a debugging hook that bypasses the real control is a hook that keeps
 * working after the real control has broken. */
wchar_t g_query_w[512];
char g_query_u8[1024];
int g_query_regex;

const char* current_query(void) { return g_query_u8[0] ? g_query_u8 : NULL; }

} /* namespace */

void spdf_win_find_set_query(const wchar_t* query, int regex) {
    g_query_regex = regex ? 1 : 0;
    if (!query || !query[0]) {
        g_query_w[0] = L'\0';
        g_query_u8[0] = '\0';
        return;
    }
    wcsncpy_s(g_query_w, query, sizeof(g_query_w) / sizeof(g_query_w[0]) - 1);
    /* No MB_ERR_INVALID_CHARS: an unpaired surrogate cannot reach here (the
     * field removes a pair as a unit, spdf_win_chrome_text.h), and a query that
     * silently became empty would look like a search that found nothing. On
     * overflow the UTF-8 is left empty rather than truncated mid-sequence --
     * spdf_win_search_dup_query caps the query anyway, and a half-character is a
     * worse thing to hand a regex compiler than nothing. */
    if (WideCharToMultiByte(CP_UTF8, 0, g_query_w, -1, g_query_u8, (int)sizeof(g_query_u8), NULL, NULL) <= 0)
        g_query_u8[0] = '\0';
}

const char* spdf_win_find_query_utf8(void) { return g_query_u8; }

SpdfWinFindSession* spdf_win_find_shared(void) {
    /* Lazy for real, and still lazy after the environment bridge went away: no
     * query means no session, no thread and no document handle, so a process
     * that never searches pays one branch. The session outlives a query being
     * cleared, because a reader who deletes the query and types another must not
     * pay for a second worker thread. */
    if (!g_shared && current_query()) g_shared = spdf_win_find_session_new();
    return g_shared;
}

/* The scene builder's entry point, over the process-wide session. Here, beside
 * spdf_win_find_shared(), and NOT beside _apply_overlays_for() in
 * spdf_win_search_geometry.h: putting it there would make every consumer of the
 * engine also need this file's shared session, which is exactly the dependency
 * this split exists to avoid -- portable/win/tests/find_overlay_test.c links the
 * engine and nothing else. */
void spdf_win_find_apply_overlays(struct spdf_win_scene* scene) {
    spdf_win_find_apply_overlays_for(spdf_win_find_shared(), scene);
}

void spdf_win_find_fill_model(SpdfWinChromeModel* model, const char* utf8_path) {
    SpdfWinFindSession* s;
    const char* query;

    if (!model) return;
    model->query = NULL;
    model->regex = 0;
    model->searching = 0;
    model->match_count = 0;
    model->match_index = -1;
    model->marks = NULL;
    model->mark_count = 0;
    model->active_mark = -1;

    s = spdf_win_find_shared();
    /* No session means nothing has ever been typed, so the cleared fields above
     * are the whole answer -- but the REGEX flag is the reader's setting whether
     * or not a search is running, and the toolbar checkbox and the Edit menu
     * both read it back from here. */
    model->regex = g_query_regex;
    if (!s) return;
    query = current_query();
    spdf_win_find_set(s, utf8_path, query, g_query_regex);
    spdf_win_find_poll(s);

    /* Borrowed, and valid for exactly as long as the model is: the buffer is
     * static and only spdf_win_find_set_query() writes it, which happens on the
     * UI thread between frames. */
    model->query = query ? g_query_w : NULL;
    model->searching = spdf_win_find_searching(s);
    model->match_count = spdf_win_find_match_count(s);
    model->match_index = spdf_win_find_match_index(s);
    model->marks = spdf_win_find_marks(s, &model->mark_count, &model->active_mark);
    /* macOS grows the sidebar's minimum and shows its Search section only while
     * a query is live (ShenzhenPDFMac.mm:3138-3144, :9603-9615). */
    model->search_active = model->query != NULL;

    spdf_win_find_note_paint_thread(s);
}
