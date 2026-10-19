/* assoc_test.c — the .pdf association: the ported decisions from
 * portable/linux/gtk4/tests/default_reader_test.c, and the registration under
 * a THROWAWAY registry key.
 *
 * The decision table and the "is it us" match are
 * spdf_default_reader_should_prompt / spdf_default_reader_output_is_us case
 * for case, with xdg-mime's desktop id replaced by the ProgID. The
 * registration is exercised for real -- RegCreateKeyExW and friends -- but
 * under HKCU\Software\ShenzhenPDF-test-<pid>, which is created here, read
 * back, and deleted before exit. The user's real HKCU\Software\Classes is
 * never written by a test; that is the port's registry rule and this file
 * keeps it.
 *
 * Exit code is the whole signal.
 */
/* spdf-test-sources: portable/win/src/spdf_win_assoc.cpp */
#include <windows.h>

#include "spdf_win_assoc.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                      \
    do {                                                                                 \
        ++g_checks;                                                                      \
        if (!(cond)) {                                                                   \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__);             \
            ++g_failures;                                                                \
        }                                                                                \
    } while (0)

/* --- the decision table --------------------------------------------------- */

static void test_should_prompt(void) {
    /* The one prompting row: registered, not default, never dismissed, not
     * yet prompted this run. */
    CHECK(spdf_win_assoc_should_prompt(1, 0, 0, 0));
    /* Not registered (a build run from its folder): always silent. */
    CHECK(!spdf_win_assoc_should_prompt(0, 0, 0, 0));
    /* Already the default: nothing to offer. */
    CHECK(!spdf_win_assoc_should_prompt(1, 1, 0, 0));
    /* Dismissed persists forever (settings key defaultReaderPromptDismissed). */
    CHECK(!spdf_win_assoc_should_prompt(1, 0, 1, 0));
    /* At most once per process. */
    CHECK(!spdf_win_assoc_should_prompt(1, 0, 0, 1));
    /* Every gate closed stays closed. */
    CHECK(!spdf_win_assoc_should_prompt(0, 1, 1, 1));
}

/* --- "is it us" ----------------------------------------------------------- */

static void test_progid_is_us(void) {
    CHECK(spdf_win_assoc_progid_is_us(L"ShenzhenPDF.Document"));
    CHECK(spdf_win_assoc_progid_is_us(L"ShenzhenPDF.Document\n"));
    CHECK(spdf_win_assoc_progid_is_us(L"  ShenzhenPDF.Document \r\n"));
    CHECK(spdf_win_assoc_progid_is_us(L"shenzhenpdf.document")); /* the registry is case-insensitive */
    /* Anyone else, including near-misses. */
    CHECK(!spdf_win_assoc_progid_is_us(L"AcroExch.Document.DC"));
    CHECK(!spdf_win_assoc_progid_is_us(L"MSEdgePDF"));
    CHECK(!spdf_win_assoc_progid_is_us(L"ShenzhenPDF"));
    CHECK(!spdf_win_assoc_progid_is_us(L"ShenzhenPDF.Document.bak"));
    CHECK(!spdf_win_assoc_progid_is_us(L"a ShenzhenPDF.Document"));
    CHECK(!spdf_win_assoc_progid_is_us(L""));
    CHECK(!spdf_win_assoc_progid_is_us(L"\n"));
    CHECK(!spdf_win_assoc_progid_is_us(NULL));
}

/* --- the open verb -------------------------------------------------------- */

static void test_open_command(void) {
    wchar_t cmd[MAX_PATH + 16];
    CHECK(spdf_win_assoc_open_command(L"C:\\Program Files\\Shenzhen PDF\\ShenzhenPDF.exe", cmd, _countof(cmd)));
    CHECK(wcscmp(cmd, L"\"C:\\Program Files\\Shenzhen PDF\\ShenzhenPDF.exe\" \"%1\"") == 0);
    CHECK(!spdf_win_assoc_open_command(L"C:\\x.exe", cmd, 5)); /* too small */
    CHECK(!spdf_win_assoc_open_command(NULL, cmd, _countof(cmd)));
}

/* --- registration under a throwaway root ---------------------------------- */

static int read_string(HKEY root, const wchar_t* sub, const wchar_t* name, wchar_t* out, size_t out_len) {
    HKEY key;
    DWORD type = 0;
    DWORD size = (DWORD)(out_len * sizeof(wchar_t));
    LONG rc;
    out[0] = L'\0';
    if (RegOpenKeyExW(root, sub, 0, KEY_READ, &key) != ERROR_SUCCESS) return 0;
    rc = RegQueryValueExW(key, name, NULL, &type, (BYTE*)out, &size);
    RegCloseKey(key);
    if (rc != ERROR_SUCCESS || type != REG_SZ) return 0;
    out[out_len - 1] = L'\0';
    return 1;
}

