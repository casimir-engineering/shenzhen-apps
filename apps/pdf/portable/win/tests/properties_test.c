/* properties_test.c -- the document-properties MODEL: which rows appear, what
 * they say, what the Copy All transcript looks like, and what collecting them
 * costs.
 *
 * WHY THE MODEL AND NOT THE DIALOG. spdf_win_properties_collect() takes a
 * document and produces (section, label, value) strings with no HWND, no COM
 * and no message loop; spdf_win_properties_show() then draws them. Everything
 * worth being wrong about is in the first half, and the first half needs no
 * desktop -- which is why it is a separate translation unit.
 *
 * THE VALUE FORMATTING IS NOT TESTED HERE. "2.4 MB (2,437,120 bytes)" and
 * "210 x 297 mm" are spdf_win_props_format.h's business, checked byte for byte
 * by props_format_test.c and compared against the GTK original by
 * props_differential.c. What this suite checks is the ASSEMBLY: that the panel
 * asks for the right things, omits what both other frontends omit, and orders
 * the groups the way they do.
 *
 * NO MAGIC NUMBERS FROM THE FIXTURES where the fixture could be regenerated:
 * the file size is compared against what the formatter makes of the file's
 * ACTUAL size on disk, so this suite tests the plumbing rather than pinning a
 * byte count that make_fixture_pdf.py could legitimately change.
 */
/* spdf-test-sources: portable/win/src/spdf_win_properties.cpp portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c */
/* spdf-test-args: portable/win/tests/fixtures/golden.pdf portable/win/tests/fixtures/outline.pdf */
/* spdf-test-needs: mupdf */
#include <windows.h>

#include "shenzhen_pdf_core.h"
#include "spdf_win_properties.h"
#include "spdf_win_props_format.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                                     \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

static const char* row_value(const spdf_win_properties* p, const char* section, const char* label) {
    int i;
    for (i = 0; i < p->count; ++i)
        if (strcmp(p->rows[i].section, section) == 0 && strcmp(p->rows[i].label, label) == 0) return p->rows[i].value;
    return NULL;
}

