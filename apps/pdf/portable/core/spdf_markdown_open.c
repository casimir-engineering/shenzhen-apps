/* spdf_markdown_open.c -- the MuPDF side of Markdown: open, lay out, export.
 *
 * The only unit of the subsystem that touches MuPDF or the disk. It reads the
 * file, hands the bytes to the pure converter, and gives MuPDF's HTML engine
 * the result as an in-memory document whose "directory" is the Markdown
 * file's own folder -- so `![](img/a.png)` resolves exactly as it would in a
 * browser next to the file, and nothing outside that folder is reachable
 * (spdf_markdown_resolve_image already refused `..`, absolute paths and drive
 * letters at conversion time; the directory archive is the second fence).
 * A frontend's remote-image cache is a second directory MOUNTED under
 * ".spdf-remote/", which is the prefix the converter rewrote cached https
 * sources to. That same mount carries transcoded LOCAL images: this file works
 * out the document's folder once and puts it in options.document_dir, which is
 * what lets the local-image hook turn `![](shot.webp)` -- a format MuPDF has no
 * decoder for -- into a PNG in the cache.
 *
 * TWO RENDITIONS, ONE PAGINATION. With options->dark_rendition the same body
 * is laid out twice, once per stylesheet, and the dark document is parked in
 * spdf_document.dark_doc for the core's render path to pick up under
 * SPDF_RENDER_DARK_THEME. The stylesheets differ only in colours
 * (spdf_markdown_support.c), so the page count matches; if it ever did not,
 * the dark rendition is dropped rather than shown -- a wrong page is worse
 * than a recoloured one.
 *
 * The page is A4 (595 x 842 pt, landscape swapped) and the em is 11pt times
 * text_scale, which is the whole of the A-/A+ text-size control: a different
 * em relays the document; nothing else in the pipeline knows about it.
 */
#include "spdf_core_document.h"
#include "spdf_document_export.h"
#include "spdf_markdown.h"
#include "spdf_win_compat.h"

#include <stdlib.h>
#include <string.h>

#define SPDF_MARKDOWN_STORE_LIMIT ((size_t)256 * 1024 * 1024)
#define SPDF_MARKDOWN_INPUT_BUDGET ((size_t)64 * 1024 * 1024) /* the Mac reader's limit too */
#define SPDF_MARKDOWN_BASE_EM 11.0f
#define SPDF_A4_WIDTH 595.0f
#define SPDF_A4_HEIGHT 842.0f

static void set_error(char* err, size_t err_len, const char* message) {
    if (!err || err_len == 0) return;
    snprintf(err, err_len, "%s", message ? message : "Unknown error");
}

static float clamp_scale(float scale) {
    if (!(scale > 0.0f)) return 1.0f; /* NaN, zero, negative */
    if (scale < 0.5f) return 0.5f;
    if (scale > 3.0f) return 3.0f;
    return scale;
}

static fz_document* open_rendition(fz_context* ctx, fz_archive* dir, const char* html, float w, float h, float em) {
    fz_buffer* buf = NULL;
    fz_stream* stm = NULL;
    fz_document* doc = NULL;

    fz_var(buf);
    fz_var(stm);
    fz_try(ctx) {
        buf = fz_new_buffer_from_copied_data(ctx, (const unsigned char*)html, strlen(html));
        stm = fz_open_buffer(ctx, buf);
        /* "html" is the magic: it selects MuPDF's HTML5 handler by extension. */
        doc = fz_open_document_with_stream_and_dir(ctx, "html", stm, dir);
        fz_layout_document(ctx, doc, w, h, em);
    }
    fz_always(ctx) {
        fz_drop_stream(ctx, stm);
        fz_drop_buffer(ctx, buf);
    }
    fz_catch(ctx) {
        fz_drop_document(ctx, doc);
        fz_rethrow(ctx);
    }
    return doc;
}

/* The document's own folder, as both MuPDF's resource root and the base the
 * local-image hook resolves a relative source against. 0 when the path is too
 * long for the buffer. Not fz_dirname: it splits on '/' alone, and a Windows
 * path arrives with backslashes -- the folder would silently become ".". */
