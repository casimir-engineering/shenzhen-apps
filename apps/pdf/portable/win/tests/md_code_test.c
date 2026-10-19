/* md_code_test.c -- the code box's in-page controls, without a window.
 *
 * Four things, in the order they have to be true:
 *   1. THE ROW's geometry -- both pills on one line at opposite ends of the
 *      text column, the same height, never overlapping, the copy button
 *      standing down when there is no room, and its width taken from the WIDER
 *      of its two titles so "Copied" cannot move the button under the pointer.
 *   2. THE ROUTER, over marks built by hand: a point on a pill routes to that
 *      pill, the gap between them belongs to neither, the 7px slop bites and
 *      then stops, and a stood-down copy button is never hit. This is the pure
 *      header the real router will include, tested exactly as
 *      sidebar_route_test and toolbar_route_test test theirs.
 *   3. THE FENCE TABLE against a real document: the ordinals, the languages,
 *      the raw source for the clipboard, and that every anchor resolved to a
 *      page -- which is the whole claim that "#spdf-code-N" locates fence N.
 *   4. THE PUBLISH, over a scene built by hand: marks for a Markdown document
 *      and NONE for a document that is not one, which is the mechanism by
 *      which every PDF tab pays nothing for this feature.
 *
 * NOTHING HERE OPENS A WINDOW, touches the clipboard or draws: the copy action
 * itself needs a real clipboard and is left to a human, but everything that
 * decides WHAT would be copied is pinned here.
 */
/* spdf-test-sources: portable/win/src/spdf_win_md_code.cpp portable/win/src/spdf_win_md.cpp portable/win/src/spdf_win_md_images.cpp portable/win/src/spdf_win_md_webp.cpp portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c portable/core/spdf_markdown.c portable/core/spdf_markdown_support.c portable/core/spdf_markdown_html.c portable/core/spdf_markdown_lang.c portable/core/spdf_markdown_lex.c portable/core/spdf_markdown_math.c portable/core/spdf_markdown_fences.c portable/core/spdf_markdown_open.c ext/md4c/md4c.c portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c */
/* spdf-test-args: portable/win/tests/fixtures/readme-style.md portable/win/tests/fixtures/golden.pdf */
/* spdf-test-needs: mupdf */
#include "spdf_win_d2d.h" /* spdf_win_scene: the frame is built by hand below */
#include "spdf_win_md.h"
#include "spdf_win_md_code.h"
#include "spdf_win_md_code_marks.h"

#include "spdf_markdown.h"

#include <math.h>
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

static int near_to(float a, float b) {
    return fabsf(a - b) < 0.51f;
}

/* --- 1. the row ---------------------------------------------------------------- */

