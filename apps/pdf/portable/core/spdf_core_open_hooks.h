#pragma once

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

void spdf_close(spdf_document* doc) {
    if (!doc) return;
    if (close_hook) close_hook(doc);
    spdf_drop_page_list_cache(doc, -1);
    if (doc->dark_doc) fz_drop_document(doc->ctx, doc->dark_doc);
    if (doc->doc) fz_drop_document(doc->ctx, doc->doc);
    if (doc->ctx) fz_drop_context(doc->ctx);
    free(doc->title);
    free(doc->page_sizes);
    free(doc);
}
