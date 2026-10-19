/* spdf_win_shell.cpp — the Win32 half of spdf_win_shell.h. Every call is the
 * explicit *W variant: the build does not define UNICODE (spdf_win_window.cpp
 * says why), and a document path is exactly where a CJK name shows up. */
#include "spdf_win_shell.h"

#include "spdf_win_paths.h"
#include "spdf_win_shell_dialog.h"

#include <shellapi.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <stdio.h>
#include <stdlib.h>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "user32.lib")

namespace {

/* COM for the duration of one call; S_FALSE still needs the matching
 * CoUninitialize (see spdf_win_menu.cpp's ComScope). */
struct ComScope {
    bool owned;
    ComScope() {
        HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
        owned = hr == S_OK || hr == S_FALSE;
    }
    ~ComScope() {
        if (owned) CoUninitialize();
    }
};

wchar_t* widen(const char* utf8) { return utf8 ? spdf_win_utf16_dup_from_utf8(utf8) : NULL; }

} /* namespace */

int spdf_win_shell_home_dir(wchar_t* out, int out_cap) {
    PWSTR path = NULL;
    int ok = 0;
    if (!out || out_cap < 2) return 0;
    out[0] = 0;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Profile, KF_FLAG_DEFAULT, NULL, &path)) && path) {
        if ((int)wcslen(path) < out_cap) {
            wcscpy_s(out, (size_t)out_cap, path);
            ok = 1;
        }
        CoTaskMemFree(path);
    }
    return ok;
}

int spdf_win_shell_show_in_folder(const char* utf8_path) {
    ComScope com;
    wchar_t* wide = widen(utf8_path);
    PIDLIST_ABSOLUTE pidl = NULL;
    SFGAOF attrs = 0;
    int ok = 0;
    if (!wide || !wide[0]) {
        free(wide);
        return 0;
    }
    if (SUCCEEDED(SHParseDisplayName(wide, NULL, &pidl, 0, &attrs)) && pidl) {
        ok = SUCCEEDED(SHOpenFolderAndSelectItems(pidl, 0, NULL, 0));
        CoTaskMemFree(pidl);
    }
    if (!ok) {
        /* The shell item could not be parsed (a path on a share that is not
         * mounted, say): Explorer's own command line does the same job. */
        wchar_t args[1100];
        _snwprintf_s(args, _TRUNCATE, L"/select,\"%s\"", wide);
        ok = (INT_PTR)ShellExecuteW(NULL, L"open", L"explorer.exe", args, NULL, SW_SHOWNORMAL) > 32;
    }
    free(wide);
    return ok;
}

int spdf_win_shell_reveal_folder(const char* utf8_dir) {
    ComScope com;
    wchar_t* wide = widen(utf8_dir);
    PIDLIST_ABSOLUTE pidl = NULL;
    SFGAOF attrs = 0;
    int ok = 0;
    if (!wide || !wide[0]) {
        free(wide);
        return 0;
    }
    if (SUCCEEDED(SHParseDisplayName(wide, NULL, &pidl, 0, &attrs)) && pidl) {
        /* cidl 0 with no child items: OPEN this folder. show_in_folder above
         * passes a FILE's pidl for the same call, which selects it in its
         * parent -- the same API, two jobs, told apart only by what is
         * parsed. */
        ok = SUCCEEDED(SHOpenFolderAndSelectItems(pidl, 0, NULL, 0));
        CoTaskMemFree(pidl);
    }
    if (!ok) {
        wchar_t args[1100];
        _snwprintf_s(args, _TRUNCATE, L"\"%s\"", wide);
        ok = (INT_PTR)ShellExecuteW(NULL, L"open", L"explorer.exe", args, NULL, SW_SHOWNORMAL) > 32;
    }
    free(wide);
    return ok;
}

int spdf_win_shell_open_with_default_app(const char* utf8_path) {
    ComScope com;
    wchar_t* wide = widen(utf8_path);
    int ok = 0;
    if (!wide || !wide[0]) {
        free(wide);
        return 0;
    }
    ok = (INT_PTR)ShellExecuteW(NULL, L"open", wide, NULL, NULL, SW_SHOWNORMAL) > 32;
    if (!ok) {
        /* Nothing is registered for .yaml on a stock Windows, so "open" fails
         * with ERROR_NO_ASSOCIATION and the honest answer is the picker the
         * shell itself would show -- not an error message, and not a guess at
         * notepad.exe, which would be this app choosing the reader's editor. */
        ok = (INT_PTR)ShellExecuteW(NULL, L"openas", wide, NULL, NULL, SW_SHOWNORMAL) > 32;
    }
    free(wide);
    return ok;
}

