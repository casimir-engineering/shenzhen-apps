/* md_win_test.c -- the Windows Markdown module: the open seam, the text size
 * and its settings key, the option assembly, and the remote-image cache's
 * naming and lookup against a scratch directory.
 *
 * NO NETWORK. The WinHTTP fetch is never started here: the lookup records a
 * miss, the test checks the miss was recorded and that a file dropped into the
 * cache directory under the computed name is found on the next lookup -- the
 * whole contract the converter and the frontend rely on, minus the socket.
 */
/* spdf-test-sources: portable/win/src/spdf_win_md.cpp portable/win/src/spdf_win_md_code.cpp portable/win/src/spdf_win_md_images.cpp portable/win/src/spdf_win_md_webp.cpp portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c portable/core/spdf_markdown.c portable/core/spdf_markdown_support.c portable/core/spdf_markdown_html.c portable/core/spdf_markdown_lang.c portable/core/spdf_markdown_lex.c portable/core/spdf_markdown_math.c portable/core/spdf_markdown_fences.c portable/core/spdf_markdown_open.c ext/md4c/md4c.c portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c portable/win/src/spdf_win_open.c */
/* spdf-test-args: portable/win/tests/fixtures/golden.pdf portable/win/tests/fixtures/readme-style.md %SCRATCH% */
/* spdf-test-needs: mupdf */
#include "spdf_win_md.h"
#include "spdf_win_md_images.h"
#include "spdf_win_open.h"
#include "spdf_win_paths.h" /* the state-directory override, for the orientation round trip */

#include <direct.h>
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

static int close_to(float a, float b) {
    return fabsf(a - b) < 1e-4f;
}

static void test_text_scale(void) {
    unsigned gen;
    spdf_win_md_set_text_scale(1.0f);
    gen = spdf_win_md_options_generation();
    EXPECT(close_to(spdf_win_md_text_scale(), 1.0f), "default scale is 1.0");
    EXPECT(spdf_win_md_text_scale_step(+1) && close_to(spdf_win_md_text_scale(), 1.1f), "A+ is +10%%: %g",
           spdf_win_md_text_scale());
    EXPECT(spdf_win_md_options_generation() == gen + 1, "a change bumps the generation once");
    EXPECT(spdf_win_md_text_scale_step(+1) && close_to(spdf_win_md_text_scale(), 1.2f), "1.1 -> 1.2 exactly: %g",
           spdf_win_md_text_scale());
    spdf_win_md_set_text_scale(5.0f);
    EXPECT(close_to(spdf_win_md_text_scale(), 3.0f), "clamped to 3.0");
    EXPECT(!spdf_win_md_text_scale_step(+1), "A+ at the ceiling changes nothing");
    gen = spdf_win_md_options_generation();
    spdf_win_md_set_text_scale(3.0f);
    EXPECT(spdf_win_md_options_generation() == gen, "a no-op set does not bump the generation");
    spdf_win_md_set_text_scale(0.1f);
    EXPECT(close_to(spdf_win_md_text_scale(), 0.5f), "clamped to 0.5");
    EXPECT(!spdf_win_md_text_scale_step(-1), "A- at the floor changes nothing");
    {
        volatile float zero = 0.0f; /* a runtime NaN: the compiler refuses the constant */
        spdf_win_md_set_text_scale(zero / zero);
    }
    EXPECT(close_to(spdf_win_md_text_scale(), 1.0f), "NaN resets to 1.0");
    spdf_win_md_set_text_scale(-2.0f);
    EXPECT(close_to(spdf_win_md_text_scale(), 1.0f), "negative resets to 1.0");
}

