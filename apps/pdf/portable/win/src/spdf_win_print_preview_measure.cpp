/* spdf_win_print_preview_measure.cpp — the preview's dealings with the RENDER
 * POOL, and re-reading the dialog's controls. None of it draws anything (the
 * window is spdf_win_print_preview.cpp) and none of it asks a driver anything
 * (that is spdf_win_print_preview_sheet.cpp, on a thread of its own).
 *
 * WHEN THE PRINTER IS RE-ASKED, AND WHEN IT IS NOT. Only when the PRINTER or
 * the DEVMODE has actually changed — never when a scaling radio moves, because
 * the scale changes where the page lands on the sheet, not what the sheet is.
 * The check is a byte comparison of the DEVMODE, not a flag, because the
 * driver's own property sheet can change any field in it including ones this app
 * has never heard of. It matters that this is tight: the measurement it starts
 * took 48 seconds on this machine's network printer.
 */

#include "spdf_win_print_preview_internal.h"

#include "spdf_win_export.h" /* spdf_win_export_render_flags — the light-theme rule */

#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "user32.lib")

/* --- the bitmap cache ----------------------------------------------------- */

void spdf_win_preview_tiles_clear(spdf_win_print_preview* pv) {
    int i;
    if (!pv) return;
    for (i = 0; i < SPDF_WIN_PREVIEW_TILES; ++i) {
        free(pv->tiles[i].bgra);
        pv->tiles[i].bgra = NULL;
        pv->tiles[i].page = -1;
    }
    pv->next_tile = 0;
}

static long long preview_zoom_q(double zoom) {
    spdf_win_render_spec spec;
    memset(&spec, 0, sizeof(spec));
    spec.zoom = (float)zoom;
    /* The SERVICE's own quantization, so a tile can never be looked up under a
     * key the service would have called something else. */
    return spdf_win_render_key_for(&spec).zoom_q;
}

const spdf_win_preview_tile* spdf_win_preview_tile_now(const spdf_win_print_preview* pv) {
    long long want;
    int page;
    int i;

    if (!pv || !pv->layout.valid || pv->at < 0 || pv->at >= pv->page_count) return NULL;
    page = pv->pages[pv->at];
    want = preview_zoom_q(spdf_win_preview_render_zoom(pv->layout.page.w, pv->page_w_pt));
    for (i = 0; i < SPDF_WIN_PREVIEW_TILES; ++i)
        if (pv->tiles[i].bgra && pv->tiles[i].page == page && pv->tiles[i].zoom_q == want) return &pv->tiles[i];
    return NULL;
}

/* Round-robin rather than a true LRU: eight slots and one visible page means the
 * oldest slot is very nearly always the least useful, and spdf_win_lru is worth
 * linking for a canvas that holds hundreds of megabytes, not for this.
 *
 * THE CONVERSION HAPPENS HERE, ONCE, not on every paint. The core hands back
 * RGBA with a stride that may be wider than width * 4; a 32-bit BI_RGB DIB is
 * BGRX with a stride that must be exactly width * 4. So the rows are compacted
 * and the two outer channels swapped as the tile is stored, and painting is then
 * one StretchDIBits straight out of the buffer. Returns 0 when the tile could
 * not be taken, in which case the service frees the pixels as usual. */
static int preview_tile_store(spdf_win_print_preview* pv, spdf_win_render_result* result) {
    spdf_win_preview_tile* slot = &pv->tiles[pv->next_tile];
    unsigned char* packed;
    int row;
    int x;

    if (result->width <= 0 || result->height <= 0) return 0;
    packed = (unsigned char*)malloc((size_t)result->width * (size_t)result->height * 4u);
    if (!packed) return 0;
    for (row = 0; row < result->height; ++row) {
        const unsigned char* src = result->rgba + (size_t)row * (size_t)result->stride;
        unsigned char* dst = packed + (size_t)row * (size_t)result->width * 4u;
        for (x = 0; x < result->width; ++x) {
            dst[x * 4 + 0] = src[x * 4 + 2];
            dst[x * 4 + 1] = src[x * 4 + 1];
            dst[x * 4 + 2] = src[x * 4 + 0];
            dst[x * 4 + 3] = 0xFF;
        }
    }
    free(slot->bgra);
    slot->page = result->spec.page;
    slot->zoom_q = spdf_win_render_key_for(&result->spec).zoom_q;
    slot->width = result->width;
    slot->height = result->height;
    slot->bgra = packed;
    pv->next_tile = (pv->next_tile + 1) % SPDF_WIN_PREVIEW_TILES;
    return 1;
}

