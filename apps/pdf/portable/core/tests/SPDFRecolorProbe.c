/* Dark-reading recolor probe.
 *
 *   SPDFRecolorProbe <document> [page-index] [zoom] [out-dir]
 *
 * Renders one page through the same core entry point the mac and GTK frontends
 * use -- once plainly, once with SPDF_RENDER_DARK_THEME, once with the images
 * preserved -- so the SHIPPING path is what gets timed and photographed, not a
 * standalone copy of the math. It then applies each candidate transform to the
 * plain buffer for the quality comparison, writes before/after PNGs, and
 * prints the pixel evidence:
 *   - paper: the modal color of the page, which must land on the theme paper
 *   - ink: the mean of the pixels that were darkest before, which must land
 *     on the theme ink
 *   - hue: the mean absolute hue rotation of the saturated pixels, which must
 *     stay near zero for a transform that does not turn photos into negatives
 *
 * Nothing here launches or touches the app; it only writes PNGs into out-dir.
 */
#include "shenzhen_pdf_core.h"
#include "spdf_recolor.h"
#include "spdf_win_compat.h"

#include <mupdf/fitz.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* clock_gettime()/CLOCK_MONOTONIC are absent from the MSVC UCRT; the shim reads
 * QueryPerformanceCounter there and clock_gettime() everywhere else. */
static double now_ms(void) {
    return spdf_compat_monotonic_ms();
}

static void write_png(const char* path, const unsigned char* rgba, int w, int h, int stride) {
    fz_context* ctx = fz_new_context(NULL, NULL, FZ_STORE_UNLIMITED);
    fz_pixmap* pix;
    int y;

    if (!ctx) {
        fprintf(stderr, "png: no context\n");
        return;
    }
    fz_try(ctx) {
        pix = fz_new_pixmap(ctx, fz_device_rgb(ctx), w, h, NULL, 1);
        for (y = 0; y < h; ++y)
            memcpy(pix->samples + (size_t)y * (size_t)pix->stride, rgba + (size_t)y * (size_t)stride, (size_t)w * 4);
        fz_save_pixmap_as_png(ctx, pix, path);
        fz_drop_pixmap(ctx, pix);
    }
    fz_catch(ctx) { fprintf(stderr, "png: %s\n", fz_caught_message(ctx)); }
    fz_drop_context(ctx);
}

/* HSV hue in degrees; -1 for achromatic pixels. */
static double hue_of(int r, int g, int b) {
    int mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
    int mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
    int c = mx - mn;
    double h;

    if (c == 0) return -1.0;
    if (mx == r)
        h = fmod(((double)(g - b) / c), 6.0);
    else if (mx == g)
        h = (double)(b - r) / c + 2.0;
    else
        h = (double)(r - g) / c + 4.0;
    h *= 60.0;
    if (h < 0.0) h += 360.0;
    return h;
}

static double hue_delta(double a, double b) {
    double d = fabs(a - b);
    return d > 180.0 ? 360.0 - d : d;
}

typedef struct {
    size_t* darkest;   /* byte offsets of the darkest original pixels (the ink) */
    int darkest_count;
    size_t* colorful;  /* byte offsets of the most saturated original pixels */
    double* colorful_hue;
    int colorful_count;
    int modal_r, modal_g, modal_b; /* most common original color: the paper */
} probe_sites;

static void collect_sites(const unsigned char* rgba, int w, int h, int stride, probe_sites* out) {
    static int hist[32][32][32];
    int best = -1, br = 0, bg = 0, bb = 0;
    int x, y, i, j, k;
    int dark_cap = 20000, color_cap = 20000;

    memset(hist, 0, sizeof(hist));
    memset(out, 0, sizeof(*out));
    out->darkest = (size_t*)malloc(sizeof(size_t) * (size_t)dark_cap);
    out->colorful = (size_t*)malloc(sizeof(size_t) * (size_t)color_cap);
    out->colorful_hue = (double*)malloc(sizeof(double) * (size_t)color_cap);

    for (y = 0; y < h; ++y) {
        const unsigned char* row = rgba + (size_t)y * (size_t)stride;
        for (x = 0; x < w; ++x) {
            const unsigned char* px = row + (size_t)x * 4;
            int r = px[0], g = px[1], b = px[2];
            int mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
            int mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
            size_t off = (size_t)y * (size_t)stride + (size_t)x * 4;
            hist[r >> 3][g >> 3][b >> 3]++;
            if (mx < 60 && out->darkest_count < dark_cap) out->darkest[out->darkest_count++] = off;
            /* saturated and not near-black/near-white: a real colored figure */
            if (mx - mn > 70 && mx > 60 && out->colorful_count < color_cap) {
                out->colorful_hue[out->colorful_count] = hue_of(r, g, b);
                out->colorful[out->colorful_count++] = off;
            }
        }
    }
    for (i = 0; i < 32; ++i)
        for (j = 0; j < 32; ++j)
            for (k = 0; k < 32; ++k)
                if (hist[i][j][k] > best) {
                    best = hist[i][j][k];
                    br = i * 8 + 4;
                    bg = j * 8 + 4;
                    bb = k * 8 + 4;
                }
    out->modal_r = br;
    out->modal_g = bg;
    out->modal_b = bb;
}

