/* spdf_win_tabstrip.h — tab-strip geometry for the Win32 frontend.
 *
 * WHAT THIS IS: the pure geometry and hit-testing arithmetic of the macOS tab
 * strip, ported the way spdf_win_layout.h ported the GTK4 layout layer — types
 * only, no toolkit, no state, header-only, compiled by MSVC as C and as C++.
 * Every function has a counterpart in portable/mac/SPDFMacTabStripView.mm and
 * portable/mac/SPDFMacTabStripGeometry.h and is required to agree with it:
 *
 *   spdf_win_tabstrip_tab_width        <- -[SPDFMacTabStripView tabWidth]
 *   spdf_win_tabstrip_capacity         <- -visibleTabCapacityWithOverflow:
 *   spdf_win_tabstrip_has_overflow     <- -hasOverflowTabs
 *   spdf_win_tabstrip_visible_range    <- -visibleTabIndexes
 *   spdf_win_tabstrip_tab_rect         <- -rectForTabAtIndex:
 *   spdf_win_tabstrip_plus_rect        <- -plusRect
 *   spdf_win_tabstrip_overflow_rect    <- -overflowRectAssumingVisible
 *   spdf_win_tabstrip_close_rect       <- -closeCircleRectForTabRect:
 *   spdf_win_tabstrip_readonly_dot     <- -readOnlyDotRectForTabRect:...
 *   spdf_win_tabstrip_hit              <- -tabIndexAtPoint:
 *   spdf_win_tabstrip_drop_slot        <- spdf_tab_strip_drop_slot_for_x
 *   spdf_win_tabstrip_move_index       <- spdf_tab_strip_same_window_move_index
 *
 * WHY GEOMETRY LIVES IN A HEADER OF ITS OWN. portable/docs/windows-port-plan.md
 * §2.3's reuse rule: "Win32 must supply painting and hit-testing, not
 * re-derived behaviour. Re-deriving it would mean re-deriving its bug fixes
 * too." Overflow windowing around the selected tab, the forgiving click
 * target, and the collapse of the two gaps adjacent to a dragged tab are all
 * behaviour that took iterations to get right on macOS. They are transcribed
 * here, not reinvented, and being toolkit-free they can be differentially
 * tested against the originals the way layout_geometry_test.c is.
 *
 * WHERE THE STRIP LIVES: INSIDE THE TITLE BAR, ON BOTH PLATFORMS.
 * On macOS SPDFWindow sets titlebarAppearsTransparent, titleVisibility Hidden
 * and NSWindowStyleMaskFullSizeContentView, which is why the strip's background
 * is clearColor and why it reserves a LEADING inset for the traffic lights
 * (MAX(16.0, NSMaxX(zoomButton) + 18.0), falling back to 138.0 windowed and
 * 16.0 fullscreen).
 *
 * Here the client area is extended over the caption (spdf_win_window.cpp owns
 * WM_NCCALCSIZE and WM_NCHITTEST for that), so the strip IS the title bar, and
 * the mirror of macOS applies: Windows' caption buttons sit at the RIGHT, so the
 * reserve is a TRAILING inset. Three Windows 11 caption buttons at 46 px each
 * are 138 px at 96 dpi -- the same number macOS falls back to for its traffic
 * lights, which is a coincidence worth keeping rather than rounding.
 *
 * The consequences for the two insets:
 *   - LEADING is macOS's own no-traffic-lights value, 16.0 -- the number it uses
 *     in fullscreen, for exactly this situation.
 *   - TRAILING is the caption-button reserve, 138.0, and the `+` and overflow
 *     buttons sit to its left. spdf_win_tabstrip_caption_rect() below is the
 *     geometry of the three buttons themselves, in the same strip-local points
 *     as everything else here, so the painter and WM_NCHITTEST agree about
 *     where the close button is for the same reason they agree about a tab.
 *
 * Everything else -- overflow windowing, the forgiving hit target, the drag
 * slots -- is macOS's arithmetic unchanged; the reserve only moves the right
 * edge the `+` is pinned against.
 *
 * UNITS. Everything here is in logical points, matching the macOS constants
 * one for one. The caller multiplies by the window's DPI scale when it paints,
 * and hit-tests in the same space by dividing the mouse position. This differs
 * from SPDF_WIN_PAGE_MARGIN_H/V in spdf_win_layout.h, which are content-space
 * and deliberately NOT DPI-scaled — page margins live in document coordinates,
 * chrome is screen furniture. Keeping the two in different spaces is
 * intentional; do not "unify" them.
 *
 * NO ALLOCATION, NO STATE. The visible window is returned as a (start, count)
 * pair rather than an array, so nothing here allocates and a caller can drive
 * painting and hit-testing from the same two integers. macOS returns an
 * NSArray of indexes; the range form carries the same information because the
 * visible set is always contiguous (-visibleTabIndexes builds `start + i`).
 */
