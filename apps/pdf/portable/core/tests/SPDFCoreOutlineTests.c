#include "mupdf/fitz.h"

#include "shenzhen_pdf_core.h"
#include "spdf_win_compat.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failure_count = 0;

#define EXPECT(condition, ...)                         \
    do {                                               \
        if (!(condition)) {                            \
            fprintf(stderr, "FAIL " __VA_ARGS__);      \
            fprintf(stderr, " [line %d]\n", __LINE__); \
            ++g_failure_count;                         \
        }                                              \
    } while (0)

static const char* kContainerXml =
    "<?xml version=\"1.0\"?>\n"
    "<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">\n"
    "  <rootfiles><rootfile full-path=\"OEBPS/content.opf\" "
    "media-type=\"application/oebps-package+xml\"/></rootfiles>\n"
    "</container>\n";

static const char* kPackageOpf =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\">\n"
    "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n"
    "    <dc:identifier id=\"book-id\">urn:uuid:spdf-outline-test</dc:identifier>\n"
    "    <dc:title>Outline Test</dc:title><dc:language>en</dc:language>\n"
    "  </metadata>\n"
    "  <manifest>\n"
    "    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"
    "    <item id=\"one\" href=\"one.xhtml\" media-type=\"application/xhtml+xml\"/>\n"
    "    <item id=\"two\" href=\"two.xhtml\" media-type=\"application/xhtml+xml\"/>\n"
    "  </manifest>\n"
    "  <spine><itemref idref=\"one\"/><itemref idref=\"two\"/></spine>\n"
    "</package>\n";

static const char* kNavigationXhtml =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">\n"
    "<head><title>Contents</title></head><body><nav epub:type=\"toc\"><ol>\n"
    "  <li><a href=\"one.xhtml#first\">First chapter</a><ol>\n"
    "    <li><a href=\"one.xhtml#later\">Later section</a></li>\n"
    "  </ol></li>\n"
    "  <li><a href=\"two.xhtml#second\">Second chapter</a></li>\n"
    "  <li><a href=\"missing.xhtml#nowhere\">Missing chapter</a></li>\n"
    "  <li><a href=\"https://example.com/\">External site</a></li>\n"
    "</ol></nav></body></html>\n";

static const char* kChapterOneXhtml =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>One</title></head><body>\n"
    "<h1 id=\"first\">First chapter</h1><p>Opening text.</p>\n"
    "<h2 id=\"later\">Later section</h2><p>More text.</p>\n"
    "</body></html>\n";

static const char* kChapterTwoXhtml =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Two</title></head><body>\n"
    "<h1 id=\"second\">Second chapter</h1><p>Closing text.</p>\n"
    "</body></html>\n";

static void write_zip_text(fz_context* ctx, fz_zip_writer* zip, const char* name, const char* text, int compress) {
    fz_buffer* buffer = NULL;

    fz_var(buffer);
    fz_try(ctx) {
        buffer = fz_new_buffer_from_copied_data(ctx, (const unsigned char*)text, strlen(text));
        fz_write_zip_entry(ctx, zip, name, buffer, compress);
    }
    fz_always(ctx) {
        fz_drop_buffer(ctx, buffer);
    }
    fz_catch(ctx) {
        fz_rethrow(ctx);
    }
}

