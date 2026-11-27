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

/* ---- The file a document reads, as it last left it (spdf_core_document.h: opened_path, opened_file) ---- */

static int spdf_file_seen_now(const char* path, spdf_file_seen* out) {
    memset(out, 0, sizeof(*out));
    if (!path || !spdf_compat_file_mtime(path, &out->mtime_sec, &out->mtime_nsec)) return 0;
#ifdef _WIN32
    {
        FILE* f = spdf_compat_fopen(path, "rb");
        if (!f) return 0;
        if (_fseeki64(f, 0, SEEK_END) == 0) out->size = (long long)_ftelli64(f);
        fclose(f);
    }
#else
    {
        struct stat st;
        if (stat(path, &st) != 0) return 0;
        out->size = (long long)st.st_size;
        out->device = (long long)st.st_dev;
        out->inode = (long long)st.st_ino;
    }
#endif
    out->known = 1;
    return 1;
}

static int spdf_same_file_seen(const spdf_file_seen* a, const spdf_file_seen* b) {
    return a->known && b->known && a->size == b->size && a->mtime_sec == b->mtime_sec &&
           a->mtime_nsec == b->mtime_nsec && a->device == b->device && a->inode == b->inode;
}

/* At open (spdf_open_with_password). A document still downloading changes until it is whole: nothing is noted. */
static void spdf_note_opened(spdf_document* doc, const char* path, int progressive) {
    doc->progressive = progressive;
    if (progressive || !path) return;
    doc->opened_path = spdf_compat_strdup(path);
    if (doc->opened_path) spdf_file_seen_now(path, &doc->opened_file);
}

/* After every spdf_save_document: a save into the file the document reads moves what it was last seen as. */
static int spdf_note_saved(spdf_document* doc, const char* path) {
    if (doc && doc->opened_path && path && !strcmp(doc->opened_path, path)) spdf_file_seen_now(path, &doc->opened_file);
    return 1;
}

/* ---- spdf_deferred_save.h ---- */

static spdf_core_save_failed_hook save_failed_hook;
void spdf_core_set_save_failed_hook(spdf_core_save_failed_hook hook) { save_failed_hook = hook; }

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

int spdf_deferred_save_file_changed(const spdf_document* doc) {
    spdf_file_seen now;
    if (!doc || !doc->deferred_save_path || !doc->opened_file.known) return 0;
    return !spdf_file_seen_now(doc->deferred_save_path, &now) || !spdf_same_file_seen(&now, &doc->opened_file);
}

int spdf_save_deferred(spdf_document* doc, char* err, size_t err_len) {
    if (err && err_len) err[0] = 0;
    if (!doc || !doc->deferred_save_path) return 1;
    /* An increment holds only what changed and where the rest is in the file the document read: appended to another
     * file (replaced, grown or cut by another app, or gone) it would make a damaged PDF. Still owed. */
    if (spdf_deferred_save_file_changed(doc)) {
        if (err && err_len) snprintf(err, err_len, "%s", SPDF_FILE_CHANGED_ELSEWHERE);
        return 0;
    }
    if (!spdf_save_document(doc, doc->deferred_save_path, err, err_len)) return 0; /* still owed: tried again later */
    spdf_file_seen_now(doc->deferred_save_path, &doc->opened_file);
    free(doc->deferred_save_path);
    doc->deferred_save_path = NULL;
    return 1;
}

int spdf_save_deferred_copy(spdf_document* doc, const char* path, char* err, size_t err_len) {
    pdf_document* pdf = NULL;
    pdf_write_options options = pdf_default_write_options;
    char* temp;
    size_t len;
    if (err && err_len) err[0] = 0;
    if (!doc || !doc->doc || !path || !*path) return 0;
    len = strlen(path);
    temp = (char*)malloc(len + 8);
    if (!temp) return 0;
    memcpy(temp, path, len);
    memcpy(temp + len, ".saving", 8);
    options.do_compress = options.do_compress_images = options.do_compress_fonts = 1;
    fz_try(doc->ctx) {
        pdf = pdf_specifics(doc->ctx, doc->doc);
        if (!pdf) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Only PDF documents can be saved.");
        pdf_save_document(doc->ctx, pdf, temp, &options); /* the whole document: every object, from memory or its file */
    }
    fz_catch(doc->ctx) {
        if (err && err_len) snprintf(err, err_len, "%s", fz_caught_message(doc->ctx));
        remove(temp);
        free(temp);
        return 0;
    }
    if (spdf_compat_replace_file(temp, path) != 0) {
        if (err && err_len) snprintf(err, err_len, "The copy could not be written.");
        remove(temp);
        free(temp);
        return 0;
    }
    free(temp);
    free(doc->deferred_save_path); /* kept in the copy: nothing is owed to the original any more */
    doc->deferred_save_path = NULL;
    return 1;
}

/* Past this many objects nothing is read ahead: a save that may not come would hold them all in memory first. */
#define SPDF_PREPARE_SAVE_MAX_OBJECTS 500000

int spdf_prepare_save_step(spdf_document* doc, int max_objects) {
    pdf_document* pdf;
    int num, len, read = 0, scanned = 0;
    if (!doc || !doc->doc) return 1;
    pdf = pdf_specifics(doc->ctx, doc->doc);
    if (!pdf || pdf->checked) return 1;
    len = pdf_xref_len(doc->ctx, pdf);
    if (len > SPDF_PREPARE_SAVE_MAX_OBJECTS) return 1;
    /* A step stops after max_objects read, or as many again times 8 entries looked at (free ones included). */
    for (num = doc->save_prepared_next > 0 ? doc->save_prepared_next : 1;
         num < len && read < max_objects && scanned < max_objects * 8; ++num, ++scanned) {
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
        if (!spdf_save_deferred(doc, err, sizeof(err))) {
            char* owed = doc->deferred_save_path;
            doc->deferred_save_path = NULL;
            if (save_failed_hook) save_failed_hook(doc, owed, err); /* the frontend keeps the changes and tells */
            else fprintf(stderr, "ShenzhenPDF: a change could not be saved: %s\n", err);
            free(owed);
        }
    }
    if (close_hook) close_hook(doc);
    spdf_drop_page_list_cache(doc, -1);
    if (doc->dark_doc) fz_drop_document(doc->ctx, doc->dark_doc);
    if (doc->doc) fz_drop_document(doc->ctx, doc->doc);
    if (doc->ctx) fz_drop_context(doc->ctx);
    free(doc->title);
    free(doc->opened_path);
    free(doc->page_sizes);
    free(doc);
}
