/* spdf_win_render_core.h — the render pool's DEFAULT backend: the shipping core.
 *
 * Extracted from spdf_win_render.c under the repo's 500-line cap
 * (tools/file-size-limits.md). The seam is spdf_win_render.h's injectable
 * backend, so this is the one implementation of it that touches MuPDF; the
 * tests supply their own and never compile this in a way that matters. Keeping
 * it here means spdf_win_render.c is scheduling and nothing else, and that
 * "which document does a worker render against?" is answered by one small file.
 *
 * ONE spdf_document PER WORKER THREAD, per the core's one-document-per-thread
 * contract (shenzhen_pdf_core.c:40-43). Kept across renders so the core's
 * per-page display-list cache stays warm -- that cache is what makes the second
 * render of a page nearly free, which is half of the "repeat renders are cheap"
 * promise -- and released when the worker exits.
 *
 * Header-only and included by exactly one translation unit
 * (spdf_win_render.c), the same arrangement spdf_win_tabs_app.h uses and for
 * the same reason: a new .cpp would have to be added to a source list that
 * lives in another track's file.
 */
#ifndef SPDF_WIN_RENDER_CORE_H
#define SPDF_WIN_RENDER_CORE_H

#include "spdf_win_open.h" /* the process opener: spdf_open, or Markdown-aware once main() says so */
#include "spdf_win_render.h"
#include "spdf_win_render_thread.h" /* SPDF_TLS */

static SPDF_TLS spdf_document* g_slot_doc;
static SPDF_TLS char* g_slot_path;

static void core_thread_exit(void* ctx) {
    (void)ctx;
    if (g_slot_doc) spdf_close(g_slot_doc);
    free(g_slot_path);
    g_slot_doc = NULL;
    g_slot_path = NULL;
}

static char* spdf_win_render_dup_str(const char* s);

static spdf_document* core_doc(const char* path, char* err, size_t err_len) {
    if (g_slot_doc && g_slot_path && path && strcmp(g_slot_path, path) == 0) return g_slot_doc;
    core_thread_exit(NULL);
    if (!path) return NULL;
    g_slot_doc = spdf_win_open_document(path, err, err_len);
    if (g_slot_doc) g_slot_path = spdf_win_render_dup_str(path);
    return g_slot_doc;
}

static int core_page_size(void* ctx, const char* path, int page, float* w, float* h, char* err, size_t err_len) {
    spdf_document* doc = core_doc(path, err, err_len);
    (void)ctx;
    return doc ? spdf_page_size(doc, page, w, h, err, err_len) : 0;
}

/* DARK_THEME / PRESERVE_IMAGES arrive in `flags` and are part of the request's
 * identity; nothing here decides the theme. USE_PAGE_LIST is ours. */
static int core_render(void* ctx, const char* path, int page, float zoom, unsigned flags,
                       const spdf_win_render_abort* abort, spdf_bitmap* out, char* err, size_t err_len) {
    spdf_document* doc = core_doc(path, err, err_len);
    (void)ctx;
    return doc ? spdf_render_page_rgba_opts(doc, page, zoom, flags | SPDF_RENDER_USE_PAGE_LIST,
                                            abort ? abort->token : NULL, out, err, err_len)
               : 0;
}

const spdf_win_render_backend* spdf_win_render_core_backend(void) {
    static const spdf_win_render_backend backend = {NULL, core_page_size, core_render, core_thread_exit};
    return &backend;
}

#endif /* SPDF_WIN_RENDER_CORE_H */