static void test_row_geometry(void) {
    SpdfWinMdCodePill lang, copy;
    float scale = 1.5f;
    /* An A4 text column at zoom 1.5: 61pt in from each edge of a 595pt sheet. */
    float x0 = 91.5f, x1 = 800.0f, top = 400.0f;
    int has_copy = spdf_win_md_code_row(x0, x1, top, scale, 12.0f, &lang, &copy);

    EXPECT(has_copy, "a full column has room for both pills");
    EXPECT(near_to(lang.h, SPDF_WIN_MD_CODE_HEIGHT * scale), "20 logical px tall: %g", lang.h);
    EXPECT(near_to(copy.h, lang.h), "both the same height");
    EXPECT(near_to(copy.y, lang.y), "both on one line");
    EXPECT(near_to(lang.y + lang.h, top + SPDF_WIN_MD_CODE_LIP * scale),
           "the row rests on the box's top edge with a small lip inside it: bottom %g vs edge %g",
           lang.y + lang.h, top);
    EXPECT(lang.y < top, "so most of the pill is above the box and none of it is over code");
    EXPECT(near_to(copy.x, x0 + SPDF_WIN_MD_CODE_SIDE_INSET * scale), "the copy button is 10 logical px in from the left");
    EXPECT(near_to(lang.x + lang.w, x1 - SPDF_WIN_MD_CODE_SIDE_INSET * scale), "the language pill is 10 in from the right");
    EXPECT(copy.x + copy.w + SPDF_WIN_MD_CODE_MIN_GAP * scale <= lang.x + 0.01f, "6 logical px of air between them");
    EXPECT(!(copy.x < lang.x + lang.w && lang.x < copy.x + copy.w), "they do not overlap");
    EXPECT(lang.w > copy.w, "\"Plain Text\" is wider than \"Copied\"");

    /* The copy button's width must not depend on which of its two titles is
     * showing, or the button would move under the pointer as it changed. */
    {
        SpdfWinMdCodePill again;
        spdf_win_md_code_row(x0, x1, top, scale, 12.0f, NULL, &again);
        EXPECT(near_to(again.w, copy.w), "its width is fixed, whatever it says");
    }

    /* A narrow column: the language pill keeps the row, the copy button goes. */
    has_copy = spdf_win_md_code_row(0.0f, 120.0f, top, 1.0f, 12.0f, &lang, &copy);
    EXPECT(!has_copy, "no room for both");
    EXPECT(copy.w == 0.0f && copy.h == 0.0f, "and the copy button is an empty rectangle");
    EXPECT(lang.w > 0.0f, "while the language pill is still drawn");

    /* No column at all is no row. */
    EXPECT(!spdf_win_md_code_row(200.0f, 200.0f, top, 1.0f, 12.0f, &lang, &copy), "a zero-width column has no row");

    /* Width grows with the title and never below the padding. */
    EXPECT(spdf_win_md_code_pill_width(12.0f, 1.0f) > spdf_win_md_code_pill_width(4.0f, 1.0f), "monotone in the title");
    EXPECT(spdf_win_md_code_pill_width(0.0f, 1.0f) >= SPDF_WIN_MD_CODE_PAD_X * 2.0f, "always at least its padding");
    EXPECT(spdf_win_md_code_pill_width(6.0f, 2.0f) > spdf_win_md_code_pill_width(6.0f, 1.0f), "and with the dpi scale");
}

/* --- 2. the router -------------------------------------------------------------- */

static void test_router(void) {
    SpdfWinMdCodeMark marks[2];
    int which = -1;

    memset(marks, 0, sizeof(marks));
    /* Fence 4: a language pill at 300..400 and a copy button at 100..160, both
     * already carrying their slop, y 50..90 (a 20px pill plus 7px either side
     * at scale 1 would be 43..77; round numbers here keep the arithmetic
     * readable and the header does not care). */
    marks[0].fence_index = 4;
    marks[0].page_index = 1;
    marks[0].lx0 = 300.0f;
    marks[0].lx1 = 400.0f;
    marks[0].ly0 = 50.0f;
    marks[0].ly1 = 90.0f;
    marks[0].cx0 = 100.0f;
    marks[0].cx1 = 160.0f;
    marks[0].cy0 = 50.0f;
    marks[0].cy1 = 90.0f;
    /* Fence 9: the copy button stood down, so its rectangle is all zeroes. */
    marks[1].fence_index = 9;
    marks[1].page_index = 2;
    marks[1].lx0 = 300.0f;
    marks[1].lx1 = 400.0f;
    marks[1].ly0 = 200.0f;
    marks[1].ly1 = 240.0f;

    EXPECT(spdf_win_md_code_mark_at(marks, 2, 350.0f, 70.0f, &which) == 4 && which == 0,
           "a point on the language pill routes to it");
    EXPECT(spdf_win_md_code_mark_at(marks, 2, 130.0f, 70.0f, &which) == 4 && which == 1,
           "a point on the copy button routes to it");
    EXPECT(spdf_win_md_code_mark_at(marks, 2, 230.0f, 70.0f, &which) == -1, "the gap between them belongs to neither");
    EXPECT(spdf_win_md_code_mark_at(marks, 2, 350.0f, 120.0f, &which) == -1, "below the row is neither");
    EXPECT(spdf_win_md_code_mark_at(marks, 2, 300.0f, 50.0f, &which) == 4, "the edges are inclusive");
    EXPECT(spdf_win_md_code_mark_at(marks, 2, 350.0f, 220.0f, &which) == 9 && which == 0,
           "the second fence's pill routes to the second fence");
    /* The stood-down button's all-zero rectangle must not swallow the origin. */
    EXPECT(spdf_win_md_code_mark_at(marks, 2, 0.0f, 0.0f, &which) == -1, "a stood-down copy button is never hit");
    EXPECT(spdf_win_md_code_mark_at(NULL, 0, 350.0f, 70.0f, &which) == -1, "no marks, no hit");
    EXPECT(spdf_win_md_code_mark_at(marks, 0, 350.0f, 70.0f, &which) == -1, "a zero count is no marks");
}

