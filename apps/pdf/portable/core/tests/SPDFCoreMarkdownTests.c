/* SPDFCoreMarkdownTests.c -- the Markdown converter, pinned byte for byte.
 *
 * Pure C, no MuPDF, no files: every case feeds spdf_markdown_body_html (or one
 * of the subsystem seams in spdf_markdown.h) a string and looks for the HTML
 * it must -- and must not -- contain. The end-to-end behaviour on a laid-out
 * document is portable/win/tests/markdown_open_test.c's job.
 *
 * The in-page code controls' converter side -- the fence table, the per-fence
 * language override, the picker's filter and the local-image transcode hook --
 * is SPDFCoreMarkdownCodeTests.c, extracted when this file reached its cap.
 *
 * Sources: portable/core/spdf_markdown.c spdf_markdown_support.c
 *          spdf_markdown_html.c spdf_markdown_lang.c spdf_markdown_lex.c
 *          spdf_markdown_math.c ext/md4c/md4c.c
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

static void test_headings_and_slugs(void) {
    char* h = convert("# Hello World!\n\n## Hello World!\n\n### Sub *emph*\n\n#### Fourth level\n");
    HAS(h, "<h1 id=\"hello-world\">Hello World!</h1>");
    HAS(h, "<h2 id=\"hello-world-1\">Hello World!</h2>");
    HAS(h, "<h3 id=\"sub-emph\">Sub <em>emph</em></h3>");
    /* Levels 4-6 stay out of MuPDF's heading outline, as on macOS (H1-H3). */
    HAS(h, "<p class=\"h4\" id=\"fourth-level\">Fourth level</p>");
    LACKS(h, "<h4");
    free(h);
}

static void test_inline(void) {
    char* h = convert("Text *em* **strong** `co<de>` ~~del~~ [link](https://e.com/ \"T\") [bad](javascript:x) "
                      "<https://auto.link/> [[Page|alias]]\nline two  \nhard\n");
    HAS(h, "<em>em</em>");
    HAS(h, "<strong>strong</strong>");
    HAS(h, "<code>co&lt;de&gt;</code>");
    HAS(h, "<del>del</del>");
    HAS(h, "<a href=\"https://e.com/\" title=\"T\">link</a>");
    HAS(h, "<span>bad</span>");
    LACKS(h, "javascript:");
    HAS(h, "<a href=\"https://auto.link/\">https://auto.link/</a>");
    HAS(h, "<span class=\"wikilink\">alias</span>");
    HAS(h, "<br>");
    free(h);
}

static int fake_hook(void* user, const char* url, char* out, size_t cap) {
    (void)user;
    if (strstr(url, "slash")) {
        snprintf(out, cap, "evil/../x.png");
        return 1;
    }
    if (strstr(url, "cached")) {
        snprintf(out, cap, "3fa9.png");
        return 1;
    }
    return 0;
}

static void test_images(void) {
    spdf_markdown_options o = spdf_markdown_default_options();
    char* h;

    h = convert("![Alt text](icon.png \"A title\")\n\nSentence with ![i](icon.png) inline.\n\n"
                "![up](../secret.png)\n\n![abs](/etc/passwd.png)\n\n![drive](C:/x.png)\n\n"
                "![data](data:image/png;base64,AAAA)\n\n![remote](https://img.example/b.svg)\n\n"
                "![two](a.png) ![images](b.png \"Second\")\n");
    HAS(h, "<figure><img src=\"icon.png\" alt=\"Alt text\" title=\"A title\"><figcaption>A title</figcaption></figure>");
    HAS(h, "<p>Sentence with <img src=\"icon.png\" alt=\"i\"> inline.</p>");
    HAS(h, "[Image: up]");
    LACKS(h, "secret.png");
    HAS(h, "[Image: abs]");
    HAS(h, "[Image: drive]");
    HAS(h, "[Image: data]");
    HAS(h, "[Image: remote]"); /* no hook: every https image is a placeholder */
    HAS(h, "<figcaption>two \xC2\xB7 Second</figcaption>");
    free(h);

    o.remote_image = fake_hook;
    o.remote_image_dir = "C:/cache";
    h = convert_with("![c](https://x/cached.png)\n\n![m](https://x/missing.png)\n\n![s](https://x/slash.png)\n", &o);
    HAS(h, "<img src=\".spdf-remote/3fa9.png\" alt=\"c\">");
    HAS(h, "[Image: m]");
    HAS(h, "[Image: s]"); /* a hook answer that escapes the cache directory is refused */
    free(h);
}

