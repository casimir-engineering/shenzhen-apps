/* annot_model_test.c — pins portable/win/src/spdf_win_annot_model.h and the
 * canvas half of the input router it feeds (spdf_win_annot_marks.h).
 *
 * WHAT IT IS FOR. The differential (annot-differential-native.cmd) proves the
 * path rules equal to the GTK original over forward-slash paths; this suite
 * pins what the differential cannot reach: the Windows spellings of those
 * rules (backslashes, drive letters), the marker geometry and hit tests whose
 * GTK originals are welded to SpdfTab, the strings the sidebar and the hover
 * bubble show, and the routing -- a press on a badge opens the editor, a press
 * beside it is still the canvas, a bare move names the comment for the
 * preview. Every constant is cited at its definition in the header.
 *
 * Header-only under test, so no `spdf-test-sources` line -- same as
 * chrome_input_test.c and menu_test.c.
 */
#include "spdf_win_annot_model.h"
#include "spdf_win_chrome_input.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__);                                           \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_STR(got, want)                                                                                           \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(got) || strcmp((got), (want)) != 0) {                                                                    \
            fprintf(stderr, "FAIL %s == \"%s\" (got \"%s\") (%s:%d)\n", #got, want, (got) ? (got) : "(null)", __FILE__, \
                    __LINE__);                                                                                         \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* --- 1. path rules, Windows spellings ------------------------------------- */

static void test_paths(void) {
    char* s;
    CHECK(spdf_win_annot_path_has_pdf_extension("C:\\Docs\\a.pdf"));
    CHECK(spdf_win_annot_path_has_pdf_extension("C:\\Docs\\A.PDF"));
    CHECK(!spdf_win_annot_path_has_pdf_extension("C:\\Docs\\a.pdf.bak"));
    CHECK(!spdf_win_annot_path_has_pdf_extension("C:\\Docs\\readme.md"));
    CHECK(!spdf_win_annot_path_has_pdf_extension(NULL));
    CHECK(!spdf_win_annot_path_has_pdf_extension(""));

    /* Both separators, on the boundary only. */
    CHECK(spdf_win_annot_path_is_under_directory("C:\\Temp\\x.pdf", "C:\\Temp"));
    CHECK(spdf_win_annot_path_is_under_directory("C:/Temp/x.pdf", "C:/Temp"));
    CHECK(spdf_win_annot_path_is_under_directory("C:\\Temp/x.pdf", "C:\\Temp"));
    CHECK(spdf_win_annot_path_is_under_directory("C:\\Temp", "C:\\Temp"));
    CHECK(!spdf_win_annot_path_is_under_directory("C:\\Temporary\\x.pdf", "C:\\Temp"));
    CHECK(!spdf_win_annot_path_is_under_directory(NULL, "C:\\Temp"));
    CHECK(!spdf_win_annot_path_is_under_directory("C:\\Temp\\x", NULL));
    CHECK(!spdf_win_annot_path_is_under_directory("", "C:\\Temp"));

    CHECK(spdf_win_annot_path_is_temp_in("C:\\Users\\u\\AppData\\Local\\Temp\\x.pdf", "C:\\Users\\u\\AppData\\Local\\Temp",
                                         NULL));
    CHECK(!spdf_win_annot_path_is_temp_in("C:\\Docs\\x.pdf", "C:\\Users\\u\\AppData\\Local\\Temp", NULL));
    /* The original's two POSIX roots never match a Windows path. */
    CHECK(!spdf_win_annot_path_is_temp_in("C:\\tmp\\x.pdf", "C:\\T", NULL));

    s = spdf_win_annot_filename_with_pdf_extension("C:\\Docs\\a.pdf");
    CHECK_STR(s, "C:\\Docs\\a.pdf");
    free(s);
    s = spdf_win_annot_filename_with_pdf_extension("C:\\Docs\\a");
    CHECK_STR(s, "C:\\Docs\\a.pdf");
    free(s);
    s = spdf_win_annot_filename_with_pdf_extension("C:\\Docs\\A.PDF");
    CHECK_STR(s, "C:\\Docs\\A.PDF");
    free(s);
    CHECK(spdf_win_annot_filename_with_pdf_extension(NULL) == NULL);
    CHECK(spdf_win_annot_filename_with_pdf_extension("") == NULL);

    s = spdf_win_annot_single_page_filename("C:\\Docs\\report.pdf", 4);
    CHECK_STR(s, "report - page 5.pdf");
    free(s);
    s = spdf_win_annot_single_page_filename("C:/Docs/report.final.pdf", 0);
    CHECK_STR(s, "report.final - page 1.pdf");
    free(s);
    s = spdf_win_annot_single_page_filename(NULL, 2);
    CHECK_STR(s, "Page - page 3.pdf");
    free(s);
    s = spdf_win_annot_single_page_filename("C:\\Docs\\.hidden", 0);
    CHECK_STR(s, ".hidden - page 1.pdf"); /* a leading dot is not an extension */
    free(s);

    CHECK(spdf_win_annot_same_folder_write_allowed(0, 1, 1));
    CHECK(!spdf_win_annot_same_folder_write_allowed(1, 1, 1));
    CHECK(!spdf_win_annot_same_folder_write_allowed(0, 0, 1));
    CHECK(!spdf_win_annot_same_folder_write_allowed(0, 1, 0));
    CHECK(spdf_win_annot_save_target_acceptable("C:\\Docs\\a.pdf", "C:\\T", NULL));
    CHECK(!spdf_win_annot_save_target_acceptable("C:\\T\\a.pdf", "C:\\T", NULL));
    CHECK(!spdf_win_annot_save_target_acceptable("C:\\Docs\\a.txt", "C:\\T", NULL));
}

