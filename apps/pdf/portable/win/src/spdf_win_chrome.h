/* spdf_win_chrome.h — how the client area is divided, for the Win32 frontend.
 *
 * WHAT THIS IS: the arithmetic that turns one client rect into the bands and
 * panels the macOS window is made of, plus the model the painters read. Pure,
 * toolkit-free, header-only, no state, no allocation — the same shape as
 * spdf_win_layout.h and spdf_win_tabstrip.h, and testable the same way
 * (portable/win/tests/chrome_geometry_test.c).
 *
 * THE macOS WINDOW, top to bottom (ShenzhenPDFMac.mm:3292-3312):
 *
 *     +--------------------------------------------------+
 *     | tab strip                       42 pt  [ _ o x ] |
 *     +--------------------------------------------------+
 *     | toolbar                                    42 pt |
 *     +--------------------------------------------------+
 *     | sidebar  | |            canvas            | | mm |
 *     |  240 pt  |5|                              |5|126.5
 *     +--------------------------------------------------+
 *
 * The strip IS the title bar on both platforms. macOS puts it inside the
 * transparent title bar and reserves a leading inset for the traffic lights;
 * here the client area is extended over the caption (spdf_win_window.cpp's
 * WM_NCCALCSIZE) and the strip reserves a TRAILING inset for the three Windows
 * caption buttons, which the chrome draws itself -- `caption` below is that
 * reserve, and it lies INSIDE the strip rect rather than beside it, because the
 * band, its hairline and its hit-testing are all still the strip's.
 *
 * The middle row is an NSSplitView (vertical, thin divider) filling the rest.
 * BOTH side panels are visible by default -- `_defaultSidebarVisibleForNewDocuments
 * = YES` (:836-838) and the minimap likewise (:837-840) -- which is worth stating
 * because a Windows reader coming from SumatraPDF will assume otherwise, and
 * because "looks like the Mac app" means both panels showing on first launch.
 *
 * WHY THE GEOMETRY IS SEPARATE FROM THE PAINTING. Two reasons, both learned in
 * this port rather than assumed:
 *
 *   1. spdf_win_paint() must never require an HWND (spdf_win_d2d.h). That rule
 *      is what let Phase 1 be verified at all -- the live window's client area
 *      was measured byte-identical to the offscreen compose path. Chrome that
 *      computes its own rects from an HWND would put itself outside every pixel
 *      test in the repo. Chrome laid out by this header stays inside them.
 *   2. Hit-testing and painting must agree exactly. On macOS they do because
 *      AppKit owns both; here they agree only if they call the same functions.
 *      Every rect below is consumed by the painter AND by the input router.
 *
 * UNITS. Points in, device pixels out. Every function takes a `dpi_scale` and
 * returns device-pixel rects, because chrome is screen furniture: a 42 pt strip
 * must be 63 px at 150%. This is deliberately unlike SPDF_WIN_PAGE_MARGIN_H/V in
 * spdf_win_layout.h, which are content-space and NOT DPI-scaled -- page margins
 * live in document coordinates. Keeping the two in different spaces is
 * intentional; do not unify them.
 *
 * Rects are LEFT/TOP/WIDTH/HEIGHT in the client area's own coordinates, origin
 * top-left, y increasing downward -- Win32's convention and D2D's, not
 * AppKit's. So "the tab strip is at the top" reads y = 0 here and y = maxY on
 * macOS; the numbers are the same, the axis is flipped.
 */
#ifndef SPDF_WIN_CHROME_H
#define SPDF_WIN_CHROME_H

#include <math.h>

/* For the caption-button reserve (SPDF_WIN_TABSTRIP_TRAILING_INSET), which is
 * the strip's own metric and must be the one number in one place: the layout's
 * `caption` rect and the strip's `+` position both derive from it. */
#include "spdf_win_tabstrip.h"

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_CHROME_INLINE __inline
#else
#define SPDF_WIN_CHROME_INLINE inline
#endif

