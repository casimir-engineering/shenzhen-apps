/* The content the sidebar and minimap show, and the temporary bridge that finds
 * it. See spdf_win_chrome_content.h for the three rules that shape this file. */
#include "spdf_win_chrome_content.h"
#include "spdf_win_open.h" /* the process opener: spdf_open, or Markdown-aware once main() says so */

#include "spdf_win_chrome_thumbs.h"
#include "spdf_win_launch_profile.h" /* SPDF-LAUNCH markers; free when unset */
#include "shenzhen_pdf_core.h"

#include <shellapi.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "shell32.lib")

/* --- the temporary bridge ----------------------------------------------- */
/*
 * WHAT THIS IS AND WHAT REPLACES IT. The painters are reached only through
 * spdf_win_paint(), whose scene carries a SpdfWinChromeModel and nothing else --
 * no document, no path, no canvas. So until the model (or the scene) carries the
 * outline and the thumbnail store, this file finds the document the only way it
 * can from inside a paint: on the process command line, which is where
 * spdf_win_main.cpp got it too.
 *
 * It is honest about its limits and they are all listed in this change's report:
 * it opens a SECOND document handle (the render workers already do exactly that,
 * because the core allows one spdf_document per thread) and it cannot know the
 * canvas's live scroll offset. Both are a field on a struct owned by another
 * track, not a design.
 *
 * THE FILTER TEXT IS NO LONGER ONE OF THOSE LIMITS. It used to come from
 * SPDF_SIDEBAR_FILTER -- one getenv, documented as temporary at its definition,
 * because no keyboard input reached this track. The field is typeable now
 * (spdf_win_chrome_text.h, routed by SPDF_WIN_CA_FOCUS_SIDEBAR_FILTER) and the
 * environment variable is gone; spdf_win_chrome_content_set_filter() is the only
 * way in. Do not bring it back: a debugging hook that bypasses the real control
 * is a hook that keeps working after the real control has broken.
 */

namespace {

struct Bridge {
    int tried;
    char* path;       /* UTF-8, owned */
    int launch_page;  /* from --page N or the --render-window-png positional */
    spdf_document* doc;

    /* Sidebar. */
    int outline_tried;
    spdf_outline outline;
    /* The outline as the three parallel arrays the builder takes, filled once
     * per document: the rows are rebuilt on every keystroke and every fold, and
     * neither should re-walk the outline items. */
    const char** titles;
    int* pages;
    int* levels;
    unsigned char* visible; /* the builder's scratch: one flag per outline entry */
    SpdfWinSidebarRow* rows;
    int row_cap;      /* how many `rows` can hold, and `arena`'s size in units of 320 */
    wchar_t* arena;
    wchar_t filter[128];
    /* The chapters this document left collapsed, by positional key
     * (spdf_win_sidebar_outline.h), loaded with the outline and written through
     * on every change. Empty is the default and means expanded. */
    char** collapsed;
    int collapsed_count;
    /* The filter changed and the row list has not caught up. Set by the setter
     * and cleared by the rebuild, rather than the rebuild comparing strings:
     * the reader types one character at a time and every keystroke IS a change,
     * so the flag is the honest representation and the compare would be dead
     * code that looked like a guard. */
    int filter_dirty;
    SpdfWinSidebarContent sidebar;

    /* Minimap. */
    SpdfWinThumbStore* thumbs;
    SpdfWinPageSizePt* sizes;
    int size_count;
    SpdfWinMinimapContent minimap;

    SpdfWinChromePanelsContent content;
};

Bridge g_bridge;
const SpdfWinChromePanelsContent* g_attached;
/* The per-document memory, if a store registered (spdf_win_chrome_content.h
 * says who does and what a binary without one gets). */
const SpdfWinChapterStore* g_store;

/* Keys come from the store's load or from _strdup here; both are malloc'd. */
void free_keys(char** keys, int count) {
    int i;
    if (!keys) return;
    for (i = 0; i < count; ++i) free(keys[i]);
    free(keys);
}

char* utf8_dup_from_wide(const wchar_t* w) {
    int need;
    char* out;
    if (!w) return NULL;
    need = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (need <= 0) return NULL;
    out = (char*)malloc((size_t)need);
    if (!out) return NULL;
    if (WideCharToMultiByte(CP_UTF8, 0, w, -1, out, need, NULL, NULL) <= 0) {
        free(out);
        return NULL;
    }
    return out;
}

int file_exists(const wchar_t* path) {
    DWORD attr = GetFileAttributesW(path);
    return attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY);
}