/* --- 2. markers and hit tests --------------------------------------------- */

static spdf_comment_item item(int index, int page, float x0, float y0, float x1, float y1) {
    spdf_comment_item it;
    memset(&it, 0, sizeof(it));
    it.index = index;
    it.page_index = page;
    it.bounds.x0 = x0;
    it.bounds.y0 = y0;
    it.bounds.x1 = x1;
    it.bounds.y1 = y1;
    return it;
}

static void test_markers(void) {
    spdf_comment_item items[4];
    spdf_rect b;
    items[0] = item(0, 0, 100.0f, 200.0f, 300.0f, 220.0f);
    items[1] = item(1, 1, 50.0f, 50.0f, 60.0f, 60.0f);
    items[2] = item(-1, 0, 100.0f, 200.0f, 300.0f, 220.0f); /* not a visible comment */
    items[3] = item(3, 0, 400.0f, 400.0f, 400.0f, 400.0f);   /* no area */

    /* The badge: 12 pt, hugging the top-right corner 4 in / 8 out. */
    b = spdf_win_annot_badge(&items[0].bounds);
    CHECK(b.x0 == 296.0f && b.x1 == 308.0f && b.y0 == 192.0f && b.y1 == 204.0f);
    /* Inverted bounds resolve to the same corner. */
    items[1].bounds.x0 = 60.0f;
    items[1].bounds.x1 = 50.0f;
    items[1].bounds.y0 = 60.0f;
    items[1].bounds.y1 = 50.0f;
    b = spdf_win_annot_badge(&items[1].bounds);
    CHECK(b.x0 == 56.0f && b.x1 == 68.0f && b.y0 == 42.0f && b.y1 == 54.0f);

    /* Bounds + 3 pt. */
    CHECK(spdf_win_annot_comment_at_point(items, 4, 0, 200.0f, 210.0f) == 0);
    CHECK(spdf_win_annot_comment_at_point(items, 4, 0, 97.0f, 197.0f) == 0);
    CHECK(spdf_win_annot_comment_at_point(items, 4, 0, 96.9f, 210.0f) == -1);
    CHECK(spdf_win_annot_comment_at_point(items, 4, 0, 303.0f, 223.0f) == 0);
    CHECK(spdf_win_annot_comment_at_point(items, 4, 1, 200.0f, 210.0f) == -1); /* wrong page */
    CHECK(spdf_win_annot_comment_at_point(items, 4, 1, 55.0f, 55.0f) == 1);   /* inverted bounds still hit */
    /* A zero-area rect still hits once inflated by the 3 pt slop -- GTK's
     * annot_comment_at_point inflates first and only then rejects an empty
     * rect, so a Popup-less note whose bounds collapsed is still hoverable. */
    CHECK(spdf_win_annot_comment_at_point(items, 4, 0, 400.0f, 400.0f) == 3);
    CHECK(spdf_win_annot_comment_at_point(items, 0, 0, 200.0f, 210.0f) == -1);
    /* The item with index -1 never answers, even though its rect matches. */
    items[0].index = -1;
    CHECK(spdf_win_annot_comment_at_point(items, 4, 0, 200.0f, 210.0f) == -1);
    items[0].index = 0;

    /* Badge + 2 pt, and ONLY the badge: the middle of the highlight is not a
     * click-to-edit (text selection over it must still work). */
    CHECK(spdf_win_annot_comment_at_badge(items, 4, 0, 302.0f, 198.0f) == 0);
    CHECK(spdf_win_annot_comment_at_badge(items, 4, 0, 294.0f, 190.0f) == 0);
    CHECK(spdf_win_annot_comment_at_badge(items, 4, 0, 310.0f, 206.0f) == 0);
    CHECK(spdf_win_annot_comment_at_badge(items, 4, 0, 293.9f, 198.0f) == -1);
    CHECK(spdf_win_annot_comment_at_badge(items, 4, 0, 200.0f, 210.0f) == -1);

    CHECK(spdf_win_annot_item_for_index(items, 4, 1) == &items[1]);
    CHECK(spdf_win_annot_item_for_index(items, 4, 3) == &items[3]);
    CHECK(spdf_win_annot_item_for_index(items, 4, 7) == NULL);
    CHECK(spdf_win_annot_item_for_index(items, 4, -1) == NULL);
    CHECK(spdf_win_annot_item_for_index(NULL, 4, 1) == NULL);

    CHECK(spdf_win_annot_bounds_have_area(&items[0].bounds));
    CHECK(!spdf_win_annot_bounds_have_area(&items[3].bounds));
    CHECK(!spdf_win_annot_bounds_have_area(NULL));
}

