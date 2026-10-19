/* md_reload_test.c -- the off-thread Markdown re-read
 * (portable/win/src/spdf_win_md_reload.{h,cpp}).
 *
 * No window: begin() is given no HWND and the result is polled with take(),
 * which is the contract the header states so the thread is testable. What is
 * pinned: a re-read lands as a real document read from the path it was asked
 * for; a file that cannot be read parks nothing, so the reader keeps the last
 * good document; a second begin() while the first is in flight supersedes it,
 * so exactly one document lands and it is the last one asked for; shutdown
 * joins and leaves nothing parked.
 */
/* spdf-test-sources: portable/win/src/spdf_win_md_reload.cpp portable/win/src/spdf_win_md.cpp portable/win/src/spdf_win_md_code.cpp portable/win/src/spdf_win_md_images.cpp portable/win/src/spdf_win_md_webp.cpp portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c portable/core/spdf_markdown.c portable/core/spdf_markdown_support.c portable/core/spdf_markdown_html.c portable/core/spdf_markdown_lang.c portable/core/spdf_markdown_lex.c portable/core/spdf_markdown_math.c portable/core/spdf_markdown_fences.c portable/core/spdf_markdown_open.c ext/md4c/md4c.c portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c portable/win/src/spdf_win_open.c */
/* spdf-test-args: portable/win/tests/fixtures/readme-style.md %SCRATCH% */
/* spdf-test-needs: mupdf */
#include "spdf_win_md.h"
#include "spdf_win_md_reload.h"

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

/* Wait for the thread(s) to finish; a layout of the fixture is well under a
 * second, so 30 s is a hang, not a slow box. */
static int wait_idle(void) {
    int waited = 0;
    while (spdf_win_md_reload_in_flight() && waited < 30000) {
        Sleep(10);
        waited += 10;
    }
    return !spdf_win_md_reload_in_flight();
}

static void test_reread_lands(const char* md) {
    char path[1024] = {0};
    spdf_document* doc;
    EXPECT(spdf_win_md_reload_take(path, sizeof(path)) == NULL, "nothing parked before any begin");
    EXPECT(spdf_win_md_reload_begin(md, NULL, 0) == 1, "begin starts a thread");
    EXPECT(wait_idle(), "the re-read finishes");
    doc = spdf_win_md_reload_take(path, sizeof(path));
    EXPECT(doc != NULL, "a document landed");
    EXPECT(strcmp(path, md) == 0, "read from the path asked for: %s", path);
    if (doc) {
        EXPECT(spdf_page_count(doc) > 0, "it has pages: %d", spdf_page_count(doc));
        spdf_close(doc);
    }
    EXPECT(spdf_win_md_reload_take(path, sizeof(path)) == NULL, "take() hands a result over once");
    EXPECT(path[0] == 0, "and reports no path when there is nothing");
}

static void test_failed_read_parks_nothing(const char* scratch) {
    char missing[1024];
    _snprintf_s(missing, sizeof(missing), _TRUNCATE, "%s\\does-not-exist-%lu.md", scratch, GetCurrentProcessId());
    EXPECT(spdf_win_md_reload_begin(missing, NULL, 0) == 1, "begin starts even for a file that will fail");
    EXPECT(wait_idle(), "the failed re-read finishes");
    EXPECT(spdf_win_md_reload_take(NULL, 0) == NULL, "an unreadable file leaves the reader's document alone");
    EXPECT(spdf_win_md_reload_begin(NULL, NULL, 0) == 0, "a NULL path is refused");
    EXPECT(spdf_win_md_reload_begin("", NULL, 0) == 0, "an empty path is refused");
}

/* Two files so the path says which read landed. */
static void test_second_begin_supersedes(const char* md, const char* scratch) {
    char copy[1024], path[1024] = {0};
    FILE* in;
    FILE* out;
    spdf_document* doc;
    _snprintf_s(copy, sizeof(copy), _TRUNCATE, "%s\\reload-second-%lu.md", scratch, GetCurrentProcessId());
    in = fopen(md, "rb");
    out = fopen(copy, "wb");
    EXPECT(in && out, "the fixture can be copied to the scratch directory");
    if (in && out) {
        char buf[8192];
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), in)) > 0) fwrite(buf, 1, n, out);
        fputs("\n\n## Second\n\nThe second file.\n", out);
    }
    if (in) fclose(in);
    if (out) fclose(out);

    EXPECT(spdf_win_md_reload_begin(md, NULL, 0) == 1, "first begin");
    EXPECT(spdf_win_md_reload_begin(copy, NULL, 0) == 1, "second begin, at once");
    EXPECT(wait_idle(), "both re-reads finish");
    doc = spdf_win_md_reload_take(path, sizeof(path));
    EXPECT(doc != NULL, "exactly one document landed");
    EXPECT(strcmp(path, copy) == 0, "...and it is the LAST one asked for, not the first: %s", path);
    if (doc) spdf_close(doc);
    EXPECT(spdf_win_md_reload_take(NULL, 0) == NULL, "the superseded read parked nothing");

    /* A parked result nobody took is dropped by the next begin(). */
    EXPECT(spdf_win_md_reload_begin(md, NULL, 0) == 1, "third begin");
    EXPECT(wait_idle(), "it lands");
    EXPECT(spdf_win_md_reload_begin(copy, NULL, 0) == 1, "a fourth, before the third was taken");
    EXPECT(wait_idle(), "it lands too");
    doc = spdf_win_md_reload_take(path, sizeof(path));
    EXPECT(doc != NULL && strcmp(path, copy) == 0, "only the newest is parked: %s", path);
    if (doc) spdf_close(doc);
    EXPECT(spdf_win_md_reload_take(NULL, 0) == NULL, "nothing else");
    remove(copy);
}

static void test_shutdown(const char* md) {
    spdf_win_md_reload_shutdown(); /* idle: a no-op */
    EXPECT(spdf_win_md_reload_begin(md, NULL, 0) == 1, "begin before shutdown");
    spdf_win_md_reload_shutdown();
    EXPECT(!spdf_win_md_reload_in_flight(), "shutdown joined the thread");
    EXPECT(spdf_win_md_reload_take(NULL, 0) == NULL, "shutdown dropped the result");
    spdf_win_md_reload_shutdown(); /* idempotent */
}

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: md_reload_test readme-style.md scratch-dir\n");
        return 64;
    }
    test_reread_lands(argv[1]);
    test_failed_read_parks_nothing(argv[2]);
    test_second_begin_supersedes(argv[1], argv[2]);
    test_shutdown(argv[1]);
    if (g_failures) {
        fprintf(stderr, "md_reload_test: %d failure(s)\n", g_failures);
        return 1;
    }
    printf("md_reload_test: passed\n");
    return 0;
}
