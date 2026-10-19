/* tabs_names_test.c — pins portable/win/src/spdf_win_tabs_names.h, the
 * transcription of spdf_disambiguated_display_names_for_paths
 * (portable/mac/SPDFMacSupport.mm:82-137) and the label helpers it stands on.
 *
 * Header-only under test, so no `spdf-test-sources` line is needed. Every
 * expectation below is what the mac function returns for the same input; the
 * cases are the ones its own callers rely on -- two tabs with the same file
 * name in sibling folders, three where two folders also coincide, and the
 * exhausted case where the whole path is the only distinguishing thing.
 */
#include "spdf_win_tabs_names.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

static void check_name(const char* got, const char* want, const char* what) {
    ++g_checks;
    if (strcmp(got, want) != 0) {
        fprintf(stderr, "FAIL %s: got \"%s\", want \"%s\"\n", what, got, want);
        ++g_failures;
    }
}

static void names(const char* const* paths, int count, char (*out)[SPDF_WIN_TABS_NAME_MAX]) {
    spdf_win_tabs_display_names(paths, count, out);
}

static void test_labels(void) {
    char out[SPDF_WIN_TABS_NAME_MAX];
    spdf_win_tn_label_without_extension("report.pdf", 10, out, sizeof(out));
    check_name(out, "report", "a known extension is stripped");
    spdf_win_tn_label_without_extension("Report.PDF", 10, out, sizeof(out));
    check_name(out, "Report", "case-insensitively");
    spdf_win_tn_label_without_extension("notes.md", 8, out, sizeof(out));
    check_name(out, "notes", "markdown too");
    spdf_win_tn_label_without_extension("archive.zip", 11, out, sizeof(out));
    check_name(out, "archive.zip", "an unknown extension stays (macOS strips only what it opens)");
    spdf_win_tn_label_without_extension("Rev 2.1 schematic", 17, out, sizeof(out));
    check_name(out, "Rev 2.1 schematic", "a dot inside a name is not an extension");
    spdf_win_tn_label_without_extension("draft.pdf - copy", 16, out, sizeof(out));
    check_name(out, "draft - copy", "an extension followed by ' -' is removed where it stands (:27-29)");
    spdf_win_tn_label_without_extension("a.pdf.bak", 9, out, sizeof(out));
    check_name(out, "a.pdf.bak", "an extension followed by more name is not one");
}

static void test_no_collision(void) {
    const char* paths[] = {"C:\\Users\\r\\Docs\\alpha.pdf", "C:\\Users\\r\\Docs\\beta.pdf", "/home/r/gamma.md"};
    char out[3][SPDF_WIN_TABS_NAME_MAX];
    names(paths, 3, out);
    check_name(out[0], "alpha", "leaf, extension stripped, backslash path");
    check_name(out[1], "beta", "second leaf");
    check_name(out[2], "gamma", "a forward-slash path from another platform's session");
}

static void test_sibling_folders(void) {
    const char* paths[] = {"C:\\Projects\\Alpha\\spec.pdf", "C:\\Projects\\Beta\\spec.pdf", "C:\\Projects\\notes.pdf"};
    char out[3][SPDF_WIN_TABS_NAME_MAX];
    names(paths, 3, out);
    check_name(out[0], "Alpha/spec", "the folder joins the name for the first twin");
    check_name(out[1], "Beta/spec", "and for the second");
    check_name(out[2], "notes", "an uninvolved tab is untouched");
}

static void test_case_insensitive_collision(void) {
    const char* paths[] = {"D:\\a\\Report.pdf", "D:\\b\\report.PDF"};
    char out[2][SPDF_WIN_TABS_NAME_MAX];
    names(paths, 2, out);
    check_name(out[0], "a/Report", "REPORT and report collide case-insensitively (lowercaseString key)");
    check_name(out[1], "b/report", "each keeps its own spelling");
}

static void test_deeper_tail(void) {
    /* The parent folders coincide too, so tailLength 2 fails and tailLength 3
     * with one leading component is the first unique arrangement:
     * "x/.../spec" against "y/.../spec". */
    const char* paths[] = {"C:\\x\\shared\\spec.pdf", "C:\\y\\shared\\spec.pdf"};
    char out[2][SPDF_WIN_TABS_NAME_MAX];
    names(paths, 2, out);
    check_name(out[0], "x/.../spec", "a three-component tail elides the middle");
    check_name(out[1], "y/.../spec", "for both");
}

static void test_tail_grows_past_a_shared_folder(void) {
    /* Five deep, differing at the second component only. tailLength 2 gives
     * "deep/spec" twice, tailLength 3 gives "shared/.../spec" twice, and
     * tailLength 4 with one leading component is the first unique arrangement:
     * the tail starts at the differing folder, and the ellipsis hides the two
     * shared ones. */
    const char* paths[] = {"C:\\p\\shared\\deep\\spec.pdf", "C:\\q\\shared\\deep\\spec.pdf"};
    char out[2][SPDF_WIN_TABS_NAME_MAX];
    names(paths, 2, out);
    check_name(out[0], "p/.../spec", "the tail grows until its first component differs");
    check_name(out[1], "q/.../spec", "for both");
}

static void test_leading_count_grows(void) {
    /* Three tabs where no single folder tells all three apart: at tailLength 3
     * "m/.../spec" repeats, at tailLength 4 with one leading component
     * "a/.../spec" repeats, and only two leading components separate them. This
     * is the case the inner leadingCount loop exists for. */
    const char* paths[] = {"C:\\a\\m\\deep\\spec.pdf", "C:\\a\\n\\deep\\spec.pdf", "C:\\b\\m\\deep\\spec.pdf"};
    char out[3][SPDF_WIN_TABS_NAME_MAX];
    names(paths, 3, out);
    check_name(out[0], "a/m/.../spec", "two leading components once one is not enough");
    check_name(out[1], "a/n/.../spec", "for the second");
    check_name(out[2], "b/m/.../spec", "and the third");
}

static void test_exhausted(void) {
    /* Identical paths (the same file opened twice from two roots that the tab
     * model keeps distinct): nothing distinguishes them, so both show the full
     * path without extension. */
    const char* paths[] = {"C:\\one\\same.pdf", "C:\\one\\same.pdf"};
    char out[2][SPDF_WIN_TABS_NAME_MAX];
    names(paths, 2, out);
    check_name(out[0], "C:\\one\\same", "the full path without extension when nothing else helps");
    check_name(out[1], "C:\\one\\same", "for both");
}

static void test_degenerate(void) {
    const char* paths[] = {"", NULL, "lonely.pdf"};
    char out[3][SPDF_WIN_TABS_NAME_MAX];
    names(paths, 3, out);
    check_name(out[0], "", "an empty path is an empty name");
    check_name(out[1], "", "so is a NULL one");
    check_name(out[2], "lonely", "a bare file name with no folders");
    /* NULL out or paths must not crash. */
    spdf_win_tabs_display_names(NULL, 3, out);
    spdf_win_tabs_display_names(paths, 3, NULL);
    ++g_checks;
}

int main(void) {
    test_labels();
    test_no_collision();
    test_sibling_folders();
    test_case_insensitive_collision();
    test_deeper_tail();
    test_tail_grows_past_a_shared_folder();
    test_leading_count_grows();
    test_exhausted();
    test_degenerate();
    printf("tabs_names_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
