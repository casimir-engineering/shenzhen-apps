/* spdf_win_placement.h — where a restored window goes, and which frame is
 * remembered. The RULES only: no Win32, no HWND, so placement_test.c can pin
 * them with the display geometry the defect was found on and no monitor to
 * plug in.
 *
 * Ported from portable/mac/SPDFMacWindowPlacement.mm (060856589, 96b7e8b7a).
 * The defect it exists to not have, stated once: a window left on a second
 * display, launched while that display was asleep or unplugged, was CLAMPED
 * onto the main display at load time and the clamp was SAVED on quit -- one
 * launch without the display forgot the position for good. So:
 *
 *   1. The saved frame is kept RAW. Nothing clamps it on the way in.
 *   2. A frame no attached display can show is still put somewhere visible --
 *      centred on the main display, no bigger than its work area -- but that
 *      placement is a FALLBACK and display-only: what gets saved is still the
 *      frame the reader left, until the reader moves or resizes the window
 *      themselves (spdf_win_window_get_placement, spdf_win_window_frame.h).
 *   3. When the missing display reappears (WM_DISPLAYCHANGE), the remembered
 *      frame is applied then.
 *
 * WHAT IDENTIFIES A DISPLAY. The mac judges a frame by what it overlaps
 * (NSScreen.visibleFrame). Windows can do better: MONITORINFOEXW carries a
 * device name (\\.\DISPLAY2) and the monitor's rectangle in virtual-screen
 * coordinates, and the two together say "the display it was left on, where it
 * was". Otherwise -- a mac-written file has no display, an unplugged and
 * replugged display can come back under another name, a rearranged desktop
 * moves the rectangle -- the overlap rule decides, with the mac's own
 * threshold: an 80 x 80 sliver is not "on screen".
 *
 * WHAT "ON SCREEN" HAS TO MEAN HERE (2026-09-07). This file first applied a
 * frame exactly whenever its display was attached, whatever it overlapped, and
 * a frame is not reachable just because its display is. Measured on the
 * 2880 x 1800 desktop: a frame left with a 60 x 28 corner inside the work area
 * came back as exactly that corner, focused and invisible; a frame whose top
 * edge was 1100 px above the display came back as a 111 px strip along the
 * top with its title bar -- the tab strip, the only thing there is to drag --
 * off the screen. Windows' own SetWindowPlacement pulls a frame that misses
 * every monitor back to the nearest edge, and leaves a frame that touches one
 * where it is; so the partial cases are ours. Hence rule 4:
 *
 *   4. A frame is REACHABLE, and applied as saved, only when its top edge lies
 *      in a work area it overlaps by the 80 x 80 minimum. Anything else is
 *      parked: pulled whole into the work area of the display it overlaps
 *      (or, overlapping none, of the display it names when that is attached)
 *      -- the reader's place, corrected by the least that makes it reachable
 *      -- and, on no display at all, centred on the main display as before.
 *      Parked is parked either way: the saved frame stays what is remembered.
 */
#ifndef SPDF_WIN_PLACEMENT_H
#define SPDF_WIN_PLACEMENT_H

#include <string.h>

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_PLACEMENT_INLINE __inline
#else
#define SPDF_WIN_PLACEMENT_INLINE inline
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* CCHDEVICENAME: the size of MONITORINFOEXW::szDevice. */
#define SPDF_WIN_DISPLAY_NAME_MAX 32

/* The smallest overlap worth calling "on screen" (mac: kSPDFMinimumVisibleArea). */
#define SPDF_WIN_PLACEMENT_MIN_VISIBLE 80

typedef struct spdf_win_rect {
    int x, y, w, h;
} spdf_win_rect;

/* A window's placement for the session: the NORMAL frame -- what it occupies
 * when neither maximized nor full screen -- in virtual-screen device pixels,
 * and the display it was on. `display` is empty when unknown (a mac-written
 * session, or a build that never wrote one); `frame.w`/`h` <= 0 means none. */
typedef struct spdf_win_placement {
    spdf_win_rect frame;
    char display[SPDF_WIN_DISPLAY_NAME_MAX]; /* MONITORINFOEXW szDevice, ASCII */
    spdf_win_rect display_rect;              /* that display's rcMonitor */
} spdf_win_placement;

