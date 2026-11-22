/* spdf_core_document.h -- the core's private document record.
 *
 * CORE-INTERNAL. Included by shenzhen_pdf_core.c, which owns every field, and
 * by the sibling core units that must CONSTRUCT a document rather than merely
 * read through one (spdf_markdown_open.c builds an spdf_document around an
 * HTML rendition of a Markdown file). Frontends never include this header:
 * they see only the opaque spdf_document of shenzhen_pdf_core.h, and the
 * accessor spdf_selection_document_access() remains the way to borrow the
 * MuPDF handles for read-only work.
 *
 * Moved verbatim out of shenzhen_pdf_core.c, whose line cap is frozen
 * (tools/file-size-limits.tsv); the one addition is `dark_doc`.
 */
#ifndef SPDF_CORE_DOCUMENT_H
#define SPDF_CORE_DOCUMENT_H

#include "shenzhen_pdf_core.h"
#include "spdf_recolor.h"

#include "mupdf/fitz.h"
#include "mupdf/pdf.h"

#include <stdint.h>

typedef struct spdf_page_size_cache {
    float width;
    float height;
    int valid;
} spdf_page_size_cache;

#define SPDF_PAGE_LIST_SLOTS 4

typedef struct spdf_page_list_entry {
    fz_display_list* list; /* NULL = empty slot */
    int page_index;
    int dark; /* built from dark_doc (see below); a light and a dark list never alias */
    double build_ms;
    uint64_t last_used; /* monotonic counter, LRU */
} spdf_page_list_entry;

/* THREADING CONTRACT: an spdf_document (and everything hanging off it, including
 * the page-list cache and last_render_stats below) may only be used by one thread
 * at a time. The app honors this by giving each worker thread its own document
 * (see workerDocumentForPath on the Mac side); the main-thread document is only
 * touched from the main thread. No locking is done here. */
struct spdf_document {
    fz_context* ctx;
    fz_document* doc;
    /* An ALTERNATE RENDITION of the same document for SPDF_RENDER_DARK_THEME,
     * or NULL (every format MuPDF opens directly). When set, a render carrying
     * the dark flag draws this document instead of `doc`, on paper of
     * spdf_recolor_default_dark_theme()'s colour, and skips the lightness
     * remap -- the rendition already IS the dark palette. Everything else
     * (page count and sizes, text, search, links, outline, print, export,
     * Copy Page) keeps reading `doc`, so the light-theme rule of the export
     * paths holds by construction: they pass no dark flag and never see this.
     * The owner guarantees identical pagination in both renditions. Only the
     * Markdown opener sets it (spdf_markdown_open.c). */
    fz_document* dark_doc;
    char* title;
    int page_count;
    spdf_page_size_cache* page_sizes;
    spdf_page_list_entry page_lists[SPDF_PAGE_LIST_SLOTS];
    uint64_t page_list_use_counter;
    spdf_render_stats last_render_stats;
    int password_protected;
    spdf_authentication authentication;
    /* Image rectangles per page, for SPDF_RENDER_PRESERVE_IMAGES. Pure cache:
     * the dark reading theme itself is a per-render flag, not document state. */
    spdf_recolor_page_cache recolor_pages;
    int picture_document; /* -1 unknown; 0 document; 1 picture (honors preserve-images) */
    /* Opened while still downloading (spdf_progressive.h): every render runs with a cookie, and one that drew
     * without some of its bytes fails with SPDF_NOT_DOWNLOADED instead of showing a wrong page. */
    int progressive;
    int rendering; /* inside a render: its page-size lookup asks for the bytes it waits on (see spdf_page_size) */
};

/* Body of the public cancellation token (shenzhen_pdf_core.h): just an fz_cookie, here so sibling units that run a
 * page themselves (spdf_fill_snap.c) can honour it. cancel() writes cookie.abort from any thread while a run on
 * another thread polls it; abort is a plain int flag that MuPDF only ever reads during a run, so the unsynchronized
 * write is benign (worst case the run aborts at the next poll point). */
struct spdf_render_token {
    fz_cookie cookie;
};

/* Documents read while they download. spdf_progressive.c installs these on its first registration; a frontend that
 * never downloads a document never links it, and every open then goes straight to fz_open_document. `open` returns
 * NULL for a path that is not downloading; `set_quiet` stops this thread's page-size lookups asking for bytes. */
typedef struct spdf_core_progressive_hooks {
    fz_document* (*open)(fz_context* ctx, const char* path);
    void (*set_quiet)(int on);
} spdf_core_progressive_hooks;
void spdf_core_set_progressive_hooks(const spdf_core_progressive_hooks* hooks);
/* Formats MuPDF does not read, turned into a document it does (spdf_sensor_raw.c adds one for camera sensor frames,
 * spdf_camera_raw.c one for RAW photos). Returns NULL for a path it does not handle; throws when it handles the path
 * but cannot show it. Hooks claim disjoint extensions, so their order does not matter. */
typedef fz_document* (*spdf_core_open_hook)(fz_context* ctx, const char* path);
void spdf_core_add_open_hook(spdf_core_open_hook hook);
/* Called with every document opened from a path (spdf_picture_text.c installs one that lays a picture's recognised
 * text over it). Returns `doc` itself or a document that took it over; never throws. */
typedef fz_document* (*spdf_core_wrap_hook)(fz_context* ctx, const char* path, fz_document* doc);
void spdf_core_set_picture_text_hook(spdf_core_wrap_hook hook);
#define SPDF_NOT_DOWNLOADED "This page has not downloaded yet."

/* After an incremental save. MuPDF remembers the size the file had when it was opened and cuts the file back to it
 * before the next incremental save, so a second save dropped the first one while its cross-reference still pointed
 * there (a damaged file, the first change lost). When the save grew the very file the document reads, it ends there. */
static inline void spdf_follow_incremental_save(fz_context* ctx, pdf_document* pdf) {
    if (!pdf || !pdf->file) return;
    fz_seek(ctx, pdf->file, 0, SEEK_END);
    if (fz_tell(ctx, pdf->file) > pdf->file_size) pdf->file_size = fz_tell(ctx, pdf->file);
}

#endif /* SPDF_CORE_DOCUMENT_H */
