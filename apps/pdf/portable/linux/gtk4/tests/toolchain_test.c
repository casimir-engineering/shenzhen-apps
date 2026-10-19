/* Pure-logic tests for spdf_toolchain.c (glib only, no GTK — the GTK half is
 * compiled out via SPDF_TOOLCHAIN_TESTING): the package-manager command
 * table, install-plan assembly, install-script generation, Tesseract
 * language helpers, Argos diagnostics stripping and the missing-package
 * classifier. The expected commands are byte-copies of what the GTK3
 * ocr_install_script / translate_install_script ran. */
#define SPDF_TOOLCHAIN_TESTING 1

#include "../spdf_toolchain.c"

static void test_pm_probe_names(void) {
    g_assert_cmpstr(spdf_toolchain_pm_probe(SPDF_PKG_APT), ==, "apt-get");
    g_assert_cmpstr(spdf_toolchain_pm_probe(SPDF_PKG_DNF), ==, "dnf");
    g_assert_cmpstr(spdf_toolchain_pm_probe(SPDF_PKG_PACMAN), ==, "pacman");
    g_assert_cmpstr(spdf_toolchain_pm_probe(SPDF_PKG_ZYPPER), ==, "zypper");
    g_assert_null(spdf_toolchain_pm_probe(SPDF_PKG_MANAGER_COUNT));
}

static void test_pm_install_commands(void) {
    /* The GTK3 command table, one manager at a time. */
    char* apt = spdf_toolchain_pm_install_command(SPDF_PKG_APT, spdf_toolchain_ocr_tool_packages(SPDF_PKG_APT));
    char* dnf = spdf_toolchain_pm_install_command(SPDF_PKG_DNF, spdf_toolchain_ocr_tool_packages(SPDF_PKG_DNF));
    char* pacman =
        spdf_toolchain_pm_install_command(SPDF_PKG_PACMAN, spdf_toolchain_ocr_tool_packages(SPDF_PKG_PACMAN));
    char* zypper =
        spdf_toolchain_pm_install_command(SPDF_PKG_ZYPPER, spdf_toolchain_ocr_tool_packages(SPDF_PKG_ZYPPER));

    g_assert_cmpstr(apt, ==, "pkexec /bin/sh -c 'apt-get update && apt-get install -y ocrmypdf tesseract-ocr'");
    g_assert_cmpstr(dnf, ==, "pkexec dnf install -y ocrmypdf tesseract");
    g_assert_cmpstr(pacman, ==, "pkexec pacman -S --needed --noconfirm ocrmypdf tesseract");
    g_assert_cmpstr(zypper, ==, "pkexec zypper --non-interactive install ocrmypdf tesseract-ocr");
    g_free(apt);
    g_free(dnf);
    g_free(pacman);
    g_free(zypper);

    g_assert_null(spdf_toolchain_pm_install_command(SPDF_PKG_APT, NULL));
    g_assert_null(spdf_toolchain_pm_install_command(SPDF_PKG_APT, ""));
}

static void test_pm_package_names(void) {
    g_assert_cmpstr(spdf_toolchain_chinese_traineddata_packages(SPDF_PKG_APT), ==,
                    "tesseract-ocr-chi-sim tesseract-ocr-chi-tra");
    g_assert_cmpstr(spdf_toolchain_chinese_traineddata_packages(SPDF_PKG_DNF), ==,
                    "tesseract-langpack-chi_sim tesseract-langpack-chi_tra");
    g_assert_cmpstr(spdf_toolchain_chinese_traineddata_packages(SPDF_PKG_PACMAN), ==,
                    "tesseract-data-chi_sim tesseract-data-chi_tra");
    g_assert_cmpstr(spdf_toolchain_chinese_traineddata_packages(SPDF_PKG_ZYPPER), ==,
                    "tesseract-ocr-traineddata-chinese_simplified tesseract-ocr-traineddata-chinese_traditional");
    for (int pm = 0; pm < SPDF_PKG_MANAGER_COUNT; ++pm)
        g_assert_cmpstr(spdf_toolchain_argos_packages((SpdfPackageManager)pm), ==, "argos-translate");
}

