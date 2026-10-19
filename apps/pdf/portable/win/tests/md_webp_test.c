/* md_webp_test.c -- WebP for the Markdown reader: the naming and sniffing that
 * decide when to transcode, the WIC transcode itself, and the whole route
 * through spdf_open_markdown.
 *
 * THE ASSERTION THAT MATTERS is test_open_has_no_placeholder(): the fixture's
 * WebP figure must not leave MuPDF's own "[image]" word on the page. It is
 * proved BOTH ways -- the same document opened without the hook still says
 * "[image]" -- because a search for a word that is absent for the wrong reason
 * (a typo, a broken fixture, an empty page) would otherwise look like a pass.
 *
 * NO NETWORK. Nothing here fetches: the source is a committed 128x128 WebP and
 * the cache is a scratch directory handed in as argv[2].
 *
 * IF WINDOWS HAS NO WEBP CODEC (before Windows 10 1809) the transcode cannot
 * succeed and this suite says so and skips the two cases that need it, rather
 * than failing -- the product behaviour there is the "[image]" fallback, which
 * is what the un-hooked half already pins.
 */
/* spdf-test-sources: portable/win/src/spdf_win_md_webp.cpp portable/win/src/spdf_win_md_images.cpp portable/win/src/spdf_win_paths.c portable/core/spdf_markdown.c portable/core/spdf_markdown_support.c portable/core/spdf_markdown_html.c portable/core/spdf_markdown_lang.c portable/core/spdf_markdown_lex.c portable/core/spdf_markdown_math.c portable/core/spdf_markdown_fences.c portable/core/spdf_markdown_open.c ext/md4c/md4c.c portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c */
/* spdf-test-args: portable/win/tests/fixtures/webp-figure.md %SCRATCH% */
/* spdf-test-needs: mupdf */
#include "spdf_win_md_images.h"
#include "spdf_win_md_webp.h"
#include "spdf_win_paths.h"

#include "shenzhen_pdf_core.h"

#include <direct.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_codec = 1; /* cleared when WIC turns out to have no WebP decoder */

#define EXPECT(condition, ...)                         \
    do {                                               \
        if (!(condition)) {                            \
            fprintf(stderr, "FAIL " __VA_ARGS__);      \
            fprintf(stderr, " [line %d]\n", __LINE__); \
            ++g_failures;                              \
        }                                              \
    } while (0)

/* argv[1] is the fixture; its folder holds md-shot.webp and md-icon.png. */
static char g_doc[1024];
static char g_dir[1024];
static char g_cache[1024];

static void fixture_paths(const char* doc) {
    size_t i, cut = 0;
    snprintf(g_doc, sizeof(g_doc), "%s", doc);
    for (i = 0; g_doc[i]; ++i)
        if (g_doc[i] == '/' || g_doc[i] == '\\') cut = i;
    snprintf(g_dir, sizeof(g_dir), "%.*s", (int)cut, g_doc);
}

static int join(const char* name, char* out, size_t cap) {
    return spdf_win_path_join(g_dir, name, out, cap);
}

static int file_size(const char* path) {
    FILE* f = fopen(path, "rb");
    long n;
    if (!f) return -1;
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fclose(f);
    return (int)n;
}

static int starts_with_png_signature(const char* path) {
    static const unsigned char sig[8] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    unsigned char head[8];
    size_t got;
    FILE* f = fopen(path, "rb");
    if (!f) return 0;
    got = fread(head, 1, sizeof(head), f);
    fclose(f);
    return got == sizeof(head) && memcmp(head, sig, sizeof(sig)) == 0;
}

/* --- the pure halves ------------------------------------------------------------ */

static void test_name_gate(void) {
    EXPECT(spdf_win_md_webp_is_webp_name("a.webp"), "a.webp is one");
    EXPECT(spdf_win_md_webp_is_webp_name("C:\\x\\SHOT.WEBP"), "case does not matter");
    EXPECT(!spdf_win_md_webp_is_webp_name(".webp"), "a bare extension is not a file name");
    EXPECT(!spdf_win_md_webp_is_webp_name("a.web"), "a.web is not one");
    EXPECT(!spdf_win_md_webp_is_webp_name("a.webpx"), "a.webpx is not one");
    EXPECT(!spdf_win_md_webp_is_webp_name("a.png"), "a.png is not one");
    EXPECT(!spdf_win_md_webp_is_webp_name(NULL), "NULL is not one");
}

static void test_byte_sniff(void) {
    const char* webp = "RIFF\x08\x13\x00\x00WEBPVP8 ";
    const char* avi = "RIFF\x08\x13\x00\x00AVI LIST";
    EXPECT(spdf_win_md_webp_is_webp_bytes(webp, 16), "RIFF....WEBP is WebP");
    EXPECT(!spdf_win_md_webp_is_webp_bytes(webp, 11), "eleven bytes cannot decide");
    EXPECT(!spdf_win_md_webp_is_webp_bytes(avi, 16), "another RIFF form is not WebP");
    EXPECT(!spdf_win_md_webp_is_webp_bytes("\x89PNG\r\n\x1a\n\x00\x00\x00\x0d", 12), "a PNG is not WebP");
    EXPECT(!spdf_win_md_webp_is_webp_bytes(NULL, 12), "NULL is not WebP");
}

