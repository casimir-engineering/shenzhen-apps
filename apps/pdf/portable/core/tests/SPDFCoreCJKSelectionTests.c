#include "shenzhen_pdf_core.h"
#include "spdf_win_compat.h"
#include "spdf_selection.h"

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

#define TIAN "\xe5\xa4\xa9"
#define XIAN "\xe7\xba\xbf"
#define DAN "\xe5\xbc\xb9"
#define PIAN "\xe7\x89\x87"
#define YOU "\xe6\x9c\x89"
#define SI "\xe5\x8f\xb8"
#define LE "\xe4\xba\x86"
#define DUN "\xe3\x80\x81"

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

/* Mimics an OCRmyPDF/Tesseract text layer: an invisible (3 Tr) glyphless
   Type3 font whose empty glyph outlines collapse accurate stext quads onto
   the baseline, with ToUnicode carrying the recognized text. Codes:
   A=天 B=线 C=弹 D=片 E=有 F=限 G=公 H=司 I=了 J=、 and identity for L 9 . */
static int create_cjk_fixture(const char* path) {
    static const char content[] =
        "BT /F2 18 Tf 3 Tr 72 700 Td (ABCD L9.9) Tj 0 Tr ET\n"
        "BT /F2 18 Tf 3 Tr 72 650 Td (ABL9.9) Tj 0 Tr ET\n"
        "BT /F2 30 Tf 3 Tr 72 600 Td (EFG) Tj 0 Tr ET\n"
        "BT /F2 14 Tf 3 Tr 200 596 Td (EFGH) Tj 0 Tr ET\n"
        "BT /F2 18 Tf 3 Tr 72 560 Td (AJB) Tj 0 Tr ET\n"
        "BT /F2 14 Tf 3 Tr 0 1 -1 0 540 200 Tm (I) Tj 0 Tr ET\n";
    static const char empty_glyph[] = "500 0 d0";
    static const char tounicode[] =
        "/CIDInit /ProcSet findresource begin\n"
        "12 dict begin\n"
        "begincmap\n"
        "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
        "/CMapName /Adobe-Identity-UCS def\n"
        "/CMapType 2 def\n"
        "1 begincodespacerange\n<00> <FF>\nendcodespacerange\n"
        "13 beginbfchar\n"
        "<41> <5929>\n<42> <7EBF>\n<43> <5F39>\n<44> <7247>\n"
        "<45> <6709>\n<46> <9650>\n<47> <516C>\n<48> <53F8>\n"
        "<49> <4E86>\n<4A> <3001>\n"
        "<4C> <004C>\n<39> <0039>\n<2E> <002E>\n"
        "endbfchar\n"
        "endcmap\n"
        "CMapName currentdict /CMap defineresource pop\n"
        "end\nend\n";
    long offsets[8] = {0};
    long xref;
    FILE* file;
    int ok = 0;
    int i;

    file = fopen(path, "wb");
    if (!file) return 0;
    if (fprintf(file, "%%PDF-1.7\n%%\342\343\317\323\n") < 0) goto done;
    if (!write_object(file, offsets, 1, "<< /Type /Catalog /Pages 2 0 R >>")) goto done;
    if (!write_object(file, offsets, 2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")) goto done;
    if (!write_object(file, offsets, 3,
                      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 800] "
                      "/Resources << /Font << /F2 4 0 R >> >> /Contents 5 0 R >>"))
        goto done;
    if (!write_object(file, offsets, 4,
                      "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 500 1000] "
                      "/FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /empty 7 0 R >> "
                      "/Encoding << /Type /Encoding /Differences [32 /empty 46 /empty 57 /empty "
                      "65 /empty /empty /empty /empty /empty /empty /empty /empty /empty /empty 76 /empty] >> "
                      "/FirstChar 32 /LastChar 76 /Widths [500 0 0 0 0 0 0 0 0 0 0 0 0 0 "
                      "500 0 0 0 0 0 0 0 0 0 0 500 0 0 0 0 0 0 0 "
                      "500 500 500 500 500 500 500 500 500 500 0 500] /ToUnicode 6 0 R >>"))
        goto done;
    if (!write_stream(file, offsets, 5, content, sizeof(content) - 1)) goto done;
    if (!write_stream(file, offsets, 6, tounicode, sizeof(tounicode) - 1)) goto done;
    if (!write_stream(file, offsets, 7, empty_glyph, sizeof(empty_glyph) - 1)) goto done;
    xref = ftell(file);
    if (fprintf(file, "xref\n0 8\n0000000000 65535 f \n") < 0) goto done;
    for (i = 1; i < 8; ++i)
        if (fprintf(file, "%010ld 00000 n \n", offsets[i]) < 0) goto done;
    if (fprintf(file, "trailer\n<< /Size 8 /Root 1 0 R >>\nstartxref\n%ld\n%%%%EOF\n", xref) < 0) goto done;
    ok = 1;
done:
    if (file && fclose(file) != 0) ok = 0;
    return ok;
}

static spdf_rect find_text(spdf_document* doc, const char* text) {
    spdf_rect rect = {0};
    char err[256];
    int count = spdf_search_page_rects(doc, 0, text, &rect, 1, err, sizeof(err));
    EXPECT(count >= 1, "find '%s': count=%d err=%s", text, count, err);
    return rect;
}

static void expect_word_at(spdf_document* doc, float x, float y, const char* expected, const char* label) {
    char err[256];
    spdf_text_selection sel = {0};
    spdf_selection_status status = spdf_select_text(doc, 0, SPDF_SELECTION_WORD, x, y, 0, 0, &sel, err, sizeof(err));
    EXPECT(status == SPDF_SELECTION_OK, "%s: word selection succeeds at (%.1f,%.1f): status=%d err=%s", label, x, y,
           (int)status, err);
    if (status == SPDF_SELECTION_OK) {
        EXPECT(sel.text && strcmp(sel.text, expected) == 0, "%s: word text is '%s', got '%s'", label, expected,
               sel.text ? sel.text : "(null)");
        EXPECT(sel.rect_count > 0, "%s: word selection has geometry", label);
        if (sel.rect_count > 0)
            EXPECT(sel.rects[0].x1 > sel.rects[0].x0 && sel.rects[0].y1 > sel.rects[0].y0,
                   "%s: word rect is non-empty", label);
    }
    spdf_free_text_selection(&sel);
}

static void test_cjk_word_selection(spdf_document* doc) {
    spdf_rect tian = find_text(doc, TIAN XIAN DAN PIAN);
    spdf_rect latin = find_text(doc, "L9.9");
    spdf_rect mixed = find_text(doc, TIAN XIAN "L9.9");
    spdf_rect punct = find_text(doc, TIAN DUN XIAN);
    float w;

    /* Double-click over collapsed-quad OCR ideographs selects the CJK run. */
    expect_word_at(doc, (tian.x0 + tian.x1) / 2, (tian.y0 + tian.y1) / 2, TIAN XIAN DAN PIAN, "CJK run");
    /* Latin token on the same OCR line keeps space-delimited behavior. */
    expect_word_at(doc, (latin.x0 + latin.x1) / 2, (latin.y0 + latin.y1) / 2, "L9.9", "Latin token");
    /* Spaceless script transition is a word boundary in both directions. */
    w = (mixed.x1 - mixed.x0) / 6.0f; /* six equal-width glyphless chars */
    expect_word_at(doc, mixed.x0 + w * 0.5f, (mixed.y0 + mixed.y1) / 2, TIAN XIAN, "CJK before Latin");
    expect_word_at(doc, mixed.x0 + w * 2.5f, (mixed.y0 + mixed.y1) / 2, "L9.9", "Latin after CJK");
    /* CJK punctuation breaks runs and selects as a single glyph. */
    w = (punct.x1 - punct.x0) / 3.0f;
    expect_word_at(doc, punct.x0 + w * 0.5f, (punct.y0 + punct.y1) / 2, TIAN, "CJK before punctuation");
    expect_word_at(doc, punct.x0 + w * 1.5f, (punct.y0 + punct.y1) / 2, DUN, "CJK punctuation");
}

static void test_cjk_block_and_range(spdf_document* doc) {
    char err[256];
    spdf_text_selection sel = {0};
    spdf_rect tian = find_text(doc, TIAN XIAN DAN PIAN);
    spdf_rect overlap = find_text(doc, YOU "\xe9\x99\x90\xe5\x85\xac" SI);
    spdf_rect rotated = find_text(doc, LE);
    spdf_selection_status status;

    /* Triple-click over collapsed quads selects the whole OCR block. */
    status = spdf_select_text(doc, 0, SPDF_SELECTION_BLOCK, (tian.x0 + tian.x1) / 2, (tian.y0 + tian.y1) / 2, 0, 0,
                              &sel, err, sizeof(err));
    EXPECT(status == SPDF_SELECTION_OK, "block selection over OCR CJK succeeds: %s", err);
    EXPECT(sel.text && strstr(sel.text, TIAN XIAN DAN PIAN), "block contains the CJK run");
    spdf_free_text_selection(&sel);

    /* A drag across a line stacked under a larger overlapping line hits it. */
    status = spdf_select_text(doc, 0, SPDF_SELECTION_RANGE, overlap.x0 - 1, (overlap.y0 + overlap.y1) / 2,
                              overlap.x1 + 1, (overlap.y0 + overlap.y1) / 2, &sel, err, sizeof(err));
    EXPECT(status == SPDF_SELECTION_OK, "range across overlapped CJK line succeeds: %s", err);
    EXPECT(sel.text && strstr(sel.text, YOU "\xe9\x99\x90\xe5\x85\xac" SI), "range returns the overlapped line");
    EXPECT(sel.rect_count > 0, "overlapped range has geometry");
    spdf_free_text_selection(&sel);

    /* Rotated OCR glyphs: double-click and a perpendicular drag both work. */
    expect_word_at(doc, (rotated.x0 + rotated.x1) / 2, (rotated.y0 + rotated.y1) / 2, LE, "rotated CJK glyph");
    status = spdf_select_text(doc, 0, SPDF_SELECTION_RANGE, rotated.x0 - 1, (rotated.y0 + rotated.y1) / 2,
                              rotated.x1 + 1, (rotated.y0 + rotated.y1) / 2, &sel, err, sizeof(err));
    EXPECT(status == SPDF_SELECTION_OK, "drag across rotated CJK glyph succeeds: %s", err);
    EXPECT(sel.text && strstr(sel.text, LE), "rotated drag returns the glyph");
    spdf_free_text_selection(&sel);
}

static void test_word_char_classes(void) {
    EXPECT(spdf_word_char_classify(' ') == SPDF_WORD_CHAR_SPACE, "ASCII space is SPACE");
    EXPECT(spdf_word_char_classify(0x3000) == SPDF_WORD_CHAR_SPACE, "ideographic space is SPACE");
    EXPECT(spdf_word_char_classify('A') == SPDF_WORD_CHAR_OTHER, "Latin letter is OTHER");
    EXPECT(spdf_word_char_classify('.') == SPDF_WORD_CHAR_OTHER, "ASCII punctuation stays OTHER");
    EXPECT(spdf_word_char_classify(0x5929) == SPDF_WORD_CHAR_CJK, "Han is CJK");
    EXPECT(spdf_word_char_classify(0x3400) == SPDF_WORD_CHAR_CJK, "Han extension A is CJK");
    EXPECT(spdf_word_char_classify(0xF97C) == SPDF_WORD_CHAR_CJK, "Han compatibility is CJK");
    EXPECT(spdf_word_char_classify(0x20000) == SPDF_WORD_CHAR_CJK, "Han extension B is CJK");
    EXPECT(spdf_word_char_classify(0x3042) == SPDF_WORD_CHAR_CJK, "hiragana is CJK");
    EXPECT(spdf_word_char_classify(0x30AB) == SPDF_WORD_CHAR_CJK, "katakana is CJK");
    EXPECT(spdf_word_char_classify(0x3005) == SPDF_WORD_CHAR_CJK, "iteration mark continues a run");
    EXPECT(spdf_word_char_classify(0xAC00) == SPDF_WORD_CHAR_CJK, "Hangul syllable is CJK");
    EXPECT(spdf_word_char_classify(0x3001) == SPDF_WORD_CHAR_CJK_PUNCT, "ideographic comma is punctuation");
    EXPECT(spdf_word_char_classify(0x3002) == SPDF_WORD_CHAR_CJK_PUNCT, "ideographic full stop is punctuation");
    EXPECT(spdf_word_char_classify(0x300A) == SPDF_WORD_CHAR_CJK_PUNCT, "double angle bracket is punctuation");
    EXPECT(spdf_word_char_classify(0xFF0C) == SPDF_WORD_CHAR_CJK_PUNCT, "fullwidth comma is punctuation");

    EXPECT(spdf_word_chars_join(0x5929, 0x7EBF), "Han joins Han");
    EXPECT(spdf_word_chars_join('L', '9') && spdf_word_chars_join('9', '.'), "Latin token joins across ASCII punct");
    EXPECT(!spdf_word_chars_join(0x5929, 'L'), "Han does not join Latin");
    EXPECT(!spdf_word_chars_join('L', 0x5929), "Latin does not join Han");
    EXPECT(!spdf_word_chars_join(0x5929, 0x3001), "Han does not join CJK punctuation");
    EXPECT(!spdf_word_chars_join(0x3001, 0x3001), "CJK punctuation never joins");
    EXPECT(!spdf_word_chars_join('a', ' '), "whitespace never joins");
}

static void test_repair_rotated_collapsed_quad(void) {
    fz_stext_char collapsed = {0};
    fz_stext_char zero_advance = {0};
    fz_stext_line line = {0};
    fz_stext_block block = {0};
    fz_stext_page page = {0};
    fz_rect repaired;

    /* A vertical OCR line (reading up the page): the baseline runs from
       (100,50) to (100,40) and the glyph quad is collapsed onto it. */
    collapsed.c = 0x4E86;
    collapsed.size = 10.0f;
    collapsed.quad.ul = collapsed.quad.ll = fz_make_point(100.0f, 50.0f);
    collapsed.quad.ur = collapsed.quad.lr = fz_make_point(100.0f, 40.0f);
    collapsed.next = &zero_advance;
    zero_advance.c = 'X';
    zero_advance.size = 10.0f;
    zero_advance.quad.ul = zero_advance.quad.ur = zero_advance.quad.ll = zero_advance.quad.lr =
        fz_make_point(100.0f, 40.0f);
    line.dir = fz_make_point(0.0f, -1.0f);
    line.first_char = &collapsed;
    line.last_char = &zero_advance;
    block.type = FZ_STEXT_BLOCK_TEXT;
    block.u.t.first_line = &line;
    block.u.t.last_line = &line;
    page.first_block = &block;
    page.last_block = &block;

    spdf_selection_repair_collapsed_quads(&page);

    repaired = fz_rect_from_quad(collapsed.quad);
    EXPECT(repaired.x1 > repaired.x0 && repaired.y1 > repaired.y0, "repaired rotated quad has area");
    EXPECT(fz_is_point_inside_quad(fz_make_point(96.0f, 44.0f), collapsed.quad),
           "point beside the vertical baseline hits the repaired quad");
    EXPECT(fabsf((collapsed.quad.ul.x - collapsed.quad.ll.x) + 10.0f) < 0.01f,
           "repair expands perpendicular to the rotated baseline by the char size");
    EXPECT(zero_advance.quad.ul.x == 100.0f && zero_advance.quad.lr.x == 100.0f,
           "zero-advance glyph stays collapsed so it keeps flagging incomplete geometry");
}

int main(void) {
    char temp_dir[SPDF_COMPAT_PATH_MAX];
    char path[SPDF_COMPAT_PATH_MAX];
    char err[512];
    spdf_document* doc;

    test_word_char_classes();
    test_repair_rotated_collapsed_quad();

    if (!spdf_compat_make_temp_dir(temp_dir, sizeof(temp_dir), "spdf-core-cjk-selection-tests.")) {
        perror("mkdtemp");
        return 2;
    }
    snprintf(path, sizeof(path), "%s" SPDF_PATH_SEP_STR "cjk-selection.pdf", temp_dir);
    if (!create_cjk_fixture(path)) {
        fprintf(stderr, "Could not create CJK selection fixture\n");
        spdf_compat_rmdir(temp_dir);
        return 2;
    }
    doc = spdf_open(path, err, sizeof(err));
    if (!doc) {
        fprintf(stderr, "Could not open CJK selection fixture: %s\n", err);
        spdf_compat_unlink(path);
        spdf_compat_rmdir(temp_dir);
        return 2;
    }

    test_cjk_word_selection(doc);
    test_cjk_block_and_range(doc);

    spdf_close(doc);
    spdf_compat_unlink(path);
    spdf_compat_rmdir(temp_dir);
    if (failures) {
        fprintf(stderr, "%d core CJK selection test(s) failed\n", failures);
        return 1;
    }
    printf("All core CJK selection tests passed\n");
    return 0;
}