static void test_registration(void) {
    wchar_t root_name[128];
    HKEY root = NULL;
    wchar_t value[MAX_PATH + 32];
    const wchar_t* exe = L"C:\\Apps\\Shenzhen PDF\\ShenzhenPDF.exe";

    _snwprintf_s(root_name, _countof(root_name), _TRUNCATE, L"Software\\ShenzhenPDF-test-%lu",
                 (unsigned long)GetCurrentProcessId());
    /* NOT REG_OPTION_VOLATILE: a volatile key refuses non-volatile children
     * (ERROR_CHILD_MUST_BE_VOLATILE), and the registration writes ordinary
     * keys because the real one must survive a reboot. The tree is deleted at
     * the end instead. */
    CHECK(RegCreateKeyExW(HKEY_CURRENT_USER, root_name, 0, NULL, REG_OPTION_NON_VOLATILE, KEY_ALL_ACCESS, NULL,
                          &root, NULL) == ERROR_SUCCESS);
    if (!root) return;

    CHECK(!spdf_win_assoc_is_registered_under(root));
    CHECK(!spdf_win_assoc_register_under(root, NULL));
    CHECK(!spdf_win_assoc_register_under(NULL, exe));
    CHECK(spdf_win_assoc_register_under(root, exe));
    CHECK(spdf_win_assoc_is_registered_under(root));

    /* The ProgID's open verb. */
    CHECK(read_string(root, L"Software\\Classes\\ShenzhenPDF.Document\\shell\\open\\command", NULL, value,
                      _countof(value)));
    CHECK(wcscmp(value, L"\"C:\\Apps\\Shenzhen PDF\\ShenzhenPDF.exe\" \"%1\"") == 0);
    CHECK(read_string(root, L"Software\\Classes\\ShenzhenPDF.Document\\DefaultIcon", NULL, value, _countof(value)));
    CHECK(wcscmp(value, L"C:\\Apps\\Shenzhen PDF\\ShenzhenPDF.exe,0") == 0);
    /* The .pdf candidate list. */
    CHECK(read_string(root, L"Software\\Classes\\.pdf\\OpenWithProgids", L"ShenzhenPDF.Document", value,
                      _countof(value)));
    /* Default Programs: what Settings lists. */
    CHECK(read_string(root, L"Software\\RegisteredApplications", L"ShenzhenPDF", value, _countof(value)));
    CHECK(wcscmp(value, L"Software\\ShenzhenPDF\\Capabilities") == 0);
    CHECK(read_string(root, L"Software\\ShenzhenPDF\\Capabilities\\FileAssociations", L".pdf", value,
                      _countof(value)));
    CHECK(spdf_win_assoc_progid_is_us(value));
    CHECK(read_string(root, L"Software\\ShenzhenPDF\\Capabilities", L"ApplicationName", value, _countof(value)));
    CHECK(wcscmp(value, L"Shenzhen PDF") == 0);
    /* Idempotent. */
    CHECK(spdf_win_assoc_register_under(root, exe));

    /* And gone again. */
    CHECK(spdf_win_assoc_unregister_under(root));
    CHECK(!spdf_win_assoc_is_registered_under(root));
    CHECK(!read_string(root, L"Software\\RegisteredApplications", L"ShenzhenPDF", value, _countof(value)));
    CHECK(!read_string(root, L"Software\\Classes\\.pdf\\OpenWithProgids", L"ShenzhenPDF.Document", value,
                       _countof(value)));

    RegCloseKey(root);
    CHECK(RegDeleteTreeW(HKEY_CURRENT_USER, root_name) == ERROR_SUCCESS);
}

/* --- the live query is read-only and answers ------------------------------ */

static void test_current_default_reads(void) {
    wchar_t progid[256];
    int has = spdf_win_assoc_current_default(progid, _countof(progid));
    /* Whatever this machine has, the call must not crash and must be
     * consistent with is_default(). Reported, not asserted: the value is a
     * property of the machine. */
    printf("assoc_test: current .pdf default: %ls (is us: %d)\n", has ? progid : L"(none)",
           spdf_win_assoc_is_default());
    CHECK(has == (progid[0] != L'\0'));
    CHECK(spdf_win_assoc_is_default() == (has && spdf_win_assoc_progid_is_us(progid)));
}

int main(void) {
    test_should_prompt();
    test_progid_is_us();
    test_open_command();
    test_registration();
    test_current_default_reads();
    printf("assoc_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