static void test_settings_json(void) {
    char* out;
    EXPECT(close_to(spdf_win_md_settings_scale(NULL), 1.0f), "no file: 1.0");
    EXPECT(close_to(spdf_win_md_settings_scale("{}"), 1.0f), "no key: 1.0");
    EXPECT(close_to(spdf_win_md_settings_scale("{\"markdownFontScale\":1.25}"), 1.25f), "reads the key");
    EXPECT(close_to(spdf_win_md_settings_scale("{\"markdownFontScale\":\"1.3\"}"), 1.3f), "tolerates a quoted number");
    EXPECT(close_to(spdf_win_md_settings_scale("{\"markdownFontScale\":42}"), 3.0f), "clamps on read");
    EXPECT(close_to(spdf_win_md_settings_scale("{\"a\":{\"markdownFontScale\":9},\"b\":[1,{\"x\":2}],\"markdownFontScale\":1.5}"),
                1.5f),
           "only the TOP-LEVEL key counts");
    EXPECT(close_to(spdf_win_md_settings_scale("{\"s\":\"a\\\"}b\",\"markdownFontScale\":2}"), 2.0f),
           "an escaped quote inside a string does not derail the scan");

    out = spdf_win_md_settings_with_scale(NULL, 1.1f);
    EXPECT(out && strcmp(out, "{\"markdownFontScale\":1.10}") == 0, "from nothing: %s", out ? out : "(null)");
    free(out);
    out = spdf_win_md_settings_with_scale("{}", 0.5f);
    EXPECT(out && strcmp(out, "{\"markdownFontScale\":0.50}") == 0, "from an empty object: %s", out ? out : "(null)");
    free(out);
    out = spdf_win_md_settings_with_scale("{\"darkTheme\":true,\"zoom\":1.5}", 1.25f);
    EXPECT(out && strcmp(out, "{\"darkTheme\":true,\"zoom\":1.5,\"markdownFontScale\":1.25}") == 0,
           "appended after the other keys: %s", out ? out : "(null)");
    free(out);
    out = spdf_win_md_settings_with_scale("{\"markdownFontScale\":2,\"b\":\"x\"}", 1.0f);
    EXPECT(out && strcmp(out, "{\"markdownFontScale\":1.00,\"b\":\"x\"}") == 0, "replaced in place: %s",
           out ? out : "(null)");
    free(out);
    out = spdf_win_md_settings_with_scale("{\"a\":1,\"markdownFontScale\":\"2\"}", 2.7f);
    EXPECT(out && strcmp(out, "{\"a\":1,\"markdownFontScale\":2.70}") == 0, "a quoted value is replaced whole: %s",
           out ? out : "(null)");
    if (out) EXPECT(close_to(spdf_win_md_settings_scale(out), 2.7f), "round-trips through the reader");
    free(out);
    out = spdf_win_md_settings_with_scale("not json", 1.0f);
    EXPECT(out && strcmp(out, "{\"markdownFontScale\":1.00}") == 0, "garbage is replaced by a fresh object: %s",
           out ? out : "(null)");
    free(out);
}

