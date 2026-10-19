/* spdf_win_print_math.h — the print job's PURE arithmetic: scaling mode,
 * destination rect on the paper, the visible-source split for oversized pages,
 * and the render-zoom (dpi + memory) policy.
 *
 * THIS IS A TRANSCRIPTION, NOT A DESIGN. Every function below is ported line
 * for line from portable/linux/gtk4/spdf_print.c section 1, which is itself a
 * port of the macOS accessory helpers (SPDFClampPrintCustomScale,
 * spdf_print_scale_for_mode, spdf_print_destination_rect in
 * SPDFMacPrintView.mm). portable/win/tests/print_differential.c compiles that
 * GTK source beside this header — SPDF_PRINT_TESTING makes it glib-only, and
 * portable/win/tests/glib_shim/ already supplies the CLAMP/MAX/MIN macros and
 * the gboolean typedef it needs — and compares the two EXACTLY, the same
 * instrument as layout.differential, the minimap differential, the search
 * differential and the selection differential. That discipline has already
 * caught a one-ulp transcription error in this port, which is why a hand
 * written test is not considered sufficient for a transcription.
 *
 * The comparison order in the MAX/MIN/CLAMP expressions is load-bearing and is
 * reproduced through spdf_win_max_d/min_d/clamp_d (spdf_win_layout.h), which
 * spell glib's own bodies out for exactly this reason: CLAMP with hi < lo
 * yields hi, and every comparison against NaN is false so MAX(NaN, b) is b.
 *
 * NO WINDOWS TYPES, NO CORE TYPES, NO DOCUMENT. Everything here is doubles in
 * and doubles out, so portable/win/tests/print_math_test.c and the differential
 * both drive it with no MuPDF, no printer and no window — which is the only
 * reason the print path can be tested at all on a locked workstation where a
 * print dialog cannot be shown.
 *
 * COORDINATE SPACE: PDF points throughout, the imageable (printable) area's
 * origin at (0, 0) and y increasing DOWNWARD. That is GtkPrintContext's
 * draw-page space, and spdf_win_print_paper_from_caps() at the end of this file
 * is what turns a Win32 printer DC's GetDeviceCaps numbers into it — also pure
 * arithmetic, also tested here, so that nothing in the print path needs a
 * printer in order to be checked.
 */
#ifndef SPDF_WIN_PRINT_MATH_H
#define SPDF_WIN_PRINT_MATH_H

#include <math.h>

#include "spdf_win_layout.h" /* SPDF_WIN_INLINE, spdf_win_max_d/min_d/clamp_d */

