/* spdf_win_print.cpp — see spdf_win_print.h. */

#include "spdf_win_print.h"

#include "spdf_win_clipboard_page.h" /* spdf_win_clipboard_alloc_dib */
#include "spdf_win_export.h"         /* the light-theme rule */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "gdi32.lib")

/* --- permissions ---------------------------------------------------------- */

int spdf_win_print_allowed(spdf_document* doc) {
    return doc && spdf_has_permission(doc, 'p') ? 1 : 0;
}

int spdf_win_print_high_quality_allowed(spdf_document* doc) {
    return doc && spdf_has_permission(doc, 'h') ? 1 : 0;
}

/* --- one page ------------------------------------------------------------- */

int spdf_win_print_page_to_dc(HDC dc, spdf_document* doc, int page_index, const spdf_win_print_paper* paper,
                              spdf_win_print_scaling_mode mode, double custom_scale, int high_quality_allowed,
                              char* err, size_t err_len) {
    float page_w = 0.0f, page_h = 0.0f;
    spdf_win_print_rect dest;
    spdf_win_print_rect src_pt;
    spdf_win_print_rect dst_pt;
    double mode_scale;
    double zoom;
    spdf_rect region;
    spdf_bitmap bitmap;
    HGLOBAL dib;
    unsigned char* base;
    BITMAPINFOHEADER* header;
    int dest_x, dest_y, dest_w, dest_h;
    int drawn;

    if (err && err_len) err[0] = '\0';
    if (!dc || !doc || !paper) return 0;
    if (!spdf_page_size(doc, page_index, &page_w, &page_h, err, err_len)) return 0;

    dest = spdf_win_print_dest_rect(page_w, page_h, paper->imageable_w_pt, paper->imageable_h_pt, mode, custom_scale);
    if (!spdf_win_print_visible_source(&dest, page_w, page_h, paper->imageable_w_pt, paper->imageable_h_pt, &src_pt,
                                       &dst_pt)) {
        /* Nothing of the page lands on the paper. A blank sheet is the honest
         * result, not a failure: the reader asked for a 10% custom scale on a
         * page that then fell outside the printable area, and refusing the
         * whole job would be worse than one empty page. */
        return 1;
    }

    mode_scale = spdf_win_print_mode_scale(page_w, page_h, paper->imageable_w_pt, paper->imageable_h_pt, mode,
                                           custom_scale);
    zoom = spdf_win_print_render_zoom(mode_scale, paper->dpi_x, paper->dpi_y, src_pt.w, src_pt.h,
                                      SPDF_WIN_PRINT_RENDER_BYTE_CAP);
    zoom = spdf_win_print_permission_render_zoom(zoom, mode_scale, high_quality_allowed);

    region.x0 = (float)src_pt.x;
    region.y0 = (float)src_pt.y;
    region.x1 = (float)(src_pt.x + src_pt.w);
    region.y1 = (float)(src_pt.y + src_pt.h);

    memset(&bitmap, 0, sizeof(bitmap));
    /* spdf_win_export_render_flags() and NOTHING ELSE — see spdf_win_export.h.
     * A printed page carries the document's own colours. */
    if (!spdf_render_page_region_rgba_opts(doc, page_index, (float)zoom, region, spdf_win_export_render_flags(), NULL,
                                           &bitmap, err, err_len))
        return 0;

    /* Reuse of the clipboard's DIB packer, deliberately: it is the tested one,
     * it already handles a MuPDF stride wider than width*4, and a second
     * RGBA->BGRA loop in this file would be a second place to get the channel
     * order wrong. v5 = 0 gives a plain BITMAPINFOHEADER, bottom-up, which is
     * what StretchDIBits wants with a positive height. */
    dib = spdf_win_clipboard_alloc_dib(&bitmap, 0, NULL);
    spdf_free_bitmap(&bitmap);
    if (!dib) {
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "The page could not be prepared for the printer.");
        return 0;
    }
    base = (unsigned char*)GlobalLock(dib);
    if (!base) {
        GlobalFree(dib);
        return 0;
    }
    header = (BITMAPINFOHEADER*)base;

    /* Paper points -> printer device pixels. The DC's origin is the printable
     * area's top-left (HORZRES/VERTRES describe that area), so no physical
     * offset enters; see spdf_win_print_paper_from_caps(). */
    dest_x = (int)(dst_pt.x * paper->dpi_x / 72.0 + 0.5);
    dest_y = (int)(dst_pt.y * paper->dpi_y / 72.0 + 0.5);
    dest_w = (int)(dst_pt.w * paper->dpi_x / 72.0 + 0.5);
    dest_h = (int)(dst_pt.h * paper->dpi_y / 72.0 + 0.5);
    if (dest_w < 1) dest_w = 1;
    if (dest_h < 1) dest_h = 1;

    SetStretchBltMode(dc, HALFTONE);
    SetBrushOrgEx(dc, 0, 0, NULL);
    drawn = StretchDIBits(dc, dest_x, dest_y, dest_w, dest_h, 0, 0, header->biWidth, header->biHeight,
                          base + sizeof(BITMAPINFOHEADER), (const BITMAPINFO*)header, DIB_RGB_COLORS, SRCCOPY);
    GlobalUnlock(dib);
    GlobalFree(dib);
    if (drawn == GDI_ERROR) {
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "The printer driver rejected the page.");
        return 0;
    }
    return 1;
}

