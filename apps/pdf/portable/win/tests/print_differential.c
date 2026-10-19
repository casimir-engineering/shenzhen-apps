/* THE PRINT DIFFERENTIAL: portable/win/src/spdf_win_print_math.h versus the
 * GTK4 original it was transcribed from, portable/linux/gtk4/spdf_print.c,
 * both compiled into ONE binary, driven with identical inputs, compared for
 * EXACT equality.
 *
 * Same instrument as portable/win/tests/gtk_differential.c (layout),
 * minimap_differential.c, search_differential.c and selection_differential.c,
 * and for the same reason: a hand-written test can only assert what its author
 * remembered, while this one asserts each function against the implementation
 * it was ported from. Doubles are compared with `==` and not an epsilon -- the
 * port is a TRANSCRIPTION, so a difference of one ulp is a transcription error
 * and not a rounding question. That discipline has already caught a one-ulp
 * error elsewhere in this port.
 *
 * WHY THE GTK SIDE COMPILES HERE AT ALL. spdf_print.c is a GTK module, but its
 * author put the pure arithmetic in section 1 behind SPDF_PRINT_TESTING and
 * ships tests/print_scaling_test.c that `#include "../spdf_print.c"` with that
 * defined. Under it the file needs nothing but <math.h> and glib's gboolean,
 * TRUE/FALSE, MAX/MIN and CLAMP -- all of which portable/win/tests/glib_shim/
 * already supplies, with glib's own macro bodies character for character
 * (the comparison order at the edges is part of what is being checked). So
 * this differential needs NO new shim, unlike the search one.
 *
 * It is arguably a PURER check than a cross-platform run: both sides are
 * compiled by the same MSVC into the same binary with /fp:precise, so a
 * difference cannot be two toolchains disagreeing about floating point and can
 * only be a transcription error.
 *
 * Not named *_test.c on purpose -- the same convention minimap_differential.c
 * and search_differential.c follow -- so run-tests-native.sh's `*_test.c` sweep
 * does not try to build it without the extra include paths. Build and run it
 * with portable\win\tests\print-differential-native.cmd and judge it by its
 * exit code.
 */

#define SPDF_PRINT_TESTING 1

/* The GTK4 original. The .cmd puts glib_shim on the include path. */
#include "spdf_print.c"

/* The port. */
#include "spdf_win_print_math.h"

#include <stdio.h>
#include <string.h>

static int mismatches;
static long comparisons;

static void same_d(const char* what, double win, double gtk) {
    comparisons++;
    if (win != gtk) {
        if (mismatches < 40) printf("DIFFER %s: win=%.17g gtk=%.17g\n", what, win, gtk);
        mismatches++;
    }
}

static void same_i(const char* what, long long win, long long gtk) {
    comparisons++;
    if (win != gtk) {
        if (mismatches < 40) printf("DIFFER %s: win=%lld gtk=%lld\n", what, win, gtk);
        mismatches++;
    }
}

/* --------------------------------------------------------------------------
 * The input grids. Chosen to cover what a real print job produces AND the
 * corners: a zero page, a 1224 pt foldout (portable/win/tests/fixtures/
 * outline.pdf page 2), a 72 dpi print-to-file device, a 4800x1200 inkjet, and
 * the byte cap disabled so the dimension cap can be reached on its own. */

static const double k_pages[] = {0.0, 0.5, 100.0, 200.0, 595.0, 612.0, 792.0, 842.0, 1224.0, 20000.0};
static const double k_imageable[] = {0.0, 1.0, 288.0, 576.0, 595.0, 756.0, 792.0, 1584.0};
static const double k_customs[] = {-1.0, 0.0, 0.05, 0.1, 0.5, 1.0, 2.0, 8.0, 50.0};
static const int k_modes[] = {SPDF_PRINT_SCALING_FIT, SPDF_PRINT_SCALING_ACTUAL, SPDF_PRINT_SCALING_CUSTOM};

#define N(a) ((int)(sizeof(a) / sizeof((a)[0])))

