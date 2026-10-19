#include "spdf_search_regex.h"
#include "shenzhen_pdf_core.h"

#include "spdf_recolor.h"
#include "spdf_selection.h"
#include "spdf_win_compat.h"

#include "mupdf/fitz.h"
#include "mupdf/pdf.h"

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define SPDF_MUPDF_STORE_LIMIT ((size_t)256 * 1024 * 1024)
#define SPDF_MAX_RENDER_DIMENSION 32768
#define SPDF_MAX_RENDER_BYTES ((size_t)512 * 1024 * 1024)

/* struct spdf_document and its page caches live in spdf_core_document.h. */
#include "spdf_core_document.h"

/* Which rendition a render draws, and what colour its paper is cleared to.
 * doc->dark_doc is NULL for every format but Markdown (see the header). */
static fz_document* render_document(const spdf_document* doc, unsigned flags) {
    return (flags & SPDF_RENDER_DARK_THEME) && doc->dark_doc ? doc->dark_doc : doc->doc;
}

static int render_paper_value(const spdf_document* doc, unsigned flags) {
    /* The dark paper (#1E1E1E) is a neutral grey, so one channel clears all three. */
    return render_document(doc, flags) == doc->doc ? 0xFF : (int)(spdf_recolor_default_dark_theme().paper_rgb & 0xFF);
}

/* Core-private body of the public cancellation token: just an fz_cookie.
 * cancel() writes cookie.abort from any thread while a render on another
 * thread polls it; abort is a plain int flag that mupdf only ever reads
 * during a run, so the unsynchronized write is benign (worst case the
 * render aborts at the next poll point). */
struct spdf_render_token {
    fz_cookie cookie;
};

spdf_render_token* spdf_render_token_new(void) {
    return (spdf_render_token*)calloc(1, sizeof(spdf_render_token));
}

void spdf_render_token_cancel(spdf_render_token* token) {
    if (token) token->cookie.abort = 1;
}

void spdf_render_token_free(spdf_render_token* token) {
    free(token);
}

static fz_cookie* token_cookie(spdf_render_token* token) {
    return token ? &token->cookie : NULL;
}

static int token_canceled(const spdf_render_token* token) {
    return token && token->cookie.abort;
}

typedef struct outline_builder {
    spdf_outline_item* items;
    int count;
    int capacity;
} outline_builder;

typedef struct comment_builder {
    spdf_comment_item* items;
    int count;
    int capacity;
} comment_builder;

typedef struct text_line_builder {
    spdf_text_line* items;
    int count;
    int capacity;
} text_line_builder;

typedef struct page_image_stats {
    double total_image_area;
    double largest_image_area;
    int image_count;
} page_image_stats;

static void set_error(char* err, size_t err_len, const char* message) {
    if (!err || err_len == 0) return;
    if (!message) message = "Unknown error";
    snprintf(err, err_len, "%s", message);
}

static char* copy_string(const char* value) {
    size_t len;
    char* copy;

    if (!value) value = "";
    len = strlen(value);
    copy = (char*)malloc(len + 1);
    if (!copy) return NULL;
    memcpy(copy, value, len + 1);
    return copy;
}

/* Splitting on '/' alone showed a whole C:\Users\x\a.pdf as the window title. */
static const char* path_basename(const char* path) {
    if (!path || !*path) return "Untitled";
    return spdf_compat_path_basename(path);
}

spdf_document* spdf_open_with_password(const char* path, const char* password, spdf_open_status* status,
                                       spdf_authentication* authentication, char* err, size_t err_len) {
    spdf_document* opened = NULL;
    fz_context* ctx = NULL;
    fz_document* doc = NULL;
    spdf_open_status open_status = SPDF_OPEN_OK;
    spdf_authentication auth_result = SPDF_AUTHENTICATION_NOT_REQUIRED;
    int password_protected = 0;
    char title[512];

    set_error(err, err_len, "");
    if (status) *status = SPDF_OPEN_ERROR;
    if (authentication) *authentication = SPDF_AUTHENTICATION_NOT_REQUIRED;
    if (!path || !*path) {
        set_error(err, err_len, "No document path was supplied.");
        return NULL;
    }

    ctx = fz_new_context(NULL, NULL, SPDF_MUPDF_STORE_LIMIT);
    if (!ctx) {
        set_error(err, err_len, "Could not create MuPDF context.");
        return NULL;
    }

    fz_try(ctx) {
        fz_register_document_handlers(ctx);
        doc = fz_open_document(ctx, path);
        password_protected = fz_needs_password(ctx, doc) != 0;
        if (password_protected && !password) {
            open_status = SPDF_OPEN_PASSWORD_REQUIRED;
        } else if (password_protected) {
            auth_result = (spdf_authentication)fz_authenticate_password(ctx, doc, password);
            if (auth_result == SPDF_AUTHENTICATION_NOT_REQUIRED) open_status = SPDF_OPEN_BAD_PASSWORD;
        }

        if (open_status == SPDF_OPEN_OK) {
            opened = (spdf_document*)calloc(1, sizeof(spdf_document));
            if (!opened) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");

            opened->ctx = ctx;
            opened->doc = doc;
            opened->password_protected = password_protected;
            opened->authentication = auth_result;
            spdf_recolor_page_cache_reset(&opened->recolor_pages);
            opened->picture_document = spdf_recolor_path_is_picture(path) ? 1 : -1;
            opened->page_count = fz_count_pages(ctx, doc);
            if (opened->page_count > 0) {
                opened->page_sizes =
                    (spdf_page_size_cache*)calloc((size_t)opened->page_count, sizeof(spdf_page_size_cache));
                if (!opened->page_sizes) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
            }

            title[0] = '\0';
            if (fz_lookup_metadata(ctx, doc, FZ_META_INFO_TITLE, title, sizeof(title)) <= 0 || !title[0])
                snprintf(title, sizeof(title), "%s", path_basename(path));
            opened->title = copy_string(title);
            if (!opened->title) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
        }
    }
    fz_catch(ctx) {
        open_status = SPDF_OPEN_ERROR;
        set_error(err, err_len, fz_caught_message(ctx));
        if (opened) {
            free(opened->title);
            free(opened->page_sizes);
            free(opened);
        }
        if (doc) fz_drop_document(ctx, doc);
        fz_drop_context(ctx);
        if (status) *status = open_status;
        return NULL;
    }

    if (!opened) {
        if (open_status == SPDF_OPEN_PASSWORD_REQUIRED)
            set_error(err, err_len, "Password required.");
        else if (open_status == SPDF_OPEN_BAD_PASSWORD)
            set_error(err, err_len, "Incorrect password.");
        if (doc) fz_drop_document(ctx, doc);
        fz_drop_context(ctx);
        if (status) *status = open_status;
        return NULL;
    }

    if (status) *status = SPDF_OPEN_OK;
    if (authentication) *authentication = auth_result;
    return opened;
}

spdf_document* spdf_open(const char* path, char* err, size_t err_len) {
    return spdf_open_with_password(path, NULL, NULL, NULL, err, err_len);
}

void spdf_close(spdf_document* doc) {
    if (!doc) return;
    spdf_drop_page_list_cache(doc, -1);
    if (doc->dark_doc) fz_drop_document(doc->ctx, doc->dark_doc);
    if (doc->doc) fz_drop_document(doc->ctx, doc->doc);
    if (doc->ctx) fz_drop_context(doc->ctx);
    free(doc->title);
    free(doc->page_sizes);
    free(doc);
}

int spdf_page_count(spdf_document* doc) {
    return doc ? doc->page_count : 0;
}

int spdf_selection_document_access(spdf_document* doc, int page_index, fz_context** ctx_out, fz_document** doc_out,
                                   char* err, size_t err_len) {
    if (ctx_out) *ctx_out = NULL;
    if (doc_out) *doc_out = NULL;
    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        set_error(err, err_len, "Page index is out of range.");
        return 0;
    }
    if (!ctx_out || !doc_out) {
        set_error(err, err_len, "Selection document output is required.");
        return 0;
    }
    *ctx_out = doc->ctx;
    *doc_out = doc->doc;
    return 1;
}

const char* spdf_title(spdf_document* doc) {
    return doc && doc->title ? doc->title : "";
}

int spdf_lookup_metadata(spdf_document* doc, const char* key, char* buf, size_t buf_len) {
    int found = 0;

    if (!buf || buf_len == 0) return 0;
    buf[0] = '\0';
    if (!doc || !doc->doc || !key || !*key) return 0;

    fz_try(doc->ctx) {
        found = fz_lookup_metadata(doc->ctx, doc->doc, key, buf, buf_len) > 0;
    }
    fz_catch(doc->ctx) {
        buf[0] = '\0';
        found = 0;
    }
    if (!found || !buf[0]) {
        buf[0] = '\0';
        return 0;
    }
    return 1;
}

int spdf_has_permission(spdf_document* doc, int permission) {
    int allowed = doc && doc->password_protected ? 0 : 1;
    /* FZ_PERMISSION_COPY is deliberately never consulted; see the header. */
    if (!doc || !doc->doc || permission == FZ_PERMISSION_COPY) return 1;
    fz_try(doc->ctx) {
        allowed = fz_has_permission(doc->ctx, doc->doc, (fz_permission)permission) != 0;
    }
    fz_catch(doc->ctx) {
        /* An authenticated protected document must never gain a permission
         * because its handler failed to answer the permission query. */
        allowed = doc->password_protected ? 0 : 1;
    }
    return allowed;
}

int spdf_is_password_protected(const spdf_document* doc) {
    return doc ? doc->password_protected : 0;
}

spdf_authentication spdf_authentication_result(const spdf_document* doc) {
    return doc ? doc->authentication : SPDF_AUTHENTICATION_NOT_REQUIRED;
}

int spdf_needs_password(spdf_document* doc) {
    return spdf_is_password_protected(doc);
}

int spdf_set_page_size_cache(spdf_document* doc, int page_index, float width, float height) {
    spdf_page_size_cache* cached;

    if (!doc || page_index < 0 || page_index >= doc->page_count || !doc->page_sizes || !isfinite(width) ||
        !isfinite(height) || width <= 0.0f || height <= 0.0f)
        return 0;

    cached = &doc->page_sizes[page_index];
    cached->width = width;
    cached->height = height;
    cached->valid = 1;
    return 1;
}

int spdf_page_size(spdf_document* doc, int page_index, float* width, float* height, char* err, size_t err_len) {
    fz_page* page = NULL;
    spdf_page_size_cache* cached;
    fz_rect bounds;

    set_error(err, err_len, "");
    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        set_error(err, err_len, "Page index is out of range.");
        return 0;
    }
    cached = doc->page_sizes ? &doc->page_sizes[page_index] : NULL;
    if (cached && cached->valid) {
        if (width) *width = cached->width;
        if (height) *height = cached->height;
        return 1;
    }

    fz_try(doc->ctx) {
        page = fz_load_page(doc->ctx, doc->doc, page_index);
        bounds = fz_bound_page(doc->ctx, page);
        if (cached) {
            cached->width = bounds.x1 - bounds.x0;
            cached->height = bounds.y1 - bounds.y0;
            cached->valid = 1;
        }
        if (width) *width = bounds.x1 - bounds.x0;
        if (height) *height = bounds.y1 - bounds.y0;
        fz_drop_page(doc->ctx, page);
        page = NULL;
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        if (page) fz_drop_page(doc->ctx, page);
        return 0;
    }

    return 1;
}

static int render_page_size_allowed(float page_width, float page_height, float zoom, char* err, size_t err_len) {
    double scaled_width;
    double scaled_height;

    if (!isfinite(page_width) || !isfinite(page_height) || page_width < 0.0f || page_height < 0.0f) {
        set_error(err, err_len, "Page has invalid dimensions.");
        return 0;
    }

    scaled_width = ceil((double)page_width * (double)zoom) + 2.0;
    scaled_height = ceil((double)page_height * (double)zoom) + 2.0;
    if (!isfinite(scaled_width) || !isfinite(scaled_height) || scaled_width > SPDF_MAX_RENDER_DIMENSION ||
        scaled_height > SPDF_MAX_RENDER_DIMENSION ||
        scaled_width * scaled_height * 4.0 > (double)SPDF_MAX_RENDER_BYTES) {
        set_error(err, err_len, "Rendered page would be too large.");
        return 0;
    }

    return 1;
}

static int render_pixmap_allocation_size(int width, int height, int comps, int src_stride, int* stride_out,
                                         size_t* byte_count_out, char* err, size_t err_len) {
    int stride;
    size_t byte_count;

    if (width <= 0 || height <= 0 || width > SPDF_MAX_RENDER_DIMENSION || height > SPDF_MAX_RENDER_DIMENSION) {
        set_error(err, err_len, "Rendered page has invalid dimensions.");
        return 0;
    }
    if (comps <= 0 || comps > 16 || src_stride <= 0 || (size_t)src_stride < (size_t)width * (size_t)comps) {
        set_error(err, err_len, "Rendered page has an invalid pixel layout.");
        return 0;
    }
    if (width > INT_MAX / 4) {
        set_error(err, err_len, "Rendered page is too wide.");
        return 0;
    }

    stride = width * 4;
    if ((size_t)height > ((size_t)-1) / (size_t)stride) {
        set_error(err, err_len, "Rendered page is too large.");
        return 0;
    }
    byte_count = (size_t)stride * (size_t)height;
    if (byte_count > SPDF_MAX_RENDER_BYTES) {
        set_error(err, err_len, "Rendered page is too large.");
        return 0;
    }

    *stride_out = stride;
    *byte_count_out = byte_count;
    return 1;
}

/* SILENT FAILURE IF WRONG: clock_gettime/CLOCK_MONOTONIC are absent from the
 * MSVC UCRT, and this feeds the render stats -- a stub reads 0, not an error. */
static double spdf_monotonic_ms(void) {
    return spdf_compat_monotonic_ms();
}

void spdf_drop_page_list_cache(spdf_document* doc, int page_index) {
    int i;

    if (!doc) return;
    for (i = 0; i < SPDF_PAGE_LIST_SLOTS; ++i) {
        spdf_page_list_entry* entry = &doc->page_lists[i];
        if (!entry->list) continue;
        if (page_index >= 0 && entry->page_index != page_index) continue;
        fz_drop_display_list(doc->ctx, entry->list);
        memset(entry, 0, sizeof(*entry));
    }
}

spdf_render_stats spdf_last_render_stats(const spdf_document* doc) {
    spdf_render_stats empty = {0, 0, 0.0};
    return doc ? doc->last_render_stats : empty;
}

/* LRU lookup of the display list for page_index; builds and caches it on miss.
 * Returns NULL on build failure (err is set, nothing partial is ever cached).
 * A token cancellation during the build run also returns NULL (err is
 * "Render canceled."); the partial list is dropped, never cached. */