/* --- the copied feedback -------------------------------------------------------- */

static void test_copied_feedback(void) {
    EXPECT(spdf_win_md_code_copied_at(-1, 0, 5000) == -1, "nothing armed, nothing shown");
    EXPECT(spdf_win_md_code_copied_at(3, 1000, 1000) == 3, "shown at once");
    EXPECT(spdf_win_md_code_copied_at(3, 1000, 1000 + SPDF_WIN_MD_CODE_FEEDBACK_MS - 1) == 3, "still shown just before");
    EXPECT(spdf_win_md_code_copied_at(3, 1000, 1000 + SPDF_WIN_MD_CODE_FEEDBACK_MS) == -1, "gone on the deadline");
    EXPECT(spdf_win_md_code_copied_at(3, 1000, 500) == 3, "a tick counter that went backwards keeps it up");
}

/* --- the override map ----------------------------------------------------------- */

static void test_overrides(void) {
    const spdf_markdown_language_override* map;
    int count = -1;
    unsigned gen;

    spdf_win_md_code_clear_overrides();
    EXPECT(spdf_win_md_code_overrides(&count) == NULL && count == 0, "no overrides to start");

    gen = spdf_win_md_options_generation();
    EXPECT(spdf_win_md_code_set_language(2, "rust"), "recording one is a change");
    EXPECT(spdf_win_md_options_generation() == gen + 1, "and bumps the options generation exactly once");
    EXPECT(!spdf_win_md_code_set_language(2, "rust"), "recording the same one again is not");
    EXPECT(spdf_win_md_options_generation() == gen + 1, "and does not bump it");
    EXPECT(spdf_win_md_code_set_language(2, "go"), "changing it is");
    map = spdf_win_md_code_overrides(&count);
    EXPECT(map && count == 1 && map[0].fence_index == 2 && strcmp(map[0].language_id, "go") == 0,
           "one entry, replaced in place");
    EXPECT(spdf_win_md_code_set_language(5, "plain") && spdf_win_md_code_overrides(&count) && count == 2,
           "a second fence appends");
    EXPECT(!spdf_win_md_code_set_language(-1, "go"), "a negative fence is refused");
    EXPECT(!spdf_win_md_code_set_language(0, ""), "an empty language is refused");
    EXPECT(!spdf_win_md_code_set_language(0, NULL), "NULL is refused");
    spdf_win_md_code_clear_overrides();
    EXPECT(spdf_win_md_code_overrides(&count) == NULL && count == 0, "clearing empties it");
}

/* --- the picker's filter -------------------------------------------------------- */

static void test_language_filter(void) {
    int i, n = spdf_markdown_language_count();
    int all = 0, py = 0, yml = 0, found_python = 0, found_yaml = 0, found_plain = 0;

    for (i = 0; i < n; ++i) {
        if (spdf_markdown_language_matches(i, "")) ++all;
        if (spdf_markdown_language_matches(i, "  ")) continue; /* counted by `all` */
    }
    EXPECT(all == n, "an empty query shows the whole catalog: %d of %d", all, n);
    for (i = 0; i < n; ++i) {
        if (spdf_markdown_language_matches(i, "py")) {
            ++py;
            if (strcmp(spdf_markdown_language_at(i)->id, "python") == 0) found_python = 1;
        }
        if (spdf_markdown_language_matches(i, "YML")) {
            ++yml;
            if (strcmp(spdf_markdown_language_at(i)->id, "yaml") == 0) found_yaml = 1;
        }
        if (spdf_markdown_language_matches(i, "plain text")) {
            if (strcmp(spdf_markdown_language_at(i)->id, "plain") == 0) found_plain = 1;
        }
    }
    EXPECT(py >= 1 && py < n && found_python, "\"py\" narrows the list and keeps Python: %d", py);
    EXPECT(yml == 1 && found_yaml, "an ALIAS matches, case-insensitively: %d", yml);
    EXPECT(found_plain, "Plain Text is findable by its display name");
    EXPECT(!spdf_markdown_language_matches(-1, ""), "an index outside the catalog matches nothing");
    EXPECT(!spdf_markdown_language_matches(n, "py"), "nor one past the end");
    for (i = 0; i < n; ++i) EXPECT(!spdf_markdown_language_matches(i, "zzqqx"), "and nothing matches nonsense");
}

