/* spdf_win_assoc.cpp — the registry half of spdf_win_assoc.h. The decisions
 * are in the header; this is RegCreateKeyExW, AssocQueryStringW and
 * ShellExecuteW, nothing more.
 *
 * WHY THERE IS NO "SET DEFAULT" CALL. Windows 8 removed
 * IApplicationAssociationRegistration::SetAppAsDefault for desktop apps and
 * Windows 10 hash-protected the .pdf UserChoice key, so an app that writes it
 * directly is either ignored or reset with a "an app default was reset"
 * notification. The supported path is the one Edge, Acrobat and Firefox take:
 * register through RegisteredApplications + Capabilities, then send the user
 * to Settings on the app's own page. That is what this does.
 */
#include "spdf_win_assoc.h"

#include <windows.h>
#include <shellapi.h>
#include <shlobj.h> /* SHChangeNotify */
#include <shlwapi.h>

#include <string.h>

#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "user32.lib")

/* Sets `value` (or the default value when `name` is NULL) of `sub` under
 * `root`, creating the key. */
static int set_string(HKEY root, const wchar_t* sub, const wchar_t* name, const wchar_t* value) {
    HKEY key;
    LONG rc;
    if (RegCreateKeyExW(root, sub, 0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL) != ERROR_SUCCESS) return 0;
    rc = RegSetValueExW(key, name, 0, REG_SZ, (const BYTE*)value, (DWORD)((wcslen(value) + 1) * sizeof(wchar_t)));
    RegCloseKey(key);
    return rc == ERROR_SUCCESS;
}

int spdf_win_assoc_register_under(void* root_handle, const wchar_t* exe) {
    HKEY root = (HKEY)root_handle;
    wchar_t command[MAX_PATH + 16];
    wchar_t icon[MAX_PATH + 8];
    int ok = 1;

    if (!root || !exe || !*exe) return 0;
    if (!spdf_win_assoc_open_command(exe, command, _countof(command))) return 0;
    _snwprintf_s(icon, _countof(icon), _TRUNCATE, L"%s,0", exe);

    /* The ProgID. */
    ok &= set_string(root, L"Software\\Classes\\" SPDF_WIN_ASSOC_PROGID, NULL, L"PDF Document");
    ok &= set_string(root, L"Software\\Classes\\" SPDF_WIN_ASSOC_PROGID, L"FriendlyTypeName", L"PDF Document");
    ok &= set_string(root, L"Software\\Classes\\" SPDF_WIN_ASSOC_PROGID L"\\DefaultIcon", NULL, icon);
    ok &= set_string(root, L"Software\\Classes\\" SPDF_WIN_ASSOC_PROGID L"\\shell\\open\\command", NULL, command);
    /* The extension's candidate list ("Open with" and the Settings picker). */
    ok &= set_string(root, L"Software\\Classes\\.pdf\\OpenWithProgids", SPDF_WIN_ASSOC_PROGID, L"");
    /* The Applications entry Explorer shows in "Open with > Choose another app". */
    ok &= set_string(root, L"Software\\Classes\\Applications\\ShenzhenPDF.exe", L"FriendlyAppName",
                     L"Shenzhen PDF");
    ok &= set_string(root, L"Software\\Classes\\Applications\\ShenzhenPDF.exe\\shell\\open\\command", NULL, command);
    ok &= set_string(root, L"Software\\Classes\\Applications\\ShenzhenPDF.exe\\SupportedTypes", L".pdf", L"");
    /* The Default Programs registration Settings lists. */
    ok &= set_string(root, L"Software\\" SPDF_WIN_ASSOC_APP_NAME L"\\Capabilities", L"ApplicationName",
                     L"Shenzhen PDF");
    ok &= set_string(root, L"Software\\" SPDF_WIN_ASSOC_APP_NAME L"\\Capabilities", L"ApplicationDescription",
                     L"A fast PDF reader with a document map, search, tabs and a dark reading theme.");
    ok &= set_string(root, L"Software\\" SPDF_WIN_ASSOC_APP_NAME L"\\Capabilities\\FileAssociations", L".pdf",
                     SPDF_WIN_ASSOC_PROGID);
    ok &= set_string(root, L"Software\\RegisteredApplications", SPDF_WIN_ASSOC_APP_NAME,
                     L"Software\\" SPDF_WIN_ASSOC_APP_NAME L"\\Capabilities");
    return ok;
}

