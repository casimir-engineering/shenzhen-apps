/* print_math_test.c — the print job's arithmetic, with no printer, no
 * document, no MuPDF and no window.
 *
 * WHY IT RUNS ANYWHERE, INCLUDING WHERE THE DIALOGS DO NOT. Everything the job
 * DECIDES before it needs a printer or a window -- the paper conversion, the
 * placement, the visible-source split, the render zoom, the page range -- is
 * pure double arithmetic in spdf_win_print_math.h, and this suite drives all of
 * it with no desktop and no spooler. It was for a while the only print test
 * that could run at all: PrintDlgExW does not return on this host
 * (portable/docs/windows-print-dialog.md). The two suites that now cover the
 * rest are print_e2e_test.c, which drives a real job to a real printer, and
 * print_watchdog_test.c, which proves the dialog can no longer hang the app.
 *
 * THIS IS THE HAND-WRITTEN HALF. The other half is
 * portable/win/tests/print_differential.c, which compiles the GTK4 original
 * (portable/linux/gtk4/spdf_print.c, glib-only under SPDF_PRINT_TESTING) beside
 * the port and compares them exactly. A hand-written test can only assert what
 * its author remembered; the differential asserts against the implementation
 * this was transcribed from. Both are wanted: this one pins the cases a reader
 * cares about in words, that one pins every case.
 */
#include "spdf_win_print_math.h"
/* The Scaling page's pure half: radios and a percentage field to a choice and
 * back. The Win32 page itself is left out (SPDF_WIN_PRINT_SCALING_PURE). */
#define SPDF_WIN_PRINT_SCALING_PURE
#include "spdf_win_print_scaling.h"