static void report(const char* label, const unsigned char* rgba, int stride, const probe_sites* s, int w, int h) {
    static int hist[32][32][32];
    int best = -1, br = 0, bg = 0, bb = 0;
    long ir = 0, ig = 0, ib = 0;
    double hsum = 0.0;
    int hn = 0;
    int i, j, k, x, y;

    memset(hist, 0, sizeof(hist));
    for (y = 0; y < h; ++y) {
        const unsigned char* row = rgba + (size_t)y * (size_t)stride;
        for (x = 0; x < w; ++x) {
            const unsigned char* px = row + (size_t)x * 4;
            hist[px[0] >> 3][px[1] >> 3][px[2] >> 3]++;
        }
    }
    for (i = 0; i < 32; ++i)
        for (j = 0; j < 32; ++j)
            for (k = 0; k < 32; ++k)
                if (hist[i][j][k] > best) {
                    best = hist[i][j][k];
                    br = i * 8 + 4;
                    bg = j * 8 + 4;
                    bb = k * 8 + 4;
                }

    for (i = 0; i < s->darkest_count; ++i) {
        const unsigned char* px = rgba + s->darkest[i];
        ir += px[0];
        ig += px[1];
        ib += px[2];
    }
    for (i = 0; i < s->colorful_count; ++i) {
        const unsigned char* px = rgba + s->colorful[i];
        double hnew = hue_of(px[0], px[1], px[2]);
        if (hnew >= 0.0 && s->colorful_hue[i] >= 0.0) {
            hsum += hue_delta(hnew, s->colorful_hue[i]);
            hn++;
        }
    }

    printf("  %-14s paper #%02X%02X%02X", label, br, bg, bb);
    if (s->darkest_count)
        printf("  ink #%02X%02X%02X", (int)(ir / s->darkest_count), (int)(ig / s->darkest_count),
               (int)(ib / s->darkest_count));
    else
        printf("  ink (none)");
    if (hn)
        printf("  hue-shift %6.2f deg over %d px\n", hsum / hn, hn);
    else
        printf("  hue-shift (no saturated px)\n");
}

typedef struct {
    const char* name;
    spdf_recolor_mode mode;
} mode_entry;


/* Mean hue rotation and mean luma inside one rectangle. Run over the page's
 * largest image block this answers "did the photograph survive?" directly:
 * a negative shows ~180 deg of rotation, a lightness inversion shows ~0 deg of
 * rotation but a mirrored luma, and an excluded region shows neither. */
static void report_region(const char* label, const unsigned char* before, const unsigned char* after, int stride,
                          spdf_recolor_irect r) {
    double hsum = 0.0, lb = 0.0, la = 0.0;
    double sbb = 0.0, saa = 0.0, sba = 0.0;
    long n = 0, hn = 0;
    int x, y;

    for (y = r.y0; y < r.y1; ++y) {
        for (x = r.x0; x < r.x1; ++x) {
            size_t off = (size_t)y * (size_t)stride + (size_t)x * 4;
            const unsigned char* p0 = before + off;
            const unsigned char* p1 = after + off;
            double h0 = hue_of(p0[0], p0[1], p0[2]);
            double h1 = hue_of(p1[0], p1[1], p1[2]);
            double y0 = 0.299 * p0[0] + 0.587 * p0[1] + 0.114 * p0[2];
            double y1 = 0.299 * p1[0] + 0.587 * p1[1] + 0.114 * p1[2];
            lb += y0;
            la += y1;
            sbb += y0 * y0;
            saa += y1 * y1;
            sba += y0 * y1;
            n++;
            if (h0 >= 0.0 && h1 >= 0.0) {
                hsum += hue_delta(h0, h1);
                hn++;
            }
        }
    }
    if (!n) return;
    {
        /* Pearson correlation of per-pixel luma before vs after. +1 means the
         * region's lightness ordering is intact (the photo still reads as
         * itself); -1 means it was mirrored (a negative). */
        double cb = sbb - lb * lb / n;
        double ca = saa - la * la / n;
        double cv = sba - lb * la / n;
        double corr = (cb > 0.0 && ca > 0.0) ? cv / sqrt(cb * ca) : 0.0;
        printf("    photo region %-12s hue-shift %6.2f deg   mean luma %3.0f -> %3.0f   luma corr %+.3f\n", label,
               hn ? hsum / hn : 0.0, lb / n, la / n, corr);
    }
}