/* --- 3 and 4: the fence table and the publish ----------------------------------- */

/* A scene with one drawn page, as spdf_win_canvas_build_scene would leave it. */
static void publish_one_page(int page_index, float dest_y, float zoom, float dpi) {
    spdf_win_scene scene;
    spdf_win_page_draw page;
    memset(&scene, 0, sizeof(scene));
    memset(&page, 0, sizeof(page));
    page.page_index = page_index;
    page.dest_x = 0.0f;
    page.dest_y = dest_y;
    page.dest_w = 595.0f * zoom; /* A4 portrait */
    page.dest_h = 842.0f * zoom;
    scene.pages = &page;
    scene.page_count = 1;
    scene.fit = SPDF_WIN_FIT_CANVAS;
    scene.dpi_scale = dpi;
    spdf_win_md_code_publish_geometry(&scene, 100.0f, 50.0f, zoom);
}

static void test_fence_table(const char* md_path, const char* pdf_path) {
    char err[512] = "";
    spdf_markdown_options o;
    spdf_document* doc;
    const SpdfWinMdCodeMark* marks;
    int count = -1, i, resolved = 0, plain = 0;

    spdf_win_md_code_clear_overrides();
    spdf_win_md_options(&o);
    doc = spdf_open_markdown(md_path, &o, err, sizeof(err));
    if (!doc) {
        EXPECT(0, "spdf_open_markdown(%s): %s", md_path, err);
        return;
    }
    {
        int p = -1;
        float y = -1.0f;
        int ok = spdf_markdown_resolve_anchor(doc, "#spdf-code-0", &p, &y);
    }
    spdf_win_md_code_sync(doc, md_path);
    /* readme-style.md has seven fences: c, python, json, yaml, bash, mermaid
     * and one bare. */
    EXPECT(spdf_win_md_code_count() == 7, "seven fences in the fixture, got %d", spdf_win_md_code_count());
    if (spdf_win_md_code_count() == 7) {
        EXPECT(strcmp(spdf_win_md_code_language(0), "c") == 0, "fence 0 is c: %s", spdf_win_md_code_language(0));
        EXPECT(strcmp(spdf_win_md_code_language_name(0), "C") == 0, "and shows as C");
        EXPECT(strcmp(spdf_win_md_code_language(1), "python") == 0, "fence 1 is python");
        EXPECT(strcmp(spdf_win_md_code_language(6), "plain") == 0, "the bare fence reads as plain: %s",
               spdf_win_md_code_language(6));
        EXPECT(strcmp(spdf_win_md_code_language_name(6), "Plain Text") == 0, "and shows as Plain Text");
        {
            size_t len = 0;
            const char* src = spdf_win_md_code_source(1, &len);
            EXPECT(src && strstr(src, "def greet(name: str) -> str:"), "the raw source is there for the clipboard");
            EXPECT(src && strstr(src, "\n    \"\"\"Docstring.\"\"\"\n"), "with its indentation intact");
            EXPECT(src && !strstr(src, "```"), "and without the fence markers");
            EXPECT(src && len == strlen(src), "the length agrees with the bytes");
        }
        EXPECT(spdf_win_md_code_source(-1, NULL) == NULL, "an invalid index has no source");
        EXPECT(spdf_win_md_code_source(7, NULL) == NULL, "nor does one past the end");
        EXPECT(spdf_win_md_code_language(7) == NULL, "nor a language");
    }

    /* An override changes what the pill says without another sync. */
    if (spdf_win_md_code_count() > 6) {
        spdf_win_md_code_set_language(6, "rust");
        EXPECT(strcmp(spdf_win_md_code_language(6), "rust") == 0, "the override wins");
        EXPECT(strcmp(spdf_win_md_code_language_name(6), "Rust") == 0, "and renames the pill");
        spdf_win_md_code_clear_overrides();
        EXPECT(strcmp(spdf_win_md_code_language(6), "plain") == 0, "clearing it restores the fence's own language");
    }

    /* Every anchor must have resolved, or the pills would have nowhere to go.
     * This is the claim "#spdf-code-N locates fence N", measured. */
    for (i = 0; i < spdf_win_md_code_count(); ++i) {
        publish_one_page(0, 13.0f, 1.5f, 1.5f);
        (void)plain;
    }
    /* Page 0 draws some of them; every page in turn must account for all seven. */
    resolved = 0;
    for (i = 0; i < spdf_page_count(doc); ++i) {
        publish_one_page(i, 13.0f, 1.5f, 1.5f);
        marks = spdf_win_md_code_marks(&count);
        (void)marks;
        resolved += count;
    }
    EXPECT(resolved == 7, "all seven fences were placed on some page, got %d", resolved);

    /* One page's marks, checked in detail. */
    for (i = 0; i < spdf_page_count(doc); ++i) {
        publish_one_page(i, 13.0f, 1.5f, 1.5f);
        marks = spdf_win_md_code_marks(&count);
        if (count <= 0) continue;
        EXPECT(marks[0].page_index == i, "a mark's page is the page that was drawn");
        EXPECT(marks[0].lx1 > marks[0].lx0 && marks[0].ly1 > marks[0].ly0, "the language pill has area");
        /* Client px: the canvas origin (100, 50) was added. */
        EXPECT(marks[0].lx0 > 100.0f, "the canvas origin is in the mark: %g", marks[0].lx0);
        EXPECT(marks[0].cx1 > marks[0].cx0, "and this column has room for the copy button");
        EXPECT(marks[0].cx1 + SPDF_WIN_MD_CODE_MIN_GAP <= marks[0].lx1, "with the copy button on the left");
        break;
    }

    /* A page nobody drew publishes nothing, and so does a cleared scene. */
    publish_one_page(9999, 0.0f, 1.5f, 1.5f);
    spdf_win_md_code_marks(&count);
    EXPECT(count == 0, "a page that was not drawn has no marks");
    spdf_win_md_code_publish_geometry(NULL, 0.0f, 0.0f, 1.0f);
    EXPECT(spdf_win_md_code_marks(&count) == NULL && count == 0, "a scene-less frame clears the marks");
    spdf_close(doc);

    /* THE POINT OF THE FEATURE'S COST MODEL: a PDF tab has no fences, so it
     * publishes nothing and pays nothing. */
    doc = spdf_open(pdf_path, err, sizeof(err));
    if (!doc) {
        EXPECT(0, "spdf_open(%s): %s", pdf_path, err);
        return;
    }
    spdf_win_md_code_sync(doc, pdf_path);
    EXPECT(spdf_win_md_code_count() == 0, "a PDF has no code fences");
    publish_one_page(0, 0.0f, 1.0f, 1.0f);
    EXPECT(spdf_win_md_code_marks(&count) == NULL && count == 0, "and therefore no marks");
    spdf_close(doc);
}

int main(int argc, char** argv) {
    /* Unbuffered: a crash in one of these must not take the failures printed
     * before it out of the log with it. */
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    test_row_geometry();
    test_router();
    test_copied_feedback();
    test_overrides();
    test_language_filter();
    if (argc >= 3) test_fence_table(argv[1], argv[2]);
    else EXPECT(0, "usage: md_code_test <readme-style.md> <golden.pdf>");

    printf("md_code_test: %d failure(s)\n", g_failures);
    return g_failures == 0 ? 0 : 1;
}