/* --- metrics, all cited to portable/mac/ShenzhenPDFMac.mm ---------------- */

#define SPDF_WIN_CHROME_TABSTRIP_H 42.0 /* :68  kTabStripHeight */
#define SPDF_WIN_CHROME_TOOLBAR_H 42.0  /* :3293 toolbar height pin */

/* :72-76. kSearchSidebarMinWidth 216.0 applies while the Search section is
 * showing; the caller raises the minimum then rather than this header guessing
 * which section is live. */
#define SPDF_WIN_CHROME_SIDEBAR_W 240.0
#define SPDF_WIN_CHROME_SIDEBAR_MIN_W 176.0
#define SPDF_WIN_CHROME_SIDEBAR_MAX_W 320.0
#define SPDF_WIN_CHROME_SIDEBAR_SEARCH_MIN_W 216.0
/* :72-76 again: never more than this fraction of the split view. */
#define SPDF_WIN_CHROME_SIDEBAR_MAX_FRACTION 0.34

/* :71, persisted as settings["minimapWidth"], clamped [72, 260] on read
 * (:1455) and [72, MAX(120, MIN(320, containerWidth * 0.35))] on drag
 * (:9535-9537). The odd default is macOS's, not a typo. */
#define SPDF_WIN_CHROME_MINIMAP_W 126.5
#define SPDF_WIN_CHROME_MINIMAP_MIN_W 72.0
#define SPDF_WIN_CHROME_MINIMAP_MAX_W 260.0
#define SPDF_WIN_CHROME_MINIMAP_DRAG_MAX_FRACTION 0.35

/* :77-78. Drawn as windowBackgroundColor with a 1 pt separator line down its
 * centre and a resizeLeftRight cursor (SPDFMacUIHelpers.mm:425-431). */
#define SPDF_WIN_CHROME_DIVIDER_W 5.0

/* Scroller thickness. macOS uses a legacy-style NSScroller, 15 pt wide, and
 * never autohides it; Windows' own metric (SM_CXVSCROLL, 17 px at 96 dpi) is
 * close but is a user setting, and a pixel test whose expected value depends on
 * a user setting is not a test. 15 pt matches macOS and DPI-scales like every
 * other chrome metric here.
 *
 * The heat-map geometry that rides on the vertical trough is macOS's own
 * (SPDFMacUIHelpers.mm:453-479): the track is inset 2 pt top and bottom, a
 * marker starts 2 pt in from the slot's left edge and is MAX(2, slotWidth - 4)
 * wide, the ACTIVE match is 2 pt tall and the others 1 pt, and a marker closer
 * than 1.5 pt to the previous one is dropped rather than drawn over it. */
#define SPDF_WIN_CHROME_SCROLLBAR_W 15.0
#define SPDF_WIN_CHROME_SCROLL_TRACK_INSET 2.0
#define SPDF_WIN_CHROME_SCROLL_MARKER_INSET 2.0
#define SPDF_WIN_CHROME_SCROLL_MARKER_MIN_W 2.0
#define SPDF_WIN_CHROME_SCROLL_MARKER_ACTIVE_H 2.0
#define SPDF_WIN_CHROME_SCROLL_MARKER_H 1.0
#define SPDF_WIN_CHROME_SCROLL_MARKER_MIN_GAP 1.5
/* Shortest a thumb may get, so a 10,000-page document still leaves something
 * to grab. Not a macOS number -- AppKit enforces its own minimum internally. */
#define SPDF_WIN_CHROME_SCROLL_THUMB_MIN 24.0

/* Window sizing (:2912-2938, :69-70). Windows currently applies NO minimum at
 * all and derives its initial size from page 0, so golden.pdf opens a 244x286
 * window -- narrower than its own caption buttons. These are the macOS numbers
 * to adopt. */
