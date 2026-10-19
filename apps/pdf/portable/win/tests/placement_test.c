/* placement_test.c — the window-placement rules in
 * portable/win/src/spdf_win_placement.h, pinned without a display to plug in.
 *
 * The Windows transcription of the mac's SPDFMacWindowChromeTests cases for
 * spdf_window_frame_is_usable_on_screens and the fallback (96b7e8b7a), on the
 * geometry the defect was found on: a built-in display and an external one
 * mounted above it, so the external frame's y is negative in Windows'
 * virtual-screen coordinates the way it was above the main screen on the mac.
 * Three claims:
 *
 *   1. A frame on an ATTACHED display is usable, whether by identity (the
 *      display's name and rectangle match) or by overlap (a mac-written frame
 *      with no display), and a sliver -- under 80 x 80 inside any work area --
 *      is not.
 *   2. A frame on a MISSING display is not usable, even when its display name
 *      is remembered, and even when a display of the same name is attached
 *      somewhere else (the desktop was rearranged: the overlap rule decides).
 *   3. The fallback is CENTRED in the main display's work area, no bigger than
 *      it, and never the corner a clamp would have produced.
 *   4. A frame is applied as saved only when it is REACHABLE -- its top edge,
 *      the strip that is its title bar, inside a work area it overlaps by the
 *      minimum -- whatever its display's identity says; an unreachable frame
 *      that is still partly on a display is pulled whole into that display's
 *      work area, and one on no display is centred as in 3. Both are parked.
 *      Measured on the 2880 x 1800 desktop (windows-native-observations.md,
 *      section 13): a 60 x 28 corner and a 111 px strip with the title bar
 *      above the screen were both "usable" by the identity rule alone.
 *
 * Header-only under test -- every rule is inline -- so no `spdf-test-sources`
 * line is needed. Exit code is the whole signal: 0 pass, 1 fail.
 */
#include "../src/spdf_win_placement.h"

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

static spdf_win_rect rect(int x, int y, int w, int h) {
    spdf_win_rect r;
    r.x = x;
    r.y = y;
    r.w = w;
    r.h = h;
    return r;
}

static spdf_win_display display(const char* name, spdf_win_rect monitor, int taskbar_h) {
    spdf_win_display d;
    memset(&d, 0, sizeof(d));
    snprintf(d.name, sizeof(d.name), "%s", name);
    d.monitor = monitor;
    d.work = rect(monitor.x, monitor.y, monitor.w, monitor.h - taskbar_h);
    return d;
}

static spdf_win_placement placement(spdf_win_rect frame, const char* name, spdf_win_rect display_rect) {
    spdf_win_placement p;
    memset(&p, 0, sizeof(p));
    p.frame = frame;
    if (name) snprintf(p.display, sizeof(p.display), "%s", name);
    p.display_rect = display_rect;
    return p;
}

/* The real geometry: a 1800 x 1169 built-in at the origin with a 48 px
 * taskbar, and a 3440 x 1440 external mounted above it, so it sits at y -1440. */
static const spdf_win_rect kBuiltIn = {0, 0, 1800, 1169};
static const spdf_win_rect kExternal = {-820, -1440, 3440, 1440};