static void test_language_components(void) {
    char** parts = spdf_ocr_language_components("chi_sim+eng");
    g_assert_cmpstr(parts[0], ==, "chi_sim");
    g_assert_cmpstr(parts[1], ==, "eng");
    g_assert_null(parts[2]);
    g_strfreev(parts);

    /* NULL/empty fall back to eng (GTK3 behavior). */
    parts = spdf_ocr_language_components(NULL);
    g_assert_cmpstr(parts[0], ==, "eng");
    g_assert_null(parts[1]);
    g_strfreev(parts);

    g_assert_true(spdf_ocr_language_uses_extra_traineddata("chi_sim+eng"));
    g_assert_true(spdf_ocr_language_uses_extra_traineddata("deu"));
    g_assert_false(spdf_ocr_language_uses_extra_traineddata("eng"));
    g_assert_false(spdf_ocr_language_uses_extra_traineddata(NULL));

    {
        char* list = spdf_ocr_language_shell_list("chi_tra+eng");
        g_assert_cmpstr(list, ==, "chi_tra eng");
        g_free(list);
    }
}

static void test_list_output_has_language(void) {
    const char* output = "List of available languages (3):\neng\nchi_sim\nosd\n";
    g_assert_true(spdf_toolchain_list_output_has_language(output, "eng"));
    g_assert_true(spdf_toolchain_list_output_has_language(output, "chi_sim+eng"));
    g_assert_false(spdf_toolchain_list_output_has_language(output, "chi_tra+eng"));
    g_assert_false(spdf_toolchain_list_output_has_language(output, "deu"));
    g_assert_false(spdf_toolchain_list_output_has_language("", "eng"));
    /* Substring rows must not match (exact trimmed line comparison). */
    g_assert_false(spdf_toolchain_list_output_has_language("engx\n", "eng"));
}

static void test_install_plan(void) {
    SpdfOcrInstallPlan plan;

    spdf_toolchain_ocr_install_plan(FALSE, TRUE, FALSE, "chi_sim+eng", &plan);
    g_assert_true(plan.install_tools); /* ocrmypdf missing */
    g_assert_true(plan.install_chinese_packs);
    g_assert_true(plan.download_traineddata);

    spdf_toolchain_ocr_install_plan(TRUE, TRUE, TRUE, "chi_sim+eng", &plan);
    g_assert_false(plan.install_tools);
    g_assert_true(plan.install_chinese_packs); /* still requested; script self-checks */
    g_assert_false(plan.download_traineddata);

    spdf_toolchain_ocr_install_plan(TRUE, FALSE, FALSE, "eng", &plan);
    g_assert_true(plan.install_tools); /* tesseract missing */
    g_assert_false(plan.install_chinese_packs);
    g_assert_true(plan.download_traineddata);
}

static void test_ocr_install_script(void) {
    char* script = spdf_toolchain_ocr_install_script("chi_sim+eng");

    /* Language list is shell-quoted and iterated. */
    g_assert_nonnull(strstr(script, "OCR_LANGS='chi_sim eng'"));
    /* All four manager branches, with the table commands embedded. */
    g_assert_nonnull(strstr(script, "if command -v apt-get >/dev/null 2>&1; then"));
    g_assert_nonnull(strstr(script, "pkexec /bin/sh -c 'apt-get update && apt-get install -y ocrmypdf tesseract-ocr'"));
    g_assert_nonnull(strstr(script, "elif command -v dnf >/dev/null 2>&1; then"));
    g_assert_nonnull(strstr(script, "pkexec dnf install -y ocrmypdf tesseract"));
    g_assert_nonnull(strstr(script, "elif command -v pacman >/dev/null 2>&1; then"));
    g_assert_nonnull(strstr(script, "elif command -v zypper >/dev/null 2>&1; then"));
    /* Chinese langpack phase enabled for a non-eng language... */
    g_assert_nonnull(strstr(script, "if [ \"1\" = \"1\" ] && command -v pkexec"));
    g_assert_nonnull(strstr(script, "tesseract-langpack-chi_sim tesseract-langpack-chi_tra"));
    /* ...and the tessdata_fast download fallback is always present. */
    g_assert_nonnull(strstr(script, "tesseract-ocr/tessdata_fast/main/$lang.traineddata"));
    g_assert_nonnull(strstr(script, "shenzhenpdf/tesseract"));
    g_free(script);

    /* eng-only: langpack phase disabled. */
    script = spdf_toolchain_ocr_install_script("eng");
    g_assert_nonnull(strstr(script, "if [ \"0\" = \"1\" ] && command -v pkexec"));
    g_free(script);
}

