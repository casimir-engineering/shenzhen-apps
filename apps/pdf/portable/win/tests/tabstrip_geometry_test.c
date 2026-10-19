/* tabstrip_geometry_test.c — pins portable/win/src/spdf_win_tabstrip.h.
 *
 * The tab strip's geometry is transcribed from macOS rather than invented
 * (portable/mac/SPDFMacTabStripView.mm, SPDFMacTabStripGeometry.h). There is no
 * GTK4 original to differentially test against -- the GTK frontend has no tab
 * strip -- so this suite pins the properties the transcription must have, plus
 * the specific macOS numbers at a known window width. A differential test
 * against the mac source would be better and is not possible from Windows; a
 * property test that would catch a transcription slip is what is available.
 *
 * Header-only under test, so there is no extra translation unit:
 * no `spdf-test-sources` line is needed.
 */
#include "spdf_win_tabstrip.h"
#include "spdf_win_tabs_drag.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

static void fail(const char* what, const char* file, int line) {
    fprintf(stderr, "FAIL %s (%s:%d)\n", what, file, line);
    ++g_failures;
}

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) fail(#cond, __FILE__, __LINE__);                                                                   \
    } while (0)

#define CHECK_NEAR(a, b)                                                                                               \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (fabs((double)(a) - (double)(b)) > 1e-9) {                                                                  \
            fprintf(stderr, "FAIL %s == %s (%.17g vs %.17g) (%s:%d)\n", #a, #b, (double)(a), (double)(b), __FILE__,     \
                    __LINE__);                                                                                         \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* --- the strip's own metrics agree with the macOS constants --------------- */
static void test_metrics(void) {
    CHECK_NEAR(SPDF_WIN_TABSTRIP_HEIGHT, 42.0);
    CHECK_NEAR(SPDF_WIN_TABSTRIP_TAB_GAP, 6.0);
    CHECK_NEAR(SPDF_WIN_TABSTRIP_TAB_MIN_VISIBLE_WIDTH, 112.0);
    CHECK_NEAR(SPDF_WIN_TABSTRIP_TAB_MAX_WIDTH, 320.0);
    CHECK_NEAR(SPDF_WIN_TABSTRIP_CONTROL_WIDTH, 32.0);
    CHECK_NEAR(SPDF_WIN_TABSTRIP_TAB_Y, 7.0);
    CHECK_NEAR(SPDF_WIN_TABSTRIP_TAB_HEIGHT, 28.0);
    CHECK_NEAR(SPDF_WIN_TABSTRIP_READONLY_DOT_DIAMETER, 7.0);
    CHECK_NEAR(SPDF_WIN_TABSTRIP_CLOSE_DIAMETER, 16.0);

    /* The tab body must fit inside the strip with equal air above and below:
     * 7 + 28 + 7 = 42. If someone changes the height and forgets the y, this
     * is the check that notices. */
    CHECK_NEAR(SPDF_WIN_TABSTRIP_TAB_Y * 2.0 + SPDF_WIN_TABSTRIP_TAB_HEIGHT, SPDF_WIN_TABSTRIP_HEIGHT);

    /* macOS derives the read-only title inset as 6.0 + 7.0 + 2.5 = 15.5. */
    CHECK_NEAR(spdf_win_tabstrip_title_left_inset(1), 15.5);
    CHECK_NEAR(spdf_win_tabstrip_title_left_inset(0), 12.0);
}