#define SPDF_WIN_CHROME_DEFAULT_CONTENT_W 1120.0
#define SPDF_WIN_CHROME_DEFAULT_CONTENT_H 800.0
#define SPDF_WIN_CHROME_MIN_CONTENT_W 560.0
#define SPDF_WIN_CHROME_MIN_CONTENT_H 380.0

typedef struct SpdfWinChromeRect {
    float x, y, w, h;
} SpdfWinChromeRect;

/* Which chrome element a point lands in. The order of the divider cases
 * matters to the caller: a divider's grab area overlaps its neighbours'
 * edges, so dividers are tested first (see spdf_win_chrome_hit). */
typedef enum spdf_win_chrome_part {
    SPDF_WIN_CHROME_NONE = 0,
    SPDF_WIN_CHROME_TABSTRIP,
    SPDF_WIN_CHROME_TOOLBAR,
    SPDF_WIN_CHROME_SIDEBAR,
    SPDF_WIN_CHROME_SIDEBAR_DIVIDER,
    SPDF_WIN_CHROME_CANVAS,
    SPDF_WIN_CHROME_MINIMAP_DIVIDER,
    SPDF_WIN_CHROME_MINIMAP,
    /* The two scrollers. Inside the canvas region, not siblings of it, because
     * that is where macOS puts them: an NSScrollView contains the document view
     * and its scrollers, and the scroll view is what sits between the sidebar
     * and the minimap. `autohidesScrollers = NO` on both of macOS's scroll
     * views (ShenzhenPDFMac.mm:3225-3227), so the trough is ALWAYS visible --
     * which is what makes it a usable position indicator and a place to hang the
     * search heat-map. */
    SPDF_WIN_CHROME_VSCROLL,
    SPDF_WIN_CHROME_HSCROLL,
    /* The caption-button reserve at the strip's trailing end. Tested BEFORE the
     * strip because it lies inside the strip's rect. Which of the three buttons
     * is a further question the input router asks spdf_win_tabstrip_caption_hit().
     * Appended, so no existing part changes number. */
    SPDF_WIN_CHROME_CAPTION
} spdf_win_chrome_part;

/* The full division of one client area. Empty rects (w or h <= 0) mean the
 * element is not present -- hidden by the user, or squeezed out by a window too
 * small to hold it. Every consumer must treat w <= 0 as absent rather than
 * assuming the element is always there; a 560 pt minimum window still has to
 * survive a user dragging the sidebar to its maximum. */
typedef struct SpdfWinChromeLayout {
    SpdfWinChromeRect tabstrip;
    /* The three caption buttons' reserve: the trailing
     * SPDF_WIN_TABSTRIP_TRAILING_INSET points of the strip, full strip height,
     * INSIDE `tabstrip`. Empty whenever the strip is. Coarse hit-testing only;
     * the individual buttons come from spdf_win_tabstrip_caption_rect(). */
    SpdfWinChromeRect caption;
    SpdfWinChromeRect toolbar;
    SpdfWinChromeRect sidebar;
    SpdfWinChromeRect sidebar_divider;
    /* The DOCUMENT area -- what the canvas lays itself out into and what
     * spdf_win_paint() translates the page rects by. It EXCLUDES the two
     * scrollers, which sit inside the canvas region beside and below it. */
    SpdfWinChromeRect canvas;
    /* Vertical scroller, to the right of `canvas`, full canvas height.
     * Horizontal scroller, below `canvas`, canvas width. Either may be empty:
     * the horizontal one only appears when the content is actually wider than
     * the viewport, matching a scroll view with no horizontal overflow, while
     * the vertical one is always present because macOS never autohides it. */
    SpdfWinChromeRect vscroll;
    SpdfWinChromeRect hscroll;
    SpdfWinChromeRect minimap_divider;
    SpdfWinChromeRect minimap;
    float dpi_scale;
} SpdfWinChromeLayout;