/* --- 3. text ---------------------------------------------------------------- */

static void test_text(void) {
    spdf_comment_item it = item(0, 2, 0, 0, 10, 10);
    char buf[512];
    char longtext[400];
    int i;

    it.author = (char*)"Rapha\xc3\xabl";
    it.text = (char*)"Check this figure";
    it.type = (char*)"Highlight";
    spdf_win_annot_row_title(&it, buf, sizeof(buf));
    CHECK_STR(buf, "Rapha\xc3\xabl: Check this figure");
    spdf_win_annot_row_subtitle(&it, buf, sizeof(buf));
    CHECK_STR(buf, "Page 3");
    spdf_win_annot_hover_text(&it, buf, sizeof(buf));
    CHECK_STR(buf, "Rapha\xc3\xabl - Highlight\nCheck this figure");
    spdf_win_annot_filter_haystack(&it, buf, sizeof(buf));
    CHECK_STR(buf, "Rapha\xc3\xabl: Check this figure Rapha\xc3\xabl Highlight p.3");

    /* No text: the type stands in; no author: no prefix. */
    it.text = (char*)"";
    spdf_win_annot_row_title(&it, buf, sizeof(buf));
    CHECK_STR(buf, "Rapha\xc3\xabl: Highlight");
    spdf_win_annot_hover_text(&it, buf, sizeof(buf));
    CHECK_STR(buf, "Rapha\xc3\xabl - Highlight");
    it.author = NULL;
    spdf_win_annot_row_title(&it, buf, sizeof(buf));
    CHECK_STR(buf, "Highlight");
    it.type = NULL;
    spdf_win_annot_row_title(&it, buf, sizeof(buf));
    CHECK_STR(buf, "Comment");
    spdf_win_annot_hover_text(&it, buf, sizeof(buf));
    CHECK_STR(buf, "Comment");
    it.text = (char*)"note";
    spdf_win_annot_hover_text(&it, buf, sizeof(buf));
    CHECK_STR(buf, "Comment\nnote");
    spdf_win_annot_row_title(NULL, buf, sizeof(buf));
    CHECK_STR(buf, "");

    /* The delete detail: the sentence alone, with the text, and cut at 180
     * bytes with "..." -- never inside a multibyte sequence. */
    spdf_win_annot_delete_detail(NULL, buf, sizeof(buf));
    CHECK_STR(buf, "This will permanently remove the comment from the PDF.");
    spdf_win_annot_delete_detail("short", buf, sizeof(buf));
    CHECK_STR(buf, "This will permanently remove the comment from the PDF.\n\nshort");
    for (i = 0; i < 178; ++i) longtext[i] = 'a';
    memcpy(longtext + 178, "\xc3\xa9\xc3\xa9", 4); /* two 2-byte chars straddling the cut at 180 */
    longtext[182] = 'z';
    longtext[183] = '\0';
    spdf_win_annot_delete_detail(longtext, buf, sizeof(buf));
    CHECK(strlen(buf) == strlen("This will permanently remove the comment from the PDF.\n\n") + 180 + 3);
    CHECK(strstr(buf, "\xc3\xa9...") != NULL);          /* the cut fell on a boundary */
    CHECK(strstr(buf, "\xc3...") == NULL && strstr(buf, "z") == NULL);
}

/* --- 4. routing ------------------------------------------------------------- */

