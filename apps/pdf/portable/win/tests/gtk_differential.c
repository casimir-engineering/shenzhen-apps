/* THE DIFFERENTIAL: the Windows layout/cache port versus the GTK4 original,
 * both compiled into one binary, driven with identical inputs, compared for
 * EXACT equality.
 *
 * portable/win/src/spdf_win_layout.h and spdf_win_lru.c exist so a Windows
 * frontend puts pages where the other two frontends put them. A hand-written
 * test can only assert what its author remembered to assert; this one asserts
 * the whole function against the implementation it was ported from. Doubles are
 * compared with `==`, not an epsilon -- the port is a transcription, so any
 * difference at all is a transcription error.
 *
 * macOS only, and deliberately not named *_test.c: it links against glib and
 * includes portable/linux/gtk4/spdf_docview_internal.h, neither of which exists
 * in the Windows guest, so run-tests.sh must not try to build it there.
 * portable/win/tests/t3-verify.sh builds and runs it.
 *
 * Build (see t3-verify.sh for the real line):
 *   cc -ffp-contract=off $(pkg-config --cflags glib-2.0) \
 *      -Iportable/core -Iportable/win/src -Iportable/linux/gtk4 \
 *      gtk_differential.c gtk_differential_cache.c portable/win/src/spdf_win_lru.c \
 *      $(pkg-config --libs glib-2.0)
 */

#include <glib.h>
#include <stdio.h>

#include "spdf_docview_internal.h" /* the GTK4 original */
#include "spdf_win_layout.h"       /* the port */
#include "spdf_win_lru.h"

#include "gtk_differential.h"

int spdf_diff_mismatches;
int spdf_diff_comparisons;

void spdf_diff_same_d(const char* what, double win, double gtk) {
    spdf_diff_comparisons++;
    if (win != gtk) {
        printf("DIFFER %s: win=%.17g gtk=%.17g\n", what, win, gtk);
        spdf_diff_mismatches++;
    }
}

void spdf_diff_same_i(const char* what, long long win, long long gtk) {
    spdf_diff_comparisons++;
    if (win != gtk) {
        printf("DIFFER %s: win=%lld gtk=%lld\n", what, win, gtk);
        spdf_diff_mismatches++;
    }
}

void spdf_diff_report(const char* what, const char* detail) {
    printf("DIFFER %s: %s\n", what, detail);
    spdf_diff_mismatches++;
}

/* --------------------------------------------------------------------------
 * Input space. Deliberately awkward: a giant schematic sheet next to an A5
 * page is what broke the GTK centring and anchoring in the first place. */

static const SpdfWinPageSizePt doc_a[] = {{612.0, 792.0}, {612.0, 792.0}, {612.0, 792.0}};
static const SpdfWinPageSizePt doc_b[] = {{612.0, 792.0}, {10900.0, 7539.0}, {420.0, 595.0}, {612.0, 4000.0}};
static const SpdfWinPageSizePt doc_c[] = {{841.89, 595.28}};
static const SpdfWinPageSizePt doc_d[] = {{1.0, 1.0},        {3000.0, 2.0},  {2.0, 3000.0}, {612.0, 792.0},
                                          {595.276, 841.89}, {200.0, 200.0}, {72.0, 72.0}};

typedef struct {
    const char* name;
    const SpdfWinPageSizePt* sizes;
    int count;
} document;

static const document documents[] = {
    {"uniform", doc_a, 3},      {"mixed", doc_b, 4}, {"single-landscape", doc_c, 1},
    {"pathological", doc_d, 7}, {"empty", NULL, 0},
};

static const double zooms[] = {0.1, 0.25, 0.5, 0.75, 1.0, 1.3333333333333333, 2.0, 3.7, 8.0};
static const double viewports_w[] = {320.0, 900.0, 1440.0, 3840.0};
static const double viewports_h[] = {200.0, 700.0, 1200.0};

/* The GTK layout takes the same doubles; only the struct type differs. */
static const SpdfPageSizePt* as_gtk(const SpdfWinPageSizePt* sizes) {
    /* SpdfPageSizePt and SpdfWinPageSizePt are both { double width, height; }.
     * Assert that rather than assume it, then reinterpret -- copying would work
     * too but would hide a layout change behind a memcpy. */
    return (const SpdfPageSizePt*)sizes;
}