/* One tab, as the strip needs to see it. Borrowed UTF-16 title; the tab model
 * in spdf_win_tabs.h owns the storage. `missing` and `read_only` exist because
 * macOS colours a tab red for a missing file and shows an orange dot for a
 * read-only source (SPDFMacTabStripView.mm:552-555, :585). */
/* The model the painters read. Kept here so every existing include of this
 * header still gets both halves. */
#include "spdf_win_chrome_state.h"

static SPDF_WIN_CHROME_INLINE SpdfWinChromeRect spdf_win_chrome_zero(void) {
    SpdfWinChromeRect r;
    r.x = r.y = r.w = r.h = 0.0f;
    return r;
}

static SPDF_WIN_CHROME_INLINE int spdf_win_chrome_rect_empty(SpdfWinChromeRect r) {
    return !(r.w > 0.0f && r.h > 0.0f);
}

static SPDF_WIN_CHROME_INLINE int spdf_win_chrome_contains(SpdfWinChromeRect r, float x, float y) {
    if (spdf_win_chrome_rect_empty(r)) return 0;
    return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h;
}

static SPDF_WIN_CHROME_INLINE float spdf_win_chrome_max(float a, float b) { return a > b ? a : b; }
static SPDF_WIN_CHROME_INLINE float spdf_win_chrome_min(float a, float b) { return a < b ? a : b; }

/* Whole device pixels. Chrome edges must land on the pixel grid: a band at a
 * fractional y puts a 1 px separator across two rows, which is the defect the
 * dark page border already hit at 150% (spdf_win_d2d.cpp draw_canvas_page). */
static SPDF_WIN_CHROME_INLINE float spdf_win_chrome_px(double points, float dpi_scale) {
    float s = dpi_scale > 0.0f ? dpi_scale : 1.0f;
    return floorf((float)(points * (double)s) + 0.5f);
}

/* Clamp helpers matching macOS's own, so a restored width lands where macOS
 * would put it (ShenzhenPDFMac.mm:179-187, :1455). */
static SPDF_WIN_CHROME_INLINE float spdf_win_chrome_clamp_sidebar_pt(float want_pt, float split_w_pt,
                                                                     int search_active) {
    float lo = search_active ? (float)SPDF_WIN_CHROME_SIDEBAR_SEARCH_MIN_W : (float)SPDF_WIN_CHROME_SIDEBAR_MIN_W;
    float hi = (float)SPDF_WIN_CHROME_SIDEBAR_MAX_W;
    float frac = (float)(SPDF_WIN_CHROME_SIDEBAR_MAX_FRACTION * (double)split_w_pt);
    if (want_pt <= 0.0f) want_pt = (float)SPDF_WIN_CHROME_SIDEBAR_W;
    if (frac > 0.0f) hi = spdf_win_chrome_min(hi, frac);
    /* A window narrow enough that the fraction falls below the minimum cannot
     * satisfy both. macOS resolves this by letting the minimum win and letting
     * the split view squeeze the canvas; matching that is what keeps a narrow
     * window's sidebar usable rather than a sliver. */
    if (hi < lo) hi = lo;
    return spdf_win_chrome_max(lo, spdf_win_chrome_min(hi, want_pt));
}

static SPDF_WIN_CHROME_INLINE float spdf_win_chrome_clamp_minimap_pt(float want_pt, float container_w_pt) {
    float hi = (float)SPDF_WIN_CHROME_MINIMAP_MAX_W;
    float drag_hi;
    if (want_pt <= 0.0f) want_pt = (float)SPDF_WIN_CHROME_MINIMAP_W;
    drag_hi = (float)spdf_win_chrome_max(120.0f,
                                        spdf_win_chrome_min(320.0f, (float)(SPDF_WIN_CHROME_MINIMAP_DRAG_MAX_FRACTION *
                                                                            (double)container_w_pt)));
    hi = spdf_win_chrome_min(hi, drag_hi);
    if (hi < (float)SPDF_WIN_CHROME_MINIMAP_MIN_W) hi = (float)SPDF_WIN_CHROME_MINIMAP_MIN_W;
    return spdf_win_chrome_max((float)SPDF_WIN_CHROME_MINIMAP_MIN_W, spdf_win_chrome_min(hi, want_pt));
}

