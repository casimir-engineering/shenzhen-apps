/* toolchain_test.c -- pins the PURE half of portable/win/src/spdf_win_toolchain.h
 * (spdf_win_toolchain.cpp, _cmd.cpp, _plan.cpp), with strings only: where each
 * tool is looked for, how PATH is walked (the filesystem is a callback), how
 * versions are read out of --version banners, the Tesseract language helpers
 * and the Argos helpers the GTK suite pins (portable/linux/gtk4/tests/
 * toolchain_test.c, same cases), the exact command lines the installer will
 * run, the install plans, the live-log line splitter and the settings JSON
 * accessors.
 *
 * NO network, NO installer, NO real tool, NO subprocess: the plan functions
 * produce command lines and nothing here runs them. The subprocess seam has
 * its own suite, toolchain_run_test.c, against a fake tesseract.cmd.
 */
/* spdf-test-sources: portable/win/src/spdf_win_toolchain.cpp portable/win/src/spdf_win_toolchain_cmd.cpp portable/win/src/spdf_win_toolchain_plan.cpp */
#include "spdf_win_toolchain.h"

#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

static void fail(const char* what, const char* file, int line) {
    fprintf(stderr, "FAIL %s (%s:%d)\n", what, file, line);
    ++g_failures;
}

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) fail(#cond, __FILE__, __LINE__);                                                                   \
    } while (0)