static void test_argos_install_script(void) {
    char* script = spdf_toolchain_argos_install_script();

    g_assert_nonnull(strstr(script, "command -v argos-translate"));
    g_assert_nonnull(strstr(script, "pkexec /bin/sh -c 'apt-get update && apt-get install -y argos-translate' || true"));
    g_assert_nonnull(strstr(script, "pkexec dnf install -y argos-translate || true"));
    /* pip --user fallback with the PEP-668 escape hatch. */
    g_assert_nonnull(strstr(script, "python3 -m pip install --user --upgrade argostranslate"));
    g_assert_nonnull(strstr(script, "--break-system-packages"));
    g_free(script);
}

static void test_argos_diagnostics(void) {
    const char* diagnostic_line =
        "WARNING: Language zh package 1.9 expects sentencepiece 0.1.99, which has been added";
    g_assert_true(spdf_toolchain_is_argos_diagnostic_line(diagnostic_line, FALSE));
    g_assert_true(spdf_toolchain_is_argos_diagnostic_line("added", TRUE));
    g_assert_true(spdf_toolchain_is_argos_diagnostic_line("which has been added", TRUE));
    g_assert_false(spdf_toolchain_is_argos_diagnostic_line("added", FALSE));
    g_assert_false(spdf_toolchain_is_argos_diagnostic_line("Hello world", FALSE));

    {
        char* text = g_strdup_printf("%s\nadded\nTranslated line\n", diagnostic_line);
        char* cleaned = spdf_toolchain_strip_argos_diagnostics(text);
        g_assert_cmpstr(cleaned, ==, "Translated line\n");
        g_free(cleaned);
        g_free(text);
    }
    {
        /* No diagnostics: returned verbatim. */
        char* cleaned = spdf_toolchain_strip_argos_diagnostics("A\nB");
        g_assert_cmpstr(cleaned, ==, "A\nB");
        g_free(cleaned);
    }
    {
        char* cleaned = spdf_toolchain_strip_argos_diagnostics(NULL);
        g_assert_cmpstr(cleaned, ==, "");
        g_free(cleaned);
    }
}

static void test_missing_package_classifier(void) {
    /* Mac rule: only missing-package failures get the argospm prompt. */
    g_assert_true(spdf_toolchain_argos_failure_is_missing_package("Error: 'zh' is not an installed language."));
    g_assert_true(spdf_toolchain_argos_failure_is_missing_package("No package found matching translate-zh_en"));
    g_assert_false(spdf_toolchain_argos_failure_is_missing_package("Traceback (most recent call last):"));
    g_assert_false(spdf_toolchain_argos_failure_is_missing_package(""));
    g_assert_false(spdf_toolchain_argos_failure_is_missing_package(NULL));
}

static void test_argos_package_name(void) {
    char* name = spdf_toolchain_argos_package_name("zh", "en");
    g_assert_cmpstr(name, ==, "translate-zh_en");
    g_free(name);
    g_assert_null(spdf_toolchain_argos_package_name(NULL, "en"));
    g_assert_null(spdf_toolchain_argos_package_name("zh", ""));
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/toolchain/pm_probe_names", test_pm_probe_names);
    g_test_add_func("/toolchain/pm_install_commands", test_pm_install_commands);
    g_test_add_func("/toolchain/pm_package_names", test_pm_package_names);
    g_test_add_func("/toolchain/language_components", test_language_components);
    g_test_add_func("/toolchain/list_output_has_language", test_list_output_has_language);
    g_test_add_func("/toolchain/install_plan", test_install_plan);
    g_test_add_func("/toolchain/ocr_install_script", test_ocr_install_script);
    g_test_add_func("/toolchain/argos_install_script", test_argos_install_script);
    g_test_add_func("/toolchain/argos_diagnostics", test_argos_diagnostics);
    g_test_add_func("/toolchain/missing_package_classifier", test_missing_package_classifier);
    g_test_add_func("/toolchain/argos_package_name", test_argos_package_name);
    return g_test_run();
}
