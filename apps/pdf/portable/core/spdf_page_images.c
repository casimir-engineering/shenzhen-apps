/* Embedded images at native resolution and pages rendered to PNG, for the assistant's Python (spdf_page_images.h). */
#include "spdf_page_images.h"

#include <mupdf/fitz.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Images found while a page runs: each kept, in drawing order. A page that draws thousands (a tiled scan) stops
 * collecting at the cap; the extraction reports the rest as skipped. */
typedef struct {
    fz_device super;
    fz_image** images;
    int count, capacity, dropped;
} spdf_image_device;

enum { SPDF_MAX_IMAGES_PER_PAGE = 256 };

static void spdf_collect_image(fz_context* ctx, fz_device* device, fz_image* image, fz_matrix ctm, float alpha,
                               fz_color_params params) {
    (void)ctm;
    (void)alpha;
    (void)params;
    spdf_image_device* collector = (spdf_image_device*)device;
    for (int i = 0; i < collector->count; i++)
        if (collector->images[i] == image) return; /* drawn twice on the page: one file */
    if (collector->count >= SPDF_MAX_IMAGES_PER_PAGE) { collector->dropped++; return; }
    if (collector->count == collector->capacity) {
        int capacity = collector->capacity ? collector->capacity * 2 : 8;
        collector->images = fz_realloc_array(ctx, collector->images, capacity, fz_image*);
        collector->capacity = capacity;
    }
    collector->images[collector->count++] = fz_keep_image(ctx, image);
}

static void spdf_set_error(char* err, size_t err_len, const char* message) {
    if (err && err_len) snprintf(err, err_len, "%s", message ? message : "unknown error");
}

static fz_document* spdf_open(fz_context* ctx, const char* path) {
    fz_document* doc = fz_open_document(ctx, path);
    if (fz_needs_password(ctx, doc)) {
        fz_drop_document(ctx, doc);
        fz_throw(ctx, FZ_ERROR_GENERIC, "the document needs a password");
    }
    return doc;
}

static fz_context* spdf_new_context(char* err, size_t err_len) {
    fz_context* ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    if (!ctx) { spdf_set_error(err, err_len, "out of memory"); return NULL; }
    fz_try(ctx) fz_register_document_handlers(ctx);
    fz_catch(ctx) {
        spdf_set_error(err, err_len, fz_caught_message(ctx));
        fz_drop_context(ctx);
        return NULL;
    }
    return ctx;
}

int spdf_document_page_count(const char* path, char* err, size_t err_len) {
    fz_context* ctx = spdf_new_context(err, err_len);
    if (!ctx) return -1;
    fz_document* volatile doc = NULL;
    int count = -1;
    fz_try(ctx) {
        doc = spdf_open(ctx, path);
        count = fz_count_pages(ctx, doc);
    }
    fz_catch(ctx) {
        spdf_set_error(err, err_len, fz_caught_message(ctx));
        count = -1;
    }
    fz_drop_document(ctx, doc);
    fz_drop_context(ctx);
    return count;
}

/* One image written: its file and what it is. Previously written images are found by pointer, so an image several
 * pages share is written once. */
typedef struct {
    fz_image* image;
    spdf_page_image entry;
} spdf_written;

static void spdf_describe(fz_context* ctx, fz_image* image, spdf_page_image* entry) {
    entry->width = image->w;
    entry->height = image->h;
    entry->bits_per_component = image->bpc;
    entry->has_mask = image->mask != NULL;
    snprintf(entry->colorspace, sizeof entry->colorspace, "%s",
             image->colorspace ? fz_colorspace_name(ctx, image->colorspace) : "none");
    int type = fz_compressed_image_type(ctx, image);
    const char* name = type != FZ_IMAGE_UNKNOWN ? fz_image_type_name(type) : "raw";
    snprintf(entry->encoding, sizeof entry->encoding, "%s", name ? name : "raw");
}

