/* spdf_win_sidebar_rows.h — what the sidebar's Chapters list SHOWS and where:
 * the row and content structs, the panel's bands, each row's disclosure
 * triangle and title rects, the filter, and the outline -> rows builder that
 * applies the filter and the per-document collapse state.
 *
 * Split out of spdf_win_chrome_content.h when that file passed the repo's
 * 500-line cap (tools/file-size-limits.md asks for a file, not a raised cap):
 * this is the sidebar's geometry and builder, that one is the content SEAM --
 * the provider the painters resolve once per frame, and the folding calls the
 * app makes on a press. Everything here is header-only and C-compatible so
 * portable/win/tests/sidebar_rows_test.c drives it with hand-built outlines and
 * no render target, no document and no MuPDF.
 *
 * spdf_win_chrome_content.h includes this, so every file that read the row
 * geometry from there still does.
 */
#ifndef SPDF_WIN_SIDEBAR_ROWS_H
#define SPDF_WIN_SIDEBAR_ROWS_H

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <wchar.h>

#include "spdf_win_chrome.h"
#include "spdf_win_sidebar_outline.h" /* the nesting rules: has_children, keys, visibility */

#ifdef __cplusplus
extern "C" {
#endif

/* --- the sidebar's Chapters list ----------------------------------------
 *
 * macOS: a headerless NSTableView, rowHeight 25.0, one column 230.0 wide in a
 * 240 pt sidebar (ShenzhenPDFMac.mm:3149-3213). The row view is
 * SPDFMacSidebarChapters.mm's since a5820117a: a 14 pt disclosure triangle whose
 * leading edge IS the indent -- 6 pt plus 13 pt per level, level clamped to
 * [0, 16] -- then the title 2 pt after it, inset 6 trailing, centred
 * vertically, systemFontOfSize:13, single line, truncating TAIL. A childless
 * row keeps the triangle's WIDTH, hidden, so titles at one depth stay aligned;
 * a nested title therefore lines up under its parent's title, not under the
 * parent's triangle. (Before that commit both platforms indented the STRING by
 * level*3 spaces; the real indent replaced it, and this port follows.)
 *
 * NESTING is derived, not stored (spdf_win_sidebar_outline.h): a row's children
 * are the rows after it at a deeper level. The builder below hides the rows
 * under a collapsed parent and marks each survivor has_children / collapsed;
 * a live FILTER suppresses nesting entirely, since nesting a filtered list would
 * hide matches under parents that did not match. Collapse state is per
 * document (spdf_win_chapter_state.h) and everything starts expanded.
 *
 * A row whose destination did not resolve (page_index < 0: a /Fit-less dest, a
 * missing target, an external URL -- all three are in the core's conformance
 * suite) is drawn in secondaryLabelColor rather than labelColor, which is
 * exactly macOS's `page >= 0 ? labelColor : secondaryLabelColor`. */

#define SPDF_WIN_SIDEBAR_ROW_H 25.0        /* :3160 rowHeight */
#define SPDF_WIN_SIDEBAR_COLUMN_W 230.0    /* :3166 single column width */
#define SPDF_WIN_SIDEBAR_INSET 8.0         /* panel edge -> column, in a 240 pt sidebar */
#define SPDF_WIN_SIDEBAR_CELL_LEADING 8.0  /* the Search/Comments rows' text inset (:16590) */
#define SPDF_WIN_SIDEBAR_CELL_TRAILING 6.0 /* :16591 */
#define SPDF_WIN_SIDEBAR_FONT_SIZE 13.0    /* :16622 systemFontOfSize:13 */
#define SPDF_WIN_SIDEBAR_MAX_LEVEL 16      /* styleSidebarCell: MIN(level, 16) */
/* SPDFMacSidebarChapters.mm: the triangle's leading constraint is 6 + level *
 * kSPDFChapterIndentPerLevel (13); kSPDFChapterTriangleWidth is 14; the title's
 * leading is the triangle's trailing + 2. */
#define SPDF_WIN_SIDEBAR_DISCLOSURE_LEADING 6.0
#define SPDF_WIN_SIDEBAR_INDENT_PER_LEVEL 13.0
#define SPDF_WIN_SIDEBAR_DISCLOSURE_W 14.0
#define SPDF_WIN_SIDEBAR_DISCLOSURE_GAP 2.0

/* Rows above the list, in points: the segmented control and the filter field
 * are both 24 pt with 8 pt around them, and 6 pt separates the field from the
 * first row. Transcribed from spdf_win_chrome_panels.cpp, which had them as
 * literals at its draw sites; they are here now so the hit-test and the paint
 * cannot disagree. */
#define SPDF_WIN_SIDEBAR_TOP_PAD 8.0
#define SPDF_WIN_SIDEBAR_CONTROL_H 24.0
#define SPDF_WIN_SIDEBAR_FIELD_H 24.0
#define SPDF_WIN_SIDEBAR_FIELD_GAP 6.0

/* THE ONE EXPAND / COLLAPSE BUTTON, at the trailing end of the filter field's
 * row (SPDFMacSidebarChapters.mm since 0a1f0845c): kSPDFOutlineToggleWidth 22,
 * kSPDFOutlineToggleGap 4 between it and the field. It replaced a labelled
 * Expand All / Collapse All pair on a row of its own, so the list got that row
 * back. It shows the action it will PERFORM -- arrows drawing in while anything
 * is still expanded, arrows opening out once everything is collapsed -- and it
 * is there only while something is nestable: on a flat outline, in Comments, or
 * over search results the field takes the width back. */
#define SPDF_WIN_SIDEBAR_TOGGLE_W 22.0
#define SPDF_WIN_SIDEBAR_TOGGLE_GAP 4.0

typedef struct SpdfWinSidebarRow {
    const wchar_t* title;  /* UTF-16, the title alone -- the indent is geometry; borrowed */
    int page_index;        /* < 0 when the outline entry has no resolvable page */
    int level;             /* clamped [0, 16] */
    int outline_index;     /* position in spdf_load_outline order, for the click route */
    int has_children;      /* draws the disclosure triangle; 0 under a live filter */
    int collapsed;         /* the triangle points right and the children are not rows */
} SpdfWinSidebarRow;

typedef struct SpdfWinSidebarContent {
    const SpdfWinSidebarRow* rows;
    int row_count;   /* rows AFTER filtering and collapsing */
    int total_count; /* rows before filtering; 0 means the document has no outline */
    int loaded;      /* 0 while the outline has not been read yet */
    int selected_row;
    int hot_row;   /* -1 when nothing is hovered */
    float scroll_y; /* device px, 0 at the top of the list */
    const wchar_t* filter; /* the live filter text; NULL or empty means none */
    /* The toggle button's two facts: how many rows have children (0 hides the
     * button), and how many of those are open (0 flips it to "expand"). Both 0
     * under a live filter, where nesting is off. */
    int collapsible_count;
    int open_count;
} SpdfWinSidebarContent;

/* The sidebar's bands, in the panel's own device-pixel coordinates. One
 * function so the painter and the input router cannot drift: this is
 * spdf_win_chrome.h's rule 2 applied one level down. `filter` comes back empty
 * in Search mode, where macOS hides and disables the field (:3149-3157).
 *
 * `toggle` is the expand / collapse button's slot at the trailing end of the
 * filter row, Chapters only. The layout cannot know whether the list is
 * nestable, so `filter` is always the FULL width here and the painter narrows
 * it with spdf_win_sidebar_filter_beside_toggle() while the button is up. The
 * router reports a click in the slot as the filter's (the field is what is
 * there when nothing nests); the app refines it against the content it has
 * (spdf_win_chrome_content_sidebar_press). */
typedef struct SpdfWinSidebarLayout {
    SpdfWinChromeRect sections;
    SpdfWinChromeRect filter;
    SpdfWinChromeRect toggle;
    SpdfWinChromeRect list;
    float row_h;
} SpdfWinSidebarLayout;

static SPDF_WIN_CHROME_INLINE void spdf_win_sidebar_layout(SpdfWinChromeRect sidebar, int section, float dpi_scale,
                                                           SpdfWinSidebarLayout* out) {
    float s = dpi_scale > 0.0f ? dpi_scale : 1.0f;
    float y;

    if (!out) return;
    out->sections = spdf_win_chrome_zero();
    out->filter = spdf_win_chrome_zero();
    out->toggle = spdf_win_chrome_zero();
    out->list = spdf_win_chrome_zero();
    out->row_h = spdf_win_chrome_px(SPDF_WIN_SIDEBAR_ROW_H, s);
    if (spdf_win_chrome_rect_empty(sidebar)) return;

    y = sidebar.y + spdf_win_chrome_px(SPDF_WIN_SIDEBAR_TOP_PAD, s);
    out->sections.x = sidebar.x + spdf_win_chrome_px(SPDF_WIN_SIDEBAR_INSET, s);
    out->sections.w = sidebar.w - 2.0f * spdf_win_chrome_px(SPDF_WIN_SIDEBAR_INSET, s);
    out->sections.y = y;
    out->sections.h = spdf_win_chrome_px(SPDF_WIN_SIDEBAR_CONTROL_H, s);
    y = out->sections.y + out->sections.h + spdf_win_chrome_px(SPDF_WIN_SIDEBAR_TOP_PAD, s);

    if (section != 2) {
        out->filter = out->sections;
        out->filter.y = y;
        out->filter.h = spdf_win_chrome_px(SPDF_WIN_SIDEBAR_FIELD_H, s);
        y = out->filter.y + out->filter.h + spdf_win_chrome_px(SPDF_WIN_SIDEBAR_FIELD_GAP, s);
        if (section == 0) {
            /* Trailing end of the field's row, the button's own width, centred
             * on the field (toggle.centerYAnchor == filterField.centerYAnchor). */
            out->toggle = out->filter;
            out->toggle.w = spdf_win_chrome_px(SPDF_WIN_SIDEBAR_TOGGLE_W, s);
            out->toggle.x = out->filter.x + out->filter.w - out->toggle.w;
            if (out->toggle.x < out->filter.x) out->toggle = spdf_win_chrome_zero();
        }
    }

    out->list.x = sidebar.x + spdf_win_chrome_px(SPDF_WIN_SIDEBAR_INSET, s);
    out->list.w = sidebar.w - 2.0f * spdf_win_chrome_px(SPDF_WIN_SIDEBAR_INSET, s);
    out->list.y = y;
    out->list.h = spdf_win_chrome_max(0.0f, sidebar.y + sidebar.h - y);
    if (out->list.w < 0.0f) out->list.w = 0.0f;
}

/* The filter field as drawn while the toggle button is up: it stops short of
 * the panel edge by the button's width and the gap, and reclaims the width when
 * the button goes away (the mac's filter-trailing constraint, -(8 + 22 + 4)). */
static SPDF_WIN_CHROME_INLINE SpdfWinChromeRect spdf_win_sidebar_filter_beside_toggle(const SpdfWinSidebarLayout* l,
                                                                                      float dpi_scale) {
    SpdfWinChromeRect f;
    float s = dpi_scale > 0.0f ? dpi_scale : 1.0f;
    if (!l) return spdf_win_chrome_zero();
    f = l->filter;
    if (spdf_win_chrome_rect_empty(l->toggle)) return f;
    f.w -= l->toggle.w + spdf_win_chrome_px(SPDF_WIN_SIDEBAR_TOGGLE_GAP, s);
    if (f.w < 0.0f) f.w = 0.0f;
    return f;
}

/* The disclosure triangle's slot inside one row: the row's height, 14 pt wide,
 * its leading edge 6 + level*13 pt in from the row's. Drawn only when the row
 * has children; the WIDTH is kept either way so the title rect below aligns
 * titles at one depth. Also the click target for folding the row. */
static SPDF_WIN_CHROME_INLINE SpdfWinChromeRect spdf_win_sidebar_disclosure_rect(SpdfWinChromeRect row, int level,
                                                                                 float dpi_scale) {
    SpdfWinChromeRect r = row;
    float s = dpi_scale > 0.0f ? dpi_scale : 1.0f;
    if (level < 0) level = 0;
    if (level > SPDF_WIN_SIDEBAR_MAX_LEVEL) level = SPDF_WIN_SIDEBAR_MAX_LEVEL;
    r.x = row.x + spdf_win_chrome_px(SPDF_WIN_SIDEBAR_DISCLOSURE_LEADING + (double)level * SPDF_WIN_SIDEBAR_INDENT_PER_LEVEL,
                                     s);
    r.w = spdf_win_chrome_px(SPDF_WIN_SIDEBAR_DISCLOSURE_W, s);
    if (r.x + r.w > row.x + row.w) r.w = spdf_win_chrome_max(0.0f, row.x + row.w - r.x);
    return r;
}

/* The title's rect: 2 pt after the triangle's slot, 6 pt trailing inset. */
static SPDF_WIN_CHROME_INLINE SpdfWinChromeRect spdf_win_sidebar_title_rect(SpdfWinChromeRect row, int level,
                                                                            float dpi_scale) {
    SpdfWinChromeRect d = spdf_win_sidebar_disclosure_rect(row, level, dpi_scale);
    SpdfWinChromeRect t = row;
    float s = dpi_scale > 0.0f ? dpi_scale : 1.0f;
    t.x = d.x + spdf_win_chrome_px(SPDF_WIN_SIDEBAR_DISCLOSURE_W + SPDF_WIN_SIDEBAR_DISCLOSURE_GAP, s);
    t.w = spdf_win_chrome_max(0.0f, row.x + row.w - spdf_win_chrome_px(SPDF_WIN_SIDEBAR_CELL_TRAILING, s) - t.x);
    return t;
}

/* One row's rect in panel coordinates, scroll included. Rows outside the list
 * viewport come back non-empty and simply do not intersect it, so the caller
 * clips rather than special-casing. */
static SPDF_WIN_CHROME_INLINE SpdfWinChromeRect spdf_win_sidebar_row_rect(const SpdfWinSidebarLayout* l, float scroll_y,
                                                                          int row) {
    SpdfWinChromeRect r;
    if (!l || row < 0 || l->row_h <= 0.0f) return spdf_win_chrome_zero();
    r.x = l->list.x;
    r.w = l->list.w;
    r.h = l->row_h;
    r.y = l->list.y - scroll_y + l->row_h * (float)row;
    return r;
}

/* Which row a point lands in, or -1. Used by the input router; the painter uses
 * the same arithmetic through spdf_win_sidebar_row_rect. */
static SPDF_WIN_CHROME_INLINE int spdf_win_sidebar_row_at(const SpdfWinSidebarLayout* l, float scroll_y, int row_count,
                                                          float x, float y) {
    int row;
    if (!l || row_count <= 0 || l->row_h <= 0.0f) return -1;
    if (!spdf_win_chrome_contains(l->list, x, y)) return -1;
    row = (int)floorf((y - l->list.y + scroll_y) / l->row_h);
    if (row < 0 || row >= row_count) return -1;
    return row;
}

/* How far the list can scroll, in device px. */
static SPDF_WIN_CHROME_INLINE float spdf_win_sidebar_max_scroll(const SpdfWinSidebarLayout* l, int row_count) {
    float content;
    if (!l || row_count <= 0) return 0.0f;
    content = l->row_h * (float)row_count;
    return spdf_win_chrome_max(0.0f, content - l->list.h);
}

/* The filter, macOS's semantics exactly (:9666-9670): an empty filter matches
 * everything, an empty title matches nothing, and otherwise it is a substring
 * test that ignores BOTH case and diacritics -- NSCaseInsensitiveSearch |
 * NSDiacriticInsensitiveSearch. FindNLSStringEx with LINGUISTIC_IGNORECASE |
 * NORM_IGNORENONSPACE is the Windows spelling of that same pair, which is why
 * this is not a hand-rolled towupper loop: "Zürich" must match "zurich" on both
 * platforms, and a chapter title is exactly where an accented or CJK name shows
 * up. The towupper loop is kept only as the fallback for a locale that cannot
 * do the linguistic compare at all. */
static SPDF_WIN_CHROME_INLINE int spdf_win_sidebar_ascii_fold_find(const wchar_t* hay, const wchar_t* needle) {
    size_t i, j;
    for (i = 0; hay[i]; ++i) {
        for (j = 0; needle[j]; ++j) {
            wchar_t a = hay[i + j];
            wchar_t b = needle[j];
            if (!a) return 0;
            if (a >= L'a' && a <= L'z') a = (wchar_t)(a - L'a' + L'A');
            if (b >= L'a' && b <= L'z') b = (wchar_t)(b - L'a' + L'A');
            if (a != b) break;
        }
        if (!needle[j]) return 1;
    }
    return 0;
}

static SPDF_WIN_CHROME_INLINE int spdf_win_sidebar_title_matches(const wchar_t* title, const wchar_t* filter) {
    int found;
    if (!filter || !filter[0]) return 1;
    if (!title || !title[0]) return 0;
    SetLastError(ERROR_SUCCESS);
    found = FindNLSStringEx(LOCALE_NAME_USER_DEFAULT, FIND_FROMSTART | LINGUISTIC_IGNORECASE | NORM_IGNORENONSPACE,
                            title, -1, filter, -1, NULL, NULL, NULL, 0);
    if (found >= 0) return 1;
    if (GetLastError() == ERROR_SUCCESS) return 0; /* a real "not found" */
    return spdf_win_sidebar_ascii_fold_find(title, filter);
}

/* --- outline -> rows -----------------------------------------------------
 *
 * Header-only, and deliberately: portable/win/tests/sidebar_rows_test.c drives
 * these with hand-built outlines -- CJK, accented and malformed titles, the
 * cases a narrow conversion mangles silently on this machine's 1252 code page --
 * and it should not have to link the thumbnail store, the render pool and MuPDF
 * to do it. `titles`/`pages`/`levels` are the three parallel arrays
 * spdf_outline holds; `text_arena` receives the indented UTF-16 the rows point
 * into. Returns the number of rows written. */
/* UTF-8 in, UTF-16 out, and never anything narrower. A chapter title is exactly
 * where a CJK or accented name turns up, and this machine's ANSI code page is
 * 1252 -- so MultiByteToWideChar(CP_UTF8, ...) is not a stylistic choice, it is
 * the difference between "Überblick" and "Ãœberblick". Returns the number of
 * wchar_t written INCLUDING the terminator, or 0 on failure. */
static SPDF_WIN_CHROME_INLINE int spdf_win_sidebar_utf16_from_utf8(const char* utf8, wchar_t* out, int out_max) {
    int n;
    if (!out || out_max <= 0) return 0;
    if (!utf8 || !*utf8) {
        out[0] = 0;
        return 1;
    }
    n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out, out_max);
    if (n > 0) return n;
    /* Malformed UTF-8 from a hostile or damaged document must not lose the row.
     * Without MB_ERR_INVALID_CHARS the conversion substitutes U+FFFD and cannot
     * fail for that reason, so reaching here means the buffer was too small; the
     * title is truncated rather than dropped. */
    n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    if (n <= 0) {
        out[0] = 0;
        return 1;
    }
    if (MultiByteToWideChar(CP_UTF8, 0, utf8, out_max - 1, out, out_max - 1) <= 0) {
        out[0] = 0;
        return 1;
    }
    out[out_max - 1] = 0;
    return out_max;
}