/* --- one tab in a default-sized window ----------------------------------- */
static void test_single_tab(void) {
    /* 1120 is the macOS default content width (ShenzhenPDFMac.mm:2912-2938). */
    const double w = 1120.0;
    SpdfWinTabRect tab, plus;

    CHECK(spdf_win_tabstrip_has_overflow(w, 1) == 0);
    CHECK(spdf_win_tabstrip_has_overflow(w, 0) == 0);

    tab = spdf_win_tabstrip_tab_rect(w, 1, 0, 0);
    CHECK(!spdf_win_tabstrip_rect_is_empty(tab));
    CHECK_NEAR(tab.x, SPDF_WIN_TABSTRIP_LEADING_INSET);
    CHECK_NEAR(tab.y, 7.0);
    CHECK_NEAR(tab.h, 28.0);
    /* A single tab is capped at kTabMaxWidth however wide the window is. */
    CHECK_NEAR(tab.w, SPDF_WIN_TABSTRIP_TAB_MAX_WIDTH);

    /* An index outside the tab count has no rect. */
    CHECK(spdf_win_tabstrip_rect_is_empty(spdf_win_tabstrip_tab_rect(w, 1, 0, 1)));
    CHECK(spdf_win_tabstrip_rect_is_empty(spdf_win_tabstrip_tab_rect(w, 1, 0, -1)));

    /* The + button sits just left of the caption-button reserve -- 42 pt from
     * its edge, as macOS pins it 42 pt from the window's -- and never overlaps
     * the tabs. */
    plus = spdf_win_tabstrip_plus_rect(w);
    CHECK_NEAR(plus.w, 32.0);
    CHECK_NEAR(plus.h, 28.0);
    CHECK_NEAR(plus.x, w - SPDF_WIN_TABSTRIP_TRAILING_INSET - 42.0);
    CHECK(plus.x + plus.w <= w - SPDF_WIN_TABSTRIP_TRAILING_INSET);
    CHECK(tab.x + tab.w <= plus.x);

    /* With no overflow there is no overflow button. */
    CHECK(spdf_win_tabstrip_rect_is_empty(spdf_win_tabstrip_overflow_rect(w, 1)));
}

/* --- the caption buttons: three, 46 wide, full height, flush right --------- */
static void test_caption_buttons(void) {
    const double w = 1120.0, h = SPDF_WIN_TABSTRIP_HEIGHT;
    SpdfWinTabRect mn = spdf_win_tabstrip_caption_rect(w, h, SPDF_WIN_CAPTION_MINIMIZE);
    SpdfWinTabRect mx = spdf_win_tabstrip_caption_rect(w, h, SPDF_WIN_CAPTION_MAXIMIZE);
    SpdfWinTabRect cl = spdf_win_tabstrip_caption_rect(w, h, SPDF_WIN_CAPTION_CLOSE);

    /* 3 x 46 = 138: macOS's windowed traffic-light reserve, mirrored. */
    CHECK_NEAR(SPDF_WIN_TABSTRIP_TRAILING_INSET, 138.0);
    CHECK_NEAR(SPDF_WIN_TABSTRIP_CAPTION_BUTTON_W, 46.0);

    CHECK_NEAR(cl.x + cl.w, w);
    CHECK_NEAR(mx.x + mx.w, cl.x);
    CHECK_NEAR(mn.x + mn.w, mx.x);
    CHECK_NEAR(mn.x, w - SPDF_WIN_TABSTRIP_TRAILING_INSET);
    CHECK_NEAR(mn.y, 0.0);
    CHECK_NEAR(mn.h, h);
    CHECK_NEAR(cl.h, h);

    /* Hit-testing agrees with the rects, edge-inclusive on the left. */
    CHECK(spdf_win_tabstrip_caption_hit(w, h, mn.x, 0.0) == SPDF_WIN_CAPTION_MINIMIZE);
    CHECK(spdf_win_tabstrip_caption_hit(w, h, mx.x + 23.0, 41.0) == SPDF_WIN_CAPTION_MAXIMIZE);
    CHECK(spdf_win_tabstrip_caption_hit(w, h, w - 1.0, 20.0) == SPDF_WIN_CAPTION_CLOSE);
    CHECK(spdf_win_tabstrip_caption_hit(w, h, mn.x - 1.0, 20.0) == SPDF_WIN_CAPTION_NONE);
    CHECK(spdf_win_tabstrip_caption_hit(w, h, w, 20.0) == SPDF_WIN_CAPTION_NONE);
    CHECK(spdf_win_tabstrip_caption_hit(w, h, w - 1.0, h) == SPDF_WIN_CAPTION_NONE);

    /* The reserve never collides with the controls left of it. */
    {
        SpdfWinTabRect plus = spdf_win_tabstrip_plus_rect(w);
        SpdfWinTabRect ov = spdf_win_tabstrip_overflow_rect(w, 40);
        CHECK(plus.x + plus.w <= mn.x);
        CHECK(ov.x + ov.w <= plus.x);
    }

    /* Degenerate input: NONE and out-of-range buttons have no rect, and a strip
     * narrower than the reserve has no buttons rather than buttons off its left
     * edge. */
    CHECK(spdf_win_tabstrip_rect_is_empty(spdf_win_tabstrip_caption_rect(w, h, SPDF_WIN_CAPTION_NONE)));
    CHECK(spdf_win_tabstrip_rect_is_empty(spdf_win_tabstrip_caption_rect(w, h, 4)));
    CHECK(spdf_win_tabstrip_rect_is_empty(spdf_win_tabstrip_caption_rect(100.0, h, SPDF_WIN_CAPTION_CLOSE)));
    CHECK(spdf_win_tabstrip_caption_hit(100.0, h, 90.0, 20.0) == SPDF_WIN_CAPTION_NONE);
}