static void differential_clamp(void) {
    int i;
    /* Every custom scale a spin button can produce, plus the degenerate ones.
     * -3.00 to 12.00 in hundredths is 1501 values. */
    for (i = -300; i <= 1200; ++i) {
        double v = (double)i / 100.0;
        same_d("clamp_custom_scale", spdf_win_print_clamp_custom_scale(v), spdf_print_clamp_custom_scale(v));
    }
    /* The values that are not numbers. NaN is the one that matters: CLAMP's
     * comparison order decides the answer (every comparison against NaN is
     * false), and both sides must agree about it. */
    same_d("clamp/nan", spdf_win_print_clamp_custom_scale(NAN), spdf_print_clamp_custom_scale(NAN));
    same_d("clamp/inf", spdf_win_print_clamp_custom_scale(INFINITY), spdf_print_clamp_custom_scale(INFINITY));
    same_d("clamp/-inf", spdf_win_print_clamp_custom_scale(-INFINITY), spdf_print_clamp_custom_scale(-INFINITY));
    same_d("mode_scale/nan", spdf_win_print_mode_scale(595.0, 842.0, 576.0, 756.0, SPDF_WIN_PRINT_SCALING_CUSTOM, NAN),
           spdf_print_mode_scale(595.0, 842.0, 576.0, 756.0, SPDF_PRINT_SCALING_CUSTOM, NAN));
    same_d("render_zoom/nan-dpi", spdf_win_print_render_zoom(1.0, NAN, NAN, 612.0, 792.0, 0.0),
           spdf_print_render_zoom(1.0, NAN, NAN, 612.0, 792.0, 0.0));
    same_d("render_zoom/nan-scale", spdf_win_print_render_zoom(NAN, 600.0, 600.0, 612.0, 792.0, 0.0),
           spdf_print_render_zoom(NAN, 600.0, 600.0, 612.0, 792.0, 0.0));
    same_d("permission/nan", spdf_win_print_permission_render_zoom(NAN, 1.0, 0),
           spdf_print_permission_render_zoom(NAN, 1.0, FALSE));
}

static void differential_mode_and_dest(void) {
    int pw, ph, iw, ih, m, c;
    for (pw = 0; pw < N(k_pages); ++pw)
        for (ph = 0; ph < N(k_pages); ++ph)
            for (iw = 0; iw < N(k_imageable); ++iw)
                for (ih = 0; ih < N(k_imageable); ++ih)
                    for (m = 0; m < N(k_modes); ++m)
                        for (c = 0; c < N(k_customs); ++c) {
                            double page_w = k_pages[pw], page_h = k_pages[ph];
                            double img_w = k_imageable[iw], img_h = k_imageable[ih];
                            double custom = k_customs[c];
                            SpdfPrintScalingMode gmode = (SpdfPrintScalingMode)k_modes[m];
                            spdf_win_print_scaling_mode wmode = (spdf_win_print_scaling_mode)k_modes[m];
                            spdf_win_print_rect wr;
                            SpdfPrintRect gr;
                            spdf_win_print_rect wsrc, wdst;
                            SpdfPrintRect gsrc, gdst;
                            int wok, gok;

                            same_d("mode_scale",
                                   spdf_win_print_mode_scale(page_w, page_h, img_w, img_h, wmode, custom),
                                   spdf_print_mode_scale(page_w, page_h, img_w, img_h, gmode, custom));

                            wr = spdf_win_print_dest_rect(page_w, page_h, img_w, img_h, wmode, custom);
                            gr = spdf_print_dest_rect(page_w, page_h, img_w, img_h, gmode, custom);
                            same_d("dest.x", wr.x, gr.x);
                            same_d("dest.y", wr.y, gr.y);
                            same_d("dest.w", wr.w, gr.w);
                            same_d("dest.h", wr.h, gr.h);

                            memset(&wsrc, 0, sizeof(wsrc));
                            memset(&wdst, 0, sizeof(wdst));
                            memset(&gsrc, 0, sizeof(gsrc));
                            memset(&gdst, 0, sizeof(gdst));
                            wok = spdf_win_print_visible_source(&wr, page_w, page_h, img_w, img_h, &wsrc, &wdst);
                            gok = spdf_print_visible_source(&gr, page_w, page_h, img_w, img_h, &gsrc, &gdst) ? 1 : 0;
                            same_i("visible_source/ok", wok, gok);
                            if (!wok || !gok) continue;
                            same_d("src.x", wsrc.x, gsrc.x);
                            same_d("src.y", wsrc.y, gsrc.y);
                            same_d("src.w", wsrc.w, gsrc.w);
                            same_d("src.h", wsrc.h, gsrc.h);
                            same_d("dst.x", wdst.x, gdst.x);
                            same_d("dst.y", wdst.y, gdst.y);
                            same_d("dst.w", wdst.w, gdst.w);
                            same_d("dst.h", wdst.h, gdst.h);
                        }
}

