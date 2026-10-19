/* THE ANNOTATIONS DIFFERENTIAL: portable/win/src/spdf_win_annot_model.h section
 * 1 versus the GTK4 original it was transcribed from, portable/linux/gtk4/
 * spdf_annot.c section 1 -- compiled here exactly as the GTK tree's own
 * tests/annot_preflight_test.c compiles it (SPDF_ANNOT_TESTING, the .c
 * included whole) -- both in ONE binary, driven with identical inputs,
 * compared for EXACT equality.
 *
 * Same instrument as sidebar_differential.c, for the same reason: a
 * hand-written test asserts what its author remembered, this one asserts each
 * function against the implementation it was ported from. Strings are compared
 * with strcmp and integers with ==; a one-byte difference is a transcription
 * error, not a rounding question.
 *
 * TWO HONEST LIMITS, both stated in the port's header and the shim's: the
 * paths are forward-slash (G_DIR_SEPARATOR is '/' on the GTK side, and the port
 * accepts both), and g_canonicalize_filename is identity on the GTK side so the
 * CONTAINMENT rule is what is compared, not glib's dot-segment collapse. The
 * backslash spellings are pinned by annot_model_test.c.
 *
 * Not named *_test.c on purpose, so run-tests-native.sh's sweep does not build
 * it without the three include paths. Build and run it with:
 *
 *   portable\win\tests\annot-differential-native.cmd
 *
 * and judge it by its exit code.
 */
#define SPDF_ANNOT_TESTING 1

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The GTK4 original, whole, under the layered shim (glib_shim_annot first). */
#include "spdf_annot.c"

/* The port. */
#include "spdf_win_annot_model.h"

static int mismatches;
static long comparisons;

static void same_i(const char* what, long long win, long long gtk) {
    comparisons++;
    if (win != gtk) {
        printf("DIFFER %s: win=%lld gtk=%lld\n", what, win, gtk);
        mismatches++;
    }
}

static void same_s(const char* what, const char* win, const char* gtk) {
    comparisons++;
    if ((win == NULL) != (gtk == NULL) || (win && gtk && strcmp(win, gtk) != 0)) {
        printf("DIFFER %s: win=\"%s\" gtk=\"%s\"\n", what, win ? win : "(null)", gtk ? gtk : "(null)");
        mismatches++;
    }
}

static const char* kPaths[] = {
    NULL,
    "",
    "/a/b/doc.pdf",
    "/a/b/DOC.PDF",
    "/a/b/doc.PdF",
    "/a/b/doc.pdf.bak",
    "/a/b/doc",
    "/a/b/pdf",
    "/a/b/.pdf",
    "/a/b/doc.",
    "/tmp",
    "/tmp/",
    "/tmp/x.pdf",
    "/tmp/a/b/c.pdf",
    "/tmpfiles/x.pdf",
    "/var/tmp/doc.pdf",
    "/var/tmp",
    "/custom/tmp/doc.pdf",
    "/run/user/1000/doc.pdf",
    "/run/user/1000",
    "/home/u/doc.pdf",
    "/home/u/Z\xc3\xbcrich.PDF",
    "/home/u/\xe7\xac\xac\xe4\xb8\x80\xe7\xab\xa0.pdf",
    "relative.pdf",
    "relative",
    "///",
    "/",
    ".",
    "..",
    "/a/b/report.final.pdf",
    "/a/b/report - page 3.pdf",
    "/a/b/.hidden",
    "/a/b/dir/",
};

static const char* kDirs[] = {NULL, "", "/tmp", "/tmp/", "/var/tmp", "/custom/tmp", "/run/user/1000", "/home/u",
                              "/", "/a", "/a/b", "relative"};

static void differential_paths(void) {
    char label[256];
    size_t p, d, r;
    for (p = 0; p < sizeof(kPaths) / sizeof(kPaths[0]); ++p) {
        const char* path = kPaths[p];
        char* w;
        char* g;
        int page;

        sprintf(label, "has_pdf_extension[%zu]", p);
        same_i(label, spdf_win_annot_path_has_pdf_extension(path), spdf_annot_path_has_pdf_extension(path));

        w = spdf_win_annot_filename_with_pdf_extension(path);
        g = spdf_annot_filename_with_pdf_extension(path);
        sprintf(label, "filename_with_pdf_extension[%zu]", p);
        same_s(label, w, g);
        free(w);
        g_free(g);

        for (page = -1; page <= 3; ++page) {
            w = spdf_win_annot_single_page_filename(path, page);
            g = spdf_annot_single_page_filename(path, page);
            sprintf(label, "single_page_filename[%zu][page=%d]", p, page);
            same_s(label, w, g);
            free(w);
            g_free(g);
        }

        for (d = 0; d < sizeof(kDirs) / sizeof(kDirs[0]); ++d) {
            sprintf(label, "is_under_directory[%zu][%zu]", p, d);
            same_i(label, spdf_win_annot_path_is_under_directory(path, kDirs[d]),
                   spdf_annot_path_is_under_directory(path, kDirs[d]));
            for (r = 0; r < sizeof(kDirs) / sizeof(kDirs[0]); ++r) {
                sprintf(label, "is_temp_in[%zu][tmp=%zu][rt=%zu]", p, d, r);
                same_i(label, spdf_win_annot_path_is_temp_in(path, kDirs[d], kDirs[r]),
                       spdf_annot_path_is_temp_in(path, kDirs[d], kDirs[r]));
                sprintf(label, "save_target_acceptable[%zu][tmp=%zu][rt=%zu]", p, d, r);
                same_i(label, spdf_win_annot_save_target_acceptable(path, kDirs[d], kDirs[r]),
                       spdf_annot_save_target_acceptable(path, kDirs[d], kDirs[r]));
            }
        }
    }
}

static void differential_verdict(void) {
    char label[64];
    int t, f, d;
    for (t = 0; t <= 1; ++t)
        for (f = 0; f <= 1; ++f)
            for (d = 0; d <= 1; ++d) {
                sprintf(label, "same_folder_write_allowed[%d%d%d]", t, f, d);
                same_i(label, spdf_win_annot_same_folder_write_allowed(t, f, d),
                       spdf_annot_same_folder_write_allowed(t, f, d));
            }
}

int main(void) {
    differential_paths();
    differential_verdict();
    printf("[annot-differential] %ld comparisons, %d differ\n", comparisons, mismatches);
    if (comparisons <= 0) {
        printf("[annot-differential] the matrix did not run\n");
        return 2;
    }
    return mismatches == 0 ? 0 : 1;
}
