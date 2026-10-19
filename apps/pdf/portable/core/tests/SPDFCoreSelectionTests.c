#include "shenzhen_pdf_core.h"
#include "spdf_win_compat.h"

#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

#define EXPECT(condition, ...)                         \
    do {                                               \
        if (!(condition)) {                            \
            fprintf(stderr, "FAIL " __VA_ARGS__);      \
            fprintf(stderr, " [line %d]\n", __LINE__); \
            ++failures;                                \
        }                                              \
    } while (0)

static int write_object(FILE* file, long* offsets, int number, const char* body) {
    offsets[number] = ftell(file);
    return fprintf(file, "%d 0 obj\n%s\nendobj\n", number, body) > 0;
}

static int write_stream(FILE* file, long* offsets, int number, const char* data, size_t len) {
    offsets[number] = ftell(file);
    if (fprintf(file, "%d 0 obj\n<< /Length %zu >>\nstream\n", number, len) < 0) return 0;
    if (fwrite(data, 1, len, file) != len) return 0;
    return fprintf(file, "\nendstream\nendobj\n") > 0;
}

static int create_fixture(const char* path) {
    static const char page_one[] =
        "BT /F1 18 Tf 72 700 Td (Alpha paragraph) Tj 0 -24 Td (continues here) Tj ET\n"
        "BT /F1 18 Tf 72 610 Td (Second block) Tj ET\n"
        "BT /F1 18 Tf 330 700 Td (Right column) Tj ET\n"
        "BT /F1 16 Tf 3 Tr 72 500 Td (OCRLEFT) Tj 258 0 Td (OCRRIGHT) Tj 0 Tr ET\n"
        "q 120 0 0 80 330 350 cm BI /W 2 /H 2 /CS /RGB /BPC 8 /F /AHx ID\n"
        "FF000000FF000000FFFFFFFF> EI Q\n"
        "BT /F1 16 Tf 0 1 -1 0 540 300 Tm (ROTATED) Tj ET\n"
        "BT /F1 16 Tf 72 250 Td (GEOMETRY) Tj 0 Tz (X) Tj ET\n";
    char* page_two = NULL;
    size_t capacity = 32768;
    size_t length = 0;
    long offsets[8] = {0};
    long xref;
    FILE* file = NULL;
    int ok = 0;
    int i;

    page_two = (char*)malloc(capacity);
    if (!page_two) return 0;
    for (i = 0; i < 300; ++i) {
        int written =
            snprintf(page_two + length, capacity - length, "BT /F1 8 Tf 36 %d Td (LONG%03d) Tj ET\n", 3950 - i * 12, i);
        if (written < 0 || (size_t)written >= capacity - length) goto done;
        length += (size_t)written;
    }

    file = fopen(path, "wb");
    if (!file) goto done;
    if (fprintf(file, "%%PDF-1.7\n%%\342\343\317\323\n") < 0) goto done;
    if (!write_object(file, offsets, 1, "<< /Type /Catalog /Pages 2 0 R >>")) goto done;
    if (!write_object(file, offsets, 2, "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 >>")) goto done;
    if (!write_object(file, offsets, 3,
                      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 800] "
                      "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>"))
        goto done;
    if (!write_object(file, offsets, 4, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")) goto done;
    if (!write_stream(file, offsets, 5, page_one, sizeof(page_one) - 1)) goto done;
    if (!write_object(file, offsets, 6,
                      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 4000] "
                      "/Resources << /Font << /F1 4 0 R >> >> /Contents 7 0 R >>"))
        goto done;
    if (!write_stream(file, offsets, 7, page_two, length)) goto done;
    xref = ftell(file);
    if (fprintf(file, "xref\n0 8\n0000000000 65535 f \n") < 0) goto done;
    for (i = 1; i < 8; ++i)
        if (fprintf(file, "%010ld 00000 n \n", offsets[i]) < 0) goto done;
    if (fprintf(file, "trailer\n<< /Size 8 /Root 1 0 R >>\nstartxref\n%ld\n%%%%EOF\n", xref) < 0) goto done;
    ok = 1;

done:
    if (file && fclose(file) != 0) ok = 0;
    free(page_two);
    return ok;
}

static spdf_rect find_text(spdf_document* doc, int page, const char* text) {
    spdf_rect rect = {0};
    char err[256];
    int count = spdf_search_page_rects(doc, page, text, &rect, 1, err, sizeof(err));
    EXPECT(count == 1, "find '%s' on page %d: count=%d err=%s", text, page, count, err);
    return rect;
}

static float center_y(spdf_rect rect) {
    return (rect.y0 + rect.y1) * 0.5f;
}