static fz_display_list* get_or_build_page_list(spdf_document* doc, int page_index, unsigned flags,
                                               spdf_render_token* token, char* err, size_t err_len) {
    spdf_page_list_entry* slot;
    fz_page* page = NULL;
    fz_display_list* list = NULL;
    fz_device* dev = NULL;
    double build_start;
    double build_ms;
    int dark = render_document(doc, flags) != doc->doc;
    int i;

    for (i = 0; i < SPDF_PAGE_LIST_SLOTS; ++i) {
        spdf_page_list_entry* entry = &doc->page_lists[i];
        if (entry->list && entry->page_index == page_index && entry->dark == dark) {
            entry->last_used = ++doc->page_list_use_counter;
            return entry->list;
        }
    }

    slot = &doc->page_lists[0];
    for (i = 0; i < SPDF_PAGE_LIST_SLOTS; ++i) {
        spdf_page_list_entry* entry = &doc->page_lists[i];
        if (!entry->list) {
            slot = entry;
            break;
        }
        if (entry->last_used < slot->last_used) slot = entry;
    }

    fz_var(page);
    fz_var(list);
    fz_var(dev);

    build_start = spdf_monotonic_ms();
    fz_try(doc->ctx) {
        page = fz_load_page(doc->ctx, render_document(doc, flags), page_index);
        list = fz_new_display_list(doc->ctx, fz_bound_page(doc->ctx, page));
        dev = fz_new_list_device(doc->ctx, list);
        fz_run_page(doc->ctx, page, dev, fz_identity, token_cookie(token));
        fz_close_device(doc->ctx, dev);
        fz_drop_device(doc->ctx, dev);
        dev = NULL;
        fz_drop_page(doc->ctx, page);
        page = NULL;
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        if (dev) fz_drop_device(doc->ctx, dev);
        if (page) fz_drop_page(doc->ctx, page);
        if (list) fz_drop_display_list(doc->ctx, list);
        return NULL;
    }
    build_ms = spdf_monotonic_ms() - build_start;

    /* A cookie abort stops fz_run_page without throwing, leaving a PARTIAL
     * list: take the never-cache-on-error path so it can never be replayed. */
    if (token_canceled(token)) {
        fz_drop_display_list(doc->ctx, list);
        set_error(err, err_len, "Render canceled.");
        return NULL;
    }

    if (slot->list) fz_drop_display_list(doc->ctx, slot->list);
    slot->list = list;
    slot->page_index = page_index;
    slot->dark = dark;
    slot->build_ms = build_ms;
    slot->last_used = ++doc->page_list_use_counter;
    doc->last_render_stats.built_list = 1;
    doc->last_render_stats.build_ms = build_ms;
    return list;
}

#include "spdf_render_bitmap.h"

int spdf_render_page_rgba(spdf_document* doc, int page_index, float zoom, spdf_bitmap* out, char* err, size_t err_len) {
    return spdf_render_page_rgba_opts(doc, page_index, zoom, SPDF_RENDER_DEFAULT, NULL, out, err, err_len);
}

int spdf_render_page_rgba_opts(spdf_document* doc, int page_index, float zoom, unsigned flags, spdf_render_token* token,
                               spdf_bitmap* out, char* err, size_t err_len) {
    fz_page* page = NULL;
    fz_pixmap* pix = NULL;
    fz_device* dev = NULL;
    fz_display_list* list = NULL;
    fz_rect bounds;
    fz_rect transformed;
    fz_irect bbox;
    fz_matrix ctm;
    float page_width;
    float page_height;

    set_error(err, err_len, "");
    if (!out) {
        set_error(err, err_len, "No render output was supplied.");
        return 0;
    }
    memset(out, 0, sizeof(*out));

    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        set_error(err, err_len, "Page index is out of range.");
        return 0;
    }
    memset(&doc->last_render_stats, 0, sizeof(doc->last_render_stats));
    if (!isfinite(zoom)) {
        set_error(err, err_len, "Zoom level is invalid.");
        return 0;
    }
    if (zoom <= 0.01f) zoom = 0.01f;
    if (!spdf_page_size(doc, page_index, &page_width, &page_height, err, err_len)) return 0;
    if (!render_page_size_allowed(page_width, page_height, zoom, err, err_len)) return 0;

    if (token_canceled(token)) {
        set_error(err, err_len, "Render canceled.");
        return 0;
    }

    if (flags & SPDF_RENDER_USE_PAGE_LIST) {
        list = get_or_build_page_list(doc, page_index, flags, token, err, err_len);
        if (!list) {
            if (token_canceled(token)) return 0; /* err is already "Render canceled." */
            set_error(err, err_len, "");         /* fail-open: fall through to the direct path */
        }
    }

    fz_var(page);
    fz_var(pix);
    fz_var(dev);

    fz_try(doc->ctx) {
        if (list) {
            bounds = fz_bound_display_list(doc->ctx, list);
            ctm = fz_scale(zoom, zoom);
            transformed = fz_transform_rect(bounds, ctm);
            bbox = fz_round_rect(transformed);
            pix = fz_new_pixmap_with_bbox(doc->ctx, fz_device_rgb(doc->ctx), bbox, NULL, 0);
            fz_clear_pixmap_with_value(doc->ctx, pix, render_paper_value(doc, flags));
            dev = fz_new_draw_device(doc->ctx, fz_identity, pix);
            fz_run_display_list(doc->ctx, list, dev, ctm, fz_infinite_rect, token_cookie(token));
            fz_close_device(doc->ctx, dev);
            fz_drop_device(doc->ctx, dev);
            dev = NULL;
            doc->last_render_stats.used_list = 1;
        } else if (token || render_document(doc, flags) != doc->doc) {
            /* Explicit equivalent of fz_new_pixmap_from_page_number (mupdf
             * source/fitz/util.c, alpha=0) so the cookie reaches fz_run_page. */
            page = fz_load_page(doc->ctx, render_document(doc, flags), page_index);
            bounds = fz_bound_page(doc->ctx, page);
            ctm = fz_scale(zoom, zoom);
            transformed = fz_transform_rect(bounds, ctm);
            bbox = fz_round_rect(transformed);
            pix = fz_new_pixmap_with_bbox(doc->ctx, fz_device_rgb(doc->ctx), bbox, NULL, 0);
            fz_clear_pixmap_with_value(doc->ctx, pix, render_paper_value(doc, flags));
            dev = fz_new_draw_device(doc->ctx, ctm, pix);
            fz_run_page(doc->ctx, page, dev, fz_identity, token_cookie(token));
            fz_close_device(doc->ctx, dev);
            fz_drop_device(doc->ctx, dev);
            dev = NULL;
            fz_drop_page(doc->ctx, page);
            page = NULL;
        } else {
            pix = fz_new_pixmap_from_page_number(doc->ctx, doc->doc, page_index, fz_scale(zoom, zoom),
                                                 fz_device_rgb(doc->ctx), 0);
        }

        /* A cookie abort stops the run without throwing; skip the bitmap copy
         * and report the cancellation after cleanup below. */
        if (!token_canceled(token)) copy_pixmap_to_bitmap(doc, pix, page_index, zoom, flags, out, err, err_len);

        fz_drop_pixmap(doc->ctx, pix);
        pix = NULL;
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        spdf_free_bitmap(out);
        if (dev) fz_drop_device(doc->ctx, dev);
        if (pix) fz_drop_pixmap(doc->ctx, pix);
        if (page) fz_drop_page(doc->ctx, page);
        return 0;
    }

    if (token_canceled(token)) {
        spdf_free_bitmap(out);
        set_error(err, err_len, "Render canceled.");
        return 0;
    }

    return 1;
}

int spdf_render_page_region_rgba(spdf_document* doc, int page_index, float zoom, spdf_rect region, spdf_bitmap* out,
                                 char* err, size_t err_len) {
    return spdf_render_page_region_rgba_opts(doc, page_index, zoom, region, SPDF_RENDER_DEFAULT, NULL, out, err,
                                             err_len);
}

int spdf_render_page_region_rgba_opts(spdf_document* doc, int page_index, float zoom, spdf_rect region, unsigned flags,
                                      spdf_render_token* token, spdf_bitmap* out, char* err, size_t err_len) {
    fz_page* page = NULL;
    fz_pixmap* pix = NULL;
    fz_device* dev = NULL;
    fz_display_list* list = NULL;
    fz_rect bounds;
    fz_rect crop;
    fz_rect transformed;
    fz_irect bbox;
    fz_matrix ctm;
    float page_width;
    float page_height;

    set_error(err, err_len, "");
    if (!out) {
        set_error(err, err_len, "No render output was supplied.");
        return 0;
    }
    memset(out, 0, sizeof(*out));

    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        set_error(err, err_len, "Page index is out of range.");
        return 0;
    }
    memset(&doc->last_render_stats, 0, sizeof(doc->last_render_stats));
    if (!isfinite(zoom)) {
        set_error(err, err_len, "Zoom level is invalid.");
        return 0;
    }
    if (zoom <= 0.01f) zoom = 0.01f;
    if (!spdf_page_size(doc, page_index, &page_width, &page_height, err, err_len)) return 0;

    region.x0 = fmaxf(0.0f, fminf(region.x0, page_width));
    region.x1 = fmaxf(0.0f, fminf(region.x1, page_width));
    region.y0 = fmaxf(0.0f, fminf(region.y0, page_height));
    region.y1 = fmaxf(0.0f, fminf(region.y1, page_height));
    if (region.x1 <= region.x0 || region.y1 <= region.y0) {
        set_error(err, err_len, "Render region is empty.");
        return 0;
    }
    if (!render_page_size_allowed(region.x1 - region.x0, region.y1 - region.y0, zoom, err, err_len)) return 0;

    if (token_canceled(token)) {
        set_error(err, err_len, "Render canceled.");
        return 0;
    }

    if (flags & SPDF_RENDER_USE_PAGE_LIST) {
        list = get_or_build_page_list(doc, page_index, flags, token, err, err_len);
        if (!list) {
            if (token_canceled(token)) return 0; /* err is already "Render canceled." */
            set_error(err, err_len, "");         /* fail-open: fall through to the direct path */
        }
    }

    fz_var(page);
    fz_var(pix);
    fz_var(dev);

    fz_try(doc->ctx) {
        if (list) {
            bounds = fz_bound_display_list(doc->ctx, list);
        } else {
            page = fz_load_page(doc->ctx, render_document(doc, flags), page_index);
            bounds = fz_bound_page(doc->ctx, page);
        }
        crop.x0 = bounds.x0 + region.x0;
        crop.y0 = bounds.y0 + region.y0;
        crop.x1 = bounds.x0 + region.x1;
        crop.y1 = bounds.y0 + region.y1;

        ctm = fz_scale(zoom, zoom);
        transformed = fz_transform_rect(crop, ctm);
        bbox = fz_round_rect(transformed);
        pix = fz_new_pixmap_with_bbox(doc->ctx, fz_device_rgb(doc->ctx), bbox, NULL, 0);
        fz_clear_pixmap_with_value(doc->ctx, pix, render_paper_value(doc, flags));
        dev = fz_new_draw_device(doc->ctx, fz_identity, pix);
        if (list) {
            /* Scissor is the DEVICE-space rect of the pixmap, not page coords. */
            fz_run_display_list(doc->ctx, list, dev, ctm, fz_rect_from_irect(bbox), token_cookie(token));
            doc->last_render_stats.used_list = 1;
        } else {
            fz_run_page(doc->ctx, page, dev, ctm, token_cookie(token));
        }
        fz_close_device(doc->ctx, dev);
        fz_drop_device(doc->ctx, dev);
        dev = NULL;

        /* A cookie abort stops the run without throwing; skip the bitmap copy
         * and report the cancellation after cleanup below. */
        if (!token_canceled(token)) copy_pixmap_to_bitmap(doc, pix, page_index, zoom, flags, out, err, err_len);

        fz_drop_pixmap(doc->ctx, pix);
        pix = NULL;
        if (page) {
            fz_drop_page(doc->ctx, page);
            page = NULL;
        }
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        spdf_free_bitmap(out);
        if (dev) fz_drop_device(doc->ctx, dev);
        if (pix) fz_drop_pixmap(doc->ctx, pix);
        if (page) fz_drop_page(doc->ctx, page);
        return 0;
    }

    if (token_canceled(token)) {
        spdf_free_bitmap(out);
        set_error(err, err_len, "Render canceled.");
        return 0;
    }

    return 1;
}

void spdf_free_bitmap(spdf_bitmap* bitmap) {
    if (!bitmap) return;
    free(bitmap->rgba);
    memset(bitmap, 0, sizeof(*bitmap));
}

int spdf_search_page(spdf_document* doc, int page_index, const char* needle, char* err, size_t err_len) {
    fz_quad hits[128];
    int hit_marks[128];
    int count = 0;

    set_error(err, err_len, "");
    if (!needle || !*needle) return 0;
    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        set_error(err, err_len, "Page index is out of range.");
        return -1;
    }

    fz_try(doc->ctx) {
        count = fz_search_page_number(doc->ctx, doc->doc, page_index, needle, hit_marks, hits, 128);
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        return -1;
    }

    return count;
}

int spdf_search_page_rects(spdf_document* doc, int page_index, const char* needle, spdf_rect* rects, int rect_max,
                           char* err, size_t err_len) {
    fz_quad hits[256];
    int hit_marks[256];
    int max_hits;
    int count = 0;
    int i;

    set_error(err, err_len, "");
    if (!needle || !*needle) return 0;
    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        set_error(err, err_len, "Page index is out of range.");
        return -1;
    }
    if (!rects || rect_max <= 0) return spdf_search_page(doc, page_index, needle, err, err_len);

    max_hits = rect_max < 256 ? rect_max : 256;
    fz_try(doc->ctx) {
        count = fz_search_page_number(doc->ctx, doc->doc, page_index, needle, hit_marks, hits, max_hits);
        if (count > max_hits) count = max_hits;
        for (i = 0; i < count; ++i) {
            fz_rect r = fz_rect_from_quad(hits[i]);
            rects[i].x0 = r.x0;
            rects[i].y0 = r.y0;
            rects[i].x1 = r.x1;
            rects[i].y1 = r.y1;
        }
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        return -1;
    }

    return count;
}

static fz_search_options spdf_search_options(int regex) {
    fz_search_options options = FZ_SEARCH_IGNORE_CASE;

    if (regex) options |= FZ_SEARCH_REGEXP;
    if (regex) options |= FZ_SEARCH_KEEP_LINES | FZ_SEARCH_KEEP_PARAGRAPHS;
    return options;
}

int spdf_search_page_options(spdf_document* doc, int page_index, const char* needle, int regex, int regex_multiline,
                             char* err, size_t err_len) {
    int count = 0;
    char* multiline_needle = NULL;
    const char* search_needle = needle;

    if (!regex) return spdf_search_page(doc, page_index, needle, err, err_len);

    set_error(err, err_len, "");
    if (!needle || !*needle) return 0;
    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        set_error(err, err_len, "Page index is out of range.");
        return -1;
    }
    if (regex_multiline) {
        multiline_needle = copy_multiline_regex_pattern(needle);
        if (!multiline_needle) {
            set_error(err, err_len, "Out of memory");
            return -1;
        }
        search_needle = multiline_needle;
    }

    fz_try(doc->ctx) {
        count = fz_match_page_number_cb(doc->ctx, doc->doc, page_index, search_needle, NULL, NULL,
                                        spdf_search_options(regex));
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        free(multiline_needle);
        return -1;
    }

    free(multiline_needle);
    return count;
}

typedef struct search_rect_builder {
    spdf_rect* rects;
    int rect_max;
    int count;
} search_rect_builder;

static int append_match_rects(fz_context* ctx, void* opaque, int num_quads, fz_quad* quads, int chapter, int page) {
    search_rect_builder* builder = (search_rect_builder*)opaque;
    int i;

    (void)ctx;
    (void)chapter;
    (void)page;

    for (i = 0; i < num_quads && builder->count < builder->rect_max; ++i) {
        fz_rect r = fz_rect_from_quad(quads[i]);
        builder->rects[builder->count].x0 = r.x0;
        builder->rects[builder->count].y0 = r.y0;
        builder->rects[builder->count].x1 = r.x1;
        builder->rects[builder->count].y1 = r.y1;
        builder->count++;
    }
    return builder->count >= builder->rect_max ? 1 : 0;
}