/* An attached display, as the window layer enumerates them. */
typedef struct spdf_win_display {
    char name[SPDF_WIN_DISPLAY_NAME_MAX];
    spdf_win_rect monitor; /* rcMonitor */
    spdf_win_rect work;    /* rcWork: minus the taskbar */
} spdf_win_display;

static SPDF_WIN_PLACEMENT_INLINE int spdf_win_rect_equal(spdf_win_rect a, spdf_win_rect b) {
    return a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h;
}

/* The intersection's width and height, each 0 when the rectangles miss. */
static SPDF_WIN_PLACEMENT_INLINE void spdf_win_rect_overlap(spdf_win_rect a, spdf_win_rect b, int* w, int* h) {
    int left = a.x > b.x ? a.x : b.x;
    int top = a.y > b.y ? a.y : b.y;
    int right = a.x + a.w < b.x + b.w ? a.x + a.w : b.x + b.w;
    int bottom = a.y + a.h < b.y + b.h ? a.y + a.h : b.y + b.h;
    *w = right > left ? right - left : 0;
    *h = bottom > top ? bottom - top : 0;
}

/* Whether `frame` is reachable on some attached display: at least an 80 x 80
 * block of it lies inside a work area. Pure, and the mac's rule exactly
 * (spdf_window_frame_is_usable_on_screens), so the two apps agree about what
 * "on screen" means. */
static SPDF_WIN_PLACEMENT_INLINE int spdf_win_frame_is_visible(spdf_win_rect frame, const spdf_win_display* displays,
                                                              int count) {
    int i, w, h;
    if (frame.w <= 0 || frame.h <= 0) return 0;
    for (i = 0; i < count; ++i) {
        spdf_win_rect_overlap(frame, displays[i].work, &w, &h);
        if (w >= SPDF_WIN_PLACEMENT_MIN_VISIBLE && h >= SPDF_WIN_PLACEMENT_MIN_VISIBLE) return 1;
    }
    return 0;
}

/* Whether the display a placement names is attached where it was. */
static SPDF_WIN_PLACEMENT_INLINE int spdf_win_placement_display_attached(const spdf_win_placement* p,
                                                                        const spdf_win_display* displays, int count) {
    int i;
    if (!p || !p->display[0]) return 0;
    for (i = 0; i < count; ++i)
        if (strcmp(displays[i].name, p->display) == 0 && spdf_win_rect_equal(displays[i].monitor, p->display_rect))
            return 1;
    return 0;
}

/* Whether `frame` is REACHABLE: visible by the rule above on some work area,
 * AND its top edge inside that same work area, so the strip that is this
 * window's title bar can be taken hold of. The overlap region starts at the
 * frame's top edge when that edge is inside, so "80 rows overlap" then means
 * the top 80 rows -- the strip -- are the ones on screen. A frame that is
 * visible but not reachable is the 111 px strip the header describes. */
static SPDF_WIN_PLACEMENT_INLINE int spdf_win_frame_is_reachable(spdf_win_rect frame, const spdf_win_display* displays,
                                                                int count) {
    int i, w, h;
    if (frame.w <= 0 || frame.h <= 0) return 0;
    for (i = 0; i < count; ++i) {
        const spdf_win_rect work = displays[i].work;
        spdf_win_rect_overlap(frame, work, &w, &h);
        if (w >= SPDF_WIN_PLACEMENT_MIN_VISIBLE && h >= SPDF_WIN_PLACEMENT_MIN_VISIBLE && frame.y >= work.y &&
            frame.y < work.y + work.h)
            return 1;
    }
    return 0;
}

/* THE RULE: a saved placement is applied as it is when its frame is reachable
 * on some attached display. Anything else is a frame the desktop cannot show
 * as it is, and spdf_win_placement_resolve() below parks it. The display's
 * identity no longer makes an unreachable frame usable (rule 4 in the header);
 * it still says where such a frame is parked. */
static SPDF_WIN_PLACEMENT_INLINE int spdf_win_placement_is_usable(const spdf_win_placement* p,
                                                                 const spdf_win_display* displays, int count) {
    if (!p || p->frame.w <= 0 || p->frame.h <= 0) return 0;
    return spdf_win_frame_is_reachable(p->frame, displays, count);
}

