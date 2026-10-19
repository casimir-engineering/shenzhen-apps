/* print_preview_test.c — THE PREVIEW'S GEOMETRY, with no window, no printer, no
 * document and no MuPDF.
 *
 * THE ONE CLAIM THAT MATTERS, AND WHY IT CANNOT BE FAKED. A print preview is
 * only worth looking at if it shows where the job will actually put the page.
 * That placement is spdf_win_print_dest_rect() in spdf_win_print_math.h — a
 * transcription of the GTK original, compared against it function by function
 * at 1,944,132 points by portable/win/tests/print_differential.c. A preview
 * that computed its own placement would be a SECOND answer to the same
 * question, and the reader would be shown a lie the first time the two
 * disagreed.
 *
 * So the assertion below is not "the rectangle looks about right". It is that
 * spdf_win_preview_layout_for() carries spdf_win_print_dest_rect()'s output
 * through BIT FOR BIT in `dest_pt`, that `mode_scale` is
 * spdf_win_print_mode_scale()'s answer bit for bit, and that every drawn
 * rectangle is that rect times ONE scale plus ONE translation — checked with
 * `==` on doubles, not with a tolerance. An approximation cannot pass this; a
 * second implementation cannot pass it either, because it would have to
 * reproduce the original's exact rounding to the last bit.
 *
 * It is driven at Fit, at Actual Size and at Custom (both a shrinking 25% and a
 * magnifying 400%), in portrait and in landscape, on four real drivers'
 * GetDeviceCaps numbers — a 600 dpi laser with a 12 pt unprintable border, a
 * 1200 dpi laser, Microsoft Print to PDF (which prints to the edge), and a
 * driver that reports no physical sheet at all so the DEVMODE's own
 * dmPaperWidth/dmPaperLength have to answer for it.
 *
 * WHY IT RUNS ANYWHERE. spdf_win_print_preview_geom.h is a pure header, the way
 * spdf_win_print_math.h and spdf_win_md_code_marks.h are: doubles in, doubles
 * out, no Windows types. The window around it is
 * portable/win/tests/print_dialog_test.c's business.
 */
#include "spdf_win_print_preview_geom.h"

#include <math.h>
#include <stdio.h>

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

/* EXACT, not near: see this file's header. Every use of this macro is a place
 * where an approximation would be wrong rather than merely imprecise. */