#define CHECK_STR(a, b)                                                                                                \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (strcmp((a), (b)) != 0) {                                                                                   \
            fprintf(stderr, "FAIL %s == \"%s\" (got \"%s\") (%s:%d)\n", #a, (b), (a), __FILE__, __LINE__);            \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

static void roots_fixture(SpdfWinToolchainRoots* r) {
    memset(r, 0, sizeof(*r));
    strcpy(r->program_files, "C:\\Program Files");
    strcpy(r->local_appdata, "C:\\Users\\Ren\\AppData\\Local");
    strcpy(r->user_profile, "C:\\Users\\Ren");
    strcpy(r->system_root, "C:\\Windows");
    strcpy(r->user_scripts, "C:\\Users\\Ren\\AppData\\Local\\Packages\\Py\\LocalCache\\local-packages\\Python313\\Scripts");
    strcpy(r->path_env, "C:\\Windows\\System32;\"C:\\Tools With Space\";;C:\\Users\\Ren\\bin");
}

/* --- candidates and PATH --------------------------------------------------- */

static int fake_exists(const char* path, void* user) {
    const char* const* have = (const char* const*)user;
    for (int i = 0; have[i]; ++i)
        if (_stricmp(have[i], path) == 0) return 1;
    return 0;
}

static void test_candidates(void) {
    SpdfWinToolchainRoots r;
    char out[SPDF_WIN_TC_MAX_CANDIDATES][SPDF_WIN_TC_PATH];
    roots_fixture(&r);
    CHECK_STR(spdf_win_tool_exe(SPDF_WIN_TOOL_TESSERACT), "tesseract.exe");
    CHECK_STR(spdf_win_tool_exe(SPDF_WIN_TOOL_GHOSTSCRIPT), "gswin64c.exe");
    CHECK(spdf_win_toolchain_candidates(SPDF_WIN_TOOL_TESSERACT, &r, out) == 3);
    CHECK_STR(out[0], "C:\\Program Files\\Tesseract-OCR\\tesseract.exe");
    CHECK(spdf_win_toolchain_candidates(SPDF_WIN_TOOL_GHOSTSCRIPT, &r, out) == 2);
    CHECK_STR(out[0], "C:\\Users\\Ren\\AppData\\Local\\Programs\\gs\\gs*\\bin\\gswin64c.exe");
    CHECK_STR(out[1], "C:\\Program Files\\gs\\gs*\\bin\\gswin64c.exe");
    CHECK(spdf_win_toolchain_candidates(SPDF_WIN_TOOL_OCRMYPDF, &r, out) == 1);
    CHECK_STR(out[0],
              "C:\\Users\\Ren\\AppData\\Local\\Packages\\Py\\LocalCache\\local-packages\\Python313\\Scripts\\ocrmypdf.exe");
    CHECK(spdf_win_toolchain_candidates(SPDF_WIN_TOOL_CURL, &r, out) == 1);
    CHECK_STR(out[0], "C:\\Windows\\System32\\curl.exe");
    CHECK(spdf_win_toolchain_tessdata_parent(&r, out[0], SPDF_WIN_TC_PATH));
    CHECK_STR(out[0], "C:\\Users\\Ren\\.shenzhenpdf\\tesseract");
    /* No Python: no scripts directory, so no pip --user candidate; the Argos
     * venv location is still looked at. */
    r.user_scripts[0] = '\0';
    CHECK(spdf_win_toolchain_candidates(SPDF_WIN_TOOL_OCRMYPDF, &r, out) == 0);
    CHECK(spdf_win_toolchain_candidates(SPDF_WIN_TOOL_ARGOSPM, &r, out) == 1);
}

static void test_search_path(void) {
    SpdfWinToolchainRoots r;
    const char* have[] = {"C:\\Tools With Space\\tesseract.exe", "C:\\Users\\Ren\\bin\\curl.exe", NULL};
    char out[SPDF_WIN_TC_PATH];
    roots_fixture(&r);
    /* Quoted entry and empty entry are handled as the shell handles them. */
    CHECK(spdf_win_toolchain_search_path_env(r.path_env, "tesseract.exe", fake_exists, (void*)have, out, sizeof(out)));
    CHECK_STR(out, "C:\\Tools With Space\\tesseract.exe");
    CHECK(spdf_win_toolchain_search_path_env(r.path_env, "curl.exe", fake_exists, (void*)have, out, sizeof(out)));
    CHECK_STR(out, "C:\\Users\\Ren\\bin\\curl.exe");
    CHECK(!spdf_win_toolchain_search_path_env(r.path_env, "gswin64c.exe", fake_exists, (void*)have, out, sizeof(out)));
    CHECK(!spdf_win_toolchain_search_path_env(NULL, "x.exe", fake_exists, (void*)have, out, sizeof(out)));
}

static void test_versions(void) {
    const char* names[] = {"gs9.56.1", "gs10.07.1", "gs10.5.0", "readme"};
    int maj = 0, min = 0, pat = 0;
    CHECK(spdf_win_toolchain_newest_version_index(names, 4) == 1);
    CHECK(spdf_win_toolchain_newest_version_index(names, 0) == -1);
    CHECK(spdf_win_toolchain_parse_version("tesseract v5.4.0.20240606\n leptonica-1.84.1", &maj, &min, &pat));
    CHECK(maj == 5 && min == 4 && pat == 0);
    CHECK(spdf_win_toolchain_parse_version("Python 3.13.14", &maj, &min, &pat));
    CHECK(maj == 3 && min == 13 && pat == 14);
    CHECK(spdf_win_toolchain_parse_version("GPL Ghostscript 10.07.1 (2025-09-30)", &maj, &min, &pat));
    CHECK(maj == 10 && min == 7 && pat == 1);
    CHECK(!spdf_win_toolchain_parse_version("no numbers here", &maj, &min, &pat));
}

/* --- languages and Argos (GTK toolchain_test.c cases) ---------------------- */

static void test_languages(void) {
    char parts[8][32];
    const char* output = "List of available languages (3):\neng\nosd\nchi_sim\n";
    CHECK(spdf_win_ocr_language_components("chi_sim+eng", parts) == 2);
    CHECK_STR(parts[0], "chi_sim");
    CHECK_STR(parts[1], "eng");
    CHECK(spdf_win_ocr_language_components(NULL, parts) == 1);
    CHECK_STR(parts[0], "eng");
    CHECK(spdf_win_ocr_language_uses_extra_traineddata("chi_sim+eng"));
    CHECK(spdf_win_ocr_language_uses_extra_traineddata("deu"));
    CHECK(!spdf_win_ocr_language_uses_extra_traineddata("eng"));
    CHECK(!spdf_win_ocr_language_uses_extra_traineddata(NULL));
    CHECK(spdf_win_toolchain_list_output_has_language(output, "eng"));
    CHECK(spdf_win_toolchain_list_output_has_language(output, "chi_sim+eng"));
    CHECK(!spdf_win_toolchain_list_output_has_language(output, "chi_tra+eng"));
    CHECK(!spdf_win_toolchain_list_output_has_language(output, "deu"));
    CHECK(!spdf_win_toolchain_list_output_has_language("", "eng"));
    CHECK(!spdf_win_toolchain_list_output_has_language("engx\n", "eng"));
    /* Windows tesseract prints CRLF. */
    CHECK(spdf_win_toolchain_list_output_has_language("List:\r\neng\r\nosd\r\n", "eng"));
}

static void test_argos_helpers(void) {
    const char* diagnostic = "WARNING: Language zh package translate-zh_en expects Argos 1.9 which has been added";
    char out[512], name[64];
    CHECK(spdf_win_toolchain_is_argos_diagnostic_line(diagnostic, 0));
    CHECK(spdf_win_toolchain_is_argos_diagnostic_line("added", 1));
    CHECK(spdf_win_toolchain_is_argos_diagnostic_line("which has been added", 1));
    CHECK(!spdf_win_toolchain_is_argos_diagnostic_line("added", 0));
    CHECK(!spdf_win_toolchain_is_argos_diagnostic_line("Hello world", 0));
    spdf_win_toolchain_strip_argos_diagnostics(
        "WARNING: Language zh package x expects y\nadded\nTranslated line\n", out, sizeof(out));
    CHECK_STR(out, "Translated line\n");
    spdf_win_toolchain_strip_argos_diagnostics("A\nB", out, sizeof(out));
    CHECK_STR(out, "A\nB");
    spdf_win_toolchain_strip_argos_diagnostics("WARNING: Language a package b expects c", out, sizeof(out));
    CHECK_STR(out, "");
    CHECK(spdf_win_toolchain_argos_failure_is_missing_package("Error: 'zh' is not an installed language."));
    CHECK(spdf_win_toolchain_argos_failure_is_missing_package("No package found matching translate-zh_en"));
    CHECK(!spdf_win_toolchain_argos_failure_is_missing_package("Traceback (most recent call last):"));
    CHECK(!spdf_win_toolchain_argos_failure_is_missing_package(""));
    CHECK(spdf_win_toolchain_argos_package_name("zh", "en", name, sizeof(name)));
    CHECK_STR(name, "translate-zh_en");
    CHECK(!spdf_win_toolchain_argos_package_name("", "en", name, sizeof(name)));
}

/* --- command lines ------------------------------------------------------------ */

static void test_command_lines(void) {
    char cmd[SPDF_WIN_TC_CMD];
    const char* pkgs[] = {"ocrmypdf"};
    spdf_win_toolchain_quote_arg("plain", cmd, sizeof(cmd));
    CHECK_STR(cmd, "plain");
    spdf_win_toolchain_quote_arg("C:\\Program Files\\x.exe", cmd, sizeof(cmd));
    CHECK_STR(cmd, "\"C:\\Program Files\\x.exe\"");
    spdf_win_toolchain_quote_arg("say \"hi\"", cmd, sizeof(cmd));
    CHECK_STR(cmd, "\"say \\\"hi\\\"\"");
    spdf_win_toolchain_quote_arg("trail\\", cmd, sizeof(cmd));
    CHECK_STR(cmd, "trail\\"); /* no spaces: unquoted, backslash kept */
    spdf_win_toolchain_quote_arg("a b\\", cmd, sizeof(cmd));
    CHECK_STR(cmd, "\"a b\\\\\""); /* trailing backslash doubled before the closing quote */
    spdf_win_toolchain_quote_arg("", cmd, sizeof(cmd));
    CHECK_STR(cmd, "\"\"");

    spdf_win_toolchain_winget_cmd("C:\\W\\winget.exe", SPDF_WIN_TC_WINGET_TESSERACT, 0, cmd, sizeof(cmd));
    CHECK_STR(cmd, "C:\\W\\winget.exe install --id UB-Mannheim.TesseractOCR -e --accept-source-agreements "
                   "--accept-package-agreements --disable-interactivity");
    spdf_win_toolchain_winget_cmd("winget", SPDF_WIN_TC_WINGET_PYTHON, 1, cmd, sizeof(cmd));
    CHECK(strstr(cmd, "--id Python.Python.3.12 -e") && strstr(cmd, " --scope user"));
    spdf_win_toolchain_pip_cmd("C:\\Py Dir\\python.exe", 1, pkgs, 1, cmd, sizeof(cmd));
    CHECK_STR(cmd, "\"C:\\Py Dir\\python.exe\" -m pip install --user --upgrade --progress-bar off ocrmypdf");
    spdf_win_toolchain_pip_cmd("C:\\A\\Scripts\\python.exe", 0, pkgs, 1, cmd, sizeof(cmd));
    CHECK_STR(cmd, "C:\\A\\Scripts\\python.exe -m pip install --upgrade --progress-bar off ocrmypdf");
    spdf_win_toolchain_venv_cmd("python", "C:\\Users\\Ren\\.shenzhenpdf\\argos", cmd, sizeof(cmd));
    CHECK_STR(cmd, "python -m venv C:\\Users\\Ren\\.shenzhenpdf\\argos");
    spdf_win_toolchain_curl_cmd("curl.exe", "https://x/y.traineddata", "C:\\T d\\y.traineddata", cmd, sizeof(cmd));
    CHECK_STR(cmd, "curl.exe -L -f -sS -o \"C:\\T d\\y.traineddata\" https://x/y.traineddata");
    spdf_win_toolchain_argospm_cmd("argospm.exe", "zh", "en", cmd, sizeof(cmd));
    CHECK_STR(cmd, "argospm.exe install translate-zh_en");
}

/* --- plans ----------------------------------------------------------------- */

static void test_plans(void) {
    SpdfWinToolchainRoots r;
    SpdfWinToolchainState st;
    SpdfWinToolchainPlan plan;
    roots_fixture(&r);
    memset(&st, 0, sizeof(st));
    strcpy(st.path[SPDF_WIN_TOOL_WINGET], "C:\\W\\winget.exe");
    strcpy(st.path[SPDF_WIN_TOOL_CURL], "C:\\Windows\\System32\\curl.exe");
    strcpy(st.missing_languages[0], "chi_sim");
    st.missing_language_count = 1;

    /* Bare machine with winget: Tesseract, Python, ocrmypdf, one traineddata --
     * chi_sim only, because the Tesseract installer ships eng; and never
     * Ghostscript, which OCRmyPDF 17 does not need. */
    strcpy(st.missing_languages[1], "eng");
    st.missing_language_count = 2;
    spdf_win_toolchain_ocr_plan(&st, &r, "chi_sim+eng", &plan);
    CHECK(plan.count == 4);
    st.missing_language_count = 1;
    CHECK(plan.steps[0].kind == SPDF_WIN_TC_STEP_WINGET && strstr(plan.steps[0].command, "UB-Mannheim.TesseractOCR"));
    CHECK(plan.steps[1].kind == SPDF_WIN_TC_STEP_WINGET && strstr(plan.steps[1].command, "--scope user"));
    CHECK(plan.steps[2].kind == SPDF_WIN_TC_STEP_PIP);
    CHECK_STR(plan.steps[2].command, "python -m pip install --user --upgrade --progress-bar off ocrmypdf");
    CHECK(plan.steps[3].kind == SPDF_WIN_TC_STEP_TRAINEDDATA);
    CHECK_STR(plan.steps[3].dest, "C:\\Users\\Ren\\.shenzhenpdf\\tesseract\\tessdata\\chi_sim.traineddata");
    CHECK(strstr(plan.steps[3].command, "tessdata_fast/main/chi_sim.traineddata") != NULL);
    CHECK(plan.needs_elevation_note); /* Tesseract's installer is machine-wide */

    /* Everything present but the language: one download, no elevation note.
     * Ghostscript stays absent and is not asked for. */
    strcpy(st.path[SPDF_WIN_TOOL_TESSERACT], "C:\\Program Files\\Tesseract-OCR\\tesseract.exe");
    strcpy(st.path[SPDF_WIN_TOOL_PYTHON], "C:\\Py\\python.exe");
    strcpy(st.path[SPDF_WIN_TOOL_OCRMYPDF], "C:\\Py\\Scripts\\ocrmypdf.exe");
    spdf_win_toolchain_ocr_plan(&st, &r, "chi_sim+eng", &plan);
    CHECK(plan.count == 1 && plan.steps[0].kind == SPDF_WIN_TC_STEP_TRAINEDDATA);
    CHECK(!plan.needs_elevation_note);
    st.missing_language_count = 0;
    spdf_win_toolchain_ocr_plan(&st, &r, "eng", &plan);
    CHECK(plan.count == 0);

    /* No winget and no python: the plan says so instead of shrinking. */
    st.path[SPDF_WIN_TOOL_WINGET][0] = '\0';
    st.path[SPDF_WIN_TOOL_TESSERACT][0] = '\0';
    st.path[SPDF_WIN_TOOL_PYTHON][0] = '\0';
    spdf_win_toolchain_ocr_plan(&st, &r, "eng", &plan);
    CHECK(plan.count == 2);
    CHECK(plan.steps[0].kind == SPDF_WIN_TC_STEP_BLOCKED && strstr(plan.steps[0].label, "Tesseract"));
    CHECK(plan.steps[1].kind == SPDF_WIN_TC_STEP_BLOCKED && strstr(plan.steps[1].label, "Python"));

    /* Argos: a venv made by the user's python (quoted when known), the package
     * installed by the venv's python WITHOUT --user, argospm from the venv. */
    strcpy(st.path[SPDF_WIN_TOOL_PYTHON], "C:\\Py Dir\\python.exe");
    spdf_win_toolchain_argos_plan(&st, &r, "zh", "en", 1, &plan);
    CHECK(plan.count == 3);
    CHECK(plan.steps[0].kind == SPDF_WIN_TC_STEP_VENV);
    CHECK_STR(plan.steps[0].command, "\"C:\\Py Dir\\python.exe\" -m venv C:\\Users\\Ren\\.shenzhenpdf\\argos");
    CHECK_STR(plan.steps[0].dest, "C:\\Users\\Ren\\.shenzhenpdf\\argos");
    CHECK(plan.steps[1].kind == SPDF_WIN_TC_STEP_PIP);
    CHECK_STR(plan.steps[1].command, "C:\\Users\\Ren\\.shenzhenpdf\\argos\\Scripts\\python.exe -m pip install "
                                     "--upgrade --progress-bar off argostranslate");
    CHECK(plan.steps[2].kind == SPDF_WIN_TC_STEP_ARGOSPM);
    CHECK_STR(plan.steps[2].command, "C:\\Users\\Ren\\.shenzhenpdf\\argos\\Scripts\\argospm.exe install translate-zh_en");
    CHECK(!plan.needs_elevation_note);
    strcpy(st.path[SPDF_WIN_TOOL_ARGOS_TRANSLATE], "C:\\S\\argos-translate.exe");
    strcpy(st.path[SPDF_WIN_TOOL_ARGOSPM], "C:\\S\\argospm.exe");
    spdf_win_toolchain_argos_plan(&st, &r, "zh", "en", 0, &plan);
    CHECK(plan.count == 0);
    spdf_win_toolchain_argos_plan(&st, &r, "zh", "en", 1, &plan);
    CHECK(plan.count == 1 && plan.steps[0].kind == SPDF_WIN_TC_STEP_ARGOSPM);
    CHECK_STR(plan.steps[0].command, "C:\\S\\argospm.exe install translate-zh_en");
    /* The venv's scripts are looked for before the user's. */
    {
        char cands[SPDF_WIN_TC_MAX_CANDIDATES][SPDF_WIN_TC_PATH];
        CHECK(spdf_win_toolchain_candidates(SPDF_WIN_TOOL_ARGOS_TRANSLATE, &r, cands) == 2);
        CHECK_STR(cands[0], "C:\\Users\\Ren\\.shenzhenpdf\\argos\\Scripts\\argos-translate.exe");
    }
}

/* --- line splitter ------------------------------------------------------------ */

static char g_lines[32][256];
static int g_line_count;
static void collect_line(const char* line, void* user) {
    (void)user;
    if (g_line_count < 32) snprintf(g_lines[g_line_count], 256, "%s", line);
    ++g_line_count;
}

static void test_line_splitter(void) {
    SpdfWinLineSplitter s;
    const char* chunk1 = "one\r\ntwo\n\x1b[32mgreen\x1b[0m\nprogress 10%\rprogress 50%\rdone\r\n";
    const char* chunk2 = "tail without newline";
    g_line_count = 0;
    spdf_win_line_splitter_init(&s);
    spdf_win_line_splitter_feed(&s, chunk1, strlen(chunk1), collect_line, NULL);
    CHECK(g_line_count == 6);
    CHECK_STR(g_lines[0], "one");
    CHECK_STR(g_lines[1], "two");
    CHECK_STR(g_lines[2], "green");
    CHECK_STR(g_lines[3], "progress 10%");
    CHECK_STR(g_lines[4], "progress 50%");
    CHECK_STR(g_lines[5], "done");
    /* A chunk boundary inside "\r\n" must not produce an empty line. */
    spdf_win_line_splitter_feed(&s, "a\r", 2, collect_line, NULL);
    spdf_win_line_splitter_feed(&s, "\nb\n\n", 4, collect_line, NULL);
    CHECK(g_line_count == 9);
    CHECK_STR(g_lines[6], "a");
    CHECK_STR(g_lines[7], "b");
    CHECK_STR(g_lines[8], ""); /* a genuine blank line survives */
    spdf_win_line_splitter_feed(&s, chunk2, strlen(chunk2), collect_line, NULL);
    CHECK(g_line_count == 9);
    spdf_win_line_splitter_flush(&s, collect_line, NULL);
    CHECK(g_line_count == 10);
    CHECK_STR(g_lines[9], "tail without newline");
    /* OSC title sequence and a split CSI. */
    g_line_count = 0;
    spdf_win_line_splitter_init(&s);
    spdf_win_line_splitter_feed(&s, "\x1b]0;title\x07x\x1b[", 13, collect_line, NULL);
    spdf_win_line_splitter_feed(&s, "?25ly\n", 6, collect_line, NULL);
    CHECK(g_line_count == 1);
    CHECK_STR(g_lines[0], "xy");
}

/* --- settings JSON ------------------------------------------------------------ */

static void test_settings_json(void) {
    char out[1024], value[64];
    CHECK(spdf_win_toolchain_json_set_string(NULL, "ocrLanguage", "chi_sim+eng", out, sizeof(out)));
    CHECK_STR(out, "{\"ocrLanguage\":\"chi_sim+eng\"}");
    CHECK(spdf_win_toolchain_json_get_string(out, "ocrLanguage", value, sizeof(value)));
    CHECK_STR(value, "chi_sim+eng");
    CHECK(!spdf_win_toolchain_json_get_string(out, "translateSourceLanguage", value, sizeof(value)));
    /* Insert beside existing members; replace in place. */
    CHECK(spdf_win_toolchain_json_set_string("{\"minimapWidth\": 126.5, \"ocrLanguage\": \"eng\"}", "ocrLanguage",
                                             "deu", out, sizeof(out)));
    CHECK_STR(out, "{\"minimapWidth\": 126.5, \"ocrLanguage\": \"deu\"}");
    CHECK(spdf_win_toolchain_json_set_string("{\"minimapWidth\": 126.5}\n", "translateTargetLanguage", "en", out,
                                             sizeof(out)));
    CHECK_STR(out, "{\"minimapWidth\": 126.5,\"translateTargetLanguage\":\"en\"}\n");
    CHECK(spdf_win_toolchain_json_set_string("{ }", "k", "a\"b", out, sizeof(out)));
    CHECK_STR(out, "{\"k\":\"a\\\"b\"}");
    CHECK(spdf_win_toolchain_json_get_string(out, "k", value, sizeof(value)));
    CHECK_STR(value, "a\"b");
    /* A key that is a prefix of another must not match. */
    CHECK(!spdf_win_toolchain_json_get_string("{\"ocrLanguageX\":\"z\"}", "ocrLanguage", value, sizeof(value)));
}

int main(void) {
    test_candidates();
    test_search_path();
    test_versions();
    test_languages();
    test_argos_helpers();
    test_command_lines();
    test_plans();
    test_line_splitter();
    test_settings_json();
    printf("toolchain_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