/* THE ONE ENTRY POINT.
 *
 * Divides a client area of client_px_w x client_px_h device pixels. Order of
 * operations mirrors the macOS view tree: the two full-width bands come off the
 * top, then what is left is the split view, and the side panels come off its
 * edges. The canvas gets the remainder -- never a negative remainder, which is
 * why every step clamps rather than subtracting blindly.
 *
 * A panel whose divider would not fit is dropped WITH its divider, so a window
 * can never show a divider with nothing beyond it. */
static SPDF_WIN_CHROME_INLINE void spdf_win_chrome_layout(const SpdfWinChromeModel* model, unsigned client_px_w,
                                                          unsigned client_px_h, float dpi_scale,
                                                          SpdfWinChromeLayout* out) {
    float w = (float)client_px_w;
    float h = (float)client_px_h;
    float s = dpi_scale > 0.0f ? dpi_scale : 1.0f;
    float y = 0.0f;
    float split_top, split_h, split_w_pt;
    float div_px = spdf_win_chrome_px(SPDF_WIN_CHROME_DIVIDER_W, s);
    float left = 0.0f, right = w;

    if (!out) return;
    out->tabstrip = spdf_win_chrome_zero();
    out->caption = spdf_win_chrome_zero();
    out->toolbar = spdf_win_chrome_zero();
    out->sidebar = spdf_win_chrome_zero();
    out->sidebar_divider = spdf_win_chrome_zero();
    out->canvas = spdf_win_chrome_zero();
    out->vscroll = spdf_win_chrome_zero();
    out->hscroll = spdf_win_chrome_zero();
    out->minimap_divider = spdf_win_chrome_zero();
    out->minimap = spdf_win_chrome_zero();
    out->dpi_scale = s;
    if (!model || w <= 0.0f || h <= 0.0f) return;

    /* --- the two bands ---------------------------------------------------
     * Presentation mode collapses both to zero rather than hiding them, which
     * is what :13634 does, so the canvas gets the whole window. */
    if (!model->presentation) {
        float strip_h = spdf_win_chrome_px(SPDF_WIN_CHROME_TABSTRIP_H, s);
        float bar_h = spdf_win_chrome_px(SPDF_WIN_CHROME_TOOLBAR_H, s);
        /* Do not let chrome eat a window so small that nothing is left to
         * read. Below this the bands are dropped in the order that keeps the
         * document usable: the toolbar first, then the strip. */
        if (strip_h + bar_h < h * 0.75f) {
            out->tabstrip.x = 0.0f;
            out->tabstrip.y = 0.0f;
            out->tabstrip.w = w;
            out->tabstrip.h = strip_h;
            y += strip_h;

            out->toolbar.x = 0.0f;
            out->toolbar.y = y;
            out->toolbar.w = w;
            out->toolbar.h = bar_h;
            y += bar_h;
        } else if (strip_h < h * 0.5f) {
            out->tabstrip.x = 0.0f;
            out->tabstrip.y = 0.0f;
            out->tabstrip.w = w;
            out->tabstrip.h = strip_h;
            y += strip_h;
        }
        /* The caption reserve rides on the strip: same whole-pixel conversion
         * the strip painter applies to the buttons, so the coarse rect and the
         * drawn buttons share an edge. A strip narrower than the reserve has no
         * buttons at all rather than buttons hanging off its left edge. */
        if (!spdf_win_chrome_rect_empty(out->tabstrip)) {
            float cap_w = spdf_win_chrome_px(SPDF_WIN_TABSTRIP_TRAILING_INSET, s);
            if (cap_w <= w) {
                out->caption.x = w - cap_w;
                out->caption.y = 0.0f;
                out->caption.w = cap_w;
                out->caption.h = out->tabstrip.h;
            }
        }
    }

    split_top = y;
    split_h = spdf_win_chrome_max(0.0f, h - y);
    if (split_h <= 0.0f) return;
    split_w_pt = w / s;

    /* --- sidebar, from the leading edge --------------------------------- */
    if (model->show_sidebar) {
        float want = spdf_win_chrome_clamp_sidebar_pt(model->sidebar_w, split_w_pt, model->search_active);
        float px = spdf_win_chrome_px(want, s);
        /* Leave at least the divider plus a token canvas, else drop the panel
         * and its divider together. */
        if (px + div_px < w * 0.9f) {
            out->sidebar.x = left;
            out->sidebar.y = split_top;
            out->sidebar.w = px;
            out->sidebar.h = split_h;
            left += px;

            out->sidebar_divider.x = left;
            out->sidebar_divider.y = split_top;
            out->sidebar_divider.w = div_px;
            out->sidebar_divider.h = split_h;
            left += div_px;
        }
    }

    /* --- minimap, from the trailing edge -------------------------------- */
    if (model->show_minimap) {
        float want = spdf_win_chrome_clamp_minimap_pt(model->minimap_w, split_w_pt);
        float px = spdf_win_chrome_px(want, s);
        if (left + div_px + px < right - div_px) {
            out->minimap.x = right - px;
            out->minimap.y = split_top;
            out->minimap.w = px;
            out->minimap.h = split_h;
            right -= px;

            out->minimap_divider.x = right - div_px;
            out->minimap_divider.y = split_top;
            out->minimap_divider.w = div_px;
            out->minimap_divider.h = split_h;
            right -= div_px;
        }
    }

    /* --- canvas gets what is left, less its scrollers ------------------- */
    out->canvas.x = left;
    out->canvas.y = split_top;
    out->canvas.w = spdf_win_chrome_max(0.0f, right - left);
    out->canvas.h = split_h;

    /* Presentation mode has no scrollers at all -- it has no chrome. */
    if (model->presentation) return;

    {
        float bar = spdf_win_chrome_px(SPDF_WIN_CHROME_SCROLLBAR_W, s);
        /* Reserve nothing on a canvas too small to lose it: below this the
         * scroller would take more of the page than it is worth, and a viewport
         * of zero width is a division waiting to happen downstream. */
        int room_v = out->canvas.w > bar * 3.0f;
        int room_h = out->canvas.h > bar * 3.0f;
        int want_h = model->h_scrollable && room_h;

        if (room_v) {
            out->vscroll.x = out->canvas.x + out->canvas.w - bar;
            out->vscroll.y = out->canvas.y;
            out->vscroll.w = bar;
            /* The vertical trough stops where the horizontal one begins, so the
             * two never overlap in the corner. */
            out->vscroll.h = out->canvas.h - (want_h ? bar : 0.0f);
            out->canvas.w -= bar;
        }
        if (want_h) {
            out->hscroll.x = out->canvas.x;
            out->hscroll.y = out->canvas.y + out->canvas.h - bar;
            out->hscroll.w = out->canvas.w;
            out->hscroll.h = bar;
            out->canvas.h -= bar;
        }
    }
}

