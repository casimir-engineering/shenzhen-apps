/* markdown_open_test.c -- a Markdown file through the core, end to end.
 *
 * Opens portable/win/tests/fixtures/readme-style.md with spdf_open_markdown
 * and checks what the reader would see through the SAME core calls a PDF tab
 * makes: pages exist, the chapter outline is the H1-H3 headings with their
 * pages, a word on the last page is found on the last page and not on the
 * first, links exist on page 0, the dark rendition draws on #1E1E1E paper
 * while the light one stays white (and the export/print path, which passes no
 * flag, gets the light one), a bigger text size paginates onto more pages,
 * landscape swaps the sheet, and Save as PDF writes a file that reopens with
 * the same page count.
 *
 * No network: the fixture's https image is a placeholder here. The remote
 * cache is exercised with a fake hook pointing at a scratch directory holding
 * a copy of the local icon, which is how the frontend's WinHTTP cache reaches
 * the converter too.
 */
/* spdf-test-sources: portable/core/spdf_markdown.c portable/core/spdf_markdown_support.c portable/core/spdf_markdown_html.c portable/core/spdf_markdown_lang.c portable/core/spdf_markdown_lex.c portable/core/spdf_markdown_math.c portable/core/spdf_markdown_fences.c portable/core/spdf_markdown_open.c ext/md4c/md4c.c portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c */
/* spdf-test-args: portable/win/tests/fixtures/readme-style.md %SCRATCH% */
/* spdf-test-needs: mupdf */
#include "shenzhen_pdf_core.h"

#include <direct.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;

#define EXPECT(condition, ...)                         \
    do {                                               \
        if (!(condition)) {                            \
            fprintf(stderr, "FAIL " __VA_ARGS__);      \
            fprintf(stderr, " [line %d]\n", __LINE__); \
            ++g_failures;                              \
        }                                              \
    } while (0)

static int outline_has(const spdf_outline* o, int level, const char* title, int* page_out) {
    int i;
    for (i = 0; i < o->count; ++i) {
        if (o->items[i].level == level && strcmp(o->items[i].title, title) == 0) {
            if (page_out) *page_out = o->items[i].page_index;
            return 1;
        }
    }
    return 0;
}

static unsigned pixel(const spdf_bitmap* b, int x, int y) {
    const unsigned char* p = b->rgba + (size_t)y * (size_t)b->stride + (size_t)x * 4;
    return ((unsigned)p[0] << 16) | ((unsigned)p[1] << 8) | p[2];
}

static int bitmaps_differ(const spdf_bitmap* a, const spdf_bitmap* b) {
    int y;
    if (a->width != b->width || a->height != b->height) return 1;
    for (y = 0; y < a->height; ++y)
        if (memcmp(a->rgba + (size_t)y * a->stride, b->rgba + (size_t)y * b->stride, (size_t)a->width * 4)) return 1;
    return 0;
}

static int copy_file(const char* from, const char* to) {
    FILE* in = fopen(from, "rb");
    FILE* out = in ? fopen(to, "wb") : NULL;
    char buf[8192];
    size_t n;
    if (!in || !out) {
        if (in) fclose(in);
        return 0;
    }
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) fwrite(buf, 1, n, out);
    fclose(in);
    fclose(out);
    return 1;
}

static int scratch_hook(void* user, const char* url, char* out, size_t cap) {
    (void)user;
    if (strstr(url, "shields.io")) {
        snprintf(out, cap, "cached-badge.png");
        return 1;
    }
    return 0;
}