#define CHECK_ROW(p, section, label, want)                                                                             \
    do {                                                                                                               \
        const char* got = row_value((p), (section), (label));                                                          \
        ++g_checks;                                                                                                    \
        if (!got || strcmp(got, (want)) != 0) {                                                                        \
            printf("FAIL %s:%d: %s/%s = \"%s\", want \"%s\"\n", __FILE__, __LINE__, (section), (label),                 \
                   got ? got : "(absent)", (want));                                                                    \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

static spdf_document* open_fixture(const char* path, wchar_t* wide, int wide_cap) {
    char err[512] = "";
    spdf_document* doc = spdf_open(path, err, sizeof(err));
    if (!doc) {
        printf("FAIL could not open %s: %s\n", path, err);
        ++g_failures;
        return NULL;
    }
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, wide_cap);
    return doc;
}

/* --- the rows ------------------------------------------------------------- */

static void test_golden(const char* path) {
    wchar_t wide[MAX_PATH];
    spdf_document* doc = open_fixture(path, wide, MAX_PATH);
    spdf_win_properties props;
    WIN32_FILE_ATTRIBUTE_DATA attr;
    char expected_size[64];

    if (!doc) return;
    CHECK(spdf_win_properties_collect(doc, wide, 0, -1, -1, &props) == props.count);
    CHECK(props.count > 0);

    /* Document. golden.pdf carries no Info dictionary, and a metadata row with
     * an empty value is OMITTED -- the Mac rule, which GTK also follows. A
     * panel full of blank labels tells the reader nothing. */
    CHECK(row_value(&props, "Document", "Title") == NULL);
    CHECK(row_value(&props, "Document", "Author") == NULL);
    CHECK(row_value(&props, "Document", "Producer") == NULL);
    /* Security is always shown, even when there is nothing to say. MuPDF says
     * "None" for an unencrypted PDF and both originals blank it so the summary
     * reads "Not encrypted" rather than "Encrypted - None". */
    CHECK_ROW(&props, "Document", "Security", "Not encrypted");

    /* File. The size string is what the formatter makes of the file's actual
     * size, so this checks the plumbing rather than pinning a byte count. */
    CHECK(GetFileAttributesExW(wide, GetFileExInfoStandard, &attr));
    spdf_win_props_format_file_size(((unsigned long long)attr.nFileSizeHigh << 32) | attr.nFileSizeLow, expected_size,
                                    sizeof(expected_size));
    CHECK_ROW(&props, "File", "Size", expected_size);
    CHECK(row_value(&props, "File", "Location") != NULL);
    CHECK(row_value(&props, "File", "Format") != NULL);
    CHECK(strncmp(row_value(&props, "File", "Format"), "PDF", 3) == 0);

    /* Statistics. golden.pdf is 2 pages of 200 x 260 pt. */
    CHECK_ROW(&props, "Statistics", "Pages", "2");
    CHECK_ROW(&props, "Statistics", "Page 1 size",
              "71 \xc3\x97 92 mm \xc2\xb7 2.78 \xc3\x97 3.61 in \xc2\xb7 200 \xc3\x97 260 pt");
    CHECK_ROW(&props, "Statistics", "Table of contents", "None");
    CHECK_ROW(&props, "Statistics", "Annotations", "None");

    /* Dates: no PDF metadata dates, so only the on-disk pair appears. */
    CHECK(row_value(&props, "Dates", "Created") == NULL);
    CHECK(row_value(&props, "Dates", "Created (on disk)") != NULL);

    /* A page index outside the document contributes no size row rather than a
     * wrong one. Like both originals, the panel reports the CURRENT page's
     * size and never a survey -- outline.pdf's foldout is why that is not a
     * simplification worth making. */
    CHECK(spdf_win_properties_collect(doc, wide, 99, 0, 0, &props) > 0);
    CHECK(row_value(&props, "Statistics", "Page 100 size") == NULL);
    CHECK(row_value(&props, "Statistics", "Page 1 size") == NULL);

    spdf_close(doc);
}

static void test_outline(const char* path) {
    wchar_t wide[MAX_PATH];
    spdf_document* doc = open_fixture(path, wide, MAX_PATH);
    spdf_win_properties props;

    if (!doc) return;
    /* -1 asks the panel to load the counts itself, which is what a caller with
     * no sidebar open does. outline.pdf has an outline. */
    CHECK(spdf_win_properties_collect(doc, wide, 2, -1, -1, &props) > 0);
    CHECK_ROW(&props, "Statistics", "Pages", "4");
    CHECK(row_value(&props, "Statistics", "Table of contents") != NULL);
    CHECK(strstr(row_value(&props, "Statistics", "Table of contents"), "entries") != NULL);

    /* Page 3 (index 2) is the 1224 pt foldout (make_outline_fixture.py:42),
     * and the panel reports THAT page because it is the page the reader is on.
     * Reporting "the document's page size" would have no answer here, which is
     * why neither original attempts one. */
    CHECK(row_value(&props, "Statistics", "Page 3 size") != NULL);
    CHECK(row_value(&props, "Statistics", "Page 3 size") &&
          strstr(row_value(&props, "Statistics", "Page 3 size"), "1224 ") != NULL);

    /* A cached count from the caller is used verbatim -- the sidebar and the
     * annotation layer already hold these, and reloading them for a panel
     * would be work the reader did not ask for. */
    CHECK(spdf_win_properties_collect(doc, wide, 0, 0, 7, &props) > 0);
    CHECK_ROW(&props, "Statistics", "Table of contents", "None");
    CHECK_ROW(&props, "Statistics", "Annotations", "7");

    spdf_close(doc);
}

/* --- the transcript ------------------------------------------------------- */

static void test_transcript(const char* path) {
    wchar_t wide[MAX_PATH];
    spdf_document* doc = open_fixture(path, wide, MAX_PATH);
    spdf_win_properties props;
    char text[8192];
    int n;

    if (!doc) return;
    CHECK(spdf_win_properties_collect(doc, wide, 0, 0, 0, &props) > 0);
    n = spdf_win_properties_transcript(&props, text, sizeof(text));
    CHECK(n > 0);
    CHECK((int)strlen(text) == n);

    /* "Section\n  Label: Value\n", groups separated by a blank line -- byte for
     * byte the format macOS copies and GTK copies, so a properties dump pasted
     * into a bug report reads the same whichever app produced it. */
    CHECK(strncmp(text, "Document\n  Security: Not encrypted\n", 34) == 0);
    CHECK(strstr(text, "\n\nFile\n  Location: ") != NULL);
    CHECK(strstr(text, "\n\nStatistics\n  Pages: 2\n") != NULL);
    /* No leading blank line: the first group starts the transcript. */
    CHECK(text[0] != '\n');

    /* A buffer too small truncates cleanly instead of running off the end, and
     * the RETURNED LENGTH still describes the string that is actually there --
     * _snprintf_s with _TRUNCATE returns -1 while leaving a valid partial
     * string, so a writer that trusted that return value would hand back a
     * length pointing into the middle of the truncated line. */
    n = spdf_win_properties_transcript(&props, text, 12);
    CHECK(n >= 0 && n < 12);
    CHECK((int)strlen(text) == n);
    CHECK(text[n] == '\0');

    spdf_close(doc);
}

/* --- what it costs -------------------------------------------------------- */

/* THE PORT'S STANDING SPEED RULE, ASSERTED RATHER THAN CLAIMED: a feature must
 * cost nothing for documents that do not use it, and nothing new may run on the
 * launch path. Opening the properties panel must not RENDER anything -- macOS's
 * panel additionally walks every page for a word count, on a worker, and this
 * port deliberately omits that row for exactly this reason (see
 * spdf_win_properties.h).
 *
 * spdf_last_render_stats() is the instrument: it reports how the LAST render on
 * this document got its pixels, so a collect that rendered would move it. The
 * check is paired with its own negative -- a real render afterwards must move
 * it -- because otherwise a stats function that never reported anything would
 * make this pass forever. */
static void test_collect_renders_nothing(const char* path) {
    wchar_t wide[MAX_PATH];
    spdf_document* doc = open_fixture(path, wide, MAX_PATH);
    spdf_win_properties props;
    spdf_render_stats before;
    spdf_render_stats after;
    spdf_bitmap bitmap;
    char err[512] = "";

    if (!doc) return;
    before = spdf_last_render_stats(doc);
    CHECK(before.used_list == 0 && before.built_list == 0 && before.build_ms == 0.0);

    CHECK(spdf_win_properties_collect(doc, wide, 0, -1, -1, &props) > 0);
    after = spdf_last_render_stats(doc);
    CHECK(after.used_list == before.used_list);
    CHECK(after.built_list == before.built_list);
    CHECK(after.build_ms == before.build_ms);

    /* The negative: a real render DOES move the instrument, so the check above
     * is not passing because the instrument is dead. */
    memset(&bitmap, 0, sizeof(bitmap));
    CHECK(spdf_render_page_rgba_opts(doc, 0, 1.0f, SPDF_RENDER_USE_PAGE_LIST, NULL, &bitmap, err, sizeof(err)));
    after = spdf_last_render_stats(doc);
    CHECK(after.used_list != 0 || after.built_list != 0);
    if (bitmap.rgba) spdf_free_bitmap(&bitmap);

    spdf_close(doc);
}

static void test_refusals(void) {
    spdf_win_properties props;
    char text[64];

    CHECK(spdf_win_properties_collect(NULL, L"x.pdf", 0, 0, 0, &props) == 0);
    CHECK(props.count == 0);
    CHECK(spdf_win_properties_transcript(&props, text, sizeof(text)) == 0);
    CHECK(spdf_win_properties_transcript(NULL, text, sizeof(text)) == 0);
    CHECK(text[0] == '\0');
}

int main(int argc, char** argv) {
    const char* golden = argc > 1 ? argv[1] : "portable/win/tests/fixtures/golden.pdf";
    const char* outline = argc > 2 ? argv[2] : "portable/win/tests/fixtures/outline.pdf";

    test_golden(golden);
    test_outline(outline);
    test_transcript(golden);
    test_collect_renders_nothing(golden);
    test_refusals();

    printf("properties_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