/* --- the render ----------------------------------------------------------- */

static void preview_adopt(spdf_win_render_result* result, void* user_data) {
    spdf_win_print_preview* pv = (spdf_win_print_preview*)user_data;

    if (!pv) return;
    /* Exactly one callback arrives per request whatever its status, so this is
     * the one place the in-flight slot can be kept honest. */
    if (result->token == pv->token) {
        pv->token = 0;
        pv->token_page = -1;
    }
    if (result->status != SPDF_WIN_RENDER_OK || !result->rgba || result->width <= 0) return;
    if (!preview_tile_store(pv, result)) return;
    /* The bitmap is only worth a repaint if it is the one now on screen; a tile
     * that landed after the reader stepped on is cache and nothing more. */
    if (pv->hwnd) InvalidateRect(pv->hwnd, NULL, FALSE);
}

/* Fired on a WORKER thread. Reads one field and posts; touches nothing else. */
static void preview_notify(void* ctx) {
    spdf_win_print_preview* pv = (spdf_win_print_preview*)ctx;
    if (pv && pv->hwnd) PostMessageW(pv->hwnd, SPDF_WIN_PREVIEW_WM_READY, 0, 0);
}

void spdf_win_preview_drain(spdf_win_print_preview* pv) {
    if (pv && pv->service) spdf_win_render_drain(pv->service, -1);
}

/* The service, made lazily: a reader who opens the print dialog and cancels it
 * should not have paid for a worker thread and a second MuPDF document. */
static spdf_win_render_service* preview_service(spdf_win_print_preview* pv) {
    if (!pv->service && pv->doc_path_utf8[0])
        /* ONE worker, and a byte cap two orders of magnitude below the canvas's.
         * A preview needs the one page it is looking at, at a couple of hundred
         * pixels across, and the pages the reader is READING must out-thread it
         * — the tiering argument in spdf_win_render.h's policy note. */
        pv->service = spdf_win_render_service_new_ex(pv->doc_path_utf8, NULL, (size_t)8 * 1024 * 1024, preview_notify,
                                                     pv, 1);
    return pv->service;
}

static void preview_request(spdf_win_print_preview* pv) {
    spdf_win_render_spec spec;
    spdf_win_render_service* svc;
    int page;
    long long zoom_q;

    if (!pv->layout.valid || pv->at < 0 || pv->at >= pv->page_count) return;
    if (spdf_win_preview_tile_now(pv)) return;
    page = pv->pages[pv->at];

    memset(&spec, 0, sizeof(spec));
    spec.page = page;
    spec.zoom = (float)spdf_win_preview_render_zoom(pv->layout.page.w, pv->page_w_pt);
    /* THE LIGHT-THEME RULE, and nothing else. A preview of a print carries the
     * document's own colours even when the app is dark; see spdf_win_export.h
     * and portable/win/tests/light_theme_test.c. */
    spec.flags = spdf_win_export_render_flags();
    zoom_q = spdf_win_render_key_for(&spec).zoom_q;
    if (pv->token && pv->token_page == page && pv->token_zoom_q == zoom_q) return; /* already on its way */

    svc = preview_service(pv);
    if (!svc) return;
    /* One render at a time. The reader can only look at one sheet, and a
     * superseded request that is cancelled rather than left running is what
     * keeps a page-by-page walk from queueing a dozen renders nobody wants. */
    if (pv->token) spdf_win_render_cancel(svc, pv->token);
    pv->token = spdf_win_render_request(svc, &spec, SPDF_WIN_RENDER_VISIBLE, preview_adopt, pv);
    pv->token_page = pv->token ? page : -1;
    pv->token_zoom_q = zoom_q;
}

/* --- the layout ----------------------------------------------------------- */