/* --- tabs are laid out left to right, gap exactly kTabGap ---------------- */
static void test_gaps_and_order(void) {
    const double w = 1120.0;
    int counts[] = {2, 3, 4, 5, 8};
    size_t c;

    for (c = 0; c < sizeof(counts) / sizeof(counts[0]); ++c) {
        int n = counts[c];
        int start = 0, visible = 0, i;
        double expect_w = spdf_win_tabstrip_tab_width(w, n, 0);
        spdf_win_tabstrip_visible_range(w, n, 0, &start, &visible);
        CHECK(visible >= 1);
        CHECK(start >= 0);
        CHECK(start + visible <= n);

        for (i = start; i + 1 < start + visible; ++i) {
            SpdfWinTabRect a = spdf_win_tabstrip_tab_rect(w, n, 0, i);
            SpdfWinTabRect b = spdf_win_tabstrip_tab_rect(w, n, 0, i + 1);
            if (spdf_win_tabstrip_rect_is_empty(a) || spdf_win_tabstrip_rect_is_empty(b)) continue;
            /* strictly increasing */
            CHECK(b.x > a.x);
            /* the gap between consecutive tabs is exactly kTabGap, except
             * where the final tab was truncated against the tab area */
            if (a.w >= expect_w - 1e-9) CHECK_NEAR(b.x - (a.x + a.w), SPDF_WIN_TABSTRIP_TAB_GAP);
            /* no overlap, ever */
            CHECK(a.x + a.w <= b.x);
        }
    }
}

/* --- overflow: many tabs stay at least kTabMinVisibleWidth wide ---------- */
static void test_overflow(void) {
    const double w = 1120.0;
    int start = 0, visible = 0;

    /* 40 tabs cannot fit in 1120pt at 112pt minimum, so overflow engages. */
    CHECK(spdf_win_tabstrip_has_overflow(w, 40) == 1);
    CHECK(!spdf_win_tabstrip_rect_is_empty(spdf_win_tabstrip_overflow_rect(w, 40)));

    spdf_win_tabstrip_visible_range(w, 40, 20, &start, &visible);
    CHECK(visible >= 1);
    CHECK(visible < 40);
    /* the window contains the selected tab */
    CHECK(20 >= start);
    CHECK(20 < start + visible);

    /* Selecting the first tab pins the window to the left edge... */
    spdf_win_tabstrip_visible_range(w, 40, 0, &start, &visible);
    CHECK(start == 0);
    /* ...and the last tab pins it to the right. */
    spdf_win_tabstrip_visible_range(w, 40, 39, &start, &visible);
    CHECK(start + visible == 40);

    /* Every visible tab is at least the minimum width (that is what capacity
     * is computed from) and the overflow button never overlaps a tab. */
    {
        SpdfWinTabRect ov = spdf_win_tabstrip_overflow_rect(w, 40);
        SpdfWinTabRect plus = spdf_win_tabstrip_plus_rect(w);
        int i;
        spdf_win_tabstrip_visible_range(w, 40, 20, &start, &visible);
        for (i = start; i < start + visible; ++i) {
            SpdfWinTabRect t = spdf_win_tabstrip_tab_rect(w, 40, 20, i);
            if (spdf_win_tabstrip_rect_is_empty(t)) continue;
            CHECK(t.x + t.w <= ov.x);
        }
        CHECK(ov.x + ov.w <= plus.x);
    }
}