int spdf_search_page_rects_options(spdf_document* doc, int page_index, const char* needle, int regex,
                                   int regex_multiline, spdf_rect* rects, int rect_max, char* err, size_t err_len) {
    int count = 0;
    search_rect_builder builder;
    char* multiline_needle = NULL;
    const char* search_needle = needle;

    if (!regex) return spdf_search_page_rects(doc, page_index, needle, rects, rect_max, err, err_len);

    set_error(err, err_len, "");
    if (!needle || !*needle) return 0;
    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        set_error(err, err_len, "Page index is out of range.");
        return -1;
    }
    if (!rects || rect_max <= 0)
        return spdf_search_page_options(doc, page_index, needle, regex, regex_multiline, err, err_len);
    if (regex_multiline) {
        multiline_needle = copy_multiline_regex_pattern(needle);
        if (!multiline_needle) {
            set_error(err, err_len, "Out of memory");
            return -1;
        }
        search_needle = multiline_needle;
    }

    fz_try(doc->ctx) {
        builder.rects = rects;
        builder.rect_max = rect_max;
        builder.count = 0;
        (void)fz_match_page_number_cb(doc->ctx, doc->doc, page_index, search_needle, append_match_rects, &builder,
                                      spdf_search_options(regex));
        count = builder.count;
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        free(multiline_needle);
        return -1;
    }

    free(multiline_needle);
    return count;
}

int spdf_select_page_text(spdf_document* doc, int page_index, float ax, float ay, float bx, float by, spdf_rect* rects,
                          int rect_max, char** text_out, char* err, size_t err_len) {
    fz_stext_page* text = NULL;
    fz_quad* quads = NULL;
    fz_point a;
    fz_point b;
    int max_hits;
    int count = 0;
    int i;
    char* copied = NULL;
    int failed = 0;

    set_error(err, err_len, "");
    if (text_out) *text_out = NULL;
    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        set_error(err, err_len, "Page index is out of range.");
        return -1;
    }

    max_hits = rects && rect_max > 0 ? rect_max : 0;
    if (max_hits > 0) {
        if ((size_t)max_hits > SIZE_MAX / sizeof(fz_quad)) {
            set_error(err, err_len, "Selection geometry is too large.");
            return -1;
        }
        quads = (fz_quad*)malloc((size_t)max_hits * sizeof(fz_quad));
        if (!quads) {
            set_error(err, err_len, "Out of memory");
            return -1;
        }
    }

    fz_try(doc->ctx) {
        text = fz_new_stext_page_from_page_number(doc->ctx, doc->doc, page_index, NULL);
        a = fz_make_point(ax, ay);
        b = fz_make_point(bx, by);
        if (max_hits > 0) {
            count = fz_highlight_selection(doc->ctx, text, a, b, quads, max_hits);
            if (count > max_hits) count = max_hits;
            for (i = 0; i < count; ++i) {
                fz_rect r = fz_rect_from_quad(quads[i]);
                rects[i].x0 = r.x0;
                rects[i].y0 = r.y0;
                rects[i].x1 = r.x1;
                rects[i].y1 = r.y1;
            }
        }
        if (text_out) {
            copied = fz_copy_selection(doc->ctx, text, a, b, 0);
            *text_out = copy_string(copied ? copied : "");
            if (!*text_out) fz_throw(doc->ctx, FZ_ERROR_SYSTEM, "Out of memory");
        }
    }
    fz_always(doc->ctx) {
        if (copied) fz_free(doc->ctx, copied);
        if (text) fz_drop_stext_page(doc->ctx, text);
        free(quads);
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        failed = 1;
    }
    if (failed) {
        if (text_out) free(*text_out);
        if (text_out) *text_out = NULL;
        return -1;
    }

    return count;
}

void spdf_free_string(char* text) {
    free(text);
}

static double spdf_rect_area(fz_rect rect) {
    double w;
    double h;

    if (fz_is_empty_rect(rect)) return 0.0;
    w = (double)(rect.x1 - rect.x0);
    h = (double)(rect.y1 - rect.y0);
    if (w <= 0.0 || h <= 0.0) return 0.0;
    return w * h;
}

static void spdf_rect_to_public(fz_rect rect, spdf_rect* out) {
    out->x0 = rect.x0;
    out->y0 = rect.y0;
    out->x1 = rect.x1;
    out->y1 = rect.y1;
}

static int append_extracted_text_line(text_line_builder* builder, const char* text, fz_rect bounds, float font_size) {
    spdf_text_line* next_items;
    int next_capacity;

    if (builder->count == builder->capacity) {
        next_capacity = builder->capacity ? builder->capacity * 2 : 64;
        next_items = (spdf_text_line*)realloc(builder->items, (size_t)next_capacity * sizeof(spdf_text_line));
        if (!next_items) return 0;
        builder->items = next_items;
        builder->capacity = next_capacity;
    }

    memset(&builder->items[builder->count], 0, sizeof(builder->items[builder->count]));
    builder->items[builder->count].text = copy_string(text);
    if (!builder->items[builder->count].text) return 0;
    spdf_rect_to_public(bounds, &builder->items[builder->count].bounds);
    builder->items[builder->count].font_size = font_size;
    builder->count++;
    return 1;
}

static void free_text_line_builder(text_line_builder* builder) {
    int i;

    if (!builder) return;
    for (i = 0; i < builder->count; ++i) free(builder->items[i].text);
    free(builder->items);
    memset(builder, 0, sizeof(*builder));
}

static int rune_is_line_space(int rune) {
    return rune == ' ' || rune == '\t' || rune == '\r' || rune == '\n' || rune == '\f';
}

static int append_line_text_rune(fz_context* ctx, fz_buffer* buf, int rune, int* last_was_space) {
    if (rune_is_line_space(rune)) {
        if (*last_was_space) return 0;
        fz_append_byte(ctx, buf, ' ');
        *last_was_space = 1;
        return 1;
    }
    if (rune <= 32 || rune > 0x10ffff) rune = '?';
    fz_append_rune(ctx, buf, rune);
    *last_was_space = 0;
    return 1;
}

static int append_stext_line(fz_context* ctx, text_line_builder* builder, fz_stext_line* line) {
    fz_buffer* buf = NULL;
    fz_stext_char* ch;
    fz_rect bounds = fz_empty_rect;
    double total_font_size = 0.0;
    int font_count = 0;
    int has_bounds = 0;
    int last_was_space = 1;
    const char* text;
    size_t len;

    fz_var(buf);
    fz_try(ctx) {
        buf = fz_new_buffer(ctx, 128);
        for (ch = line->first_char; ch; ch = ch->next) {
            fz_rect char_bounds = fz_rect_from_quad(ch->quad);
            if (!fz_is_empty_rect(char_bounds)) {
                bounds = has_bounds ? fz_union_rect(bounds, char_bounds) : char_bounds;
                has_bounds = 1;
            }
            if (ch->size > 0.0f) {
                total_font_size += ch->size;
                font_count++;
            }
            append_line_text_rune(ctx, buf, ch->c, &last_was_space);
        }

        fz_terminate_buffer(ctx, buf);
        text = fz_string_from_buffer(ctx, buf);
        len = strlen(text);
        while (len > 0 && text[len - 1] == ' ') len--;
        if (len > 0 && has_bounds) {
            char* trimmed = (char*)malloc(len + 1);
            if (!trimmed) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
            memcpy(trimmed, text, len);
            trimmed[len] = '\0';
            if (!append_extracted_text_line(
                    builder, trimmed, bounds,
                    font_count > 0 ? (float)(total_font_size / (double)font_count) : bounds.y1 - bounds.y0)) {
                free(trimmed);
                fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
            }
            free(trimmed);
        }
        fz_drop_buffer(ctx, buf);
        buf = NULL;
    }
    fz_catch(ctx) {
        if (buf) fz_drop_buffer(ctx, buf);
        fz_rethrow(ctx);
    }

    return 1;
}

static void collect_image_stats_from_blocks(fz_rect page_bounds, fz_stext_block* block, page_image_stats* stats) {
    for (; block; block = block->next) {
        if (block->type == FZ_STEXT_BLOCK_IMAGE) {
            double area = spdf_rect_area(fz_intersect_rect(block->bbox, page_bounds));
            if (area > 0.0) {
                stats->total_image_area += area;
                if (area > stats->largest_image_area) stats->largest_image_area = area;
                stats->image_count++;
            }
        } else if (block->type == FZ_STEXT_BLOCK_STRUCT && block->u.s.down) {
            collect_image_stats_from_blocks(page_bounds, block->u.s.down->first_block, stats);
        }
    }
}

static int text_page_is_image_backed(fz_stext_page* text) {
    page_image_stats stats;
    double page_area;

    memset(&stats, 0, sizeof(stats));
    if (!text) return 0;
    page_area = spdf_rect_area(text->mediabox);
    if (page_area <= 0.0) return 0;
    collect_image_stats_from_blocks(text->mediabox, text->first_block, &stats);
    if (stats.largest_image_area / page_area >= 0.55) return 1;
    if (stats.image_count > 1 && stats.total_image_area / page_area >= 0.75) return 1;
    return 0;
}

/* Image-block rectangles of a page, in page space, for the dark theme's
 * "leave images alone" setting. Recurses through FZ_STEXT_BLOCK_STRUCT the way
 * collect_image_stats_from_blocks() above does. */
static void collect_image_rects_from_blocks(fz_stext_block* block, spdf_recolor_page_entry* entry) {
    for (; block; block = block->next) {
        if (block->type == FZ_STEXT_BLOCK_IMAGE) {
            if (entry->count < SPDF_RECOLOR_MAX_REGIONS && block->bbox.x1 > block->bbox.x0 &&
                block->bbox.y1 > block->bbox.y0) {
                spdf_recolor_frect* r = &entry->rects[entry->count++];
                r->x0 = block->bbox.x0;
                r->y0 = block->bbox.y0;
                r->x1 = block->bbox.x1;
                r->y1 = block->bbox.y1;
            }
        } else if (block->type == FZ_STEXT_BLOCK_STRUCT && block->u.s.down) {
            collect_image_rects_from_blocks(block->u.s.down->first_block, entry);
        }
    }
}

static int page_recolor_exclusions(spdf_document* doc, int page_index, float zoom, int origin_x, int origin_y,
                                   spdf_recolor_irect* out, int max) {
    spdf_recolor_page_entry* entry;

    if (!doc || page_index < 0 || page_index >= doc->page_count) return 0;
    entry = spdf_recolor_page_cache_find(&doc->recolor_pages, page_index);
    if (!entry) {
        /* One structured-text pass per PAGE, not per render: renders repeat at
         * every zoom and display scale, the image rectangles do not. */
        fz_stext_page* text = NULL;
        entry = spdf_recolor_page_cache_claim(&doc->recolor_pages, page_index);
        if (!entry) return 0;
        fz_try(doc->ctx) {
            fz_stext_options opts;
            memset(&opts, 0, sizeof(opts));
            opts.flags = FZ_STEXT_PRESERVE_IMAGES;
            text = fz_new_stext_page_from_page_number(doc->ctx, doc->doc, page_index, &opts);
            if (text) {
                entry->image_backed = text_page_is_image_backed(text);
                collect_image_rects_from_blocks(text->first_block, entry);
            }
        }
        fz_always(doc->ctx) {
            fz_drop_stext_page(doc->ctx, text);
        }
        fz_catch(doc->ctx) {
            /* A page whose text cannot be walked keeps an empty entry, which
             * means "no exclusions": the page is recolored whole, which is the
             * safe answer -- dark mode still works, photographs are the only
             * casualty. */
            fz_ignore_error(doc->ctx);
        }
    }
    return spdf_recolor_page_entry_exclusions(entry, zoom, origin_x, origin_y, out, max);
}

static void extract_lines_from_blocks(fz_context* ctx, text_line_builder* builder, fz_stext_block* block) {
    for (; block; block = block->next) {
        if (block->type == FZ_STEXT_BLOCK_TEXT) {
            fz_stext_line* line;
            for (line = block->u.t.first_line; line; line = line->next) append_stext_line(ctx, builder, line);
        } else if (block->type == FZ_STEXT_BLOCK_STRUCT && block->u.s.down) {
            extract_lines_from_blocks(ctx, builder, block->u.s.down->first_block);
        }
    }
}

int spdf_extract_page_text_lines(spdf_document* doc, int page_index, spdf_text_lines* out, char* err, size_t err_len) {
    fz_stext_page* text = NULL;
    fz_stext_options opts;
    text_line_builder builder;

    set_error(err, err_len, "");
    if (!out) {
        set_error(err, err_len, "No text lines output was supplied.");
        return 0;
    }
    memset(out, 0, sizeof(*out));
    memset(&builder, 0, sizeof(builder));
    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        set_error(err, err_len, "Page index is out of range.");
        return 0;
    }

    fz_try(doc->ctx) {
        memset(&opts, 0, sizeof(opts));
        opts.flags = FZ_STEXT_PRESERVE_IMAGES;
        text = fz_new_stext_page_from_page_number(doc->ctx, doc->doc, page_index, &opts);
        extract_lines_from_blocks(doc->ctx, &builder, text ? text->first_block : NULL);
        out->image_backed = text_page_is_image_backed(text);
        fz_drop_stext_page(doc->ctx, text);
        text = NULL;
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        if (text) fz_drop_stext_page(doc->ctx, text);
        free_text_line_builder(&builder);
        return 0;
    }

    out->items = builder.items;
    out->count = builder.count;
    return 1;
}

void spdf_free_text_lines(spdf_text_lines* lines) {
    int i;

    if (!lines) return;
    for (i = 0; i < lines->count; ++i) free(lines->items[i].text);
    free(lines->items);
    memset(lines, 0, sizeof(*lines));
}

static int append_outline_item(outline_builder* builder, const char* title, int page_index, int level, float dest_x,
                               float dest_y, int has_dest) {
    spdf_outline_item* next_items;
    int next_capacity;

    if (builder->count == builder->capacity) {
        next_capacity = builder->capacity ? builder->capacity * 2 : 32;
        next_items = (spdf_outline_item*)realloc(builder->items, (size_t)next_capacity * sizeof(spdf_outline_item));
        if (!next_items) return 0;
        builder->items = next_items;
        builder->capacity = next_capacity;
    }

    builder->items[builder->count].title = copy_string(title && *title ? title : "Untitled");
    if (!builder->items[builder->count].title) return 0;
    builder->items[builder->count].page_index = page_index;
    builder->items[builder->count].level = level;
    builder->items[builder->count].dest_x = has_dest ? dest_x : 0.0f;
    builder->items[builder->count].dest_y = has_dest ? dest_y : 0.0f;
    builder->items[builder->count].has_dest = has_dest;
    builder->count++;
    return 1;
}

