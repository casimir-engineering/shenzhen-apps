/* spdf_win_print_preview_internal.h — the preview's private state, shared by
 * its two translation units. Contract and reasoning: spdf_win_print_preview.h.
 *
 * THREE FILES, AND WHY. spdf_win_print_preview.cpp is the WINDOW — the class,
 * the painting, the page stepper. spdf_win_print_preview_measure.cpp is
 * re-reading the dialog's controls and the asynchronous page bitmap with its
 * cache. spdf_win_print_preview_sheet.cpp is the printer, asked on a worker
 * thread because opening a DC on a network queue was measured at 48 seconds on
 * this host. The split is the same one spdf_win_print_dialog.cpp and
 * spdf_win_print_dialog_run.cpp already make, for the same reason: each of
 * these needs something different (a window, a render pool, a driver) and
 * mixing them makes all three harder to read.
 */
#ifndef SPDF_WIN_PRINT_PREVIEW_INTERNAL_H
#define SPDF_WIN_PRINT_PREVIEW_INTERNAL_H

#include "spdf_win_print_preview.h"

#include "spdf_win_render.h" /* the background render service */

/* HOW MANY PREVIEW BITMAPS ARE KEPT. Each is at most the preview pane across —
 * a few hundred pixels, well under a megabyte — so eight of them cost less than
 * one screen page of the reading canvas, and eight is enough that stepping back
 * and forth through a short range never re-renders. Keyed on (page, quantized
 * zoom) exactly as spdf_win_render_key is, so a resize that changes the zoom
 * invalidates by missing rather than by having to be noticed. */
#define SPDF_WIN_PREVIEW_TILES 8

/* The stepper's ids. Children of the PREVIEW window, not of the dialog, so its
 * WM_COMMAND arrives here and the dialog needs to know nothing about them. */
#define SPDF_WIN_PREVIEW_ID_PREV 1301
#define SPDF_WIN_PREVIEW_ID_NEXT 1302
#define SPDF_WIN_PREVIEW_ID_COUNT 1303

/* The printer, asked off the UI thread; see the section at the end of this
 * header and spdf_win_print_preview_sheet.cpp. Declared up here because the
 * preview holds one. */
typedef struct spdf_win_preview_measure spdf_win_preview_measure;

/* One finished preview bitmap, already in the form GDI wants: 32-bit BGRX,
 * top-down, stride exactly width * 4. The conversion out of the core's RGBA
 * happens once when the tile is stored, never on a paint. */
typedef struct spdf_win_preview_tile {
    int page;
    long long zoom_q;
    int width;
    int height;
    unsigned char* bgra; /* NULL when the slot is empty */
} spdf_win_preview_tile;

struct spdf_win_print_preview {
    HWND hwnd;
    HWND prev_button;
    HWND next_button;
    HWND count_label;
    HFONT font;
    /* The panel behind everything, and what WM_CTLCOLORSTATIC hands back so the
     * stepper's label does not sit in a grey system-coloured box on a dark
     * panel -- which is exactly what GetSysColorBrush(COLOR_BTNFACE) gave. */
    HBRUSH back;
    int dark;
    int dpi;

    /* The caller's document handle, touched ONLY on the thread that created the
     * preview and only through spdf_page_size(). The pixels come from the
     * service below, which opens its own handle per worker. */
    spdf_document* doc;
    int doc_page_count;
    int current_page; /* 0-based, or negative when the caller did not say */
    /* What the render workers open for themselves — never this thread's
     * handle, because the core has no locking inside a document. Empty when the
     * caller gave no path, which is a supported state: the sheet and the
     * placement are still true, there is simply never a bitmap. */
    char doc_path_utf8[MAX_PATH * 4];
    spdf_win_render_service* service;

    /* What the reader has chosen, as last read out of the dialog. The printer
     * list is the DIALOG's and is borrowed, not copied. */
    const spdf_win_print_printers* printers;
    wchar_t printer[SPDF_WIN_PRINT_NAME_MAX];
    DEVMODEW* devmode; /* our own copy of the dialog's, or NULL */
    size_t devmode_bytes;
    spdf_win_print_choice choice;
    int* pages;     /* 0-based, the range expanded; malloc'd */
    int page_count; /* entries in `pages` */
    int at;         /* index into `pages` */

    /* What was measured, and what follows from it. The mailbox belongs to
     * spdf_win_print_preview_sheet.cpp and outlives this struct. */
    spdf_win_preview_measure* measure;
    spdf_win_preview_sheet sheet;
    int have_sheet;
    int measuring; /* a printer is being asked right now */
    double page_w_pt;
    double page_h_pt;
    int have_page_size;
    spdf_win_preview_layout layout;

    /* The one render that may be in flight, and the bitmaps that have landed. */
    unsigned long long token;
    int token_page;
    long long token_zoom_q;
    spdf_win_preview_tile tiles[SPDF_WIN_PREVIEW_TILES];
    int next_tile;
};

/* --- spdf_win_print_preview_sheet.cpp -------------------------------------
 *
 * THE PRINTER, ASKED OFF THE UI THREAD. Opening a DC on a network queue was
 * measured at 48 s on this host, and the first version of this preview did it
 * in the printer combo's notification handler, freezing the whole dialog for
 * that long. So the sheet is a MAILBOX: the UI thread leaves a request and is
 * told later. Everything about the lifetime, the reference count and why the
 * worker is never joined or killed is in that file's header.
 *
 * Posted to the preview window when a measurement has landed. */
#define SPDF_WIN_PREVIEW_WM_SHEET (WM_APP + 72)

spdf_win_preview_measure* spdf_win_preview_measure_new(HWND hwnd);
/* Stop a late PostMessage from landing, then drop this side's reference. Both
 * are needed, in that order, and only the last holder frees. */
void spdf_win_preview_measure_detach(spdf_win_preview_measure* ms);
void spdf_win_preview_measure_release(spdf_win_preview_measure* ms);
/* Ask for `printer` with `devmode`, replacing any request not yet started.
 * Returns at once; the answer arrives as SPDF_WIN_PREVIEW_WM_SHEET. */
void spdf_win_preview_measure_ask(spdf_win_preview_measure* ms, const wchar_t* printer, const DEVMODEW* devmode);
/* The newest answer. Returns 1 when it is usable; `*pending` says whether a
 * printer is still being asked, which is a different sentence to show than
 * "this printer reported nothing". */
int spdf_win_preview_measure_take(spdf_win_preview_measure* ms, spdf_win_preview_sheet* out, int* pending);

/* --- spdf_win_print_preview_measure.cpp ----------------------------------- */

/* Recompute pv->layout for the pane `w` x `h`, asking the service for the
 * bitmap it needs if one is not already cached or in flight. Never blocks. */
void spdf_win_preview_relayout(spdf_win_print_preview* pv, int w, int h);

/* The cached bitmap for the page now shown at the current zoom, or NULL. */
const spdf_win_preview_tile* spdf_win_preview_tile_now(const spdf_win_print_preview* pv);

/* Deliver whatever the workers have finished. UI thread. */
void spdf_win_preview_drain(spdf_win_print_preview* pv);

/* Drop every cached bitmap; used when the sheet or the document changes. */
void spdf_win_preview_tiles_clear(spdf_win_print_preview* pv);

/* --- spdf_win_print_preview.cpp ------------------------------------------- */

/* Re-lay out against the window's own client rect, show or hide the stepper,
 * and repaint. What every change ends in. */
void spdf_win_print_preview_invalidate(spdf_win_print_preview* pv);

#endif /* SPDF_WIN_PRINT_PREVIEW_INTERNAL_H */
