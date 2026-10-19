/* spdf_win_setup_shell.h — the Win32 mechanics --install and --uninstall are
 * built out of: where the per-user locations are, the Start Menu shortcut, and
 * the two ways a directory holding a RUNNING exe can be made to go away.
 *
 * Included by spdf_win_setup.cpp and by nothing else — the same arrangement
 * spdf_win_headless.h, spdf_win_d2d_png.h and spdf_win_chrome_state.h use, and
 * for the same reason: spdf_win_setup.cpp would otherwise be well past the
 * 500-line cap tools/file-size-limits.md asks not to raise. Everything here is
 * `static`, so nothing else can call it by accident; the DECISIONS these
 * functions carry out are in spdf_win_setup.h, where a test can drive them.
 */
#ifndef SPDF_WIN_SETUP_SHELL_H
#define SPDF_WIN_SETUP_SHELL_H

/* Known-folder GUIDs, spelled out rather than pulled from knownfolders.h's
 * extern symbols, exactly as spdf_win_paths.c:291 spells FOLDERID_RoamingAppData
 * and for the same reason: no uuid.lib, no <initguid.h> ordering to get wrong,
 * and portable/win/guest-build.cmd passes no /link arguments at all. */
static const GUID spdf_setup_folderid_user_programs = {
    0x5CD7AEE2, 0x2219, 0x4A67, {0xB8, 0x5D, 0x6C, 0x9C, 0xE1, 0x56, 0x60, 0xCB}}; /* UserProgramFiles */
static const GUID spdf_setup_folderid_local_appdata = {
    0xF1B32785, 0x6FBA, 0x4FCF, {0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91}};
static const GUID spdf_setup_folderid_start_programs = {
    0xA77F5D77, 0x2E2B, 0x44C3, {0xA6, 0xA2, 0xAB, 0xA6, 0x01, 0x05, 0x4A, 0x51}}; /* Start Menu\Programs */
static const GUID spdf_setup_folderid_roaming_appdata = {
    0x3EB685DB, 0x65F9, 0x4CF6, {0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D}};