static void collect_outline(spdf_document* doc, outline_builder* builder, fz_outline* outline, int level) {
    fz_outline* item;

    for (item = outline; item; item = item->next) {
        int page_index = -1;
        fz_location location = item->page;
        /* fz_outline.x/y carry the destination point for the outline link. For
         * /Fit-style destinations mupdf leaves them as 0 (or non-finite); only
         * treat the point as usable when it is finite and not the (0,0) sentinel
         * so position-aware attribution falls back gracefully otherwise. */
        float dest_x = item->x;
        float dest_y = item->y;
        int has_dest = isfinite(dest_x) && isfinite(dest_y) && !(dest_x == 0.0f && dest_y == 0.0f);
        /* EPUB outlines are returned as internal URIs with an unresolved
         * (-1,-1) location. Resolve only that fallback case: PDF destinations
         * remain untouched, while external and invalid links stay unresolved. */
        if ((location.chapter < 0 || location.page < 0) && item->uri && *item->uri &&
            !fz_is_external_link(doc->ctx, item->uri))
            location = fz_resolve_link(doc->ctx, doc->doc, item->uri, NULL, NULL);
        if (location.chapter >= 0 && location.page >= 0)
            page_index = fz_page_number_from_location(doc->ctx, doc->doc, location);
        if (!append_outline_item(builder, item->title, page_index, level, dest_x, dest_y, has_dest))
            fz_throw(doc->ctx, FZ_ERROR_SYSTEM, "Out of memory");
        if (item->down) collect_outline(doc, builder, item->down, level + 1);
    }
}

int spdf_load_outline(spdf_document* doc, spdf_outline* out, char* err, size_t err_len) {
    fz_outline* outline = NULL;
    outline_builder builder;

    set_error(err, err_len, "");
    if (!out) {
        set_error(err, err_len, "No outline output was supplied.");
        return 0;
    }
    memset(out, 0, sizeof(*out));
    memset(&builder, 0, sizeof(builder));
    if (!doc) return 0;

    fz_try(doc->ctx) {
        outline = fz_load_outline(doc->ctx, doc->doc);
        if (outline) collect_outline(doc, &builder, outline, 0);
        if (outline) fz_drop_outline(doc->ctx, outline);
        outline = NULL;
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        if (outline) fz_drop_outline(doc->ctx, outline);
        out->items = builder.items;
        out->count = builder.count;
        spdf_free_outline(out);
        return 0;
    }

    out->items = builder.items;
    out->count = builder.count;
    return 1;
}

void spdf_free_outline(spdf_outline* outline) {
    int i;

    if (!outline) return;
    for (i = 0; i < outline->count; ++i) free(outline->items[i].title);
    free(outline->items);
    memset(outline, 0, sizeof(*outline));
}

static int append_comment_item(comment_builder* builder, const char* author, const char* text, const char* type,
                               int comment_index, int page_index, fz_rect bounds) {
    spdf_comment_item* next_items;
    char* author_copy;
    char* text_copy;
    char* type_copy;
    int next_capacity;

    if (builder->count == builder->capacity) {
        next_capacity = builder->capacity ? builder->capacity * 2 : 32;
        next_items = (spdf_comment_item*)realloc(builder->items, (size_t)next_capacity * sizeof(spdf_comment_item));
        if (!next_items) return 0;
        builder->items = next_items;
        builder->capacity = next_capacity;
    }

    author_copy = copy_string(author && *author ? author : "");
    text_copy = copy_string(text && *text ? text : "");
    type_copy = copy_string(type && *type ? type : "Annotation");
    if (!author_copy || !text_copy || !type_copy) {
        free(author_copy);
        free(text_copy);
        free(type_copy);
        return 0;
    }
    builder->items[builder->count].author = author_copy;
    builder->items[builder->count].text = text_copy;
    builder->items[builder->count].type = type_copy;
    builder->items[builder->count].index = comment_index;
    builder->items[builder->count].page_index = page_index;
    builder->items[builder->count].bounds.x0 = bounds.x0;
    builder->items[builder->count].bounds.y0 = bounds.y0;
    builder->items[builder->count].bounds.x1 = bounds.x1;
    builder->items[builder->count].bounds.y1 = bounds.y1;
    builder->count++;
    return 1;
}

static int annot_type_should_surface(enum pdf_annot_type type) {
    return type != PDF_ANNOT_LINK && type != PDF_ANNOT_POPUP && type != PDF_ANNOT_WIDGET && type != PDF_ANNOT_SCREEN;
}

static int comment_annotation_should_surface(const char* contents, const char* author, enum pdf_annot_type annot_type) {
    return (contents && *contents) || (author && *author) || annot_type_should_surface(annot_type);
}

static const char* dict_text_or_empty(fz_context* ctx, pdf_obj* obj, pdf_obj* key) {
    const char* text;

    if (!obj) return "";
    text = pdf_dict_get_text_string(ctx, obj, key);
    return text ? text : "";
}

static const char* comment_author_or_empty(fz_context* ctx, pdf_obj* annot_obj, pdf_obj* popup) {
    const char* author = dict_text_or_empty(ctx, annot_obj, PDF_NAME(T));

    if (!author || !*author) author = dict_text_or_empty(ctx, popup, PDF_NAME(T));
    return author;
}

static pdf_obj* popup_for_parent(fz_context* ctx, pdf_obj* annots, pdf_obj* parent) {
    int i;
    int count;

    if (!annots || !parent) return NULL;
    count = pdf_array_len(ctx, annots);
    for (i = 0; i < count; ++i) {
        pdf_obj* annot = pdf_array_get(ctx, annots, i);
        pdf_obj* subtype = pdf_dict_get(ctx, annot, PDF_NAME(Subtype));
        if (!pdf_name_eq(ctx, subtype, PDF_NAME(Popup))) continue;
        if (pdf_objcmp_resolve(ctx, pdf_dict_get(ctx, annot, PDF_NAME(Parent)), parent) == 0) return annot;
    }
    return NULL;
}

static void remove_popups_for_parent(fz_context* ctx, pdf_obj* annots, pdf_obj* parent) {
    int i;

    if (!annots || !parent) return;
    for (i = 0; i < pdf_array_len(ctx, annots);) {
        pdf_obj* annot = pdf_array_get(ctx, annots, i);
        pdf_obj* subtype = pdf_dict_get(ctx, annot, PDF_NAME(Subtype));
        if (pdf_name_eq(ctx, subtype, PDF_NAME(Popup)) &&
            pdf_objcmp_resolve(ctx, pdf_dict_get(ctx, annot, PDF_NAME(Parent)), parent) == 0) {
            pdf_array_delete(ctx, annots, i);
            continue;
        }
        i++;
    }
}

static fz_rect annot_bounds(fz_context* ctx, pdf_annot* annot) {
    fz_rect bounds = fz_empty_rect;
    int i;

    if (pdf_annot_has_quad_points(ctx, annot)) {
        int count = pdf_annot_quad_point_count(ctx, annot);
        for (i = 0; i < count; ++i)
            bounds = fz_union_rect(bounds, fz_rect_from_quad(pdf_annot_quad_point(ctx, annot, i)));
        if (!fz_is_empty_rect(bounds)) return bounds;
    }

    if (pdf_annot_has_ink_list(ctx, annot)) {
        int stroke;
        int stroke_count = pdf_annot_ink_list_count(ctx, annot);
        for (stroke = 0; stroke < stroke_count; ++stroke) {
            int vertex;
            int vertex_count = pdf_annot_ink_list_stroke_count(ctx, annot, stroke);
            for (vertex = 0; vertex < vertex_count; ++vertex)
                bounds = fz_include_point_in_rect(bounds, pdf_annot_ink_list_stroke_vertex(ctx, annot, stroke, vertex));
        }
        if (!fz_is_empty_rect(bounds)) return fz_expand_rect(bounds, 2);
    }

    if (pdf_annot_has_vertices(ctx, annot)) {
        int count = pdf_annot_vertex_count(ctx, annot);
        for (i = 0; i < count; ++i) bounds = fz_include_point_in_rect(bounds, pdf_annot_vertex(ctx, annot, i));
        if (!fz_is_empty_rect(bounds)) return fz_expand_rect(bounds, 2);
    }

    if (pdf_annot_has_line(ctx, annot)) {
        fz_point a;
        fz_point b;
        pdf_annot_line(ctx, annot, &a, &b);
        bounds = fz_include_point_in_rect(bounds, a);
        bounds = fz_include_point_in_rect(bounds, b);
        if (!fz_is_empty_rect(bounds)) return fz_expand_rect(bounds, 2);
    }

    return pdf_bound_annot(ctx, annot);
}

int spdf_load_comments(spdf_document* doc, spdf_comments* out, char* err, size_t err_len) {
    pdf_document* pdf = NULL;
    pdf_page* page = NULL;
    comment_builder builder;
    int i;

    set_error(err, err_len, "");
    if (!out) {
        set_error(err, err_len, "No comments output was supplied.");
        return 0;
    }
    memset(out, 0, sizeof(*out));
    memset(&builder, 0, sizeof(builder));
    if (!doc) return 0;

    fz_try(doc->ctx) {
        pdf = pdf_specifics(doc->ctx, doc->doc);
        if (pdf) {
            for (i = 0; i < doc->page_count; ++i) {
                pdf_annot* annot;
                pdf_obj* annots;
                page = pdf_load_page(doc->ctx, pdf, i);
                annots = pdf_dict_get(doc->ctx, page->obj, PDF_NAME(Annots));
                for (annot = pdf_first_annot(doc->ctx, page); annot; annot = pdf_next_annot(doc->ctx, annot)) {
                    pdf_obj* obj = pdf_annot_obj(doc->ctx, annot);
                    pdf_obj* popup = pdf_dict_get(doc->ctx, obj, PDF_NAME(Popup));
                    enum pdf_annot_type annot_type = pdf_annot_type(doc->ctx, annot);
                    const char* contents = pdf_annot_contents(doc->ctx, annot);
                    const char* author;
                    const char* type = pdf_string_from_annot_type(doc->ctx, annot_type);
                    fz_rect bounds;
                    if (!popup) popup = popup_for_parent(doc->ctx, annots, obj);
                    if (!contents || !*contents) contents = dict_text_or_empty(doc->ctx, popup, PDF_NAME(Contents));
                    author = comment_author_or_empty(doc->ctx, obj, popup);
                    if (!comment_annotation_should_surface(contents, author, annot_type)) continue;
                    bounds = annot_bounds(doc->ctx, annot);
                    if (!append_comment_item(&builder, author, contents, type, builder.count, i, bounds))
                        fz_throw(doc->ctx, FZ_ERROR_SYSTEM, "Out of memory");
                }
                pdf_drop_page(doc->ctx, page);
                page = NULL;
            }
        }
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        if (page) pdf_drop_page(doc->ctx, page);
        out->items = builder.items;
        out->count = builder.count;
        spdf_free_comments(out);
        return 0;
    }

    out->items = builder.items;
    out->count = builder.count;
    return 1;
}

void spdf_free_comments(spdf_comments* comments) {
    int i;

    if (!comments) return;
    for (i = 0; i < comments->count; ++i) {
        free(comments->items[i].author);
        free(comments->items[i].text);
        free(comments->items[i].type);
    }
    free(comments->items);
    memset(comments, 0, sizeof(*comments));
}

static int point_in_rect(float x, float y, fz_rect rect) {
    float x0 = rect.x0 < rect.x1 ? rect.x0 : rect.x1;
    float x1 = rect.x0 < rect.x1 ? rect.x1 : rect.x0;
    float y0 = rect.y0 < rect.y1 ? rect.y0 : rect.y1;
    float y1 = rect.y0 < rect.y1 ? rect.y1 : rect.y0;
    return x >= x0 && x <= x1 && y >= y0 && y <= y1;
}

static int ascii_starts_with_case(const char* text, const char* prefix) {
    while (*prefix) {
        unsigned char a = (unsigned char)*text++;
        unsigned char b = (unsigned char)*prefix++;
        if (tolower(a) != tolower(b)) return 0;
    }
    return 1;
}

static int link_char_can_continue(char c) {
    if ((unsigned char)c <= 32) return 0;
    return strchr("<>\"'[]{}", c) == NULL;
}

static int link_trailing_punctuation(char c) {
    return c == '.' || c == ',' || c == ':' || c == ';' || c == '!' || c == '?' || c == ')' || c == ']';
}

static int line_link_prefix_length(const char* text) {
    if (ascii_starts_with_case(text, "http://")) return 7;
    if (ascii_starts_with_case(text, "https://")) return 8;
    if (ascii_starts_with_case(text, "mailto:")) return 7;
    if (ascii_starts_with_case(text, "ftp://")) return 6;
    if (ascii_starts_with_case(text, "file:")) return 5;
    if (ascii_starts_with_case(text, "www.")) return 4;
    return 0;
}

static char* copy_text_link_uri(const char* text, int start, int end) {
    int add_https = ascii_starts_with_case(text + start, "www.");
    size_t prefix_len = add_https ? strlen("https://") : 0;
    size_t link_len = (size_t)(end - start);
    char* uri = (char*)malloc(prefix_len + link_len + 1);

    if (!uri) return NULL;
    if (add_https) memcpy(uri, "https://", prefix_len);
    memcpy(uri + prefix_len, text + start, link_len);
    uri[prefix_len + link_len] = '\0';
    return uri;
}

static int text_line_link_at_point(fz_stext_line* line, float x, float y, spdf_link_target* out) {
    char text[2048];
    fz_rect rects[2048];
    int count = 0;
    int i;

    for (fz_stext_char* ch = line->first_char; ch && count < (int)(sizeof(text) - 1); ch = ch->next) {
        text[count] = ch->c > 0 && ch->c < 128 ? (char)ch->c : ' ';
        rects[count] = fz_rect_from_quad(ch->quad);
        count++;
    }
    text[count] = '\0';

    for (i = 0; i < count; ++i) {
        int end;
        int j;
        fz_rect link_rect = fz_empty_rect;
        int has_rect = 0;

        if (!line_link_prefix_length(text + i)) continue;
        end = i;
        while (end < count && link_char_can_continue(text[end])) end++;
        while (end > i && link_trailing_punctuation(text[end - 1])) end--;
        if (end <= i) continue;

        for (j = i; j < end; ++j) {
            if (fz_is_empty_rect(rects[j])) continue;
            link_rect = has_rect ? fz_union_rect(link_rect, rects[j]) : rects[j];
            has_rect = 1;
        }
        if (has_rect && point_in_rect(x, y, fz_expand_rect(link_rect, 2.0f))) {
            out->kind = SPDF_LINK_URI;
            out->uri = copy_text_link_uri(text, i, end);
            if (!out->uri) return -1;
            return 1;
        }
        i = end;
    }

    return 0;
}

static int text_link_at_point(spdf_document* doc, int page_index, float x, float y, spdf_link_target* out) {
    fz_stext_page* text = NULL;
    int result = 0;

    fz_var(text);
    fz_try(doc->ctx) {
        text = fz_new_stext_page_from_page_number(doc->ctx, doc->doc, page_index, NULL);
        for (fz_stext_block* block = text ? text->first_block : NULL; block && result == 0; block = block->next) {
            if (block->type == FZ_STEXT_BLOCK_TEXT) {
                for (fz_stext_line* line = block->u.t.first_line; line && result == 0; line = line->next)
                    result = text_line_link_at_point(line, x, y, out);
            }
        }
        if (text) fz_drop_stext_page(doc->ctx, text);
        text = NULL;
    }
    fz_catch(doc->ctx) {
        if (text) fz_drop_stext_page(doc->ctx, text);
        fz_rethrow(doc->ctx);
    }

    return result;
}