#ifndef SPDF_WIN_TABSTRIP_H
#define SPDF_WIN_TABSTRIP_H

#include <math.h>

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_TS_INLINE __inline
#else
#define SPDF_WIN_TS_INLINE inline
#endif

/* ---------------------------------------------------------------- metrics
 * All from portable/mac/ShenzhenPDFMac.mm and SPDFMacTabStripView.mm, cited
 * per line so a future divergence is traceable to a decision rather than to
 * drift. */

/* ShenzhenPDFMac.mm:68 (kTabStripHeight). Collapses to 0 in presentation
 * mode there (:13634); the caller owns that, not this header. */
#define SPDF_WIN_TABSTRIP_HEIGHT 42.0

/* SPDFMacTabStripView.mm:9-12 */
#define SPDF_WIN_TABSTRIP_TAB_GAP 6.0
#define SPDF_WIN_TABSTRIP_TAB_MIN_VISIBLE_WIDTH 112.0
#define SPDF_WIN_TABSTRIP_TAB_MAX_WIDTH 320.0
#define SPDF_WIN_TABSTRIP_CONTROL_WIDTH 32.0

/* SPDFMacTabStripView.mm:13-18. The dot's hit area and its drawn rect are
 * derived from the same constants on macOS so hover stays aligned with the
 * pixels; same discipline here. */
#define SPDF_WIN_TABSTRIP_READONLY_DOT_DIAMETER 7.0
#define SPDF_WIN_TABSTRIP_READONLY_DOT_LEFT_INSET 6.0
#define SPDF_WIN_TABSTRIP_READONLY_DOT_TITLE_GAP 2.5

/* Tab body: y = 7, height 28 within the 42pt strip
 * (SPDFMacTabStripView.mm:124-129, :213-222). The corner radius is
 * kSPDFTabCornerRadius (SPDFMacTabStripStyle.mm:6): 10 pt since 26.9.2-1's
 * "Give every tab a visible outline" -- at 7 pt the corners read as a chamfer
 * once the outline is actually visible. */
#define SPDF_WIN_TABSTRIP_TAB_Y 7.0
#define SPDF_WIN_TABSTRIP_TAB_HEIGHT 28.0
#define SPDF_WIN_TABSTRIP_TAB_RADIUS 10.0

/* The tab chip's style -- fill, outline, widths -- lives in spdf_win_tabs_style.h,
 * split out for the file-size ratchet; included here so every consumer of the
 * strip's geometry keeps seeing it. */
#include "spdf_win_tabs_style.h"

/* The `+` and overflow `…` buttons: 32 x 28 at y = 7, radius 9
 * (SPDFMacTabStripView.mm:135-149, :651-681). */
#define SPDF_WIN_TABSTRIP_CONTROL_RADIUS 9.0

/* Title insets (SPDFMacTabStripView.mm:565-604). The right inset leaves room
 * for the close button; the left one grows when a read-only dot is shown. */