/* Dividers are tested FIRST and with a widened grab area: a 5 pt divider is a
 * hard target with a mouse, and macOS gets the same forgiveness from its
 * NSSplitView. The widening overlaps the neighbouring panels, so testing the
 * panels first would make the divider unusable. */
#define SPDF_WIN_CHROME_DIVIDER_GRAB_SLOP 2.0

static SPDF_WIN_CHROME_INLINE SpdfWinChromeRect spdf_win_chrome_grab_rect(SpdfWinChromeRect divider, float dpi_scale) {
    float slop;
    if (spdf_win_chrome_rect_empty(divider)) return spdf_win_chrome_zero();
    slop = spdf_win_chrome_px(SPDF_WIN_CHROME_DIVIDER_GRAB_SLOP, dpi_scale);
    divider.x -= slop;
    divider.w += 2.0f * slop;
    return divider;
}

static SPDF_WIN_CHROME_INLINE spdf_win_chrome_part spdf_win_chrome_hit(const SpdfWinChromeLayout* l, float x,
                                                                      float y) {
    if (!l) return SPDF_WIN_CHROME_NONE;
    if (spdf_win_chrome_contains(spdf_win_chrome_grab_rect(l->sidebar_divider, l->dpi_scale), x, y))
        return SPDF_WIN_CHROME_SIDEBAR_DIVIDER;
    if (spdf_win_chrome_contains(spdf_win_chrome_grab_rect(l->minimap_divider, l->dpi_scale), x, y))
        return SPDF_WIN_CHROME_MINIMAP_DIVIDER;
    /* The caption reserve before the strip that contains it. */
    if (spdf_win_chrome_contains(l->caption, x, y)) return SPDF_WIN_CHROME_CAPTION;
    if (spdf_win_chrome_contains(l->tabstrip, x, y)) return SPDF_WIN_CHROME_TABSTRIP;
    if (spdf_win_chrome_contains(l->toolbar, x, y)) return SPDF_WIN_CHROME_TOOLBAR;
    if (spdf_win_chrome_contains(l->sidebar, x, y)) return SPDF_WIN_CHROME_SIDEBAR;
    if (spdf_win_chrome_contains(l->minimap, x, y)) return SPDF_WIN_CHROME_MINIMAP;
    /* Before the canvas: both scrollers lie inside the canvas REGION, and the
     * canvas rect has already been shrunk away from them, so order only matters
     * if a future change stops shrinking it. Cheap insurance. */
    if (spdf_win_chrome_contains(l->vscroll, x, y)) return SPDF_WIN_CHROME_VSCROLL;
    if (spdf_win_chrome_contains(l->hscroll, x, y)) return SPDF_WIN_CHROME_HSCROLL;
    if (spdf_win_chrome_contains(l->canvas, x, y)) return SPDF_WIN_CHROME_CANVAS;
    return SPDF_WIN_CHROME_NONE;
}