static void test_lists_and_tables(void) {
    char* h = convert("- a\n  - b\n- [x] done\n- [ ] todo\n\n3. three\n4. four\n\n"
                      "| L | C | R |\n|---|:-:|--:|\n| 1 | 2 | 3 |\n");
    HAS(h, "<ul>\n<li>a<ul>\n<li>b</li>");
    HAS(h, "<li class=\"task\">\xE2\x98\x91 done</li>");
    HAS(h, "<li class=\"task\">\xE2\x98\x90 todo</li>");
    HAS(h, "<ol start=\"3\">");
    HAS(h, "<thead>\n<tr><th>L</th><th class=\"ac\">C</th><th class=\"ar\">R</th></tr>");
    HAS(h, "<tbody>\n<tr><td>1</td><td class=\"ac\">2</td><td class=\"ar\">3</td></tr>");
    free(h);
}

static void test_code_blocks(void) {
    char* h = convert(SPDF_MD_TEST_FOUR_FENCES);
    /* Every <pre> carries its fence's ordinal as an id, which is how the in-page
     * language picker and copy button find the box on the laid-out page. */
    HAS(h, "<pre id=\"spdf-code-0\"><code><span class=\"hk\">int</span> x = <span class=\"hn\">0</span>; "
           "<span class=\"hc\">// hi</span></code></pre>");
    HAS(h, "<pre id=\"spdf-code-1\"><code>int y;</code></pre>");
    HAS(h, "<pre id=\"spdf-code-2\"><code>graph TD</code></pre>"); /* diagram fences keep their code box */
    HAS(h, "<pre id=\"spdf-code-3\"><code>plain &lt;b&gt;</code></pre>");
    free(h);
}

static void test_language_catalog(void) {
    EXPECT(spdf_markdown_language_count() == 31, "catalog has %d languages", spdf_markdown_language_count());
    EXPECT(strcmp(spdf_markdown_language_for_fence("C++ title", 9)->id, "cpp") == 0, "c++ alias");
    EXPECT(strcmp(spdf_markdown_language_for_fence("yml", 3)->id, "yaml") == 0, "yml alias");
    EXPECT(strcmp(spdf_markdown_language_for_fence("Bash", 4)->id, "shell") == 0, "bash alias");
    EXPECT(strcmp(spdf_markdown_language_for_fence("txt", 3)->id, "plain") == 0, "txt alias");
    EXPECT(strcmp(spdf_markdown_language_for_fence("objective-c", 11)->id, "objc") == 0, "objc alias");
    EXPECT(spdf_markdown_language_for_fence("brainfuck", 9) == NULL, "unknown fence");
    EXPECT(spdf_markdown_language_for_fence("", 0) == NULL, "empty fence");
    EXPECT(spdf_markdown_is_diagram_fence("mermaid", 7), "mermaid is a diagram fence");
    EXPECT(spdf_markdown_is_diagram_fence("flow", 4), "flow is a diagram fence");
    EXPECT(!spdf_markdown_is_diagram_fence("c", 1), "c is not a diagram fence");
    EXPECT(strcmp(spdf_markdown_language_at(0)->name, "C") == 0, "sorted by display name");
}

static void highlight(const char* id, const char* code, spdf_md_buf* out) {
    spdf_md_buf_init(out);
    spdf_markdown_highlight_html(id, code, strlen(code), out);
    spdf_md_buf_putc(out, '\0');
}