int spdf_link_at_point(spdf_document* doc, int page_index, float x, float y, spdf_link_target* out,
                       int detect_text_links, char* err, size_t err_len) {
    fz_page* page = NULL;
    fz_link* links = NULL;
    fz_link* link;

    set_error(err, err_len, "");
    if (!out) {
        set_error(err, err_len, "No link output was supplied.");
        return 0;
    }
    memset(out, 0, sizeof(*out));
    out->page_index = -1;
    out->zoom = 0.0f;

    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        set_error(err, err_len, "Page index is out of range.");
        return -1;
    }

    fz_try(doc->ctx) {
        page = fz_load_page(doc->ctx, doc->doc, page_index);
        links = fz_load_links(doc->ctx, page);
        for (link = links; link; link = link->next) {
            if (!point_in_rect(x, y, link->rect)) continue;

            if (link->uri && fz_is_external_link(doc->ctx, link->uri)) {
                out->kind = SPDF_LINK_URI;
                out->uri = copy_string(link->uri);
                if (!out->uri) fz_throw(doc->ctx, FZ_ERROR_SYSTEM, "Out of memory");
            } else if (link->uri && *link->uri) {
                float target_x = 0.0f;
                float target_y = 0.0f;
                fz_location loc = fz_resolve_link(doc->ctx, doc->doc, link->uri, &target_x, &target_y);
                int target_page = loc.page >= 0 ? fz_page_number_from_location(doc->ctx, doc->doc, loc) : -1;
                if (target_page >= 0) {
                    out->kind = SPDF_LINK_INTERNAL;
                    out->page_index = target_page;
                    out->x = target_x;
                    out->y = target_y;
                } else {
                    out->kind = SPDF_LINK_URI;
                    out->uri = copy_string(link->uri);
                    if (!out->uri) fz_throw(doc->ctx, FZ_ERROR_SYSTEM, "Out of memory");
                }
            }
            break;
        }
        if (links) fz_drop_link(doc->ctx, links);
        links = NULL;
        fz_drop_page(doc->ctx, page);
        page = NULL;
        if (detect_text_links && out->kind == SPDF_LINK_NONE && text_link_at_point(doc, page_index, x, y, out) < 0)
            fz_throw(doc->ctx, FZ_ERROR_SYSTEM, "Out of memory");
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        if (links) fz_drop_link(doc->ctx, links);
        if (page) fz_drop_page(doc->ctx, page);
        spdf_free_link_target(out);
        return -1;
    }

    return out->kind != SPDF_LINK_NONE;
}

void spdf_free_link_target(spdf_link_target* target) {
    if (!target) return;
    free(target->uri);
    memset(target, 0, sizeof(*target));
}

/* Append the union rect of every plain-text URL run in the line (same run
 * detection as text_line_link_at_point, minus the point test). Returns the
 * new total; runs beyond rect_max are dropped. */
static int text_line_collect_link_rects(fz_stext_line* line, spdf_rect* rects, int rect_max, int count_so_far) {
    char text[2048];
    fz_rect char_rects[2048];
    int count = 0;
    int total = count_so_far;
    int i;

    for (fz_stext_char* ch = line->first_char; ch && count < (int)(sizeof(text) - 1); ch = ch->next) {
        text[count] = ch->c > 0 && ch->c < 128 ? (char)ch->c : ' ';
        char_rects[count] = fz_rect_from_quad(ch->quad);
        count++;
    }
    text[count] = '\0';

    for (i = 0; i < count; ++i) {
        int end;
        int j;
        fz_rect link_rect = fz_empty_rect;
        int has_rect = 0;

        if (!line_link_prefix_length(text + i)) continue;
        end = i;
        while (end < count && link_char_can_continue(text[end])) end++;
        while (end > i && link_trailing_punctuation(text[end - 1])) end--;
        if (end <= i) continue;

        for (j = i; j < end; ++j) {
            if (fz_is_empty_rect(char_rects[j])) continue;
            link_rect = has_rect ? fz_union_rect(link_rect, char_rects[j]) : char_rects[j];
            has_rect = 1;
        }
        if (has_rect && total < rect_max) {
            rects[total].x0 = link_rect.x0;
            rects[total].y0 = link_rect.y0;
            rects[total].x1 = link_rect.x1;
            rects[total].y1 = link_rect.y1;
            total++;
        }
        i = end;
    }

    return total;
}

int spdf_page_link_rects(spdf_document* doc, int page_index, int detect_text_links, spdf_rect* rects, int rect_max,
                         char* err, size_t err_len) {
    fz_page* page = NULL;
    fz_link* links = NULL;
    fz_link* link;
    fz_stext_page* text = NULL;
    int count = 0;

    set_error(err, err_len, "");
    if (!rects || rect_max <= 0) {
        set_error(err, err_len, "No rectangle output was supplied.");
        return -1;
    }
    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        set_error(err, err_len, "Page index is out of range.");
        return -1;
    }

    fz_var(page);
    fz_var(links);
    fz_var(text);
    fz_try(doc->ctx) {
        page = fz_load_page(doc->ctx, doc->doc, page_index);
        links = fz_load_links(doc->ctx, page);
        /* Any link annotation with a URI is clickable: spdf_link_at_point
         * follows external URIs directly and treats unresolvable internal
         * ones as URIs, so nothing with a non-empty URI is a dead target. */
        for (link = links; link && count < rect_max; link = link->next) {
            if (!link->uri || !*link->uri) continue;
            rects[count].x0 = link->rect.x0;
            rects[count].y0 = link->rect.y0;
            rects[count].x1 = link->rect.x1;
            rects[count].y1 = link->rect.y1;
            count++;
        }
        if (links) fz_drop_link(doc->ctx, links);
        links = NULL;
        fz_drop_page(doc->ctx, page);
        page = NULL;
        if (detect_text_links && count < rect_max) {
            /* Same stext walk as text_link_at_point (top-level text blocks,
             * default options) so hover rects match what a click resolves. */
            text = fz_new_stext_page_from_page_number(doc->ctx, doc->doc, page_index, NULL);
            for (fz_stext_block* block = text ? text->first_block : NULL; block; block = block->next) {
                if (block->type != FZ_STEXT_BLOCK_TEXT) continue;
                for (fz_stext_line* line = block->u.t.first_line; line; line = line->next)
                    count = text_line_collect_link_rects(line, rects, rect_max, count);
            }
            fz_drop_stext_page(doc->ctx, text);
            text = NULL;
        }
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        if (links) fz_drop_link(doc->ctx, links);
        if (page) fz_drop_page(doc->ctx, page);
        if (text) fz_drop_stext_page(doc->ctx, text);
        return -1;
    }

    return count;
}

static fz_rect rect_from_spdf_rect(spdf_rect rect) {
    fz_rect out;
    out.x0 = rect.x0 < rect.x1 ? rect.x0 : rect.x1;
    out.x1 = rect.x0 < rect.x1 ? rect.x1 : rect.x0;
    out.y0 = rect.y0 < rect.y1 ? rect.y0 : rect.y1;
    out.y1 = rect.y0 < rect.y1 ? rect.y1 : rect.y0;
    return out;
}

int spdf_add_highlight_comment(spdf_document* doc, int page_index, const spdf_rect* rects, int rect_count,
                               const char* text, const char* author, char* err, size_t err_len) {
    pdf_document* pdf = NULL;
    pdf_page* page = NULL;
    pdf_annot* annot = NULL;
    fz_quad* quads = NULL;
    fz_rect bounds = fz_empty_rect;
    const float yellow[3] = {1.0f, 0.86f, 0.08f};
    int i;

    set_error(err, err_len, "");
    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        set_error(err, err_len, "Page index is out of range.");
        return 0;
    }
    if (!rects || rect_count <= 0) {
        set_error(err, err_len, "No selected text was supplied.");
        return 0;
    }

    fz_try(doc->ctx) {
        pdf = pdf_specifics(doc->ctx, doc->doc);
        if (!pdf) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Comments can only be added to PDF files.");
        page = pdf_load_page(doc->ctx, pdf, page_index);
        quads = (fz_quad*)fz_calloc(doc->ctx, (size_t)rect_count, sizeof(fz_quad));
        for (i = 0; i < rect_count; ++i) {
            fz_rect r = rect_from_spdf_rect(rects[i]);
            if (fz_is_empty_rect(r)) continue;
            quads[i] = fz_quad_from_rect(r);
            bounds = fz_is_empty_rect(bounds) ? r : fz_union_rect(bounds, r);
        }
        if (fz_is_empty_rect(bounds)) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "No selected text was supplied.");

        annot = pdf_create_annot(doc->ctx, page, PDF_ANNOT_HIGHLIGHT);
        pdf_set_annot_quad_points(doc->ctx, annot, rect_count, quads);
        pdf_set_annot_color(doc->ctx, annot, 3, yellow);
        pdf_set_annot_opacity(doc->ctx, annot, 0.35f);
        if (text && *text) pdf_set_annot_contents(doc->ctx, annot, text);
        if (author && *author) pdf_set_annot_author(doc->ctx, annot, author);
        pdf_update_annot(doc->ctx, annot);
        fz_free(doc->ctx, quads);
        quads = NULL;
        pdf_drop_page(doc->ctx, page);
        page = NULL;
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        if (quads) fz_free(doc->ctx, quads);
        if (page) pdf_drop_page(doc->ctx, page);
        spdf_drop_page_list_cache(doc, page_index);
        return 0;
    }

    spdf_drop_page_list_cache(doc, page_index);
    return 1;
}

int spdf_add_text_comment(spdf_document* doc, int page_index, float x, float y, const char* text, const char* author,
                          char* err, size_t err_len) {
    pdf_document* pdf = NULL;
    pdf_page* page = NULL;
    pdf_annot* annot = NULL;
    const float yellow[3] = {1.0f, 0.86f, 0.08f};

    set_error(err, err_len, "");
    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        set_error(err, err_len, "Page index is out of range.");
        return 0;
    }

    fz_try(doc->ctx) {
        pdf = pdf_specifics(doc->ctx, doc->doc);
        if (!pdf) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Comments can only be added to PDF files.");
        page = pdf_load_page(doc->ctx, pdf, page_index);
        annot = pdf_create_annot(doc->ctx, page, PDF_ANNOT_TEXT);
        pdf_set_annot_rect(doc->ctx, annot, fz_make_rect(x, y, x + 24.0f, y + 24.0f));
        pdf_set_annot_color(doc->ctx, annot, 3, yellow);
        if (text && *text) pdf_set_annot_contents(doc->ctx, annot, text);
        if (author && *author) pdf_set_annot_author(doc->ctx, annot, author);
        pdf_update_annot(doc->ctx, annot);
        pdf_drop_page(doc->ctx, page);
        page = NULL;
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        if (page) pdf_drop_page(doc->ctx, page);
        spdf_drop_page_list_cache(doc, page_index);
        return 0;
    }

    spdf_drop_page_list_cache(doc, page_index);
    return 1;
}

static void set_comment_text_and_author(fz_context* ctx, pdf_annot* annot, pdf_obj* popup, const char* text,
                                        const char* author);

int spdf_update_comment(spdf_document* doc, int comment_index, const char* text, const char* author, char* err,
                        size_t err_len) {
    pdf_document* pdf = NULL;
    pdf_page* page = NULL;
    int visible_index = 0;
    int found = 0;
    int i;

    set_error(err, err_len, "");
    if (!doc || comment_index < 0) {
        set_error(err, err_len, "Comment index is out of range.");
        return 0;
    }

    fz_try(doc->ctx) {
        pdf = pdf_specifics(doc->ctx, doc->doc);
        if (!pdf) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Comments can only be edited in PDF files.");
        for (i = 0; i < doc->page_count && !found; ++i) {
            pdf_annot* annot;
            pdf_obj* annots;
            page = pdf_load_page(doc->ctx, pdf, i);
            annots = pdf_dict_get(doc->ctx, page->obj, PDF_NAME(Annots));
            for (annot = pdf_first_annot(doc->ctx, page); annot; annot = pdf_next_annot(doc->ctx, annot)) {
                pdf_obj* obj = pdf_annot_obj(doc->ctx, annot);
                pdf_obj* popup = pdf_dict_get(doc->ctx, obj, PDF_NAME(Popup));
                enum pdf_annot_type annot_type = pdf_annot_type(doc->ctx, annot);
                const char* contents = pdf_annot_contents(doc->ctx, annot);
                const char* current_author;
                if (!popup) popup = popup_for_parent(doc->ctx, annots, obj);
                if (!contents || !*contents) contents = dict_text_or_empty(doc->ctx, popup, PDF_NAME(Contents));
                current_author = comment_author_or_empty(doc->ctx, obj, popup);
                if (!comment_annotation_should_surface(contents, current_author, annot_type)) continue;

                if (visible_index == comment_index) {
                    set_comment_text_and_author(doc->ctx, annot, popup, text, author);
                    found = 1;
                    break;
                }
                visible_index++;
            }
            pdf_drop_page(doc->ctx, page);
            page = NULL;
        }
        if (!found) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Comment was not found.");
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        if (page) pdf_drop_page(doc->ctx, page);
        spdf_drop_page_list_cache(doc, -1); /* page of the edited comment is not directly known */
        return 0;
    }

    spdf_drop_page_list_cache(doc, -1); /* page of the edited comment is not directly known */
    return 1;
}

int spdf_delete_comment(spdf_document* doc, int comment_index, char* err, size_t err_len) {
    pdf_document* pdf = NULL;
    pdf_page* page = NULL;
    int visible_index = 0;
    int found = 0;
    int i;

    set_error(err, err_len, "");
    if (!doc || comment_index < 0) {
        set_error(err, err_len, "Comment index is out of range.");
        return 0;
    }

    fz_try(doc->ctx) {
        pdf = pdf_specifics(doc->ctx, doc->doc);
        if (!pdf) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Comments can only be deleted in PDF files.");
        for (i = 0; i < doc->page_count && !found; ++i) {
            pdf_annot* annot;
            pdf_obj* annots;
            page = pdf_load_page(doc->ctx, pdf, i);
            annots = pdf_dict_get(doc->ctx, page->obj, PDF_NAME(Annots));
            for (annot = pdf_first_annot(doc->ctx, page); annot; annot = pdf_next_annot(doc->ctx, annot)) {
                pdf_obj* obj = pdf_annot_obj(doc->ctx, annot);
                pdf_obj* popup = pdf_dict_get(doc->ctx, obj, PDF_NAME(Popup));
                enum pdf_annot_type annot_type = pdf_annot_type(doc->ctx, annot);
                const char* contents = pdf_annot_contents(doc->ctx, annot);
                const char* current_author;
                if (!popup) popup = popup_for_parent(doc->ctx, annots, obj);
                if (!contents || !*contents) contents = dict_text_or_empty(doc->ctx, popup, PDF_NAME(Contents));
                current_author = comment_author_or_empty(doc->ctx, obj, popup);
                if (!comment_annotation_should_surface(contents, current_author, annot_type)) continue;

                if (visible_index == comment_index) {
                    remove_popups_for_parent(doc->ctx, annots, obj);
                    pdf_delete_annot(doc->ctx, page, annot);
                    found = 1;
                    break;
                }
                visible_index++;
            }
            pdf_drop_page(doc->ctx, page);
            page = NULL;
        }
        if (!found) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Comment was not found.");
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        if (page) pdf_drop_page(doc->ctx, page);
        spdf_drop_page_list_cache(doc, -1); /* page of the deleted comment is not directly known */
        return 0;
    }

    spdf_drop_page_list_cache(doc, -1); /* page of the deleted comment is not directly known */
    return 1;
}

