/* SPDFCoreMarkdownCodeTests.c -- the converter's side of the in-page code
 * controls: the fence table, the per-fence language override, and the local
 * image transcode hook.
 *
 * Extracted from SPDFCoreMarkdownTests.c, which reached its 500-line cap
 * (tools/file-size-limits.tsv). Same discipline: pure C, no MuPDF, no files,
 * every case a string in and the HTML -- or the fence list -- it must and must
 * not contain. The end-to-end behaviour on a laid-out document is
 * portable/win/tests/md_code_test.c's and md_webp_test.c's job.
 *
 * THE CASE THAT MATTERS is test_fence_scan()'s second half: the ordinals the
 * scan produces are the ordinals the converter numbers its <pre> anchors with,
 * over one shared fixture. Everything the frontend does with a code box --
 * find it on the page, name its language, copy its source, override its
 * highlighting -- rests on that being true by construction rather than by a
 * geometric guess, so it is measured here and not assumed.
 *
 * Sources: portable/core/spdf_markdown.c spdf_markdown_support.c
 *          spdf_markdown_html.c spdf_markdown_lang.c spdf_markdown_lex.c
 *          spdf_markdown_math.c spdf_markdown_fences.c ext/md4c/md4c.c
 */
#include "SPDFCoreMarkdownFences.h"

#include "spdf_markdown.h"

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

static char* convert(const char* md) {
    spdf_markdown_options o = spdf_markdown_default_options();
    char* html = spdf_markdown_body_html(md, strlen(md), &o);
    EXPECT(html != NULL, "conversion returned NULL for %.40s", md);
    return html ? html : strdup("");
}

static char* convert_with(const char* md, const spdf_markdown_options* o) {
    char* html = spdf_markdown_body_html(md, strlen(md), o);
    EXPECT(html != NULL, "conversion returned NULL");
    return html ? html : strdup("");
}

#define HAS(html, needle) EXPECT(strstr((html), (needle)) != NULL, "missing %s in: %.300s", (needle), (html))
#define LACKS(html, needle) EXPECT(strstr((html), (needle)) == NULL, "unexpected %s in: %.300s", (needle), (html))

/* --- the per-fence language override ------------------------------------------- */

static void test_language_overrides(void) {
    spdf_markdown_language_override over[3];
    spdf_markdown_options o = spdf_markdown_default_options();
    char* h;

    /* Fence 1 was an unknown language and gets coloured as C; fence 2 is the
     * mermaid box, which the picker may colour even though the diagram rule
     * would not; fence 0 is turned back to Plain Text, which must CLEAR the
     * highlighting rather than leave the fence's own language in place. */
    over[0].fence_index = 1;
    over[0].language_id = "c";
    over[1].fence_index = 2;
    over[1].language_id = "python";
    over[2].fence_index = 0;
    over[2].language_id = "plain";
    o.language_overrides = over;
    o.language_override_count = 3;
    h = convert_with(SPDF_MD_TEST_FOUR_FENCES, &o);
    HAS(h, "<pre id=\"spdf-code-0\"><code>int x = 0; // hi</code></pre>");
    HAS(h, "<pre id=\"spdf-code-1\"><code><span class=\"hk\">int</span> y;</code></pre>");
    HAS(h, "<pre id=\"spdf-code-2\"><code>graph TD</code></pre>"); /* "graph TD" has no python token */
    HAS(h, "<pre id=\"spdf-code-3\"><code>plain &lt;b&gt;</code></pre>"); /* untouched */
    free(h);

    /* An index no fence has changes nothing; a later entry for the same fence
     * wins, so a frontend may append rather than rewrite its map. */
    over[0].fence_index = 99;
    over[1].fence_index = 1;
    over[1].language_id = "c";
    over[2].fence_index = 1;
    over[2].language_id = "plain";
    h = convert_with(SPDF_MD_TEST_FOUR_FENCES, &o);
    HAS(h, "<pre id=\"spdf-code-1\"><code>int y;</code></pre>");
    LACKS(h, "spdf-code-99");
    free(h);

    EXPECT(spdf_markdown_language_override_for(&o, 1) &&
               strcmp(spdf_markdown_language_override_for(&o, 1), "plain") == 0,
           "the last entry for a fence wins");
    EXPECT(spdf_markdown_language_override_for(&o, 3) == NULL, "no entry, no override");
    EXPECT(spdf_markdown_language_override_for(&o, -1) == NULL, "a negative index is not an override");
    EXPECT(spdf_markdown_language_override_for(NULL, 0) == NULL, "no options, no override");
}