static const double k_scales[] = {0.0, 0.05, 0.25, 1.0, 1.5, 4.0, 8.0};
static const double k_dpis[] = {0.0, 72.0, 96.0, 150.0, 300.0, 600.0, 1200.0, 4800.0};
static const double k_srcs[] = {0.0, 1.0, 72.0, 576.0, 792.0, 1224.0};
static const double k_caps[] = {0.0, 1024.0 * 1024.0, SPDF_PRINT_RENDER_BYTE_CAP};

static void differential_render_zoom(void) {
    int s, dx, dy, sw, sh, cp;
    for (s = 0; s < N(k_scales); ++s)
        for (dx = 0; dx < N(k_dpis); ++dx)
            for (dy = 0; dy < N(k_dpis); ++dy)
                for (sw = 0; sw < N(k_srcs); ++sw)
                    for (sh = 0; sh < N(k_srcs); ++sh)
                        for (cp = 0; cp < N(k_caps); ++cp)
                            same_d("render_zoom",
                                   spdf_win_print_render_zoom(k_scales[s], k_dpis[dx], k_dpis[dy], k_srcs[sw],
                                                              k_srcs[sh], k_caps[cp]),
                                   spdf_print_render_zoom(k_scales[s], k_dpis[dx], k_dpis[dy], k_srcs[sw], k_srcs[sh],
                                                          k_caps[cp]));
}

static void differential_permission_zoom(void) {
    int z, s, hq;
    static const double k_zooms[] = {-1.0, 0.0, 0.01, 0.05, 1.0, 2.0, 4.1666666666666667, 8.3333333333333339, 100.0};
    for (z = 0; z < N(k_zooms); ++z)
        for (s = 0; s < N(k_scales); ++s)
            for (hq = 0; hq < 2; ++hq)
                same_d("permission_render_zoom",
                       spdf_win_print_permission_render_zoom(k_zooms[z], k_scales[s], hq),
                       spdf_print_permission_render_zoom(k_zooms[z], k_scales[s], hq ? TRUE : FALSE));
}

/* The constants themselves. A port that agreed function for function while
 * disagreeing about the 128 MB cap or the 150 dpi restriction would print
 * differently on the two platforms and every comparison above would still
 * pass, because both sides would be using their own constant. */
static void differential_constants(void) {
    same_d("MIN_CUSTOM_SCALE", SPDF_WIN_PRINT_MIN_CUSTOM_SCALE, SPDF_PRINT_MIN_CUSTOM_SCALE);
    same_d("MAX_CUSTOM_SCALE", SPDF_WIN_PRINT_MAX_CUSTOM_SCALE, SPDF_PRINT_MAX_CUSTOM_SCALE);
    same_d("MIN_RENDER_ZOOM", SPDF_WIN_PRINT_MIN_RENDER_ZOOM, SPDF_PRINT_MIN_RENDER_ZOOM);
    same_d("TARGET_DPI_FLOOR", SPDF_WIN_PRINT_TARGET_DPI_FLOOR, SPDF_PRINT_TARGET_DPI_FLOOR);
    same_d("RESTRICTED_DPI", SPDF_WIN_PRINT_RESTRICTED_DPI, SPDF_PRINT_RESTRICTED_DPI);
    same_d("RENDER_BYTE_CAP", SPDF_WIN_PRINT_RENDER_BYTE_CAP, SPDF_PRINT_RENDER_BYTE_CAP);
    same_d("MAX_RENDER_DIMENSION", SPDF_WIN_PRINT_MAX_RENDER_DIMENSION, SPDF_PRINT_MAX_RENDER_DIMENSION);
    /* The scaling-mode values are persisted in settings.json and shared with
     * macOS; a renumbering would silently change what a saved preference
     * means. */
    same_i("SCALING_FIT", SPDF_WIN_PRINT_SCALING_FIT, SPDF_PRINT_SCALING_FIT);
    same_i("SCALING_ACTUAL", SPDF_WIN_PRINT_SCALING_ACTUAL, SPDF_PRINT_SCALING_ACTUAL);
    same_i("SCALING_CUSTOM", SPDF_WIN_PRINT_SCALING_CUSTOM, SPDF_PRINT_SCALING_CUSTOM);
}

int main(void) {
    differential_constants();
    differential_clamp();
    differential_mode_and_dest();
    differential_render_zoom();
    differential_permission_zoom();

    printf("print differential: %ld comparisons, %d mismatches\n", comparisons, mismatches);
    if (mismatches > 0) return 1;
    /* A matrix that did not run must never look like a pass -- the same guard
     * gtk_differential.c's main() carries. */
    if (comparisons < 100000) {
        printf("print differential: only %ld comparisons ran; the matrix did not execute\n", comparisons);
        return 2;
    }
    return 0;
}