static void test_cache_names(const char* scratch) {
    char a[64], b[64], c[64], d[64], dir[1024], path[2048];
    FILE* f;
    int pending;

    spdf_win_md_images_cache_name("https://img.shields.io/badge/a-b.svg", a, sizeof(a));
    spdf_win_md_images_cache_name("https://img.shields.io/badge/a-b.svg", b, sizeof(b));
    EXPECT(strcmp(a, b) == 0 && strlen(a) == 20 && strcmp(a + 16, ".svg") == 0, "deterministic, .svg kept: %s", a);
    spdf_win_md_images_cache_name("https://x/y/picture.PNG?size=2#frag", c, sizeof(c));
    EXPECT(strlen(c) == 20 && strcmp(c + 16, ".png") == 0, "query and fragment ignored, extension lowered: %s", c);
    EXPECT(strncmp(a, c, 16) != 0, "different URLs hash differently");
    spdf_win_md_images_cache_name("https://x/y/noext", d, sizeof(d));
    EXPECT(strcmp(d + 16, ".img") == 0, "no extension -> .img: %s", d);
    spdf_win_md_images_cache_name("https://x/v1.2.3/api/badge", d, sizeof(d));
    EXPECT(strcmp(d + 16, ".img") == 0, "a dot in a directory is not an extension: %s", d);
    spdf_win_md_images_cache_name("https://x/a.verylongext", d, sizeof(d));
    EXPECT(strcmp(d + 16, ".img") == 0, "an implausible extension -> .img: %s", d);

    /* Lookup against a scratch cache directory. */
    snprintf(dir, sizeof(dir), "%s/md-win-cache", scratch);
    spdf_win_md_images_set_dir_override(dir);
    spdf_win_md_images_clear_pending();
    /* The seed this test plants below survives into the next run under the same
     * scratch directory, where it would answer the "miss" lookups as a hit:
     * the suite failed on every second run until this remove. */
    snprintf(path, sizeof(path), "%s/%s", dir, a);
    remove(path);
    EXPECT(spdf_win_md_images_dir(path, sizeof(path)) && strcmp(path, dir) == 0, "override directory is used");
    EXPECT(!spdf_win_md_images_lookup(NULL, "http://plain.example/a.png", b, sizeof(b)), "http is never cached");
    EXPECT(spdf_win_md_images_pending_count() == 0, "and never recorded");
    EXPECT(!spdf_win_md_images_lookup(NULL, "https://img.shields.io/badge/a-b.svg", b, sizeof(b)), "a miss answers 0");
    EXPECT(spdf_win_md_images_pending_count() == 1, "the miss is recorded");
    spdf_win_md_images_lookup(NULL, "https://img.shields.io/badge/a-b.svg", b, sizeof(b));
    EXPECT(spdf_win_md_images_pending_count() == 1, "the same URL is recorded once");
    pending = spdf_win_md_images_pending_count();

    snprintf(path, sizeof(path), "%s/%s", dir, a);
    f = fopen(path, "wb");
    EXPECT(f != NULL, "can seed the cache at %s", path);
    if (f) {
        fputs("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\"/>", f);
        fclose(f);
    }
    EXPECT(spdf_win_md_images_lookup(NULL, "https://img.shields.io/badge/a-b.svg", b, sizeof(b)) && strcmp(a, b) == 0,
           "a cached URL answers its file name: %s", b);
    EXPECT(spdf_win_md_images_pending_count() == pending, "a hit records nothing");
    spdf_win_md_images_clear_pending();
    EXPECT(spdf_win_md_images_pending_count() == 0, "cleared");
    EXPECT(!spdf_win_md_images_fetch_pending(NULL, 0), "nothing pending: no fetch starts");
    EXPECT(!spdf_win_md_images_fetching(), "and none is running");
}

static void test_open_seam(const char* pdf, const char* md) {
    char err[512] = {0};
    spdf_document* doc;
    spdf_markdown_options options;
    spdf_bitmap bmp;

    spdf_win_md_set_text_scale(1.0f);
    spdf_win_md_options(&options);
    EXPECT(close_to(options.text_scale, 1.0f) && options.dark_rendition, "options carry the scale and the dark rendition");
    EXPECT(options.remote_image != NULL && options.remote_image_dir != NULL, "the cache hook is wired");

    doc = spdf_win_md_open_any(pdf, err, sizeof(err));
    EXPECT(doc && spdf_page_count(doc) == 2, "a PDF opens through spdf_open unchanged: %s", err);
    if (doc) spdf_close(doc);

    doc = spdf_win_md_open_any(md, err, sizeof(err));
    EXPECT(doc && spdf_page_count(doc) >= 3, "a .md opens as pages: %s", err);
    if (doc) {
        memset(&bmp, 0, sizeof(bmp));
        if (spdf_render_page_rgba_opts(doc, 0, 0.3f, SPDF_RENDER_DARK_THEME, NULL, &bmp, err, sizeof(err))) {
            const unsigned char* p = bmp.rgba + 2 * bmp.stride + 8;
            EXPECT(p[0] == 0x1E && p[1] == 0x1E && p[2] == 0x1E, "the dark rendition is wired (%02X%02X%02X)", p[0],
                   p[1], p[2]);
        } else {
            EXPECT(0, "dark render: %s", err);
        }
        spdf_free_bitmap(&bmp);
        spdf_close(doc);
    }
    doc = spdf_win_md_open_any("C:/definitely/missing.md", err, sizeof(err));
    EXPECT(doc == NULL && err[0], "a missing .md fails with a message");
    doc = spdf_win_md_open_any("C:/definitely/missing.pdf", err, sizeof(err));
    EXPECT(doc == NULL && err[0], "a missing .pdf fails with a message");
}