static void test_lexers(void) {
    spdf_md_buf b;
    highlight("c", "\"if x\" /* for */ 0x1F", &b);
    HAS(b.data, "<span class=\"hs\">&quot;if x&quot;</span>");
    LACKS(b.data, "<span class=\"hk\">if</span>"); /* a keyword inside a string is a string */
    HAS(b.data, "<span class=\"hc\">/* for */</span>");
    HAS(b.data, "<span class=\"hn\">0x1F</span>");
    spdf_md_buf_free(&b);

    highlight("python", "x = f\"a\" # c\nreturn", &b);
    HAS(b.data, "<span class=\"hs\">f&quot;a&quot;</span>");
    HAS(b.data, "<span class=\"hc\"># c</span>");
    HAS(b.data, "<span class=\"hk\">return</span>");
    spdf_md_buf_free(&b);

    highlight("json", "{\"k\": \"v\", \"n\": -1.5, \"t\": true}", &b);
    HAS(b.data, "<span class=\"hy\">&quot;k&quot;</span>");
    HAS(b.data, "<span class=\"hs\">&quot;v&quot;</span>");
    HAS(b.data, "<span class=\"hn\">-1.5</span>");
    HAS(b.data, "<span class=\"hk\">true</span>");
    spdf_md_buf_free(&b);

    highlight("yaml", "key: value # c\n- item\nflag: yes\n", &b);
    HAS(b.data, "<span class=\"hy\">key</span>");
    HAS(b.data, "<span class=\"hc\"># c</span>");
    HAS(b.data, "<span class=\"hk\">yes</span>");
    spdf_md_buf_free(&b);

    highlight("toml", "[table]\nname = \"x\"\nn = 3\n", &b);
    HAS(b.data, "<span class=\"hm\">[table]</span>");
    HAS(b.data, "<span class=\"hy\">name</span>");
    spdf_md_buf_free(&b);

    highlight("html", "<a href=\"x\">&amp;</a>", &b);
    HAS(b.data, "<span class=\"hm\">&lt;a</span>");
    HAS(b.data, "<span class=\"hy\">href</span>");
    HAS(b.data, "<span class=\"hs\">&quot;x&quot;</span>");
    HAS(b.data, "<span class=\"hm\">&amp;amp;</span>");
    spdf_md_buf_free(&b);

    highlight("css", ".cls { color: #fff; }", &b);
    HAS(b.data, "<span class=\"hm\">.cls</span>");
    HAS(b.data, "<span class=\"hy\">color</span>");
    HAS(b.data, "<span class=\"hn\">#fff</span>");
    spdf_md_buf_free(&b);

    highlight("latex", "\\frac{1}{2} % note $x$", &b);
    HAS(b.data, "<span class=\"hk\">\\frac</span>");
    HAS(b.data, "<span class=\"hc\">% note $x$</span>");
    spdf_md_buf_free(&b);

    highlight("sql", "SELECT * FROM t -- c", &b);
    HAS(b.data, "<span class=\"hk\">SELECT</span>"); /* case-insensitive keywords */
    HAS(b.data, "<span class=\"hc\">-- c</span>");
    spdf_md_buf_free(&b);

    highlight("shell", "echo $HOME ${X}", &b);
    HAS(b.data, "<span class=\"hk\">echo</span>");
    HAS(b.data, "<span class=\"hy\">$HOME</span>");
    HAS(b.data, "<span class=\"hy\">${X}</span>");
    spdf_md_buf_free(&b);

    highlight("go", "s := `raw` // c", &b);
    HAS(b.data, "<span class=\"hs\">`raw`</span>");
    spdf_md_buf_free(&b);

    highlight("plain", "int x;", &b);
    LACKS(b.data, "<span");
    spdf_md_buf_free(&b);

    highlight("typescript", "let n: number = 1;", &b);
    HAS(b.data, "<span class=\"hk\">number</span>");
    spdf_md_buf_free(&b);
}

