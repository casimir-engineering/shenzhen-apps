/* spdf_win_page_wheel.h -- Alt + scroll wheel turns PAGES, wherever the pointer
 * is, by how far the wheel turned.
 *
 * WHAT THIS IS THE PORT OF. macOS 26.9.4-1 (SPDFMacPageWheel.mm, commits
 * f5b941930 and 946cbcb58): Option + wheel becomes the page arrows -- the
 * document, the minimap, the sidebar, the toolbar, it does not matter where the
 * pointer is -- and it pages by TRAVEL rather than one page per gesture. The
 * second commit records why: a scroll driver that smooths the wheel delivers a
 * burst of small deltas per notch, which "one page per gesture" read as a single
 * flick, so spinning the wheel fast turned one page and dropped the rest. Each
 * threshold's worth of travel now turns a page and is subtracted from the
 * accumulator, so three notches turn three pages and the remainder carries into
 * the next event instead of being discarded.
 *
 * THE RULES, transcribed (the numbers are the mac's, in Windows units):
 *
 *   - one NOTCH of travel is one page. The mac measures 14 pt of
 *     scrollingDeltaY per smoothed notch and one line per raw notch; Windows
 *     gets the same answer through the notch the window already converts to a
 *     scroll distance (spdf_win_page_wheel_notch_px below), so a precision
 *     touchpad's fractional deltas add up to a page exactly as a mouse notch is
 *     one -- which is the mac's smoothed-wheel case;
 *   - a fast spin keeps up: the count is (travel / notch), capped at
 *     SPDF_WIN_PAGE_WHEEL_MAX_PAGES_PER_EVENT so one enormous delta (a hard
 *     touchpad flick) cannot teleport through the document;
 *   - the remainder is KEPT, and drained with the sign of the pages turned --
 *     getting that backwards grew the accumulator and mis-paged every event
 *     after the first, which the mac's test pins and so does ours;
 *   - a pause of SPDF_WIN_PAGE_WHEEL_IDLE_RESET_S drops any part-page of travel,
 *     so a new spin begins cleanly rather than paging early;
 *   - reversing direction discards the abandoned direction's travel;
 *   - Ctrl already means zoom (spdf_win_window_input.h routes Ctrl + wheel to
 *     SPDF_WIN_INPUT_ZOOM before this is ever asked); Shift may ride along, as
 *     on the mac.
 *
 * WHAT DOES NOT TRANSFER: momentum. The mac ignores a flick's inertial tail
 * because NSEvent labels it; WM_MOUSEWHEEL has no phase, and a Windows
 * precision touchpad delivers its inertia as ordinary wheel messages
 * (spdf_win_search_map_input.h says the same of the minimap). So on Windows a
 * touchpad flick pages for as long as it travels, bounded by the per-event cap
 * -- which is what "paging follows the wheel" means on a wheel that cannot say
 * where a gesture ends.
 *
 * UNITS. `delta` and `units_per_page` are in the SAME unit, whatever the caller
 * has -- device pixels of scroll distance in the app, which is what
 * spdf_win_input carries. Positive delta ADVANCES the document (the viewport
 * moves down), which is the scroll offset's own sign and the opposite of the
 * mac's deltaY; the caller passes in->dy unchanged.
 *
 * Header-only, no Win32, no app state, no allocation -- a pure policy in the
 * spdf_win_chrome_input.h family, pinned by portable/win/tests/page_wheel_test.c.
 * The GTK4 frontend has no equivalent (0 wheel-paging references in
 * portable/linux), so there is no differential; the mac's own test cases are
 * transcribed instead.
 */
#ifndef SPDF_WIN_PAGE_WHEEL_H
#define SPDF_WIN_PAGE_WHEEL_H

#include <math.h>

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_PW_INLINE __inline
#else
#define SPDF_WIN_PW_INLINE inline
#endif

/* The mac's kGestureIdleReset: a pause means the reader stopped and started
 * again, so leftover travel is dropped rather than paging early. */
#define SPDF_WIN_PAGE_WHEEL_IDLE_RESET_S 0.35
/* The mac's kMaxPagesPerEvent. */
#define SPDF_WIN_PAGE_WHEEL_MAX_PAGES_PER_EVENT 4

/* The modifier bits, deliberately the same numbers as spdf_win_window.h's
 * SPDF_WIN_MOD_* (which are spdf_win_menu.h's SPDF_WIN_ACCEL_* bits), so an
 * input's `mods` is handed straight in. Re-declared here rather than included
 * so this header stays free of <windows.h> and testable on its own; the
 * equality is pinned by page_wheel_test.c against the window's header. */