/* The display a frame belongs to: the one whose MONITOR rectangle (taskbar
 * included -- a frame under the taskbar is still on that display) it overlaps
 * most, by area; else the display the placement names, when that is attached
 * where it was; else -1. */
static SPDF_WIN_PLACEMENT_INLINE int spdf_win_placement_home_display(const spdf_win_placement* p,
                                                                    const spdf_win_display* displays, int count) {
    int i, w, h, best = -1;
    long long best_area = 0;
    if (!p) return -1;
    for (i = 0; i < count; ++i) {
        spdf_win_rect_overlap(p->frame, displays[i].monitor, &w, &h);
        if ((long long)w * h > best_area) {
            best_area = (long long)w * h;
            best = i;
        }
    }
    if (best >= 0) return best;
    for (i = 0; i < count; ++i)
        if (p->display[0] && strcmp(displays[i].name, p->display) == 0 &&
            spdf_win_rect_equal(displays[i].monitor, p->display_rect))
            return i;
    return -1;
}

/* `desired` pulled whole into `work`: no bigger than it, then translated by
 * the least that puts every edge inside. The size and the offset within the
 * work area are the reader's wherever they can be; only what hung outside
 * moves. Idempotent on a rect already inside. */
static SPDF_WIN_PLACEMENT_INLINE spdf_win_rect spdf_win_placement_clamp(spdf_win_rect desired, spdf_win_rect work) {
    spdf_win_rect r = desired;
    if (r.w > work.w) r.w = work.w;
    if (r.h > work.h) r.h = work.h;
    if (r.x + r.w > work.x + work.w) r.x = work.x + work.w - r.w;
    if (r.y + r.h > work.y + work.h) r.y = work.y + work.h - r.h;
    if (r.x < work.x) r.x = work.x;
    if (r.y < work.y) r.y = work.y;
    return r;
}

/* Where to park a window whose own display is not attached: centred in `work`
 * (the main display's work area), at no more than its size. Centred rather
 * than clamped into a corner, which is what produced a window pinned at the
 * display's exact edge -- and, saved, a position nobody chose. */
static SPDF_WIN_PLACEMENT_INLINE spdf_win_rect spdf_win_placement_fallback(spdf_win_rect desired, spdf_win_rect work) {
    spdf_win_rect r;
    r.w = desired.w < work.w ? desired.w : work.w;
    r.h = desired.h < work.h ? desired.h : work.h;
    r.x = work.x + (work.w - r.w) / 2;
    r.y = work.y + (work.h - r.h) / 2;
    return r;
}

/* WHERE THE WINDOW GOES: the saved frame when it is reachable; otherwise the
 * frame clamped into the work area of its home display, or centred in
 * `main_work` (the main display's work area) when it has no home among the
 * attached displays. `*parked` says the result is not the saved frame, so the
 * window layer remembers the saved one (rule 2 in the header) -- and it is
 * set by comparing rectangles rather than by which branch ran, so a frame that
 * is already where it would be parked reads as "as saved". Pure: the whole of
 * rule 4, with no HWND, so placement_test.c pins it on the geometry it was
 * found on. */
static SPDF_WIN_PLACEMENT_INLINE spdf_win_rect spdf_win_placement_resolve(const spdf_win_placement* p,
                                                                          const spdf_win_display* displays, int count,
                                                                          spdf_win_rect main_work, int* parked) {
    spdf_win_rect r;
    int home;
    if (parked) *parked = 0;
    if (!p) {
        r = spdf_win_placement_fallback(main_work, main_work);
        if (parked) *parked = 1;
        return r;
    }
    if (spdf_win_placement_is_usable(p, displays, count)) return p->frame;
    home = spdf_win_placement_home_display(p, displays, count);
    r = home >= 0 ? spdf_win_placement_clamp(p->frame, displays[home].work)
                  : spdf_win_placement_fallback(p->frame, main_work);
    if (parked) *parked = !spdf_win_rect_equal(r, p->frame);
    return r;
}

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_PLACEMENT_H */
