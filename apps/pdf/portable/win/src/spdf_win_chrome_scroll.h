/* spdf_win_chrome_scroll.h — where a scroller's thumb, its trough regions and
 * its search heat-map ticks sit.
 *
 * WHAT THIS IS: the arithmetic that turns a scroller's band rect plus two
 * fractions (`pos`, `visible`) into a thumb rect, and the inverse that turns a
 * pointer position or a drag delta back into a `pos`. Pure, toolkit-free,
 * header-only, no state, no allocation -- the fourth member of the family
 * spdf_win_chrome.h, spdf_win_tabstrip.h and spdf_win_chrome_input.h belong to,
 * and testable the same way (portable/win/tests/chrome_scroll_test.c).
 *
 * WHY IT IS A SEPARATE FILE FROM BOTH THE PAINTER AND THE ROUTER, and this is
 * the whole reason the file exists rather than an inline block in either:
 *
 *   spdf_win_chrome.h already states the rule -- "Hit-testing and painting must
 *   agree exactly. On macOS they do because AppKit owns both; here they agree
 *   only if they call the same functions." A scrollbar is the sharpest case of
 *   that rule in the whole window. Every other chrome control has a fixed rect;
 *   a thumb MOVES, and it moves as a function of two floats that arrive from the
 *   document. If the painter derives the thumb one way and the router another,
 *   the mismatch is not a wrong colour -- it is a click that grabs nothing, and
 *   it only shows up at the scroll positions nobody tested. So the thumb rect
 *   has exactly one definition, spdf_win_scroll_thumb(), and both callers use
 *   it. The painter's ONLY licence to differ is the cross-axis inset it draws
 *   with (spdf_win_scroll_thumb_visual), which is strictly INSIDE the hit rect
 *   -- the forgiving direction, and the Windows 11 look.
 *
 * UNITS. Device pixels in, device pixels out, in the client area's own
 * coordinates -- the space SpdfWinChromeLayout's rects live in. The functions
 * that convert a macOS point metric (the 2 pt track inset, the 1.5 pt marker
 * gap) take a `dpi_scale` and go through spdf_win_chrome_px(), exactly as
 * spdf_win_chrome.h does, so a 2 pt inset is 3 px at 150%.
 *
 * FRACTIONS, NOT OFFSETS. `pos` is the scrolled fraction in [0,1] and `visible`
 * is the fraction of the content the viewport shows -- which IS the thumb's
 * proportional length. That is what SpdfWinChromeModel carries
 * (spdf_win_chrome_state.h), and it is deliberate: a scroller needs no document
 * unit, no page count and no zoom, so none of this can go wrong when the
 * document's size is measured lazily one page at a time.
 *
 * DEGENERATE INPUT IS A FIRST-CLASS CASE, not an afterthought. The viewport is
 * 1x1 before the window is laid out; a document whose height has not been
 * measured yet reports visible = 0; a zoom change can leave `pos` momentarily
 * outside [0,1]; and a NaN reaching a D2D rect draws nothing and silently
 * poisons whatever it touches. So every entry point clamps, and every clamp is
 * written as `if (!(v > lo))` rather than `if (v < lo)` so a NaN takes the
 * clamped branch instead of falling through.
 */
#ifndef SPDF_WIN_CHROME_SCROLL_H
#define SPDF_WIN_CHROME_SCROLL_H

#include "spdf_win_chrome.h"

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_CS_INLINE __inline
#else
#define SPDF_WIN_CS_INLINE inline
#endif

/* Which way a scroller runs. The two share every function below; passing the
 * axis rather than duplicating the file is what keeps the vertical and the
 * horizontal scroller from drifting apart, which is how one of them ends up
 * with the minimum-thumb rule and the other without it. */
typedef enum spdf_win_scroll_axis {
    SPDF_WIN_SCROLL_V = 0,
    SPDF_WIN_SCROLL_H = 1
} spdf_win_scroll_axis;

/* Where in a scroller a point landed. TROUGH_BACK is the part of the track
 * BEFORE the thumb -- above it on the vertical scroller, left of it on the
 * horizontal one -- and a click there pages backwards, which is the Win32 and
 * the AppKit behaviour both. */
typedef enum spdf_win_scroll_part {
    SPDF_WIN_SCROLL_NONE = 0,
    SPDF_WIN_SCROLL_TROUGH_BACK,
    SPDF_WIN_SCROLL_THUMB,
    SPDF_WIN_SCROLL_TROUGH_FORWARD
} spdf_win_scroll_part;

/* The thumb's visual inset across the axis. NOT a macOS number: AppKit's legacy
 * scroller draws a knob nearly the full slot width, while a Windows 11 scrollbar
 * is a thin rounded pill floating on a quiet trough. This is the one place the
 * two idioms differ visibly, and spdf_win_chrome_theme.h's header already sets
 * the policy for that -- chrome should look like Windows while keeping every
 * macOS RELATIONSHIP. The relationship kept here is that the thumb's POSITION
 * and LENGTH are macOS's exactly; only its thickness is Windows'. */