int main(void) {
    spdf_win_display both[2];
    spdf_win_display builtin_only[1];
    spdf_win_display rearranged[2];
    spdf_win_placement p;
    spdf_win_rect fallback;
    int w, h;

    both[0] = display("\\\\.\\DISPLAY1", kBuiltIn, 48);
    both[1] = display("\\\\.\\DISPLAY2", kExternal, 0);
    builtin_only[0] = both[0];
    /* The same two displays, the external now to the RIGHT of the built-in. */
    rearranged[0] = both[0];
    rearranged[1] = display("\\\\.\\DISPLAY2", rect(1800, 0, 3440, 1440), 0);

    /* --- overlap: the mac's own rule ------------------------------------- */
    spdf_win_rect_overlap(rect(0, 0, 100, 100), rect(50, 50, 100, 100), &w, &h);
    CHECK(w == 50 && h == 50);
    spdf_win_rect_overlap(rect(0, 0, 100, 100), rect(100, 0, 100, 100), &w, &h);
    CHECK(w == 0 && h == 100); /* touching edges do not overlap */
    spdf_win_rect_overlap(rect(0, 0, 100, 100), rect(500, 500, 10, 10), &w, &h);
    CHECK(w == 0 && h == 0);

    /* 1. A frame on the external display, as measured: usable while attached... */
    p = placement(rect(220, -1319, 1300, 900), "\\\\.\\DISPLAY2", kExternal);
    CHECK(spdf_win_placement_display_attached(&p, both, 2));
    CHECK(spdf_win_placement_is_usable(&p, both, 2));
    /* ...a mac-written frame with no display too, by overlap alone... */
    p = placement(rect(220, -1319, 1300, 900), NULL, rect(0, 0, 0, 0));
    CHECK(!spdf_win_placement_display_attached(&p, both, 2));
    CHECK(spdf_win_placement_is_usable(&p, both, 2));
    /* ...and a frame on the built-in display is usable with either set. */
    p = placement(rect(100, 120, 1120, 800), "\\\\.\\DISPLAY1", kBuiltIn);
    CHECK(spdf_win_placement_is_usable(&p, both, 2));
    CHECK(spdf_win_placement_is_usable(&p, builtin_only, 1));
    /* A sliver is not on screen: 79 px of a window poking in from the right
     * edge of the built-in display -- with no display of its own to vouch for
     * it, and equally with one: the display's identity does not make the
     * frame reachable (rule 4). */
    p = placement(rect(1800 - 79, 200, 1300, 900), NULL, rect(0, 0, 0, 0));
    CHECK(!spdf_win_placement_is_usable(&p, both, 2));
    p = placement(rect(1800 - 79, 200, 1300, 900), "\\\\.\\DISPLAY1", kBuiltIn);
    CHECK(spdf_win_placement_display_attached(&p, both, 2));
    CHECK(!spdf_win_placement_is_usable(&p, both, 2));
    /* Exactly 80 x 80 is the threshold, inclusive, as kSPDFMinimumVisibleArea. */
    p = placement(rect(1800 - 80, 200, 1300, 900), NULL, rect(0, 0, 0, 0));
    CHECK(spdf_win_placement_is_usable(&p, both, 2));
    /* The taskbar is not work area: a frame entirely under it is not visible. */
    p = placement(rect(100, 1169 - 48, 1300, 900), NULL, rect(0, 0, 0, 0));
    CHECK(!spdf_win_placement_is_usable(&p, builtin_only, 1));
    /* No frame is never usable. */
    p = placement(rect(0, 0, 0, 0), "\\\\.\\DISPLAY1", kBuiltIn);
    CHECK(!spdf_win_placement_is_usable(&p, both, 2));
    CHECK(!spdf_win_placement_is_usable(NULL, both, 2));

    /* 2. The external display is asleep or unplugged: the frame it held is not
     * usable, remembered name or not. THIS is the case that used to clamp the
     * frame onto the built-in display and save the clamp. */
    p = placement(rect(220, -1319, 1300, 900), "\\\\.\\DISPLAY2", kExternal);
    CHECK(!spdf_win_placement_display_attached(&p, builtin_only, 1));
    CHECK(!spdf_win_placement_is_usable(&p, builtin_only, 1));
    p = placement(rect(220, -1319, 1300, 900), NULL, rect(0, 0, 0, 0));
    CHECK(!spdf_win_placement_is_usable(&p, builtin_only, 1));
    /* The display is attached under its name but somewhere else: the identity
     * does not hold, and a frame at the old position is above every display. */
    p = placement(rect(220, -1319, 1300, 900), "\\\\.\\DISPLAY2", kExternal);
    CHECK(!spdf_win_placement_display_attached(&p, rearranged, 2));
    CHECK(!spdf_win_placement_is_usable(&p, rearranged, 2));
    /* ...while a frame that happens to land on the moved display is usable by
     * overlap, which is what lets a replugged display that came back under a
     * new name still show the window. */
    p = placement(rect(2000, 100, 1300, 900), "\\\\.\\DISPLAY3", rect(1800, 0, 3440, 1440));
    CHECK(!spdf_win_placement_display_attached(&p, rearranged, 2));
    CHECK(spdf_win_placement_is_usable(&p, rearranged, 2));
    /* The identity is exact: the same name at the same rectangle, and only that. */
    p = placement(rect(220, -1319, 1300, 900), "\\\\.\\DISPLAY2", rect(-820, -1440, 3440, 1439));
    CHECK(!spdf_win_placement_display_attached(&p, both, 2));
    p = placement(rect(220, -1319, 1300, 900), "\\\\.\\display2", kExternal);
    CHECK(!spdf_win_placement_display_attached(&p, both, 2)); /* names compare as Windows spells them */

    /* 3. The fallback: centred in the main display's work area. The mac
     * measured the clamp at exactly the built-in screen's visible frame
     * (0, 65); centred is the visible difference between "parked" and "moved". */
    fallback = spdf_win_placement_fallback(rect(220, -1319, 1300, 900), builtin_only[0].work);
    CHECK(fallback.w == 1300 && fallback.h == 900);
    CHECK(fallback.x == (1800 - 1300) / 2);
    CHECK(fallback.y == (1121 - 900) / 2);
    CHECK(!(fallback.x == 0 && fallback.y == 0));
    /* No bigger than the work area: a 3440-wide window parks at the width of
     * the display it is parked on, from its left edge. */
    fallback = spdf_win_placement_fallback(rect(-820, -1440, 3440, 1400), builtin_only[0].work);
    CHECK(fallback.w == 1800 && fallback.h == 1121);
    CHECK(fallback.x == 0 && fallback.y == 0);
    /* A work area that does not start at the origin (a taskbar on the left,
     * or a main display that is not at 0,0) centres inside ITS rectangle. */
    fallback = spdf_win_placement_fallback(rect(0, 0, 800, 600), rect(60, 0, 1740, 1169));
    CHECK(fallback.x == 60 + (1740 - 800) / 2 && fallback.y == (1169 - 600) / 2);
    /* The fallback of a frame that is already where it would be parked is the
     * frame itself, which is how restore tells "parked" from "as saved". */
    fallback = spdf_win_placement_fallback(rect(250, 110, 1300, 900), builtin_only[0].work);
    CHECK(spdf_win_rect_equal(fallback, rect(250, 110, 1300, 900)));

    /* 4. Reachable, and the parking that follows from not being reachable. The
     * two frames measured on the 2880 x 1800 desktop with its 72 px taskbar,
     * on that desktop's geometry. */
    {
        spdf_win_display desk[1];
        spdf_win_rect main_work, got;
        int parked = -1;
        desk[0] = display("\\\\.\\DISPLAY1", rect(0, 0, 2880, 1800), 72);
        main_work = desk[0].work;
        /* The 60 x 28 corner: visible by no rule, on its own attached display.
         * Parked by CLAMPING onto that display -- the reader's size, pulled to
         * the bottom-right of the work area -- not centred. */
        p = placement(rect(2820, 1700, 1702, 1211), "\\\\.\\DISPLAY1", rect(0, 0, 2880, 1800));
        CHECK(!spdf_win_frame_is_reachable(p.frame, desk, 1));
        CHECK(spdf_win_placement_home_display(&p, desk, 1) == 0);
        got = spdf_win_placement_resolve(&p, desk, 1, main_work, &parked);
        CHECK(parked == 1);
        CHECK(spdf_win_rect_equal(got, rect(2880 - 1702, 1728 - 1211, 1702, 1211)));
        /* The 111 px strip: 1702 x 111 of it inside the work area passes the
         * visibility rule, but its top edge is 1100 px above the display, so
         * the title bar is not on the screen. Not reachable; pulled down to
         * y = 0 and otherwise left where the reader had it. */
        p = placement(rect(228, -1100, 1702, 1211), "\\\\.\\DISPLAY1", rect(0, 0, 2880, 1800));
        CHECK(spdf_win_frame_is_visible(p.frame, desk, 1));
        CHECK(!spdf_win_frame_is_reachable(p.frame, desk, 1));
        CHECK(!spdf_win_placement_is_usable(&p, desk, 1));
        got = spdf_win_placement_resolve(&p, desk, 1, main_work, &parked);
        CHECK(parked == 1);
        CHECK(spdf_win_rect_equal(got, rect(228, 0, 1702, 1211)));
        /* Reachable is the threshold's own inclusive edge: the top edge on the
         * work area's first row with 80 rows inside, and 80 columns inside. */
        p = placement(rect(2880 - 80, 0, 1702, 1211), NULL, rect(0, 0, 0, 0));
        CHECK(spdf_win_frame_is_reachable(p.frame, desk, 1));
        got = spdf_win_placement_resolve(&p, desk, 1, main_work, &parked);
        CHECK(parked == 0 && spdf_win_rect_equal(got, p.frame));
        p = placement(rect(2880 - 80, -1, 1702, 1211), NULL, rect(0, 0, 0, 0));
        CHECK(!spdf_win_frame_is_reachable(p.frame, desk, 1));
        /* Under the taskbar: on the display (its home) but in no work area, so
         * it is pulled up into the work area rather than centred. */
        p = placement(rect(100, 1740, 1300, 900), NULL, rect(0, 0, 0, 0));
        CHECK(spdf_win_placement_home_display(&p, desk, 1) == 0);
        got = spdf_win_placement_resolve(&p, desk, 1, main_work, &parked);
        CHECK(parked == 1 && spdf_win_rect_equal(got, rect(100, 1728 - 900, 1300, 900)));
        /* Wholly off every monitor, its display attached: the display it
         * names is its home, and it is clamped to that display's edge -- what
         * SetWindowPlacement itself does with a frame that misses every
         * monitor, now decided here so the two agree. */
        p = placement(rect(3500, 100, 1702, 1211), "\\\\.\\DISPLAY1", rect(0, 0, 2880, 1800));
        CHECK(spdf_win_placement_home_display(&p, desk, 1) == 0);
        got = spdf_win_placement_resolve(&p, desk, 1, main_work, &parked);
        CHECK(parked == 1 && spdf_win_rect_equal(got, rect(2880 - 1702, 100, 1702, 1211)));
        /* Wholly off, and its display gone: no home, centred as in 3. */
        p = placement(rect(3000, 100, 1702, 1211), "\\\\.\\DISPLAY7", rect(2880, 0, 3440, 1440));
        CHECK(spdf_win_placement_home_display(&p, desk, 1) == -1);
        got = spdf_win_placement_resolve(&p, desk, 1, main_work, &parked);
        CHECK(parked == 1 && spdf_win_rect_equal(got, spdf_win_placement_fallback(p.frame, main_work)));
        /* Bigger than the work area and off it: shrunk to the work area, at its
         * origin. Bigger but reachable is applied as saved (the system trims). */
        p = placement(rect(-100, -200, 4000, 3000), NULL, rect(0, 0, 0, 0));
        got = spdf_win_placement_resolve(&p, desk, 1, main_work, &parked);
        CHECK(parked == 1 && spdf_win_rect_equal(got, rect(0, 0, 2880, 1728)));
        p = placement(rect(0, 0, 4000, 3000), NULL, rect(0, 0, 0, 0));
        got = spdf_win_placement_resolve(&p, desk, 1, main_work, &parked);
        CHECK(parked == 0 && spdf_win_rect_equal(got, p.frame));
        /* The home display is the one overlapped MOST, so a frame straddling
         * two displays with its top edge above both is pulled onto the one it
         * is mostly on -- and the clamp is idempotent. */
        {
            spdf_win_display two[2];
            two[0] = display("\\\\.\\DISPLAY1", rect(0, 0, 2880, 1800), 72);
            two[1] = display("\\\\.\\DISPLAY2", rect(2880, 0, 3440, 1440), 0);
            p = placement(rect(2500, -200, 1702, 1211), NULL, rect(0, 0, 0, 0));
            CHECK(spdf_win_placement_home_display(&p, two, 2) == 1);
            got = spdf_win_placement_resolve(&p, two, 2, two[0].work, &parked);
            CHECK(parked == 1 && spdf_win_rect_equal(got, rect(2880, 0, 1702, 1211)));
            CHECK(spdf_win_rect_equal(spdf_win_placement_clamp(got, two[1].work), got));
        }
        /* And the measured-good frame of the report, as saved: reachable, as is. */
        p = placement(rect(228, 228, 1702, 1211), "\\\\.\\DISPLAY1", rect(0, 0, 2880, 1800));
        got = spdf_win_placement_resolve(&p, desk, 1, main_work, &parked);
        CHECK(parked == 0 && spdf_win_rect_equal(got, p.frame));
    }

    printf("placement_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