#ifdef __cplusplus
extern "C" {
#endif

/* Persisted as settings.json "printScalingMode"; the values must match the Mac
 * SPDFPrintScalingMode enum and the GTK SpdfPrintScalingMode. */
typedef enum spdf_win_print_scaling_mode {
    SPDF_WIN_PRINT_SCALING_FIT = 0,
    SPDF_WIN_PRINT_SCALING_ACTUAL = 1,
    SPDF_WIN_PRINT_SCALING_CUSTOM = 2
} spdf_win_print_scaling_mode;

/* Same limits as the Mac accessory and the settings.json clamp. */
#define SPDF_WIN_PRINT_MIN_CUSTOM_SCALE 0.10
#define SPDF_WIN_PRINT_MAX_CUSTOM_SCALE 8.0

/* Render-resolution policy, identical constants to the GTK original:
 * never below 72 dpi, aim for at least 300 dpi even when the driver reports a
 * nominal 72 (print-to-file / preview), 150 dpi ceiling when the document
 * denies HIGH-QUALITY printing, and a hard RGBA byte cap that wins over the
 * dpi target. */
#define SPDF_WIN_PRINT_MIN_RENDER_ZOOM 1.0
#define SPDF_WIN_PRINT_TARGET_DPI_FLOOR 300.0
#define SPDF_WIN_PRINT_RESTRICTED_DPI 150.0
#define SPDF_WIN_PRINT_RENDER_BYTE_CAP (128.0 * 1024.0 * 1024.0)
#define SPDF_WIN_PRINT_MAX_RENDER_DIMENSION 16384.0

typedef struct spdf_win_print_rect {
    double x;
    double y;
    double w;
    double h;
} spdf_win_print_rect;

/* Non-finite / non-positive -> 1.0, else clamped into [0.10, 8.0]. */
static SPDF_WIN_INLINE double spdf_win_print_clamp_custom_scale(double scale) {
    if (!isfinite(scale) || scale <= 0.0) return 1.0;
    return spdf_win_clamp_d(scale, SPDF_WIN_PRINT_MIN_CUSTOM_SCALE, SPDF_WIN_PRINT_MAX_CUSTOM_SCALE);
}

/* Points-on-paper per PDF point. Fit = min(iw/pw, ih/ph) and may GROW a small
 * page; Actual = 1.0; Custom = the clamped custom scale. Degenerate inputs
 * fall back to 1.0 rather than to a division. */
static SPDF_WIN_INLINE double spdf_win_print_mode_scale(double page_w, double page_h, double imageable_w,
                                                        double imageable_h, spdf_win_print_scaling_mode mode,
                                                        double custom_scale) {
    if (page_w <= 0.0 || page_h <= 0.0 || imageable_w <= 0.0 || imageable_h <= 0.0) return 1.0;
    if (mode == SPDF_WIN_PRINT_SCALING_ACTUAL) return 1.0;
    if (mode == SPDF_WIN_PRINT_SCALING_CUSTOM) return spdf_win_print_clamp_custom_scale(custom_scale);
    return spdf_win_min_d(imageable_w / page_w, imageable_h / page_h);
}

/* The scaled page centered on the imageable area, at least 1x1 pt. An
 * oversized result (Actual or Custom on a big sheet) deliberately overflows
 * the paper with a negative origin; spdf_win_print_visible_source() is what
 * turns that into the region actually worth rendering. */
static SPDF_WIN_INLINE spdf_win_print_rect spdf_win_print_dest_rect(double page_w, double page_h, double imageable_w,
                                                                    double imageable_h,
                                                                    spdf_win_print_scaling_mode mode,
                                                                    double custom_scale) {
    double scale = spdf_win_print_mode_scale(page_w, page_h, imageable_w, imageable_h, mode, custom_scale);
    spdf_win_print_rect rect;

    rect.w = spdf_win_max_d(1.0, page_w * scale);
    rect.h = spdf_win_max_d(1.0, page_h * scale);
    rect.x = (imageable_w - rect.w) / 2.0;
    rect.y = (imageable_h - rect.h) / 2.0;
    return rect;
}

/* Intersect the destination with the paper and map the overlap back onto the
 * page. *src_pt is the page region (page points, origin top-left) that must be
 * rendered; *dst_pt is where it lands on the paper. This is what keeps print
 * memory proportional to PAPER area rather than to page area on an oversized
 * Actual/Custom job — a 1224 pt foldout printed at 100% would otherwise be
 * rasterised in full to have three quarters of it thrown away. Returns 0 when
 * nothing of the page is visible. */
static SPDF_WIN_INLINE int spdf_win_print_visible_source(const spdf_win_print_rect* dest, double page_w, double page_h,
                                                         double imageable_w, double imageable_h,
                                                         spdf_win_print_rect* src_pt, spdf_win_print_rect* dst_pt) {
    double scale;
    double x0;
    double y0;
    double x1;
    double y1;

    if (!dest || !src_pt || !dst_pt) return 0;
    if (dest->w <= 0.0 || dest->h <= 0.0 || page_w <= 0.0 || page_h <= 0.0) return 0;
    if (imageable_w <= 0.0 || imageable_h <= 0.0) return 0;

    scale = dest->w / page_w; /* uniform by construction of the dest rect */
    x0 = spdf_win_max_d(dest->x, 0.0);
    y0 = spdf_win_max_d(dest->y, 0.0);
    x1 = spdf_win_min_d(dest->x + dest->w, imageable_w);
    y1 = spdf_win_min_d(dest->y + dest->h, imageable_h);
    if (x1 <= x0 || y1 <= y0) return 0;

    dst_pt->x = x0;
    dst_pt->y = y0;
    dst_pt->w = x1 - x0;
    dst_pt->h = y1 - y0;
    src_pt->x = (x0 - dest->x) / scale;
    src_pt->y = (y0 - dest->y) / scale;
    src_pt->w = dst_pt->w / scale;
    src_pt->h = dst_pt->h / scale;
    return 1;
}

/* Device pixels per PDF point for one page: mode_scale x max(dpi_x, dpi_y)/72,
 * raised to the 300 dpi floor and the 1.0 minimum, then shrunk CONTINUOUSLY
 * (not the Mac's halving loop) so the rendered region stays under byte_cap
 * bytes of RGBA and under the dimension cap. byte_cap <= 0 disables the byte
 * cap, which is how the tests reach the dimension cap on its own. */
static SPDF_WIN_INLINE double spdf_win_print_render_zoom(double mode_scale, double dpi_x, double dpi_y,
                                                         double src_w_pt, double src_h_pt, double byte_cap) {
    double dpi = spdf_win_max_d(dpi_x, dpi_y);
    double zoom;
    double bytes;
    double max_dim;

    if (!isfinite(dpi) || dpi < SPDF_WIN_PRINT_TARGET_DPI_FLOOR) dpi = SPDF_WIN_PRINT_TARGET_DPI_FLOOR;
    if (!isfinite(mode_scale) || mode_scale <= 0.0) mode_scale = 1.0;
    zoom = mode_scale * dpi / 72.0;
    if (zoom < SPDF_WIN_PRINT_MIN_RENDER_ZOOM) zoom = SPDF_WIN_PRINT_MIN_RENDER_ZOOM;
    if (src_w_pt <= 0.0 || src_h_pt <= 0.0) return zoom;

    if (byte_cap > 0.0) {
        bytes = src_w_pt * zoom * src_h_pt * zoom * 4.0;
        if (bytes > byte_cap) zoom *= sqrt(byte_cap / bytes);
    }
    max_dim = spdf_win_max_d(src_w_pt, src_h_pt) * zoom;
    if (max_dim > SPDF_WIN_PRINT_MAX_RENDER_DIMENSION) zoom *= SPDF_WIN_PRINT_MAX_RENDER_DIMENSION / max_dim;
    return spdf_win_max_d(zoom, 0.05);
}

/* Apply the PDF HIGH-QUALITY-print permission ('h') after the normal quality
 * and memory policy: a restricted job never exceeds 150 effective dpi. Note
 * this is the 'h' flag, NOT 'p' — 'p' decides whether the job runs at all and
 * is answered in spdf_win_print.cpp, before any of this arithmetic. */
static SPDF_WIN_INLINE double spdf_win_print_permission_render_zoom(double render_zoom, double mode_scale,
                                                                    int high_quality_allowed) {
    double restricted_zoom;

    if (!isfinite(render_zoom) || render_zoom <= 0.0) return 0.05;
    if (high_quality_allowed) return render_zoom;
    if (!isfinite(mode_scale) || mode_scale <= 0.0) mode_scale = 1.0;
    restricted_zoom = spdf_win_max_d(0.05, mode_scale * SPDF_WIN_PRINT_RESTRICTED_DPI / 72.0);
    return spdf_win_min_d(render_zoom, restricted_zoom);
}

/* --- the page range -------------------------------------------------------
 *
 * Win32 hands a print job either "all pages", "the current selection" or a set
 * of PRINTPAGERANGE {nFromPage, nToPage} pairs, 1-based and inclusive, in the
 * order the user typed them and with no guarantee they are sorted, disjoint or
 * inside the document. This turns one such request into the ordered, unique,
 * clamped 0-BASED list the render loop walks, so that the loop itself contains
 * no range logic at all and the whole of it is testable without a printer.
 *
 * Duplicates are dropped rather than printed twice: "1-3,2" is three sheets on
 * macOS and on GTK, and a reader who typed an overlapping range meant to name
 * pages, not to ask for copies (copies are a separate field on every print
 * dialog). Order is ASCENDING page order for the same reason. */
typedef struct spdf_win_print_page_range {
    int from; /* 1-based, inclusive, as Win32 delivers it */
    int to;   /* 1-based, inclusive */
} spdf_win_print_page_range;

/* Expand `ranges` against a document of `page_count` pages into `out` (0-based
 * page indices, ascending, unique, all in [0, page_count)). A NULL/empty range
 * list means the whole document. Returns the number of indices written, or -1
 * when out is NULL or out_max is too small to hold the result.
 *
 * out_max must be at least page_count for the all-pages case; callers size the
 * buffer from spdf_page_count(). */
static SPDF_WIN_INLINE int spdf_win_print_expand_ranges(const spdf_win_print_page_range* ranges, int range_count,
                                                        int page_count, int* out, int out_max) {
    int written = 0;
    int page;
    int i;

    if (!out || out_max <= 0 || page_count <= 0) return -1;
    if (!ranges || range_count <= 0) {
        if (out_max < page_count) return -1;
        for (page = 0; page < page_count; ++page) out[written++] = page;
        return written;
    }
    /* One pass per page rather than per range keeps the output sorted and
     * unique without a sort or a set: page_count is small (a 10,000 page
     * document with 4 ranges is 40,000 integer comparisons, microseconds) and
     * an O(n log n) sort plus a dedup pass would be more code for no
     * measurable gain. */
    for (page = 0; page < page_count; ++page) {
        for (i = 0; i < range_count; ++i) {
            int from = ranges[i].from;
            int to = ranges[i].to;
            if (from > to) { /* a reversed pair still names a range */
                int swap = from;
                from = to;
                to = swap;
            }
            if (page + 1 >= from && page + 1 <= to) {
                if (written >= out_max) return -1;
                out[written++] = page;
                break;
            }
        }
    }
    return written;
}

/* --- the paper, from a printer DC ----------------------------------------
 *
 * GetDeviceCaps numbers in, the coordinate space every function above works
 * in out. Deliberately takes plain ints rather than an HDC so it is pure and
 * so print_math_test.c can drive real printers' numbers (600 dpi laser,
 * 4800x1200 asymmetric inkjet, a 72 dpi "Print to PDF" pseudo-device) with no
 * printer attached.
 *
 * HORZRES/VERTRES are already the PRINTABLE area in device pixels and the DC's
 * origin is already its top-left corner, so PHYSICALOFFSETX/Y do not enter:
 * they only matter to code that wants full-sheet coordinates, and centring on
 * the printable area is what all three frontends do. A driver reporting a
 * non-square resolution (many inkjets report 4800x1200) keeps both axes here;
 * spdf_win_print_render_zoom() takes the max, so the render never under-
 * samples the finer axis. */
typedef struct spdf_win_print_paper {
    double dpi_x;
    double dpi_y;
    double imageable_w_pt;
    double imageable_h_pt;
} spdf_win_print_paper;

/* Returns 0 (and zeroes *out) when the caps are unusable — a driver that
 * reports 0 dpi or a zero-width page exists, and dividing by it would produce
 * an infinite zoom rather than a diagnosable failure. */
static SPDF_WIN_INLINE int spdf_win_print_paper_from_caps(int logpixels_x, int logpixels_y, int horz_res,
                                                          int vert_res, spdf_win_print_paper* out) {
    if (!out) return 0;
    out->dpi_x = 0.0;
    out->dpi_y = 0.0;
    out->imageable_w_pt = 0.0;
    out->imageable_h_pt = 0.0;
    if (logpixels_x <= 0 || logpixels_y <= 0 || horz_res <= 0 || vert_res <= 0) return 0;
    out->dpi_x = (double)logpixels_x;
    out->dpi_y = (double)logpixels_y;
    out->imageable_w_pt = (double)horz_res * 72.0 / (double)logpixels_x;
    out->imageable_h_pt = (double)vert_res * 72.0 / (double)logpixels_y;
    return 1;
}

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SPDF_WIN_PRINT_MATH_H */
