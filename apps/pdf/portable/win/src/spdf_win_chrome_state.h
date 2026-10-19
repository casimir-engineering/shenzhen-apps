/* spdf_win_chrome_state.h -- what the chrome DRAWS, as opposed to where.
 *
 * Split out of spdf_win_chrome.h, which had grown past the 500-line cap
 * (tools/file-size-limits.md) as the model gained the toolbar readouts, the
 * scroller fractions, the find state and the sidebar state. The division is a
 * real one rather than a convenience: this file is the model -- values the window
 * layer fills and the painters read -- while spdf_win_chrome.h is the geometry
 * that turns a client rect into rects. Nothing here has any arithmetic about
 * WHERE anything sits.
 *
 * spdf_win_chrome.h includes this, so every existing include of that header
 * keeps compiling unchanged and no other file had to be touched for the split.
 *
 * THE ONE RULE THIS FILE ENFORCES: the model is plain values and borrowed
 * strings, with no pointer into app state and no toolkit type. That is what lets
 * a headless test hand-build a model and compose the entire window offscreen,
 * which is how the chrome is pixel-tested at all (spdf_win_chrome_paint.h).
 */
#ifndef SPDF_WIN_CHROME_STATE_H
#define SPDF_WIN_CHROME_STATE_H

#include <math.h>

/* For spdf_win_text_focus, which `focus` below carries. Taking it from there
 * rather than declaring a parallel enum here is the same decision
 * spdf_win_window.h states for spdf_win_chrome_button: two enums with the same
 * meaning and independent numbering is how a page field gets the find field's
 * focus ring. That header is pure and toolkit-free, so it costs nothing. */
#include "spdf_win_chrome_text.h"

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_CHROME_STATE_INLINE __inline
#else
#define SPDF_WIN_CHROME_STATE_INLINE inline
#endif

/* The moved code keeps spdf_win_chrome.h's spelling of these two, so the
 * split is a pure move with no signature churn to review. */
#ifndef SPDF_WIN_CHROME_INLINE
#define SPDF_WIN_CHROME_INLINE SPDF_WIN_CHROME_STATE_INLINE
#endif

typedef struct SpdfWinChromeTab {
    const wchar_t* title;
    int read_only;
    int missing;
} SpdfWinChromeTab;

/* A comment marker as the INPUT ROUTER sees it: the annotation's bounds
 * inflated by the 3 pt hover slop and the click-to-edit badge inflated by its
 * 2 pt slop (spdf_win_annot_model.h), both already in CLIENT device pixels, so
 * the router -- which knows no page geometry -- tests a point against them
 * with four comparisons (spdf_win_annot_marks.h). `comment_index` is
 * spdf_comment_item.index, what the core's edit and delete calls take. */
typedef struct SpdfWinAnnotMark {
    int comment_index;
    int page_index;
    float x0, y0, x1, y1;     /* bounds + hover slop */
    float bx0, by0, bx1, by1; /* badge + click slop */
} SpdfWinAnnotMark;

/* A MARKDOWN CODE BOX'S TWO CONTROLS, in client device pixels, published by the
 * paint that drew them (spdf_win_md_code.h keeps the authoritative definition;
 * this is the same layout, declared here for the same reason SpdfWinAnnotMark
 * is -- the router and its tests must not need the Markdown module). `cx*` is
 * the Copy button, all zero where it stood down; `lx*` is the language pill. */
typedef struct SpdfWinMdCodeMark {
    int fence_index;
    int page_index;
    float lx0, ly0, lx1, ly1; /* language pill + slop */
    float cx0, cy0, cx1, cy1; /* copy button + slop, all zero when it stood down */
} SpdfWinMdCodeMark;

/* What the painters need to know that geometry does not carry. Deliberately a
 * plain value type with no pointers into app state beyond the strings it
 * borrows, so a headless test can build one by hand -- which is how the chrome
 * gets pixel-tested without a window. */