static void expect_valid_geometry(const spdf_text_selection* selection) {
    int i;
    for (i = 0; i < selection->rect_count; ++i) {
        const spdf_rect r = selection->rects[i];
        EXPECT(isfinite(r.x0) && isfinite(r.y0) && isfinite(r.x1) && isfinite(r.y1), "selection rectangle %d is finite",
               i);
        EXPECT(r.x1 > r.x0 && r.y1 > r.y0, "selection rectangle %d is non-empty", i);
    }
}

static int find_glyph_hit(spdf_document* doc, int page, spdf_rect bounds, float* x_out, float* y_out) {
    char err[256];
    int row;
    int column;

    for (row = 1; row < 16; ++row) {
        for (column = 1; column < 16; ++column) {
            spdf_text_selection probe = {0};
            float x = bounds.x0 + (bounds.x1 - bounds.x0) * (float)column / 16.0f;
            float y = bounds.y0 + (bounds.y1 - bounds.y0) * (float)row / 16.0f;
            spdf_selection_status status =
                spdf_select_text(doc, page, SPDF_SELECTION_WORD, x, y, 0, 0, &probe, err, sizeof(err));
            if (status == SPDF_SELECTION_OK) {
                spdf_free_text_selection(&probe);
                *x_out = x;
                *y_out = y;
                return 1;
            }
            EXPECT(status != SPDF_SELECTION_ERROR, "glyph probe does not error: %s", err);
        }
    }
    return 0;
}

static void test_word_and_block(spdf_document* doc) {
    char err[256];
    spdf_text_selection selection = {0};
    spdf_rect alpha = find_text(doc, 0, "Alpha");
    spdf_selection_status status;
    float hit_x = 0;
    float hit_y = 0;

    EXPECT(find_glyph_hit(doc, 0, alpha, &hit_x, &hit_y), "find an actual glyph inside Alpha search bounds");

    status = spdf_select_text(doc, 0, SPDF_SELECTION_WORD, hit_x, hit_y, 0, 0, &selection, err, sizeof(err));
    EXPECT(status == SPDF_SELECTION_OK, "word selection succeeds: %s", err);
    EXPECT(selection.text && strcmp(selection.text, "Alpha") == 0, "word selection text is Alpha, got '%s'",
           selection.text ? selection.text : "(null)");
    EXPECT(selection.rect_count > 0, "word selection has geometry");
    expect_valid_geometry(&selection);
    spdf_free_text_selection(&selection);

    status = spdf_select_text(doc, 0, SPDF_SELECTION_BLOCK, hit_x, hit_y, 0, 0, &selection, err, sizeof(err));
    EXPECT(status == SPDF_SELECTION_OK, "block selection succeeds: %s", err);
    EXPECT(selection.text && strstr(selection.text, "Alpha paragraph"), "block contains first line");
    EXPECT(selection.text && strstr(selection.text, "continues here"), "block contains continuation line");
    EXPECT(!selection.text || !strstr(selection.text, "Second block"), "block excludes adjacent paragraph");
    EXPECT(!selection.text || !strstr(selection.text, "Right column"), "block excludes adjacent column");
    expect_valid_geometry(&selection);
    spdf_free_text_selection(&selection);
}

static void test_gaps_and_rotation(spdf_document* doc) {
    char err[256];
    spdf_text_selection selection = {0};
    spdf_rect left = find_text(doc, 0, "OCRLEFT");
    spdf_rect right = find_text(doc, 0, "OCRRIGHT");
    spdf_rect rotated = find_text(doc, 0, "ROTATED");
    spdf_rect geometry = find_text(doc, 0, "GEOMETRY");
    float gap_x = (left.x1 + right.x0) * 0.5f;
    float gap_y = center_y(left);
    float rotated_x = 0;
    float rotated_y = 0;

    EXPECT(spdf_select_text(doc, 0, SPDF_SELECTION_WORD, gap_x, gap_y, 0, 0, &selection, err, sizeof(err)) ==
               SPDF_SELECTION_NONE,
           "OCR-style gap returns NONE");
    EXPECT(selection.text == NULL && selection.rects == NULL, "NONE leaves no allocated result");
    EXPECT(spdf_select_text(doc, 0, SPDF_SELECTION_BLOCK, 390, 410, 0, 0, &selection, err, sizeof(err)) ==
               SPDF_SELECTION_NONE,
           "image-only region returns NONE");

    EXPECT(find_glyph_hit(doc, 0, rotated, &rotated_x, &rotated_y), "find an actual glyph in rotated text bounds");
    EXPECT(spdf_select_text(doc, 0, SPDF_SELECTION_WORD, rotated_x, rotated_y, 0, 0, &selection, err, sizeof(err)) ==
               SPDF_SELECTION_OK,
           "rotated word selection succeeds: %s", err);
    EXPECT(selection.text && strstr(selection.text, "ROTATED"), "rotated selection returns text");
    expect_valid_geometry(&selection);
    spdf_free_text_selection(&selection);

    EXPECT(find_glyph_hit(doc, 0, geometry, &rotated_x, &rotated_y), "find glyph in degenerate-geometry block");
    EXPECT(spdf_select_text(doc, 0, SPDF_SELECTION_BLOCK, rotated_x, rotated_y, 0, 0, &selection, err, sizeof(err)) ==
               SPDF_SELECTION_OK,
           "degenerate-geometry block remains selectable: %s", err);
    if (selection.text && strstr(selection.text, "X"))
        EXPECT(selection.flags & SPDF_SELECTION_GEOMETRY_INCOMPLETE,
               "preserved zero-width glyph marks geometry incomplete");
    expect_valid_geometry(&selection);
    spdf_free_text_selection(&selection);
}