static void set_comment_text_and_author(fz_context* ctx, pdf_annot* annot, pdf_obj* popup, const char* text,
                                        const char* author) {
    pdf_obj* obj = pdf_annot_obj(ctx, annot);

    if (!text) text = "";
    if (!author) author = "";

    pdf_dict_put_text_string(ctx, obj, PDF_NAME(Contents), text);
    pdf_dict_del(ctx, obj, PDF_NAME(RC));
    pdf_dict_put_text_string(ctx, obj, PDF_NAME(T), author);
    if (popup) {
        pdf_dict_put_text_string(ctx, popup, PDF_NAME(Contents), text);
        pdf_dict_del(ctx, popup, PDF_NAME(RC));
        pdf_dict_put_text_string(ctx, popup, PDF_NAME(T), author);
    }
    pdf_dirty_annot(ctx, annot);
    pdf_update_annot(ctx, annot);
}

static int normalize_page_rotation(int degrees) {
    int normalized = degrees % 360;
    int quarter;

    if (normalized < 0) normalized += 360;
    quarter = (normalized + 45) / 90;
    return (quarter % 4) * 90;
}

int spdf_rotate_page(spdf_document* doc, int page_index, int degrees, char* err, size_t err_len) {
    pdf_document* pdf = NULL;
    pdf_obj* page_obj = NULL;

    set_error(err, err_len, "");
    if (!doc || page_index < 0 || page_index >= doc->page_count) {
        set_error(err, err_len, "Page index is out of range.");
        return 0;
    }

    fz_try(doc->ctx) {
        int current_rotation;
        int next_rotation;

        pdf = pdf_specifics(doc->ctx, doc->doc);
        if (!pdf) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Only PDF pages can be rotated and saved.");

        page_obj = pdf_lookup_page_obj(doc->ctx, pdf, page_index);
        if (!page_obj) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Could not find the PDF page object.");

        current_rotation = normalize_page_rotation(pdf_dict_get_inheritable_int(doc->ctx, page_obj, PDF_NAME(Rotate)));
        next_rotation = normalize_page_rotation(current_rotation + degrees);
        pdf_dict_put_int(doc->ctx, page_obj, PDF_NAME(Rotate), next_rotation);
        pdf_dirty_obj(doc->ctx, page_obj);
        if (doc->page_sizes) doc->page_sizes[page_index].valid = 0;
        spdf_drop_page_list_cache(doc, page_index);
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        spdf_drop_page_list_cache(doc, page_index);
        return 0;
    }

    return 1;
}

/* Sanitize-filter text callback: a non-zero return removes the character. We
 * remove every one, dropping the whole text layer. */
static int spdf_delete_all_text_filter(fz_context* ctx, void* opaque, int* ucsbuf, int ucslen, fz_matrix trm,
                                       fz_matrix ctm, fz_rect bbox, int tr, float ca, float CA) {
    (void)ctx;
    (void)opaque;
    (void)ucsbuf;
    (void)ucslen;
    (void)trm;
    (void)ctm;
    (void)bbox;
    (void)tr;
    (void)ca;
    (void)CA;
    return 1;
}

static char* create_temp_save_path(fz_context* ctx, const char* path);

int spdf_delete_all_text(spdf_document* doc, const char* path, char* err, size_t err_len) {
    pdf_document* pdf = NULL;
    pdf_page* page = NULL;
    pdf_write_options options;
    char* temp_path = NULL;
    int i;
    int page_count;

    set_error(err, err_len, "");
    if (!doc || !path || !*path) {
        set_error(err, err_len, "No document path was supplied.");
        return 0;
    }

    fz_var(page);
    fz_var(temp_path);
    fz_try(doc->ctx) {
        pdf = pdf_specifics(doc->ctx, doc->doc);
        if (!pdf) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Only PDF documents can have their text removed.");
        page_count = doc->page_count;
        for (i = 0; i < page_count; ++i) {
            pdf_filter_options filter_opts;
            pdf_sanitize_filter_options sanitize_opts;
            pdf_filter_factory filter_list[2];

            page = pdf_load_page(doc->ctx, pdf, i);

            memset(&filter_opts, 0, sizeof filter_opts);
            memset(&sanitize_opts, 0, sizeof sanitize_opts);
            memset(filter_list, 0, sizeof filter_list);
            filter_opts.instance_forms = 1; /* expand form xobjects so their text is filtered too */
            filter_opts.ascii = 1;
            filter_opts.filters = filter_list;
            sanitize_opts.text_filter = spdf_delete_all_text_filter;
            filter_list[0].filter = pdf_new_sanitize_filter;
            filter_list[0].options = &sanitize_opts;

            pdf_filter_page_contents(doc->ctx, pdf, page, &filter_opts);

            pdf_drop_page(doc->ctx, page);
            page = NULL;
        }

        /* Full (non-incremental) rewrite with garbage collection so the old,
         * now-unreferenced text content streams are actually dropped from the
         * file rather than left behind as orphans. */
        options = pdf_default_write_options;
        options.do_garbage = 2;
        options.do_compress = 1;
        options.do_compress_images = 1;
        options.do_compress_fonts = 1;
        temp_path = create_temp_save_path(doc->ctx, path);
        pdf_save_document(doc->ctx, pdf, temp_path, &options);
        spdf_drop_page_list_cache(doc, -1);
    }
    fz_always(doc->ctx) {
        if (page) pdf_drop_page(doc->ctx, page);
        page = NULL;
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        if (temp_path) {
            remove(temp_path);
            free(temp_path);
        }
        return 0;
    }

    if (temp_path) {
        if (spdf_compat_replace_file(temp_path, path) != 0) {
            set_error(err, err_len, "Could not replace the original PDF after removing text.");
            remove(temp_path);
            free(temp_path);
            return 0;
        }
        free(temp_path);
    }
    return 1;
}

/* The temp file must land in the document's own directory, because the save ends
 * in an atomic replace and that exists only within one volume. Splitting on '/'
 * alone found none in a Windows path, so dir_len was 0 and this wrote the CWD. */
static char* create_temp_save_path(fz_context* ctx, const char* path) {
    static const char temp_name[] = ".shenzhenpdf-save-XXXXXX";
    size_t dir_len = spdf_compat_path_dir_len(path);
    size_t temp_name_len = strlen(temp_name);
    char* temp_path;
    int fd;

    if (dir_len > ((size_t)-1) - temp_name_len - 1) fz_throw(ctx, FZ_ERROR_SYSTEM, "Temporary save path is too long");

    temp_path = (char*)malloc(dir_len + temp_name_len + 1);
    if (!temp_path) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
    if (dir_len) memcpy(temp_path, path, dir_len);
    memcpy(temp_path + dir_len, temp_name, temp_name_len + 1);

    fd = spdf_compat_mkstemp(temp_path);
    if (fd < 0) {
        int saved_errno = errno;
        free(temp_path);
        fz_throw(ctx, FZ_ERROR_SYSTEM, "Could not create a temporary save file: %s", strerror(saved_errno));
    }
    if (spdf_compat_close(fd) != 0) {
        int saved_errno = errno;
        remove(temp_path);
        free(temp_path);
        fz_throw(ctx, FZ_ERROR_SYSTEM, "Could not close a temporary save file: %s", strerror(saved_errno));
    }

    return temp_path;
}

int spdf_save_document(spdf_document* doc, const char* path, char* err, size_t err_len) {
    pdf_document* pdf = NULL;
    pdf_write_options options;
    char* temp_path = NULL;
    const char* save_path;
    int incremental;

    set_error(err, err_len, "");
    if (!doc || !path || !*path) {
        set_error(err, err_len, "No document path was supplied.");
        return 0;
    }

    fz_var(temp_path);
    fz_try(doc->ctx) {
        pdf = pdf_specifics(doc->ctx, doc->doc);
        if (!pdf) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Only PDF documents can be saved.");
        options = pdf_default_write_options;
        incremental = pdf_can_be_saved_incrementally(doc->ctx, pdf);
        options.do_incremental = incremental;
        options.do_compress = 1;
        options.do_compress_images = 1;
        options.do_compress_fonts = 1;
        save_path = path;
        if (!incremental) {
            temp_path = create_temp_save_path(doc->ctx, path);
            save_path = temp_path;
        }
        pdf_save_document(doc->ctx, pdf, save_path, &options);
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        if (temp_path) {
            remove(temp_path);
            free(temp_path);
        }
        return 0;
    }

    if (temp_path) {
        if (spdf_compat_replace_file(temp_path, path) != 0) {
            set_error(err, err_len, "Could not replace the original PDF after saving.");
            remove(temp_path);
            free(temp_path);
            return 0;
        }
        free(temp_path);
    }
    return 1;
}

/* Tolerant UTF-8 scan shared by the script detectors: decodes the next code
 * point, skipping stray continuation bytes, invalid lead bytes and truncated
 * sequences. Returns 0 at the end of the string. */
static unsigned utf8_next_rune(const unsigned char** cursor) {
    const unsigned char* s = *cursor;

    while (*s) {
        unsigned rune;
        int extra;
        int i;
        unsigned char c = *s++;

        if (c < 0x80) {
            *cursor = s;
            return c;
        }
        if ((c & 0xE0) == 0xC0) {
            rune = c & 0x1Fu;
            extra = 1;
        } else if ((c & 0xF0) == 0xE0) {
            rune = c & 0x0Fu;
            extra = 2;
        } else if ((c & 0xF8) == 0xF0) {
            rune = c & 0x07u;
            extra = 3;
        } else {
            continue; /* stray continuation or invalid lead byte */
        }
        for (i = 0; i < extra; ++i) {
            if ((s[i] & 0xC0) != 0x80) break; /* also stops at NUL */
            rune = (rune << 6) | (s[i] & 0x3Fu);
        }
        s += i;
        if (i < extra) continue; /* truncated/malformed sequence */
        if (rune == 0) continue; /* overlong-encoded NUL */
        *cursor = s;
        return rune;
    }
    *cursor = s;
    return 0;
}

int spdf_text_contains_han(const char* utf8) {
    const unsigned char* s = (const unsigned char*)utf8;
    unsigned rune;

    if (!s) return 0;
    while ((rune = utf8_next_rune(&s)) != 0) {
        if ((rune >= 0x4E00 && rune <= 0x9FFF) || (rune >= 0x3400 && rune <= 0x4DBF) ||
            (rune >= 0xF900 && rune <= 0xFAFF) || (rune >= 0x20000 && rune <= 0x2FA1F)) {
            return 1;
        }
    }
    return 0;
}

int spdf_text_contains_latin(const char* utf8) {
    const unsigned char* s = (const unsigned char*)utf8;
    unsigned rune;

    if (!s) return 0;
    while ((rune = utf8_next_rune(&s)) != 0) {
        if ((rune >= 'A' && rune <= 'Z') || (rune >= 'a' && rune <= 'z')) return 1;
        /* Latin-1 letters (multiplication/division signs excluded), Latin
         * Extended-A/B, and Latin Extended Additional (Vietnamese). */
        if (rune >= 0x00C0 && rune <= 0x024F && rune != 0x00D7 && rune != 0x00F7) return 1;
        if (rune >= 0x1E00 && rune <= 0x1EFF) return 1;
    }
    return 0;
}

spdf_translation_script spdf_translation_script_for_language(const char* code) {
    /* Argos-supported languages written in Latin script. */
    static const char* const latin_codes[] = {"az", "ca", "cs", "da", "de", "en", "eo", "es", "et", "eu", "fi", "fr",
                                              "ga", "gl", "hr", "hu", "id", "it", "lt", "lv", "ms", "nb", "nl", "no",
                                              "pl", "pt", "ro", "sk", "sl", "sq", "sv", "tl", "tr", "vi"};
    /* Recognized languages whose script the detectors cannot classify. */
    static const char* const other_codes[] = {"ar", "be", "bg", "bn", "el", "fa", "he", "hi", "ja", "ka", "kk", "km",
                                              "ko", "ky", "mk", "mn", "my", "ru", "sr", "ta", "te", "th", "uk", "ur"};
    char primary[4];
    size_t len = 0;
    size_t i;

    if (!code) return SPDF_TRANSLATION_SCRIPT_UNKNOWN;
    while (len < 3 && code[len]) {
        char c = code[len];
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        if (c < 'a' || c > 'z') break;
        primary[len++] = c;
    }
    primary[len] = 0;
    /* The primary subtag must stand alone or be followed by a region/script
     * separator ("zh-TW", "pt_BR"); anything else is not a language code. */
    if (len < 2 || (code[len] && code[len] != '-' && code[len] != '_')) return SPDF_TRANSLATION_SCRIPT_UNKNOWN;

    if (strcmp(primary, "zh") == 0 || strcmp(primary, "zt") == 0) return SPDF_TRANSLATION_SCRIPT_HAN;
    for (i = 0; i < sizeof(latin_codes) / sizeof(latin_codes[0]); ++i)
        if (strcmp(primary, latin_codes[i]) == 0) return SPDF_TRANSLATION_SCRIPT_LATIN;
    for (i = 0; i < sizeof(other_codes) / sizeof(other_codes[0]); ++i)
        if (strcmp(primary, other_codes[i]) == 0) return SPDF_TRANSLATION_SCRIPT_OTHER;
    return SPDF_TRANSLATION_SCRIPT_UNKNOWN;
}

int spdf_translation_should_translate(const char* utf8, spdf_translation_script source_script,
                                      spdf_translation_script target_script) {
    int has_han;

    if (!utf8 || !*utf8) return 0;
    has_han = spdf_text_contains_han(utf8);
    /* An explicitly selected source language with a detectable script takes
     * precedence: keep the existing Chinese-source behavior (translate only
     * items containing Han text) and mirror it for Latin-script sources. */
    if (source_script == SPDF_TRANSLATION_SCRIPT_HAN) return has_han;
    if (source_script == SPDF_TRANSLATION_SCRIPT_LATIN) return spdf_text_contains_latin(utf8) && !has_han;
    /* Known source in a script the detectors cannot classify (Cyrillic,
     * Japanese, Arabic...): never filter, translate everything as before. */
    if (source_script == SPDF_TRANSLATION_SCRIPT_OTHER) return 1;
    /* Source unknown: decide by script vs. the target language. */
    if (target_script == SPDF_TRANSLATION_SCRIPT_HAN) return spdf_text_contains_latin(utf8) && !has_han;
    if (target_script == SPDF_TRANSLATION_SCRIPT_LATIN) return has_han;
    return 1;
}

static fz_rect normalized_public_rect(const spdf_rect* rect) {
    float x0 = rect->x0 < rect->x1 ? rect->x0 : rect->x1;
    float x1 = rect->x0 < rect->x1 ? rect->x1 : rect->x0;
    float y0 = rect->y0 < rect->y1 ? rect->y0 : rect->y1;
    float y1 = rect->y0 < rect->y1 ? rect->y1 : rect->y0;
    return fz_make_rect(x0, y0, x1, y1);
}

/* 1 = CJK script (mupdf sets these in a full-width CJK fallback font),
 * 0 = other strong script, -1 = common/neutral (digits, punctuation, spaces)
 * which inherits the surrounding script, mirroring mupdf's text walker in
 * pdf-appearance.c. */