static void test_sanitizer(void) {
    char* h = convert("<div align=\"center\">\n\n# Title\n\n</div>\n\n"
                      "<script>alert(1)</script>\n\n"
                      "<p onclick=\"x()\" style=\"color:red\">Para <kbd>Ctrl</kbd> H<sub>2</sub>O <font color=\"red\">f</font></p>\n\n"
                      "<details>\n<summary>More</summary>\n\nBody\n\n</details>\n\n"
                      "<img src=\"b.svg\" width=\"90\" height=\"20\" alt=\"badge\" onerror=\"x()\">\n\n"
                      "<iframe src=\"https://evil\"></iframe>\n\n<!-- comment -->\n\n"
                      "<table><tr><td align=\"right\" colspan=\"2\">c</td></tr></table>\n\n"
                      "inline <span style=\"x\">s</span> and <script>bad()</script> gone\n");
    HAS(h, "<div class=\"ac\">");
    HAS(h, "<h1 id=\"title\">Title</h1>");
    LACKS(h, "alert(1)");
    LACKS(h, "<script");
    HAS(h, "<p>Para <kbd>Ctrl</kbd> H<sub>2</sub>O f</p>");
    LACKS(h, "onclick");
    LACKS(h, "style=");
    LACKS(h, "<font");
    HAS(h, "<div class=\"details\">");
    HAS(h, "<div class=\"summary\">\xE2\x96\xB8 More</div>");
    HAS(h, "<p>Body</p>");
    HAS(h, "<img src=\"b.svg\" alt=\"badge\" width=\"90\" height=\"20\">");
    LACKS(h, "onerror");
    LACKS(h, "iframe");
    LACKS(h, "evil");
    LACKS(h, "comment");
    HAS(h, "<td class=\"ar\" colspan=\"2\">c</td>");
    HAS(h, "inline <span>s</span> and  gone");
    LACKS(h, "bad()");
    free(h);
}

static void test_math(void) {
    char* h = convert("Inline $x^2 + \\alpha$ and $\\frac{1}{2}$, $\\frac{a}{b}$, $\\sqrt{x}$, $\\sqrt{ab}$, "
                      "$\\text{if } n$, $\\foo$, $\\mathbb{R}$.\n\n$$\\int_0^\\infty e^{-x}$$\n");
    HAS(h, "<span class=\"math\"><i>x</i><sup>2</sup> + α</span>");
    HAS(h, "<span class=\"math\">½</span>");
    HAS(h, "<span class=\"math\"><i>a</i> ⁄ <i>b</i></span>");
    HAS(h, "<span class=\"math\">√<i>x</i></span>");
    HAS(h, "<span class=\"math\">√(<i>ab</i>)</span>");
    HAS(h, "<span class=\"math\">if <i>n</i></span>");
    HAS(h, "<code>\\foo</code>"); /* unknown commands degrade visibly, never vanish */
    HAS(h, "ℝ");
    HAS(h, "<span class=\"mdisplay\">∫<sub>0</sub><sup>∞</sup> <i>e</i><sup>-<i>x</i></sup></span>");
    free(h);
}

static void test_front_matter_bom_entities(void) {
    char* h = convert("\xEF\xBB\xBF---\ntitle: X\ntags: [a]\n---\n\nBody &copy; &#169; here\n\n> [!WARNING]\n> Careful\n");
    LACKS(h, "title: X");
    HAS(h, "<p>Body &copy; &#169; here</p>");
    HAS(h, "<blockquote>\n<p><span class=\"callout\">Warning</span><br>\nCareful</p>");
    free(h);
    h = convert("---\nnot closed\n\nText\n");
    HAS(h, "not closed"); /* an unterminated block is content, not front matter */
    free(h);
}

static void test_stylesheets_differ_only_in_colour(void) {
    char* light = spdf_markdown_stylesheet(0);
    char* dark = spdf_markdown_stylesheet(1);
    size_t i = 0, n;
    int colour_diffs = 0;

    EXPECT(light && dark, "stylesheets generated");
    if (!light || !dark) return;
    EXPECT(strlen(light) == strlen(dark), "same length: every colour is #RRGGBB");
    n = strlen(light) < strlen(dark) ? strlen(light) : strlen(dark);
    while (i < n) {
        if (light[i] == dark[i]) {
            ++i;
            continue;
        }
        /* Walk back to the '#' this colour started at, then skip six hex digits. */
        while (i > 0 && light[i] != '#' && i + 1 > 0 && (i - 1) + 7 > i) {
            if (light[i - 1] == '#') {
                --i;
                break;
            }
            --i;
        }
        EXPECT(light[i] == '#' && dark[i] == '#', "difference at %zu is a colour: %.8s vs %.8s", i, light + i, dark + i);
        i += 7;
        ++colour_diffs;
    }
    EXPECT(colour_diffs >= 10, "the palettes actually differ (%d colours)", colour_diffs);
    HAS(light, "@page{margin:60pt 61pt}");
    HAS(dark, "html{background-color:#1E1E1E}");
    HAS(light, "html{background-color:#FFFFFF}");
    LACKS(light, "$"); /* every token substituted */
    free(light);
    free(dark);
}