/* --- a window too narrow for anything must still not misbehave ----------- */
static void test_degenerate_widths(void) {
    double widths[] = {0.0, 1.0, 40.0, 80.0, 120.0, 200.0};
    size_t i;
    for (i = 0; i < sizeof(widths) / sizeof(widths[0]); ++i) {
        double w = widths[i];
        int n, start = 0, visible = 0;
        for (n = 0; n <= 6; ++n) {
            int j;
            spdf_win_tabstrip_visible_range(w, n, 0, &start, &visible);
            CHECK(start >= 0);
            CHECK(visible >= 0);
            CHECK(start + visible <= (n > 0 ? n : 0));
            /* No rect may be negative-width or run off the left edge. */
            for (j = 0; j < n; ++j) {
                SpdfWinTabRect t = spdf_win_tabstrip_tab_rect(w, n, 0, j);
                CHECK(t.w >= 0.0);
                CHECK(t.h >= 0.0);
                if (!spdf_win_tabstrip_rect_is_empty(t)) CHECK(t.x >= 0.0);
            }
            /* Hit testing must never return an out-of-range index. */
            {
                int hit = spdf_win_tabstrip_hit(w, SPDF_WIN_TABSTRIP_HEIGHT, n, 0, 20.0, 20.0);
                CHECK(hit >= -1);
                CHECK(hit < n);
            }
        }
    }
}

/* --- close button lies inside its tab, and only where it is drawn -------- */
static void test_close_button(void) {
    const double w = 1120.0;
    SpdfWinTabRect tab = spdf_win_tabstrip_tab_rect(w, 3, 0, 0);
    SpdfWinTabRect close = spdf_win_tabstrip_close_rect(tab);

    CHECK(!spdf_win_tabstrip_rect_is_empty(close));
    /* wholly inside the tab */
    CHECK(close.x >= tab.x);
    CHECK(close.x + close.w <= tab.x + tab.w);
    CHECK(close.y >= tab.y);
    CHECK(close.y + close.h <= tab.y + tab.h);
    /* vertically centred */
    CHECK_NEAR(close.y + close.h / 2.0, tab.y + tab.h / 2.0);
    /* right edge 26pt in from the tab's trailing edge, per macOS */
    CHECK_NEAR(tab.x + tab.w - close.x, SPDF_WIN_TABSTRIP_CLOSE_RIGHT_EDGE_INSET);

    /* A click in the middle of the close circle reports that tab... */
    CHECK(spdf_win_tabstrip_close_hit(w, 3, 0, close.x + close.w / 2.0, close.y + close.h / 2.0) == 0);
    /* ...and a click at the tab's left edge does not. */
    CHECK(spdf_win_tabstrip_close_hit(w, 3, 0, tab.x + 2.0, tab.y + tab.h / 2.0) == -1);

    /* An empty tab rect yields no close rect rather than a bogus one. */
    CHECK(spdf_win_tabstrip_rect_is_empty(spdf_win_tabstrip_close_rect(spdf_win_tabstrip_zero_rect())));
}

/* --- read-only dot ------------------------------------------------------- */
static void test_readonly_dot(void) {
    SpdfWinTabRect tab = spdf_win_tabstrip_tab_rect(1120.0, 3, 0, 0);
    SpdfWinTabRect dot = spdf_win_tabstrip_readonly_dot_rect(tab);
    CHECK(!spdf_win_tabstrip_rect_is_empty(dot));
    CHECK_NEAR(dot.w, 7.0);
    CHECK_NEAR(dot.x - tab.x, SPDF_WIN_TABSTRIP_READONLY_DOT_LEFT_INSET);
    CHECK_NEAR(dot.y + dot.h / 2.0, tab.y + tab.h / 2.0);
    /* The dot must sit left of where the title starts when it is shown. */
    CHECK(dot.x + dot.w <= tab.x + spdf_win_tabstrip_title_left_inset(1));
}