/* The first argument that names an existing file wins, and a `--page N` or a
 * numeric token straight after it sets the launch page. Both of the app's
 * argument forms fall out of that: `[--dark] [--page N] <file.pdf>` and
 * `--render-window-png <file.pdf> <page> <w> <h> <out.png>` -- in the second,
 * out.png does not exist yet, so the document is still the first match. */
void find_document(Bridge* b) {
    int argc = 0;
    wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    int i;

    if (!argv) return;
    for (i = 1; i < argc; ++i) {
        if (wcscmp(argv[i], L"--page") == 0 && i + 1 < argc) {
            b->launch_page = _wtoi(argv[i + 1]);
            ++i;
            continue;
        }
        if (argv[i][0] == L'-') continue;
        if (!file_exists(argv[i])) continue;
        b->path = utf8_dup_from_wide(argv[i]);
        if (i + 1 < argc && argv[i + 1][0] >= L'0' && argv[i + 1][0] <= L'9') b->launch_page = _wtoi(argv[i + 1]);
        break;
    }
    LocalFree(argv);
}

void ensure_path(Bridge* b) {
    if (b->tried) return;
    b->tried = 1;
    find_document(b);
}

/* Rebuild the row list from the loaded outline THROUGH THE CURRENT FILTER.
 *
 * Separate from ensure_outline() below because the two have different triggers:
 * the outline is loaded once per document, and the rows are rebuilt on every
 * keystroke in the filter field. Reloading the outline per keystroke would mean
 * reopening the document per keystroke, which is exactly the kind of cost this
 * file's rule 1 exists to keep off the paint path.
 *
 * `rows` and `arena` are sized for the UNFILTERED outline and reused: filtering
 * can only ever produce fewer rows, so a filter can never need a bigger buffer
 * than the one the first build allocated. */
void rebuild_rows(Bridge* b) {
    size_t arena_wchars;
    int i;
    int nesting;

    b->sidebar.rows = NULL;
    b->sidebar.row_count = 0;
    b->sidebar.collapsible_count = 0;
    b->sidebar.open_count = 0;
    b->sidebar.filter = b->filter[0] ? b->filter : NULL;
    if (b->outline.count <= 0) return;

    if (!b->rows || !b->arena || !b->titles) {
        free(b->rows);
        free(b->arena);
        free((void*)b->titles);
        free(b->pages);
        free(b->levels);
        free(b->visible);
        b->row_cap = b->outline.count;
        b->rows = (SpdfWinSidebarRow*)calloc((size_t)b->row_cap, sizeof(SpdfWinSidebarRow));
        b->arena = (wchar_t*)calloc((size_t)b->row_cap * 320u, sizeof(wchar_t));
        b->titles = (const char**)calloc((size_t)b->row_cap, sizeof(char*));
        b->pages = (int*)calloc((size_t)b->row_cap, sizeof(int));
        b->levels = (int*)calloc((size_t)b->row_cap, sizeof(int));
        b->visible = (unsigned char*)calloc((size_t)b->row_cap, 1);
        if (!b->rows || !b->arena || !b->titles || !b->pages || !b->levels || !b->visible) return;
        for (i = 0; i < b->outline.count; ++i) {
            b->titles[i] = b->outline.items[i].title;
            b->pages[i] = b->outline.items[i].page_index;
            b->levels[i] = b->outline.items[i].level;
        }
    }
    arena_wchars = (size_t)b->row_cap * 320u;

    b->sidebar.rows = b->rows;
    b->sidebar.row_count = spdf_win_sidebar_build_rows_ex(b->titles, b->pages, b->levels, b->outline.count,
                                                          b->sidebar.filter, (const char* const*)b->collapsed,
                                                          b->collapsed_count, b->visible, b->rows, b->row_cap,
                                                          b->arena, arena_wchars);
    /* The toggle button's facts. A live filter turns nesting off, and with it
     * the button (the mac hides it: chapterLevelsForCurrentSidebar is nil). */
    nesting = b->sidebar.filter == NULL;
    b->sidebar.collapsible_count =
        nesting ? spdf_win_sidebar_outline_collapsible_count(b->levels, b->outline.count) : 0;
    b->sidebar.open_count = nesting ? spdf_win_sidebar_outline_open_count(b->levels, b->outline.count,
                                                                           (const char* const*)b->collapsed,
                                                                           b->collapsed_count)
                                    : 0;

    /* macOS selects the first row whose page is the current page
     * (:10613-10620). The live page is not reachable from here, so the launch
     * page stands in -- see the report's model-field request. */
    b->sidebar.selected_row = -1;
    b->sidebar.hot_row = -1;
    for (i = 0; i < b->sidebar.row_count; ++i) {
        if (b->rows[i].page_index != b->launch_page) continue;
        b->sidebar.selected_row = i;
        break;
    }
}