int main(int argc, char** argv) {
    const char* fixture = argc > 1 ? argv[1] : "portable/win/tests/fixtures/readme-style.md";
    const char* scratch = argc > 2 ? argv[2] : ".";
    char err[512] = {0};
    spdf_markdown_options opts = spdf_markdown_default_options();
    spdf_document* doc;
    spdf_outline outline;
    int pages, last, page = -1;
    float w = 0, h = 0;
    spdf_bitmap light, dark, export_flags;
    spdf_rect rects[64];
    char out_path[2048];

    EXPECT(spdf_path_is_markdown(fixture), "fixture path is recognised as Markdown");

    doc = spdf_open_markdown(fixture, &opts, err, sizeof(err));
    EXPECT(doc != NULL, "spdf_open_markdown: %s", err);
    if (!doc) return 1;

    pages = spdf_page_count(doc);
    last = pages - 1;
    EXPECT(pages >= 3, "the fixture paginates onto several A4 sheets (%d)", pages);
    EXPECT(strcmp(spdf_title(doc), "readme-style.md") == 0, "title is the file name: %s", spdf_title(doc));
    EXPECT(spdf_page_size(doc, 0, &w, &h, err, sizeof(err)) && (int)w == 595 && (int)h == 842,
           "A4 portrait: %gx%g", w, h);

    /* --- outline: H1-H3 with pages (spdf_outline_item.level is 0-based) ------ */
    memset(&outline, 0, sizeof(outline));
    EXPECT(spdf_load_outline(doc, &outline, err, sizeof(err)), "outline loads: %s", err);
    EXPECT(outline_has(&outline, 0, "ShenzhenPDF Fixture", &page) && page == 0, "H1 on page 0");
    EXPECT(outline_has(&outline, 1, "Lists", &page) && page == 0, "H2 Lists on page 0 (%d)", page);
    EXPECT(outline_has(&outline, 1, "Tables", NULL), "H2 Tables");
    EXPECT(outline_has(&outline, 2, "Details", NULL), "H3 Details");
    EXPECT(outline_has(&outline, 1, "Colophon", &page) && page == last, "Colophon is on the last page (%d/%d)",
           page, last);
    EXPECT(!outline_has(&outline, 3, "A fourth-level heading", NULL), "H4 stays out of the outline");
    {
        int i, deepest = 0;
        for (i = 0; i < outline.count; ++i)
            if (outline.items[i].level > deepest) deepest = outline.items[i].level;
        EXPECT(deepest == 2, "outline depth is H1-H3 (deepest level index %d)", deepest);
        EXPECT(outline.count >= 8, "outline has the fixture's headings (%d)", outline.count);
    }
    spdf_free_outline(&outline);

    /* --- search and links --------------------------------------------------- */
    EXPECT(spdf_search_page(doc, last, "zanzibar", err, sizeof(err)) == 1, "zanzibar found once on the last page");
    EXPECT(spdf_search_page(doc, 0, "zanzibar", err, sizeof(err)) == 0, "zanzibar absent from page 0");
    EXPECT(spdf_search_page(doc, 0, "Fixture", err, sizeof(err)) >= 1, "the title is searchable text");
    EXPECT(spdf_search_page_rects(doc, last, "zanzibar", rects, 64, err, sizeof(err)) == 1 && rects[0].x1 > rects[0].x0,
           "search returns a rectangle");
    EXPECT(spdf_page_link_rects(doc, 0, 0, rects, 64, err, sizeof(err)) >= 2, "page 0 carries link rectangles");
    {
        spdf_link_target target;
        memset(&target, 0, sizeof(target));
        /* The anchor link "#tables" resolves to the Tables heading's page. */
        int n = spdf_page_link_rects(doc, 0, 0, rects, 64, err, sizeof(err));
        int i, internal = 0;
        for (i = 0; i < n; ++i) {
            float cx = (rects[i].x0 + rects[i].x1) / 2, cy = (rects[i].y0 + rects[i].y1) / 2;
            if (spdf_link_at_point(doc, 0, cx, cy, &target, 0, err, sizeof(err)) && target.kind == SPDF_LINK_INTERNAL)
                internal = 1;
            spdf_free_link_target(&target);
        }
        EXPECT(internal, "an internal #anchor link resolves through the core's link path");
    }

    /* --- the two renditions -------------------------------------------------- */
    memset(&light, 0, sizeof(light));
    memset(&dark, 0, sizeof(dark));
    memset(&export_flags, 0, sizeof(export_flags));
    EXPECT(spdf_render_page_rgba_opts(doc, 0, 0.5f, SPDF_RENDER_DEFAULT, NULL, &light, err, sizeof(err)),
           "light render: %s", err);
    EXPECT(spdf_render_page_rgba_opts(doc, 0, 0.5f, SPDF_RENDER_DARK_THEME | SPDF_RENDER_USE_PAGE_LIST, NULL, &dark,
                                      err, sizeof(err)),
           "dark render: %s", err);
    EXPECT(spdf_render_page_rgba_opts(doc, 0, 0.5f, SPDF_RENDER_DEFAULT | SPDF_RENDER_USE_PAGE_LIST, NULL,
                                      &export_flags, err, sizeof(err)),
           "export-flag render: %s", err);
    if (light.rgba && dark.rgba && export_flags.rgba) {
        EXPECT(pixel(&light, 2, 2) == 0xFFFFFF, "light paper is white (%06X)", pixel(&light, 2, 2));
        EXPECT(pixel(&dark, 2, 2) == 0x1E1E1E, "dark paper is #1E1E1E (%06X)", pixel(&dark, 2, 2));
        EXPECT(bitmaps_differ(&light, &dark), "the dark rendition is a different picture");
        EXPECT(!bitmaps_differ(&light, &export_flags), "no flag = light, list or not (the export rule)");
    }
    spdf_free_bitmap(&light);
    spdf_free_bitmap(&dark);
    spdf_free_bitmap(&export_flags);

    /* --- export --------------------------------------------------------------- */
    snprintf(out_path, sizeof(out_path), "%s/markdown-export.pdf", scratch);
    EXPECT(spdf_export_pdf(doc, out_path, -1, err, sizeof(err)), "export whole document: %s", err);
    {
        spdf_document* pdf = spdf_open(out_path, err, sizeof(err));
        EXPECT(pdf != NULL, "exported PDF reopens: %s", err);
        if (pdf) {
            EXPECT(spdf_page_count(pdf) == pages, "exported page count %d == %d", spdf_page_count(pdf), pages);
            EXPECT(spdf_search_page(pdf, last, "zanzibar", err, sizeof(err)) == 1, "exported text is selectable text");
            spdf_close(pdf);
        }
    }
    snprintf(out_path, sizeof(out_path), "%s/markdown-page.pdf", scratch);
    EXPECT(spdf_export_pdf(doc, out_path, last, err, sizeof(err)), "export one page: %s", err);
    {
        spdf_document* pdf = spdf_open(out_path, err, sizeof(err));
        EXPECT(pdf && spdf_page_count(pdf) == 1, "single-page export has one page");
        if (pdf) spdf_close(pdf);
    }
    EXPECT(!spdf_export_pdf(doc, out_path, pages + 5, err, sizeof(err)) && err[0], "out-of-range page is refused");
    spdf_close(doc);

    /* --- text size and orientation -------------------------------------------- */
    opts.text_scale = 1.6f;
    opts.dark_rendition = 0;
    doc = spdf_open_markdown(fixture, &opts, err, sizeof(err));
    EXPECT(doc != NULL, "open at 1.6x: %s", err);
    if (doc) {
        EXPECT(spdf_page_count(doc) > pages, "bigger text, more pages (%d > %d)", spdf_page_count(doc), pages);
        memset(&dark, 0, sizeof(dark));
        EXPECT(spdf_render_page_rgba_opts(doc, 0, 0.3f, SPDF_RENDER_DARK_THEME, NULL, &dark, err, sizeof(err)),
               "dark render without a dark rendition falls back to the recolour: %s", err);
        if (dark.rgba) EXPECT(pixel(&dark, 2, 2) == 0x1E1E1E, "recoloured paper is #1E1E1E too (%06X)", pixel(&dark, 2, 2));
        spdf_free_bitmap(&dark);
        spdf_close(doc);
    }
    opts.text_scale = 1.0f;
    opts.landscape = 1;
    doc = spdf_open_markdown(fixture, &opts, err, sizeof(err));
    EXPECT(doc != NULL, "open landscape: %s", err);
    if (doc) {
        EXPECT(spdf_page_size(doc, 0, &w, &h, err, sizeof(err)) && (int)w == 842 && (int)h == 595,
               "A4 landscape: %gx%g", w, h);
        spdf_close(doc);
    }

    /* --- remote image cache through the hook ------------------------------------ */
    {
        char cache_dir[2048], cached[2048], fixture_dir[2048], icon[2048];
        size_t n = strlen(fixture);
        spdf_document* plain;
        spdf_bitmap a, b;
        while (n && fixture[n - 1] != '/' && fixture[n - 1] != '\\') --n;
        memcpy(fixture_dir, fixture, n);
        fixture_dir[n] = '\0';
        snprintf(icon, sizeof(icon), "%smd-icon.png", fixture_dir);
        snprintf(cache_dir, sizeof(cache_dir), "%s/md-image-cache", scratch);
        (void)_mkdir(cache_dir);
        snprintf(cached, sizeof(cached), "%s/cached-badge.png", cache_dir);
        EXPECT(copy_file(icon, cached), "scratch cache seeded from %s", icon);

        opts = spdf_markdown_default_options();
        opts.dark_rendition = 0;
        plain = spdf_open_markdown(fixture, &opts, err, sizeof(err));
        opts.remote_image = scratch_hook;
        opts.remote_image_dir = cache_dir;
        doc = spdf_open_markdown(fixture, &opts, err, sizeof(err));
        EXPECT(plain && doc, "opens with and without the cache hook: %s", err);
        if (plain && doc) {
            int images_page = -1;
            memset(&outline, 0, sizeof(outline));
            spdf_load_outline(doc, &outline, err, sizeof(err));
            outline_has(&outline, 1, "Images", &images_page);
            spdf_free_outline(&outline);
            EXPECT(images_page >= 0, "Images heading located");
            memset(&a, 0, sizeof(a));
            memset(&b, 0, sizeof(b));
            if (images_page >= 0 &&
                spdf_render_page_rgba(plain, images_page, 0.5f, &a, err, sizeof(err)) &&
                spdf_render_page_rgba(doc, images_page, 0.5f, &b, err, sizeof(err)))
                EXPECT(bitmaps_differ(&a, &b), "a cached remote image draws where the placeholder was");
            spdf_free_bitmap(&a);
            spdf_free_bitmap(&b);
        }
        if (plain) spdf_close(plain);
        if (doc) spdf_close(doc);
    }

    /* --- failure paths ------------------------------------------------------------- */
    doc = spdf_open_markdown("Z:/no/such/file.md", NULL, err, sizeof(err));
    EXPECT(doc == NULL && err[0], "missing file fails with a message");
    doc = spdf_open_markdown("", NULL, err, sizeof(err));
    EXPECT(doc == NULL && err[0], "empty path fails with a message");

    if (g_failures) {
        fprintf(stderr, "%d Markdown open check(s) failed\n", g_failures);
        return 1;
    }
    printf("All Markdown open tests passed\n");
    return 0;
}
