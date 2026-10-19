/* wheel_input_test.c -- pins portable/win/src/spdf_win_wheel.h: what one
 * WM_MOUSEWHEEL is worth when the wheel is not a wheel.
 *
 * WHAT THIS IS EVIDENCE ABOUT. WM_MOUSEWHEEL is documented as delivering
 * multiples of WHEEL_DELTA, and a mouse with a detented wheel obliges. A
 * Windows Precision Touchpad -- which is what a laptop has instead of a mouse
 * -- does not: it reports the finger's travel as a stream of small arbitrary
 * deltas, sends its inertial tail the same way, and delivers its PINCH as
 * Ctrl + wheel with those same small deltas. A viewer that reads the
 * documentation literally and rounds the notch count to an integer converts
 * every one of those events to zero and never moves, however long the reader
 * scrolls. That failure is invisible to a synthetic test, because SendInput's
 * mouse_event sends 120 like a mouse does.
 *
 * So the assertions below are all about the SMALL deltas, and the one that
 * matters most is the sum: a hundred and twenty deltas of 1 must travel exactly
 * as far as one delta of 120. Nothing may be lost per event.
 */
#include "spdf_win_wheel.h"
#include "spdf_win_page_wheel.h"

#include <math.h>
#include <stdio.h>

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

#define CHECK_NEAR(a, b, tol)                                                                                          \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(fabs((double)(a) - (double)(b)) <= (double)(tol))) {                                                      \
            fprintf(stderr, "FAIL %s ~= %s (%.9f vs %.9f) (%s:%d)\n", #a, #b, (double)(a), (double)(b), __FILE__,       \
                    __LINE__);                                                                                         \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* A DETENTED MOUSE, which is the case that always worked. */
static void test_one_notch(void) {
    CHECK_NEAR(spdf_win_wheel_notches(120), 1.0f, 0.0);
    CHECK_NEAR(spdf_win_wheel_notches(-120), -1.0f, 0.0);
    CHECK_NEAR(spdf_win_wheel_distance_px(120, 3, 1.0f, 800), 60.0f, 1e-4);
    /* The DPI scales the distance, so a notch covers the same amount of page at
     * 96 and at 144. */
    CHECK_NEAR(spdf_win_wheel_distance_px(120, 3, 1.5f, 800), 90.0f, 1e-4);
    CHECK_NEAR(spdf_win_wheel_distance_px(120, 3, 2.0f, 800), 120.0f, 1e-4);
    /* And the reader's own setting. */
    CHECK_NEAR(spdf_win_wheel_distance_px(120, 1, 1.0f, 800), 20.0f, 1e-4);
    CHECK_NEAR(spdf_win_wheel_distance_px(120, 10, 1.0f, 800), 200.0f, 1e-4);
}

/* A PRECISION TOUCHPAD. Every one of these deltas is real -- they are what a
 * two-finger drag produces -- and every one of them must move the view. */
static void test_small_deltas_are_not_lost(void) {
    int deltas[] = {1, 2, 3, 5, 8, 13, 17, 40, 119};
    size_t i;
    for (i = 0; i < sizeof(deltas) / sizeof(deltas[0]); ++i) {
        float px = spdf_win_wheel_distance_px(deltas[i], 3, 1.0f, 800);
        /* Non-zero, and in proportion. A rounded notch count gives 0.0f for
         * every entry here, which is the bug this file exists for. */
        CHECK(px > 0.0f);
        CHECK_NEAR(px, 60.0f * (float)deltas[i] / 120.0f, 1e-3);
    }
    /* The smallest delta Windows can send still moves the view by more than the
     * canvas's "did anything change" threshold (0.01 px,
     * spdf_win_canvas_scroll_to), at every scroll-lines setting a reader can
     * choose. Below that the position would drift with no repaint. */
    CHECK(spdf_win_wheel_distance_px(1, 1, 1.0f, 800) > 0.01f);
    CHECK(spdf_win_wheel_distance_px(1, 1, 0.5f, 800) > 0.01f);
}

/* THE SUM. A slow drag delivered as 120 deltas of 1 travels exactly as far as
 * one detent. If anything were dropped or rounded per event, this is where it
 * would show. */
static void test_a_stream_sums_to_a_notch(void) {
    double total = 0.0;
    int i;
    for (i = 0; i < 120; ++i) total += (double)spdf_win_wheel_distance_px(1, 3, 1.5f, 800);
    CHECK_NEAR(total, (double)spdf_win_wheel_distance_px(120, 3, 1.5f, 800), 1e-3);

    /* And a mixed, realistic burst: the deltas a finger actually produces,
     * summing to 120. */
    {
        int burst[] = {3, 7, 12, 18, 21, 19, 15, 11, 8, 4, 2};
        int sum = 0;
        size_t k;
        double travelled = 0.0;
        for (k = 0; k < sizeof(burst) / sizeof(burst[0]); ++k) {
            sum += burst[k];
            travelled += (double)spdf_win_wheel_distance_px(burst[k], 3, 1.0f, 800);
        }
        CHECK(sum == 120);
        CHECK_NEAR(travelled, (double)spdf_win_wheel_distance_px(120, 3, 1.0f, 800), 1e-3);
    }
}

