/* End-to-end regression tests for the PDF save paths in shenzhen_pdf_core.c.
 *
 * Both spdf_delete_all_text() and the non-incremental branch of
 * spdf_save_document() finish the same way: write a temp file built by
 * create_temp_save_path(), then move it over the destination. Two things about
 * that sequence were wrong on Windows and silent on every platform:
 *
 *   - create_temp_save_path() split the directory on '/' only, so a Windows
 *     path produced dir_len == 0 and the temp file was created in the process
 *     CWD rather than beside the destination -- frequently a different volume,
 *     which is exactly what an atomic replace cannot cross.
 *   - rename() cannot replace an existing file on Windows, so saving over a
 *     document that already existed failed every single time.
 *
 * These tests pin the observable contract on any host: saving over an existing
 * file succeeds, the result is a readable PDF, and no temp file is left behind
 * in the working directory. SPDFCoreCompatTests.c covers the two shims
 * underneath directly, including the Windows path regime.
 */
#include "shenzhen_pdf_core.h"

#include "spdf_win_compat.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <io.h>
#else
#include <dirent.h>
#endif

static int g_failures = 0;

#define EXPECT(condition, ...)                         \
    do {                                               \
        if (!(condition)) {                            \
            fprintf(stderr, "FAIL " __VA_ARGS__);      \
            fprintf(stderr, " [line %d]\n", __LINE__); \
            ++g_failures;                              \
        }                                              \
    } while (0)

/* A one-page PDF carrying a line of text, assembled here so the suite needs no
 * fixture file and no external tool. */
static int write_fixture_pdf(const char* path) {
    static const char* objects[] = {
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> >> "
         "/Contents 5 0 R >>"),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    };
    static const char* stream = "BT /F1 24 Tf 36 110 Td (Save fixture) Tj ET\n";
    long offsets[6];
    int count = (int)(sizeof(objects) / sizeof(objects[0])) + 1;
    long xref;
    int i;
    FILE* f = fopen(path, "wb");

    if (!f) return 0;
    fprintf(f, "%%PDF-1.4\n%%\xe2\xe3\xcf\xd3\n");
    for (i = 0; i < count - 1; ++i) {
        offsets[i] = ftell(f);
        fprintf(f, "%d 0 obj\n%s\nendobj\n", i + 1, objects[i]);
    }
    offsets[count - 1] = ftell(f);
    fprintf(f, "%d 0 obj\n<< /Length %d >>\nstream\n%sendstream\nendobj\n", count, (int)strlen(stream), stream);

    xref = ftell(f);
    fprintf(f, "xref\n0 %d\n0000000000 65535 f \n", count + 1);
    for (i = 0; i < count; ++i) fprintf(f, "%010ld 00000 n \n", offsets[i]);
    fprintf(f, "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%ld\n%%%%EOF\n", count + 1, xref);
    return fclose(f) == 0;
}

static int copy_file(const char* from, const char* to) {
    FILE* src = fopen(from, "rb");
    FILE* dst;
    char buffer[4096];
    size_t got;

    if (!src) return 0;
    dst = fopen(to, "wb");
    if (!dst) {
        fclose(src);
        return 0;
    }
    while ((got = fread(buffer, 1, sizeof(buffer), src)) > 0)
        if (fwrite(buffer, 1, got, dst) != got) break;
    fclose(src);
    return fclose(dst) == 0;
}

static int file_exists(const char* path) {
    FILE* f = fopen(path, "rb");

    if (!f) return 0;
    fclose(f);
    return 1;
}

/* Any .shenzhenpdf-save-* entry in the working directory means
 * create_temp_save_path() lost the destination's directory and fell back to the
 * CWD -- bug (1) above, observed from outside the core. */
static int temp_file_left_in_cwd(void) {
#ifdef _WIN32
    struct _finddata_t info;
    intptr_t handle = _findfirst(".shenzhenpdf-save-*", &info);

    if (handle == -1) return 0;
    _findclose(handle);
    return 1;
#else
    static const char prefix[] = ".shenzhenpdf-save-";
    DIR* directory = opendir(".");
    struct dirent* entry;
    int found = 0;

    if (!directory) return 0;
    while ((entry = readdir(directory)) != NULL)
        if (strncmp(entry->d_name, prefix, sizeof(prefix) - 1) == 0) found = 1;
    closedir(directory);
    return found;
#endif
}

static char* join(const char* dir, const char* leaf) {
    size_t len = strlen(dir) + strlen(leaf) + 2;
    char* path = (char*)malloc(len);

    if (!path) return NULL;
    snprintf(path, len, "%s" SPDF_PATH_SEP_STR "%s", dir, leaf);
    return path;
}