/* Best-of-N whole renders through the shipping entry point. Leaves the last
 * bitmap in `out` (owned by the caller). Returns -1.0 on failure. */
static double timed_render(spdf_document* doc, int page, float zoom, unsigned flags, int reps, spdf_bitmap* out,
                           char* err, size_t err_len) {
    double best = 1e30;
    int rep;

    for (rep = 0; rep < reps; ++rep) {
        double t0;
        if (rep) spdf_free_bitmap(out);
        t0 = now_ms();
        if (!spdf_render_page_rgba_opts(doc, page, zoom, flags, NULL, out, err, err_len)) return -1.0;
        {
            double dt = now_ms() - t0;
            if (dt < best) best = dt;
        }
    }
    return best;
}

/* Bounding box and count of the pixels a transform left byte identical. */
static long untouched_bounds(const unsigned char* before, const unsigned char* after, int w, int h, int stride,
                             spdf_recolor_irect* box) {
    long count = 0;
    int x, y;

    box->x0 = w;
    box->y0 = h;
    box->x1 = 0;
    box->y1 = 0;
    for (y = 0; y < h; ++y) {
        const unsigned char* a = before + (size_t)y * (size_t)stride;
        const unsigned char* b = after + (size_t)y * (size_t)stride;
        for (x = 0; x < w; ++x) {
            if (memcmp(a + (size_t)x * 4, b + (size_t)x * 4, 3) != 0) continue;
            count++;
            if (x < box->x0) box->x0 = x;
            if (x + 1 > box->x1) box->x1 = x + 1;
            if (y < box->y0) box->y0 = y;
            if (y + 1 > box->y1) box->y1 = y + 1;
        }
    }
    if (box->x1 <= box->x0 || box->y1 <= box->y0) {
        box->x0 = box->y0 = box->x1 = box->y1 = 0;
        return 0;
    }
    return count;
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : NULL;
    int page = argc > 2 ? atoi(argv[2]) : 0;
    float zoom = argc > 3 ? (float)atof(argv[3]) : 2.0f;
    const char* out_dir = argc > 4 ? argv[4] : ".";
    char err[512];
    spdf_document* doc;
    spdf_bitmap bitmap;
    unsigned char* original;
    unsigned char* work;
    size_t bytes;
    probe_sites sites;
    spdf_recolor_theme theme = spdf_recolor_default_dark_theme();
    char png[1024];
    int i;
    spdf_recolor_irect kept = {0, 0, 0, 0};
    long kept_area = 0;
    double plain_ms, dark_ms, images_ms;
    const int reps = 20;
    mode_entry modes[3] = {{"invert", SPDF_RECOLOR_INVERT},
                           {"tint", SPDF_RECOLOR_TINT},
                           {"luma-remap", SPDF_RECOLOR_LUMA_REMAP}};

    if (!path) {
        fprintf(stderr, "usage: SPDFRecolorProbe <document> [page] [zoom] [out-dir]\n");
        return 2;
    }

    doc = spdf_open(path, err, sizeof(err));
    if (!doc) {
        fprintf(stderr, "open failed: %s\n", err);
        return 1;
    }

    plain_ms = timed_render(doc, page, zoom, SPDF_RENDER_DEFAULT, reps, &bitmap, err, sizeof(err));
    if (plain_ms < 0.0) {
        fprintf(stderr, "render failed: %s\n", err);
        spdf_close(doc);
        return 1;
    }
    printf("document  %s\npage      %d @ zoom %.2f -> %dx%d px (%.1f MB)\n", path, page, zoom, bitmap.width,
           bitmap.height, (double)bitmap.stride * bitmap.height / (1024.0 * 1024.0));

    bytes = (size_t)bitmap.stride * (size_t)bitmap.height;
    original = (unsigned char*)malloc(bytes);
    work = (unsigned char*)malloc(bytes);
    if (!original || !work) {
        fprintf(stderr, "out of memory\n");
        return 1;
    }
    memcpy(original, bitmap.rgba, bytes);

    collect_sites(original, bitmap.width, bitmap.height, bitmap.stride, &sites);
    printf("sites     %d dark px (ink), %d saturated px (color figures), modal paper #%02X%02X%02X\n\n",
           sites.darkest_count, sites.colorful_count, sites.modal_r, sites.modal_g, sites.modal_b);

    snprintf(png, sizeof(png), "%s/recolor-before.png", out_dir);
    write_png(png, original, bitmap.width, bitmap.height, bitmap.stride);
    printf("wrote     %s\n", png);
    printf("  %-14s (unmodified reference)\n", "before");
    report("before", original, bitmap.stride, &sites, bitmap.width, bitmap.height);
    printf("\n");

    /* --- The shipping path, end to end --------------------------------- *
     * The recolor is fused into the core's pixmap -> RGBA tail, so the honest
     * cost is the difference between two whole renders, not a standalone loop
     * over a buffer that is already hot. */
    {
        spdf_bitmap dark;
        dark_ms = timed_render(doc, page, zoom, SPDF_RENDER_DARK_THEME, reps, &dark, err, sizeof(err));
        if (dark_ms < 0.0) {
            fprintf(stderr, "dark render failed: %s\n", err);
            return 1;
        }
        printf("  %-14s %.3f ms best of %d (plain render %.3f ms; fused recolor costs %+.3f ms)\n", "RENDER dark",
               dark_ms, reps, plain_ms, dark_ms - plain_ms);
        report("RENDER dark", dark.rgba, dark.stride, &sites, dark.width, dark.height);
        snprintf(png, sizeof(png), "%s/recolor-render-dark.png", out_dir);
        write_png(png, dark.rgba, dark.width, dark.height, dark.stride);
        printf("  wrote %s\n\n", png);
        spdf_free_bitmap(&dark);
    }

    {
        spdf_bitmap dark;
        images_ms = timed_render(doc, page, zoom, SPDF_RENDER_DARK_THEME | SPDF_RENDER_PRESERVE_IMAGES, reps, &dark,
                                 err, sizeof(err));
        if (images_ms < 0.0) {
            fprintf(stderr, "preserve-images render failed: %s\n", err);
            return 1;
        }
        /* The pixels the preserve-images render left byte identical ARE the
         * excluded image blocks; their bounding box is what the photograph
         * fidelity below is measured over. An empty box means the page had no
         * image blocks, or was image-backed (a scan) and so was deliberately
         * recolored whole despite the setting. */
        kept_area = untouched_bounds(original, dark.rgba, bitmap.width, bitmap.height, bitmap.stride, &kept);
        printf("  %-14s %.3f ms best of %d (+%.3f ms over plain; image blocks excluded)\n", "RENDER dark+img",
               images_ms, reps, images_ms - plain_ms);
        printf("  %-14s %ld px kept byte identical = %.1f%% of the page, bbox %d,%d-%d,%d\n", "", kept_area,
               100.0 * (double)kept_area / ((double)bitmap.width * bitmap.height), kept.x0, kept.y0, kept.x1, kept.y1);
        report("RENDER dark+img", dark.rgba, dark.stride, &sites, dark.width, dark.height);
        if (kept_area > 0) report_region("RENDER dark+img", original, dark.rgba, dark.stride, kept);
        snprintf(png, sizeof(png), "%s/recolor-render-dark-images.png", out_dir);
        write_png(png, dark.rgba, dark.width, dark.height, dark.stride);
        printf("  wrote %s\n\n", png);
        spdf_free_bitmap(&dark);
    }

    /* Bandwidth floor: the core's pixmap -> RGBA copy already reads and writes
     * every pixel once, so this memcpy is the baseline the numbers above and
     * below should be read against. */
    {
        double best = 1e30;
        int rep;
        for (rep = 0; rep < reps; ++rep) {
            double t0 = now_ms();
            memcpy(work, original, bytes);
            {
                double dt = now_ms() - t0;
                if (dt < best) best = dt;
            }
        }
        printf("  %-14s %.3f ms best of %d (bandwidth floor for one full-buffer pass)\n\n", "memcpy", best, reps);
    }

    /* --- Quality comparison against the alternatives -------------------- */
    for (i = 0; i < 3; ++i) {
        spdf_recolor_table table;
        double best = 1e30;
        int rep;

        spdf_recolor_table_init(&table, modes[i].mode, theme);
        for (rep = 0; rep < reps; ++rep) {
            double t0;
            memcpy(work, original, bytes);
            t0 = now_ms();
            spdf_recolor_rgba(work, bitmap.width, bitmap.height, bitmap.stride, &table);
            {
                double dt = now_ms() - t0;
                if (dt < best) best = dt;
            }
        }
        printf("  %-14s %.3f ms best of %d (%.1f Mpx/s, standalone pass)\n", modes[i].name, best, reps,
               (double)bitmap.width * bitmap.height / best / 1000.0);
        report(modes[i].name, work, bitmap.stride, &sites, bitmap.width, bitmap.height);
        if (kept_area > 0) report_region(modes[i].name, original, work, bitmap.stride, kept);
        snprintf(png, sizeof(png), "%s/recolor-%s.png", out_dir, modes[i].name);
        write_png(png, work, bitmap.width, bitmap.height, bitmap.stride);
        printf("  wrote %s\n\n", png);
    }

    free(original);
    free(work);
    free(sites.darkest);
    free(sites.colorful);
    free(sites.colorful_hue);
    spdf_free_bitmap(&bitmap);
    spdf_close(doc);
    return 0;
}