#define SPDF_WIN_TABSTRIP_TITLE_LEFT_INSET 12.0
#define SPDF_WIN_TABSTRIP_TITLE_RIGHT_INSET 34.0
#define SPDF_WIN_TABSTRIP_TITLE_FONT_SIZE 12.0

/* Close button: a 16pt circle whose right edge sits 26pt in from the tab's
 * trailing edge; the X arms are +-3.2pt at lineWidth 1.35
 * (SPDFMacTabStripView.mm:397-400, :600-616). */
#define SPDF_WIN_TABSTRIP_CLOSE_DIAMETER 16.0
#define SPDF_WIN_TABSTRIP_CLOSE_RIGHT_EDGE_INSET 26.0
#define SPDF_WIN_TABSTRIP_CLOSE_X_ARM 3.2
#define SPDF_WIN_TABSTRIP_CLOSE_X_LINE_WIDTH 1.35

/* Leading inset. macOS: MAX(16.0, reservedLeadingInset) to clear the traffic
 * lights. Windows has none, so 16.0 -- macOS's own value when there are no
 * traffic lights in the way. See the header comment. */
#define SPDF_WIN_TABSTRIP_LEADING_INSET 16.0

/* Trailing inset: the caption-button reserve. Three buttons, each 46 pt wide
 * and the full strip height, which is how Windows 11 sizes them (46 x the
 * caption's height; ours is 42). 3 * 46 = 138, macOS's windowed fallback for
 * the traffic-light reserve, mirrored to the trailing end. */
#define SPDF_WIN_TABSTRIP_CAPTION_BUTTON_W 46.0
#define SPDF_WIN_TABSTRIP_CAPTION_BUTTONS 3
#define SPDF_WIN_TABSTRIP_TRAILING_INSET (SPDF_WIN_TABSTRIP_CAPTION_BUTTON_W * SPDF_WIN_TABSTRIP_CAPTION_BUTTONS)

/* The three caption buttons, in left-to-right order, plus NONE. Numbered so
 * that (4 - button) is how many button widths the button's LEFT edge is from
 * the strip's trailing edge -- see spdf_win_tabstrip_caption_rect. The same
 * values are SpdfWinChromeModel::caption_hot / caption_pressed. */
typedef enum spdf_win_caption_button {
    SPDF_WIN_CAPTION_NONE = 0,
    SPDF_WIN_CAPTION_MINIMIZE = 1,
    SPDF_WIN_CAPTION_MAXIMIZE = 2, /* draws Restore when the window is maximized */
    SPDF_WIN_CAPTION_CLOSE = 3
} spdf_win_caption_button;

/* Drop indicator for a reattach drag: 2pt wide, full tab height, corner radius
 * 1.0, systemYellow (SPDFMacTabStripView.mm:684-699). */
#define SPDF_WIN_TABSTRIP_DROP_INDICATOR_WIDTH 2.0
#define SPDF_WIN_TABSTRIP_DROP_INDICATOR_RADIUS 1.0

/* Forgiving hit target: NSInsetRect(tabRect, -6.0, -10.0) expanded to the full
 * strip height (SPDFMacTabStripView.mm:224-230). */
#define SPDF_WIN_TABSTRIP_HIT_SLOP_X 6.0

typedef struct SpdfWinTabRect {
    double x, y, w, h;
} SpdfWinTabRect;

/* An empty rect means "nothing here" -- the same signal NSZeroRect carries on
 * macOS, and every consumer below treats w <= 0 as absent. */
static SPDF_WIN_TS_INLINE SpdfWinTabRect spdf_win_tabstrip_zero_rect(void) {
    SpdfWinTabRect r;
    r.x = r.y = r.w = r.h = 0.0;
    return r;
}

static SPDF_WIN_TS_INLINE int spdf_win_tabstrip_rect_is_empty(SpdfWinTabRect r) {
    return !(r.w > 0.0 && r.h > 0.0);
}

