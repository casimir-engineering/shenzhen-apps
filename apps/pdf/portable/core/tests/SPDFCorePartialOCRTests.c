// A PDF is "fully OCRed" only if EVERY page carries text.
//
// ocrmypdf skips a page with no raster image ("page has no images - skipping
// all processing on this page to avoid losing detail"), so a datasheet with a
// scanned cover and vector body pages came back with a text layer on page 1
// and nothing on pages 2..8 -- and the app, which asked only "is there any
// text?", called that a success. Measured on inductor-datasheet.pdf: the plain
// pass produced p1=1493 chars, p2..p8=0; the same run with --force-ocr
// produced text on all eight.
//
// spdf_mac_ocr_pages_without_text is the per-page counter that replaced the
// any-text check. It is a loop over spdf_extract_page_text_lines, so this
// suite pins the core behaviour that loop depends on: a page with text reports
// lines, a page without reports none, and the two can sit in one document.

#include "shenzhen_pdf_core.h"

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

// Page 1 draws a line of text; page 2 draws a vector rectangle and no text at
// all -- the shape of the pages ocrmypdf skips.
static int write_mixed_pdf(const char* path) {
    static const char* kTextPage = "BT /F1 24 Tf 20 100 Td (Hello OCR) Tj ET\n";
    static const char* kVectorPage = "0 0 1 rg 20 20 160 160 re f\n";
    FILE* file = fopen(path, "wb");
    if (!file) return 0;
    fprintf(file,
            "%%PDF-1.4\n"
            "1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"
            "2 0 obj<</Type/Pages/Kids[3 0 R 6 0 R]/Count 2>>endobj\n"
            "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R"
            "/Resources<</Font<</F1 5 0 R>>>>>>endobj\n"
            "4 0 obj<</Length %zu>>stream\n%sendstream\nendobj\n"
            "5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\n"
            "6 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 7 0 R>>endobj\n"
            "7 0 obj<</Length %zu>>stream\n%sendstream\nendobj\n"
            "trailer<</Root 1 0 R>>\n"
            "%%%%EOF\n",
            strlen(kTextPage), kTextPage, strlen(kVectorPage), kVectorPage);
    fclose(file);
    return 1;
}

// The counter the Mac layer runs, written against the same core calls.
static int pages_without_text(spdf_document* doc) {
    int empty = 0;
    int pages = spdf_page_count(doc);
    for (int page = 0; page < pages; ++page) {
        spdf_text_lines lines;
        char err[1024] = {0};
        memset(&lines, 0, sizeof(lines));
        if (!spdf_extract_page_text_lines(doc, page, &lines, err, sizeof(err))) return -1;
        if (lines.count <= 0) ++empty;
        spdf_free_text_lines(&lines);
    }
    return empty;
}

int main(void) {
    char path[] = "/tmp/spdf-partial-ocr-XXXXXX";
    EXPECT(mkstemp(path) != -1, "fixture path");
    EXPECT(write_mixed_pdf(path), "fixture writes");

    char err[1024] = {0};
    spdf_document* doc = spdf_open(path, err, sizeof(err));
    EXPECT(doc != NULL, "the mixed document opens (%s)", err);
    if (doc) {
        EXPECT(spdf_page_count(doc) == 2, "it has both pages");
        // The old check: satisfied by page 1 alone, which is the whole bug.
        EXPECT(spdf_document_has_text(doc, 0, err, sizeof(err)) == 1,
               "the any-text check says yes, though page 2 is empty");
        // The new one: the empty page is counted, so the app retries forced.
        EXPECT(pages_without_text(doc) == 1, "exactly one page has no text");
        spdf_close(doc);
    }

    remove(path);
    if (g_failure_count == 0) printf("SPDFCorePartialOCRTests passed\n");
    return g_failure_count == 0 ? 0 : 1;
}