/* THE SAVE BUG, end to end: the destination already exists, which is the only
 * case that matters in practice -- a user saving an edit back over their own
 * document. This failed on every Windows save before MoveFileExW landed. */
static void test_delete_all_text_over_existing_file(const char* dir) {
    char* source = join(dir, "save-source.pdf");
    char* target = join(dir, "save-target.pdf");
    char err[512];
    spdf_document* doc;

    if (!source || !target) {
        EXPECT(0, "out of memory");
        free(source);
        free(target);
        return;
    }
    EXPECT(write_fixture_pdf(source), "fixture written");
    EXPECT(copy_file(source, target), "destination seeded so the save must overwrite");
    EXPECT(file_exists(target), "destination exists before the save");

    doc = spdf_open(source, err, sizeof(err));
    EXPECT(doc != NULL, "fixture opens: %s", err);
    if (doc) {
        EXPECT(spdf_page_count(doc) == 1, "fixture has one page");
        EXPECT(spdf_delete_all_text(doc, target, err, sizeof(err)) == 1, "save over an existing file: %s", err);
        spdf_close(doc);
    }
    EXPECT(!temp_file_left_in_cwd(), "no temp file leaked into the working directory");

    /* The replaced file must still be a document, not a truncated temp file. */
    doc = spdf_open(target, err, sizeof(err));
    EXPECT(doc != NULL, "replaced destination reopens: %s", err);
    if (doc) {
        EXPECT(spdf_page_count(doc) == 1, "replaced destination still has one page");
        spdf_close(doc);
    }

    remove(source);
    remove(target);
    free(source);
    free(target);
}

/* The same save run twice over the same destination: the second run is the one
 * that would have hit ERROR_ALREADY_EXISTS against a file this very test wrote. */
static void test_repeated_saves_over_the_same_file(const char* dir) {
    char* source = join(dir, "repeat-source.pdf");
    char* target = join(dir, "repeat-target.pdf");
    char err[512];
    int round;

    if (!source || !target) {
        EXPECT(0, "out of memory");
        free(source);
        free(target);
        return;
    }
    EXPECT(write_fixture_pdf(source), "fixture written");
    EXPECT(copy_file(source, target), "destination seeded");

    for (round = 0; round < 3; ++round) {
        spdf_document* doc = spdf_open(source, err, sizeof(err));
        EXPECT(doc != NULL, "round %d opens: %s", round, err);
        if (!doc) break;
        EXPECT(spdf_delete_all_text(doc, target, err, sizeof(err)) == 1, "round %d saves: %s", round, err);
        spdf_close(doc);
        EXPECT(file_exists(target), "round %d left the destination in place", round);
    }
    EXPECT(!temp_file_left_in_cwd(), "no temp file leaked across repeated saves");

    remove(source);
    remove(target);
    free(source);
    free(target);
}

/* spdf_save_document() must succeed whether or not it takes the temp-and-replace
 * branch, and must never leave the destination missing. */
static void test_save_document_over_existing_file(const char* dir) {
    char* source = join(dir, "doc-source.pdf");
    char* target = join(dir, "doc-target.pdf");
    char err[512];
    spdf_document* doc;

    if (!source || !target) {
        EXPECT(0, "out of memory");
        free(source);
        free(target);
        return;
    }
    EXPECT(write_fixture_pdf(source), "fixture written");
    EXPECT(copy_file(source, target), "destination seeded");

    doc = spdf_open(target, err, sizeof(err));
    EXPECT(doc != NULL, "destination opens: %s", err);
    if (doc) {
        EXPECT(spdf_save_document(doc, target, err, sizeof(err)) == 1, "save onto itself: %s", err);
        spdf_close(doc);
    }
    EXPECT(file_exists(target), "destination survives the save");
    EXPECT(!temp_file_left_in_cwd(), "no temp file leaked from spdf_save_document");

    doc = spdf_open(target, err, sizeof(err));
    EXPECT(doc != NULL, "saved document reopens: %s", err);
    if (doc) {
        EXPECT(spdf_page_count(doc) == 1, "saved document still has one page");
        spdf_close(doc);
    }

    remove(source);
    remove(target);
    free(source);
    free(target);
}

int main(int argc, char** argv) {
    const char* dir = argc > 1 ? argv[1] : ".";

    test_delete_all_text_over_existing_file(dir);
    test_repeated_saves_over_the_same_file(dir);
    test_save_document_over_existing_file(dir);

    if (g_failures) {
        fprintf(stderr, "SPDFCoreSaveTests: %d failure(s)\n", g_failures);
        return 1;
    }
    printf("SPDFCoreSaveTests: all checks passed\n");
    return 0;
}