static void test_dynamic_range(spdf_document* doc) {
    char err[256];
    char* legacy_text = NULL;
    spdf_text_selection selection = {0};
    spdf_rect first = find_text(doc, 1, "LONG000");
    spdf_rect last = find_text(doc, 1, "LONG299");
    spdf_rect legacy_rects[400];
    spdf_selection_status status;
    int legacy_count;

    status = spdf_select_text(doc, 1, SPDF_SELECTION_RANGE, first.x0 - 1, center_y(first), last.x1 + 1, center_y(last),
                              &selection, err, sizeof(err));
    EXPECT(status == SPDF_SELECTION_OK,
           "large range selection succeeds: %s first=(%.1f %.1f %.1f %.1f) last=(%.1f %.1f %.1f %.1f)", err, first.x0,
           first.y0, first.x1, first.y1, last.x0, last.y0, last.x1, last.y1);
    EXPECT(selection.text && strstr(selection.text, "LONG000") && strstr(selection.text, "LONG299"),
           "large range includes both endpoints");
    EXPECT(selection.rect_count > 256, "typed range is not truncated at 256 rects, got %d", selection.rect_count);
    expect_valid_geometry(&selection);
    spdf_free_text_selection(&selection);

    legacy_count = spdf_select_page_text(doc, 1, first.x0 - 1, center_y(first), last.x1 + 1, center_y(last),
                                         legacy_rects, 400, &legacy_text, err, sizeof(err));
    EXPECT(legacy_count > 256, "legacy wrapper honors caller capacity beyond 256, got %d", legacy_count);
    EXPECT(legacy_text && strstr(legacy_text, "LONG299"), "legacy wrapper still returns complete text");
    spdf_free_string(legacy_text);
}

static void test_errors(spdf_document* doc) {
    char err[256];
    spdf_text_selection selection;
    memset(&selection, 0xA5, sizeof(selection));
    EXPECT(spdf_select_text(doc, 99, SPDF_SELECTION_WORD, 0, 0, 0, 0, &selection, err, sizeof(err)) ==
               SPDF_SELECTION_ERROR,
           "invalid page returns ERROR");
    EXPECT(err[0] != 0, "ERROR supplies a message");
    EXPECT(selection.text == NULL && selection.rects == NULL && selection.rect_count == 0 && selection.flags == 0,
           "ERROR zeroes the output");
}

int main(void) {
    char temp_dir[SPDF_COMPAT_PATH_MAX];
    char path[SPDF_COMPAT_PATH_MAX];
    char err[512];
    spdf_document* doc;

    if (!spdf_compat_make_temp_dir(temp_dir, sizeof(temp_dir), "spdf-core-selection-tests.")) {
        perror("mkdtemp");
        return 2;
    }
    snprintf(path, sizeof(path), "%s" SPDF_PATH_SEP_STR "selection.pdf", temp_dir);
    if (!create_fixture(path)) {
        fprintf(stderr, "Could not create selection fixture\n");
        spdf_compat_rmdir(temp_dir);
        return 2;
    }
    doc = spdf_open(path, err, sizeof(err));
    if (!doc) {
        fprintf(stderr, "Could not open selection fixture: %s\n", err);
        spdf_compat_unlink(path);
        spdf_compat_rmdir(temp_dir);
        return 2;
    }

    EXPECT(spdf_page_count(doc) == 2, "fixture has two pages");
    test_word_and_block(doc);
    test_gaps_and_rotation(doc);
    test_dynamic_range(doc);
    test_errors(doc);

    spdf_close(doc);
    spdf_compat_unlink(path);
    spdf_compat_rmdir(temp_dir);
    if (failures) {
        fprintf(stderr, "%d core selection test(s) failed\n", failures);
        return 1;
    }
    printf("All core selection tests passed\n");
    return 0;
}