typedef struct SpdfWinChromeModel {
    /* Tab strip contents. `count` also drives the strip's GEOMETRY (tab width,
     * overflow, the visible window), which is why it lives in the model rather
     * than in a separate content struct. `hot` and `hot_close` are -1 when
     * nothing is hovered. */
    const SpdfWinChromeTab* tabs;
    int tab_count;
    int selected_tab;
    int hot_tab;
    int hot_close;
    /* A REORDER DRAG IN PROGRESS. `drag_tab` is the tab being dragged (-1 when
     * none) and `drop_slot` is the insertion position among the VISIBLE tabs
     * that spdf_win_tabstrip_drop_slot() returned for the pointer's current x
     * (-1 when none). Together they are everything needed to draw macOS's yellow
     * drop indicator (SPDFMacTabStripView.mm:684-699, whose metrics are
     * SPDF_WIN_TABSTRIP_DROP_INDICATOR_* in spdf_win_tabstrip.h).
     *
     * spdf_win_chrome_paint.cpp draws it from these two fields alone (the
     * wiring pass of 2026-09-02 landed the paint; the geometry is
     * spdf_win_tabstrip_drop_indicator_rect() in spdf_win_tabs_drag.h). The
     * REORDER itself happens on mouse-up through spdf_win_tabstrip_move_index(). */
    int drag_tab;
    int drop_slot;

    /* --- the caption buttons -----------------------------------------------
     *
     * The strip is the title bar (spdf_win_tabstrip.h's header), so the three
     * Windows caption buttons are drawn by the strip painter from these three
     * values and nothing else. `maximized` swaps the maximize glyph for restore;
     * `caption_hot` and `caption_pressed` are spdf_win_caption_button values,
     * SPDF_WIN_CAPTION_NONE (0) when nothing is hovered or held, which is what a
     * zeroed model already says. The WINDOW fills them, because only an HWND
     * knows its own zoom state and only WM_NCMOUSEMOVE knows the pointer is over
     * a non-client button; the painter must never ask an HWND itself, or the
     * chrome falls out of every offscreen pixel test in this port. A hand-built
     * model draws the three buttons at rest, which is what the headless
     * `--render-window-png --chrome` frame shows. */
    int maximized;
    int caption_hot;
    int caption_pressed;

    int dark;
    int presentation; /* collapses the strip and toolbar to zero, as :13634 does */
    int show_sidebar;
    int show_minimap;
    float sidebar_w;   /* points; 0 asks for the default */
    float minimap_w;   /* points; 0 asks for the default */
    int sidebar_section; /* 0 chapters, 1 comments, 2 search */
    int search_active;   /* the Search section exists only while a query is live */
    /* THE SELECTED TAB IS A MARKDOWN DOCUMENT, which puts the A−/A＋ text-size
     * pill in the toolbar (macOS item 10) and takes it away again on a PDF tab.
     * It is GEOMETRY, like search_active above it: the pill occupies 64 pt of
     * the row, so a router that left this zeroed while the painter drew the pill
     * would hit-test every later control 68 pt to the left of where it is. Both
     * the painter's model (spdf_win_chrome_model.h) and the router's
     * (chrome_layout_for_input) fill it from the same test. */
    int markdown;

    /* --- what the toolbar reads out -------------------------------------
     *
     * These are here rather than fetched by the painter because the painters
     * must stay callable with a hand-built model and no app at all: that is what
     * lets the whole window be composed offscreen and pixel-tested
     * (spdf_win_chrome_paint.h). Every one of them is a plain value the window
     * layer fills in spdf_win_chrome_model.cpp.
     *
     * `page_index` IS 0-BASED, like every page number inside this port
     * (spdf_win_main.cpp's header comment). The toolbar draws page_index + 1,
     * because the 1-based indicator is a PRESENTATION concern and this is where
     * that conversion is allowed to happen -- exactly what macOS does at
     * ShenzhenPDFMac.mm:10528 (`_pageIndex + 1`). -1 means "no document", which
     * macOS draws as an empty field (:10528's `hasDoc` branch). */
    int page_index;
    int page_count;
    /* WHAT THE READER HAS TYPED into the page field, borrowed UTF-16, or NULL
     * when the field is not being edited. NULL is the normal case and means
     * "show page_index + 1"; non-NULL means the field is under the reader's
     * hands and must show exactly what they typed, including an empty string
     * while they are between numbers. A field that snapped back to the current
     * page on every keystroke could not be typed into at all. */
    const wchar_t* page_text;
    /* Which field has the keyboard, as spdf_win_text_focus. The painter draws
     * the focus ring on that one rectangle; SPDF_WIN_FOCUS_NONE means the
     * DOCUMENT has focus, which is what the arrow keys then scroll. */
    int focus;
    /* Device pixels per PDF point, straight from spdf_win_canvas_zoom(), and
     * the display's device-pixels-per-logical-pixel that turns it into a
     * percentage. Two fields rather than a pre-divided percentage so the model
     * carries measurements and the toolbar owns the rounding. */
    float zoom;
    float zoom_dpi_scale;
    int fit_mode; /* spdf_win_chrome_fit */

    /* --- scrollers -------------------------------------------------------
     *
     * Fractions rather than pixel offsets, so the scroller geometry does not
     * have to know the document's size in any unit: `pos` is the scrolled
     * fraction in [0,1] and `visible` is the fraction of the content the
     * viewport shows, which IS the thumb's proportional length. `h_scrollable`
     * says whether the content overflows horizontally at all -- until now
     * SpdfWinHScrollClamp.scrollable was computed by the canvas and thrown away
     * (spdf_win_canvas.cpp), which is the one thing needed to decide whether a
     * horizontal trough should exist. */
    float v_pos;
    float v_visible;
    float h_pos;
    float h_visible;
    int h_scrollable;

    /* --- find ------------------------------------------------------------
     *
     * `query` is borrowed UTF-16 and may be NULL. The counter's four states are
     * macOS's exactly (ShenzhenPDFMac.mm:10631-10652): empty text with no
     * query, "..." while a search is running, "0 / 0" on no match, else
     * "<match> / <total>" -- and the counter AND the prev/next pill are hidden
     * whenever the query is empty. `match_index` is 0-BASED here; the counter
     * draws index + 1, the same presentation-layer convention as page_index.
     *
     * `marks`/`mark_count` are the heat-map ticks for the vertical trough, each
     * a document-height fraction in [0,1], already deduplicated by the search
     * layer -- the painter must not have to sort or thin them on the paint
     * path. `active_mark` is an index into `marks`, or -1. */
    const wchar_t* query;
    int regex;
    int searching;
    int match_count;
    int match_index;
    const float* marks;
    int mark_count;
    int active_mark;

    /* --- sidebar ---------------------------------------------------------
     * Borrowed UTF-16 filter text (may be NULL), the list's scroll offset in
     * device pixels, and the hovered row (-1 for none). */
    const wchar_t* sidebar_filter;
    float sidebar_scroll_y;
    int sidebar_hot_row;
    /* How many rows the list is CURRENTLY showing, after filtering. The input
     * router needs it -- which row a click landed on is a function of the row
     * count -- and the router has no access to the content provider, so the app
     * copies last frame's count in. Last frame's count is the right one: it is
     * the number of rows that were actually drawn under the pointer. */
    int sidebar_row_count;
    /* 0 when the current section has nothing to list, so the app can hide the
     * whole panel the way rebuildSidebar does (:9813-9905). */
    int sidebar_has_content;

    /* --- comment markers -------------------------------------------------
     * One per comment on a drawn page, CLIENT device pixels, published per
     * paint by the annotations glue (spdf_win_annot.h) and copied into the
     * ROUTER's model so a badge is hit exactly where it was drawn. Borrowed;
     * NULL/0 -- the zeroed model, every headless frame -- means none. The
     * painters never read these: the marks themselves are scene overlays. */
    const SpdfWinAnnotMark* annot_marks;
    /* The code pills the last paint published, and how many. Filled beside
     * annot_marks in spdf_win_chrome_view_ui.h; zero on a PDF tab. */
    const SpdfWinMdCodeMark* md_code_marks;
    int md_code_mark_count;
    int annot_mark_count;
} SpdfWinChromeModel;