static void test_routing(void) {
    SpdfWinChromeModel m;
    SpdfWinChromeLayout l;
    SpdfWinChromeHit hit;
    SpdfWinAnnotMark marks[2];
    float cx, cy;

    memset(&m, 0, sizeof(m));
    m.show_sidebar = 0;
    m.show_minimap = 0;
    m.hot_tab = -1;
    m.hot_close = -1;
    m.tab_count = 1;
    m.page_index = 0;
    m.page_count = 1;
    m.zoom = 1.0f;
    m.zoom_dpi_scale = 1.0f;
    spdf_win_chrome_layout(&m, 1200u, 900u, 1.0f, &l);
    CHECK(!spdf_win_chrome_rect_empty(l.canvas));
    cx = l.canvas.x;
    cy = l.canvas.y;

    /* Two marks, client px: one 200x20 highlight with its badge, one note. */
    memset(marks, 0, sizeof(marks));
    marks[0].comment_index = 4;
    marks[0].page_index = 0;
    marks[0].x0 = cx + 97.0f;
    marks[0].y0 = cy + 197.0f;
    marks[0].x1 = cx + 303.0f;
    marks[0].y1 = cy + 223.0f;
    marks[0].bx0 = cx + 294.0f;
    marks[0].by0 = cy + 190.0f;
    marks[0].bx1 = cx + 310.0f;
    marks[0].by1 = cy + 206.0f;
    marks[1].comment_index = 9;
    marks[1].page_index = 0;
    marks[1].x0 = cx + 500.0f;
    marks[1].y0 = cy + 500.0f;
    marks[1].x1 = cx + 530.0f;
    marks[1].y1 = cy + 530.0f;
    marks[1].bx0 = cx + 520.0f;
    marks[1].by0 = cy + 495.0f;
    marks[1].bx1 = cx + 536.0f;
    marks[1].by1 = cy + 511.0f;

    /* No marks: the canvas is the canvas, with nothing under the pointer. */
    spdf_win_chrome_input_route(&l, &m, cx + 200.0f, cy + 210.0f, SPDF_WIN_CB_LEFT, &hit);
    CHECK(hit.action == SPDF_WIN_CA_CANVAS && hit.index == -1);

    m.annot_marks = marks;
    m.annot_mark_count = 2;
    /* A bare move over the highlight names it; a left press there is still
     * the canvas (a drag over a highlight selects its text). */
    spdf_win_chrome_input_route(&l, &m, cx + 200.0f, cy + 210.0f, SPDF_WIN_CB_NONE, &hit);
    CHECK(hit.action == SPDF_WIN_CA_CANVAS && hit.index == 4);
    spdf_win_chrome_input_route(&l, &m, cx + 200.0f, cy + 210.0f, SPDF_WIN_CB_LEFT, &hit);
    CHECK(hit.action == SPDF_WIN_CA_CANVAS && hit.index == 4);
    /* A left press on the badge opens the editor; a middle press does not. */
    spdf_win_chrome_input_route(&l, &m, cx + 302.0f, cy + 198.0f, SPDF_WIN_CB_LEFT, &hit);
    CHECK(hit.action == SPDF_WIN_CA_ANNOT_EDIT && hit.index == 4);
    spdf_win_chrome_input_route(&l, &m, cx + 302.0f, cy + 198.0f, SPDF_WIN_CB_MIDDLE, &hit);
    CHECK(hit.action == SPDF_WIN_CA_CANVAS && hit.index == 4);
    /* The badge's corner that lies outside the bounds still edits (GTK tests
     * the badge, not the bounds). */
    spdf_win_chrome_input_route(&l, &m, cx + 308.0f, cy + 192.0f, SPDF_WIN_CB_LEFT, &hit);
    CHECK(hit.action == SPDF_WIN_CA_ANNOT_EDIT && hit.index == 4);
    /* The second mark, and empty canvas between the two. */
    spdf_win_chrome_input_route(&l, &m, cx + 528.0f, cy + 500.0f, SPDF_WIN_CB_LEFT, &hit);
    CHECK(hit.action == SPDF_WIN_CA_ANNOT_EDIT && hit.index == 9);
    spdf_win_chrome_input_route(&l, &m, cx + 400.0f, cy + 400.0f, SPDF_WIN_CB_LEFT, &hit);
    CHECK(hit.action == SPDF_WIN_CA_CANVAS && hit.index == -1);
    /* Marks never leak outside the canvas: the toolbar is still the toolbar. */
    marks[1].bx0 = 0.0f;
    marks[1].by0 = 0.0f;
    marks[1].bx1 = 2000.0f;
    marks[1].by1 = 2000.0f;
    spdf_win_chrome_input_route(&l, &m, l.toolbar.x + 5.0f, l.toolbar.y + 5.0f, SPDF_WIN_CB_LEFT, &hit);
    CHECK(hit.action != SPDF_WIN_CA_ANNOT_EDIT);

    /* The pure helper on its own. */
    CHECK(spdf_win_annot_mark_at(NULL, 0, 1.0f, 1.0f, 0) == -1);
    CHECK(spdf_win_annot_mark_at(marks, 0, cx + 200.0f, cy + 210.0f, 0) == -1);
}

int main(void) {
    test_paths();
    test_markers();
    test_text();
    test_routing();
    printf("[annot_model_test] %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