void spdf_win_preview_relayout(spdf_win_print_preview* pv, int w, int h) {
    float page_w = 0.0f;
    float page_h = 0.0f;

    if (!pv) return;
    pv->layout.valid = 0;
    pv->have_page_size = 0;
    if (!pv->have_sheet || pv->at < 0 || pv->at >= pv->page_count) return;
    /* spdf_page_size() on the CALLING thread against the caller's own handle:
     * the core allows one spdf_document per thread and this is that thread. It
     * is a page-tree lookup, not a render, so it cannot be the thing that makes
     * the dialog feel slow. */
    if (!pv->doc || !spdf_page_size(pv->doc, pv->pages[pv->at], &page_w, &page_h, NULL, 0)) return;
    if (page_w <= 0.0f || page_h <= 0.0f) return;
    pv->page_w_pt = (double)page_w;
    pv->page_h_pt = (double)page_h;
    pv->have_page_size = 1;
    spdf_win_preview_layout_for(&pv->sheet, pv->page_w_pt, pv->page_h_pt, pv->choice.mode, pv->choice.custom_scale,
                                (double)w, (double)h, &pv->layout);
    preview_request(pv);
}

/* --- re-reading the dialog ------------------------------------------------ */

/* 1 when `devmode` differs from the copy we are holding. Byte for byte over
 * dmSize + dmDriverExtra: the driver's own property sheet can change fields
 * this app has never heard of, and any of them can move the paper. */
static int preview_devmode_changed(const spdf_win_print_preview* pv, const DEVMODEW* devmode) {
    size_t bytes;
    if (!devmode) return pv->devmode != NULL;
    if (!pv->devmode) return 1;
    bytes = (size_t)devmode->dmSize + (size_t)devmode->dmDriverExtra;
    return bytes != pv->devmode_bytes || memcmp(pv->devmode, devmode, bytes) != 0;
}

static void preview_devmode_adopt(spdf_win_print_preview* pv, const DEVMODEW* devmode) {
    free(pv->devmode);
    pv->devmode = NULL;
    pv->devmode_bytes = 0;
    if (!devmode) return;
    pv->devmode_bytes = (size_t)devmode->dmSize + (size_t)devmode->dmDriverExtra;
    pv->devmode = (DEVMODEW*)malloc(pv->devmode_bytes);
    if (pv->devmode) memcpy(pv->devmode, devmode, pv->devmode_bytes);
    else pv->devmode_bytes = 0;
}

void spdf_win_print_preview_sync(spdf_win_print_preview* pv, HWND dialog, const DEVMODEW* devmode) {
    spdf_win_print_request req;
    spdf_win_print_page_range range;
    int shown = pv && pv->at >= 0 && pv->at < pv->page_count ? pv->pages[pv->at] : -1;
    int ranges;
    int count;
    int i;
    int resheet;

    if (!pv || !dialog) return;
    memset(&req, 0, sizeof(req));
    spdf_win_print_dialog_read_controls(dialog, pv->printers, pv->doc_page_count, &req);

    resheet = wcscmp(pv->printer, req.printer) != 0 || preview_devmode_changed(pv, devmode);
    if (resheet) {
        wcsncpy_s(pv->printer, SPDF_WIN_PRINT_NAME_MAX, req.printer, _TRUNCATE);
        preview_devmode_adopt(pv, devmode);
        /* The OLD sheet is dropped rather than kept while the new one is asked
         * for: a sheet drawn to the previous printer's paper would be the one
         * thing worse than no sheet. The window says "Measuring the printer" in
         * the gap; the answer arrives as SPDF_WIN_PREVIEW_WM_SHEET. */
        pv->have_sheet = 0;
        pv->measuring = 1;
        spdf_win_preview_sheet_clear(&pv->sheet);
        spdf_win_preview_measure_ask(pv->measure, pv->printer, pv->devmode);
    }
    pv->choice = req.choice;

    /* THE SAME EXPANSION THE JOB USES (spdf_win_print_math.h), so the preview
     * cannot offer a page the job would not print. */
    ranges = spdf_win_print_dialog_range(&req, pv->current_page, pv->doc_page_count, &range);
    count = spdf_win_print_expand_ranges(ranges ? &range : NULL, ranges, pv->doc_page_count, pv->pages,
                                         pv->doc_page_count);
    pv->page_count = count > 0 ? count : 0;
    /* Stay on the page the reader was looking at when the new range still
     * contains it: narrowing "all" to "2-8" should not jump them back to 2. */
    pv->at = pv->page_count > 0 ? 0 : -1;
    for (i = 0; i < pv->page_count; ++i)
        if (pv->pages[i] == shown) pv->at = i;

    spdf_win_print_preview_invalidate(pv);
}