int spdf_win_assoc_unregister_under(void* root_handle) {
    HKEY root = (HKEY)root_handle;
    HKEY key;
    if (!root) return 0;
    RegDeleteTreeW(root, L"Software\\Classes\\" SPDF_WIN_ASSOC_PROGID);
    RegDeleteTreeW(root, L"Software\\Classes\\Applications\\ShenzhenPDF.exe");
    RegDeleteTreeW(root, L"Software\\" SPDF_WIN_ASSOC_APP_NAME);
    if (RegOpenKeyExW(root, L"Software\\Classes\\.pdf\\OpenWithProgids", 0, KEY_SET_VALUE, &key) == ERROR_SUCCESS) {
        RegDeleteValueW(key, SPDF_WIN_ASSOC_PROGID);
        RegCloseKey(key);
    }
    if (RegOpenKeyExW(root, L"Software\\RegisteredApplications", 0, KEY_SET_VALUE, &key) == ERROR_SUCCESS) {
        RegDeleteValueW(key, SPDF_WIN_ASSOC_APP_NAME);
        RegCloseKey(key);
    }
    return 1;
}

int spdf_win_assoc_is_registered_under(void* root_handle) {
    HKEY root = (HKEY)root_handle;
    HKEY key;
    if (!root) return 0;
    if (RegOpenKeyExW(root, L"Software\\Classes\\" SPDF_WIN_ASSOC_PROGID L"\\shell\\open\\command", 0, KEY_READ,
                      &key) != ERROR_SUCCESS)
        return 0;
    RegCloseKey(key);
    return 1;
}

int spdf_win_assoc_current_default(wchar_t* out, size_t out_len) {
    HKEY key;
    DWORD type = 0;
    DWORD size;
    if (!out || !out_len) return 0;
    out[0] = L'\0';
    /* Explorer's own record of the user's choice, which is what the Settings
     * page shows. AssocQueryString would fall back to the ProgID default when
     * no choice was made, and "nobody chose" is a different answer from "the
     * user chose someone else". */
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
                      L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\.pdf\\UserChoice", 0,
                      KEY_READ, &key) == ERROR_SUCCESS) {
        size = (DWORD)(out_len * sizeof(wchar_t));
        if (RegQueryValueExW(key, L"ProgId", NULL, &type, (BYTE*)out, &size) == ERROR_SUCCESS && type == REG_SZ &&
            size >= sizeof(wchar_t)) {
            out[out_len - 1] = L'\0';
            RegCloseKey(key);
            return out[0] != L'\0';
        }
        RegCloseKey(key);
    }
    out[0] = L'\0';
    {
        /* No UserChoice: whatever the shell resolves. */
        DWORD len = (DWORD)out_len;
        if (SUCCEEDED(AssocQueryStringW(ASSOCF_NONE, ASSOCSTR_PROGID, L".pdf", NULL, out, &len)) && out[0])
            return 1;
    }
    out[0] = L'\0';
    return 0;
}

int spdf_win_assoc_is_default(void) {
    wchar_t progid[256];
    return spdf_win_assoc_current_default(progid, _countof(progid)) && spdf_win_assoc_progid_is_us(progid);
}

int spdf_win_assoc_make_default(void* hwnd_handle) {
    HWND hwnd = (HWND)hwnd_handle;
    wchar_t exe[MAX_PATH];
    HINSTANCE rc;

    if (spdf_win_assoc_is_default()) {
        MessageBoxW(hwnd, L"Shenzhen PDF is already your default PDF reader.", L"Shenzhen PDF",
                    MB_OK | MB_ICONINFORMATION);
        return 2;
    }
    if (!GetModuleFileNameW(NULL, exe, _countof(exe))) return 0;
    if (!spdf_win_assoc_register_under(HKEY_CURRENT_USER, exe)) {
        MessageBoxW(hwnd, L"Shenzhen PDF could not register itself as a PDF reader (the registry refused the write).",
                    L"Shenzhen PDF", MB_OK | MB_ICONWARNING);
        return 0;
    }
    /* Tell the shell the associations changed so the Settings list is fresh.
     * FLUSHNOWAIT, not FLUSH: SHCNF_FLUSH makes this call wait until Explorer
     * has taken delivery, and this runs on the window's thread from a menu
     * click. An Explorer that is busy or hung would then hold this window
     * hostage for as long as it liked -- a cross-process hang, in Error
     * Reporting's words (AppHangXProcB1), with nothing of ours at fault. The
     * notification is delivered either way; nothing here needs to know when. */
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST | SHCNF_FLUSHNOWAIT, NULL, NULL);
    /* Windows 11 opens the app's own page; older builds ignore the query and
     * fall back to the general page, so both are tried in order. */
    rc = ShellExecuteW(hwnd, L"open", SPDF_WIN_ASSOC_SETTINGS_URI, NULL, NULL, SW_SHOWNORMAL);
    if ((INT_PTR)rc <= 32) rc = ShellExecuteW(hwnd, L"open", SPDF_WIN_ASSOC_SETTINGS_URI_FALLBACK, NULL, NULL, SW_SHOWNORMAL);
    if ((INT_PTR)rc <= 32) {
        MessageBoxW(hwnd,
                    L"Shenzhen PDF is registered. To make it the default, open Settings > Apps > Default apps > "
                    L"Shenzhen PDF and choose .pdf.",
                    L"Shenzhen PDF", MB_OK | MB_ICONINFORMATION);
        return 0;
    }
    return 1;
}