void ensure_outline(Bridge* b) {
    char err[256] = {0};

    if (!b->outline_tried) {
        b->outline_tried = 1;
        b->sidebar.loaded = 1; /* whatever happens below, the answer is now known */
        b->filter_dirty = 1;   /* a new document needs its rows built at least once */
        ensure_path(b);
        if (!b->path) return;
        spdf_win_launch_mark("outline-open-begin");
        b->doc = spdf_win_open_document(b->path, err, sizeof(err));
        spdf_win_launch_mark("outline-doc-opened");
        if (!b->doc) return;
        if (!spdf_load_outline(b->doc, &b->outline, err, sizeof(err))) return;
        spdf_win_launch_mark_n("outline-loaded", b->outline.count);
        b->sidebar.total_count = b->outline.count;
        /* What this file's reader left collapsed, from the per-document store.
         * Read here, beside the outline it applies to, so a document with no
         * outline pays nothing and one with an outline pays it once. */
        if (b->outline.count > 0 && g_store && g_store->load)
            g_store->load(b->path, &b->collapsed, &b->collapsed_count);
    }
    if (!b->filter_dirty) return;
    b->filter_dirty = 0;
    rebuild_rows(b);
}

} /* namespace */

/* --- the folding seam (spdf_win_chrome_content_fold.cpp does the folding) --- */

void spdf_win_chrome_content_set_chapter_store(const SpdfWinChapterStore* store) {
    g_store = store;
}

int spdf_win_chrome_content_fold_view(SpdfWinContentFoldView* out) {
    Bridge* b = &g_bridge;
    if (!out) return 0;
    memset(out, 0, sizeof(*out));
    if (g_attached) return 0;
    ensure_outline(b);
    if (!b->rows || !b->levels || b->outline.count <= 0) return 0;
    out->sidebar = &b->sidebar;
    out->levels = b->levels;
    out->outline_count = b->outline.count;
    out->collapsed = (const char* const*)b->collapsed;
    out->collapsed_count = b->collapsed_count;
    return 1;
}

void spdf_win_chrome_content_fold_apply(char** keys, int count) {
    Bridge* b = &g_bridge;
    if (g_attached) {
        free_keys(keys, count);
        return;
    }
    free_keys(b->collapsed, b->collapsed_count);
    b->collapsed = keys;
    b->collapsed_count = count;
    if (b->path && g_store && g_store->save) g_store->save(b->path, (const char* const*)keys, count);
    b->filter_dirty = 1; /* the row set changes under the list: re-derive it */
}

namespace {

/* `ctx` is the bridge for BOTH hooks: one owner, so a painter never has to know
 * which half of the store it is talking to. */
int bridge_thumb(void* ctx, int page, SpdfWinMinimapThumb* out) {
    return spdf_win_thumbs_lookup(((Bridge*)ctx)->thumbs, page, out);
}

void bridge_request(void* ctx, int first, int last, double panel_w, double side_inset, int dark) {
    Bridge* b = (Bridge*)ctx;
    spdf_win_thumbs_request(b->thumbs, b->sizes, b->size_count, first, last, panel_w, side_inset, dark);
}

void ensure_minimap(Bridge* b) {
    int count;

    ensure_path(b);
    if (!b->path) return;
    if (!b->thumbs) {
        b->thumbs = spdf_win_thumbs_new(b->path);
        if (!b->thumbs) return;
    }
    spdf_win_thumbs_note_paint_thread(b->thumbs);
    spdf_win_thumbs_drain(b->thumbs);
    count = spdf_win_thumbs_page_count(b->thumbs);
    SPDF_WIN_LAUNCH_MARK_ONCE("thumbs-counted");
    if (count <= 0) return;
    if (count != b->size_count) {
        free(b->sizes);
        b->sizes = (SpdfWinPageSizePt*)calloc((size_t)count, sizeof(SpdfWinPageSizePt));
        b->size_count = b->sizes ? count : 0;
    }
    if (!b->sizes) return;
    spdf_win_thumbs_page_sizes(b->thumbs, b->sizes, b->size_count);

    b->minimap.sizes = b->sizes;
    b->minimap.page_count = b->size_count;
    b->minimap.current_page = b->launch_page < b->size_count ? b->launch_page : 0;
    /* No live scroll offset reaches this track. The launch page's position in
     * the document is the honest approximation, and the viewport band is sized
     * as one page of the document -- both replaced the moment the model carries
     * the canvas's scroll state. */
    b->minimap.scroll_fraction =
        b->size_count > 1 ? (double)b->minimap.current_page / (double)(b->size_count - 1) : 0.0;
    b->minimap.doc_h = (double)b->size_count;
    b->minimap.doc_visible_h = 1.0;
    b->minimap.thumb = bridge_thumb;
    b->minimap.ctx = b;
    b->minimap.request = bridge_request;
}

} /* namespace */