static int rune_script_class(int rune) {
    if ((rune >= 0x2E80 && rune <= 0x2FDF) || (rune >= 0x3040 && rune <= 0x31FF) ||
        (rune >= 0x3400 && rune <= 0x4DBF) || (rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0xA000 && rune <= 0xA4CF) || (rune >= 0xAC00 && rune <= 0xD7AF) ||
        (rune >= 0xF900 && rune <= 0xFAFF) || (rune >= 0x1100 && rune <= 0x11FF) ||
        (rune >= 0x20000 && rune <= 0x2FA1F))
        return 1;
    if ((rune >= 'A' && rune <= 'Z') || (rune >= 'a' && rune <= 'z') || (rune >= 0x00C0 && rune <= 0x024F) ||
        (rune >= 0x0370 && rune <= 0x04FF))
        return 0;
    return -1;
}

/* Estimated width of the text in ems at the size the overlay appearance will
 * use. Mirrors mupdf's measurement (pdf-appearance.c text walker): Latin text
 * is measured with real Helvetica advances, CJK glyphs are full-width (one
 * em), and neutral characters inherit the script of the surrounding text.
 * When in doubt this over-estimates, which only shrinks the text slightly --
 * an under-estimate would make mupdf wrap the line and clip it. */
static float translated_text_ems(fz_context* ctx, const char* text) {
    fz_font* font = NULL;
    float ems = 0.0f;

    if (!text || !*text) return 0.0f;
    fz_var(font);
    fz_try(ctx) {
        const char* p = text;
        int context_class = 0;

        while (*p) {
            int c;
            int cls;
            p += fz_chartorune(&c, p);
            cls = rune_script_class(c);
            if (cls >= 0) {
                context_class = cls;
                break;
            }
        }
        font = fz_new_base14_font(ctx, "Helvetica");
        p = text;
        while (*p) {
            int c;
            int cls;
            p += fz_chartorune(&c, p);
            cls = rune_script_class(c);
            if (cls >= 0) context_class = cls;
            if (cls == 1 || (cls < 0 && context_class == 1)) {
                ems += 1.0f;
            } else {
                int gid = fz_encode_character(ctx, font, c);
                if (gid > 0)
                    ems += fz_advance_glyph(ctx, font, gid, 0);
                else
                    ems += 1.0f;
            }
        }
    }
    fz_always(ctx) {
        fz_drop_font(ctx, font);
    }
    fz_catch(ctx) {
        fz_rethrow(ctx);
    }
    return ems;
}

static char* translated_text_single_line(const char* text) {
    size_t len;
    char* out;
    char* dst;
    int pending_space = 0;

    if (!text) return NULL;
    len = strlen(text);
    out = (char*)malloc(len + 1);
    if (!out) return NULL;
    dst = out;
    while (*text) {
        unsigned char ch = (unsigned char)*text;
        if (ch <= 0x20) {
            pending_space = dst != out;
            text++;
            continue;
        }
        if (pending_space) {
            *dst++ = ' ';
            pending_space = 0;
        }
        *dst++ = *text++;
    }
    *dst = 0;
    return out;
}

static float translated_line_font_size(fz_context* ctx, const spdf_translated_line* line, fz_rect rect,
                                       const char* text) {
    float size = line->font_size;
    float rect_width = rect.x1 - rect.x0;
    float rect_height = rect.y1 - rect.y0;
    float ems = translated_text_ems(ctx, text);

    if (size <= 0.0f) size = rect_height * 0.8f;
    if (rect_height > 1.0f && size > rect_height * 0.78f) size = rect_height * 0.78f;
    /* Shrink to fit the original bounding box; the box is never widened for
     * long text (that would overflow neighboring content). The 0.96 slack
     * keeps mupdf's own measurement from wrapping into a clipped second
     * line. */
    if (ems > 0.0f && rect_width > 2.0f) {
        float fit_size = (rect_width * 0.96f) / ems;
        if (fit_size > 0.0f && fit_size < size) size = fit_size;
    }
    if (size < 2.0f) size = 2.0f;
    if (size > 96.0f) size = 96.0f;
    return size;
}

static fz_rect translated_line_annotation_rect(const spdf_translated_line* line, float font_size) {
    fz_rect rect = normalized_public_rect(&line->bounds);
    float min_height = font_size * 1.15f;
    float pad = font_size * 0.10f;

    if (pad > 1.0f) pad = 1.0f;
    if (rect.x1 - rect.x0 < font_size) rect.x1 = rect.x0 + font_size;
    if (rect.y1 - rect.y0 < min_height) rect.y1 = rect.y0 + min_height;
    return fz_expand_rect(rect, pad);
}

static void append_page_content_stream(fz_context* ctx, pdf_document* pdf, pdf_obj* page_obj, fz_buffer* buf) {
    pdf_obj* contents = pdf_dict_get(ctx, page_obj, PDF_NAME(Contents));
    pdf_obj* new_contents = NULL;

    fz_var(new_contents);
    fz_try(ctx) {
        if (!pdf_is_array(ctx, contents)) {
            new_contents = pdf_new_array(ctx, pdf, 4);
            if (contents) pdf_array_push(ctx, new_contents, contents);
            pdf_dict_put(ctx, page_obj, PDF_NAME(Contents), new_contents);
            contents = new_contents;
        }
        pdf_array_push_drop(ctx, contents, pdf_add_stream(ctx, pdf, buf, NULL, 0));
    }
    fz_always(ctx) {
        pdf_drop_obj(ctx, new_contents);
    }
    fz_catch(ctx) {
        fz_rethrow(ctx);
    }
}

static pdf_obj* ensure_page_resources(fz_context* ctx, pdf_obj* page_obj) {
    pdf_obj* res = pdf_dict_get(ctx, page_obj, PDF_NAME(Resources));

    if (!res) {
        res = pdf_dict_get_inheritable(ctx, page_obj, PDF_NAME(Resources));
        if (res)
            pdf_dict_put(ctx, page_obj, PDF_NAME(Resources), res);
        else
            res = pdf_dict_put_dict(ctx, page_obj, PDF_NAME(Resources), 4);
    }
    return res;
}

/* Appended overlay streams run after the page's original content, so a page
 * whose content stream leaves the graphics state unbalanced (missing or
 * excess Q -- common in CAD-exported PDFs) would draw every overlay under a
 * stale transform, typically scaled into a corner. Mirror pdf_bake_page():
 * count the q/Q balance and wrap the original content with enough q's in
 * front and Q's at the end that appended streams start from the initial
 * page state. Must run once per page before the first overlay is appended. */
static void balance_page_contents_for_overlays(fz_context* ctx, pdf_document* pdf, pdf_obj* page_obj, pdf_obj* res) {
    pdf_obj* contents = pdf_dict_get(ctx, page_obj, PDF_NAME(Contents));
    pdf_obj* new_contents = NULL;
    pdf_obj* prologue = NULL;
    fz_buffer* buf = NULL;
    int prepend = 0;
    int append = 0;

    fz_try(ctx) {
        pdf_count_q_balance(ctx, pdf, res, contents, &prepend, &append);
    }
    fz_catch(ctx) {
        /* Content too broken to parse: keep today's behavior. */
        fz_report_error(ctx);
        return;
    }
    if (prepend <= 0 && append <= 0) return;

    fz_var(buf);
    fz_var(new_contents);
    fz_try(ctx) {
        if (!pdf_is_array(ctx, contents)) {
            new_contents = pdf_new_array(ctx, pdf, 4);
            if (contents) pdf_array_push(ctx, new_contents, contents);
            pdf_dict_put(ctx, page_obj, PDF_NAME(Contents), new_contents);
            contents = new_contents;
        }
        if (prepend > 0) {
            buf = fz_new_buffer(ctx, 64);
            while (prepend-- > 0) fz_append_string(ctx, buf, "q\n");
            prologue = pdf_add_stream(ctx, pdf, buf, NULL, 0);
            fz_drop_buffer(ctx, buf);
            buf = NULL;
            pdf_array_insert_drop(ctx, contents, prologue, 0);
            prologue = NULL;
        }
        if (append > 0) {
            buf = fz_new_buffer(ctx, 64);
            while (append-- > 0) fz_append_string(ctx, buf, "Q\n");
            pdf_array_push_drop(ctx, contents, pdf_add_stream(ctx, pdf, buf, NULL, 0));
            fz_drop_buffer(ctx, buf);
            buf = NULL;
        }
    }
    fz_always(ctx) {
        fz_drop_buffer(ctx, buf);
        pdf_drop_obj(ctx, prologue);
        pdf_drop_obj(ctx, new_contents);
    }
    fz_catch(ctx) {
        fz_rethrow(ctx);
    }
}

static fz_matrix annot_xobject_transform(fz_context* ctx, pdf_obj* annot_obj, pdf_obj* ap) {
    fz_rect rect = pdf_dict_get_rect(ctx, annot_obj, PDF_NAME(Rect));
    fz_rect bbox = pdf_dict_get_rect(ctx, ap, PDF_NAME(BBox));
    fz_matrix transform = pdf_dict_get_matrix(ctx, ap, PDF_NAME(Matrix));
    float w;
    float h;
    float x;
    float y;

    bbox = fz_transform_rect(bbox, transform);
    if (fz_is_empty_rect(rect) || fz_is_empty_rect(bbox) || bbox.x1 == bbox.x0 || bbox.y1 == bbox.y0)
        fz_throw(ctx, FZ_ERROR_FORMAT, "Annotation appearance has invalid bounds");

    w = (rect.x1 - rect.x0) / (bbox.x1 - bbox.x0);
    h = (rect.y1 - rect.y0) / (bbox.y1 - bbox.y0);
    x = rect.x0 - bbox.x0 * w;
    y = rect.y0 - bbox.y0 * h;
    return fz_make_matrix(w, 0, 0, h, x, y);
}

static void remove_page_annotation(fz_context* ctx, pdf_obj* page_obj, pdf_obj* annot_obj) {
    pdf_obj* annots = pdf_dict_get(ctx, page_obj, PDF_NAME(Annots));
    int annot_num = pdf_to_num(ctx, annot_obj);
    int i;

    for (i = 0; i < pdf_array_len(ctx, annots); ++i) {
        pdf_obj* item = pdf_array_get(ctx, annots, i);
        if (item == annot_obj || (annot_num != 0 && pdf_to_num(ctx, item) == annot_num)) {
            pdf_array_delete(ctx, annots, i);
            return;
        }
    }
}

/* Alpha of the white rectangle painted under each translated line. */
#define SPDF_TRANSLATION_BACKGROUND_ALPHA 0.95f
#define SPDF_TRANSLATION_BACKGROUND_GS "SPDFTrBG95"

static void ensure_background_extgstate(fz_context* ctx, pdf_obj* res) {
    pdf_obj* extgstates = pdf_dict_get(ctx, res, PDF_NAME(ExtGState));
    pdf_obj* gs;

    if (!extgstates) extgstates = pdf_dict_put_dict(ctx, res, PDF_NAME(ExtGState), 4);
    if (pdf_dict_gets(ctx, extgstates, SPDF_TRANSLATION_BACKGROUND_GS)) return;
    gs = pdf_dict_puts_dict(ctx, extgstates, SPDF_TRANSLATION_BACKGROUND_GS, 3);
    pdf_dict_put(ctx, gs, PDF_NAME(Type), PDF_NAME(ExtGState));
    pdf_dict_put_real(ctx, gs, PDF_NAME(ca), SPDF_TRANSLATION_BACKGROUND_ALPHA);
    pdf_dict_put_real(ctx, gs, PDF_NAME(CA), SPDF_TRANSLATION_BACKGROUND_ALPHA);
}

static void bake_overlay_annotation(fz_context* ctx, pdf_document* pdf, pdf_page* page, pdf_annot* annot,
                                    int draw_background) {
    pdf_obj* page_obj = page->obj;
    pdf_obj* annot_obj = pdf_annot_obj(ctx, annot);
    pdf_obj* ap;
    pdf_obj* res;
    pdf_obj* xobjects;
    fz_buffer* buf = NULL;
    fz_matrix matrix;
    char name[32];

    fz_var(buf);
    fz_try(ctx) {
        ap = pdf_annot_ap(ctx, annot);
        if (!ap || !pdf_is_stream(ctx, ap)) fz_throw(ctx, FZ_ERROR_FORMAT, "Could not generate translation overlay");

        res = ensure_page_resources(ctx, page_obj);
        xobjects = pdf_dict_get(ctx, res, PDF_NAME(XObject));
        if (!xobjects) xobjects = pdf_dict_put_dict(ctx, res, PDF_NAME(XObject), 8);

        snprintf(name, sizeof(name), "SPDFTr%d", pdf_to_num(ctx, annot_obj));
        pdf_dict_puts(ctx, xobjects, name, ap);
        pdf_dict_put(ctx, ap, PDF_NAME(Type), PDF_NAME(XObject));
        pdf_dict_put(ctx, ap, PDF_NAME(Subtype), PDF_NAME(Form));

        matrix = annot_xobject_transform(ctx, annot_obj, ap);
        buf = fz_new_buffer(ctx, 256);
        if (draw_background) {
            /* White box under the text, 95% alpha so the original stays
             * faintly visible: an overlay, not a redaction. Drawn as page
             * content (not inside the FreeText appearance) so the black text
             * keeps full opacity. */
            fz_rect rect = pdf_dict_get_rect(ctx, annot_obj, PDF_NAME(Rect));
            ensure_background_extgstate(ctx, res);
            fz_append_printf(ctx, buf, "q\n/%s gs\n1 1 1 rg\n%g %g %g %g re\nf\nQ\n", SPDF_TRANSLATION_BACKGROUND_GS,
                             rect.x0, rect.y0, rect.x1 - rect.x0, rect.y1 - rect.y0);
        }
        fz_append_printf(ctx, buf, "q\n%g %g %g %g %g %g cm\n/%s Do\nQ\n", matrix.a, matrix.b, matrix.c, matrix.d,
                         matrix.e, matrix.f, name);
        append_page_content_stream(ctx, pdf, page_obj, buf);
        remove_page_annotation(ctx, page_obj, annot_obj);
        fz_drop_buffer(ctx, buf);
        buf = NULL;
    }
    fz_catch(ctx) {
        if (buf) fz_drop_buffer(ctx, buf);
        fz_rethrow(ctx);
    }
}

static void compute_image_backed_pages(fz_context* ctx, fz_document* doc, int page_count, int* image_backed) {
    fz_stext_page* text = NULL;
    fz_stext_options opts;
    int i;

    fz_var(text);
    memset(&opts, 0, sizeof(opts));
    opts.flags = FZ_STEXT_PRESERVE_IMAGES;
    fz_try(ctx) {
        for (i = 0; i < page_count; ++i) {
            text = fz_new_stext_page_from_page_number(ctx, doc, i, &opts);
            image_backed[i] = text_page_is_image_backed(text);
            fz_drop_stext_page(ctx, text);
            text = NULL;
        }
    }
    fz_catch(ctx) {
        if (text) fz_drop_stext_page(ctx, text);
        fz_rethrow(ctx);
    }
}