/* THE SETTING THAT IS NOT A NUMBER OF LINES. */
static void test_page_scroll_and_degenerate_settings(void) {
    CHECK_NEAR(spdf_win_wheel_distance_px(120, SPDF_WIN_WHEEL_LINES_PAGESCROLL, 1.0f, 800), 720.0f, 1e-3);
    /* A screenful is a screenful whatever the DPI: the client height is already
     * in device pixels. */
    CHECK_NEAR(spdf_win_wheel_distance_px(120, SPDF_WIN_WHEEL_LINES_PAGESCROLL, 2.0f, 800), 720.0f, 1e-3);
    /* A fractional screenful for a fractional event, like everything else. */
    CHECK_NEAR(spdf_win_wheel_distance_px(12, SPDF_WIN_WHEEL_LINES_PAGESCROLL, 1.0f, 800), 72.0f, 1e-3);
    /* Zero lines from a failed SystemParametersInfo reads as the default 3. */
    CHECK_NEAR(spdf_win_wheel_notch_px(0, 1.0f, 800), spdf_win_wheel_notch_px(3, 1.0f, 800), 0.0);
    /* A zero or negative DPI scale reads as 1, so a caller that has not measured
     * the window yet still scrolls. */
    CHECK_NEAR(spdf_win_wheel_notch_px(3, 0.0f, 800), 60.0f, 0.0);
    CHECK_NEAR(spdf_win_wheel_notch_px(3, -2.0f, 800), 60.0f, 0.0);
}

/* SIGNS. A wheel turned toward the reader is the mirror of one turned away, and
 * a horizontal wheel is the same arithmetic. */
static void test_direction_is_symmetric(void) {
    int deltas[] = {1, 7, 40, 120, 360};
    size_t i;
    for (i = 0; i < sizeof(deltas) / sizeof(deltas[0]); ++i)
        CHECK_NEAR(spdf_win_wheel_distance_px(-deltas[i], 3, 1.0f, 800),
                   -spdf_win_wheel_distance_px(deltas[i], 3, 1.0f, 800), 1e-4);
}

/* CTRL + WHEEL, WHICH IS ALSO THE TOUCHPAD'S PINCH. Geometric, so a gesture
 * split into many small deltas lands where the same travel in one delta would,
 * and out exactly undoes in. */
static void test_zoom_is_geometric(void) {
    double composed = 1.0;
    int i;
    CHECK_NEAR(spdf_win_wheel_zoom_factor(120), 1.1f, 1e-6);
    CHECK_NEAR(spdf_win_wheel_zoom_factor(0), 1.0f, 0.0);
    /* One notch in then one notch out is where you started. */
    CHECK_NEAR((double)spdf_win_wheel_zoom_factor(120) * (double)spdf_win_wheel_zoom_factor(-120), 1.0, 1e-6);
    /* A pinch: 120 deltas of 1 compose to one notch. */
    for (i = 0; i < 120; ++i) composed *= (double)spdf_win_wheel_zoom_factor(1);
    CHECK_NEAR(composed, 1.1, 1e-4);
    /* And the smallest pinch step is still a real change, not a factor of
     * exactly 1 that spdf_win_canvas_set_zoom_at's 1e-9 guard would drop. */
    CHECK(spdf_win_wheel_zoom_factor(1) > 1.0f + 1e-6f);
    CHECK(spdf_win_wheel_zoom_factor(-1) < 1.0f - 1e-6f);
}

/* THE TWO NOTCH FORMULAS MUST AGREE. spdf_win_page_wheel.h keeps its own copy so
 * it can stay free of every include (its header says so); this is what stops the
 * copies from drifting, which would make Alt + wheel page at a different rate
 * than the wheel scrolls. */
static void test_page_wheel_agrees(void) {
    unsigned lines[] = {1u, 3u, 5u, 10u, 0u, SPDF_WIN_WHEEL_LINES_PAGESCROLL};
    float scales[] = {1.0f, 1.25f, 1.5f, 2.0f};
    size_t i, j;
    CHECK(SPDF_WIN_WHEEL_LINES_PAGESCROLL == SPDF_WIN_PAGE_WHEEL_LINES_PAGESCROLL);
    for (i = 0; i < sizeof(lines) / sizeof(lines[0]); ++i)
        for (j = 0; j < sizeof(scales) / sizeof(scales[0]); ++j)
            CHECK_NEAR(spdf_win_wheel_notch_px(lines[i], scales[j], 900),
                       spdf_win_page_wheel_notch_px(lines[i], (double)scales[j], 900), 1e-4);
}

/* ALT + WHEEL OFF A TOUCHPAD. The page policy accumulates, so the same stream of
 * small deltas that scrolls a notch turns exactly one page -- and the leftover
 * carries rather than being dropped. Asserted here as well as in
 * page_wheel_test.c because it is the pair of headers together that has to be
 * right: the window's conversion feeds the accumulator. */
static void test_a_touchpad_stream_turns_one_page(void) {
    SpdfWinPageWheel w;
    double notch = spdf_win_page_wheel_notch_px(3, 1.5, 900);
    int pages = 0;
    int i;
    memset(&w, 0, sizeof(w));
    for (i = 0; i < 120; ++i)
        pages += spdf_win_page_wheel_step(&w, (double)spdf_win_wheel_distance_px(1, 3, 1.5f, 900), notch,
                                          1.0 + (double)i * 0.001);
    CHECK(pages == 1);
    /* A second identical stream turns exactly one more -- the accumulator does
     * not run down or run away. */
    for (i = 0; i < 120; ++i)
        pages += spdf_win_page_wheel_step(&w, (double)spdf_win_wheel_distance_px(1, 3, 1.5f, 900), notch,
                                          1.2 + (double)i * 0.001);
    CHECK(pages == 2);
}

int main(void) {
    test_one_notch();
    test_small_deltas_are_not_lost();
    test_a_stream_sums_to_a_notch();
    test_page_scroll_and_degenerate_settings();
    test_direction_is_symmetric();
    test_zoom_is_geometric();
    test_page_wheel_agrees();
    test_a_touchpad_stream_turns_one_page();

    printf("wheel_input_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
