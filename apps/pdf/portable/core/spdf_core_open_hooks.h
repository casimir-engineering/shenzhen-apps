#pragma once

#include "spdf_deferred_save.h"

/* The open hooks of spdf_core_document.h (documents read while they download, camera frames, RAW photos, a
 * picture's recognised text) and the close hook with spdf_close itself, moved out of shenzhen_pdf_core.c (whose line
 * cap is frozen) and included there. */

static spdf_core_progressive_hooks progressive_hooks; /* zero unless a frontend downloads documents */
void spdf_core_set_progressive_hooks(const spdf_core_progressive_hooks* hooks) { progressive_hooks = *hooks; }

/* Empty unless the frontend installed spdf_sensor_raw.c or spdf_camera_raw.c. Added before any document opens. */
#define SPDF_CORE_OPEN_HOOK_SLOTS 4
static spdf_core_open_hook open_hooks[SPDF_CORE_OPEN_HOOK_SLOTS];

void spdf_core_add_open_hook(spdf_core_open_hook hook) {
    int i;
    for (i = 0; i < SPDF_CORE_OPEN_HOOK_SLOTS; ++i) {
        if (open_hooks[i] == hook) return;
        if (!open_hooks[i]) {
            open_hooks[i] = hook;
            return;
        }
    }
}

static spdf_core_wrap_hook picture_text_hook; /* NULL unless the frontend installed spdf_picture_text.c */
void spdf_core_set_picture_text_hook(spdf_core_wrap_hook hook) { picture_text_hook = hook; }

/* A path that is not downloading: the first hook claiming it (camera frames, RAW photos), else MuPDF; then a picture
 * gains the text recognised in it. */
static fz_document* open_with_hooks(fz_context* ctx, const char* path) {
    fz_document* doc = NULL;
    int i;
    for (i = 0; i < SPDF_CORE_OPEN_HOOK_SLOTS && open_hooks[i] && !doc; ++i) doc = open_hooks[i](ctx, path);
    if (!doc) doc = fz_open_document(ctx, path);
    return picture_text_hook ? picture_text_hook(ctx, path, doc) : doc;
}

/* NULL unless something borrows documents past their own lifetime (Annotate's PDF page canvases, which install it
 * when the first one opens): told before the document's context goes, so it can let go of what it made with it. */
static spdf_core_close_hook close_hook;
void spdf_core_set_close_hook(spdf_core_close_hook hook) { close_hook = hook; }

/* spdf_deferred_save.h */
int spdf_defer_save(spdf_document* doc, const char* path) {
    char* copy;
    if (!doc || !path || !*path) return 0;
    if (doc->deferred_save_path && !strcmp(doc->deferred_save_path, path)) return 1;
    copy = (char*)malloc(strlen(path) + 1);
    if (!copy) return 0;
    strcpy(copy, path);
    free(doc->deferred_save_path);
    doc->deferred_save_path = copy;
    return 1;
}

const char* spdf_deferred_save_path(const spdf_document* doc) { return doc ? doc->deferred_save_path : NULL; }

int spdf_save_deferred(spdf_document* doc, char* err, size_t err_len) {
    char* path;
    int ok;
    if (err && err_len) err[0] = 0;
    if (!doc || !doc->deferred_save_path) return 1;
    path = doc->deferred_save_path;
    doc->deferred_save_path = NULL;
    ok = spdf_save_document(doc, path, err, err_len);
    free(path);
    return ok;
}

int spdf_prepare_save_step(spdf_document* doc, int max_objects) {
    pdf_document* pdf;
    int num, len, read = 0;
    if (!doc || !doc->doc) return 1;
    pdf = pdf_specifics(doc->ctx, doc->doc);
    if (!pdf || pdf->checked) return 1;
    len = pdf_xref_len(doc->ctx, pdf);
    for (num = doc->save_prepared_next > 0 ? doc->save_prepared_next : 1; num < len && read < max_objects; ++num) {
        if (!pdf_object_exists(doc->ctx, pdf, num)) continue;
        fz_try(doc->ctx) { (void)pdf_cache_object(doc->ctx, pdf, num); }
        fz_catch(doc->ctx) { fz_report_error(doc->ctx); }
        ++read;
    }
    doc->save_prepared_next = num;
    if (num < len) return 0;
    pdf_check_document(doc->ctx, pdf); /* every object is read now: this only marks the document checked */
    return 1;
}

void spdf_close(spdf_document* doc) {
    if (!doc) return;
    if (doc->deferred_save_path) {
        char err[512];
        if (!spdf_save_deferred(doc, err, sizeof(err)))
            fprintf(stderr, "ShenzhenPDF: a change could not be saved: %s\n", err);
    }
    if (close_hook) close_hook(doc);
    spdf_drop_page_list_cache(doc, -1);
    if (doc->dark_doc) fz_drop_document(doc->ctx, doc->dark_doc);
    if (doc->doc) fz_drop_document(doc->ctx, doc->doc);
    if (doc->ctx) fz_drop_context(doc->ctx);
    free(doc->title);
    free(doc->page_sizes);
    free(doc);
}
