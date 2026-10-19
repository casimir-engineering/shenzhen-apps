/* spdf_win_print_preview_geom.h — WHERE THE PREVIEW'S RECTANGLES COME FROM, as
 * pure arithmetic: no Windows types, no HDC, no window, no document.
 *
 * WHY A SECOND HEADER AND NOT A SECOND PLACEMENT. The page's rectangle on the
 * paper is decided by spdf_win_print_dest_rect() in spdf_win_print_math.h —
 * transcribed from the GTK original and compared against it at 1,944,132
 * points by portable/win/tests/print_differential.c. A preview that computed
 * its own "close enough" placement would be a SECOND answer to the same
 * question, and the first time the two disagreed the reader would be shown a
 * lie. So spdf_win_preview_layout_for() below CALLS that function, keeps its
 * output verbatim in `dest_pt`, and does nothing to it but a uniform scale and
 * a translation into the preview pane. portable/win/tests/print_preview_test.c
 * asserts exactly that: `dest_pt` must equal spdf_win_print_dest_rect()'s
 * output bit for bit, and every drawn rectangle must be that rect times
 * `px_per_pt`. That assertion cannot be satisfied by an approximation.
 *
 * WHAT THE THREE RECTANGLES MEAN, and where each number comes from:
 *
 *   sheet   the WHOLE piece of paper. PHYSICALWIDTH/PHYSICALHEIGHT from the
 *           printer DC, which already reflect the DEVMODE's dmPaperSize and
 *           dmOrientation (a landscape DEVMODE yields a wider PHYSICALWIDTH).
 *           When a driver reports no full sheet at all, the DEVMODE's own
 *           dmPaperWidth/dmPaperLength — tenths of a millimetre, describing the
 *           STOCK rather than the print direction, so dmOrientation swaps them.
 *   image   the printable area inside it: HORZRES/VERTRES, offset by
 *           PHYSICALOFFSETX/PHYSICALOFFSETY. The band between the two is the
 *           driver's UNPRINTABLE MARGIN, and it is drawn rather than silently
 *           applied: a reader should be able to see that this printer cannot
 *           reach the edge of the sheet.
 *   page    the document page inside the printable area, from
 *           spdf_win_print_dest_rect(). At Actual Size or a large Custom it can
 *           be BIGGER than the printable area and stick out past the sheet with
 *           a negative origin; the preview draws that overhang clipped, which
 *           is what the job does to it too (spdf_win_print_visible_source()).
 *
 * `sheet_measured` says which of those the driver actually told us. 0 means the
 * sheet was inferred and the unprintable border was assumed to be even on all
 * four sides — the caller shows that as a caveat instead of pretending.
 *
 * COORDINATE SPACES. Everything ending _pt is PDF/paper points. Everything in
 * spdf_win_preview_layout is PREVIEW PANE pixels, origin at the pane's top-left
 * corner, y downward — device pixels at whatever DPI the dialog landed on,
 * because the caller has already scaled the pane it hands in.
 */
#ifndef SPDF_WIN_PRINT_PREVIEW_GEOM_H
#define SPDF_WIN_PRINT_PREVIEW_GEOM_H

#include "spdf_win_print_math.h"