#define SPDF_WIN_SCROLL_THUMB_INSET 4.0
#define SPDF_WIN_SCROLL_THUMB_RADIUS 3.0

/* --- tiny helpers, shared by everything below ---------------------------- */

/* Clamp into [0,1] with NaN mapping to `fallback`. Written as a pair of
 * negated comparisons on purpose: `v < 0.0f` is FALSE for a NaN, so the naive
 * form lets one straight through into a rect. */
static SPDF_WIN_CS_INLINE float spdf_win_scroll_unit(float v, float fallback) {
    if (!(v >= 0.0f) && !(v <= 1.0f)) return fallback; /* NaN fails both */
    if (v < 0.0f) return 0.0f;
    if (v > 1.0f) return 1.0f;
    return v;
}

static SPDF_WIN_CS_INLINE float spdf_win_scroll_len(SpdfWinChromeRect r, int axis) {
    return axis == SPDF_WIN_SCROLL_H ? r.w : r.h;
}

static SPDF_WIN_CS_INLINE float spdf_win_scroll_start(SpdfWinChromeRect r, int axis) {
    return axis == SPDF_WIN_SCROLL_H ? r.x : r.y;
}

/* Whole device pixels for the shortest thumb we will draw. Not a macOS metric
 * -- AppKit enforces its own minimum internally -- but without one a 10,000
 * page document leaves a sub-pixel thumb with nothing to grab. */
static SPDF_WIN_CS_INLINE float spdf_win_scroll_thumb_min(float dpi_scale) {
    return spdf_win_chrome_px(SPDF_WIN_CHROME_SCROLL_THUMB_MIN, dpi_scale);
}

/* --- the track ----------------------------------------------------------- */

/* The usable track inside a scroller's band: inset SPDF_WIN_CHROME_SCROLL_TRACK_INSET
 * (2 pt, macOS's own) at each END of the axis and nothing across it, which is
 * exactly what SPDFMacUIHelpers.mm:453-479 does to the slot it draws its find
 * markers into. An empty band, or one too short to hold both insets, yields an
 * empty rect -- and every function below treats an empty track as "no
 * scroller", so a window squeezed to nothing draws and hits nothing rather than
 * producing negative geometry. */
static SPDF_WIN_CS_INLINE SpdfWinChromeRect spdf_win_scroll_track(SpdfWinChromeRect bar, float dpi_scale, int axis) {
    float inset;
    if (spdf_win_chrome_rect_empty(bar)) return spdf_win_chrome_zero();
    inset = spdf_win_chrome_px(SPDF_WIN_CHROME_SCROLL_TRACK_INSET, dpi_scale);
    if (spdf_win_scroll_len(bar, axis) <= 2.0f * inset) return spdf_win_chrome_zero();
    if (axis == SPDF_WIN_SCROLL_H) {
        bar.x += inset;
        bar.w -= 2.0f * inset;
    } else {
        bar.y += inset;
        bar.h -= 2.0f * inset;
    }
    return bar;
}

/* --- the thumb ----------------------------------------------------------- */

/* How long the thumb is, in device pixels along the axis.
 *
 * THE THREE RULES, in the order they apply:
 *   1. `visible >= 1` -- the viewport shows the whole document -- gives a
 *      FULL-LENGTH thumb, not a hidden one. macOS sets autohidesScrollers = NO
 *      on both scroll views (ShenzhenPDFMac.mm:3225-3227), so its scroller is
 *      always there; a full-length knob is what it shows, and it reads as "this
 *      is all of it" rather than as a broken control.
 *   2. `visible <= 0` -- nothing measured yet, or a zero-height document --
 *      does the same, for the same reason: a trough with no thumb at all looks
 *      like a failure, and "you are seeing everything" is the honest reading of
 *      a document with no scrollable extent.
 *   3. Otherwise proportional, but never shorter than `min_thumb_px` and never
 *      longer than the track. */
static SPDF_WIN_CS_INLINE float spdf_win_scroll_thumb_len(SpdfWinChromeRect track, float visible, float min_thumb_px,
                                                          int axis) {
    float track_len = spdf_win_scroll_len(track, axis);
    float len;
    if (spdf_win_chrome_rect_empty(track) || track_len <= 0.0f) return 0.0f;
    /* -1 rather than 0 as the NaN fallback, so a NaN `visible` is treated as
     * "unknown" (full length) and never as "a hair of a thumb". */
    visible = spdf_win_scroll_unit(visible, -1.0f);
    if (!(visible > 0.0f) || visible >= 1.0f) return track_len;
    if (!(min_thumb_px > 0.0f)) min_thumb_px = 0.0f;
    if (min_thumb_px > track_len) min_thumb_px = track_len;
    len = visible * track_len;
    if (len < min_thumb_px) len = min_thumb_px;
    if (len > track_len) len = track_len;
    return floorf(len + 0.5f);
}