/* --- the picker's searchable list ----------------------------------------------- */

static void test_language_filter(void) {
    int i, n = spdf_markdown_language_count();
    int all = 0, py = 0, yml = 0, found_python = 0, found_yaml = 0, found_plain = 0, nonsense = 0;

    for (i = 0; i < n; ++i) {
        if (spdf_markdown_language_matches(i, "")) ++all;
        if (spdf_markdown_language_matches(i, "py")) {
            ++py;
            if (strcmp(spdf_markdown_language_at(i)->id, "python") == 0) found_python = 1;
        }
        if (spdf_markdown_language_matches(i, "YML")) {
            ++yml;
            if (strcmp(spdf_markdown_language_at(i)->id, "yaml") == 0) found_yaml = 1;
        }
        if (spdf_markdown_language_matches(i, "plain text") && strcmp(spdf_markdown_language_at(i)->id, "plain") == 0)
            found_plain = 1;
        if (spdf_markdown_language_matches(i, "zzqqx")) ++nonsense;
    }
    EXPECT(all == n, "an empty query shows the whole catalog: %d of %d", all, n);
    EXPECT(spdf_markdown_language_matches(0, "   ") == 1, "a blank query is an empty one");
    EXPECT(py >= 1 && py < n && found_python, "\"py\" narrows the list and keeps Python: %d", py);
    EXPECT(yml == 1 && found_yaml, "an ALIAS matches, case-insensitively: %d", yml);
    EXPECT(found_plain, "Plain Text is findable by its display name");
    EXPECT(nonsense == 0, "and nothing matches nonsense");
    EXPECT(!spdf_markdown_language_matches(-1, ""), "an index outside the catalog matches nothing");
    EXPECT(!spdf_markdown_language_matches(n, "py"), "nor one past the end");
}

/* --- the fence table, and its agreement with the converter ---------------------- */

static void test_fence_scan(void) {
    spdf_markdown_fences f;
    /* The prose in front of the fences is not decoration. md4c calls every
     * MD_PARSER callback unconditionally, so the scan has to supply span
     * callbacks it does not care about; with those left NULL the FIRST
     * *emphasis*, [link](x) or `code span` in a document took the process down,
     * and a fixture of nothing but fences never noticed. */
    const char* src = "---\ntitle: x\n---\n\nProse with *emphasis*, a [link](https://e.com/), `a code span`,\n"
                      "an ![image](i.png), ~~strikethrough~~ and $x^2$ math.\n\n" SPDF_MD_TEST_FOUR_FENCES
                      "\n    four space code\n    second line\n";
    char* h;
    int i;

    EXPECT(spdf_markdown_scan_fences(src, strlen(src), &f), "the scan succeeds");
    EXPECT(f.count == 5, "four fences plus one indented block, got %d", f.count);
    if (f.count == 5) {
        EXPECT(f.items[0].index == 0 && strcmp(f.items[0].info, "c") == 0 &&
                   strcmp(f.items[0].language, "c") == 0 && !f.items[0].diagram,
               "fence 0 is c: info='%s' lang='%s'", f.items[0].info, f.items[0].language);
        EXPECT(strcmp(f.items[0].code, "int x = 0; // hi") == 0, "and carries its raw source: '%s'", f.items[0].code);
        EXPECT(f.items[0].code_len == strlen(f.items[0].code), "whose length agrees with its bytes");
        EXPECT(strcmp(f.items[1].info, "nosuchlang") == 0 && f.items[1].language[0] == '\0',
               "an unknown info string resolves to no language, not to a guess");
        EXPECT(strcmp(f.items[2].info, "mermaid") == 0 && f.items[2].diagram, "the mermaid fence is flagged");
        EXPECT(f.items[3].info[0] == '\0' && f.items[3].language[0] == '\0', "a bare fence has neither");
        EXPECT(strcmp(f.items[4].code, "four space code\nsecond line") == 0,
               "an indented block is a fence too, dedented: '%s'", f.items[4].code);
        for (i = 0; i < f.count; ++i) EXPECT(f.items[i].index == i, "indexes are dense and in order");
    }

    /* THE AGREEMENT the whole design rests on: the scan's ordinals are the
     * converter's anchors, over the very same document. */
    h = convert(src);
    for (i = 0; i < f.count; ++i) {
        char anchor[64];
        snprintf(anchor, sizeof(anchor), "<pre id=\"spdf-code-%d\">", i);
        HAS(h, anchor);
    }
    LACKS(h, "spdf-code-5"); /* and no anchor the scan did not account for */
    free(h);
    spdf_markdown_free_fences(&f);
    EXPECT(f.items == NULL && f.count == 0, "freeing empties the list");

    /* A document with no code at all is a success with nothing in it. */
    EXPECT(spdf_markdown_scan_fences("# just a heading\n", 17, &f) && f.count == 0, "no fences is not a failure");
    spdf_markdown_free_fences(&f);
    EXPECT(spdf_markdown_scan_fences(NULL, 0, &f) && f.count == 0, "NULL is an empty document");
    spdf_markdown_free_fences(&f);
    EXPECT(!spdf_markdown_scan_fences(src, strlen(src), NULL), "no output, no scan");
}