static void test_cache_name(void) {
    char a[64], b[64], c[64], d[64], e[64];
    spdf_win_md_webp_cache_name("C:\\d\\shot.webp", 100, 200, a, sizeof(a));
    spdf_win_md_webp_cache_name("C:\\d\\shot.webp", 100, 200, b, sizeof(b));
    spdf_win_md_webp_cache_name("C:\\D\\SHOT.WEBP", 100, 200, c, sizeof(c));
    spdf_win_md_webp_cache_name("C:\\d\\shot.webp", 101, 200, d, sizeof(d));
    spdf_win_md_webp_cache_name("C:\\d\\shot.webp", 100, 201, e, sizeof(e));
    EXPECT(strlen(a) == 20, "16 hex digits plus \".png\": %s", a);
    EXPECT(strcmp(a + 16, ".png") == 0, "ends .png: %s", a);
    EXPECT(strcmp(a, b) == 0, "deterministic");
    EXPECT(strcmp(a, c) == 0, "one file on a case-insensitive filesystem is one cache entry");
    EXPECT(strcmp(a, d) != 0, "a different byte size is a different entry (an edited picture)");
    EXPECT(strcmp(a, e) != 0, "a different write time is a different entry");
}

static void test_file_sniff(void) {
    char webp[1024], png[1024];
    EXPECT(join("md-shot.webp", webp, sizeof(webp)) && file_size(webp) > 0, "the WebP fixture is readable");
    EXPECT(join("md-icon.png", png, sizeof(png)) && file_size(png) > 0, "the PNG fixture is readable");
    EXPECT(spdf_win_md_webp_file_is_webp(webp), "the fixture's bytes say WebP");
    EXPECT(!spdf_win_md_webp_file_is_webp(png), "the PNG's bytes do not");
    EXPECT(!spdf_win_md_webp_file_is_webp(g_doc), "the Markdown source's do not");
    EXPECT(!spdf_win_md_webp_file_is_webp("C:\\nope\\missing.webp"), "a missing file does not");
}

/* --- the transcode -------------------------------------------------------------- */

static void test_transcode(void) {
    char src[1024], dst[1024];
    if (!join("md-shot.webp", src, sizeof(src)) || !spdf_win_path_join(g_cache, "out.png", dst, sizeof(dst))) {
        EXPECT(0, "could not build the transcode paths");
        return;
    }
    remove(dst);
    if (!spdf_win_md_webp_transcode(src, dst)) {
        g_codec = 0;
        printf("note: WIC has no WebP decoder on this Windows; the \"[image]\" fallback is what ships here.\n");
        EXPECT(file_size(dst) < 0, "a failed transcode leaves no partial file behind");
        return;
    }
    EXPECT(starts_with_png_signature(dst), "the transcode wrote a real PNG");
    EXPECT(file_size(dst) > 1000, "128x128 of pixels is more than a header: %d bytes", file_size(dst));
    EXPECT(!spdf_win_md_webp_transcode("C:\\nope\\missing.webp", dst), "a missing source fails");
    EXPECT(!spdf_win_md_webp_transcode(g_doc, dst), "a Markdown file is not an image WIC can decode");
}

static void test_lookup(void) {
    char src[1024], first[64], again[64], cached[1024], png[1024], answer[64];
    if (!g_codec) return;
    EXPECT(join("md-shot.webp", src, sizeof(src)), "path");
    first[0] = '\0';
    EXPECT(spdf_win_md_webp_lookup(NULL, src, first, sizeof(first)) && first[0], "the hook answers for a .webp");
    EXPECT(strcmp(first + strlen(first) - 4, ".png") == 0, "and names a .png: %s", first);
    EXPECT(spdf_win_path_join(g_cache, first, cached, sizeof(cached)) && starts_with_png_signature(cached),
           "the named file is in the cache and is a PNG");
    again[0] = '\0';
    EXPECT(spdf_win_md_webp_lookup(NULL, src, again, sizeof(again)) && strcmp(first, again) == 0,
           "a second open reuses the same cache entry");
    EXPECT(join("md-icon.png", png, sizeof(png)), "path");
    EXPECT(!spdf_win_md_webp_lookup(NULL, png, answer, sizeof(answer)), "a PNG is left alone");
    EXPECT(!spdf_win_md_webp_lookup(NULL, src, answer, 4), "a name that will not fit is refused");
    EXPECT(!spdf_win_md_webp_lookup(NULL, NULL, answer, sizeof(answer)), "NULL is refused");
}

/* --- the whole route ------------------------------------------------------------ */

static int placeholders_on_page_0(int hooked) {
    spdf_markdown_options o = spdf_markdown_default_options();
    spdf_document* doc;
    char err[512] = "";
    int hits;

    o.dark_rendition = 0;
    if (hooked) {
        o.remote_image_dir = g_cache;
        o.local_image = spdf_win_md_webp_lookup;
    }
    doc = spdf_open_markdown(g_doc, &o, err, sizeof(err));
    if (!doc) {
        EXPECT(0, "spdf_open_markdown failed: %s", err);
        return -1;
    }
    hits = spdf_search_page(doc, 0, "[image]", err, sizeof(err));
    spdf_close(doc);
    return hits;
}

static void test_open_has_no_placeholder(void) {
    int bare = placeholders_on_page_0(0);
    EXPECT(bare == 2, "without the hook MuPDF draws \"[image]\" for both WebP uses, got %d", bare);
    if (!g_codec) return;
    EXPECT(placeholders_on_page_0(1) == 0, "with the hook the page has no \"[image]\" left");
}

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: md_webp_test <webp-figure.md> <scratch-dir>\n");
        return 2;
    }
    fixture_paths(argv[1]);
    snprintf(g_cache, sizeof(g_cache), "%s\\md-webp-cache", argv[2]);
    _mkdir(g_cache);
    spdf_win_md_images_set_dir_override(g_cache);

    test_name_gate();
    test_byte_sniff();
    test_cache_name();
    test_file_sniff();
    test_transcode();
    test_lookup();
    test_open_has_no_placeholder();

    printf("md_webp_test: %d failure(s)\n", g_failures);
    return g_failures == 0 ? 0 : 1;
}