#define CHECK_EXACT(a, b)                                                                                              \
    do {                                                                                                               \
        double va = (double)(a);                                                                                       \
        double vb = (double)(b);                                                                                        \
        ++g_checks;                                                                                                    \
        if (!(va == vb)) {                                                                                             \
            printf("FAIL %s:%d: %s (%.17g) != %s (%.17g)\n", __FILE__, __LINE__, #a, va, #b, vb);                      \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_NEAR(a, b)                                                                                               \
    do {                                                                                                               \
        double va = (double)(a);                                                                                       \
        double vb = (double)(b);                                                                                        \
        ++g_checks;                                                                                                    \
        if (!(fabs(va - vb) < 1e-9)) {                                                                                 \
            printf("FAIL %s:%d: %s (%.17g) != %s (%.17g)\n", __FILE__, __LINE__, #a, va, #b, vb);                      \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* --- 1. the sheet, from real drivers' caps -------------------------------- */

/* A 600 dpi laser on US Letter: the sheet is 8.5 x 11 in and the driver keeps a
 * 2/100 in (12 pt) border on every side. */
static void test_sheet_laser(void) {
    spdf_win_preview_sheet s;

    CHECK(spdf_win_preview_sheet_build(600, 600, 5100, 6600, 100, 100, 4900, 6400, 0.0, 0.0, &s) == 1);
    CHECK(s.sheet_measured == 1);
    CHECK_NEAR(s.sheet_w_pt, 612.0);
    CHECK_NEAR(s.sheet_h_pt, 792.0);
    CHECK_NEAR(s.margin_l_pt, 12.0);
    CHECK_NEAR(s.margin_t_pt, 12.0);
    CHECK_NEAR(s.margin_r_pt, 12.0);
    CHECK_NEAR(s.margin_b_pt, 12.0);
    /* The printable area is spdf_win_print_paper_from_caps()'s, not a second
     * conversion of the same numbers -- so the preview and the job centre the
     * page on the same area. */
    {
        spdf_win_print_paper paper;
        CHECK(spdf_win_print_paper_from_caps(600, 600, 4900, 6400, &paper) == 1);
        CHECK_EXACT(s.imageable_w_pt, paper.imageable_w_pt);
        CHECK_EXACT(s.imageable_h_pt, paper.imageable_h_pt);
        CHECK_EXACT(s.dpi_x, paper.dpi_x);
        CHECK_EXACT(s.dpi_y, paper.dpi_y);
    }
    /* The two margins and the printable area account for the whole sheet. */
    CHECK_NEAR(s.margin_l_pt + s.imageable_w_pt + s.margin_r_pt, s.sheet_w_pt);
    CHECK_NEAR(s.margin_t_pt + s.imageable_h_pt + s.margin_b_pt, s.sheet_h_pt);
}

/* Microsoft Print to PDF reports PHYSICALWIDTH == HORZRES and a zero offset:
 * it really does print to the edge, and zero margins here are the truth about
 * it rather than a fallback. That distinction is what sheet_measured carries. */
static void test_sheet_edge_to_edge(void) {
    spdf_win_preview_sheet s;

    CHECK(spdf_win_preview_sheet_build(600, 600, 5100, 6600, 0, 0, 5100, 6600, 0.0, 0.0, &s) == 1);
    CHECK(s.sheet_measured == 1);
    CHECK_NEAR(s.sheet_w_pt, 612.0);
    CHECK_NEAR(s.margin_l_pt, 0.0);
    CHECK_NEAR(s.margin_r_pt, 0.0);
    CHECK_EXACT(s.imageable_w_pt, s.sheet_w_pt);
    CHECK_EXACT(s.imageable_h_pt, s.sheet_h_pt);
}

/* A driver that reports no physical sheet at all. The DEVMODE's own stock
 * answers for it, the border has to be ASSUMED even on all four sides, and
 * sheet_measured says so rather than letting the caveat go unsaid. */
static void test_sheet_from_devmode(void) {
    spdf_win_preview_sheet s;
    double w = 0.0;
    double h = 0.0;

    /* A4 is 2100 x 2970 tenths of a millimetre. dmPaperWidth/dmPaperLength
     * describe the STOCK, so landscape swaps them. */
    CHECK(spdf_win_preview_paper_pt(1, 2100, 2970, 0, &w, &h) == 1);
    CHECK_NEAR(w, 2100.0 * 72.0 / 254.0);
    CHECK_NEAR(h, 2970.0 * 72.0 / 254.0);
    CHECK_NEAR(w, 595.27559055118115);
    CHECK(spdf_win_preview_paper_pt(1, 2100, 2970, 1, &w, &h) == 1);
    CHECK_NEAR(w, 2970.0 * 72.0 / 254.0);
    CHECK_NEAR(h, 2100.0 * 72.0 / 254.0);
    /* A DEVMODE that named only a dmPaperSize code reports nothing: guessing a
     * size from the code would be inventing paper. */
    CHECK(spdf_win_preview_paper_pt(0, 2100, 2970, 0, &w, &h) == 0);
    CHECK_EXACT(w, 0.0);
    CHECK(spdf_win_preview_paper_pt(1, 0, 2970, 0, &w, &h) == 0);

    /* 300 dpi, A4 landscape, printable area 2400 x 1700 px, no PHYSICAL* at
     * all. 2400 px at 300 dpi is 576 pt; the sheet is 841.89 pt, so 132.9 pt is
     * unaccounted for and is split evenly. */
    spdf_win_preview_paper_pt(1, 2100, 2970, 1, &w, &h);
    CHECK(spdf_win_preview_sheet_build(300, 300, 0, 0, 0, 0, 2400, 1700, w, h, &s) == 1);
    CHECK(s.sheet_measured == 0);
    CHECK_NEAR(s.sheet_w_pt, w);
    CHECK_NEAR(s.imageable_w_pt, 576.0);
    CHECK_NEAR(s.margin_l_pt, (w - 576.0) / 2.0);
    CHECK_NEAR(s.margin_r_pt, (w - 576.0) / 2.0);

    /* Neither a sheet nor a usable DEVMODE: the printable area is all this
     * driver will admit to, and sheet_measured stays 0 because the paper around
     * it is not known to be absent, only unreported. */
    CHECK(spdf_win_preview_sheet_build(300, 300, 0, 0, 0, 0, 2400, 1700, 0.0, 0.0, &s) == 1);
    CHECK(s.sheet_measured == 0);
    CHECK_EXACT(s.sheet_w_pt, s.imageable_w_pt);
    CHECK_NEAR(s.margin_l_pt, 0.0);

    /* Unusable caps are a refusal, not an infinity. */
    CHECK(spdf_win_preview_sheet_build(0, 600, 5100, 6600, 0, 0, 4900, 6400, 0.0, 0.0, &s) == 0);
    CHECK(spdf_win_preview_sheet_build(600, 600, 5100, 6600, 0, 0, 0, 6400, 0.0, 0.0, &s) == 0);
    CHECK_EXACT(s.sheet_w_pt, 0.0);
    CHECK(spdf_win_preview_sheet_build(600, 600, 5100, 6600, 0, 0, 4900, 6400, 0.0, 0.0, NULL) == 0);
}

/* --- 2. THE CLAIM: the preview's page rect IS print_math's, scaled --------- */

/* One case of the matrix. Everything here is an exact comparison against a
 * DIRECT call into spdf_win_print_math.h with the same arguments. */
static void assert_placement(const char* what, const spdf_win_preview_sheet* s, double page_w, double page_h,
                             spdf_win_print_scaling_mode mode, double custom, double pane_w, double pane_h) {
    spdf_win_preview_layout got;
    spdf_win_print_rect want;
    double want_scale;
    double px;

    if (!spdf_win_preview_layout_for(s, page_w, page_h, mode, custom, pane_w, pane_h, &got)) {
        printf("FAIL %s: no layout\n", what);
        ++g_failures;
        ++g_checks;
        return;
    }
    /* THE SAME ARITHMETIC THE JOB USES, called here independently. */
    want = spdf_win_print_dest_rect(page_w, page_h, s->imageable_w_pt, s->imageable_h_pt, mode, custom);
    want_scale = spdf_win_print_mode_scale(page_w, page_h, s->imageable_w_pt, s->imageable_h_pt, mode, custom);
    CHECK_EXACT(got.dest_pt.x, want.x);
    CHECK_EXACT(got.dest_pt.y, want.y);
    CHECK_EXACT(got.dest_pt.w, want.w);
    CHECK_EXACT(got.dest_pt.h, want.h);
    CHECK_EXACT(got.mode_scale, want_scale);

    /* ONE scale, and it is the tighter of the two the pane allows. */
    px = got.px_per_pt;
    CHECK_EXACT(px, spdf_win_min_d(pane_w / s->sheet_w_pt, pane_h / s->sheet_h_pt));

    /* The sheet: right shape, centred in the pane. */
    CHECK_EXACT(got.sheet.w, s->sheet_w_pt * px);
    CHECK_EXACT(got.sheet.h, s->sheet_h_pt * px);
    CHECK_EXACT(got.sheet.x, (pane_w - got.sheet.w) / 2.0);
    CHECK_EXACT(got.sheet.y, (pane_h - got.sheet.h) / 2.0);

    /* The printable area: inset by the driver's own border, at the same scale. */
    CHECK_EXACT(got.image.x, got.sheet.x + s->margin_l_pt * px);
    CHECK_EXACT(got.image.y, got.sheet.y + s->margin_t_pt * px);
    CHECK_EXACT(got.image.w, s->imageable_w_pt * px);
    CHECK_EXACT(got.image.h, s->imageable_h_pt * px);

    /* AND THE PAGE: print_math's rectangle, times that one scale, translated
     * onto the printable area. Nothing else. */
    CHECK_EXACT(got.page.x, got.image.x + want.x * px);
    CHECK_EXACT(got.page.y, got.image.y + want.y * px);
    CHECK_EXACT(got.page.w, want.w * px);
    CHECK_EXACT(got.page.h, want.h * px);
}

static void test_placement_matrix(void) {
    spdf_win_preview_sheet portrait;
    spdf_win_preview_sheet landscape;
    spdf_win_preview_sheet fine;
    /* Letter portrait and landscape on the 600 dpi laser, and an A4 portrait on
     * a 1200 dpi one whose border is asymmetric (a duplexer's grip edge). */
    CHECK(spdf_win_preview_sheet_build(600, 600, 5100, 6600, 100, 100, 4900, 6400, 0.0, 0.0, &portrait) == 1);
    CHECK(spdf_win_preview_sheet_build(600, 600, 6600, 5100, 100, 100, 6400, 4900, 0.0, 0.0, &landscape) == 1);
    CHECK(spdf_win_preview_sheet_build(1200, 1200, 9921, 14031, 200, 400, 9521, 13031, 0.0, 0.0, &fine) == 1);

    /* Fit, Actual Size and Custom both ways, on each sheet, for a page smaller
     * than the paper (A5), one the same size (Letter) and an oversized foldout.
     * The pane is deliberately not square and not a round number. */
    {
        const spdf_win_preview_sheet* sheets[3];
        double pages[3][2] = {{420.0, 595.0}, {612.0, 792.0}, {1224.0, 792.0}};
        spdf_win_print_scaling_mode modes[4] = {SPDF_WIN_PRINT_SCALING_FIT, SPDF_WIN_PRINT_SCALING_ACTUAL,
                                                SPDF_WIN_PRINT_SCALING_CUSTOM, SPDF_WIN_PRINT_SCALING_CUSTOM};
        double customs[4] = {1.0, 1.0, 0.25, 4.0};
        int si, pi, mi;
        sheets[0] = &portrait;
        sheets[1] = &landscape;
        sheets[2] = &fine;
        for (si = 0; si < 3; ++si)
            for (pi = 0; pi < 3; ++pi)
                for (mi = 0; mi < 4; ++mi)
                    assert_placement("matrix", sheets[si], pages[pi][0], pages[pi][1], modes[mi], customs[mi], 233.0,
                                     341.0);
    }

    /* AND THE OVERHANG IS REAL. A 1224 pt foldout at Actual Size on Letter is
     * twice the printable width, so print_math gives it a negative origin and
     * the preview must carry that outside the sheet rather than clamp it --
     * hiding it is the one thing this window exists to prevent. */
    {
        spdf_win_preview_layout got;
        CHECK(spdf_win_preview_layout_for(&portrait, 1224.0, 792.0, SPDF_WIN_PRINT_SCALING_ACTUAL, 1.0, 233.0, 341.0,
                                          &got) == 1);
        CHECK(got.dest_pt.x < 0.0);
        CHECK(got.page.x < got.image.x);
        CHECK(got.page.x + got.page.w > got.image.x + got.image.w);
        /* Fit, on the same page, shrinks it inside the printable area instead. */
        CHECK(spdf_win_preview_layout_for(&portrait, 1224.0, 792.0, SPDF_WIN_PRINT_SCALING_FIT, 1.0, 233.0, 341.0,
                                          &got) == 1);
        CHECK(got.page.x >= got.image.x - 1e-9);
        CHECK(got.page.x + got.page.w <= got.image.x + got.image.w + 1e-9);
        CHECK(got.mode_scale < 1.0);
    }

    /* A landscape sheet is drawn landscape: the DEVMODE's orientation reaches
     * the preview through the caps, and the pane never changes the shape. */
    {
        spdf_win_preview_layout got;
        CHECK(spdf_win_preview_layout_for(&landscape, 612.0, 792.0, SPDF_WIN_PRINT_SCALING_FIT, 1.0, 233.0, 341.0,
                                          &got) == 1);
        CHECK(got.sheet.w > got.sheet.h);
        CHECK_NEAR(got.sheet.w / got.sheet.h, landscape.sheet_w_pt / landscape.sheet_h_pt);
        /* A tall pane leaves the sheet limited by WIDTH, so the sheet must not
         * fill the pane vertically -- which is what proves one scale, not two. */
        CHECK(got.sheet.h < 341.0);
        CHECK_NEAR(got.sheet.w, 233.0);
    }

    /* Nothing to draw is answered, not guessed. */
    {
        spdf_win_preview_layout got;
        spdf_win_preview_sheet empty;
        spdf_win_preview_sheet_clear(&empty);
        CHECK(spdf_win_preview_layout_for(NULL, 612.0, 792.0, SPDF_WIN_PRINT_SCALING_FIT, 1.0, 233.0, 341.0, &got) ==
              0);
        CHECK(got.valid == 0);
        CHECK(spdf_win_preview_layout_for(&empty, 612.0, 792.0, SPDF_WIN_PRINT_SCALING_FIT, 1.0, 233.0, 341.0, &got) ==
              0);
        CHECK(spdf_win_preview_layout_for(&portrait, 612.0, 792.0, SPDF_WIN_PRINT_SCALING_FIT, 1.0, 0.0, 341.0, &got) ==
              0);
        CHECK(spdf_win_preview_layout_for(&portrait, 612.0, 792.0, SPDF_WIN_PRINT_SCALING_FIT, 1.0, 233.0, 0.0, &got) ==
              0);
        /* A page with no size is print_math's degenerate case, and it falls back
         * to a 1x1 pt rect there rather than to a division -- the preview shows
         * exactly that rather than inventing a page. */
        CHECK(spdf_win_preview_layout_for(&portrait, 0.0, 792.0, SPDF_WIN_PRINT_SCALING_FIT, 1.0, 233.0, 341.0,
                                          &got) == 1);
        CHECK_EXACT(got.dest_pt.w,
                    spdf_win_print_dest_rect(0.0, 792.0, portrait.imageable_w_pt, portrait.imageable_h_pt,
                                             SPDF_WIN_PRINT_SCALING_FIT, 1.0)
                        .w);
    }
}

/* --- 3. the preview's own render zoom ------------------------------------- */

static void test_render_zoom(void) {
    /* Pixels per point, snapped to 1/32 so a one-pixel resize or a percentage
     * typed digit by digit reuses the cached bitmap instead of re-rendering. */
    CHECK_EXACT(spdf_win_preview_render_zoom(306.0, 612.0), 0.5);
    CHECK_EXACT(spdf_win_preview_render_zoom(153.0, 612.0), 0.25);
    CHECK_EXACT(spdf_win_preview_render_zoom(154.0, 612.0), 0.25); /* one px: same key */
    CHECK_EXACT(spdf_win_preview_render_zoom(160.0, 612.0), 8.0 / 32.0);
    /* The band. A 10% Custom on a big sheet must not fall to zero, and an 800%
     * one must not ask for a poster -- only the visible part is on screen. */
    CHECK_EXACT(spdf_win_preview_render_zoom(1.0, 612.0), SPDF_WIN_PREVIEW_MIN_ZOOM);
    CHECK_EXACT(spdf_win_preview_render_zoom(6000.0, 612.0), SPDF_WIN_PREVIEW_MAX_ZOOM);
    CHECK_EXACT(spdf_win_preview_render_zoom(0.0, 612.0), SPDF_WIN_PREVIEW_MIN_ZOOM);
    CHECK_EXACT(spdf_win_preview_render_zoom(306.0, 0.0), SPDF_WIN_PREVIEW_MIN_ZOOM);
    CHECK_EXACT(spdf_win_preview_render_zoom(-5.0, 612.0), SPDF_WIN_PREVIEW_MIN_ZOOM);
    /* It is the PREVIEW's zoom and nothing to do with the job's, which aims at
     * 300 dpi -- a preview rendered at print resolution would be 20 MB a page. */
    CHECK(SPDF_WIN_PREVIEW_MAX_ZOOM < SPDF_WIN_PRINT_TARGET_DPI_FLOOR / 72.0);
}

int main(void) {
    test_sheet_laser();
    test_sheet_edge_to_edge();
    test_sheet_from_devmode();
    test_placement_matrix();
    test_render_zoom();
    printf("print_preview_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
