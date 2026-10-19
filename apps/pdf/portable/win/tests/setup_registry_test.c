/* setup_registry_test.c — the Apps-list entry, written for real and read back,
 * under a THROWAWAY root key.
 *
 * Same shape and the same rule as portable/win/tests/assoc_test.c, which does
 * this for the .pdf association: RegCreateKeyExW and friends run exactly as they
 * do in a real --install, but under HKCU\Software\ShenzhenPDF-test-<pid>, which
 * is created here, read back, and deleted before exit. THE USER'S OWN "Apps &
 * features" LIST IS NEVER WRITTEN BY A TEST. A row that appeared there because
 * a test ran would be a row nobody could explain, and the Uninstall key is the
 * one thing in this port whose mistakes are visible in a Windows the user did
 * not ask us to change.
 *
 * Exit code is the whole signal.
 */
/* The settings module and its file shell come along because spdf_win_setup.cpp
 * remembers the first-run answer through spdf_win_settings_commit(); the list is
 * settings_test.c's own, plus assoc and setup. Nothing here reads or writes
 * settings.yaml -- the symbols are needed at the link, not at run time. */
/* spdf-test-sources: portable/win/src/spdf_win_setup.cpp portable/win/src/spdf_win_assoc.cpp portable/win/src/spdf_win_settings.c portable/win/src/spdf_win_state.c portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c portable/core/spdf_win_compat.c portable/win/src/spdf_win_recents.c portable/win/src/spdf_win_watcher.cpp portable/win/src/spdf_win_watcher_shadow.cpp */
#include <windows.h>

#include "spdf_win_assoc.h"
#include "spdf_win_setup.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                          \
    do {                                                                     \
        ++g_checks;                                                          \
        if (!(cond)) {                                                       \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__); \
            ++g_failures;                                                    \
        }                                                                    \
    } while (0)

static int read_sz(HKEY root, const wchar_t* name, wchar_t* out, size_t out_len) {
    HKEY key;
    DWORD type = 0;
    DWORD size = (DWORD)(out_len * sizeof(wchar_t));
    LONG rc;
    out[0] = L'\0';
    if (RegOpenKeyExW(root, SPDF_WIN_SETUP_UNINSTALL_KEY, 0, KEY_READ, &key) != ERROR_SUCCESS) return 0;
    rc = RegQueryValueExW(key, name, NULL, &type, (BYTE*)out, &size);
    RegCloseKey(key);
    if (rc != ERROR_SUCCESS || type != REG_SZ) return 0;
    out[out_len - 1] = L'\0';
    return 1;
}

static int read_dword(HKEY root, const wchar_t* name, DWORD* out) {
    HKEY key;
    DWORD type = 0;
    DWORD size = sizeof(DWORD);
    LONG rc;
    *out = 0;
    if (RegOpenKeyExW(root, SPDF_WIN_SETUP_UNINSTALL_KEY, 0, KEY_READ, &key) != ERROR_SUCCESS) return 0;
    rc = RegQueryValueExW(key, name, NULL, &type, (BYTE*)out, &size);
    RegCloseKey(key);
    return rc == ERROR_SUCCESS && type == REG_DWORD;
}