/* glib's MAX/MIN as functions rather than macros, for the reason
 * spdf_win_layout.h gives: a MAX(a, b++) double evaluation can never be
 * introduced later. */
static SPDF_WIN_TS_INLINE double spdf_win_ts_max(double a, double b) { return a > b ? a : b; }
static SPDF_WIN_TS_INLINE double spdf_win_ts_min(double a, double b) { return a < b ? a : b; }
static SPDF_WIN_TS_INLINE int spdf_win_ts_imax(int a, int b) { return a > b ? a : b; }
static SPDF_WIN_TS_INLINE int spdf_win_ts_imin(int a, int b) { return a < b ? a : b; }

/* --------------------------------------------------------------- controls
 * -plusRect (SPDFMacTabStripView.mm:132-136). The double clamp looks odd and
 * is transcribed as-is: MAX pins the button clear of the leading inset, MIN
 * then keeps it 40-42pt from the trailing edge. Reproducing the shape rather
 * than a simplification of it keeps this diffable against the original. */
/* The one edit to the transcription: `strip_w` is replaced by the edge of the
 * caption-button reserve, so the `+` is pinned 40-42 pt left of the buttons
 * rather than of the window. Everything downstream (the overflow button, the
 * tab area, capacity) derives from this rect and moves with it. */
static SPDF_WIN_TS_INLINE double spdf_win_tabstrip_controls_right(double strip_w) {
    return strip_w - SPDF_WIN_TABSTRIP_TRAILING_INSET;
}

static SPDF_WIN_TS_INLINE SpdfWinTabRect spdf_win_tabstrip_plus_rect(double strip_w) {
    double floor_x = SPDF_WIN_TABSTRIP_LEADING_INSET + SPDF_WIN_TABSTRIP_CONTROL_WIDTH + 16.0;
    double right = spdf_win_tabstrip_controls_right(strip_w);
    double x = spdf_win_ts_max(floor_x, right - 42.0);
    SpdfWinTabRect r;
    x = spdf_win_ts_min(x, spdf_win_ts_max(floor_x, right - 40.0));
    r.x = x;
    r.y = SPDF_WIN_TABSTRIP_TAB_Y;
    r.w = SPDF_WIN_TABSTRIP_CONTROL_WIDTH;
    r.h = SPDF_WIN_TABSTRIP_TAB_HEIGHT;
    return r;
}

/* -overflowRectAssumingVisible (:138-142). "Assuming visible": the caller asks
 * for this only when there IS overflow; spdf_win_tabstrip_overflow_rect below
 * is the guarded form. */
static SPDF_WIN_TS_INLINE SpdfWinTabRect spdf_win_tabstrip_overflow_rect_assuming_visible(double strip_w) {
    SpdfWinTabRect plus = spdf_win_tabstrip_plus_rect(strip_w);
    SpdfWinTabRect r;
    double x = plus.x - SPDF_WIN_TABSTRIP_CONTROL_WIDTH - SPDF_WIN_TABSTRIP_TAB_GAP;
    r.x = spdf_win_ts_max(SPDF_WIN_TABSTRIP_LEADING_INSET, x);
    r.y = SPDF_WIN_TABSTRIP_TAB_Y;
    r.w = SPDF_WIN_TABSTRIP_CONTROL_WIDTH;
    r.h = SPDF_WIN_TABSTRIP_TAB_HEIGHT;
    return r;
}

/* -tabAreaRightWithOverflow: (:144-146). Note the two different paddings, 8.0
 * with an overflow button and 10.0 without; they are macOS's numbers. */
static SPDF_WIN_TS_INLINE double spdf_win_tabstrip_area_right(double strip_w, int overflow) {
    if (overflow) return spdf_win_tabstrip_overflow_rect_assuming_visible(strip_w).x - 8.0;
    return spdf_win_tabstrip_plus_rect(strip_w).x - 10.0;
}

