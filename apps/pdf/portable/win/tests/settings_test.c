/* settings_test.c — portable/win/src/spdf_win_settings.{h,c} against the real,
 * shared portable/core/spdf_yaml.c codec and the real spdf_win_state file shell.
 *
 * Four claims, each about a way a settings file could quietly ruin somebody's
 * day rather than merely fail:
 *
 *   1. A settings.yaml THE MAC APP WROTE loads here with every key it carries,
 *      clamped the way the mac and GTK readers clamp it. The fixture is
 *      hand-written in the mac writer's shape, not produced by the code under
 *      test -- a round trip that only ever sees its own output proves nothing
 *      about the other two frontends.
 *   2. SAVING PRESERVES WHAT IT DOES NOT UNDERSTAND: the mac permission flags
 *      and the GTK extras survive a Windows rewrite byte for byte, so a shared
 *      file re-triggers no mac prompt and forgets no Linux choice.
 *   3. THE THEME IS TRI-STATE. A missing markdownTheme is "the system's" and is
 *      written back as missing; "dark" and "light" are read as the mac app reads
 *      them and written back as it writes them.
 *   4. NOTHING ON DISK MEANS DEFAULTS, and the defaults are the other
 *      frontends' defaults (fit page, both panels, images preserved, sleep
 *      prevented, print fit at 1.0, 1120 x 800).
 *
 * Exit code is the whole signal: 0 pass, 1 fail.
 */
/* spdf-test-sources: portable/win/src/spdf_win_settings.c portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c portable/core/spdf_win_compat.c portable/win/src/spdf_win_recents.c portable/win/src/spdf_win_watcher.cpp portable/win/src/spdf_win_watcher_shadow.cpp */
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif

#include "scratch_leaf.h" /* a scratch leaf unique to this process */
#include "silent_failure_support.h" /* check, write_whole/read_whole, remove_file */

#include "../src/spdf_win_recents.h"
#include "../src/spdf_win_settings.h"
#include "../src/spdf_win_state.h"

static void check_eq(int got, int want, const char* what) {
    if (got != want) {
        printf("FAIL: %s (got %d, want %d)\n", what, got, want);
        g_failures++;
    }
}

static void check_near(double got, double want, const char* what) {
    double delta = got > want ? got - want : want - got;
    if (delta > 0.00005) {
        printf("FAIL: %s (got %f, want %f)\n", what, got, want);
        g_failures++;
    }
}

static char g_settings_path[SPDF_WIN_PATH_MAX];

/* A settings.yaml in the shape the mac app writes (ShenzhenPDFMac.mm:1786-1813):
 * block mapping, sorted keys, the standard header comment, and two keys this
 * port has no feature for. minimapWidth is out of range on purpose. */
static const char* const kMacSettingsYaml =
    "# ShenzhenPDF settings \xe2\x80\x94 edit while the app is closed\n"
    "commentAuthor: \"Rapha\xc3\xabl\"\n"
    "darkThemePreservesImages: false\n"
    "defaultMinimapVisibleForNewDocuments: false\n"
    "defaultSidebarVisibleForNewDocuments: true\n"
    "fitMode: 2\n"
    "fullDiskAccessPromptDismissed: true\n"
    "markdownTheme: \"dark\"\n"
    "minimapWidth: 900\n"
    "preventSleepInPresentation: false\n"
    "printCustomScale: 1.5\n"
    "printScalingMode: 2\n"
    "searchJumpsToNearestResult: false\n"
    "sidebarWidth: 300\n"
    "windowSize:\n"
    "  height: 900\n"
    "  width: 1400\n";

/* --- 1. the mac schema, read -------------------------------------------- */

static void test_reads_a_mac_written_file(void) {
    spdf_win_settings s;
    remove_file(g_settings_path);
    if (!write_whole(g_settings_path, kMacSettingsYaml)) {
        check(0, "seed a mac-written settings.yaml");
        return;
    }
    check_eq((int)spdf_win_settings_load(&s), SPDF_WIN_SETTINGS_LOADED, "a mac-written file loads");
    check_eq(s.fit_mode, 2, "fitMode");
    check_eq(s.sidebar_width, 300, "sidebarWidth");
    check_near(s.minimap_width, 260.0, "minimapWidth is clamped to 260 as the mac reader clamps it (:1187)");
    check_eq(s.default_sidebar_visible, 1, "defaultSidebarVisibleForNewDocuments");
    check_eq(s.default_minimap_visible, 0, "defaultMinimapVisibleForNewDocuments");
    check_eq(s.search_jumps_to_nearest_result, 0, "searchJumpsToNearestResult");
    check_eq(s.prevent_sleep_in_presentation, 0, "preventSleepInPresentation");
    check_eq(s.print_scaling_mode, 2, "printScalingMode");
    check_near(s.print_custom_scale, 1.5, "printCustomScale");
    check_eq(s.window_width, 1400, "windowSize.width");
    check_eq(s.window_height, 900, "windowSize.height");
    check_eq(s.theme, SPDF_WIN_THEME_DARK, "markdownTheme dark reads as dark");
    check_eq(s.dark_theme_preserves_images, 0, "darkThemePreservesImages false is honoured");
}