/* --- the job -------------------------------------------------------------- */

spdf_win_print_status spdf_win_print_run_job(HDC dc, spdf_document* doc, const wchar_t* job_name,
                                             const wchar_t* out_file, const int* pages, int page_count, int copies,
                                             spdf_win_print_scaling_mode mode, double custom_scale, char* err,
                                             size_t err_len) {
    spdf_win_print_paper paper;
    DOCINFOW info;
    int high_quality;
    int copy, i;

    if (err && err_len) err[0] = '\0';
    if (!dc || !doc || !pages || page_count <= 0) return SPDF_WIN_PRINT_NO_DOCUMENT;
    if (copies < 1) copies = 1;
    high_quality = spdf_win_print_high_quality_allowed(doc);

    if (!spdf_win_print_paper_from_caps(GetDeviceCaps(dc, LOGPIXELSX), GetDeviceCaps(dc, LOGPIXELSY),
                                        GetDeviceCaps(dc, HORZRES), GetDeviceCaps(dc, VERTRES), &paper)) {
        if (err && err_len)
            _snprintf_s(err, err_len, _TRUNCATE, "The printer did not report a usable page size.");
        return SPDF_WIN_PRINT_FAILED;
    }

    memset(&info, 0, sizeof(info));
    info.cbSize = sizeof(info);
    info.lpszDocName = job_name && *job_name ? job_name : L"Shenzhen PDF";
    /* NULL means "the port the DC names", which is the whole point of the
     * parameter: a caller that has a file to write says so and the driver
     * never asks. */
    info.lpszOutput = out_file && *out_file ? out_file : NULL;
    if (StartDocW(dc, &info) <= 0) {
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "The print job could not be started.");
        return SPDF_WIN_PRINT_FAILED;
    }

    /* PD_COLLATE is the driver's business when it handles copies itself; when
     * it does not, nCopies comes back > 1 and the job repeats the range. */
    for (copy = 0; copy < copies; ++copy) {
        for (i = 0; i < page_count; ++i) {
            if (StartPage(dc) <= 0) {
                AbortDoc(dc);
                if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "The printer stopped accepting pages.");
                return SPDF_WIN_PRINT_FAILED;
            }
            if (!spdf_win_print_page_to_dc(dc, doc, pages[i], &paper, mode, custom_scale, high_quality, err,
                                           err_len)) {
                EndPage(dc);
                AbortDoc(dc);
                return SPDF_WIN_PRINT_FAILED;
            }
            if (EndPage(dc) <= 0) {
                AbortDoc(dc);
                if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "The printer rejected a finished page.");
                return SPDF_WIN_PRINT_FAILED;
            }
        }
    }
    EndDoc(dc);
    return SPDF_WIN_PRINT_OK;
}