#ifdef __cplusplus
extern "C" {
#endif

/* DEVMODE states paper in tenths of a millimetre; 1 pt is 25.4/72 mm. */
#define SPDF_WIN_PREVIEW_PT_PER_TENTH_MM (72.0 / 254.0)

/* The preview's own render-zoom band. A preview sheet is a couple of hundred
 * pixels across, so the bitmap behind it is tiny — well under a megabyte, which
 * is why the whole page range can sit in a small cache. The ceiling matters
 * when a reader picks Custom 800%: the page rect is then eight times the sheet
 * and only the visible eighth is worth any resolution at all. */
#define SPDF_WIN_PREVIEW_MIN_ZOOM 0.04
#define SPDF_WIN_PREVIEW_MAX_ZOOM 1.5
/* Zooms snap to 1/32 of a pixel per point so that a resize of one pixel, or a
 * percentage typed one digit at a time, reuses the cached bitmap instead of
 * starting a render per keystroke. */
#define SPDF_WIN_PREVIEW_ZOOM_STEP 32.0

typedef struct spdf_win_preview_sheet {
    double sheet_w_pt; /* the whole sheet */
    double sheet_h_pt;
    double margin_l_pt; /* the unprintable border, one value per side */
    double margin_t_pt;
    double margin_r_pt;
    double margin_b_pt;
    double imageable_w_pt; /* == sheet minus the two margins on that axis */
    double imageable_h_pt;
    double dpi_x;
    double dpi_y;
    /* 1 when PHYSICALWIDTH/HEIGHT gave the sheet and PHYSICALOFFSETX/Y gave the
     * border; 0 when either was inferred and the border was assumed even. */
    int sheet_measured;
} spdf_win_preview_sheet;

static SPDF_WIN_INLINE void spdf_win_preview_sheet_clear(spdf_win_preview_sheet* out) {
    out->sheet_w_pt = 0.0;
    out->sheet_h_pt = 0.0;
    out->margin_l_pt = 0.0;
    out->margin_t_pt = 0.0;
    out->margin_r_pt = 0.0;
    out->margin_b_pt = 0.0;
    out->imageable_w_pt = 0.0;
    out->imageable_h_pt = 0.0;
    out->dpi_x = 0.0;
    out->dpi_y = 0.0;
    out->sheet_measured = 0;
}

/* The DEVMODE's own stock, in points. `have_paper_size` is whether dmFields
 * carried DM_PAPERWIDTH | DM_PAPERLENGTH — a DEVMODE that names only a
 * dmPaperSize code leaves those two fields meaningless, and guessing a size
 * from the code would be inventing paper. `landscape` is dmOrientation ==
 * DMORIENT_LANDSCAPE. Returns 0, and zeroes both outputs, when there is nothing
 * usable to report. */
static SPDF_WIN_INLINE int spdf_win_preview_paper_pt(int have_paper_size, int tenths_mm_w, int tenths_mm_h,
                                                     int landscape, double* out_w_pt, double* out_h_pt) {
    double w;
    double h;

    if (!out_w_pt || !out_h_pt) return 0;
    *out_w_pt = 0.0;
    *out_h_pt = 0.0;
    if (!have_paper_size || tenths_mm_w <= 0 || tenths_mm_h <= 0) return 0;
    w = (double)tenths_mm_w * SPDF_WIN_PREVIEW_PT_PER_TENTH_MM;
    h = (double)tenths_mm_h * SPDF_WIN_PREVIEW_PT_PER_TENTH_MM;
    if (landscape) {
        double swap = w;
        w = h;
        h = swap;
    }
    *out_w_pt = w;
    *out_h_pt = h;
    return 1;
}

/* GetDeviceCaps numbers (plus the DEVMODE's paper as a last resort) into the
 * sheet above. Deliberately plain ints so print_preview_test.c can drive real
 * drivers' numbers with no printer attached, exactly as
 * spdf_win_print_paper_from_caps() is driven.
 *
 * The printable area is NOT recomputed here: it is
 * spdf_win_print_paper_from_caps()'s, the same conversion the job uses, so the
 * preview and the job agree about the area the page is centred on even before
 * the placement is asked for. Returns 0 (and zeroes *out) when the caps are
 * unusable. */
static SPDF_WIN_INLINE int spdf_win_preview_sheet_build(int logpixels_x, int logpixels_y, int phys_w, int phys_h,
                                                        int phys_off_x, int phys_off_y, int horz_res, int vert_res,
                                                        double dm_paper_w_pt, double dm_paper_h_pt,
                                                        spdf_win_preview_sheet* out) {
    spdf_win_print_paper paper;
    double off_x;
    double off_y;

    if (!out) return 0;
    spdf_win_preview_sheet_clear(out);
    if (!spdf_win_print_paper_from_caps(logpixels_x, logpixels_y, horz_res, vert_res, &paper)) return 0;
    out->dpi_x = paper.dpi_x;
    out->dpi_y = paper.dpi_y;
    out->imageable_w_pt = paper.imageable_w_pt;
    out->imageable_h_pt = paper.imageable_h_pt;

    if (phys_w >= horz_res && phys_h >= vert_res) {
        /* The normal case, and the only one where the border is a measurement.
         * A driver that prints edge to edge — Microsoft Print to PDF reports
         * PHYSICALWIDTH == HORZRES and a zero offset — lands here with all four
         * margins at zero, which is the truth about it and not a fallback. */
        out->sheet_w_pt = (double)phys_w * 72.0 / paper.dpi_x;
        out->sheet_h_pt = (double)phys_h * 72.0 / paper.dpi_y;
        off_x = (double)spdf_win_clamp_d((double)phys_off_x, 0.0, (double)(phys_w - horz_res));
        off_y = (double)spdf_win_clamp_d((double)phys_off_y, 0.0, (double)(phys_h - vert_res));
        out->margin_l_pt = off_x * 72.0 / paper.dpi_x;
        out->margin_t_pt = off_y * 72.0 / paper.dpi_y;
        out->sheet_measured = 1;
    } else if (dm_paper_w_pt >= paper.imageable_w_pt && dm_paper_h_pt >= paper.imageable_h_pt) {
        /* No full sheet from the driver, but the DEVMODE named the stock. The
         * border must then be ASSUMED even on all four sides — nothing here
         * knows which edge the driver keeps clear — and sheet_measured says so. */
        out->sheet_w_pt = dm_paper_w_pt;
        out->sheet_h_pt = dm_paper_h_pt;
        out->margin_l_pt = (dm_paper_w_pt - paper.imageable_w_pt) / 2.0;
        out->margin_t_pt = (dm_paper_h_pt - paper.imageable_h_pt) / 2.0;
    } else {
        /* Neither. The printable area is all this printer will admit to, so it
         * is drawn as the whole sheet — and sheet_measured stays 0, because the
         * paper around it is not known to be absent, only unreported. */
        out->sheet_w_pt = paper.imageable_w_pt;
        out->sheet_h_pt = paper.imageable_h_pt;
    }
    out->margin_r_pt = spdf_win_max_d(0.0, out->sheet_w_pt - out->margin_l_pt - out->imageable_w_pt);
    out->margin_b_pt = spdf_win_max_d(0.0, out->sheet_h_pt - out->margin_t_pt - out->imageable_h_pt);
    return out->sheet_w_pt > 0.0 && out->sheet_h_pt > 0.0;
}

typedef struct spdf_win_preview_layout {
    int valid;
    double px_per_pt;              /* the ONE scale every rectangle below shares */
    spdf_win_print_rect sheet;      /* the paper, preview px */
    spdf_win_print_rect image;      /* the printable area, preview px */
    spdf_win_print_rect page;       /* the document page, preview px, UNCLIPPED */
    spdf_win_print_rect dest_pt;    /* spdf_win_print_dest_rect()'s output, verbatim */
    double mode_scale;              /* spdf_win_print_mode_scale()'s, verbatim */
} spdf_win_preview_layout;

/* The whole preview, from the sheet and the reader's choice. `pane_w`/`pane_h`
 * are the pixels available for the paper (the caller has already taken the
 * caption, the caveat line and the page stepper out of them).
 *
 * ONE SCALE, `px_per_pt` = min(pane_w / sheet_w, pane_h / sheet_h), so the
 * sheet fits the pane in whichever direction is tighter and stays the shape the
 * DEVMODE says it is. The sheet is centred in the pane; the printable area sits
 * inside it at the measured border; the page sits inside THAT wherever
 * spdf_win_print_dest_rect() puts it.
 *
 * `page_w_pt`/`page_h_pt` are the PDF page's own size. Returns 0 with
 * out->valid == 0 when there is nothing to draw. */
static SPDF_WIN_INLINE int spdf_win_preview_layout_for(const spdf_win_preview_sheet* sheet, double page_w_pt,
                                                       double page_h_pt, spdf_win_print_scaling_mode mode,
                                                       double custom_scale, double pane_w, double pane_h,
                                                       spdf_win_preview_layout* out) {
    double s;

    if (!out) return 0;
    out->valid = 0;
    out->px_per_pt = 0.0;
    out->mode_scale = 1.0;
    out->sheet.x = out->sheet.y = out->sheet.w = out->sheet.h = 0.0;
    out->image = out->sheet;
    out->page = out->sheet;
    out->dest_pt = out->sheet;
    if (!sheet || sheet->sheet_w_pt <= 0.0 || sheet->sheet_h_pt <= 0.0) return 0;
    if (pane_w <= 0.0 || pane_h <= 0.0) return 0;

    s = spdf_win_min_d(pane_w / sheet->sheet_w_pt, pane_h / sheet->sheet_h_pt);
    if (!(s > 0.0)) return 0;
    out->px_per_pt = s;

    out->sheet.w = sheet->sheet_w_pt * s;
    out->sheet.h = sheet->sheet_h_pt * s;
    out->sheet.x = (pane_w - out->sheet.w) / 2.0;
    out->sheet.y = (pane_h - out->sheet.h) / 2.0;

    out->image.x = out->sheet.x + sheet->margin_l_pt * s;
    out->image.y = out->sheet.y + sheet->margin_t_pt * s;
    out->image.w = sheet->imageable_w_pt * s;
    out->image.h = sheet->imageable_h_pt * s;

    /* THE JOB'S OWN ARITHMETIC, unmodified, and kept so the test can compare it
     * against a direct call. Everything below is one multiply and one add. */
    out->mode_scale = spdf_win_print_mode_scale(page_w_pt, page_h_pt, sheet->imageable_w_pt, sheet->imageable_h_pt,
                                                mode, custom_scale);
    out->dest_pt = spdf_win_print_dest_rect(page_w_pt, page_h_pt, sheet->imageable_w_pt, sheet->imageable_h_pt, mode,
                                            custom_scale);
    out->page.x = out->image.x + out->dest_pt.x * s;
    out->page.y = out->image.y + out->dest_pt.y * s;
    out->page.w = out->dest_pt.w * s;
    out->page.h = out->dest_pt.h * s;
    out->valid = 1;
    return 1;
}

/* Device pixels per PDF point for the preview's own bitmap: the page rect's
 * width over the page's width, snapped to SPDF_WIN_PREVIEW_ZOOM_STEP and held
 * inside the band above so an 800% Custom does not ask for a poster. This is
 * the preview's render zoom ONLY — the job's is
 * spdf_win_print_render_zoom(), which aims at 300 dpi and is not this. */
static SPDF_WIN_INLINE double spdf_win_preview_render_zoom(double page_px_w, double page_w_pt) {
    double zoom;

    if (!(page_px_w > 0.0) || !(page_w_pt > 0.0)) return SPDF_WIN_PREVIEW_MIN_ZOOM;
    zoom = page_px_w / page_w_pt;
    zoom = floor(zoom * SPDF_WIN_PREVIEW_ZOOM_STEP + 0.5) / SPDF_WIN_PREVIEW_ZOOM_STEP;
    return spdf_win_clamp_d(zoom, SPDF_WIN_PREVIEW_MIN_ZOOM, SPDF_WIN_PREVIEW_MAX_ZOOM);
}

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SPDF_WIN_PRINT_PREVIEW_GEOM_H */