/* -tabAreaWidthWithOverflow: (:148-150) */
static SPDF_WIN_TS_INLINE double spdf_win_tabstrip_area_width(double strip_w, int overflow) {
    return spdf_win_ts_max(0.0, spdf_win_tabstrip_area_right(strip_w, overflow) - SPDF_WIN_TABSTRIP_LEADING_INSET);
}

/* -visibleTabCapacityWithOverflow: (:162-170). The `+ kTabGap` on both sides of
 * the divide is what makes the last tab in a row not need a trailing gap. */
static SPDF_WIN_TS_INLINE int spdf_win_tabstrip_capacity(double strip_w, int tab_count, int overflow) {
    double area_w;
    int capacity;
    if (tab_count <= 0) return 0;
    area_w = spdf_win_tabstrip_area_width(strip_w, overflow);
    if (area_w <= 0.0) return 1;
    capacity = (int)floor((area_w + SPDF_WIN_TABSTRIP_TAB_GAP) /
                          (SPDF_WIN_TABSTRIP_TAB_MIN_VISIBLE_WIDTH + SPDF_WIN_TABSTRIP_TAB_GAP));
    return spdf_win_ts_imax(1, spdf_win_ts_imin(tab_count, capacity));
}

/* -hasOverflowTabs (:172-176). Asked WITHOUT the overflow button present: the
 * button only appears because the tabs did not fit without it, so testing with
 * it already reserved would be circular. */
static SPDF_WIN_TS_INLINE int spdf_win_tabstrip_has_overflow(double strip_w, int tab_count) {
    if (tab_count <= 1) return 0;
    return spdf_win_tabstrip_capacity(strip_w, tab_count, 0) < tab_count;
}

static SPDF_WIN_TS_INLINE SpdfWinTabRect spdf_win_tabstrip_overflow_rect(double strip_w, int tab_count) {
    if (!spdf_win_tabstrip_has_overflow(strip_w, tab_count)) return spdf_win_tabstrip_zero_rect();
    return spdf_win_tabstrip_overflow_rect_assuming_visible(strip_w);
}

/* -selectedIndexForLayout (:154-160): a negative selection lays out as 0. */
static SPDF_WIN_TS_INLINE int spdf_win_tabstrip_selected_for_layout(int selected, int tab_count) {
    if (tab_count <= 0) return -1;
    if (selected < 0) return 0;
    return spdf_win_ts_imin(selected, tab_count - 1);
}

/* -visibleTabIndexes (:178-193) as a contiguous range.
 *
 * The window is centred on the selected tab -- start = selected -
 * (visibleCount - 1) / 2 -- then clamped into [0, count - visibleCount]. The
 * integer division is deliberate and asymmetric: with an even visibleCount the
 * selected tab sits just right of centre. That is macOS's behaviour and
 * changing it would silently move every tab by one slot. */
static SPDF_WIN_TS_INLINE void spdf_win_tabstrip_visible_range(double strip_w, int tab_count, int selected,
                                                              int* out_start, int* out_count) {
    int overflow, visible, start, sel;
    if (out_start) *out_start = 0;
    if (out_count) *out_count = 0;
    if (tab_count <= 0) return;

    overflow = spdf_win_tabstrip_has_overflow(strip_w, tab_count);
    visible = overflow ? spdf_win_tabstrip_capacity(strip_w, tab_count, 1) : tab_count;
    visible = spdf_win_ts_imax(1, spdf_win_ts_imin(tab_count, visible));

    sel = spdf_win_tabstrip_selected_for_layout(selected, tab_count);
    start = overflow ? sel - (visible - 1) / 2 : 0;
    start = spdf_win_ts_imax(0, spdf_win_ts_imin(start, tab_count - visible));

    if (out_start) *out_start = start;
    if (out_count) *out_count = visible;
}

/* -tabWidth (:125-131). Uses the VISIBLE count, so widening a window that is
 * already showing every tab widens the tabs, while one in overflow keeps them
 * at a constant width and shows more of them. */