#define SPDF_WIN_PAGE_WHEEL_MOD_CTRL 0x1u
#define SPDF_WIN_PAGE_WHEEL_MOD_SHIFT 0x2u
#define SPDF_WIN_PAGE_WHEEL_MOD_ALT 0x4u

/* One wheel gesture's accumulated state. One window per process, so one
 * instance; zero-initialise it. */
typedef struct SpdfWinPageWheel {
    double accumulator; /* travel not yet turned into a page; signed */
    int direction;      /* +1 forward, -1 back, 0 none yet */
    double last_event_s; /* seconds; 0.0 means no event yet */
} SpdfWinPageWheel;

/* True when these modifiers mean "page": Alt without Ctrl. Ctrl already means
 * zoom, and the window routes Ctrl + wheel elsewhere before this is asked, but
 * the rule is stated here too so a caller that reaches it another way agrees. */
static SPDF_WIN_PW_INLINE int spdf_win_page_wheel_modifiers_page(unsigned mods) {
    if (!(mods & SPDF_WIN_PAGE_WHEEL_MOD_ALT)) return 0;
    return (mods & SPDF_WIN_PAGE_WHEEL_MOD_CTRL) == 0;
}

static SPDF_WIN_PW_INLINE void spdf_win_page_wheel_reset(SpdfWinPageWheel* s) {
    s->accumulator = 0.0;
    s->direction = 0;
}

/* How many pages this wheel event should turn: positive forward, negative back,
 * 0 not yet. A COUNT, not a flag, so scrolling fast keeps up instead of
 * dropping notches. `units_per_page` must be positive; a non-positive value
 * turns nothing, because a threshold of zero would page on every event. */
static SPDF_WIN_PW_INLINE int spdf_win_page_wheel_step(SpdfWinPageWheel* s, double delta, double units_per_page,
                                                       double now_s) {
    int direction, pages, forward;
    if (!s || !(units_per_page > 0.0)) return 0;
    if (s->last_event_s > 0.0 && now_s - s->last_event_s > SPDF_WIN_PAGE_WHEEL_IDLE_RESET_S)
        spdf_win_page_wheel_reset(s);
    s->last_event_s = now_s;
    if (fabs(delta) < 1e-4) return 0;
    direction = delta < 0.0 ? -1 : 1;
    /* Reversing discards the abandoned direction's travel: the reader changed
     * their mind, and the leftover must not fire the way they gave up on. */
    if (s->direction != 0 && direction != s->direction) s->accumulator = 0.0;
    s->direction = direction;
    s->accumulator += delta;
    if (fabs(s->accumulator) < units_per_page) return 0;
    forward = s->accumulator < 0.0 ? -1 : 1;
    pages = (int)(fabs(s->accumulator) / units_per_page);
    if (pages > SPDF_WIN_PAGE_WHEEL_MAX_PAGES_PER_EVENT) pages = SPDF_WIN_PAGE_WHEEL_MAX_PAGES_PER_EVENT;
    /* Drain the pages just turned, keeping the sign, so the remainder belongs to
     * the next page rather than being discarded -- the whole fix. */
    s->accumulator -= (double)pages * units_per_page * (double)forward;
    return pages * forward;
}

/* ONE NOTCH IN DEVICE PIXELS, exactly as spdf_win_window_input.h's wheel_step()
 * derives the distance it hands the app for one WHEEL_DELTA: the user's
 * SPI_GETWHEELSCROLLLINES lines of 20 logical pixels, or nine tenths of the
 * client height when that setting is WHEEL_PAGESCROLL (0xFFFFFFFF, "scroll a
 * screenful"); 0 lines falls back to the Windows default of 3. The app cannot
 * see the raw notch count -- the window converts it before dispatch -- so it
 * inverts the same formula; the two must stay equal or one notch stops being
 * one page. Pure: the caller reads the system parameter and the client height
 * (in->view_px_h) and passes them in. */
#define SPDF_WIN_PAGE_WHEEL_LINES_PAGESCROLL 0xFFFFFFFFu

static SPDF_WIN_PW_INLINE double spdf_win_page_wheel_notch_px(unsigned lines, double dpi_scale,
                                                              unsigned client_px_h) {
    if (lines == SPDF_WIN_PAGE_WHEEL_LINES_PAGESCROLL) return (double)client_px_h * 0.9;
    if (lines == 0) lines = 3;
    if (!(dpi_scale > 0.0)) dpi_scale = 1.0;
    return (double)lines * 20.0 * dpi_scale;
}

#endif /* SPDF_WIN_PAGE_WHEEL_H */