static void test_entry_round_trip(void) {
    const wchar_t* exe = L"C:\\Users\\ada\\AppData\\Local\\Programs\\ShenzhenPDF\\ShenzhenPDF.exe";
    const wchar_t* dir = L"C:\\Users\\ada\\AppData\\Local\\Programs\\ShenzhenPDF";
    wchar_t root_name[128];
    wchar_t value[SPDF_WIN_SETUP_TEXT_MAX];
    spdf_win_setup_entry entry;
    HKEY root = NULL;
    DWORD number = 0;

    _snwprintf_s(root_name, _countof(root_name), _TRUNCATE, L"Software\\ShenzhenPDF-test-%lu",
                 (unsigned long)GetCurrentProcessId());
    /* NOT REG_OPTION_VOLATILE: a volatile key refuses non-volatile children
     * (ERROR_CHILD_MUST_BE_VOLATILE) and the real entry must survive a reboot,
     * so the tree is deleted at the end instead. assoc_test.c:106 makes the
     * same choice for the same reason. */
    CHECK(RegCreateKeyExW(HKEY_CURRENT_USER, root_name, 0, NULL, REG_OPTION_NON_VOLATILE, KEY_ALL_ACCESS, NULL,
                          &root, NULL) == ERROR_SUCCESS);
    if (!root) return;

    /* Nothing there yet, and removing nothing is success -- --uninstall must be
     * runnable twice. */
    CHECK(!read_sz(root, L"DisplayName", value, _countof(value)));
    CHECK(spdf_win_setup_remove_uninstall_under(root));

    CHECK(spdf_win_setup_uninstall_entry(exe, dir, 40640, &entry));
    CHECK(!spdf_win_setup_write_uninstall_under(NULL, &entry));
    CHECK(!spdf_win_setup_write_uninstall_under(root, NULL));
    CHECK(spdf_win_setup_write_uninstall_under(root, &entry));

    CHECK(read_sz(root, L"DisplayName", value, _countof(value)));
    CHECK(wcscmp(value, L"Shenzhen PDF") == 0);
    CHECK(read_sz(root, L"DisplayVersion", value, _countof(value)));
    CHECK(wcscmp(value, SPDF_WIN_SETUP_WIDE(SPDF_WIN_VERSION_STR)) == 0);
    CHECK(read_sz(root, L"Publisher", value, _countof(value)));
    CHECK(wcscmp(value, L"Casimir Engineering") == 0);
    CHECK(read_sz(root, L"DisplayIcon", value, _countof(value)));
    CHECK(wcscmp(value, exe) == 0);
    CHECK(read_sz(root, L"InstallLocation", value, _countof(value)));
    CHECK(wcscmp(value, dir) == 0);
    /* The two strings Windows actually runs. */
    CHECK(read_sz(root, L"UninstallString", value, _countof(value)));
    CHECK(wcsstr(value, L"--uninstall") != NULL && wcsstr(value, L"--quiet") == NULL);
    CHECK(value[0] == L'"');
    CHECK(read_sz(root, L"QuietUninstallString", value, _countof(value)));
    CHECK(wcsstr(value, L"--uninstall --quiet") != NULL);
    /* The three DWORDs, as DWORDs: the Apps list reads EstimatedSize as a
     * number and would ignore a REG_SZ spelling of it. */
    CHECK(read_dword(root, L"EstimatedSize", &number) && number == 40640);
    CHECK(read_dword(root, L"NoModify", &number) && number == 1);
    CHECK(read_dword(root, L"NoRepair", &number) && number == 1);

    /* Idempotent: a repair re-run overwrites rather than duplicating. */
    CHECK(spdf_win_setup_write_uninstall_under(root, &entry));
    CHECK(read_sz(root, L"DisplayName", value, _countof(value)));

    /* And gone again, key and all. */
    CHECK(spdf_win_setup_remove_uninstall_under(root));
    CHECK(!read_sz(root, L"DisplayName", value, _countof(value)));
    CHECK(spdf_win_setup_remove_uninstall_under(root));

    RegCloseKey(root);
    CHECK(RegDeleteTreeW(HKEY_CURRENT_USER, root_name) == ERROR_SUCCESS);
}

/* The association half of --install goes through the SAME
 * spdf_win_assoc_register_under() File > Make Default PDF Reader calls, and is
 * driven here against the installed path rather than a running one, because
 * that substitution is the whole reason --install exists: a person who installs
 * from Downloads and then deletes the download must still have a working .pdf
 * handler. assoc_test.c owns the contents of that registration; this checks
 * only that it takes the installed exe. */
static void test_assoc_takes_the_installed_path(void) {
    wchar_t root_name[128];
    wchar_t value[SPDF_WIN_SETUP_TEXT_MAX];
    wchar_t installed[SPDF_WIN_SETUP_PATH_MAX];
    HKEY root = NULL;
    HKEY key;
    DWORD type = 0;
    DWORD size = sizeof(value);

    CHECK(spdf_win_setup_install_exe_in(L"C:\\Users\\ada\\AppData\\Local\\Programs", installed,
                                        SPDF_WIN_SETUP_PATH_MAX));
    _snwprintf_s(root_name, _countof(root_name), _TRUNCATE, L"Software\\ShenzhenPDF-test-assoc-%lu",
                 (unsigned long)GetCurrentProcessId());
    CHECK(RegCreateKeyExW(HKEY_CURRENT_USER, root_name, 0, NULL, REG_OPTION_NON_VOLATILE, KEY_ALL_ACCESS, NULL,
                          &root, NULL) == ERROR_SUCCESS);
    if (!root) return;
    CHECK(spdf_win_assoc_register_under(root, installed));
    value[0] = L'\0';
    if (RegOpenKeyExW(root, L"Software\\Classes\\ShenzhenPDF.Document\\shell\\open\\command", 0, KEY_READ, &key) ==
        ERROR_SUCCESS) {
        CHECK(RegQueryValueExW(key, NULL, NULL, &type, (BYTE*)value, &size) == ERROR_SUCCESS);
        RegCloseKey(key);
    }
    CHECK(wcsstr(value, installed) != NULL);
    CHECK(spdf_win_assoc_unregister_under(root));
    RegCloseKey(root);
    CHECK(RegDeleteTreeW(HKEY_CURRENT_USER, root_name) == ERROR_SUCCESS);
}

int main(void) {
    test_entry_round_trip();
    test_assoc_takes_the_installed_path();
    printf("setup_registry_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
