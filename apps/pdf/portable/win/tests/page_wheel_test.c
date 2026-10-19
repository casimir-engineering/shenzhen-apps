/* page_wheel_test.c -- Alt + wheel = the page arrows, paging by travel
 * (portable/win/src/spdf_win_page_wheel.h).
 *
 * The mac's SPDFMacPageWheelTests.mm transcribed, in Windows units: one notch
 * of scroll distance is one page, a fast spin earns several, the remainder
 * carries, a pause drops a part-page, a reversal drops the abandoned direction,
 * one enormous delta is capped, and the modifier must not collide with Ctrl,
 * which already means zoom. Header-only under test, so no spdf-test-sources
 * line; the window's modifier bits are included only to pin that the two
 * headers agree on their numbers.
 */
#include "spdf_win_page_wheel.h"
#include "spdf_win_window.h" /* SPDF_WIN_MOD_* -- the bits an input carries */

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

#define CHECK_EQI(a, b)                                                                                                \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if ((int)(a) != (int)(b)) {                                                                                     \
            fprintf(stderr, "FAIL %s == %s (%d vs %d) (%s:%d)\n", #a, #b, (int)(a), (int)(b), __FILE__, __LINE__);      \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* One notch of scroll distance at the Windows default: 3 lines x 20 px x 1.0. */
#define NOTCH 60.0
/* Positive advances the document (the scroll offset's own sign). */
#define FORWARD (NOTCH)
#define BACK (-NOTCH)

static void test_modifiers(void) {
    /* The two headers must agree on the bits, or an input's `mods` would be
     * read wrong without any compiler noticing. */
    CHECK_EQI(SPDF_WIN_PAGE_WHEEL_MOD_CTRL, SPDF_WIN_MOD_CTRL);
    CHECK_EQI(SPDF_WIN_PAGE_WHEEL_MOD_SHIFT, SPDF_WIN_MOD_SHIFT);
    CHECK_EQI(SPDF_WIN_PAGE_WHEEL_MOD_ALT, SPDF_WIN_MOD_ALT);

    CHECK(spdf_win_page_wheel_modifiers_page(SPDF_WIN_MOD_ALT));
    CHECK(!spdf_win_page_wheel_modifiers_page(0));
    /* Ctrl already means zoom; stealing it would break Ctrl + wheel. */
    CHECK(!spdf_win_page_wheel_modifiers_page(SPDF_WIN_MOD_ALT | SPDF_WIN_MOD_CTRL));
    CHECK(!spdf_win_page_wheel_modifiers_page(SPDF_WIN_MOD_CTRL));
    /* Shift is not a zoom modifier, so it may ride along (the mac's rule). */
    CHECK(spdf_win_page_wheel_modifiers_page(SPDF_WIN_MOD_ALT | SPDF_WIN_MOD_SHIFT));
    CHECK(!spdf_win_page_wheel_modifiers_page(SPDF_WIN_MOD_SHIFT));
}

/* A raw wheel: one notch is one page, every notch. */
static void test_raw_wheel(void) {
    SpdfWinPageWheel s = {0};
    CHECK_EQI(spdf_win_page_wheel_step(&s, FORWARD, NOTCH, 1.00), 1);
    CHECK_EQI(spdf_win_page_wheel_step(&s, FORWARD, NOTCH, 1.05), 1);
    CHECK_EQI(spdf_win_page_wheel_step(&s, BACK, NOTCH, 1.10), -1);
    CHECK_EQI(spdf_win_page_wheel_step(&s, BACK, NOTCH, 1.15), -1);
}

/* THE DEFECT THE MAC'S SECOND COMMIT PINS: a driver that smooths the wheel
 * sends a burst of small deltas per notch. Travel decides, so N notches turn N
 * pages -- and the remainder carries between bursts rather than being lost. */
static void test_smoothed_wheel_keeps_pace(void) {
    SpdfWinPageWheel s = {0};
    int pages = 0, notch, i;
    /* Three notches, ~62 px each, delivered as four smoothed deltas apiece. */
    for (notch = 0; notch < 3; ++notch) {
        const double burst[4] = {4.7, 8.6, 21.4, 27.4};
        for (i = 0; i < 4; ++i)
            pages += spdf_win_page_wheel_step(&s, burst[i], NOTCH, 10.0 + notch * 0.10 + i * 0.02);
    }
    CHECK_EQI(pages, 3);
}

/* A touchpad flick pages by how far it travelled: 0.4 + 24 x 6.4 = 154 px over
 * a 60 px page is two pages, not one -- and the third is still 26 px away. */
static void test_flick_pages_by_travel(void) {
    SpdfWinPageWheel s = {0};
    int turns = 0, i;
    turns += spdf_win_page_wheel_step(&s, 0.4, NOTCH, 10.0);
    for (i = 1; i < 25; ++i) turns += spdf_win_page_wheel_step(&s, 6.4, NOTCH, 10.0 + i * 0.01);
    CHECK_EQI(turns, 2);
    /* A fresh gesture after a pause starts from zero travel, so a small nudge
     * alone is not yet a page... */
    CHECK_EQI(spdf_win_page_wheel_step(&s, 8.0, NOTCH, 12.0), 0);
    /* ...and it pages once the travel adds up (8 + 52 = 60). */
    CHECK_EQI(spdf_win_page_wheel_step(&s, 52.0, NOTCH, 12.02), 1);
}

/* The drain keeps the sign: after 2.5 notches forward, half a notch remains
 * FORWARD, so another half notch pages. Getting the sign backwards grew the
 * accumulator instead (the mac's own regression). */
static void test_remainder_carries_with_its_sign(void) {
    SpdfWinPageWheel s = {0};
    CHECK_EQI(spdf_win_page_wheel_step(&s, 2.5 * NOTCH, NOTCH, 20.0), 2);
    CHECK(fabs(s.accumulator - 0.5 * NOTCH) < 1e-9);
    CHECK_EQI(spdf_win_page_wheel_step(&s, 0.5 * NOTCH, NOTCH, 20.05), 1);
    CHECK(fabs(s.accumulator) < 1e-9);
    /* And the same backwards. */
    CHECK_EQI(spdf_win_page_wheel_step(&s, -2.5 * NOTCH, NOTCH, 20.10), -2);
    CHECK(fabs(s.accumulator + 0.5 * NOTCH) < 1e-9);
    CHECK_EQI(spdf_win_page_wheel_step(&s, -0.5 * NOTCH, NOTCH, 20.15), -1);
}

/* Reversing discards the abandoned direction's travel, then pages the way the
 * wheel now turns. */
static void test_reversal(void) {
    SpdfWinPageWheel s = {0};
    CHECK_EQI(spdf_win_page_wheel_step(&s, 0.8 * NOTCH, NOTCH, 30.0), 0);
    CHECK_EQI(spdf_win_page_wheel_step(&s, -0.5 * NOTCH, NOTCH, 30.05), 0); /* not -1: the 0.8 is gone */
    CHECK_EQI(spdf_win_page_wheel_step(&s, -0.5 * NOTCH, NOTCH, 30.07), -1);
}

/* A pause drops the part-page of travel. */
static void test_pause_drops_leftover(void) {
    SpdfWinPageWheel s = {0};
    CHECK_EQI(spdf_win_page_wheel_step(&s, 0.6 * NOTCH, NOTCH, 40.0), 0);
    /* Just inside the idle window the travel still counts... */
    CHECK_EQI(spdf_win_page_wheel_step(&s, 0.6 * NOTCH, NOTCH, 40.0 + SPDF_WIN_PAGE_WHEEL_IDLE_RESET_S - 0.01), 1);
    /* ...and just past it, it is gone. */
    CHECK_EQI(spdf_win_page_wheel_step(&s, 0.6 * NOTCH, NOTCH, 41.0), 0);
    CHECK_EQI(spdf_win_page_wheel_step(&s, 0.6 * NOTCH, NOTCH, 42.0), 0);
}

/* One enormous delta cannot teleport through the document. */
static void test_huge_delta_is_capped(void) {
    SpdfWinPageWheel s = {0};
    int pages = spdf_win_page_wheel_step(&s, 1000.0 * NOTCH, NOTCH, 50.0);
    CHECK_EQI(pages, SPDF_WIN_PAGE_WHEEL_MAX_PAGES_PER_EVENT);
    CHECK_EQI(spdf_win_page_wheel_step(&s, -1000.0 * NOTCH, NOTCH, 50.05), -SPDF_WIN_PAGE_WHEEL_MAX_PAGES_PER_EVENT);
}

/* Degenerate input. */
static void test_degenerate(void) {
    SpdfWinPageWheel s = {0};
    CHECK_EQI(spdf_win_page_wheel_step(&s, 0.0, NOTCH, 60.0), 0);
    CHECK_EQI(spdf_win_page_wheel_step(NULL, FORWARD, NOTCH, 61.0), 0);
    /* A zero or negative threshold would page on every event; refused. */
    CHECK_EQI(spdf_win_page_wheel_step(&s, FORWARD, 0.0, 62.0), 0);
    CHECK_EQI(spdf_win_page_wheel_step(&s, FORWARD, -1.0, 62.1), 0);
}

/* The notch, in device pixels, as the window derives it (wheel_step in
 * spdf_win_window_input.h): lines x 20 x scale, a screenful under
 * WHEEL_PAGESCROLL, 3 lines when the setting reads 0. */
static void test_notch_px(void) {
    CHECK(fabs(spdf_win_page_wheel_notch_px(3, 1.0, 800) - 60.0) < 1e-9);
    CHECK(fabs(spdf_win_page_wheel_notch_px(3, 1.5, 800) - 90.0) < 1e-9);
    CHECK(fabs(spdf_win_page_wheel_notch_px(1, 2.0, 800) - 40.0) < 1e-9);
    CHECK(fabs(spdf_win_page_wheel_notch_px(0, 1.0, 800) - 60.0) < 1e-9);
    CHECK(fabs(spdf_win_page_wheel_notch_px(SPDF_WIN_PAGE_WHEEL_LINES_PAGESCROLL, 1.0, 800) - 720.0) < 1e-9);
    CHECK(fabs(spdf_win_page_wheel_notch_px(3, 0.0, 800) - 60.0) < 1e-9); /* a zero scale is treated as 1 */
}

int main(void) {
    test_modifiers();
    test_raw_wheel();
    test_smoothed_wheel_keeps_pace();
    test_flick_pages_by_travel();
    test_remainder_carries_with_its_sign();
    test_reversal();
    test_pause_drops_leftover();
    test_huge_delta_is_capped();
    test_degenerate();
    test_notch_px();
    if (g_failures) {
        fprintf(stderr, "page_wheel_test: %d of %d checks failed\n", g_failures, g_checks);
        return 1;
    }
    printf("page_wheel_test: %d checks passed\n", g_checks);
    return 0;
}