/* The thumb's HIT rect: full track thickness across the axis, whole pixels
 * along it. This is the rect the router tests and the rect the painter derives
 * its rounded pill from -- see the file header on why there is exactly one. */
static SPDF_WIN_CS_INLINE SpdfWinChromeRect spdf_win_scroll_thumb(SpdfWinChromeRect track, float pos, float visible,
                                                                  float min_thumb_px, int axis) {
    SpdfWinChromeRect thumb = track;
    float track_len = spdf_win_scroll_len(track, axis);
    float len = spdf_win_scroll_thumb_len(track, visible, min_thumb_px, axis);
    float travel, offset;

    if (!(len > 0.0f)) return spdf_win_chrome_zero();
    travel = track_len - len;
    if (!(travel > 0.0f)) travel = 0.0f;
    offset = floorf(spdf_win_scroll_unit(pos, 0.0f) * travel + 0.5f);
    /* Belt and braces: the rounding above cannot exceed `travel`, but a thumb
     * that hangs off the end of its track is the one defect that would be
     * invisible in a screenshot and wrong in every hit test. */
    if (offset > travel) offset = travel;
    if (axis == SPDF_WIN_SCROLL_H) {
        thumb.x = track.x + offset;
        thumb.w = len;
    } else {
        thumb.y = track.y + offset;
        thumb.h = len;
    }
    return thumb;
}

/* What the PAINTER fills: the hit rect inset across the axis and given a
 * radius, for the Windows 11 pill. Derived from the hit rect by a pure
 * function, so the two can never disagree about position or length -- only
 * about thickness, and always in the direction that makes the target bigger
 * than the drawing. A track too thin for the inset keeps its full thickness
 * rather than collapsing. */
static SPDF_WIN_CS_INLINE SpdfWinChromeRect spdf_win_scroll_thumb_visual(SpdfWinChromeRect thumb, float dpi_scale,
                                                                          int axis) {
    float inset = spdf_win_chrome_px(SPDF_WIN_SCROLL_THUMB_INSET, dpi_scale);
    float cross = axis == SPDF_WIN_SCROLL_H ? thumb.h : thumb.w;
    if (spdf_win_chrome_rect_empty(thumb)) return spdf_win_chrome_zero();
    if (cross <= 2.0f * inset + 1.0f) return thumb;
    if (axis == SPDF_WIN_SCROLL_H) {
        thumb.y += inset;
        thumb.h -= 2.0f * inset;
    } else {
        thumb.x += inset;
        thumb.w -= 2.0f * inset;
    }
    return thumb;
}

/* --- the inverse --------------------------------------------------------- */

/* How far the thumb can travel, in device pixels. 0 means a full-length thumb:
 * there is nothing to scroll, so every inverse below must return the position
 * it was given rather than dividing by zero. */
static SPDF_WIN_CS_INLINE float spdf_win_scroll_travel(SpdfWinChromeRect track, float visible, float min_thumb_px,
                                                        int axis) {
    float travel = spdf_win_scroll_len(track, axis) - spdf_win_scroll_thumb_len(track, visible, min_thumb_px, axis);
    return travel > 0.0f ? travel : 0.0f;
}

/* THE DRAG. `pos_at_press` is the position the thumb had when the button went
 * down and `delta_px` how far the pointer has travelled along the axis since.
 *
 * A DELTA FROM THE PRESS, not "centre the thumb on the pointer". Grabbing a
 * thumb near its bottom edge and having it jump so its middle is under the
 * cursor is the single most complained-about scrollbar defect there is; taking
 * the delta from where the gesture started preserves the grab offset exactly and
 * needs no extra state beyond the two values the caller already has. */
static SPDF_WIN_CS_INLINE float spdf_win_scroll_drag_pos(SpdfWinChromeRect track, float pos_at_press, float visible,
                                                          float min_thumb_px, float delta_px, int axis) {
    float travel = spdf_win_scroll_travel(track, visible, min_thumb_px, axis);
    pos_at_press = spdf_win_scroll_unit(pos_at_press, 0.0f);
    if (!(travel > 0.0f)) return pos_at_press;
    if (!(delta_px > 0.0f) && !(delta_px < 0.0f)) delta_px = 0.0f; /* NaN or exactly 0 */
    return spdf_win_scroll_unit(pos_at_press + delta_px / travel, pos_at_press);
}