/* --- 2. unknown keys survive a save -------------------------------------- */

static void test_save_carries_unknown_keys(void) {
    spdf_win_settings s;
    char* yaml;
    if (spdf_win_settings_load(&s) != SPDF_WIN_SETTINGS_LOADED) {
        check(0, "load before save");
        return;
    }
    s.sidebar_width = 220;
    s.dark_theme_preserves_images = 1;
    /* The recents module keeps the MRU order and this writer writes it: the
     * shared "recentlyOpened" key, once, by the file's one writer. */
    spdf_win_recents_note_opened("C:/Docs/Recent.pdf", NULL);
    check(spdf_win_settings_save(&s), "save succeeds");
    yaml = read_whole(g_settings_path);
    check(yaml != NULL, "the file is there after saving");
    if (!yaml) return;
    check(strstr(yaml, "recentlyOpened:") != NULL, "recentlyOpened is written by the settings writer");
    check(strstr(yaml, "Recent.pdf") != NULL, "and carries the document the recents module noted");
    check(strstr(yaml, "fullDiskAccessPromptDismissed: true") != NULL,
          "the mac permission flag survives a Windows rewrite (dropping it re-triggers the mac prompt)");
    check(strstr(yaml, "commentAuthor: \"Rapha\xc3\xabl\"") != NULL, "so does the comment author, non-ASCII intact");
    check(strstr(yaml, "sidebarWidth: 220") != NULL, "an owned key is rewritten");
    check(strstr(yaml, "darkThemePreservesImages: true") != NULL, "and so is a toggled bool");
    check(strstr(yaml, "markdownTheme: \"dark\"") != NULL, "a present theme stays present");
    check(strstr(yaml, "# ShenzhenPDF settings") != NULL, "with the standard header the codec derives from the stem");
    free(yaml);

    /* And it reads back as itself. */
    memset(&s, 0, sizeof(s));
    check_eq((int)spdf_win_settings_load(&s), SPDF_WIN_SETTINGS_LOADED, "reload");
    check_eq(s.sidebar_width, 220, "the rewritten width reads back");
    check_eq(s.window_width, 1400, "and an untouched one is unchanged");
}

/* --- 3. the theme is tri-state ------------------------------------------- */

static void test_theme_absent_stays_absent(void) {
    spdf_win_settings s;
    char* yaml;
    remove_file(g_settings_path);
    check_eq((int)spdf_win_settings_load(&s), SPDF_WIN_SETTINGS_ABSENT, "no file is ABSENT");
    check_eq(s.theme, SPDF_WIN_THEME_SYSTEM, "no file means follow the system");
    check(spdf_win_settings_save(&s), "saving the defaults succeeds");
    yaml = read_whole(g_settings_path);
    check(yaml && strstr(yaml, "markdownTheme") == NULL, "an unexpressed theme is not written (macOS would read it as light)");
    free(yaml);

    s.theme = SPDF_WIN_THEME_LIGHT;
    check(spdf_win_settings_save(&s), "save light");
    yaml = read_whole(g_settings_path);
    check(yaml && strstr(yaml, "markdownTheme: \"light\"") != NULL, "an expressed light theme is written as the mac writes it");
    free(yaml);
    memset(&s, 0, sizeof(s));
    spdf_win_settings_load(&s);
    check_eq(s.theme, SPDF_WIN_THEME_LIGHT, "and reads back as light, not as system");
}

/* --- 4. defaults are the other frontends' -------------------------------- */

static void test_defaults(void) {
    spdf_win_settings s;
    spdf_win_settings_init_defaults(&s);
    check_eq(s.fit_mode, 4, "fit page");
    check_near(s.zoom, 1.0, "zoom 1");
    check_eq(s.sidebar_width, 240, "sidebar 240");
    check_near(s.minimap_width, 126.5, "minimap 126.5 (the odd default is macOS's)");
    check_eq(s.default_sidebar_visible, 1, "sidebar shown for new documents");
    check_eq(s.default_minimap_visible, 1, "minimap shown for new documents");
    check_eq(s.search_jumps_to_nearest_result, 1, "nearest-result jump on");
    check_eq(s.prevent_sleep_in_presentation, 1, "sleep prevented while presenting");
    check_eq(s.print_scaling_mode, 0, "print fit");
    check_near(s.print_custom_scale, 1.0, "print custom 1.0");
    check_eq(s.window_width, 1120, "1120 wide");
    check_eq(s.window_height, 800, "800 tall");
    check_eq(s.theme, SPDF_WIN_THEME_SYSTEM, "system theme");
    check_eq(s.dark_theme_preserves_images, 1, "Keep Image Colors defaults ON (26.9.1-1)");

    /* The pure parser clamps and tolerates. */
    check_eq(spdf_win_settings_parse_json(&s, "{\"fitMode\":9,\"printScalingMode\":-1,\"zoom\":100,\"sidebarWidth\":10}"),
             4, "four keys applied");
    check_eq(s.fit_mode, 4, "fitMode clamps high");
    check_eq(s.print_scaling_mode, 0, "printScalingMode clamps low");
    check_near(s.zoom, 8.0, "zoom clamps to 8");
    check_eq(s.sidebar_width, 140, "sidebar clamps to 140");
    check_eq(spdf_win_settings_parse_json(&s, "not json"), 0, "garbage applies nothing");
    check_eq(spdf_win_settings_parse_json(&s, NULL), 0, "NULL applies nothing");
    check_eq(s.fit_mode, 4, "and leaves the struct alone");
}