/* New width in POINTS for a divider drag, clamped the way macOS clamps it.
 * The sidebar's trailing edge follows the pointer; the minimap's leading edge
 * moves the opposite way, hence the subtraction. */
static SPDF_WIN_CHROME_INLINE float spdf_win_chrome_sidebar_drag_pt(const SpdfWinChromeLayout* l, float pointer_x,
                                                                    int search_active) {
    float s, want_pt, split_w_pt;
    if (!l) return 0.0f;
    s = l->dpi_scale > 0.0f ? l->dpi_scale : 1.0f;
    want_pt = (pointer_x - l->sidebar.x) / s;
    split_w_pt = (l->sidebar.w + l->sidebar_divider.w + l->canvas.w + l->minimap_divider.w + l->minimap.w) / s;
    return spdf_win_chrome_clamp_sidebar_pt(want_pt, split_w_pt, search_active);
}

static SPDF_WIN_CHROME_INLINE float spdf_win_chrome_minimap_drag_pt(const SpdfWinChromeLayout* l, float pointer_x) {
    float s, want_pt, split_w_pt;
    if (!l) return 0.0f;
    s = l->dpi_scale > 0.0f ? l->dpi_scale : 1.0f;
    want_pt = ((l->minimap.x + l->minimap.w) - pointer_x) / s;
    split_w_pt = (l->sidebar.w + l->sidebar_divider.w + l->canvas.w + l->minimap_divider.w + l->minimap.w) / s;
    return spdf_win_chrome_clamp_minimap_pt(want_pt, split_w_pt);
}

#endif /* SPDF_WIN_CHROME_H */