void spdf_win_chrome_content_attach(const SpdfWinChromePanelsContent* content) {
    g_attached = content;
}

void spdf_win_chrome_content_set_document(const char* utf8_path, int current_page) {
    Bridge* b = &g_bridge;

    /* A real provider outranks the bridge entirely. */
    if (g_attached) return;

    if (!utf8_path || !utf8_path[0]) {
        /* The last tab closed. Drop everything rather than keep drawing a
         * document that is no longer open. */
        if (b->path) spdf_win_chrome_content_shutdown();
        return;
    }

    if (b->path && strcmp(b->path, utf8_path) == 0) {
        /* Same document: only the position moved. This is the cheap path and it
         * runs every frame, so it must stay a string compare and two stores. */
        b->launch_page = current_page;
        if (b->minimap.page_count > 0)
            b->minimap.current_page = current_page < b->size_count ? current_page : 0;
        return;
    }

    /* A different document -- a tab switch, or the first paint. shutdown()
     * already releases the handle, the outline, the rows, the arena, the sizes
     * and the thumbnail store, and clears `tried`/`outline_tried`, so the next
     * frame rebuilds everything against the new path. Reusing it here rather
     * than open-coding a second teardown is what stops the two from drifting.
     *
     * Setting `tried` past find_document() is the point: the bridge no longer
     * guesses from the process command line once the app has told it which
     * document is selected. That guess is why the panels used to keep showing
     * the launch document after Ctrl+Tab. */
    spdf_win_chrome_content_shutdown();
    b->path = _strdup(utf8_path);
    b->tried = 1;
    b->launch_page = current_page;
}

void spdf_win_chrome_content_set_filter(const wchar_t* filter) {
    Bridge* b = &g_bridge;
    if (g_attached) return;
    if (!filter) filter = L"";
    if (wcscmp(b->filter, filter) == 0) return;
    wcsncpy_s(b->filter, filter, sizeof(b->filter) / sizeof(b->filter[0]) - 1);
    b->filter_dirty = 1;
}

const SpdfWinChromePanelsContent* spdf_win_chrome_content_current(void) {
    Bridge* b = &g_bridge;
    if (g_attached) return g_attached;
    ensure_outline(b);
    ensure_minimap(b);
    b->content.sidebar = &b->sidebar;
    b->content.minimap = b->minimap.page_count > 0 ? &b->minimap : NULL;
    return &b->content;
}

void spdf_win_chrome_content_shutdown(void) {
    Bridge* b = &g_bridge;
    spdf_win_thumbs_free(b->thumbs);
    b->thumbs = NULL;
    free(b->sizes);
    b->sizes = NULL;
    b->size_count = 0;
    if (b->outline.items) spdf_free_outline(&b->outline);
    free(b->rows);
    b->rows = NULL;
    b->row_cap = 0;
    free(b->arena);
    b->arena = NULL;
    free((void*)b->titles);
    b->titles = NULL;
    free(b->pages);
    b->pages = NULL;
    free(b->levels);
    b->levels = NULL;
    free(b->visible);
    b->visible = NULL;
    free_keys(b->collapsed, b->collapsed_count);
    b->collapsed = NULL;
    b->collapsed_count = 0;
    if (b->doc) spdf_close(b->doc);
    b->doc = NULL;
    free(b->path);
    b->path = NULL;
    memset(&b->sidebar, 0, sizeof(b->sidebar));
    memset(&b->minimap, 0, sizeof(b->minimap));
    b->tried = 0;
    b->outline_tried = 0;
}