static void compare_layouts(const char* label, const SpdfWinLayout* win, const SpdfLayout* gtk) {
    int i;
    spdf_diff_same_i("count", win->count, gtk->count);
    spdf_diff_same_d("canvas_w", win->canvas_w, gtk->canvas_w);
    spdf_diff_same_d("canvas_h", win->canvas_h, gtk->canvas_h);
    if (win->count != gtk->count) return;
    for (i = 0; i < win->count; ++i) {
        char what[160];
        g_snprintf(what, sizeof(what), "%s slot %d", label, i);
        spdf_diff_same_d(what, win->rects[i].x, gtk->rects[i].x);
        spdf_diff_same_d(what, win->rects[i].y, gtk->rects[i].y);
        spdf_diff_same_d(what, win->rects[i].w, gtk->rects[i].w);
        spdf_diff_same_d(what, win->rects[i].h, gtk->rects[i].h);
    }
}

void differential_layout(void) {
    SpdfWinLayout win = {NULL, 0, 0.0, 0.0};
    SpdfLayout gtk = {NULL, 0, 0.0, 0.0};
    unsigned d;
    unsigned z;
    unsigned v;

    for (d = 0; d < G_N_ELEMENTS(documents); ++d) {
        for (z = 0; z < G_N_ELEMENTS(zooms); ++z) {
            for (v = 0; v < G_N_ELEMENTS(viewports_w); ++v) {
                const document* doc = &documents[d];
                double zoom = zooms[z];
                double vw = viewports_w[v];
                double y;
                int page;
                unsigned h;

                spdf_win_layout_compute(&win, doc->sizes, doc->count, zoom, vw, SPDF_WIN_PAGE_MARGIN_H,
                                        SPDF_WIN_PAGE_MARGIN_V);
                spdf_layout_compute(&gtk, as_gtk(doc->sizes), doc->count, zoom, vw, SPDF_PAGE_MARGIN_H,
                                    SPDF_PAGE_MARGIN_V);
                compare_layouts(doc->name, &win, &gtk);

                /* Nearest-centre page across the whole canvas and past both ends. */
                for (y = -1000.0; y <= gtk.canvas_h + 1000.0; y += 137.0)
                    spdf_diff_same_i("nearest", spdf_win_layout_page_nearest_center(&win, y),
                                     spdf_layout_page_nearest_center(&gtk, y));
                /* And on the exact page centres and the exact midpoints between
                 * consecutive centres. A stepped sweep never lands on a tie, so
                 * without these the "earlier page wins ties" rule is untested --
                 * a mutant that flips `<=` to `<` survives the sweep. */
                for (page = 0; page < doc->count; ++page) {
                    double centre = gtk.rects[page].y + gtk.rects[page].h * 0.5;
                    spdf_diff_same_i("nearest centre", spdf_win_layout_page_nearest_center(&win, centre),
                                     spdf_layout_page_nearest_center(&gtk, centre));
                    if (page + 1 < doc->count) {
                        double next = gtk.rects[page + 1].y + gtk.rects[page + 1].h * 0.5;
                        double tie = (centre + next) * 0.5;
                        spdf_diff_same_i("nearest tie", spdf_win_layout_page_nearest_center(&win, tie),
                                         spdf_layout_page_nearest_center(&gtk, tie));
                    }
                }

                /* Visible range for viewport-sized bands stepped through the
                 * document, plus bands that fall off each end. */
                for (h = 0; h < G_N_ELEMENTS(viewports_h); ++h) {
                    double vh = viewports_h[h];
                    for (y = -2000.0; y <= gtk.canvas_h + 2000.0; y += 211.0) {
                        int wf = -7;
                        int wl = -7;
                        int gf = -7;
                        int gl = -7;
                        int wok = spdf_win_layout_visible_range(&win, y, y + vh, &wf, &wl);
                        gboolean gok = spdf_layout_visible_range(&gtk, y, y + vh, &gf, &gl);
                        spdf_diff_same_i("visible ok", wok, gok ? 1 : 0);
                        spdf_diff_same_i("visible first", wf, gf);
                        spdf_diff_same_i("visible last", wl, gl);
                    }
                    /* Degenerate and inverted bands. */
                    spdf_diff_same_i("visible degenerate",
                                     spdf_win_layout_visible_range(&win, 100.0, 100.0, NULL, NULL),
                                     spdf_layout_visible_range(&gtk, 100.0, 100.0, NULL, NULL) ? 1 : 0);
                    spdf_diff_same_i("visible inverted", spdf_win_layout_visible_range(&win, 900.0, 100.0, NULL, NULL),
                                     spdf_layout_visible_range(&gtk, 900.0, 100.0, NULL, NULL) ? 1 : 0);
                }

                /* Horizontal clamp for every page and a spread of requested
                 * scroll values, including out-of-range ones. */
                for (page = -1; page <= doc->count; ++page) {
                    static const double values[] = {-9999.0, -1.0, 0.0, 17.5, 900.0, 6000.0, 1e9};
                    unsigned k;
                    for (k = 0; k < G_N_ELEMENTS(values); ++k) {
                        SpdfWinHScrollClamp wc = spdf_win_hscroll_clamp(&win, page, vw, values[k]);
                        SpdfHScrollClamp gc = spdf_hscroll_clamp(&gtk, page, vw, values[k]);
                        spdf_diff_same_i("hclamp scrollable", wc.scrollable, gc.scrollable ? 1 : 0);
                        spdf_diff_same_d("hclamp value", wc.value, gc.value);
                    }
                }

                /* The scrollbar-policy epsilon: `canvas_w > viewport_w + 0.5`.
                 * It only shows up for a viewport within half a pixel of the
                 * content width, which no fixed list of viewport widths will
                 * ever hit, so the widths are derived from the layout itself. */
                {
                    static const double deltas[] = {-1.0, -0.75, -0.5, -0.25, 0.0, 0.25, 0.5, 0.75, 1.0};
                    unsigned k;
                    for (k = 0; k < G_N_ELEMENTS(deltas); ++k) {
                        double edge = gtk.canvas_w - deltas[k];
                        SpdfWinLayout w2 = {NULL, 0, 0.0, 0.0};
                        SpdfLayout g2 = {NULL, 0, 0.0, 0.0};
                        int p;
                        if (edge <= 0.0) continue;
                        /* Recompute at the probe width -- canvas_w depends on it. */
                        spdf_win_layout_compute(&w2, doc->sizes, doc->count, zoom, edge, SPDF_WIN_PAGE_MARGIN_H,
                                                SPDF_WIN_PAGE_MARGIN_V);
                        spdf_layout_compute(&g2, as_gtk(doc->sizes), doc->count, zoom, edge, SPDF_PAGE_MARGIN_H,
                                            SPDF_PAGE_MARGIN_V);
                        for (p = 0; p < doc->count; ++p) {
                            SpdfWinHScrollClamp wc = spdf_win_hscroll_clamp(&w2, p, edge, 0.0);
                            SpdfHScrollClamp gc = spdf_hscroll_clamp(&g2, p, edge, 0.0);
                            spdf_diff_same_i("edge scrollable", wc.scrollable, gc.scrollable ? 1 : 0);
                            spdf_diff_same_d("edge value", wc.value, gc.value);
                        }
                        spdf_win_layout_clear(&w2);
                        spdf_layout_clear(&g2);
                    }
                    /* The other half-pixel decision in the same function:
                     * `rect->w <= viewport_w + 0.5` chooses between pinning a
                     * page centred and letting it pan. Probe viewports sitting
                     * exactly on each page's own width. */
                    for (page = 0; page < doc->count; ++page) {
                        for (k = 0; k < G_N_ELEMENTS(deltas); ++k) {
                            double edge = gtk.rects[page].w - deltas[k];
                            SpdfWinLayout w2 = {NULL, 0, 0.0, 0.0};
                            SpdfLayout g2 = {NULL, 0, 0.0, 0.0};
                            static const double asks[] = {-10.0, 0.0, 5.0, 1e6};
                            unsigned a;
                            if (edge <= 0.0) continue;
                            spdf_win_layout_compute(&w2, doc->sizes, doc->count, zoom, edge, SPDF_WIN_PAGE_MARGIN_H,
                                                    SPDF_WIN_PAGE_MARGIN_V);
                            spdf_layout_compute(&g2, as_gtk(doc->sizes), doc->count, zoom, edge, SPDF_PAGE_MARGIN_H,
                                                SPDF_PAGE_MARGIN_V);
                            for (a = 0; a < G_N_ELEMENTS(asks); ++a) {
                                SpdfWinHScrollClamp wc = spdf_win_hscroll_clamp(&w2, page, edge, asks[a]);
                                SpdfHScrollClamp gc = spdf_hscroll_clamp(&g2, page, edge, asks[a]);
                                spdf_diff_same_i("page-edge scrollable", wc.scrollable, gc.scrollable ? 1 : 0);
                                spdf_diff_same_d("page-edge value", wc.value, gc.value);
                            }
                            spdf_win_layout_clear(&w2);
                            spdf_layout_clear(&g2);
                        }
                    }
                }

                /* Crop regime. */
                for (page = 0; page < doc->count; ++page)
                    for (h = 0; h < G_N_ELEMENTS(viewports_h); ++h)
                        spdf_diff_same_i("needs crop", spdf_win_slot_needs_crop(&win.rects[page], vw, viewports_h[h]),
                                         spdf_slot_needs_crop(&gtk.rects[page], vw, viewports_h[h]) ? 1 : 0);
            }
        }
    }
    spdf_win_layout_clear(&win);
    spdf_layout_clear(&gtk);
}