/* `collapsed` / `collapsed_count` are the document's remembered keys
 * (spdf_win_sidebar_outline.h); NULL means everything expanded. Nesting -- the
 * hidden descendants, has_children, collapsed -- applies only while `filter` is
 * empty, exactly as the mac's chapterLevelsForCurrentSidebar returns nil for a
 * live filter. `visible` is scratch of at least `count` bytes when nesting is
 * on; NULL makes the builder treat every row as visible. */
static SPDF_WIN_CHROME_INLINE int spdf_win_sidebar_build_rows_ex(const char* const* titles, const int* pages,
                                                                 const int* levels, int count, const wchar_t* filter,
                                                                 const char* const* collapsed, int collapsed_count,
                                                                 unsigned char* visible, SpdfWinSidebarRow* out_rows,
                                                                 int out_max, wchar_t* text_arena,
                                                                 size_t arena_wchars) {
    int i;
    int written = 0;
    size_t used = 0;
    int nesting = (!filter || !filter[0]) && levels != NULL;
    char key[SPDF_WIN_SIDEBAR_OUTLINE_KEY_MAX];

    if (!out_rows || out_max <= 0 || !text_arena || arena_wchars == 0) return 0;
    if (nesting && visible) spdf_win_sidebar_outline_visible(levels, count, collapsed, collapsed_count, visible);
    for (i = 0; i < count; ++i) {
        wchar_t title[512];
        int level = levels ? levels[i] : 0;
        size_t need;
        wchar_t* dst;

        if (written >= out_max) break;
        if (nesting && visible && !visible[i]) continue; /* under a collapsed parent */
        if (!spdf_win_sidebar_utf16_from_utf8(titles ? titles[i] : NULL, title, (int)(sizeof(title) / sizeof(title[0])))) continue;
        /* macOS substitutes "Untitled" for a missing title (:9876). */
        if (!title[0]) wcscpy_s(title, sizeof(title) / sizeof(title[0]), L"Untitled");
        if (!spdf_win_sidebar_title_matches(title, filter)) continue;

        if (level < 0) level = 0;
        if (level > SPDF_WIN_SIDEBAR_MAX_LEVEL) level = SPDF_WIN_SIDEBAR_MAX_LEVEL;
        need = wcslen(title) + 1;
        if (used + need > arena_wchars) break;
        dst = text_arena + used;
        wcscpy_s(dst, need, title);
        used += need;

        out_rows[written].title = dst;
        out_rows[written].page_index = pages ? pages[i] : -1;
        out_rows[written].level = level;
        out_rows[written].outline_index = i;
        out_rows[written].has_children = nesting ? spdf_win_sidebar_outline_has_children(levels, count, i) : 0;
        out_rows[written].collapsed =
            out_rows[written].has_children && collapsed_count > 0 &&
            spdf_win_sidebar_outline_key(levels, count, i, key, sizeof(key)) > 0 &&
            spdf_win_sidebar_outline_key_in(collapsed, collapsed_count, key);
        ++written;
    }
    return written;
}

/* The same with nothing collapsed: every row, marked has_children where it
 * has some. */
static SPDF_WIN_CHROME_INLINE int spdf_win_sidebar_build_rows(const char* const* titles, const int* pages,
                                                              const int* levels, int count, const wchar_t* filter,
                                                              SpdfWinSidebarRow* out_rows, int out_max,
                                                              wchar_t* text_arena, size_t arena_wchars) {
    return spdf_win_sidebar_build_rows_ex(titles, pages, levels, count, filter, NULL, 0, NULL, out_rows, out_max,
                                          text_arena, arena_wchars);
}

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_SIDEBAR_ROWS_H */