/* The position whose thumb ORIGIN lands on `coord` -- the exact inverse of
 * spdf_win_scroll_thumb()'s offset, up to that function's half-pixel rounding.
 * This is what makes `pos -> thumb -> pos` a round trip, which is the property
 * the test pins and the property a drag depends on. */
static SPDF_WIN_CS_INLINE float spdf_win_scroll_pos_at(SpdfWinChromeRect track, float visible, float min_thumb_px,
                                                        float coord, int axis) {
    float travel = spdf_win_scroll_travel(track, visible, min_thumb_px, axis);
    if (!(travel > 0.0f)) return 0.0f;
    return spdf_win_scroll_unit((coord - spdf_win_scroll_start(track, axis)) / travel, 0.0f);
}

/* --- hit-testing --------------------------------------------------------- */

/* Which part of the scroller (x, y) is in. Note that the THUMB wins over the
 * trough, for the same reason spdf_win_tabstrip.h gives for the close box
 * winning over the tab: the thumb lies inside the track, so testing the trough
 * first would swallow every drag. */
static SPDF_WIN_CS_INLINE spdf_win_scroll_part spdf_win_scroll_hit(SpdfWinChromeRect track, float pos, float visible,
                                                                    float min_thumb_px, float x, float y, int axis) {
    SpdfWinChromeRect thumb;
    float p;
    if (!spdf_win_chrome_contains(track, x, y)) return SPDF_WIN_SCROLL_NONE;
    thumb = spdf_win_scroll_thumb(track, pos, visible, min_thumb_px, axis);
    if (spdf_win_chrome_contains(thumb, x, y)) return SPDF_WIN_SCROLL_THUMB;
    p = axis == SPDF_WIN_SCROLL_H ? x : y;
    return p < spdf_win_scroll_start(thumb, axis) ? SPDF_WIN_SCROLL_TROUGH_BACK : SPDF_WIN_SCROLL_TROUGH_FORWARD;
}

/* --- the search heat-map ------------------------------------------------- */

/* One find marker on the vertical trough, transcribed from SPDFMacUIHelpers.mm
 * :453-479: x is the slot's left edge + 2 pt, the width is MAX(2, slotWidth - 4),
 * the ACTIVE match is 2 pt tall and every other match 1 pt, and the marker slides
 * over the track's own length so a match at fraction 1.0 sits flush with the
 * bottom instead of hanging off it.
 *
 * `track` is what spdf_win_scroll_track() returned -- macOS insets its slot by
 * the same 2 pt before placing markers, so passing the raw band here would put
 * every tick 2 px high. */
static SPDF_WIN_CS_INLINE SpdfWinChromeRect spdf_win_scroll_marker_rect(SpdfWinChromeRect track, float fraction,
                                                                         int active, float dpi_scale) {
    SpdfWinChromeRect r;
    float inset, min_w, h;
    if (spdf_win_chrome_rect_empty(track)) return spdf_win_chrome_zero();
    inset = spdf_win_chrome_px(SPDF_WIN_CHROME_SCROLL_MARKER_INSET, dpi_scale);
    min_w = spdf_win_chrome_px(SPDF_WIN_CHROME_SCROLL_MARKER_MIN_W, dpi_scale);
    h = spdf_win_chrome_px(active ? SPDF_WIN_CHROME_SCROLL_MARKER_ACTIVE_H : SPDF_WIN_CHROME_SCROLL_MARKER_H,
                           dpi_scale);
    if (h < 1.0f) h = 1.0f;
    if (h > track.h) h = track.h;
    r.x = track.x + inset;
    r.w = spdf_win_chrome_max(min_w, track.w - 2.0f * inset);
    /* Never wider than the track it rides on: a 15 pt trough is wide enough for
     * MAX(2, w-4) to be the second term, but a DPI rounding at some scale must
     * not push the marker out over the document. */
    if (r.w > track.w) {
        r.x = track.x;
        r.w = track.w;
    }
    r.h = h;
    r.y = track.y + floorf(spdf_win_scroll_unit(fraction, 0.0f) * (track.h - h) + 0.5f);
    return r;
}

/* macOS drops a marker closer than 1.5 pt to the previous one it kept, rather
 * than drawing them over each other -- 400 matches on one page would otherwise
 * paint the whole trough solid and stop meaning anything. `prev_y` is the y of
 * the last marker KEPT (not the last one considered), and any negative value
 * means "none yet". */
static SPDF_WIN_CS_INLINE int spdf_win_scroll_marker_keep(float y, float prev_y, float dpi_scale) {
    float gap;
    if (prev_y < 0.0f) return 1;
    gap = spdf_win_chrome_px(SPDF_WIN_CHROME_SCROLL_MARKER_MIN_GAP, dpi_scale);
    return (y - prev_y) >= gap ? 1 : 0;
}

#endif /* SPDF_WIN_CHROME_SCROLL_H */