static int document_dir(const char* path, char* dir, size_t cap) {
    size_t dir_len = spdf_compat_path_dir_len(path);

    if (dir_len == 0) {
        if (cap < 2) return 0;
        strcpy(dir, ".");
        return 1;
    }
    if (dir_len >= cap) return 0;
    memcpy(dir, path, dir_len);
    dir[dir_len] = '\0';
    if (dir_len > 1 && (dir[dir_len - 1] == '/' || dir[dir_len - 1] == '\\') && dir[dir_len - 2] != ':')
        dir[dir_len - 1] = '\0'; /* "C:\a\b\" -> "C:\a\b", but keep "C:\" whole */
    return 1;
}

/* The document's folder, plus the remote cache mounted under its prefix. */
static fz_archive* open_resources(fz_context* ctx, const char* dir, const char* remote_dir) {
    fz_archive* local = NULL;
    fz_archive* remote = NULL;
    fz_archive* multi = NULL;

    fz_var(local);
    fz_var(remote);
    fz_var(multi);
    fz_try(ctx) {
        local = fz_open_directory(ctx, dir);
        if (remote_dir && *remote_dir) {
            multi = fz_new_multi_archive(ctx);
            fz_mount_multi_archive(ctx, multi, local, NULL);
            remote = fz_open_directory(ctx, remote_dir);
            fz_mount_multi_archive(ctx, multi, remote, SPDF_MARKDOWN_REMOTE_MOUNT);
        }
    }
    fz_always(ctx) {
        if (multi) {
            /* The multi archive holds its own references. */
            fz_drop_archive(ctx, remote);
            fz_drop_archive(ctx, local);
        }
    }
    fz_catch(ctx) {
        fz_drop_archive(ctx, multi);
        fz_drop_archive(ctx, local);
        fz_rethrow(ctx);
    }
    return multi ? multi : local;
}