/* Writes `image` as out_dir/<base>.jpg (original JPEG bytes) or .png. */
static void spdf_write_image(fz_context* ctx, fz_image* image, const char* out_dir, const char* base,
                             spdf_page_image* entry) {
    char path[4096];
    fz_compressed_buffer* compressed = fz_compressed_image_buffer(ctx, image);
    int gray_or_rgb = image->colorspace &&
                      (fz_colorspace_is_gray(ctx, image->colorspace) || fz_colorspace_is_rgb(ctx, image->colorspace));
    if (compressed && compressed->params.type == FZ_IMAGE_JPEG && gray_or_rgb && !image->use_decode &&
        !image->use_colorkey && compressed->params.u.jpeg.color_transform != 0 && (image->n == 1 || image->n == 3)) {
        snprintf(entry->file, sizeof entry->file, "%s.jpg", base);
        snprintf(path, sizeof path, "%s/%s", out_dir, entry->file);
        fz_save_buffer(ctx, compressed->buffer, path);
        entry->components = image->n;
        entry->alpha = 0;
        entry->lossless = 1;
        return;
    }
    fz_pixmap* volatile pixmap = fz_get_pixmap_from_image(ctx, image, NULL, NULL, NULL, NULL);
    fz_try(ctx) {
        int lossless = image->bpc <= 8;
        if (!pixmap->colorspace) fz_throw(ctx, FZ_ERROR_GENERIC, "an image without colour");
        if (!fz_colorspace_is_gray(ctx, pixmap->colorspace) && !fz_colorspace_is_rgb(ctx, pixmap->colorspace)) {
            fz_pixmap* converted = fz_convert_pixmap(ctx, pixmap, fz_device_rgb(ctx), NULL, NULL,
                                                     fz_default_color_params, 1);
            fz_drop_pixmap(ctx, pixmap);
            pixmap = converted;
            lossless = 0;
        }
        snprintf(entry->file, sizeof entry->file, "%s.png", base);
        snprintf(path, sizeof path, "%s/%s", out_dir, entry->file);
        fz_save_pixmap_as_png(ctx, pixmap, path);
        entry->components = pixmap->n - pixmap->alpha;
        entry->alpha = pixmap->alpha;
        entry->lossless = lossless;
    }
    fz_always(ctx) fz_drop_pixmap(ctx, pixmap);
    fz_catch(ctx) fz_rethrow(ctx);
}

int spdf_extract_page_images(const char* path, const int* pages, int page_count, const char* out_dir, int max_images,
                             long long max_pixels, volatile int* cancel, spdf_page_images* out, char* err,
                             size_t err_len) {
    memset(out, 0, sizeof *out);
    fz_context* ctx = spdf_new_context(err, err_len);
    if (!ctx) return -1;
    fz_document* volatile doc = NULL;
    spdf_written* volatile written = NULL;
    volatile int written_count = 0;
    volatile long long pixels = 0;
    volatile int result = 0;
    fz_try(ctx) {
        doc = spdf_open(ctx, path);
        int total = fz_count_pages(ctx, doc);
        written = fz_calloc(ctx, (size_t)(max_images > 0 ? max_images : 1), sizeof(spdf_written));
        out->items = calloc((size_t)(max_images > 0 ? max_images : 1), sizeof(spdf_page_image));
        if (!out->items) fz_throw(ctx, FZ_ERROR_SYSTEM, "out of memory");
        for (int p = 0; p < page_count; p++) {
            int number = pages[p];
            if (number < 0 || number >= total) fz_throw(ctx, FZ_ERROR_ARGUMENT, "page %d is not in the document", number + 1);
            spdf_image_device* volatile device = NULL;
            fz_page* volatile page = NULL;
            fz_try(ctx) {
                page = fz_load_page(ctx, doc, number);
                device = fz_new_derived_device(ctx, spdf_image_device);
                device->super.fill_image = spdf_collect_image;
                fz_run_page(ctx, page, &device->super, fz_identity, NULL);
                fz_close_device(ctx, &device->super);
                out->skipped += device->dropped;
                for (int i = 0; i < device->count; i++) {
                    if (cancel && *cancel) fz_throw(ctx, FZ_ERROR_ABORT, "stopped");
                    fz_image* image = device->images[i];
                    spdf_page_image entry;
                    int found = -1;
                    for (int w = 0; w < written_count; w++)
                        if (written[w].image == image) { found = w; break; }
                    if (out->count >= max_images) { out->skipped++; continue; }
                    if (found >= 0) {
                        entry = written[found].entry;
                    } else {
                        long long size = (long long)image->w * image->h;
                        if (image->imagemask || pixels + size > max_pixels) { out->skipped++; continue; }
                        memset(&entry, 0, sizeof entry);
                        spdf_describe(ctx, image, &entry);
                        char base[64];
                        snprintf(base, sizeof base, "page-%d-image-%d", number + 1, i + 1);
                        spdf_write_image(ctx, image, out_dir, base, &entry);
                        pixels += size;
                        written[written_count].image = fz_keep_image(ctx, image);
                        written[written_count].entry = entry;
                        written_count++;
                    }
                    entry.page = number;
                    entry.index = i + 1;
                    out->items[out->count++] = entry;
                }
            }
            fz_always(ctx) {
                if (device) {
                    for (int i = 0; i < device->count; i++) fz_drop_image(ctx, device->images[i]);
                    fz_free(ctx, device->images);
                    fz_drop_device(ctx, &device->super);
                }
                fz_drop_page(ctx, page);
            }
            fz_catch(ctx) fz_rethrow(ctx);
        }
    }
    fz_catch(ctx) {
        spdf_set_error(err, err_len, fz_caught_message(ctx));
        result = -1;
    }
    for (int w = 0; written && w < written_count; w++) fz_drop_image(ctx, written[w].image);
    fz_free(ctx, written);
    fz_drop_document(ctx, doc);
    fz_drop_context(ctx);
    if (result != 0) spdf_free_page_images(out);
    return result;
}