/* The fit-mode popup's four fixed items, in macOS's own order
 * (ShenzhenPDFMac.mm:3006-3011), plus the CUSTOM state that has no fixed title:
 * macOS inserts a "<N>%" item for it and removes it again once the zoom returns
 * to 1.0 (syncToolbarState, :10484-10505).
 *
 * Numbered independently of spdf_win_zoom_mode on purpose. spdf_win_chrome.h
 * must not include spdf_win_canvas.h -- the chrome is drawn in tests that have
 * no canvas, no document and no MuPDF -- so the window layer maps between the
 * two. FIT_HEIGHT is listed because macOS offers it and this is the vocabulary
 * the toolbar speaks; the Windows canvas has no fit-height mode yet, so nothing
 * currently produces it. */
typedef enum spdf_win_chrome_fit {
    SPDF_WIN_CHROME_FIT_CUSTOM = 0,
    SPDF_WIN_CHROME_FIT_ACTUAL,
    SPDF_WIN_CHROME_FIT_WIDTH,
    SPDF_WIN_CHROME_FIT_HEIGHT,
    SPDF_WIN_CHROME_FIT_PAGE
} spdf_win_chrome_fit;

/* The fixed title for a fit mode, or NULL for CUSTOM -- whose title is a
 * percentage the caller formats, because a printf in a geometry header would
 * drag <stdio.h> into every test that only wants rectangles. */
static SPDF_WIN_CHROME_INLINE const wchar_t* spdf_win_chrome_fit_label(int fit_mode) {
    switch (fit_mode) {
        case SPDF_WIN_CHROME_FIT_ACTUAL: return L"100%";
        case SPDF_WIN_CHROME_FIT_WIDTH: return L"Fit Width";
        case SPDF_WIN_CHROME_FIT_HEIGHT: return L"Fit Height";
        case SPDF_WIN_CHROME_FIT_PAGE: return L"Fit Page";
        default: return NULL;
    }
}

/* The percentage a custom zoom reads out. macOS formats `_zoom * 100.0` with
 * "%.0f%%" (:10486), where its zoom is points-to-points; ours is device pixels
 * per PDF point, so it is divided by the DPI scale first -- otherwise a 150%
 * display would report 150% at actual size. */
static SPDF_WIN_CHROME_INLINE int spdf_win_chrome_zoom_percent(const SpdfWinChromeModel* m) {
    float s;
    if (!m) return 100;
    s = m->zoom_dpi_scale > 0.0f ? m->zoom_dpi_scale : 1.0f;
    if (!(m->zoom > 0.0f)) return 100;
    return (int)floorf(m->zoom / s * 100.0f + 0.5f);
}


#endif /* SPDF_WIN_CHROME_STATE_H */