#include <math.h>
#include <stdio.h>
#include <wchar.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                                     \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_NEAR(a, b)                                                                                               \
    do {                                                                                                               \
        double va = (double)(a);                                                                                       \
        double vb = (double)(b);                                                                                       \
        ++g_checks;                                                                                                    \
        if (!(fabs(va - vb) < 1e-9)) {                                                                                 \
            printf("FAIL %s:%d: %s (%.17g) != %s (%.17g)\n", __FILE__, __LINE__, #a, va, #b, vb);                      \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* US Letter with an 18 pt margin all round -- the same fixture geometry the
 * GTK suite (tests/print_scaling_test.c) uses, so the two read alike. */
#define LETTER_W (612.0 - 36.0)
#define LETTER_H (792.0 - 36.0)

static void test_custom_scale(void) {
    CHECK_NEAR(spdf_win_print_clamp_custom_scale(1.0), 1.0);
    CHECK_NEAR(spdf_win_print_clamp_custom_scale(0.25), 0.25);
    /* Out of range clamps rather than rejects. */
    CHECK_NEAR(spdf_win_print_clamp_custom_scale(0.01), SPDF_WIN_PRINT_MIN_CUSTOM_SCALE);
    CHECK_NEAR(spdf_win_print_clamp_custom_scale(50.0), SPDF_WIN_PRINT_MAX_CUSTOM_SCALE);
    /* Degenerate falls back to 1.0, never to a division. */
    CHECK_NEAR(spdf_win_print_clamp_custom_scale(0.0), 1.0);
    CHECK_NEAR(spdf_win_print_clamp_custom_scale(-2.0), 1.0);
    CHECK_NEAR(spdf_win_print_clamp_custom_scale(NAN), 1.0);
    CHECK_NEAR(spdf_win_print_clamp_custom_scale(INFINITY), 1.0);
}

static void test_mode_scale(void) {
    /* Fit takes the tighter axis: an A4 page on Letter is limited by height. */
    double fit = spdf_win_print_mode_scale(595.0, 842.0, LETTER_W, LETTER_H, SPDF_WIN_PRINT_SCALING_FIT, 1.0);
    CHECK_NEAR(fit, LETTER_H / 842.0);
    CHECK(fit < LETTER_W / 595.0);
    /* Fit GROWS a small page rather than only shrinking -- a business card
     * printed "fit to page" fills the sheet on macOS too. */
    CHECK(spdf_win_print_mode_scale(200.0, 200.0, LETTER_W, LETTER_H, SPDF_WIN_PRINT_SCALING_FIT, 1.0) > 1.0);
    CHECK_NEAR(spdf_win_print_mode_scale(595.0, 842.0, LETTER_W, LETTER_H, SPDF_WIN_PRINT_SCALING_ACTUAL, 4.0), 1.0);
    CHECK_NEAR(spdf_win_print_mode_scale(595.0, 842.0, LETTER_W, LETTER_H, SPDF_WIN_PRINT_SCALING_CUSTOM, 0.5), 0.5);
    /* A degenerate page or paper is 1.0, not a NaN that would poison the rect. */
    CHECK_NEAR(spdf_win_print_mode_scale(0.0, 842.0, LETTER_W, LETTER_H, SPDF_WIN_PRINT_SCALING_FIT, 1.0), 1.0);
    CHECK_NEAR(spdf_win_print_mode_scale(595.0, 842.0, 0.0, LETTER_H, SPDF_WIN_PRINT_SCALING_FIT, 1.0), 1.0);
}

static void test_dest_rect(void) {
    spdf_win_print_rect r;

    /* Actual size centres the page and leaves the margins. */
    r = spdf_win_print_dest_rect(300.0, 400.0, LETTER_W, LETTER_H, SPDF_WIN_PRINT_SCALING_ACTUAL, 1.0);
    CHECK_NEAR(r.w, 300.0);
    CHECK_NEAR(r.h, 400.0);
    CHECK_NEAR(r.x, (LETTER_W - 300.0) / 2.0);
    CHECK_NEAR(r.y, (LETTER_H - 400.0) / 2.0);

    /* Fit fills one axis exactly and centres on the other. */
    r = spdf_win_print_dest_rect(595.0, 842.0, LETTER_W, LETTER_H, SPDF_WIN_PRINT_SCALING_FIT, 1.0);
    CHECK_NEAR(r.h, LETTER_H);
    CHECK_NEAR(r.y, 0.0);
    CHECK(r.x > 0.0);

    /* An oversized job overflows on purpose: outline.pdf's page 2 is a 1224 pt
     * foldout, and at 100% it does not fit on Letter. A NEGATIVE origin is the
     * correct answer, because it is what the visible-source split reads. */
    r = spdf_win_print_dest_rect(1224.0, 792.0, LETTER_W, LETTER_H, SPDF_WIN_PRINT_SCALING_ACTUAL, 1.0);
    CHECK(r.x < 0.0);
    CHECK_NEAR(r.w, 1224.0);

    /* Never smaller than 1x1: a 0.1 pt page at 10% must still be a rect. */
    r = spdf_win_print_dest_rect(0.5, 0.5, LETTER_W, LETTER_H, SPDF_WIN_PRINT_SCALING_CUSTOM, 0.1);
    CHECK_NEAR(r.w, 1.0);
    CHECK_NEAR(r.h, 1.0);
}

static void test_visible_source(void) {
    spdf_win_print_rect dest;
    spdf_win_print_rect src;
    spdf_win_print_rect dst;

    /* A page that fits: the whole page is the source and it lands where the
     * destination said. */
    dest = spdf_win_print_dest_rect(300.0, 400.0, LETTER_W, LETTER_H, SPDF_WIN_PRINT_SCALING_ACTUAL, 1.0);
    CHECK(spdf_win_print_visible_source(&dest, 300.0, 400.0, LETTER_W, LETTER_H, &src, &dst));
    CHECK_NEAR(src.x, 0.0);
    CHECK_NEAR(src.y, 0.0);
    CHECK_NEAR(src.w, 300.0);
    CHECK_NEAR(src.h, 400.0);
    CHECK_NEAR(dst.x, dest.x);

    /* The foldout at 100%: only the paper's worth of page is rendered, which
     * is what keeps print memory proportional to PAPER and not to page. */
    dest = spdf_win_print_dest_rect(1224.0, 792.0, LETTER_W, LETTER_H, SPDF_WIN_PRINT_SCALING_ACTUAL, 1.0);
    CHECK(spdf_win_print_visible_source(&dest, 1224.0, 792.0, LETTER_W, LETTER_H, &src, &dst));
    CHECK_NEAR(src.w, LETTER_W);
    CHECK(src.x > 0.0); /* the middle of the sheet, not its left edge */
    CHECK_NEAR(dst.x, 0.0);
    CHECK_NEAR(dst.w, LETTER_W);
    CHECK_NEAR(src.x + src.w / 2.0, 1224.0 / 2.0); /* centred */

    /* Nothing visible is a clean 0, not a zero-area rect the renderer would
     * then be asked to produce. */
    dest.x = -10000.0;
    dest.y = 0.0;
    dest.w = 100.0;
    dest.h = 100.0;
    CHECK(!spdf_win_print_visible_source(&dest, 100.0, 100.0, LETTER_W, LETTER_H, &src, &dst));
    CHECK(!spdf_win_print_visible_source(NULL, 100.0, 100.0, LETTER_W, LETTER_H, &src, &dst));
}

static void test_render_zoom(void) {
    double zoom;

    /* A 600 dpi laser: 600/72 zoom for a page small enough not to hit the cap. */
    zoom = spdf_win_print_render_zoom(1.0, 600.0, 600.0, 100.0, 100.0, SPDF_WIN_PRINT_RENDER_BYTE_CAP);
    CHECK_NEAR(zoom, 600.0 / 72.0);

    /* A driver reporting 72 dpi (Print to PDF, preview) is raised to the 300
     * dpi floor rather than producing a screen-resolution print. */
    zoom = spdf_win_print_render_zoom(1.0, 72.0, 72.0, 100.0, 100.0, SPDF_WIN_PRINT_RENDER_BYTE_CAP);
    CHECK_NEAR(zoom, SPDF_WIN_PRINT_TARGET_DPI_FLOOR / 72.0);

    /* An asymmetric inkjet keeps the FINER axis, so nothing is under-sampled. */
    CHECK_NEAR(spdf_win_print_render_zoom(1.0, 1200.0, 4800.0, 10.0, 10.0, 0.0),
               spdf_win_print_render_zoom(1.0, 4800.0, 1200.0, 10.0, 10.0, 0.0));

    /* THE BYTE CAP WINS OVER THE DPI TARGET. A full Letter page at 600 dpi is
     * 5100 x 6600 x 4 = 134 MB of RGBA, over the 128 MB cap, so the zoom is
     * shrunk continuously until it fits -- and the result is the BEST zoom the
     * cap allows, not a halved one. */
    zoom = spdf_win_print_render_zoom(1.0, 600.0, 600.0, 612.0, 792.0, SPDF_WIN_PRINT_RENDER_BYTE_CAP);
    CHECK(zoom < 600.0 / 72.0);
    CHECK_NEAR(612.0 * zoom * 792.0 * zoom * 4.0, SPDF_WIN_PRINT_RENDER_BYTE_CAP);

    /* The dimension cap applies on its own when the byte cap is disabled. */
    zoom = spdf_win_print_render_zoom(1.0, 100000.0, 100000.0, 612.0, 792.0, 0.0);
    CHECK_NEAR(792.0 * zoom, SPDF_WIN_PRINT_MAX_RENDER_DIMENSION);

    /* Never below the floor. */
    CHECK(spdf_win_print_render_zoom(0.001, 300.0, 300.0, 612.0, 792.0, SPDF_WIN_PRINT_RENDER_BYTE_CAP) >= 0.05);
}

static void test_permission_zoom(void) {
    double normal = spdf_win_print_render_zoom(1.0, 600.0, 600.0, 100.0, 100.0, SPDF_WIN_PRINT_RENDER_BYTE_CAP);

    /* 'h' allowed: untouched. */
    CHECK_NEAR(spdf_win_print_permission_render_zoom(normal, 1.0, 1), normal);
    /* 'h' denied: capped at 150 effective dpi. This is the ONLY thing the
     * high-quality flag does -- it never blocks the job, which is 'p'. */
    CHECK_NEAR(spdf_win_print_permission_render_zoom(normal, 1.0, 0), SPDF_WIN_PRINT_RESTRICTED_DPI / 72.0);
    /* A restricted job already below the cap is not RAISED to it. */
    CHECK_NEAR(spdf_win_print_permission_render_zoom(1.0, 1.0, 0), 1.0);
    /* The restriction scales with the mode: a 50% job's 150 dpi is half. */
    CHECK_NEAR(spdf_win_print_permission_render_zoom(normal, 0.5, 0), 0.5 * SPDF_WIN_PRINT_RESTRICTED_DPI / 72.0);
    CHECK_NEAR(spdf_win_print_permission_render_zoom(NAN, 1.0, 1), 0.05);
}

static void test_paper_from_caps(void) {
    spdf_win_print_paper paper;

    /* A 600 dpi laser with a Letter sheet and quarter-inch hardware margins:
     * HORZRES/VERTRES are the PRINTABLE area, 8.0 x 10.5 inches. */
    CHECK(spdf_win_print_paper_from_caps(600, 600, 4800, 6300, &paper));
    CHECK_NEAR(paper.dpi_x, 600.0);
    CHECK_NEAR(paper.imageable_w_pt, 576.0);  /* 8.0 in */
    CHECK_NEAR(paper.imageable_h_pt, 756.0);  /* 10.5 in */

    /* Asymmetric resolution converts each axis with its own dpi. */
    CHECK(spdf_win_print_paper_from_caps(1200, 600, 9600, 6300, &paper));
    CHECK_NEAR(paper.imageable_w_pt, 576.0);
    CHECK_NEAR(paper.imageable_h_pt, 756.0);

    /* A driver reporting nonsense is refused rather than dividing by zero:
     * an infinite zoom would reach MuPDF as a request for an infinite pixmap. */
    CHECK(!spdf_win_print_paper_from_caps(0, 600, 4800, 6300, &paper));
    CHECK(!spdf_win_print_paper_from_caps(600, 600, 0, 6300, &paper));
    CHECK_NEAR(paper.imageable_w_pt, 0.0);
    CHECK(!spdf_win_print_paper_from_caps(600, 600, 4800, 6300, NULL));
}

static void test_page_ranges(void) {
    spdf_win_print_page_range ranges[4];
    int pages[16];
    int n;

    /* No ranges means the whole document. */
    n = spdf_win_print_expand_ranges(NULL, 0, 4, pages, 16);
    CHECK(n == 4);
    CHECK(pages[0] == 0 && pages[3] == 3);

    /* 1-based in, 0-based out. */
    ranges[0].from = 2;
    ranges[0].to = 3;
    n = spdf_win_print_expand_ranges(ranges, 1, 10, pages, 16);
    CHECK(n == 2);
    CHECK(pages[0] == 1 && pages[1] == 2);

    /* Overlapping ranges name pages, they do not ask for copies: "1-3,2" is
     * three sheets, not four. Order is ascending whatever the user typed. */
    ranges[0].from = 3;
    ranges[0].to = 3;
    ranges[1].from = 1;
    ranges[1].to = 2;
    ranges[2].from = 2;
    ranges[2].to = 2;
    n = spdf_win_print_expand_ranges(ranges, 3, 10, pages, 16);
    CHECK(n == 3);
    CHECK(pages[0] == 0 && pages[1] == 1 && pages[2] == 2);

    /* A reversed pair still names a range. */
    ranges[0].from = 5;
    ranges[0].to = 3;
    n = spdf_win_print_expand_ranges(ranges, 1, 10, pages, 16);
    CHECK(n == 3);
    CHECK(pages[0] == 2 && pages[2] == 4);

    /* Out-of-document pages are dropped, not clamped onto a neighbour: a
     * reader who typed 99 in a 2 page document gets nothing for it, and
     * printing page 2 twice would be worse. */
    ranges[0].from = 2;
    ranges[0].to = 99;
    n = spdf_win_print_expand_ranges(ranges, 1, 2, pages, 16);
    CHECK(n == 1);
    CHECK(pages[0] == 1);
    ranges[0].from = 50;
    ranges[0].to = 99;
    CHECK(spdf_win_print_expand_ranges(ranges, 1, 2, pages, 16) == 0);

    /* Refusals, not overflows. */
    CHECK(spdf_win_print_expand_ranges(NULL, 0, 4, pages, 2) == -1);
    CHECK(spdf_win_print_expand_ranges(NULL, 0, 4, NULL, 16) == -1);
    CHECK(spdf_win_print_expand_ranges(NULL, 0, 0, pages, 16) == -1);
}

/* --- the Scaling page's choice, both directions ------------------------- */
static void test_scaling_page_choice(void) {
    spdf_win_print_choice c;
    wchar_t text[16];

    /* The percentage the field shows. */
    spdf_win_print_percent_text(1.5, text, 16);
    CHECK(wcscmp(text, L"150") == 0);
    spdf_win_print_percent_text(1.0, text, 16);
    CHECK(wcscmp(text, L"100") == 0);
    spdf_win_print_percent_text(0.1, text, 16);
    CHECK(wcscmp(text, L"10") == 0);
    spdf_win_print_percent_text(99.0, text, 16); /* clamps to 800% first */
    CHECK(wcscmp(text, L"800") == 0);
    spdf_win_print_percent_text(-3.0, text, 16); /* non-positive is 100% */
    CHECK(wcscmp(text, L"100") == 0);

    /* Radios in mode order; the field only matters for Custom but is always
     * parsed, so the remembered custom scale survives a Fit print. */
    CHECK(spdf_win_print_choice_from_page(SPDF_WIN_PRINT_SCALING_CUSTOM, L"150", &c) == 1);
    CHECK(c.mode == SPDF_WIN_PRINT_SCALING_CUSTOM);
    CHECK_NEAR(c.custom_scale, 1.5);
    CHECK(spdf_win_print_choice_from_page(SPDF_WIN_PRINT_SCALING_FIT, L"150", &c) == 0);
    CHECK(c.mode == SPDF_WIN_PRINT_SCALING_FIT);
    CHECK_NEAR(c.custom_scale, 1.5);
    spdf_win_print_choice_from_page(SPDF_WIN_PRINT_SCALING_ACTUAL, L"", &c);
    CHECK(c.mode == SPDF_WIN_PRINT_SCALING_ACTUAL);
    CHECK_NEAR(c.custom_scale, 1.0); /* an empty field is 100% */

    /* Tolerant of what a field holds: spaces, a typed percent sign. */
    CHECK(spdf_win_print_choice_from_page(SPDF_WIN_PRINT_SCALING_CUSTOM, L"  75 %", &c) == 1);
    CHECK_NEAR(c.custom_scale, 0.75);
    /* Out of range clamps as SPDFClampPrintCustomScale does, and says so. */
    CHECK(spdf_win_print_choice_from_page(SPDF_WIN_PRINT_SCALING_CUSTOM, L"5", &c) == 0);
    CHECK_NEAR(c.custom_scale, 0.10);
    CHECK(spdf_win_print_choice_from_page(SPDF_WIN_PRINT_SCALING_CUSTOM, L"900", &c) == 0);
    CHECK_NEAR(c.custom_scale, 8.0);
    /* Nonsense is 100%, and an unknown radio is Fit. */
    CHECK(spdf_win_print_choice_from_page(SPDF_WIN_PRINT_SCALING_CUSTOM, L"abc", &c) == 0);
    CHECK_NEAR(c.custom_scale, 1.0);
    spdf_win_print_choice_from_page(9, L"100", &c);
    CHECK(c.mode == SPDF_WIN_PRINT_SCALING_FIT);
    spdf_win_print_choice_from_page(SPDF_WIN_PRINT_SCALING_CUSTOM, NULL, &c);
    CHECK_NEAR(c.custom_scale, 1.0);
    /* The radio ids ARE the modes, offset: the page relies on it. */
    CHECK(SPDF_WIN_PRINT_ID_ACTUAL - SPDF_WIN_PRINT_ID_FIT == SPDF_WIN_PRINT_SCALING_ACTUAL);
    CHECK(SPDF_WIN_PRINT_ID_CUSTOM - SPDF_WIN_PRINT_ID_FIT == SPDF_WIN_PRINT_SCALING_CUSTOM);
}

int main(void) {
    test_scaling_page_choice();
    test_custom_scale();
    test_mode_scale();
    test_dest_rect();
    test_visible_source();
    test_render_zoom();
    test_permission_zoom();
    test_paper_from_caps();
    test_page_ranges();
    printf("print_math_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