void spdf_free_page_images(spdf_page_images* images) {
    if (!images) return;
    free(images->items);
    images->items = NULL;
    images->count = 0;
}

int spdf_render_pages_png(const char* path, const int* pages, int page_count, int dpi, const char* out_dir,
                          long long max_pixels, volatile int* cancel, spdf_page_render* out, char* err,
                          size_t err_len) {
    fz_context* ctx = spdf_new_context(err, err_len);
    if (!ctx) return -1;
    fz_document* volatile doc = NULL;
    volatile int result = 0;
    fz_try(ctx) {
        doc = spdf_open(ctx, path);
        int total = fz_count_pages(ctx, doc);
        float scale = (float)dpi / 72.0f;
        for (int p = 0; p < page_count; p++) {
            if (cancel && *cancel) fz_throw(ctx, FZ_ERROR_ABORT, "stopped");
            int number = pages[p];
            if (number < 0 || number >= total) fz_throw(ctx, FZ_ERROR_ARGUMENT, "page %d is not in the document", number + 1);
            fz_page* volatile page = fz_load_page(ctx, doc, number);
            fz_pixmap* volatile pixmap = NULL;
            fz_try(ctx) {
                fz_irect box = fz_round_rect(fz_transform_rect(fz_bound_page(ctx, page), fz_scale(scale, scale)));
                long long size = (long long)(box.x1 - box.x0) * (box.y1 - box.y0);
                if (size > max_pixels)
                    fz_throw(ctx, FZ_ERROR_ARGUMENT, "page %d at %d dpi would be too large; use a lower dpi",
                             number + 1, dpi);
                pixmap = fz_new_pixmap_from_page(ctx, page, fz_scale(scale, scale), fz_device_rgb(ctx), 0);
                out[p].page = number;
                out[p].width = pixmap->w;
                out[p].height = pixmap->h;
                snprintf(out[p].file, sizeof out[p].file, "page-%d-%ddpi.png", number + 1, dpi);
                char target[4096];
                snprintf(target, sizeof target, "%s/%s", out_dir, out[p].file);
                fz_save_pixmap_as_png(ctx, pixmap, target);
            }
            fz_always(ctx) {
                fz_drop_pixmap(ctx, pixmap);
                fz_drop_page(ctx, page);
            }
            fz_catch(ctx) fz_rethrow(ctx);
        }
    }
    fz_catch(ctx) {
        spdf_set_error(err, err_len, fz_caught_message(ctx));
        result = -1;
    }
    fz_drop_document(ctx, doc);
    fz_drop_context(ctx);
    return result;
}