/* --- 5. printerName, the Windows-only key -------------------------------- */

/* WHY IT IS ITS OWN CASE. printerName is the one key in this schema no other
 * frontend has (spdf_win_settings.h), so nothing else in this suite would
 * notice if it were written unconditionally -- and a key saying `printerName:
 * ""` in the settings.yaml of a reader who has never printed is exactly the
 * kind of noise the carry-through rules above exist to prevent. So both halves
 * are checked: absent while unset, present and non-ASCII-intact once set, and
 * round-tripping either way. */
static void test_printer_name(void) {
    spdf_win_settings s;
    char* yaml;

    spdf_win_settings_init_defaults(&s);
    check(s.printer_name[0] == '\0', "no printer is remembered by default");

    remove_file(g_settings_path);
    check(spdf_win_settings_save(&s), "saving with no printer succeeds");
    yaml = read_whole(g_settings_path);
    check(yaml && strstr(yaml, "printerName") == NULL, "an unset printer is not written at all");
    free(yaml);

    /* A printer name is a display string and can be anything the driver's
     * vendor typed; UTF-8 out and back is the property that matters. */
    strncpy_s(s.printer_name, sizeof(s.printer_name), "Brother DCP-L3550CDW s\xc3\xa9ries", _TRUNCATE);
    check(spdf_win_settings_save(&s), "saving with a printer succeeds");
    yaml = read_whole(g_settings_path);
    check(yaml && strstr(yaml, "printerName:") != NULL, "a chosen printer is written");
    check(yaml && strstr(yaml, "s\xc3\xa9ries") != NULL, "with its bytes intact");
    free(yaml);

    memset(&s, 0, sizeof(s));
    check_eq((int)spdf_win_settings_load(&s), SPDF_WIN_SETTINGS_LOADED, "reload");
    check(strcmp(s.printer_name, "Brother DCP-L3550CDW s\xc3\xa9ries") == 0, "and reads back exactly");

    check_eq(spdf_win_settings_parse_json(&s, "{\"printerName\":\"Microsoft Print to PDF\"}"), 1,
             "the pure parser applies it");
    check(strcmp(s.printer_name, "Microsoft Print to PDF") == 0, "as given");
}

/* --- 6. the shared copy -------------------------------------------------- */

static void test_shared_copy(void) {
    spdf_win_settings* shared;
    remove_file(g_settings_path);
    spdf_win_settings_reset_shared();
    shared = spdf_win_settings_shared();
    check(shared != NULL, "the shared copy is never NULL");
    check_eq((int)spdf_win_settings_shared_status(), SPDF_WIN_SETTINGS_ABSENT, "and reports how it loaded");
    shared->search_jumps_to_nearest_result = 0;
    check(spdf_win_settings_commit(), "commit writes it");
    spdf_win_settings_reset_shared();
    check_eq(spdf_win_settings_shared()->search_jumps_to_nearest_result, 0, "and the next process reads it back");
}

int main(int argc, char** argv) {
    char dir[SPDF_WIN_PATH_MAX];

    printf("spdf_win_settings tests\n");
    if (!spdf_test_state_dir(argc, argv, "spdf_settings_test", SPDF_TEST_SCRATCH_STEM, dir, sizeof(dir))) {
        printf("FAIL: could not create the scratch directory\n");
        return 1;
    }
    spdf_win_paths_set_state_dir_override(dir);
    if (!spdf_win_paths_state_file(SPDF_WIN_STATE_SETTINGS, g_settings_path, sizeof(g_settings_path))) return 1;

    test_reads_a_mac_written_file();
    test_save_carries_unknown_keys();
    test_theme_absent_stays_absent();
    test_defaults();
    test_printer_name();
    test_shared_copy();

    remove_file(g_settings_path);
    spdf_win_paths_set_state_dir_override(NULL);
    if (g_failures) {
        printf("%d failure(s)\n", g_failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