static SPDF_WIN_TS_INLINE double spdf_win_tabstrip_tab_width(double strip_w, int tab_count, int selected) {
    int start = 0, visible = 0, count;
    double available;
    spdf_win_tabstrip_visible_range(strip_w, tab_count, selected, &start, &visible);
    count = spdf_win_ts_imax(1, visible);
    available = spdf_win_tabstrip_area_width(strip_w, spdf_win_tabstrip_has_overflow(strip_w, tab_count)) -
                (double)(count - 1) * SPDF_WIN_TABSTRIP_TAB_GAP;
    if (available <= 0.0) return SPDF_WIN_TABSTRIP_TAB_MIN_VISIBLE_WIDTH;
    return spdf_win_ts_max(1.0, spdf_win_ts_min(SPDF_WIN_TABSTRIP_TAB_MAX_WIDTH, floor(available / (double)count)));
}

/* -rectForTabAtIndex: (:213-222). An index outside the visible window returns
 * an empty rect; the final MIN truncates the last tab against the tab area's
 * right edge rather than letting it run under the +/overflow buttons. */
static SPDF_WIN_TS_INLINE SpdfWinTabRect spdf_win_tabstrip_tab_rect(double strip_w, int tab_count, int selected,
                                                                   int index) {
    int start = 0, visible = 0, position;
    double tab_w, x, max_right, w;
    SpdfWinTabRect r;

    spdf_win_tabstrip_visible_range(strip_w, tab_count, selected, &start, &visible);
    if (index < start || index >= start + visible) return spdf_win_tabstrip_zero_rect();
    position = index - start;

    tab_w = spdf_win_tabstrip_tab_width(strip_w, tab_count, selected);
    x = SPDF_WIN_TABSTRIP_LEADING_INSET + (double)position * (tab_w + SPDF_WIN_TABSTRIP_TAB_GAP);
    max_right = spdf_win_tabstrip_area_right(strip_w, spdf_win_tabstrip_has_overflow(strip_w, tab_count));
    w = spdf_win_ts_min(tab_w, max_right - x);

    r.x = x;
    r.y = SPDF_WIN_TABSTRIP_TAB_Y;
    r.w = w;
    r.h = SPDF_WIN_TABSTRIP_TAB_HEIGHT;
    if (r.w <= 0.0) return spdf_win_tabstrip_zero_rect();
    return r;
}

/* -closeCircleRectForTabRect: (:397-400) */
static SPDF_WIN_TS_INLINE SpdfWinTabRect spdf_win_tabstrip_close_rect(SpdfWinTabRect tab) {
    SpdfWinTabRect r;
    if (spdf_win_tabstrip_rect_is_empty(tab)) return spdf_win_tabstrip_zero_rect();
    r.w = SPDF_WIN_TABSTRIP_CLOSE_DIAMETER;
    r.h = SPDF_WIN_TABSTRIP_CLOSE_DIAMETER;
    r.x = tab.x + tab.w - SPDF_WIN_TABSTRIP_CLOSE_RIGHT_EDGE_INSET;
    r.y = tab.y + (tab.h - SPDF_WIN_TABSTRIP_CLOSE_DIAMETER) / 2.0;
    return r;
}

/* -readOnlyDotRectForTabRect:diameter:leftInset: (:580-593) */
static SPDF_WIN_TS_INLINE SpdfWinTabRect spdf_win_tabstrip_readonly_dot_rect(SpdfWinTabRect tab) {
    SpdfWinTabRect r;
    if (spdf_win_tabstrip_rect_is_empty(tab)) return spdf_win_tabstrip_zero_rect();
    r.w = SPDF_WIN_TABSTRIP_READONLY_DOT_DIAMETER;
    r.h = SPDF_WIN_TABSTRIP_READONLY_DOT_DIAMETER;
    r.x = tab.x + SPDF_WIN_TABSTRIP_READONLY_DOT_LEFT_INSET;
    r.y = tab.y + (tab.h - SPDF_WIN_TABSTRIP_READONLY_DOT_DIAMETER) / 2.0;
    return r;
}