void differential_fit_and_cap(void) {
    static const double page_w[] = {1.0, 72.0, 420.0, 612.0, 841.89, 10900.0, 1000000.0, 0.0, -5.0};
    static const double page_h[] = {1.0, 72.0, 595.0, 792.0, 7539.0, 0.0};
    static const double views[] = {0.0, 79.0, 80.0, 80.5, 81.0, 320.0, 900.0, 3840.0, 100000.0};
    unsigned a;
    unsigned b;
    unsigned c;

    for (a = 0; a < G_N_ELEMENTS(page_w); ++a) {
        for (c = 0; c < G_N_ELEMENTS(views); ++c)
            spdf_diff_same_d("fit width", spdf_win_fit_width_zoom(page_w[a], views[c]),
                             spdf_fit_width_zoom(page_w[a], views[c]));
        for (b = 0; b < G_N_ELEMENTS(page_h); ++b) {
            for (c = 0; c < G_N_ELEMENTS(views); ++c) {
                unsigned e;
                spdf_diff_same_d("fit height", spdf_win_fit_height_zoom(page_h[b], views[c]),
                                 spdf_fit_height_zoom(page_h[b], views[c]));
                for (e = 0; e < G_N_ELEMENTS(views); ++e)
                    spdf_diff_same_d("fit page", spdf_win_fit_page_zoom(page_w[a], page_h[b], views[c], views[e]),
                                     spdf_fit_page_zoom(page_w[a], page_h[b], views[c], views[e]));
            }
            /* Render byte cap over the same grid, at several zooms and caps. */
            for (c = 0; c < G_N_ELEMENTS(zooms); ++c) {
                spdf_diff_same_d("capped zoom", spdf_win_capped_render_zoom(zooms[c], page_w[a], page_h[b]),
                                 spdf_capped_render_zoom(zooms[c], page_w[a], page_h[b]));
                spdf_diff_same_d("capped zoom 8M",
                                 spdf_win_capped_render_zoom_for_cap(zooms[c], page_w[a], page_h[b], 8e6),
                                 spdf_capped_render_zoom_for_cap(zooms[c], page_w[a], page_h[b], 8e6));
            }
        }
    }
    spdf_diff_same_i("byte cap constant", (long long)SPDF_WIN_MAX_RENDER_SURFACE_BYTES,
                     (long long)SPDF_MAX_RENDER_SURFACE_BYTES);
    spdf_diff_same_d("min zoom constant", SPDF_WIN_MIN_ZOOM, SPDF_MIN_ZOOM);
    spdf_diff_same_d("max zoom constant", SPDF_WIN_MAX_ZOOM, SPDF_MAX_ZOOM);
    spdf_diff_same_d("margin h constant", SPDF_WIN_PAGE_MARGIN_H, SPDF_PAGE_MARGIN_H);
    spdf_diff_same_d("margin v constant", SPDF_WIN_PAGE_MARGIN_V, SPDF_PAGE_MARGIN_V);
}

