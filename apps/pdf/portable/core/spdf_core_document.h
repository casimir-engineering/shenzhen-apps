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
};

#endif /* SPDF_CORE_DOCUMENT_H */