static int create_epub_fixture(const char* path) {
    int ok = 1;
    fz_context* ctx = fz_new_context(NULL, NULL, FZ_STORE_UNLIMITED);
    fz_zip_writer* zip = NULL;

    if (!ctx) return 0;
    fz_var(zip);
    fz_try(ctx) {
        zip = fz_new_zip_writer(ctx, path);
        write_zip_text(ctx, zip, "mimetype", "application/epub+zip", 0);
        write_zip_text(ctx, zip, "META-INF/container.xml", kContainerXml, 1);
        write_zip_text(ctx, zip, "OEBPS/content.opf", kPackageOpf, 1);
        write_zip_text(ctx, zip, "OEBPS/nav.xhtml", kNavigationXhtml, 1);
        write_zip_text(ctx, zip, "OEBPS/one.xhtml", kChapterOneXhtml, 1);
        write_zip_text(ctx, zip, "OEBPS/two.xhtml", kChapterTwoXhtml, 1);
        fz_close_zip_writer(ctx, zip);
    }
    fz_catch(ctx) {
        fprintf(stderr, "Could not create EPUB fixture: %s\n", fz_caught_message(ctx));
        ok = 0;
    }
    fz_drop_zip_writer(ctx, zip);
    fz_drop_context(ctx);
    return ok;
}

static const spdf_outline_item* find_outline_item(const spdf_outline* outline, const char* title) {
    for (int i = 0; i < outline->count; ++i) {
        if (strcmp(outline->items[i].title, title) == 0) return &outline->items[i];
    }
    return NULL;
}

int main(void) {
    char temp_dir[SPDF_COMPAT_PATH_MAX];
    char epub_path[SPDF_COMPAT_PATH_MAX];
    char err[512];
    spdf_document* doc = NULL;
    spdf_outline outline = {0};

    if (!spdf_compat_make_temp_dir(temp_dir, sizeof(temp_dir), "spdf-core-outline-tests.")) {
        perror("mkdtemp");
        return 2;
    }
    snprintf(epub_path, sizeof(epub_path), "%s" SPDF_PATH_SEP_STR "outline.epub", temp_dir);
    if (!create_epub_fixture(epub_path)) {
        spdf_compat_rmdir(temp_dir);
        return 2;
    }

    doc = spdf_open(epub_path, err, sizeof(err));
    EXPECT(doc != NULL, "open generated EPUB: %s", err);
    if (doc) {
        EXPECT(spdf_page_count(doc) == 2, "generated EPUB has 2 pages, got %d", spdf_page_count(doc));
        EXPECT(spdf_load_outline(doc, &outline, err, sizeof(err)), "load generated EPUB outline: %s", err);
    }

    EXPECT(outline.count == 5, "generated EPUB outline has 5 entries, got %d", outline.count);
    if (outline.count > 0) {
        const spdf_outline_item* first = find_outline_item(&outline, "First chapter");
        const spdf_outline_item* later = find_outline_item(&outline, "Later section");
        const spdf_outline_item* second = find_outline_item(&outline, "Second chapter");
        const spdf_outline_item* missing = find_outline_item(&outline, "Missing chapter");
        const spdf_outline_item* external = find_outline_item(&outline, "External site");

        EXPECT(first != NULL, "first chapter outline entry exists");
        EXPECT(later != NULL, "nested section outline entry exists");
        EXPECT(second != NULL, "second chapter outline entry exists");
        EXPECT(missing != NULL, "missing-target outline entry exists");
        EXPECT(external != NULL, "external outline entry exists");
        if (first) EXPECT(first->page_index == 0, "first chapter resolves to page 0, got %d", first->page_index);
        if (later) {
            EXPECT(later->page_index == 0, "nested section resolves to page 0, got %d", later->page_index);
            EXPECT(later->level == 1, "nested section preserves level 1, got %d", later->level);
        }
        if (second)
            EXPECT(second->page_index == 1, "second chapter resolves to flattened page 1, got %d", second->page_index);
        if (missing) EXPECT(missing->page_index == -1, "missing target stays unresolved, got %d", missing->page_index);
        if (external)
            EXPECT(external->page_index == -1, "external target stays unresolved, got %d", external->page_index);
    }

    spdf_free_outline(&outline);
    spdf_close(doc);
    spdf_compat_unlink(epub_path);
    spdf_compat_rmdir(temp_dir);

    if (g_failure_count != 0) {
        fprintf(stderr, "%d core outline test(s) failed\n", g_failure_count);
        return 1;
    }
    printf("All core outline tests passed\n");
    return 0;
}