void differential_zoom_anchor(void) {
    SpdfWinLayout win = {NULL, 0, 0.0, 0.0};
    SpdfLayout gtk = {NULL, 0, 0.0, 0.0};
    unsigned d;
    unsigned z;

    for (d = 0; d < G_N_ELEMENTS(documents); ++d) {
        const document* doc = &documents[d];
        for (z = 0; z < G_N_ELEMENTS(zooms); ++z) {
            double zoom = zooms[z];
            double vw = 900.0;
            double vh = 700.0;
            double px;
            double py;
            double sy;

            spdf_win_layout_compute(&win, doc->sizes, doc->count, zoom, vw, SPDF_WIN_PAGE_MARGIN_H,
                                    SPDF_WIN_PAGE_MARGIN_V);
            spdf_layout_compute(&gtk, as_gtk(doc->sizes), doc->count, zoom, vw, SPDF_PAGE_MARGIN_H, SPDF_PAGE_MARGIN_V);

            for (sy = 0.0; sy <= gtk.canvas_h; sy += 1553.0) {
                for (py = -30.0; py <= vh + 30.0; py += 173.0) {
                    for (px = -30.0; px <= vw + 30.0; px += 219.0) {
                        SpdfWinZoomAnchor wa;
                        SpdfZoomAnchor ga;
                        unsigned t;

                        spdf_win_zoom_anchor_capture(&wa, &win, doc->sizes, zoom, px, py, 0.0, sy);
                        spdf_zoom_anchor_capture(&ga, &gtk, as_gtk(doc->sizes), zoom, px, py, 0.0, sy);
                        spdf_diff_same_i("anchor valid", wa.valid, ga.valid ? 1 : 0);
                        if (!wa.valid || !ga.valid) continue;
                        spdf_diff_same_i("anchor page", wa.page, ga.page);
                        spdf_diff_same_d("anchor page_x", wa.page_x, ga.page_x);
                        spdf_diff_same_d("anchor page_y", wa.page_y, ga.page_y);
                        spdf_diff_same_d("anchor viewport_x", wa.viewport_x, ga.viewport_x);
                        spdf_diff_same_d("anchor viewport_y", wa.viewport_y, ga.viewport_y);

                        /* Now relayout at every other zoom and re-derive. */
                        for (t = 0; t < G_N_ELEMENTS(zooms); ++t) {
                            double nz = zooms[t];
                            double wx = -1.0;
                            double wy = -1.0;
                            double gx = -2.0;
                            double gy = -2.0;
                            int wok;
                            gboolean gok;
                            spdf_win_layout_compute(&win, doc->sizes, doc->count, nz, vw, SPDF_WIN_PAGE_MARGIN_H,
                                                    SPDF_WIN_PAGE_MARGIN_V);
                            spdf_layout_compute(&gtk, as_gtk(doc->sizes), doc->count, nz, vw, SPDF_PAGE_MARGIN_H,
                                                SPDF_PAGE_MARGIN_V);
                            wok = spdf_win_zoom_anchor_apply(&wa, &win, nz, vw, vh, &wx, &wy);
                            gok = spdf_zoom_anchor_apply(&ga, &gtk, nz, vw, vh, &gx, &gy);
                            spdf_diff_same_i("anchor apply", wok, gok ? 1 : 0);
                            spdf_diff_same_d("anchor scroll_x", wx, gx);
                            spdf_diff_same_d("anchor scroll_y", wy, gy);
                        }
                        spdf_win_layout_compute(&win, doc->sizes, doc->count, zoom, vw, SPDF_WIN_PAGE_MARGIN_H,
                                                SPDF_WIN_PAGE_MARGIN_V);
                        spdf_layout_compute(&gtk, as_gtk(doc->sizes), doc->count, zoom, vw, SPDF_PAGE_MARGIN_H,
                                            SPDF_PAGE_MARGIN_V);
                    }
                }
            }
        }
    }

    /* Anchor points sitting EXACTLY in the middle of the gap between two
     * equal-width pages. Both pages are then the same distance away, and which
     * one wins is decided by the `distance < best_distance` comparison alone --
     * a strictly-less-than that a stepped sweep can never reach, and that a
     * mutant flipping it to `<=` otherwise survives. */
    for (d = 0; d < G_N_ELEMENTS(documents); ++d) {
        const document* doc = &documents[d];
        for (z = 0; z < G_N_ELEMENTS(zooms); ++z) {
            double zoom = zooms[z];
            int page;
            spdf_win_layout_compute(&win, doc->sizes, doc->count, zoom, 900.0, SPDF_WIN_PAGE_MARGIN_H,
                                    SPDF_WIN_PAGE_MARGIN_V);
            spdf_layout_compute(&gtk, as_gtk(doc->sizes), doc->count, zoom, 900.0, SPDF_PAGE_MARGIN_H,
                                SPDF_PAGE_MARGIN_V);
            for (page = 0; page + 1 < doc->count; ++page) {
                SpdfWinZoomAnchor wa;
                SpdfZoomAnchor ga;
                double gap_mid = (gtk.rects[page].y + gtk.rects[page].h + gtk.rects[page + 1].y) * 0.5;
                double centre_x = gtk.canvas_w * 0.5;
                spdf_win_zoom_anchor_capture(&wa, &win, doc->sizes, zoom, centre_x, gap_mid, 0.0, 0.0);
                spdf_zoom_anchor_capture(&ga, &gtk, as_gtk(doc->sizes), zoom, centre_x, gap_mid, 0.0, 0.0);
                spdf_diff_same_i("gap anchor valid", wa.valid, ga.valid ? 1 : 0);
                spdf_diff_same_i("gap anchor page", wa.page, ga.page);
                spdf_diff_same_d("gap anchor page_x", wa.page_x, ga.page_x);
                spdf_diff_same_d("gap anchor page_y", wa.page_y, ga.page_y);
            }
        }
    }

    spdf_win_layout_clear(&win);
    spdf_layout_clear(&gtk);
}