int spdf_win_shell_copy_text(void* hwnd, const char* utf8_text) {
    wchar_t* wide = widen(utf8_text);
    size_t bytes;
    HGLOBAL mem;
    int attempt, opened = 0;
    if (!wide) return 0;
    bytes = (wcslen(wide) + 1) * sizeof(wchar_t);
    mem = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!mem) {
        free(wide);
        return 0;
    }
    {
        void* dst = GlobalLock(mem);
        if (!dst) {
            GlobalFree(mem);
            free(wide);
            return 0;
        }
        memcpy(dst, wide, bytes);
        GlobalUnlock(mem);
    }
    free(wide);
    /* Another process may hold the clipboard for a few milliseconds; a handful
     * of retries is the convention (spdf_win_selection does the same). */
    for (attempt = 0; attempt < 5 && !opened; ++attempt) {
        opened = OpenClipboard((HWND)hwnd) != 0;
        if (!opened) Sleep(10);
    }
    if (!opened) {
        GlobalFree(mem);
        return 0;
    }
    EmptyClipboard();
    if (!SetClipboardData(CF_UNICODETEXT, mem)) {
        GlobalFree(mem);
        CloseClipboard();
        return 0;
    }
    CloseClipboard(); /* the clipboard owns `mem` now */
    return 1;
}

int spdf_win_shell_open_in_browser(const char* utf8_path) {
    wchar_t* wide = widen(utf8_path);
    wchar_t url[2100];
    wchar_t browser[MAX_PATH];
    DWORD url_len = (DWORD)(sizeof(url) / sizeof(url[0]));
    DWORD browser_len = (DWORD)(sizeof(browser) / sizeof(browser[0]));
    int ok = 0;
    if (!wide || !wide[0]) {
        free(wide);
        return 0;
    }
    if (FAILED(UrlCreateFromPathW(wide, url, &url_len, 0))) {
        free(wide);
        return 0;
    }
    free(wide);
    /* The executable registered for the http protocol IS the default browser;
     * asking it to open a file:// URL is what "open in browser" means, and it
     * sidesteps the .pdf association (which may well be this app). */
    if (SUCCEEDED(AssocQueryStringW(ASSOCF_IS_PROTOCOL, ASSOCSTR_EXECUTABLE, L"http", L"open", browser, &browser_len)) &&
        browser[0]) {
        wchar_t args[2200];
        _snwprintf_s(args, _TRUNCATE, L"\"%s\"", url);
        ok = (INT_PTR)ShellExecuteW(NULL, L"open", browser, args, NULL, SW_SHOWNORMAL) > 32;
    }
    if (!ok) {
        wchar_t args[2200];
        _snwprintf_s(args, _TRUNCATE, L"url.dll,FileProtocolHandler %s", url);
        ok = (INT_PTR)ShellExecuteW(NULL, L"open", L"rundll32.exe", args, NULL, SW_SHOWNORMAL) > 32;
    }
    return ok;
}

int spdf_win_shell_open_path_dialog(void* hwnd, wchar_t* out, int out_cap) {
    SpdfWinShellPrompt prompt;
    int rc;
    wchar_t *start, *end;
    if (!out || out_cap < 2) return -1;
    out[0] = 0;
    memset(&prompt, 0, sizeof(prompt));
    prompt.message = L"Enter the path of a document to open:";
    prompt.ok_label = L"Open";
    prompt.out = out;
    prompt.out_cap = out_cap;
    rc = spdf_win_shell_prompt_run((HWND)hwnd, L"Open Path", &prompt);
    if (rc != 1) return rc;
    /* Trim whitespace, then one pair of quotes -- Explorer's "Copy as path"
     * puts them there, and a reader pastes what they copied. */
    start = out;
    while (*start == L' ' || *start == L'\t') start++;
    end = start + wcslen(start);
    while (end > start && (end[-1] == L' ' || end[-1] == L'\t' || end[-1] == L'\r' || end[-1] == L'\n')) end--;
    if (end - start >= 2 && *start == L'"' && end[-1] == L'"') {
        start++;
        end--;
    }
    *end = 0;
    if (start != out) memmove(out, start, (wcslen(start) + 1) * sizeof(wchar_t));
    return out[0] ? 1 : 0;
}