/* --- hit testing is forgiving vertically, and round-trips ---------------- */
static void test_hit_testing(void) {
    const double w = 1120.0;
    const double h = SPDF_WIN_TABSTRIP_HEIGHT;
    int n = 4, i;

    for (i = 0; i < n; ++i) {
        SpdfWinTabRect t = spdf_win_tabstrip_tab_rect(w, n, 0, i);
        if (spdf_win_tabstrip_rect_is_empty(t)) continue;
        /* centre of the tab */
        CHECK(spdf_win_tabstrip_hit(w, h, n, 0, t.x + t.w / 2.0, t.y + t.h / 2.0) == i);
        /* the very top and bottom of the strip still hit it: the interaction
         * rect is the full strip height, not the tab's 28pt */
        CHECK(spdf_win_tabstrip_hit(w, h, n, 0, t.x + t.w / 2.0, 0.5) == i);
        CHECK(spdf_win_tabstrip_hit(w, h, n, 0, t.x + t.w / 2.0, h - 0.5) == i);
    }

    /* Left of the leading inset, past the slop, is not a tab. */
    CHECK(spdf_win_tabstrip_hit(w, h, n, 0, 1.0, h / 2.0) == -1);
    /* Far right, beyond the + button, is not a tab. */
    CHECK(spdf_win_tabstrip_hit(w, h, n, 0, w - 2.0, h / 2.0) == -1);
    /* No tabs at all: nothing is hit. */
    CHECK(spdf_win_tabstrip_hit(w, h, 0, -1, 100.0, h / 2.0) == -1);
}

/* --- drop slots ---------------------------------------------------------- */
static void test_drop_slot(void) {
    const double w = 1120.0;
    int n = 4;
    SpdfWinTabRect first = spdf_win_tabstrip_tab_rect(w, n, 0, 0);
    SpdfWinTabRect last = spdf_win_tabstrip_tab_rect(w, n, 0, n - 1);
    int start = 0, visible = 0;
    spdf_win_tabstrip_visible_range(w, n, 0, &start, &visible);

    /* Left of the first tab's midpoint -> slot 0. */
    CHECK(spdf_win_tabstrip_drop_slot(w, n, 0, first.x + 1.0) == 0);
    /* Right of the last tab's midpoint -> after the last visible tab. */
    CHECK(spdf_win_tabstrip_drop_slot(w, n, 0, last.x + last.w - 1.0) == visible);
    /* Just past the first tab's midpoint -> slot 1. */
    CHECK(spdf_win_tabstrip_drop_slot(w, n, 0, first.x + first.w / 2.0 + 1.0) == 1);
    /* Degenerate: no tabs -> slot 0. */
    CHECK(spdf_win_tabstrip_drop_slot(w, 0, -1, 100.0) == 0);
}

