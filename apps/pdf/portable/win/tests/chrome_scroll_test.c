/* chrome_scroll_test.c — pins portable/win/src/spdf_win_chrome_scroll.h.
 *
 * WHAT IT IS FOR. A scrollbar is the one piece of chrome whose geometry MOVES,
 * and it moves as a function of two floats that arrive from a document the test
 * suite has no access to. That makes example-based checks weak -- any three
 * hand-picked positions will pass while the fourth is off the end of the track --
 * so most of what is below is PROPERTY checks over swept inputs:
 *
 *   - the thumb is always inside its track, at every position and every
 *     proportion, at three DPI scales;
 *   - it is never shorter than the minimum and never longer than the track;
 *   - pos -> thumb -> pos round-trips to within the half pixel the thumb's own
 *     rounding can lose;
 *   - a point on the thumb hit-tests as the thumb, and the two trough regions
 *     are exactly the rest of the track;
 *   - `visible >= 1` gives a full-length thumb rather than a hidden one, which
 *     is what a non-autohiding scroller shows for a document that fits;
 *   - and no degenerate input -- zero-height track, visible 0, pos outside
 *     [0,1], a NaN in any of them -- produces a NaN or a rect outside the track.
 *
 * The NaN cases earn their keep specifically: `if (v < 0.0f)` is FALSE for a
 * NaN, so the obvious clamp lets one through into a D2D rect, where it draws
 * nothing and says nothing. Every clamp in the header under test is written the
 * other way round, and these are the checks that keep it that way. Header-only
 * under test, so no `spdf-test-sources` line is needed.
 */
