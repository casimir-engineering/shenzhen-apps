/* md_html_probe.c -- the Markdown track's measuring instrument, not a test.
 *
 * Renders an .html (MuPDF's engine directly, laid out on A4 at a chosen em) or
 * a .md (through the core's spdf_open_markdown) to one PNG per page, and prints
 * what the reader would see through the core: page count, the outline MuPDF
 * derives from the headings, and the link rectangles on page 0. This is what
 * produced the evidence in portable/docs/windows-markdown-design.md, and it
 * stays here so anyone can re-measure a CSS change in seconds:
 *
 *   build-native.cmd md_html_probe portable/win/tests/md_html_probe.c <core set> ext/md4c/md4c.c ...
 *   md_html_probe.exe <input.html|input.md> <out-prefix> [em] [--dark]
 *
 * Not discovered by run-tests-native.sh (no _test suffix) on purpose: it needs
 * a human to look at the PNGs.
 */
#include "mupdf/fitz.h"

#include "shenzhen_pdf_core.h"
#include "spdf_selection.h"
#if defined(__has_include)
#if __has_include("spdf_markdown.h")
#define SPDF_PROBE_HAS_MARKDOWN 1
#endif
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int ends_with_ci(const char* s, const char* suffix) {
    size_t n = strlen(s), m = strlen(suffix);
    return n >= m && _stricmp(s + n - m, suffix) == 0;
}

static void dump_outline(fz_context* ctx, fz_outline* node, int depth) {
    for (; node; node = node->next) {
        printf("outline%*s L%d page=%d \"%s\" uri=%s\n", depth * 2, "", depth + 1, node->page.page, node->title ? node->title : "",
               node->uri ? node->uri : "");
        if (node->down) dump_outline(ctx, node->down, depth + 1);
    }
}

int main(int argc, char** argv) {
    const char* input;
    const char* prefix;
    float em = 11.0f;
    unsigned flags = SPDF_RENDER_DEFAULT;
    int i;

    if (argc < 3) {
        fprintf(stderr, "usage: md_html_probe <input.html|.md> <out-prefix> [em] [--dark]\n");
        return 64;
    }
    input = argv[1];
    prefix = argv[2];
    for (i = 3; i < argc; ++i) {
        if (strcmp(argv[i], "--dark") == 0) flags |= SPDF_RENDER_DARK_THEME;
        else em = (float)atof(argv[i]);
    }

#ifdef SPDF_PROBE_HAS_MARKDOWN
    if (ends_with_ci(input, ".md") || ends_with_ci(input, ".markdown")) {
        char err[512] = {0};
        spdf_markdown_options opts = spdf_markdown_default_options();
        spdf_document* doc;
        spdf_outline outline;
        int pages, p;
        fz_context* ctx;
        fz_document* fzdoc;

        opts.text_scale = em / 11.0f;
        doc = spdf_open_markdown(input, &opts, err, sizeof(err));
        if (!doc) {
            fprintf(stderr, "spdf_open_markdown failed: %s\n", err);
            return 1;
        }
        pages = spdf_page_count(doc);
        printf("pages=%d title=\"%s\"\n", pages, spdf_title(doc));
        memset(&outline, 0, sizeof(outline));
        if (spdf_load_outline(doc, &outline, err, sizeof(err))) {
            for (i = 0; i < outline.count; ++i)
                printf("outline L%d page=%d \"%s\"\n", outline.items[i].level, outline.items[i].page_index,
                       outline.items[i].title);
            spdf_free_outline(&outline);
        }
        spdf_selection_document_access(doc, 0, &ctx, &fzdoc, err, sizeof(err));
        for (p = 0; p < pages; ++p) {
            spdf_bitmap bmp;
            char name[1024];
            fz_pixmap* pix;
            if (!spdf_render_page_rgba_opts(doc, p, 1.5f, flags, NULL, &bmp, err, sizeof(err))) {
                fprintf(stderr, "render %d failed: %s\n", p, err);
                continue;
            }
            pix = fz_new_pixmap(ctx, fz_device_rgb(ctx), bmp.width, bmp.height, NULL, 1);
            for (i = 0; i < bmp.height; ++i)
                memcpy(pix->samples + (size_t)i * pix->stride, bmp.rgba + (size_t)i * bmp.stride, (size_t)bmp.width * 4);
            snprintf(name, sizeof(name), "%s-%02d.png", prefix, p);
            fz_save_pixmap_as_png(ctx, pix, name);
            fz_drop_pixmap(ctx, pix);
            spdf_free_bitmap(&bmp);
        }
        {
            spdf_rect rects[64];
            int n = spdf_page_link_rects(doc, 0, 0, rects, 64, err, sizeof(err));
            printf("links page0=%d\n", n);
        }
        spdf_close(doc);
        return 0;
    }
#endif

    {
        fz_context* ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
        fz_document* doc = NULL;
        fz_outline* outline = NULL;
        int pages, p;
        fz_try(ctx) {
            fz_register_document_handlers(ctx);
            doc = fz_open_document(ctx, input);
            fz_layout_document(ctx, doc, 595.0f, 842.0f, em);
            pages = fz_count_pages(ctx, doc);
            printf("pages=%d\n", pages);
            outline = fz_load_outline(ctx, doc);
            dump_outline(ctx, outline, 0);
            for (p = 0; p < pages; ++p) {
                char name[1024];
                fz_pixmap* pix =
                    fz_new_pixmap_from_page_number(ctx, doc, p, fz_scale(1.5f, 1.5f), fz_device_rgb(ctx), 0);
                snprintf(name, sizeof(name), "%s-%02d.png", prefix, p);
                fz_save_pixmap_as_png(ctx, pix, name);
                fz_drop_pixmap(ctx, pix);
            }
            {
                fz_page* page = fz_load_page(ctx, doc, 0);
                fz_link* links = fz_load_links(ctx, page);
                fz_link* l;
                for (l = links; l; l = l->next)
                    printf("link [%.1f %.1f %.1f %.1f] %s\n", l->rect.x0, l->rect.y0, l->rect.x1, l->rect.y1, l->uri);
                fz_drop_link(ctx, links);
                fz_drop_page(ctx, page);
            }
        }
        fz_always(ctx) {
            fz_drop_outline(ctx, outline);
            fz_drop_document(ctx, doc);
        }
        fz_catch(ctx) {
            fprintf(stderr, "error: %s\n", fz_caught_message(ctx));
            fz_drop_context(ctx);
            return 1;
        }
        fz_drop_context(ctx);
    }
    return 0;
}