/* PAGE ORIENTATION, PER FILE: the table, its JSON, the path comparison, the
 * generation bump, the real round trip through the state directory, and the
 * sheet the open seam actually produces for a turned file. */
static void test_orientation(const char* md, const char* scratch) {
    char* json;
    char state_dir[1024];
    unsigned gen;
    spdf_document* doc;
    char err[512] = {0};
    float w = 0.0f, h = 0.0f;

    spdf_win_md_orientation_from_json(NULL);
    EXPECT(!spdf_win_md_landscape_for(md), "an unknown file is portrait");
    EXPECT(!spdf_win_md_landscape_for(NULL), "NULL is portrait");
    EXPECT(!spdf_win_md_set_landscape(md, 0), "portrait on an unknown file is a no-op");

    /* The path comparison: what Windows itself considers the same file. */
    EXPECT(spdf_win_md_path_equal("C:\\Docs\\Notes.md", "c:/docs/notes.MD"), "separators and ASCII case fold");
    EXPECT(!spdf_win_md_path_equal("C:\\Docs\\Notes.md", "C:\\Docs\\Notes2.md"), "different files differ");
    EXPECT(!spdf_win_md_path_equal("C:\\Docs\\Notes.md", "C:\\Docs\\Note"), "a prefix is not equal");
    EXPECT(!spdf_win_md_path_equal(NULL, "x"), "NULL never matches");

    gen = spdf_win_md_options_generation();
    EXPECT(spdf_win_md_set_landscape("C:\\Docs\\Wide Table.md", 1), "turning a file landscape changes the table");
    EXPECT(spdf_win_md_options_generation() == gen + 1, "and bumps the generation once");
    EXPECT(!spdf_win_md_set_landscape("c:/docs/wide table.md", 1), "the same file spelled differently is a no-op");
    EXPECT(spdf_win_md_options_generation() == gen + 1, "with no second bump");
    EXPECT(spdf_win_md_landscape_for("C:/DOCS/WIDE TABLE.MD"), "looked up under any spelling");
    EXPECT(!spdf_win_md_landscape_for("C:\\Docs\\Other.md"), "other files stay portrait");
    EXPECT(spdf_win_md_toggle_landscape("C:\\Docs\\Other.md") == 1, "toggle turns portrait landscape");
    EXPECT(spdf_win_md_toggle_landscape("C:\\Docs\\Other.md") == 0, "and back");
    EXPECT(!spdf_win_md_landscape_for("C:\\Docs\\Other.md"), "back means portrait");

    /* The JSON: the mac's record shape, landscape files only, paths escaped. */
    json = spdf_win_md_orientation_to_json();
    EXPECT(json != NULL, "the table serialises");
    if (json) {
        EXPECT(strcmp(json, "{\"C:\\\\Docs\\\\Wide Table.md\":{\"markdownLandscape\":true,\"path\":\"C:\\\\Docs\\\\Wide "
                            "Table.md\"}}") == 0,
               "one landscape record in the documents.yaml shape: %s", json);
        EXPECT(spdf_win_md_orientation_from_json(json) == 1, "it reads back as one record");
        EXPECT(spdf_win_md_landscape_for("C:\\Docs\\Wide Table.md"), "the file is still landscape after the round trip");
        free(json);
    }
    EXPECT(spdf_win_md_orientation_from_json("{\"C:\\\\a.md\":{\"markdownLandscape\":false,\"path\":\"C:\\\\a.md\"},"
                                             "\"C:\\\\b \\\"quoted\\\".md\":{\"path\":\"x\",\"markdownLandscape\":true},"
                                             "\"C:\\\\c.md\":{\"title\":\"c\"}}") == 1,
           "false and absent both mean portrait; an escaped key is unescaped");
    EXPECT(!spdf_win_md_landscape_for("C:\\a.md") && spdf_win_md_landscape_for("C:\\b \"quoted\".md") &&
               !spdf_win_md_landscape_for("C:\\c.md"),
           "the records land on the right files");
    EXPECT(spdf_win_md_orientation_from_json("not json") == 0, "garbage empties the table");
    EXPECT(!spdf_win_md_landscape_for("C:\\b \"quoted\".md"), "...really empties it");
    json = spdf_win_md_orientation_to_json();
    EXPECT(json && strcmp(json, "{}") == 0, "an empty table is {}");
    free(json);

    /* The round trip through a real state directory. */
    snprintf(state_dir, sizeof(state_dir), "%s/md-orientation-state", scratch);
    (void)_mkdir(state_dir);
    spdf_win_paths_set_state_dir_override(state_dir);
    EXPECT(spdf_win_md_load_orientation() == 0, "no file yet: nothing loaded");
    EXPECT(spdf_win_md_set_landscape(md, 1), "turn the fixture landscape");
    EXPECT(spdf_win_md_save_orientation(), "and save it");
    spdf_win_md_orientation_from_json(NULL);
    EXPECT(!spdf_win_md_landscape_for(md), "forgotten in memory");
    EXPECT(spdf_win_md_load_orientation() == 1, "one record comes back from the file");
    EXPECT(spdf_win_md_landscape_for(md), "the fixture reopens landscape");

    /* And the sheet the seam produces follows the table. */
    doc = spdf_win_md_open_any(md, err, sizeof(err));
    EXPECT(doc != NULL, "the turned fixture opens: %s", err);
    if (doc) {
        EXPECT(spdf_page_size(doc, 0, &w, &h, err, sizeof(err)) && w > h, "landscape: %gx%g", w, h);
        spdf_close(doc);
    }
    EXPECT(spdf_win_md_set_landscape(md, 0), "turn it back");
    EXPECT(spdf_win_md_save_orientation(), "save the empty table");
    doc = spdf_win_md_open_any(md, err, sizeof(err));
    EXPECT(doc != NULL, "the fixture opens again: %s", err);
    if (doc) {
        EXPECT(spdf_page_size(doc, 0, &w, &h, err, sizeof(err)) && w < h, "portrait again: %gx%g", w, h);
        spdf_close(doc);
    }
    spdf_win_paths_set_state_dir_override(NULL);
}