#include "spdf_win_chrome_scroll.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__);                                           \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_EQF(a, b)                                                                                                \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (fabsf((float)(a) - (float)(b)) > 0.001f) {                                                                 \
            fprintf(stderr, "FAIL %s == %s (%.4f vs %.4f) (%s:%d)\n", #a, #b, (double)(a), (double)(b), __FILE__,       \
                    __LINE__);                                                                                         \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_EQI(a, b)                                                                                                \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if ((int)(a) != (int)(b)) {                                                                                    \
            fprintf(stderr, "FAIL %s == %s (%d vs %d) (%s:%d)\n", #a, #b, (int)(a), (int)(b), __FILE__, __LINE__);      \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* A float is finite. `v == v` rather than isnan(), because that form survives
 * a fast-math build, and this suite is compiled by MSVC. */
static int finite_f(float v) { return v == v && v < 1e30f && v > -1e30f; }

static int rect_finite(SpdfWinChromeRect r) {
    return finite_f(r.x) && finite_f(r.y) && finite_f(r.w) && finite_f(r.h);
}

/* A rect is inside another, inclusively on all four edges. */
static int inside(SpdfWinChromeRect inner, SpdfWinChromeRect outer) {
    return inner.x >= outer.x - 0.001f && inner.y >= outer.y - 0.001f &&
           inner.x + inner.w <= outer.x + outer.w + 0.001f && inner.y + inner.h <= outer.y + outer.h + 0.001f;
}

/* The two scroller bands of a default window, as spdf_win_chrome_layout()
 * produces them -- the real rects, not invented ones. */
static void bands(float dpi, int h_scrollable, SpdfWinChromeLayout* out) {
    SpdfWinChromeModel m;
    memset(&m, 0, sizeof(m));
    m.show_sidebar = 1;
    m.show_minimap = 1;
    m.selected_tab = -1;
    m.hot_tab = -1;
    m.hot_close = -1;
    m.h_scrollable = h_scrollable;
    spdf_win_chrome_layout(&m, (unsigned)(1120.0f * dpi), (unsigned)(800.0f * dpi), dpi, out);
}

/* --- the track ----------------------------------------------------------- */

static void test_track(float dpi) {
    SpdfWinChromeLayout l;
    SpdfWinChromeRect v, h;
    float inset = spdf_win_chrome_px(SPDF_WIN_CHROME_SCROLL_TRACK_INSET, dpi);

    bands(dpi, 1, &l);
    CHECK(!spdf_win_chrome_rect_empty(l.vscroll));
    CHECK(!spdf_win_chrome_rect_empty(l.hscroll));

    v = spdf_win_scroll_track(l.vscroll, dpi, SPDF_WIN_SCROLL_V);
    /* macOS insets its slot 2 pt at each END of the axis and nothing across it
     * (SPDFMacUIHelpers.mm:453-479); getting that backwards would make a 15 pt
     * trough 11 pt wide and every marker too narrow. */
    CHECK_EQF(v.x, l.vscroll.x);
    CHECK_EQF(v.w, l.vscroll.w);
    CHECK_EQF(v.y, l.vscroll.y + inset);
    CHECK_EQF(v.h, l.vscroll.h - 2.0f * inset);
    CHECK(inside(v, l.vscroll));

    h = spdf_win_scroll_track(l.hscroll, dpi, SPDF_WIN_SCROLL_H);
    CHECK_EQF(h.y, l.hscroll.y);
    CHECK_EQF(h.h, l.hscroll.h);
    CHECK_EQF(h.x, l.hscroll.x + inset);
    CHECK_EQF(h.w, l.hscroll.w - 2.0f * inset);
    CHECK(inside(h, l.hscroll));

    /* An empty band, and one too short to hold both insets, are both "no
     * scroller" rather than a negative rect. */
    CHECK(spdf_win_chrome_rect_empty(spdf_win_scroll_track(spdf_win_chrome_zero(), dpi, SPDF_WIN_SCROLL_V)));
    {
        SpdfWinChromeRect tiny = l.vscroll;
        tiny.h = inset; /* shorter than 2 * inset */
        CHECK(spdf_win_chrome_rect_empty(spdf_win_scroll_track(tiny, dpi, SPDF_WIN_SCROLL_V)));
    }
}

/* --- THE PROPERTY SWEEP --------------------------------------------------- */

/* Every combination of position and proportion, on both axes, at three DPI
 * scales -- the check that catches a thumb hanging off the end of its track at
 * pos = 1, where a rounding error lands and where nobody clicks. */
static void test_thumb_properties(float dpi) {
    SpdfWinChromeLayout l;
    int axis;
    float min_thumb = spdf_win_scroll_thumb_min(dpi);

    bands(dpi, 1, &l);

    for (axis = 0; axis < 2; ++axis) {
        SpdfWinChromeRect band = axis == SPDF_WIN_SCROLL_H ? l.hscroll : l.vscroll;
        SpdfWinChromeRect track = spdf_win_scroll_track(band, dpi, axis);
        float track_len = spdf_win_scroll_len(track, axis);
        float visible, pos;

        CHECK(track_len > 0.0f);
        for (visible = 0.0f; visible <= 1.0001f; visible += 0.013f) {
            for (pos = 0.0f; pos <= 1.0001f; pos += 0.017f) {
                SpdfWinChromeRect thumb = spdf_win_scroll_thumb(track, pos, visible, min_thumb, axis);
                float len = spdf_win_scroll_len(thumb, axis);
                CHECK(rect_finite(thumb));
                CHECK(inside(thumb, track));
                /* Never shorter than the minimum -- unless the whole track is
                 * shorter than the minimum, which these bands are not. */
                CHECK(len >= min_thumb - 0.001f);
                CHECK(len <= track_len + 0.001f);
                /* The cross axis is the track's, untouched: the visual inset is
                 * the painter's business and must not move the hit rect. */
                if (axis == SPDF_WIN_SCROLL_H) {
                    CHECK_EQF(thumb.y, track.y);
                    CHECK_EQF(thumb.h, track.h);
                } else {
                    CHECK_EQF(thumb.x, track.x);
                    CHECK_EQF(thumb.w, track.w);
                }
            }
        }
    }
}

/* pos -> thumb origin -> pos. The forward direction rounds the origin to a whole
 * device pixel, so the round trip can lose up to half a pixel of travel and no
 * more; asserting the exact bound rather than a loose epsilon is what would
 * catch an inverse that used the wrong denominator. */
static void test_round_trip(float dpi) {
    SpdfWinChromeLayout l;
    int axis;
    float min_thumb = spdf_win_scroll_thumb_min(dpi);

    bands(dpi, 1, &l);
    for (axis = 0; axis < 2; ++axis) {
        SpdfWinChromeRect track =
            spdf_win_scroll_track(axis == SPDF_WIN_SCROLL_H ? l.hscroll : l.vscroll, dpi, axis);
        float visible;
        for (visible = 0.05f; visible < 0.999f; visible += 0.031f) {
            float travel = spdf_win_scroll_travel(track, visible, min_thumb, axis);
            float pos;
            if (!(travel > 0.0f)) continue;
            for (pos = 0.0f; pos <= 1.0001f; pos += 0.019f) {
                SpdfWinChromeRect thumb = spdf_win_scroll_thumb(track, pos, visible, min_thumb, axis);
                float back = spdf_win_scroll_pos_at(track, visible, min_thumb, spdf_win_scroll_start(thumb, axis),
                                                    axis);
                CHECK(finite_f(back));
                CHECK(fabsf(back - (pos > 1.0f ? 1.0f : pos)) <= 0.5f / travel + 0.0001f);
            }
        }
    }
}

/* The three parts tile the track exactly: every pixel of it is BACK, THUMB or
 * FORWARD, and nothing outside it is any of them. Swept down the whole track so
 * the two boundaries are crossed rather than assumed. */
static void test_hit_partitions_the_track(float dpi) {
    SpdfWinChromeLayout l;
    SpdfWinChromeRect track, thumb;
    float min_thumb = spdf_win_scroll_thumb_min(dpi);
    float visible = 0.25f, pos = 0.4f;
    float y, x;

    bands(dpi, 0, &l);
    track = spdf_win_scroll_track(l.vscroll, dpi, SPDF_WIN_SCROLL_V);
    thumb = spdf_win_scroll_thumb(track, pos, visible, min_thumb, SPDF_WIN_SCROLL_V);
    x = track.x + track.w * 0.5f;

    for (y = track.y; y < track.y + track.h; y += 1.0f) {
        spdf_win_scroll_part p = spdf_win_scroll_hit(track, pos, visible, min_thumb, x, y, SPDF_WIN_SCROLL_V);
        CHECK(p != SPDF_WIN_SCROLL_NONE);
        if (y < thumb.y) CHECK_EQI(p, SPDF_WIN_SCROLL_TROUGH_BACK);
        else if (y < thumb.y + thumb.h) CHECK_EQI(p, SPDF_WIN_SCROLL_THUMB);
        else CHECK_EQI(p, SPDF_WIN_SCROLL_TROUGH_FORWARD);
    }
    /* Outside the track -- including the 2 pt inset at each end of the band --
     * is NONE, so the router swallows it rather than paging. */
    CHECK_EQI(spdf_win_scroll_hit(track, pos, visible, min_thumb, x, track.y - 1.0f, SPDF_WIN_SCROLL_V),
              SPDF_WIN_SCROLL_NONE);
    CHECK_EQI(spdf_win_scroll_hit(track, pos, visible, min_thumb, x, track.y + track.h, SPDF_WIN_SCROLL_V),
              SPDF_WIN_SCROLL_NONE);
    CHECK_EQI(spdf_win_scroll_hit(track, pos, visible, min_thumb, track.x - 1.0f, thumb.y + 1.0f, SPDF_WIN_SCROLL_V),
              SPDF_WIN_SCROLL_NONE);
}

/* A document that fits gets a FULL-LENGTH thumb, not a hidden one: macOS never
 * autohides its scrollers (ShenzhenPDFMac.mm:3225-3227). Same answer for an
 * UNKNOWN proportion, which is what the model carries before the document has
 * been measured. */
static void test_full_and_unknown(void) {
    SpdfWinChromeLayout l;
    SpdfWinChromeRect track;
    float min_thumb = spdf_win_scroll_thumb_min(1.0f);
    float probes[4];
    int i;

    bands(1.0f, 0, &l);
    track = spdf_win_scroll_track(l.vscroll, 1.0f, SPDF_WIN_SCROLL_V);
    probes[0] = 1.0f;
    probes[1] = 2.5f;  /* clamped to 1 */
    probes[2] = 0.0f;  /* nothing measured */
    probes[3] = -1.0f; /* clamped to 0, then treated as unknown */
    for (i = 0; i < 4; ++i) {
        SpdfWinChromeRect thumb = spdf_win_scroll_thumb(track, 0.5f, probes[i], min_thumb, SPDF_WIN_SCROLL_V);
        CHECK_EQF(thumb.y, track.y);
        CHECK_EQF(thumb.h, track.h);
        /* Nowhere to travel, so every position is the same position and the
         * inverse must not divide by it. */
        CHECK_EQF(spdf_win_scroll_travel(track, probes[i], min_thumb, SPDF_WIN_SCROLL_V), 0.0f);
        CHECK_EQF(spdf_win_scroll_drag_pos(track, 0.31f, probes[i], min_thumb, 250.0f, SPDF_WIN_SCROLL_V), 0.31f);
    }
    /* And the converse: a proportion just under 1 DOES leave room to move. */
    CHECK(spdf_win_scroll_travel(track, 0.9f, 1.0f, SPDF_WIN_SCROLL_V) > 0.0f);
}

/* --- the drag ------------------------------------------------------------ */

static void test_drag(void) {
    SpdfWinChromeLayout l;
    SpdfWinChromeRect track;
    float min_thumb = spdf_win_scroll_thumb_min(1.0f);
    float visible = 0.2f, travel;

    bands(1.0f, 0, &l);
    track = spdf_win_scroll_track(l.vscroll, 1.0f, SPDF_WIN_SCROLL_V);
    travel = spdf_win_scroll_travel(track, visible, min_thumb, SPDF_WIN_SCROLL_V);
    CHECK(travel > 0.0f);

    /* No movement is no change -- the press itself must not nudge the document,
     * which is what makes a click on the thumb a no-op rather than a jump. */
    CHECK_EQF(spdf_win_scroll_drag_pos(track, 0.4f, visible, min_thumb, 0.0f, SPDF_WIN_SCROLL_V), 0.4f);
    /* Dragging the full travel from the top reaches exactly the bottom. */
    CHECK_EQF(spdf_win_scroll_drag_pos(track, 0.0f, visible, min_thumb, travel, SPDF_WIN_SCROLL_V), 1.0f);
    /* Half of it reaches the middle. */
    CHECK_EQF(spdf_win_scroll_drag_pos(track, 0.0f, visible, min_thumb, travel * 0.5f, SPDF_WIN_SCROLL_V), 0.5f);
    /* Past either end clamps rather than running away -- and because the drag is
     * computed from the PRESS rather than accumulated, coming back lands exactly
     * where it started. That is the property an accumulating implementation
     * loses, and losing it is felt as a thumb that drifts away from the cursor. */
    CHECK_EQF(spdf_win_scroll_drag_pos(track, 0.5f, visible, min_thumb, 99999.0f, SPDF_WIN_SCROLL_V), 1.0f);
    CHECK_EQF(spdf_win_scroll_drag_pos(track, 0.5f, visible, min_thumb, -99999.0f, SPDF_WIN_SCROLL_V), 0.0f);
    CHECK_EQF(spdf_win_scroll_drag_pos(track, 0.5f, visible, min_thumb, 0.0f, SPDF_WIN_SCROLL_V), 0.5f);
}

/* --- the painter's inset ------------------------------------------------- */

/* The drawn pill must be INSIDE the hit rect and must not move along the axis:
 * the whole licence the painter has to differ from the router is thickness. */
static void test_thumb_visual(float dpi) {
    SpdfWinChromeLayout l;
    int axis;

    bands(dpi, 1, &l);
    for (axis = 0; axis < 2; ++axis) {
        SpdfWinChromeRect track =
            spdf_win_scroll_track(axis == SPDF_WIN_SCROLL_H ? l.hscroll : l.vscroll, dpi, axis);
        SpdfWinChromeRect thumb = spdf_win_scroll_thumb(track, 0.33f, 0.2f, spdf_win_scroll_thumb_min(dpi), axis);
        SpdfWinChromeRect drawn = spdf_win_scroll_thumb_visual(thumb, dpi, axis);
        CHECK(!spdf_win_chrome_rect_empty(drawn));
        CHECK(inside(drawn, thumb));
        CHECK_EQF(spdf_win_scroll_start(drawn, axis), spdf_win_scroll_start(thumb, axis));
        CHECK_EQF(spdf_win_scroll_len(drawn, axis), spdf_win_scroll_len(thumb, axis));
    }
    /* A thumb too thin to inset keeps its thickness rather than vanishing. */
    {
        SpdfWinChromeRect thin;
        thin.x = 10.0f;
        thin.y = 10.0f;
        thin.w = 3.0f;
        thin.h = 40.0f;
        CHECK_EQF(spdf_win_scroll_thumb_visual(thin, dpi, SPDF_WIN_SCROLL_V).w, 3.0f);
    }
}

/* --- the search heat-map ------------------------------------------------- */

static void test_markers(float dpi) {
    SpdfWinChromeLayout l;
    SpdfWinChromeRect track;
    float f;

    bands(dpi, 0, &l);
    track = spdf_win_scroll_track(l.vscroll, dpi, SPDF_WIN_SCROLL_V);

    /* macOS's numbers: x = slotMinX + 2, w = MAX(2, slotWidth - 4), 2 pt tall
     * for the active match and 1 pt for the rest (SPDFMacUIHelpers.mm:453-479). */
    {
        SpdfWinChromeRect ordinary = spdf_win_scroll_marker_rect(track, 0.0f, 0, dpi);
        SpdfWinChromeRect active = spdf_win_scroll_marker_rect(track, 0.0f, 1, dpi);
        float inset = spdf_win_chrome_px(SPDF_WIN_CHROME_SCROLL_MARKER_INSET, dpi);
        CHECK_EQF(ordinary.x, track.x + inset);
        CHECK_EQF(ordinary.w, spdf_win_chrome_max(spdf_win_chrome_px(SPDF_WIN_CHROME_SCROLL_MARKER_MIN_W, dpi),
                                                  track.w - 2.0f * inset));
        CHECK_EQF(ordinary.h, spdf_win_chrome_px(SPDF_WIN_CHROME_SCROLL_MARKER_H, dpi));
        CHECK_EQF(active.h, spdf_win_chrome_px(SPDF_WIN_CHROME_SCROLL_MARKER_ACTIVE_H, dpi));
        CHECK(active.h > ordinary.h); /* the active match must stand out */
        CHECK_EQF(ordinary.y, track.y);
    }

    /* Every fraction lands inside the track, top and bottom included: a match at
     * the very end of a document must sit flush with the bottom of the trough,
     * not one pixel past it. */
    for (f = 0.0f; f <= 1.0001f; f += 0.01f) {
        SpdfWinChromeRect r = spdf_win_scroll_marker_rect(track, f, f > 0.5f, dpi);
        CHECK(rect_finite(r));
        CHECK(inside(r, track));
    }
    CHECK_EQF(spdf_win_scroll_marker_rect(track, 1.0f, 0, dpi).y,
              track.y + track.h - spdf_win_chrome_px(SPDF_WIN_CHROME_SCROLL_MARKER_H, dpi));

    /* Out-of-range and NaN fractions are clamped, never drawn off the track. */
    CHECK(inside(spdf_win_scroll_marker_rect(track, -3.0f, 0, dpi), track));
    CHECK(inside(spdf_win_scroll_marker_rect(track, 17.0f, 0, dpi), track));
    CHECK(spdf_win_chrome_rect_empty(spdf_win_scroll_marker_rect(spdf_win_chrome_zero(), 0.5f, 0, dpi)));

    /* The 1.5 pt thinning rule. The first marker is always kept; one closer than
     * the gap to the last KEPT marker is dropped; one exactly at the gap is
     * kept, because macOS's test is a `>=` on the distance. */
    {
        float gap = spdf_win_chrome_px(SPDF_WIN_CHROME_SCROLL_MARKER_MIN_GAP, dpi);
        CHECK(spdf_win_scroll_marker_keep(100.0f, -1.0f, dpi));
        CHECK(!spdf_win_scroll_marker_keep(100.0f, 100.0f, dpi));
        CHECK(!spdf_win_scroll_marker_keep(100.0f + gap - 1.0f, 100.0f, dpi));
        CHECK(spdf_win_scroll_marker_keep(100.0f + gap, 100.0f, dpi));
        CHECK(spdf_win_scroll_marker_keep(100.0f + gap + 50.0f, 100.0f, dpi));
    }
}

/* --- degenerate input ---------------------------------------------------- */

/* The header's stated contract: none of this may produce a NaN, a rect outside
 * the track, or a division by zero. A NaN is the dangerous one -- it draws
 * nothing, reports nothing and poisons every later comparison. */
static void test_degenerate(void) {
    SpdfWinChromeRect track;
    SpdfWinChromeRect zero = spdf_win_chrome_zero();
    float nan_f = 0.0f;
    float bad[6];
    int i, j, axis;

    /* Built rather than written as a literal: MSVC rejects 0.0f/0.0f as a
     * constant expression. */
    {
        volatile float z = 0.0f;
        nan_f = z / z;
    }
    CHECK(!finite_f(nan_f)); /* the fixture itself is what we think it is */

    track.x = 100.0f;
    track.y = 50.0f;
    track.w = 15.0f;
    track.h = 400.0f;

    bad[0] = -1.0f;
    bad[1] = 0.0f;
    bad[2] = 1.0f;
    bad[3] = 2.0f;
    bad[4] = 1e30f;
    bad[5] = nan_f;

    for (axis = 0; axis < 2; ++axis) {
        for (i = 0; i < 6; ++i) {
            for (j = 0; j < 6; ++j) {
                SpdfWinChromeRect thumb = spdf_win_scroll_thumb(track, bad[i], bad[j], 24.0f, axis);
                CHECK(rect_finite(thumb));
                CHECK(inside(thumb, track));
                CHECK(finite_f(spdf_win_scroll_travel(track, bad[j], 24.0f, axis)));
                CHECK(finite_f(spdf_win_scroll_drag_pos(track, bad[i], bad[j], 24.0f, bad[i] * 100.0f, axis)));
                CHECK(finite_f(spdf_win_scroll_pos_at(track, bad[j], 24.0f, bad[i], axis)));
                CHECK(rect_finite(spdf_win_scroll_marker_rect(track, bad[i], j & 1, 1.0f)));
                CHECK(inside(spdf_win_scroll_marker_rect(track, bad[i], j & 1, 1.0f), track));
            }
            /* A zero-height track: no thumb at all, no hit, no marker, and above
             * all no division. */
            CHECK(spdf_win_chrome_rect_empty(spdf_win_scroll_thumb(zero, bad[i], 0.3f, 24.0f, axis)));
            CHECK_EQF(spdf_win_scroll_travel(zero, 0.3f, 24.0f, axis), 0.0f);
            CHECK_EQI(spdf_win_scroll_hit(zero, bad[i], 0.3f, 24.0f, 0.0f, 0.0f, axis), SPDF_WIN_SCROLL_NONE);
            CHECK(finite_f(spdf_win_scroll_drag_pos(zero, bad[i], 0.3f, 24.0f, 10.0f, axis)));
        }
        /* A minimum thumb longer than the whole track clamps to the track rather
         * than producing a thumb that hangs off it. This is the 560 x 380
         * minimum window with both panels open: the trough gets short. */
        {
            SpdfWinChromeRect thumb = spdf_win_scroll_thumb(track, 0.5f, 0.01f, 10000.0f, axis);
            CHECK(inside(thumb, track));
            CHECK_EQF(spdf_win_scroll_len(thumb, axis), spdf_win_scroll_len(track, axis));
        }
        /* And a negative one behaves like no minimum at all. */
        CHECK(inside(spdf_win_scroll_thumb(track, 0.5f, 0.5f, -50.0f, axis), track));
    }

    /* A zero and a negative DPI must not divide or produce a zero-size marker;
     * spdf_win_chrome_px() already treats both as 1. */
    CHECK(rect_finite(spdf_win_scroll_track(track, 0.0f, SPDF_WIN_SCROLL_V)));
    CHECK(rect_finite(spdf_win_scroll_marker_rect(track, 0.5f, 1, -2.0f)));
    CHECK(spdf_win_scroll_thumb_min(0.0f) > 0.0f);
}

/* --- the narrowest window the app allows --------------------------------- */

/* 560 x 380 is macOS's contentMinSize and now Windows' WM_GETMINMAXINFO floor.
 * With both panels open there is very little canvas left, and the scroller must
 * still be coherent there rather than only in a 1120 pt window. */
static void test_minimum_window(float dpi) {
    SpdfWinChromeModel m;
    SpdfWinChromeLayout l;
    SpdfWinChromeRect track, thumb;

    memset(&m, 0, sizeof(m));
    m.show_sidebar = 1;
    m.show_minimap = 1;
    m.selected_tab = -1;
    m.hot_tab = -1;
    m.hot_close = -1;
    spdf_win_chrome_layout(&m, (unsigned)(SPDF_WIN_CHROME_MIN_CONTENT_W * dpi),
                           (unsigned)(SPDF_WIN_CHROME_MIN_CONTENT_H * dpi), dpi, &l);
    if (spdf_win_chrome_rect_empty(l.vscroll)) {
        /* Legitimately absent: spdf_win_chrome.h drops the scroller on a canvas
         * narrower than three of them. Pinned as a check so the case is
         * observed rather than silently skipped. */
        CHECK(l.canvas.w <= spdf_win_chrome_px(SPDF_WIN_CHROME_SCROLLBAR_W, dpi) * 3.0f);
        return;
    }
    track = spdf_win_scroll_track(l.vscroll, dpi, SPDF_WIN_SCROLL_V);
    thumb = spdf_win_scroll_thumb(track, 1.0f, 0.02f, spdf_win_scroll_thumb_min(dpi), SPDF_WIN_SCROLL_V);
    CHECK(inside(thumb, track));
    CHECK(inside(thumb, l.vscroll));
    CHECK(spdf_win_scroll_len(thumb, SPDF_WIN_SCROLL_V) > 0.0f);
}

int main(void) {
    float scales[3];
    int i;
    scales[0] = 1.0f;
    scales[1] = 1.5f; /* this machine's own 144 dpi -- the fractional case */
    scales[2] = 2.0f;

    for (i = 0; i < 3; ++i) {
        test_track(scales[i]);
        test_thumb_properties(scales[i]);
        test_round_trip(scales[i]);
        test_hit_partitions_the_track(scales[i]);
        test_thumb_visual(scales[i]);
        test_markers(scales[i]);
        test_minimum_window(scales[i]);
    }
    test_full_and_unknown();
    test_drag();
    test_degenerate();

    printf("chrome_scroll_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