/* CLSID_ShellLink, IID_IShellLinkW and IID_IPersistFile, likewise. */
static const CLSID spdf_setup_clsid_shell_link = {
    0x00021401, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const IID spdf_setup_iid_shell_link_w = {
    0x000214F9, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const IID spdf_setup_iid_persist_file = {
    0x0000010B, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};

/* --- where things go ------------------------------------------------------- */

static int setup_known_folder(const GUID* id, wchar_t* out, size_t out_len) {
    PWSTR wide = NULL;
    int ok = 0;
    if (SHGetKnownFolderPath(*id, KF_FLAG_CREATE, NULL, &wide) == S_OK && wide) {
        ok = wcslen(wide) + 1 <= out_len;
        if (ok) wcscpy_s(out, out_len, wide);
    }
    if (wide) CoTaskMemFree(wide);
    return ok;
}

/* SPDF_WIN_SETUP_ROOT, the test-only redirection documented in
 * spdf_win_setup.h. Absent (the only case that happens in the shipped app) it
 * answers 0 and every location below is the real one. */
static int setup_test_root(wchar_t* out, size_t out_len) {
    DWORD n = GetEnvironmentVariableW(SPDF_WIN_SETUP_ROOT_ENV, out, (DWORD)out_len);
    if (n == 0 || n >= out_len) {
        if (out_len) out[0] = L'\0';
        return 0;
    }
    return out[0] != L'\0';
}

/* %LOCALAPPDATA%\Programs. FOLDERID_UserProgramFiles names it directly;
 * composing it from FOLDERID_LocalAppData is the fallback for a Windows that
 * refuses the newer id, not the primary route, because the folder's location is
 * the shell's to decide and not ours to assume. */
static int setup_programs_dir(wchar_t* out, size_t out_len) {
    wchar_t root[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t local[SPDF_WIN_SETUP_PATH_MAX];
    if (setup_test_root(root, SPDF_WIN_SETUP_PATH_MAX)) return spdf_win_setup_join(root, L"Programs", out, out_len);
    if (setup_known_folder(&spdf_setup_folderid_user_programs, out, out_len)) return 1;
    if (!setup_known_folder(&spdf_setup_folderid_local_appdata, local, SPDF_WIN_SETUP_PATH_MAX)) return 0;
    return spdf_win_setup_join(local, L"Programs", out, out_len);
}

/* %APPDATA%\Microsoft\Windows\Start Menu\Programs. */
static int setup_start_menu_dir(wchar_t* out, size_t out_len) {
    wchar_t root[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t menu[SPDF_WIN_SETUP_PATH_MAX];
    if (setup_test_root(root, SPDF_WIN_SETUP_PATH_MAX)) {
        if (!spdf_win_setup_join(root, L"Start Menu", menu, SPDF_WIN_SETUP_PATH_MAX)) return 0;
        return spdf_win_setup_join(menu, L"Programs", out, out_len);
    }
    return setup_known_folder(&spdf_setup_folderid_start_programs, out, out_len);
}

/* %APPDATA%\ShenzhenPDF — so --purge knows what it is deleting, and so the
 * completion message can name the directory it is KEEPING.
 *
 * REDIRECTED TOO, and that is not a convenience: --purge is the one branch in
 * this module that deletes a directory full of the user's own settings and
 * session, and a test run with SPDF_WIN_SETUP_ROOT set must not be able to
 * reach the real one even by mistake. */
static int setup_state_dir(wchar_t* out, size_t out_len) {
    wchar_t root[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t roaming[SPDF_WIN_SETUP_PATH_MAX];
    if (setup_test_root(root, SPDF_WIN_SETUP_PATH_MAX)) {
        if (!spdf_win_setup_join(root, L"Roaming", roaming, SPDF_WIN_SETUP_PATH_MAX)) return 0;
    } else if (!setup_known_folder(&spdf_setup_folderid_roaming_appdata, roaming, SPDF_WIN_SETUP_PATH_MAX)) {
        return 0;
    }
    return spdf_win_setup_join(roaming, SPDF_WIN_SETUP_FOLDER_NAME, out, out_len);
}

/* mkdir -p, and the SILENT FAILURE spdf_win_paths.c:294 warns about: an
 * existing plain FILE at the directory's name also answers
 * ERROR_ALREADY_EXISTS, so what is there is asked about rather than assumed. */
static int setup_ensure_dir(const wchar_t* dir) {
    wchar_t work[SPDF_WIN_SETUP_PATH_MAX];
    size_t i, len;
    DWORD attrs;
    if (!dir || !*dir) return 0;
    len = wcslen(dir);
    if (len + 1 > SPDF_WIN_SETUP_PATH_MAX) return 0;
    wcscpy_s(work, SPDF_WIN_SETUP_PATH_MAX, dir);
    for (i = 0; i <= len; ++i) {
        if (i < len && work[i] != L'\\' && work[i] != L'/') continue;
        if (i < 3) continue; /* never "C:" or "C:\" */
        {
            wchar_t saved = work[i];
            work[i] = L'\0';
            if (!CreateDirectoryW(work, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) {
                work[i] = saved;
                return 0;
            }
            attrs = GetFileAttributesW(work);
            work[i] = saved;
            if (attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY)) return 0;
        }
    }
    return 1;
}

/* --- the registry root ------------------------------------------------------
 *
 * HKCU for the real install; a throwaway subkey of HKCU when the test
 * redirection is on, so setup_e2e_test can run the real writes and read them
 * back without a row appearing in the user's own installed-programs list.
 * NEVER HKLM: --install takes no admin rights and asks for none. */
static HKEY setup_root_key(int create) {
    wchar_t root[SPDF_WIN_SETUP_PATH_MAX];
    HKEY key = NULL;
    if (!setup_test_root(root, SPDF_WIN_SETUP_PATH_MAX)) return HKEY_CURRENT_USER;
    if (create) {
        if (RegCreateKeyExW(HKEY_CURRENT_USER, SPDF_WIN_SETUP_TEST_KEY, 0, NULL, REG_OPTION_NON_VOLATILE,
                            KEY_ALL_ACCESS, NULL, &key, NULL) != ERROR_SUCCESS)
            return NULL;
        return key;
    }
    if (RegOpenKeyExW(HKEY_CURRENT_USER, SPDF_WIN_SETUP_TEST_KEY, 0, KEY_ALL_ACCESS, &key) != ERROR_SUCCESS)
        return NULL;
    return key;
}

static void setup_close_root(HKEY key) {
    if (key && key != HKEY_CURRENT_USER) RegCloseKey(key);
}

/* --- the Start Menu shortcut ------------------------------------------------
 *
 * IShellLinkW + IPersistFile::Save, which is the only supported way to author a
 * .lnk — the format is undocumented and hand-writing one is how a shortcut ends
 * up working on the machine that wrote it and nowhere else. CoInitialize is
 * scoped to the call: --install is a one-shot command and must not leave an
 * apartment behind for the relaunched window to inherit. */
static int setup_write_shortcut(const wchar_t* lnk, const wchar_t* target, const wchar_t* workdir) {
    IShellLinkW* link = NULL;
    IPersistFile* file = NULL;
    HRESULT hr;
    int ok = 0;

    if (!lnk || !target) return 0;
    hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) return 0;
    if (SUCCEEDED(CoCreateInstance(spdf_setup_clsid_shell_link, NULL, CLSCTX_INPROC_SERVER,
                                   spdf_setup_iid_shell_link_w, (void**)&link)) &&
        link) {
        link->SetPath(target);
        if (workdir && *workdir) link->SetWorkingDirectory(workdir);
        link->SetDescription(L"Shenzhen PDF");
        /* The icon is the exe's own first icon group, which spdf_win.rc numbers
         * 1 precisely so Explorer and the taskbar pick it (spdf_win_about_version.h). */
        link->SetIconLocation(target, 0);
        if (SUCCEEDED(link->QueryInterface(spdf_setup_iid_persist_file, (void**)&file)) && file) {
            ok = SUCCEEDED(file->Save(lnk, TRUE));
            file->Release();
        }
        link->Release();
    }
    if (hr != RPC_E_CHANGED_MODE) CoUninitialize();
    return ok;
}

/* --- removing a directory that may hold the running exe ---------------------
 *
 * Two ways, in this order.
 *
 * 1. NOW, file by file. Works when --uninstall was run from somewhere else (a
 *    build tree, or the copy the user kept in Downloads).
 * 2. AFTER THIS PROCESS EXITS, through a detached `cmd /c` retry loop, because
 *    a mapped executable cannot delete itself: Windows holds the image open for
 *    the life of the process. The loop asks `rmdir /s /q` once a second until
 *    the directory is gone or fifty tries are up, which needs no pid at all —
 *    the lock IS the thing being waited on, so the retry is the wait. (`ping`
 *    is the sleep: `timeout` fails without a console, and this is cmd, so there
 *    is no Start-Sleep to reach for.)
 *
 * The caller falls back to MoveFileExW(MOVEFILE_DELAY_UNTIL_REBOOT) when the
 * spawn itself fails, and says which of the three happened. */
static int setup_delete_tree(const wchar_t* dir) {
    WIN32_FIND_DATAW found;
    wchar_t pattern[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t child[SPDF_WIN_SETUP_PATH_MAX];
    HANDLE h;
    if (!dir || !*dir) return 0;
    if (GetFileAttributesW(dir) == INVALID_FILE_ATTRIBUTES) return 1; /* already gone */
    if (!spdf_win_setup_join(dir, L"*", pattern, SPDF_WIN_SETUP_PATH_MAX)) return 0;
    h = FindFirstFileW(pattern, &found);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (wcscmp(found.cFileName, L".") == 0 || wcscmp(found.cFileName, L"..") == 0) continue;
            if (!spdf_win_setup_join(dir, found.cFileName, child, SPDF_WIN_SETUP_PATH_MAX)) continue;
            if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                setup_delete_tree(child);
            } else {
                if (found.dwFileAttributes & FILE_ATTRIBUTE_READONLY)
                    SetFileAttributesW(child, FILE_ATTRIBUTE_NORMAL);
                DeleteFileW(child);
            }
        } while (FindNextFileW(h, &found));
        FindClose(h);
    }
    return RemoveDirectoryW(dir) ? 1 : 0;
}

static int setup_spawn_delayed_delete(const wchar_t* dir) {
    wchar_t command[SPDF_WIN_SETUP_PATH_MAX * 3 + 160];
    wchar_t system_dir[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t cmd_exe[SPDF_WIN_SETUP_PATH_MAX];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    UINT n;

    if (!dir || !*dir) return 0;
    n = GetSystemDirectoryW(system_dir, SPDF_WIN_SETUP_PATH_MAX);
    if (n == 0 || n >= SPDF_WIN_SETUP_PATH_MAX) return 0;
    if (!spdf_win_setup_join(system_dir, L"cmd.exe", cmd_exe, SPDF_WIN_SETUP_PATH_MAX)) return 0;
    /* One cmd /c string. The inner quotes survive: with /c, cmd strips only the
     * first and last character when the whole argument is quoted. */
    _snwprintf_s(command, _countof(command), _TRUNCATE,
                 L"\"%s\" /c \"for /l %%i in (1,1,50) do @(rmdir /s /q \"%s\" >nul 2>nul & "
                 L"if not exist \"%s\" exit & ping -n 2 127.0.0.1 >nul)\"",
                 cmd_exe, dir, dir);
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    memset(&pi, 0, sizeof(pi));
    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, DETACHED_PROCESS | CREATE_NO_WINDOW, NULL, NULL, &si, &pi))
        return 0;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 1;
}

#endif /* SPDF_WIN_SETUP_SHELL_H */