/* The process opener (spdf_win_open.h): spdf_open until the hook is installed,
 * and this module's open_any afterwards -- which is how the render workers,
 * the search worker and the headless paths come to open Markdown without
 * linking this module. main() installs it first thing. */
static void test_open_seam_hook(const char* md) {
    char err[512] = {0};
    spdf_document* doc;
    EXPECT(spdf_win_open_hook() == NULL, "no hook installed by default");
    spdf_win_open_set_hook(spdf_win_md_open_any);
    EXPECT(spdf_win_open_hook() == spdf_win_md_open_any, "the hook is what was installed");
    doc = spdf_win_open_document(md, err, sizeof(err));
    EXPECT(doc && spdf_page_count(doc) >= 3, "with the hook a .md opens as pages: %s", err);
    if (doc) spdf_close(doc);
    spdf_win_open_set_hook(NULL);
    EXPECT(spdf_win_open_hook() == NULL, "NULL restores the default");
}

int main(int argc, char** argv) {
    const char* pdf = argc > 1 ? argv[1] : "portable/win/tests/fixtures/golden.pdf";
    const char* md = argc > 2 ? argv[2] : "portable/win/tests/fixtures/readme-style.md";
    const char* scratch = argc > 3 ? argv[3] : ".";
    char dir[1024];

    snprintf(dir, sizeof(dir), "%s/md-win-cache", scratch);
    (void)_mkdir(dir);

    test_text_scale();
    test_settings_json();
    test_cache_names(scratch);
    test_open_seam(pdf, md);
    test_orientation(md, scratch);
    test_open_seam_hook(md);

    if (g_failures) {
        fprintf(stderr, "%d Windows Markdown module check(s) failed\n", g_failures);
        return 1;
    }
    printf("All Windows Markdown module tests passed\n");
    return 0;
}
