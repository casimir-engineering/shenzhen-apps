// spdf_document_has_text is the OCR pre-flight: it decides whether a PDF is
// scanned (OCR it) or already searchable (redo its OCR layer).
//
// It used to `return 1` from inside its fz_try as soon as a page had text.
// MuPDF pops the frame fz_try pushes in fz_catch, at the END of the construct,
// so that return leaked one exception frame per call -- and the frame's setjmp
// buffer pointed into a stack frame that had already gone, so the next throw on
// that context would longjmp into it. Measured on a real datasheet: calls 100
// and 200 fine, then "exception stack overflow!" and every later call failing.
// This suite calls it far past that point and expects the same answer every
// time, with no error.

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

// A minimal one-page PDF drawing one line of text. MuPDF repairs the missing
// xref, which is enough for text extraction and keeps the fixture readable.
static int write_text_pdf(const char* path) {
    static const char* kContent = "BT /F1 24 Tf 20 100 Td (Hello OCR) Tj ET\n";
    FILE* file = fopen(path, "wb");
    if (!file) return 0;
    fprintf(file,
            "%%PDF-1.4\n"
            "1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"
            "2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
            "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R"
            "/Resources<</Font<</F1 5 0 R>>>>>>endobj\n"
            "4 0 obj<</Length %zu>>stream\n%sendstream\nendobj\n"
            "5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\n"
            "trailer<</Root 1 0 R>>\n"
            "%%%%EOF\n",
            strlen(kContent), kContent);
    fclose(file);
    return 1;
}

// The same page with no text operators at all: a blank sheet.
static int write_blank_pdf(const char* path) {
    FILE* file = fopen(path, "wb");
    if (!file) return 0;
    fprintf(file,
            "%%PDF-1.4\n"
            "1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"
            "2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
            "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R>>endobj\n"
            "4 0 obj<</Length 0>>stream\n\nendstream\nendobj\n"
            "trailer<</Root 1 0 R>>\n"
            "%%%%EOF\n");
    fclose(file);
    return 1;
}

// Far more calls than MuPDF's exception stack is deep, so a frame leaked per
// call cannot hide: the pre-fix code failed around call 250.
#define kCallCount 400

static void expect_stable_answer(const char* path, int expected, const char* what) {
    char err[1024] = {0};
    spdf_document* doc = spdf_open(path, err, sizeof(err));
    EXPECT(doc != NULL, "%s opens (%s)", what, err);
    if (!doc) return;
    int first_bad_call = 0;
    int bad_value = 0;
    char bad_err[1024] = {0};
    for (int call = 1; call <= kCallCount; ++call) {
        err[0] = '\0';
        int answer = spdf_document_has_text(doc, 0, err, sizeof(err));
        if (answer != expected || err[0]) {
            if (!first_bad_call) {
                first_bad_call = call;
                bad_value = answer;
                snprintf(bad_err, sizeof(bad_err), "%s", err);
            }
        }
    }
    EXPECT(first_bad_call == 0, "%s answers %d on all %d calls (call %d gave %d, err [%s])", what, expected,
           kCallCount, first_bad_call, bad_value, bad_err);
    spdf_close(doc);
}

int main(void) {
    char text_path[] = "/tmp/spdf-has-text-XXXXXX";
    char blank_path[] = "/tmp/spdf-no-text-XXXXXX";
    EXPECT(mkstemp(text_path) != -1, "text fixture path");
    EXPECT(mkstemp(blank_path) != -1, "blank fixture path");
    EXPECT(write_text_pdf(text_path), "text fixture writes");
    EXPECT(write_blank_pdf(blank_path), "blank fixture writes");

    // The document WITH text is the leaking case: it is the one that used to
    // take the early return.
    expect_stable_answer(text_path, 1, "a PDF with text");
    // The one without text never took it, and must keep answering 0.
    expect_stable_answer(blank_path, 0, "a PDF without text");

    // A null document is not an error, just "no text".
    char err[256] = {0};
    EXPECT(spdf_document_has_text(NULL, 0, err, sizeof(err)) == 0, "a null document has no text");

    remove(text_path);
    remove(blank_path);
    if (g_failure_count == 0) printf("SPDFCoreTextDetectionTests passed\n");
    return g_failure_count == 0 ? 0 : 1;
}