/* The title's left inset grows to clear the read-only dot, so the middle-
 * truncated title starts just right of it (:593-599). macOS computes
 * 6.0 + 7.0 + 2.5 = 15.5 in that case. */
static SPDF_WIN_TS_INLINE double spdf_win_tabstrip_title_left_inset(int show_readonly_dot) {
    if (!show_readonly_dot) return SPDF_WIN_TABSTRIP_TITLE_LEFT_INSET;
    return SPDF_WIN_TABSTRIP_READONLY_DOT_LEFT_INSET + SPDF_WIN_TABSTRIP_READONLY_DOT_DIAMETER +
           SPDF_WIN_TABSTRIP_READONLY_DOT_TITLE_GAP;
}

/* -interactionRectForTabRect: (:224-230): 6pt of horizontal slop, and
 * vertically the FULL strip height rather than the tab's 28pt, so a click just
 * above or below a tab still selects it. */
static SPDF_WIN_TS_INLINE SpdfWinTabRect spdf_win_tabstrip_interaction_rect(SpdfWinTabRect tab, double strip_h) {
    SpdfWinTabRect r;
    if (spdf_win_tabstrip_rect_is_empty(tab)) return spdf_win_tabstrip_zero_rect();
    r.x = tab.x - SPDF_WIN_TABSTRIP_HIT_SLOP_X;
    r.w = tab.w + 2.0 * SPDF_WIN_TABSTRIP_HIT_SLOP_X;
    r.y = 0.0;
    r.h = strip_h;
    return r;
}

static SPDF_WIN_TS_INLINE int spdf_win_tabstrip_rect_contains(SpdfWinTabRect r, double x, double y) {
    if (spdf_win_tabstrip_rect_is_empty(r)) return 0;
    return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h;
}

/* -tabIndexAtPoint: (:232-236). First match wins, scanning low index upward,
 * which matters because the 6pt slop makes adjacent interaction rects overlap
 * across the 6pt gap. */
static SPDF_WIN_TS_INLINE int spdf_win_tabstrip_hit(double strip_w, double strip_h, int tab_count, int selected,
                                                   double x, double y) {
    int i;
    for (i = 0; i < tab_count; ++i) {
        SpdfWinTabRect tab = spdf_win_tabstrip_tab_rect(strip_w, tab_count, selected, i);
        if (spdf_win_tabstrip_rect_is_empty(tab)) continue;
        if (spdf_win_tabstrip_rect_contains(spdf_win_tabstrip_interaction_rect(tab, strip_h), x, y)) return i;
    }
    return -1;
}

/* Whether a point is on a visible tab's close button. Checked BEFORE the tab
 * hit by the caller: the close circle lies inside the tab, so testing the tab
 * first would swallow every close click. */
static SPDF_WIN_TS_INLINE int spdf_win_tabstrip_close_hit(double strip_w, int tab_count, int selected, double x,
                                                          double y) {
    int i;
    for (i = 0; i < tab_count; ++i) {
        SpdfWinTabRect tab = spdf_win_tabstrip_tab_rect(strip_w, tab_count, selected, i);
        if (spdf_win_tabstrip_rect_is_empty(tab)) continue;
        /* Below the drawn width macOS does not draw the close box at all
         * (drawTabAtIndex: bails under 40pt), so it must not be clickable. */
        if (tab.w < 40.0) continue;
        if (spdf_win_tabstrip_rect_contains(spdf_win_tabstrip_close_rect(tab), x, y)) return i;
    }
    return -1;
}

/* --------------------------------------------------------- caption buttons
 * Windows-only geometry with no macOS counterpart: the traffic lights are
 * AppKit's, but Windows' caption buttons are ours once the client area covers
 * the caption. Strip-local points like everything else here, full strip
 * height, packed against the trailing edge in the order Windows draws them --
 * minimize, maximize/restore, close. An empty rect for NONE or for a strip too
 * narrow to hold the reserve at all. */