/* --- the drop indicator sits in the gap ---------------------------------- */
static void test_drop_indicator(void) {
    const double w = 1120.0;
    int n = 3, visible = 0, start = 0;
    SpdfWinTabRect t0 = spdf_win_tabstrip_tab_rect(w, n, 0, 0);
    SpdfWinTabRect t1 = spdf_win_tabstrip_tab_rect(w, n, 0, 1);
    SpdfWinTabRect t2 = spdf_win_tabstrip_tab_rect(w, n, 0, 2);
    SpdfWinTabRect r;
    spdf_win_tabstrip_visible_range(w, n, 0, &start, &visible);
    CHECK(visible == 3);

    /* Between tab 0 and tab 1: centred in the 6 pt gap, 2 pt wide, tab height. */
    r = spdf_win_tabstrip_drop_indicator_rect(w, n, 0, 1);
    CHECK_NEAR(r.x + r.w / 2.0, (t0.x + t0.w + t1.x) / 2.0);
    CHECK_NEAR(r.w, SPDF_WIN_TABSTRIP_DROP_INDICATOR_WIDTH);
    CHECK_NEAR(r.y, SPDF_WIN_TABSTRIP_TAB_Y);
    CHECK_NEAR(r.h, SPDF_WIN_TABSTRIP_TAB_HEIGHT);
    /* The end slots: half a gap outside the first / last tab (:19-20). */
    r = spdf_win_tabstrip_drop_indicator_rect(w, n, 0, 0);
    CHECK_NEAR(r.x + r.w / 2.0, t0.x - SPDF_WIN_TABSTRIP_TAB_GAP / 2.0);
    r = spdf_win_tabstrip_drop_indicator_rect(w, n, 0, 3);
    CHECK_NEAR(r.x + r.w / 2.0, t2.x + t2.w + SPDF_WIN_TABSTRIP_TAB_GAP / 2.0);
    /* Out of range, or nothing visible: empty, and the painter draws nothing. */
    CHECK(spdf_win_tabstrip_rect_is_empty(spdf_win_tabstrip_drop_indicator_rect(w, n, 0, 4)));
    CHECK(spdf_win_tabstrip_rect_is_empty(spdf_win_tabstrip_drop_indicator_rect(w, n, 0, -1)));
    CHECK(spdf_win_tabstrip_rect_is_empty(spdf_win_tabstrip_drop_indicator_rect(w, 0, -1, 0)));
}

/* --- when a drag leaves the strip (SPDFMacTabStripView.mm:1012-1014) ------ */
static void test_drag_detaches(void) {
    const double w = 1120.0, h = SPDF_WIN_TABSTRIP_HEIGHT;
    SpdfWinTabRect plus = spdf_win_tabstrip_plus_rect(w);
    /* Sliding along the strip is a reorder. */
    CHECK(!spdf_win_tabstrip_drag_detaches(w, h, 300.0, 20.0, 20.0));
    CHECK(!spdf_win_tabstrip_drag_detaches(w, h, 300.0, -20.0, 20.0));
    CHECK(!spdf_win_tabstrip_drag_detaches(w, h, 300.0, h + 20.0, 20.0));
    /* More than 24 pt outside the strip vertically, or 18 pt outside the tab
     * area horizontally, or 48 pt from where the drag began: a detach. */
    CHECK(spdf_win_tabstrip_drag_detaches(w, h, 300.0, -25.0, 20.0));
    CHECK(spdf_win_tabstrip_drag_detaches(w, h, 300.0, h + 25.0, 20.0));
    CHECK(spdf_win_tabstrip_drag_detaches(w, h, SPDF_WIN_TABSTRIP_LEADING_INSET - 19.0, 20.0, 20.0));
    CHECK(spdf_win_tabstrip_drag_detaches(w, h, plus.x + plus.w + 19.0, 20.0, 20.0));
    CHECK(spdf_win_tabstrip_drag_detaches(w, h, 300.0, 20.0, 20.0 + 49.0));
}

/* --- the chip style is the mac's (SPDFMacTabStripStyle.mm) ---------------- */
static void test_tab_style(void) {
    SpdfWinTabStyle s = spdf_win_tab_style_for_state(0, 0);
    /* EVERY tab is outlined: the unselected present tab has a stroke now. */
    CHECK(s.stroke_role == SPDF_WIN_TAB_ROLE_SEPARATOR);
    CHECK_NEAR(s.stroke_alpha, 0.26);
    CHECK_NEAR(s.stroke_width, 1.0);
    CHECK(s.fill_role == SPDF_WIN_TAB_ROLE_CONTROL_BACKGROUND);
    CHECK_NEAR(s.fill_alpha, 0.0);
    s = spdf_win_tab_style_for_state(1, 0);
    CHECK(s.fill_role == SPDF_WIN_TAB_ROLE_ACCENT && s.stroke_role == SPDF_WIN_TAB_ROLE_ACCENT);
    CHECK_NEAR(s.fill_alpha, 0.34);
    CHECK_NEAR(s.stroke_alpha, 0.95);
    CHECK_NEAR(s.stroke_width, 2.0); /* twice the neutral width */
    s = spdf_win_tab_style_for_state(0, 1);
    CHECK(s.fill_role == SPDF_WIN_TAB_ROLE_ALERT && s.stroke_role == SPDF_WIN_TAB_ROLE_ALERT);
    CHECK_NEAR(s.fill_alpha, 0.22);
    CHECK_NEAR(s.stroke_alpha, 0.65);
    CHECK_NEAR(s.stroke_width, 1.0);
    s = spdf_win_tab_style_for_state(1, 1);
    CHECK_NEAR(s.fill_alpha, 0.36);
    CHECK_NEAR(s.stroke_alpha, 0.95);
    CHECK_NEAR(s.stroke_width, 2.0);
    /* Half the width, so the centreline lands on a pixel at 1x and 2x. */
    CHECK_NEAR(spdf_win_tab_stroke_inset(2.0), 1.0);
    CHECK_NEAR(spdf_win_tab_stroke_inset(1.0), 0.5);
    /* kSPDFTabCornerRadius is 10 since the outline became visible. */
    CHECK_NEAR(SPDF_WIN_TABSTRIP_TAB_RADIUS, 10.0);
}