static void test_document_wrapper_and_determinism(void) {
    char* a = convert("# A\n\ntext\n");
    char* b = convert("# A\n\ntext\n");
    char* doc = spdf_markdown_document_html(a, 0);
    EXPECT(strcmp(a, b) == 0, "conversion is deterministic");
    EXPECT(doc && strstr(doc, "<!DOCTYPE html>") == doc, "document starts with the doctype");
    HAS(doc, "<style>");
    HAS(doc, "<body>\n<h1 id=\"a\">A</h1>");
    free(a);
    free(b);
    free(doc);
}

static void test_paths_and_policy(void) {
    char out[64];
    EXPECT(spdf_path_is_markdown("C:\\docs\\README.md"), ".md");
    EXPECT(spdf_path_is_markdown("/x/notes.MARKDOWN"), ".MARKDOWN");
    EXPECT(!spdf_path_is_markdown("C:\\docs\\a.pdf"), ".pdf");
    EXPECT(!spdf_path_is_markdown("md"), "bare name");
    EXPECT(!spdf_path_is_markdown("dir.md\\file"), "extension must be on the file");
    EXPECT(!spdf_path_is_markdown(NULL), "NULL");
    EXPECT(spdf_markdown_href_allowed("#top", 4), "anchor");
    EXPECT(spdf_markdown_href_allowed("docs/x.md", 9), "relative");
    EXPECT(spdf_markdown_href_allowed("mailto:a@b", 10), "mailto");
    EXPECT(!spdf_markdown_href_allowed("javascript:void(0)", 18), "javascript");
    EXPECT(!spdf_markdown_href_allowed("file:///etc", 11), "file");
    EXPECT(spdf_markdown_resolve_image(NULL, "  img/a.png ", 12, out, sizeof(out)) && strcmp(out, "img/a.png") == 0,
           "relative image trimmed: %s", out);
    EXPECT(!spdf_markdown_resolve_image(NULL, "a/../../b.png", 13, out, sizeof(out)), "parent traversal");
    EXPECT(!spdf_markdown_resolve_image(NULL, "http://x/y.png", 14, out, sizeof(out)), "plain http");
}

static void test_budgets(void) {
    /* Deep nesting and a huge input must terminate and stay bounded. */
    size_t n = 200000, i;
    char* md = (char*)malloc(n + 1);
    char* h;
    for (i = 0; i < n; ++i) md[i] = (i % 80 == 79) ? '\n' : (i % 40 == 0 ? '>' : 'a');
    md[n] = '\0';
    h = spdf_markdown_body_html(md, n, NULL);
    EXPECT(h != NULL && strlen(h) > n, "large input converts (%zu -> %zu)", n, h ? strlen(h) : 0);
    free(h);
    free(md);
    h = spdf_markdown_body_html("", 0, NULL);
    EXPECT(h && h[0] == '\0', "empty input is an empty body");
    free(h);
}

int main(void) {
    test_headings_and_slugs();
    test_inline();
    test_images();
    test_lists_and_tables();
    test_code_blocks();
    test_language_catalog();
    test_lexers();
    test_sanitizer();
    test_math();
    test_front_matter_bom_entities();
    test_stylesheets_differ_only_in_colour();
    test_document_wrapper_and_determinism();
    test_paths_and_policy();
    test_budgets();
    if (g_failures) {
        fprintf(stderr, "%d Markdown converter check(s) failed\n", g_failures);
        return 1;
    }
    printf("All core Markdown tests passed\n");
    return 0;
}