int main(void) {
    /* The reinterpret in as_gtk() is only legal while the two page-size structs
     * agree; check rather than trust. */
    if (sizeof(SpdfWinPageSizePt) != sizeof(SpdfPageSizePt)) {
        printf("DIFFER SpdfPageSizePt layout changed\n");
        return 2;
    }

    differential_layout();
    differential_fit_and_cap();
    differential_zoom_anchor();

    /* THE LRU HALVES ARE SKIPPABLE, AND ONLY ON WINDOWS.
     *
     * The layout, fit and zoom-anchor comparisons need glib for its typedefs,
     * its MAX/MIN/CLAMP macros and G_N_ELEMENTS -- all of which
     * portable/win/tests/glib_shim/glib.h supplies faithfully, so those three
     * run natively under MSVC and this differential stops being macOS-only.
     *
     * These two do not. spdf_lru_* is backed by a real GHashTable, and glib
     * leaves hash ITERATION ORDER unspecified. An eviction that picks its victim
     * by iterating would then pick a different -- equally correct -- victim
     * under a shim than under glib, and this differential would report a
     * mismatch that is not a transcription error at all. A test that can cry
     * wolf is worse than a test that admits it cannot run, so on Windows these
     * two are skipped rather than faked, and the driver that skips them says so.
     *
     * On macOS and Linux, where real glib is linked, nothing changes: the macro
     * is not defined and all five run. */
#ifndef SPDF_DIFFERENTIAL_NO_LRU
    differential_cache_recency();
    differential_cache();
#else
    printf("differential: SKIPPING the two LRU comparisons -- they need real glib, "
           "not a shim (hash iteration order is unspecified)\n");
#endif

    printf("differential: %d comparisons, %d mismatches\n", spdf_diff_comparisons, spdf_diff_mismatches);
    if (spdf_diff_comparisons < 100000) {
        printf("differential: REFUSING to pass on %d comparisons -- the matrix did not run\n", spdf_diff_comparisons);
        return 3;
    }
    return spdf_diff_mismatches == 0 ? 0 : 1;
}