/* --- local images MuPDF cannot decode ------------------------------------------- */

/* Answers for exactly one absolute path, which is how the test pins that the
 * relative source was joined to document_dir before the hook saw it. */
static int fake_local(void* user, const char* path, char* out, size_t cap) {
    (void)user;
    if (strcmp(path, "C:/docs/shot.webp") == 0) {
        snprintf(out, cap, "beef.png");
        return 1;
    }
    if (strcmp(path, "C:/docs/img/deep.WEBP") == 0) {
        snprintf(out, cap, "../escape.png"); /* refused, like the remote hook's */
        return 1;
    }
    return 0;
}

static void test_local_image_transcode(void) {
    spdf_markdown_options o = spdf_markdown_default_options();
    const char* src = "![a](shot.webp)\n\n![b](img/deep.WEBP)\n\n![c](other.webp)\n\n![d](icon.png)\n";
    char* h;

    /* No hook: a .webp is an ordinary relative source, and MuPDF -- which has
     * no WebP decoder -- draws its own "[image]" for it. This is the fallback
     * every branch below has to degrade to. */
    h = convert(src);
    HAS(h, "<img src=\"shot.webp\" alt=\"a\">");
    free(h);

    o.local_image = fake_local;
    o.remote_image_dir = "C:/cache";
    o.document_dir = "C:/docs";
    h = convert_with(src, &o);
    HAS(h, "<img src=\".spdf-remote/beef.png\" alt=\"a\">");
    HAS(h, "<img src=\"img/deep.WEBP\" alt=\"b\">"); /* escaping answer refused */
    HAS(h, "<img src=\"other.webp\" alt=\"c\">");    /* the hook declined */
    HAS(h, "<img src=\"icon.png\" alt=\"d\">");      /* not a candidate: never offered */
    free(h);

    /* A trailing separator on the folder must not double up. */
    o.document_dir = "C:/docs/";
    h = convert_with(src, &o);
    HAS(h, "<img src=\".spdf-remote/beef.png\" alt=\"a\">");
    free(h);

    /* Each of the three requirements is enough on its own to disable the hook. */
    o.document_dir = "C:/docs";
    o.remote_image_dir = NULL;
    h = convert_with(src, &o);
    HAS(h, "<img src=\"shot.webp\" alt=\"a\">");
    free(h);
    o.remote_image_dir = "C:/cache";
    o.document_dir = "";
    h = convert_with(src, &o);
    HAS(h, "<img src=\"shot.webp\" alt=\"a\">");
    free(h);
}

int main(void) {
    test_language_overrides();
    test_language_filter();
    test_fence_scan();
    test_local_image_transcode();
    printf("SPDFCoreMarkdownCodeTests: %d failure(s)\n", g_failures);
    return g_failures == 0 ? 0 : 1;
}
