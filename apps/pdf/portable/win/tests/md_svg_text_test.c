/* md_svg_text_test.c -- the diagram route's spike, kept as a test.
 *
 * WHY THIS EXISTS. The Markdown design memo (windows-markdown-design.md §3,
 * phase D) proposed drawing Mermaid, js-sequence and flowchart fences as SVG
 * served from an archive beside the document, because MuPDF's HTML engine
 * renders SVG natively. Release 26.8.31-1 promises two things about those
 * diagrams: the artwork is vector and crisp at any zoom, AND "every label
 * inside a diagram is real text: you can select it, Cmd+F finds and highlights
 * it in place, and it stays selectable in the exported PDF".
 *
 * The first half holds; this suite measures the second, and it does not. An
 * <img src="*.svg"> goes through fz_new_image_from_svg (mupdf/source/html/
 * html-parse.c:670), which wraps the SVG's display list in an fz_image -- and
 * fz_stext never descends into an image, so the SVG's <text> is drawn but never
 * extracted. An inline <svg> element takes the same road (gen2_image_svg,
 * html-parse.c:1310), so it is not an escape either, and MuPDF's CSS has no
 * `position`, `top`, `left`, `float` or `transform` (css-apply.c), so a text
 * overlay in the flow cannot be positioned over the picture.
 *
 * A FAILURE HERE IS GOOD NEWS. It would mean a MuPDF that extracts SVG text,
 * and the SVG route would then satisfy the promise as written. Read the memo's
 * §9.2 before "fixing" this suite: the assertions are the evidence a route
 * decision rests on, not a preference.
 *
 * The control assertion is the point of the fixture: the same search on the
 * same page finds the prose word Aardvark. Without it, "no matches" would be
 * indistinguishable from a broken document, a mis-typed needle or an empty page.
 */
/* spdf-test-sources: portable/core/spdf_markdown.c portable/core/spdf_markdown_support.c portable/core/spdf_markdown_html.c portable/core/spdf_markdown_lang.c portable/core/spdf_markdown_lex.c portable/core/spdf_markdown_math.c portable/core/spdf_markdown_fences.c portable/core/spdf_markdown_open.c ext/md4c/md4c.c portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c */
/* spdf-test-args: portable/win/tests/fixtures/svg-diagram.md %SCRATCH% */
/* spdf-test-needs: mupdf */
#include "shenzhen_pdf_core.h"

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

/* Read a whole file; NULL on failure. `*len_out` excludes the added NUL. */
static char* slurp(const char* path, size_t* len_out) {
    FILE* f = fopen(path, "rb");
    char* buf;
    long n;
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 0) {
        fclose(f);
        return NULL;
    }
    buf = (char*)malloc((size_t)n + 1);
    if (!buf) {
        fclose(f);
        return NULL;
    }
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) {
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);
    buf[n] = '\0';
    *len_out = (size_t)n;
    return buf;
}

/* memmem, which MSVC does not ship: the PDF holds NUL bytes. */
static int contains(const char* hay, size_t hay_len, const char* needle) {
    size_t n = strlen(needle);
    size_t i;
    if (n == 0 || hay_len < n) return 0;
    for (i = 0; i + n <= hay_len; ++i)
        if (memcmp(hay + i, needle, n) == 0) return 1;
    return 0;
}

int main(int argc, char** argv) {
    char err[512] = "";
    spdf_markdown_options o = spdf_markdown_default_options();
    spdf_document* doc;
    spdf_text_lines lines;
    char pdf_path[1024];
    char* pdf;
    size_t pdf_len = 0;
    int i, labelled = 0;

    if (argc < 3) {
        fprintf(stderr, "usage: md_svg_text_test <svg-diagram.md> <scratch-dir>\n");
        return 2;
    }
    o.dark_rendition = 0;
    doc = spdf_open_markdown(argv[1], &o, err, sizeof(err));
    if (!doc) {
        fprintf(stderr, "FAIL spdf_open_markdown: %s\n", err);
        return 1;
    }
    EXPECT(spdf_page_count(doc) == 1, "the fixture is one page, got %d", spdf_page_count(doc));

    /* The control FIRST: if this fails, nothing below means anything. */
    EXPECT(spdf_search_page(doc, 0, "Aardvark", err, sizeof(err)) == 1,
           "the control word in the prose is found exactly once");

    /* The finding: three labels are drawn inside the SVG and none is text. */
    EXPECT(spdf_search_page(doc, 0, "Kumquatlabel", err, sizeof(err)) == 0,
           "an SVG label is not searchable page text");
    EXPECT(spdf_search_page(doc, 0, "Quetzalbox", err, sizeof(err)) == 0, "nor is the second label");
    EXPECT(spdf_search_page(doc, 0, "Zanzibarnode", err, sizeof(err)) == 0, "nor the third");

    /* Line extraction is the other reader of page text -- the sidebar's map,
     * Select All, translate -- and it agrees. */
    memset(&lines, 0, sizeof(lines));
    if (spdf_extract_page_text_lines(doc, 0, &lines, err, sizeof(err))) {
        int control = 0;
        for (i = 0; i < lines.count; ++i) {
            if (!lines.items[i].text) continue;
            if (strstr(lines.items[i].text, "Kumquatlabel")) ++labelled;
            if (strstr(lines.items[i].text, "Aardvark")) ++control;
        }
        EXPECT(control > 0, "the extractor sees the prose");
        EXPECT(labelled == 0, "the extractor does not see the SVG's labels, got %d line(s)", labelled);
        spdf_free_text_lines(&lines);
    } else {
        EXPECT(0, "spdf_extract_page_text_lines: %s", err);
    }

    /* And the export, which the release note also promises: the label is not in
     * the PDF's text either, and the figure arrives as an image XObject rather
     * than as vector operators. */
    snprintf(pdf_path, sizeof(pdf_path), "%s\\svg-diagram-export.pdf", argv[2]);
    remove(pdf_path);
    EXPECT(spdf_export_pdf(doc, pdf_path, -1, err, sizeof(err)), "export: %s", err);
    pdf = slurp(pdf_path, &pdf_len);
    if (pdf) {
        EXPECT(pdf_len > 1000, "the export is a real PDF, %u bytes", (unsigned)pdf_len);
        EXPECT(!contains(pdf, pdf_len, "Kumquatlabel"), "the SVG's label is not in the exported PDF's content");
        EXPECT(contains(pdf, pdf_len, "/Image"), "the figure is embedded as an image XObject, not vector operators");
        free(pdf);
    } else {
        EXPECT(0, "could not read back %s", pdf_path);
    }
    remove(pdf_path);

    spdf_close(doc);
    printf("md_svg_text_test: %d failure(s)\n", g_failures);
    return g_failures == 0 ? 0 : 1;
}