static SPDF_WIN_TS_INLINE SpdfWinTabRect spdf_win_tabstrip_caption_rect(double strip_w, double strip_h, int button) {
    SpdfWinTabRect r;
    if (button < SPDF_WIN_CAPTION_MINIMIZE || button > SPDF_WIN_CAPTION_CLOSE) return spdf_win_tabstrip_zero_rect();
    if (strip_w < SPDF_WIN_TABSTRIP_TRAILING_INSET || strip_h <= 0.0) return spdf_win_tabstrip_zero_rect();
    r.x = strip_w - (double)(SPDF_WIN_TABSTRIP_CAPTION_BUTTONS + 1 - button) * SPDF_WIN_TABSTRIP_CAPTION_BUTTON_W;
    r.y = 0.0;
    r.w = SPDF_WIN_TABSTRIP_CAPTION_BUTTON_W;
    r.h = strip_h;
    return r;
}

/* Which caption button a strip-local point is on, or NONE. This is what
 * WM_NCHITTEST turns into HTMINBUTTON / HTMAXBUTTON / HTCLOSE -- and returning
 * HTMAXBUTTON from the real hit test is what makes Windows 11's Snap Layouts
 * flyout appear over our drawn button, so the button must be found HERE, by the
 * same function the painter draws it with, and not faked in client space. */
static SPDF_WIN_TS_INLINE int spdf_win_tabstrip_caption_hit(double strip_w, double strip_h, double x, double y) {
    int b;
    for (b = SPDF_WIN_CAPTION_MINIMIZE; b <= SPDF_WIN_CAPTION_CLOSE; ++b)
        if (spdf_win_tabstrip_rect_contains(spdf_win_tabstrip_caption_rect(strip_w, strip_h, b), x, y)) return b;
    return SPDF_WIN_CAPTION_NONE;
}

/* spdf_tab_strip_drop_slot_for_x (SPDFMacTabStripGeometry.h:16-18): the first
 * visible tab whose horizontal midpoint lies right of x, else visible_count.
 * A "slot" is an insertion position among the visible tabs: 0 is before the
 * first, visible_count is after the last. */
static SPDF_WIN_TS_INLINE int spdf_win_tabstrip_drop_slot(double strip_w, int tab_count, int selected, double x) {
    int start = 0, visible = 0, i;
    spdf_win_tabstrip_visible_range(strip_w, tab_count, selected, &start, &visible);
    if (visible <= 0) return 0;
    for (i = 0; i < visible; ++i) {
        SpdfWinTabRect tab = spdf_win_tabstrip_tab_rect(strip_w, tab_count, selected, start + i);
        if (spdf_win_tabstrip_rect_is_empty(tab)) continue;
        if (tab.x + tab.w / 2.0 > x) return i;
    }
    return visible;
}

/* spdf_tab_strip_same_window_move_index (SPDFMacTabStripGeometry.h:31-34).
 *
 * Converts a drop insertion index -- computed while the dragged tab still
 * occupies source -- into the final index for a remove-then-reinsert. Slots
 * past the source shift left by one once the tab is removed, so BOTH gaps
 * adjacent to the source collapse to a no-op move. Degenerate input returns
 * source, so a bad slot can never move a tab. */
static SPDF_WIN_TS_INLINE int spdf_win_tabstrip_move_index(int insertion, int source, int tab_count) {
    if (tab_count <= 1 || source < 0 || source >= tab_count) return source;
    if (insertion < 0) insertion = 0;
    if (insertion > tab_count) insertion = tab_count;
    if (insertion > source) insertion -= 1;
    if (insertion < 0) insertion = 0;
    if (insertion > tab_count - 1) insertion = tab_count - 1;
    return insertion;
}

#endif /* SPDF_WIN_TABSTRIP_H */