spdf_document* spdf_open_markdown(const char* path, const spdf_markdown_options* options, char* err, size_t err_len) {
    spdf_markdown_options opts = options ? *options : spdf_markdown_default_options();
    spdf_document* opened = NULL;
    fz_context* ctx;
    fz_buffer* source = NULL;
    fz_archive* dir = NULL;
    fz_document* light_doc = NULL;
    fz_document* dark_doc = NULL;
    char* body = NULL;
    char* light = NULL;
    char* dark = NULL;
    char dir_utf8[2048];
    float w, h, em;

    set_error(err, err_len, "");
    if (!path || !*path) {
        set_error(err, err_len, "No document path was supplied.");
        return NULL;
    }
    if (!document_dir(path, dir_utf8, sizeof(dir_utf8))) {
        set_error(err, err_len, "Document path is too long.");
        return NULL;
    }
    ctx = fz_new_context(NULL, NULL, SPDF_MARKDOWN_STORE_LIMIT);
    if (!ctx) {
        set_error(err, err_len, "Could not create MuPDF context.");
        return NULL;
    }
    /* The converter's local-image hook resolves `![](a.webp)` against this. */
    opts.document_dir = dir_utf8;
    opts.text_scale = clamp_scale(opts.text_scale);
    w = opts.landscape ? SPDF_A4_HEIGHT : SPDF_A4_WIDTH;
    h = opts.landscape ? SPDF_A4_WIDTH : SPDF_A4_HEIGHT;
    em = SPDF_MARKDOWN_BASE_EM * opts.text_scale;

    fz_var(source);
    fz_var(dir);
    fz_var(light_doc);
    fz_var(dark_doc);
    fz_var(opened);
    fz_var(body);
    fz_var(light);
    fz_var(dark);
    fz_try(ctx) {
        unsigned char* data;
        size_t size;

        fz_register_document_handlers(ctx);
        source = fz_read_file(ctx, path);
        size = fz_buffer_storage(ctx, source, &data);
        if (size > SPDF_MARKDOWN_INPUT_BUDGET) fz_throw(ctx, FZ_ERROR_LIMIT, "Markdown file is larger than 64 MiB.");

        body = spdf_markdown_body_html((const char*)data, size, &opts);
        if (!body) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
        light = spdf_markdown_document_html(body, 0);
        if (!light) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
        if (opts.dark_rendition) {
            dark = spdf_markdown_document_html(body, 1);
            if (!dark) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
        }
        fz_drop_buffer(ctx, source);
        source = NULL;

        dir = open_resources(ctx, dir_utf8, opts.remote_image_dir);
        light_doc = open_rendition(ctx, dir, light, w, h, em);
        if (dark) {
            dark_doc = open_rendition(ctx, dir, dark, w, h, em);
            if (fz_count_pages(ctx, dark_doc) != fz_count_pages(ctx, light_doc)) {
                fz_drop_document(ctx, dark_doc); /* never show a rendition that paginates differently */
                dark_doc = NULL;
            }
        }

        opened = (spdf_document*)calloc(1, sizeof(spdf_document));
        if (!opened) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
        opened->ctx = ctx;
        opened->doc = light_doc;
        opened->dark_doc = dark_doc;
        opened->page_count = fz_count_pages(ctx, light_doc);
        spdf_recolor_page_cache_reset(&opened->recolor_pages);
        if (opened->page_count > 0) {
            opened->page_sizes = (spdf_page_size_cache*)calloc((size_t)opened->page_count, sizeof(spdf_page_size_cache));
            if (!opened->page_sizes) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
        }
        opened->title = fz_strdup(ctx, spdf_compat_path_basename(path));
    }
    fz_always(ctx) {
        free(body);
        free(light);
        free(dark);
        fz_drop_buffer(ctx, source);
        fz_drop_archive(ctx, dir); /* the documents keep their own reference */
    }
    fz_catch(ctx) {
        set_error(err, err_len, fz_caught_message(ctx));
        fz_ignore_error(ctx); /* reported through err; MuPDF would otherwise flag it at the next throw */
        if (opened) {
            free(opened->page_sizes);
            free(opened);
        }
        fz_drop_document(ctx, dark_doc);
        fz_drop_document(ctx, light_doc);
        fz_drop_context(ctx);
        return NULL;
    }
    /* fz_strdup allocates with the context's allocator (malloc here), and
     * spdf_close frees the title with free(): the same default allocator. */
    return opened;
}

int spdf_markdown_resolve_anchor(spdf_document* doc, const char* uri, int* page_index, float* page_y) {
    fz_location loc;
    float x = 0.0f, y = 0.0f;
    int page = -1;

    if (!doc || !doc->doc || !uri || !*uri) return 0;
    fz_try(doc->ctx) {
        /* The light rendition on purpose: the two paginate identically (the
         * opener drops the dark one if they ever did not), and every caller of
         * this wants coordinates it can compare with a rendered page. */
        loc = fz_resolve_link(doc->ctx, doc->doc, uri, &x, &y);
        if (loc.page >= 0 || loc.chapter >= 0) page = fz_page_number_from_location(doc->ctx, doc->doc, loc);
    }
    fz_catch(doc->ctx) {
        fz_ignore_error(doc->ctx);
        return 0;
    }
    if (page < 0 || page >= doc->page_count) return 0;
    if (page_index) *page_index = page;
    /* MuPDF's HTML anchor y is in CONTENT space, not page space: look at
     * htdoc_resolve_link (mupdf/source/html/html-doc.c:65-70), which divides by
     * html->page_h -- the printable height -- and never adds html->page_margin[T],
     * the way fz_load_html_links does for a link rectangle
     * (html-outline.c:138-143). A caller comparing this with a rendered page
     * would be a whole top margin out, which is 60pt of a 842pt sheet and looks
     * exactly like an off-by-one-element bug. Add it here, once. */
    if (page_y) *page_y = y + SPDF_MARKDOWN_PAGE_MARGIN_TOP_PT;
    return 1;
}

int spdf_export_pdf(spdf_document* doc, const char* path, int page_index, char* err, size_t err_len) {
    return spdf_document_export_pdf(doc, path, page_index, err, err_len);
}