/* --- same-window move index --------------------------------------------- */
static void test_move_index(void) {
    /* Both gaps adjacent to the source collapse to a no-op. This is the
     * property SPDFMacTabStripGeometry.h calls out, and the one a naive
     * remove-then-insert gets wrong. */
    CHECK(spdf_win_tabstrip_move_index(2, 2, 5) == 2);
    CHECK(spdf_win_tabstrip_move_index(3, 2, 5) == 2);

    /* Moving left. */
    CHECK(spdf_win_tabstrip_move_index(0, 2, 5) == 0);
    CHECK(spdf_win_tabstrip_move_index(1, 2, 5) == 1);
    /* Moving right past one neighbour. */
    CHECK(spdf_win_tabstrip_move_index(4, 2, 5) == 3);
    /* To the very end. */
    CHECK(spdf_win_tabstrip_move_index(5, 2, 5) == 4);

    /* Degenerate input returns the source, so a bad slot never moves a tab. */
    CHECK(spdf_win_tabstrip_move_index(3, -1, 5) == -1);
    CHECK(spdf_win_tabstrip_move_index(3, 9, 5) == 9);
    CHECK(spdf_win_tabstrip_move_index(0, 0, 1) == 0);
    CHECK(spdf_win_tabstrip_move_index(0, 0, 0) == 0);

    /* Out-of-range insertion clamps rather than producing a bad index. */
    CHECK(spdf_win_tabstrip_move_index(-5, 2, 5) == 0);
    CHECK(spdf_win_tabstrip_move_index(99, 2, 5) == 4);
}

/* --- widening a window that already shows every tab widens the tabs ------ */
static void test_width_monotonicity(void) {
    int n = 3;
    double prev = -1.0;
    double w;
    for (w = 600.0; w <= 2000.0; w += 50.0) {
        double tw = spdf_win_tabstrip_tab_width(w, n, 0);
        CHECK(tw >= SPDF_WIN_TABSTRIP_TAB_MIN_VISIBLE_WIDTH || tw <= SPDF_WIN_TABSTRIP_TAB_MAX_WIDTH);
        CHECK(tw <= SPDF_WIN_TABSTRIP_TAB_MAX_WIDTH);
        /* never narrows as the window grows */
        CHECK(tw >= prev - 1e-9);
        prev = tw;
    }
    /* and it saturates at the cap */
    CHECK_NEAR(spdf_win_tabstrip_tab_width(4000.0, n, 0), SPDF_WIN_TABSTRIP_TAB_MAX_WIDTH);
}

int main(void) {
    test_metrics();
    test_single_tab();
    test_caption_buttons();
    test_gaps_and_order();
    test_overflow();
    test_degenerate_widths();
    test_close_button();
    test_readonly_dot();
    test_hit_testing();
    test_drop_slot();
    test_drop_indicator();
    test_drag_detaches();
    test_tab_style();
    test_move_index();
    test_width_monotonicity();

    printf("tabstrip_geometry_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