static void add_translated_line_overlay(fz_context* ctx, pdf_document* pdf, const spdf_translated_line* line,
                                        const int* image_backed) {
    static const float black[3] = {0.0f, 0.0f, 0.0f};
    pdf_page* page = NULL;
    pdf_annot* annot = NULL;
    fz_rect raw_rect;
    fz_rect annot_rect;
    float font_size;
    int draw_background;
    char* text = NULL;

    if (!line->text || !*line->text) return;

    text = translated_text_single_line(line->text);
    if (!text || !*text) {
        free(text);
        return;
    }

    draw_background = line->opaque_background == SPDF_TRANSLATION_BACKGROUND_OPAQUE ||
                      line->opaque_background == SPDF_TRANSLATION_BACKGROUND_AUTO;
    (void)image_backed;

    fz_var(page);
    fz_try(ctx) {
        raw_rect = normalized_public_rect(&line->bounds);
        font_size = translated_line_font_size(ctx, line, raw_rect, text);
        annot_rect = translated_line_annotation_rect(line, font_size);
        page = pdf_load_page(ctx, pdf, line->page_index);
        annot = pdf_create_annot(ctx, page, PDF_ANNOT_FREE_TEXT);
        pdf_set_annot_rect(ctx, annot, annot_rect);
        pdf_set_annot_border_width(ctx, annot, 0.0f);
        pdf_set_annot_contents(ctx, annot, text);
        pdf_set_annot_default_appearance(ctx, annot, "Helv", font_size, 3, black);
        pdf_update_annot(ctx, annot);
        bake_overlay_annotation(ctx, pdf, page, annot, draw_background);
        pdf_drop_page(ctx, page);
        page = NULL;
    }
    fz_catch(ctx) {
        free(text);
        if (page) pdf_drop_page(ctx, page);
        fz_rethrow(ctx);
    }
    free(text);
}

/* Clone the current in-memory state of a PDF document by writing it into a
 * buffer and reopening that buffer. Unlike grafting individual pages (which
 * copies only page content and drops everything else), the clone keeps the
 * complete document: outline tree, annotations, links, named destinations
 * and metadata. Encryption is dropped so the translated copy opens without
 * the original's password (the caller already authenticated to read it). */
static pdf_document* clone_pdf_document_in_memory(fz_context* ctx, pdf_document* source_pdf) {
    pdf_document* clone = NULL;
    fz_buffer* buf = NULL;
    fz_output* out = NULL;
    fz_stream* stream = NULL;
    pdf_write_options options;

    fz_var(buf);
    fz_var(out);
    fz_var(stream);
    fz_try(ctx) {
        options = pdf_default_write_options;
        options.do_encrypt = PDF_ENCRYPT_NONE;
        buf = fz_new_buffer(ctx, 1 << 20);
        out = fz_new_output_with_buffer(ctx, buf);
        pdf_write_document(ctx, source_pdf, out, &options);
        fz_close_output(ctx, out);
        stream = fz_open_buffer(ctx, buf);
        clone = pdf_open_document_with_stream(ctx, stream);
    }
    fz_always(ctx) {
        fz_drop_output(ctx, out);
        fz_drop_stream(ctx, stream);
        fz_drop_buffer(ctx, buf);
    }
    fz_catch(ctx) {
        fz_rethrow(ctx);
    }
    return clone;
}

typedef struct outline_title_update_state {
    const spdf_translated_text* updates;
    int update_count;
    int next_update;
    int node_index;    /* pre-order index of the node being visited */
    int nodes_visited; /* safety cap against cyclic/malformed outline trees */
} outline_title_update_state;

/* Pre-order walk of the raw outline dictionary tree (node, then /First
 * children, then /Next siblings) -- the same order spdf_load_outline flattens
 * the outline in, so update indices line up. Only /Title is touched:
 * structure, destinations, colors and expansion state stay as they are. */
static void update_outline_titles_walk(fz_context* ctx, pdf_obj* node, int depth, outline_title_update_state* state) {
    while (node && state->next_update < state->update_count) {
        pdf_obj* down;
        if (++state->nodes_visited > 200000 || depth > 256) return;
        if (state->updates[state->next_update].index == state->node_index) {
            const char* text = state->updates[state->next_update].text;
            pdf_dict_put_text_string(ctx, node, PDF_NAME(Title), text ? text : "");
            state->next_update++;
        }
        state->node_index++;
        down = pdf_dict_get(ctx, node, PDF_NAME(First));
        if (down) update_outline_titles_walk(ctx, down, depth + 1, state);
        node = pdf_dict_get(ctx, node, PDF_NAME(Next));
    }
}

static void apply_outline_title_updates(fz_context* ctx, pdf_document* pdf, const spdf_translated_text* updates,
                                        int update_count) {
    pdf_obj* root = pdf_dict_get(ctx, pdf_trailer(ctx, pdf), PDF_NAME(Root));
    pdf_obj* outlines = pdf_dict_get(ctx, root, PDF_NAME(Outlines));
    pdf_obj* first = pdf_dict_get(ctx, outlines, PDF_NAME(First));
    outline_title_update_state state;

    memset(&state, 0, sizeof(state));
    state.updates = updates;
    state.update_count = update_count;
    if (first) update_outline_titles_walk(ctx, first, 0, &state);
}

/* Replace the text contents of comments identified by their visible comment
 * index -- the same page-by-page annotation enumeration and filter that
 * spdf_load_comments and spdf_update_comment use, so indices line up.
 * FreeText annotations draw their contents on the page, so their appearance
 * stream is regenerated; every other type keeps its appearance and only the
 * popup/note text changes. */
static void apply_comment_text_updates(fz_context* ctx, pdf_document* pdf, int page_count,
                                       const spdf_translated_text* updates, int update_count) {
    pdf_page* page = NULL;
    int visible_index = 0;
    int next_update = 0;
    int i;

    fz_var(page);
    fz_try(ctx) {
        for (i = 0; i < page_count && next_update < update_count; ++i) {
            pdf_annot* annot;
            pdf_obj* annots;
            page = pdf_load_page(ctx, pdf, i);
            annots = pdf_dict_get(ctx, page->obj, PDF_NAME(Annots));
            for (annot = pdf_first_annot(ctx, page); annot && next_update < update_count;
                 annot = pdf_next_annot(ctx, annot)) {
                pdf_obj* obj = pdf_annot_obj(ctx, annot);
                pdf_obj* popup = pdf_dict_get(ctx, obj, PDF_NAME(Popup));
                enum pdf_annot_type annot_type = pdf_annot_type(ctx, annot);
                const char* contents = pdf_annot_contents(ctx, annot);
                const char* author;
                if (!popup) popup = popup_for_parent(ctx, annots, obj);
                if (!contents || !*contents) contents = dict_text_or_empty(ctx, popup, PDF_NAME(Contents));
                author = comment_author_or_empty(ctx, obj, popup);
                if (!comment_annotation_should_surface(contents, author, annot_type)) continue;
                if (visible_index == updates[next_update].index) {
                    const char* text = updates[next_update].text ? updates[next_update].text : "";
                    pdf_dict_put_text_string(ctx, obj, PDF_NAME(Contents), text);
                    pdf_dict_del(ctx, obj, PDF_NAME(RC));
                    if (popup) {
                        pdf_dict_put_text_string(ctx, popup, PDF_NAME(Contents), text);
                        pdf_dict_del(ctx, popup, PDF_NAME(RC));
                    }
                    if (annot_type == PDF_ANNOT_FREE_TEXT) {
                        fz_try(ctx) {
                            pdf_dirty_annot(ctx, annot);
                            pdf_update_annot(ctx, annot);
                        }
                        fz_catch(ctx) {
                            /* Contents are updated even when the appearance
                             * cannot be regenerated. */
                            fz_report_error(ctx);
                        }
                    }
                    next_update++;
                }
                visible_index++;
            }
            pdf_drop_page(ctx, page);
            page = NULL;
        }
    }
    fz_always(ctx) {
        if (page) pdf_drop_page(ctx, page);
    }
    fz_catch(ctx) {
        fz_rethrow(ctx);
    }
}

static int translated_text_updates_are_sorted(const spdf_translated_text* updates, int count) {
    int i;

    for (i = 0; i < count; ++i) {
        if (updates[i].index < 0) return 0;
        if (i > 0 && updates[i].index <= updates[i - 1].index) return 0;
    }
    return 1;
}

int spdf_save_translated_copy(spdf_document* doc, const char* path, const spdf_translated_line* lines, int line_count,
                              char* err, size_t err_len) {
    return spdf_save_translated_copy_full(doc, path, lines, line_count, NULL, 0, NULL, 0, err, err_len);
}

int spdf_save_translated_copy_full(spdf_document* doc, const char* path, const spdf_translated_line* lines,
                                   int line_count, const spdf_translated_text* outline_titles, int outline_title_count,
                                   const spdf_translated_text* comment_texts, int comment_text_count, char* err,
                                   size_t err_len) {
    pdf_document* source_pdf = NULL;
    pdf_document* out_pdf = NULL;
    pdf_write_options options;
    int* image_backed = NULL;
    char* balanced_pages = NULL;
    int needs_image_backed = 0;
    int i;

    set_error(err, err_len, "");
    if (!doc || !path || !*path) {
        set_error(err, err_len, "No document path was supplied.");
        return 0;
    }
    if (line_count < 0 || (line_count > 0 && !lines)) {
        set_error(err, err_len, "No translated lines were supplied.");
        return 0;
    }
    if (outline_title_count < 0 || (outline_title_count > 0 && !outline_titles) ||
        !translated_text_updates_are_sorted(outline_titles, outline_title_count)) {
        set_error(err, err_len, "Translated outline titles are invalid.");
        return 0;
    }
    if (comment_text_count < 0 || (comment_text_count > 0 && !comment_texts) ||
        !translated_text_updates_are_sorted(comment_texts, comment_text_count)) {
        set_error(err, err_len, "Translated comment texts are invalid.");
        return 0;
    }

    balanced_pages = (char*)calloc((size_t)(doc->page_count > 0 ? doc->page_count : 1), 1);
    if (!balanced_pages) {
        set_error(err, err_len, "Out of memory");
        return 0;
    }

    fz_var(out_pdf);
    fz_var(image_backed);
    fz_try(doc->ctx) {
        source_pdf = pdf_specifics(doc->ctx, doc->doc);
        if (!source_pdf) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Only PDF documents can be translated.");

        for (i = 0; i < line_count; ++i) {
            if (lines[i].page_index < 0 || lines[i].page_index >= doc->page_count)
                fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Translated line page index is out of range");
            if (lines[i].opaque_background == SPDF_TRANSLATION_BACKGROUND_AUTO) needs_image_backed = 1;
        }
        if (needs_image_backed) {
            image_backed = (int*)calloc((size_t)(doc->page_count > 0 ? doc->page_count : 1), sizeof(int));
            if (!image_backed) fz_throw(doc->ctx, FZ_ERROR_SYSTEM, "Out of memory");
            compute_image_backed_pages(doc->ctx, doc->doc, doc->page_count, image_backed);
        }

        /* Clone the whole document (not a page-by-page graft) so the outline
         * tree, annotations and links survive into the translated copy. */
        out_pdf = clone_pdf_document_in_memory(doc->ctx, source_pdf);

        if (outline_title_count > 0)
            apply_outline_title_updates(doc->ctx, out_pdf, outline_titles, outline_title_count);
        if (comment_text_count > 0)
            apply_comment_text_updates(doc->ctx, out_pdf, doc->page_count, comment_texts, comment_text_count);

        for (i = 0; i < line_count; ++i) {
            int page_index = lines[i].page_index;
            if (!balanced_pages[page_index]) {
                pdf_page* page = pdf_load_page(doc->ctx, out_pdf, page_index);
                balanced_pages[page_index] = 1;
                fz_try(doc->ctx) {
                    balance_page_contents_for_overlays(doc->ctx, out_pdf, page->obj,
                                                       ensure_page_resources(doc->ctx, page->obj));
                }
                fz_always(doc->ctx) {
                    pdf_drop_page(doc->ctx, page);
                }
                fz_catch(doc->ctx) {
                    fz_rethrow(doc->ctx);
                }
            }
            add_translated_line_overlay(doc->ctx, out_pdf, &lines[i], image_backed);
        }

        options = pdf_default_write_options;
        options.do_compress = 1;
        options.do_compress_images = 1;
        options.do_compress_fonts = 1;
        pdf_save_document(doc->ctx, out_pdf, path, &options);
    }
    fz_always(doc->ctx) {
        free(balanced_pages);
        free(image_backed);
        if (out_pdf) pdf_drop_document(doc->ctx, out_pdf);
        spdf_drop_page_list_cache(doc, -1);
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        return 0;
    }

    return 1;
}

int spdf_save_single_page_pdf(spdf_document* doc, int page_index, const char* path, char* err, size_t err_len) {
    pdf_document* source_pdf = NULL;
    pdf_document* out_pdf = NULL;
    pdf_graft_map* graft_map = NULL;
    pdf_write_options options;

    set_error(err, err_len, "");
    if (!doc || !path || !*path) {
        set_error(err, err_len, "No document path was supplied.");
        return 0;
    }
    if (page_index < 0 || page_index >= doc->page_count) {
        set_error(err, err_len, "Page index is out of range.");
        return 0;
    }

    fz_var(out_pdf);
    fz_var(graft_map);
    fz_try(doc->ctx) {
        source_pdf = pdf_specifics(doc->ctx, doc->doc);
        if (!source_pdf) fz_throw(doc->ctx, FZ_ERROR_FORMAT, "Only PDF documents can be copied as PDF.");

        out_pdf = pdf_create_document(doc->ctx);
        graft_map = pdf_new_graft_map(doc->ctx, out_pdf);
        /* Graft the single requested page into the fresh document at the end. */
        pdf_graft_mapped_page(doc->ctx, graft_map, -1, source_pdf, page_index);

        options = pdf_default_write_options;
        options.do_compress = 1;
        options.do_compress_images = 1;
        options.do_compress_fonts = 1;
        pdf_save_document(doc->ctx, out_pdf, path, &options);
    }
    fz_always(doc->ctx) {
        if (graft_map) pdf_drop_graft_map(doc->ctx, graft_map);
        if (out_pdf) pdf_drop_document(doc->ctx, out_pdf);
        spdf_drop_page_list_cache(doc, -1);
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        return 0;
    }

    return 1;
}

static int stext_block_has_text(fz_stext_block* block) {
    for (; block; block = block->next) {
        if (block->type == FZ_STEXT_BLOCK_TEXT) {
            fz_stext_line* line;
            for (line = block->u.t.first_line; line; line = line->next) {
                fz_stext_char* ch;
                for (ch = line->first_char; ch; ch = ch->next) {
                    if (ch->c > 255 || (ch->c > 0 && !isspace((unsigned char)ch->c))) return 1;
                }
            }
        } else if (block->type == FZ_STEXT_BLOCK_STRUCT && block->u.s.down) {
            if (stext_block_has_text(block->u.s.down->first_block)) return 1;
        }
    }
    return 0;
}

int spdf_document_has_text(spdf_document* doc, int max_pages, char* err, size_t err_len) {
    fz_stext_page* text = NULL;
    int page_count;
    int found = 0;
    int i;

    set_error(err, err_len, "");
    if (!doc) return 0;

    page_count = doc->page_count;
    if (max_pages > 0 && max_pages < page_count) page_count = max_pages;

    /* Never return from inside fz_try: fz_catch pops the frame, so an early
     * return leaks it, and call 245 then hit "exception stack overflow!". */
    fz_try(doc->ctx) {
        for (i = 0; i < page_count; ++i) {
            text = fz_new_stext_page_from_page_number(doc->ctx, doc->doc, i, NULL);
            if (text && stext_block_has_text(text->first_block)) found = 1;
            if (text) {
                fz_drop_stext_page(doc->ctx, text);
                text = NULL;
            }
            if (found) break;
        }
    }
    fz_catch(doc->ctx) {
        set_error(err, err_len, fz_caught_message(doc->ctx));
        if (text) fz_drop_stext_page(doc->ctx, text);
        return -1;
    }

    return found;
}
