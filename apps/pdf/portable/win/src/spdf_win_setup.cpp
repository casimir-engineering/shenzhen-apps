/* spdf_win_setup.cpp — --install and --uninstall, carried out.
 *
 * The decisions are all in spdf_win_setup.h and are driven by
 * portable/win/tests/setup_test.c without a machine; the mechanics are in
 * spdf_win_setup_shell.h. What is left here is the SEQUENCE, and the order
 * matters in one place: --install registers the association for the INSTALLED
 * exe, not the running one, so a person who installs from Downloads and then
 * deletes the download still has a working .pdf handler. That registration is
 * spdf_win_assoc_register_under() — the same function File ▸ Make Default PDF
 * Reader calls, unchanged and not re-implemented, because two spellings of the
 * same ProgID is how one of them goes stale.
 *
 * NOTHING HERE NEEDS ADMIN, and nothing here writes outside the user's own
 * profile: HKCU only, %LOCALAPPDATA%\Programs and the per-user Start Menu. An
 * elevation prompt for what is fundamentally one file copy would be a reason not
 * to run it.
 */
#include "spdf_win_setup.h"

#include <windows.h>
#include <commctrl.h>
#include <objbase.h>
#include <shlobj.h>

#include <stdio.h>
#include <string.h>

#include "spdf_win_assoc.h"
#include "spdf_win_paths.h"
#include "spdf_win_settings.h" /* setupPromptAnswered: the first-run answer, remembered */

#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "user32.lib")

/* The known folders, mkdir -p, the registry root, the shortcut and the two
 * ways a directory holding a running exe is made to go away. */
#include "spdf_win_setup_shell.h"
/* The first-run dialog. After the shell header, whose SPDF_WIN_SETUP_PATH_MAX
 * users it sits beside; before spdf_win_setup_first_run() at the bottom, which
 * is the only caller. */
#include "spdf_win_setup_prompt.h"

/* --- reporting --------------------------------------------------------------
 *
 * A message box normally, because --install is what a double-click on a
 * downloaded exe leads to and a GUI-subsystem process has no console to print
 * into. Plain stdout/stderr under --quiet, which is what the Uninstall key's
 * QuietUninstallString runs and what a script or a test can read. */
static void setup_say(int quiet, int is_error, const wchar_t* text) {
    if (quiet) {
        fwprintf(is_error ? stderr : stdout, L"%s\n", text);
        fflush(is_error ? stderr : stdout);
        return;
    }
    MessageBoxW(NULL, text, L"Shenzhen PDF", MB_OK | (is_error ? MB_ICONWARNING : MB_ICONINFORMATION));
}

/* --- the Apps-list entry ---------------------------------------------------- */

int spdf_win_setup_write_uninstall_under(void* root_handle, const spdf_win_setup_entry* entry) {
    HKEY root = (HKEY)root_handle;
    HKEY key = NULL;
    int i;
    int ok = 1;

    if (!root || !entry || entry->count <= 0) return 0;
    if (RegCreateKeyExW(root, SPDF_WIN_SETUP_UNINSTALL_KEY, 0, NULL, REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, NULL,
                        &key, NULL) != ERROR_SUCCESS)
        return 0;
    for (i = 0; i < entry->count; ++i) {
        const spdf_win_setup_value* v = &entry->values[i];
        LONG rc;
        if (v->is_dword) {
            DWORD n = (DWORD)v->number;
            rc = RegSetValueExW(key, v->name, 0, REG_DWORD, (const BYTE*)&n, sizeof(n));
        } else {
            rc = RegSetValueExW(key, v->name, 0, REG_SZ, (const BYTE*)v->text,
                                (DWORD)((wcslen(v->text) + 1) * sizeof(wchar_t)));
        }
        if (rc != ERROR_SUCCESS) ok = 0;
    }
    RegCloseKey(key);
    return ok;
}

int spdf_win_setup_remove_uninstall_under(void* root_handle) {
    HKEY root = (HKEY)root_handle;
    LONG rc;
    if (!root) return 0;
    rc = RegDeleteTreeW(root, SPDF_WIN_SETUP_UNINSTALL_KEY);
    /* Absent is the desired end state, so "there was nothing there" is success:
     * --uninstall must be runnable twice. */
    return rc == ERROR_SUCCESS || rc == ERROR_FILE_NOT_FOUND;
}

/* --- the shortcut, read back ------------------------------------------------ */

int spdf_win_setup_read_shortcut(const wchar_t* lnk, wchar_t* out, size_t out_len) {
    IShellLinkW* link = NULL;
    IPersistFile* file = NULL;
    HRESULT hr;
    int ok = 0;

    if (!lnk || !out || !out_len) return 0;
    out[0] = L'\0';
    hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) return 0;
    if (SUCCEEDED(CoCreateInstance(spdf_setup_clsid_shell_link, NULL, CLSCTX_INPROC_SERVER,
                                   spdf_setup_iid_shell_link_w, (void**)&link)) &&
        link) {
        if (SUCCEEDED(link->QueryInterface(spdf_setup_iid_persist_file, (void**)&file)) && file) {
            if (SUCCEEDED(file->Load(lnk, STGM_READ)))
                ok = SUCCEEDED(link->GetPath(out, (int)out_len, NULL, SLGP_RAWPATH)) && out[0] != L'\0';
            file->Release();
        }
        link->Release();
    }
    if (hr != RPC_E_CHANGED_MODE) CoUninitialize();
    return ok;
}

/* --- the two locations, for callers that only want to look ------------------ */

int spdf_win_setup_installed_exe(wchar_t* out, size_t out_len) {
    wchar_t programs[SPDF_WIN_SETUP_PATH_MAX];
    if (!setup_programs_dir(programs, SPDF_WIN_SETUP_PATH_MAX)) return 0;
    return spdf_win_setup_install_exe_in(programs, out, out_len);
}

int spdf_win_setup_shortcut_path(wchar_t* out, size_t out_len) {
    wchar_t menu[SPDF_WIN_SETUP_PATH_MAX];
    if (!setup_start_menu_dir(menu, SPDF_WIN_SETUP_PATH_MAX)) return 0;
    return spdf_win_setup_shortcut_in(menu, out, out_len);
}

int spdf_win_setup_state_dir(wchar_t* out, size_t out_len) { return setup_state_dir(out, out_len); }

/* --- portable mode ---------------------------------------------------------- */

/* SPDF_WIN_SETUP_ALLOW_PROMPT: see spdf_win_setup.h for why a variable that
 * makes a modal dialog MORE likely is the safe direction to add one in. A
 * zero-length probe, not a read: the value is irrelevant, only its presence. */
int spdf_win_setup_prompt_allowed_by_env(void) {
    return GetEnvironmentVariableW(SPDF_WIN_SETUP_ALLOW_PROMPT_ENV, NULL, 0) > 0 ? 1 : 0;
}

int spdf_win_setup_apply_portable(int flag_passed, int state_dir_given) {
    wchar_t exe[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t dir[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t marker[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t data[SPDF_WIN_SETUP_PATH_MAX];
    char utf8[SPDF_WIN_PATH_MAX];
    DWORD n;
    int marker_present;

    if (state_dir_given) return 0;
    n = GetModuleFileNameW(NULL, exe, SPDF_WIN_SETUP_PATH_MAX);
    if (n == 0 || n >= SPDF_WIN_SETUP_PATH_MAX) return 0;
    if (!spdf_win_setup_dir_of(exe, dir, SPDF_WIN_SETUP_PATH_MAX)) return 0;
    if (!spdf_win_setup_marker_in(dir, marker, SPDF_WIN_SETUP_PATH_MAX)) return 0;
    marker_present = GetFileAttributesW(marker) != INVALID_FILE_ATTRIBUTES;
    if (!spdf_win_setup_portable_wanted(marker_present, flag_passed, state_dir_given)) return 0;
    if (!spdf_win_setup_portable_data_in(dir, data, SPDF_WIN_SETUP_PATH_MAX)) return 0;
    /* Through the UTF-8 boundary spdf_win_paths.h owns, not through a cast: the
     * override is the same one --state-dir installs, and the state layer speaks
     * UTF-8 all the way down to the core. */
    if (spdf_win_utf8_from_utf16(data, utf8, sizeof(utf8)) == SPDF_WIN_CONV_ERROR) return 0;
    if (!setup_ensure_dir(data)) return 0;
    spdf_win_paths_set_state_dir_override(utf8);
    return 1;
}

/* --- --install --------------------------------------------------------------- */

/* The size the Apps list shows, in KB as that value is defined. The install is
 * one file, so this is that file's size and not a walk of the directory. */
static unsigned long setup_exe_size_kb(const wchar_t* exe) {
    WIN32_FILE_ATTRIBUTE_DATA info;
    ULARGE_INTEGER size;
    if (!GetFileAttributesExW(exe, GetFileExInfoStandard, &info)) return 0;
    size.LowPart = info.nFileSizeLow;
    size.HighPart = info.nFileSizeHigh;
    return (unsigned long)((size.QuadPart + 1023) / 1024);
}

/* Copy over an exe that may be mapped by a running instance: Windows refuses to
 * overwrite it but will let it be RENAMED, which is the same trick the updater's
 * swap turns on (spdf_win_updater_install.cpp). The moved-aside copy is deleted
 * if it is free and otherwise left to the next reboot. */
static int setup_copy_over(const wchar_t* src, const wchar_t* dst) {
    wchar_t aside[SPDF_WIN_SETUP_PATH_MAX + 8];
    if (CopyFileW(src, dst, FALSE)) return 1;
    _snwprintf_s(aside, _countof(aside), _TRUNCATE, L"%s.old", dst);
    DeleteFileW(aside);
    if (!MoveFileExW(dst, aside, MOVEFILE_REPLACE_EXISTING)) return 0;
    if (!CopyFileW(src, dst, FALSE)) {
        MoveFileExW(aside, dst, MOVEFILE_REPLACE_EXISTING); /* the working copy returns */
        return 0;
    }
    if (!DeleteFileW(aside)) MoveFileExW(aside, NULL, MOVEFILE_DELAY_UNTIL_REBOOT);
    return 1;
}

static void setup_relaunch(const wchar_t* exe, const wchar_t* file) {
    wchar_t command[SPDF_WIN_SETUP_PATH_MAX * 2 + 8];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    wchar_t root[SPDF_WIN_SETUP_PATH_MAX];

    /* Never under the test redirection: an installed copy pointed at a scratch
     * directory is not a thing anyone wants to see start. */
    if (setup_test_root(root, SPDF_WIN_SETUP_PATH_MAX)) return;
    if (file && *file) _snwprintf_s(command, _countof(command), _TRUNCATE, L"\"%s\" \"%s\"", exe, file);
    else _snwprintf_s(command, _countof(command), _TRUNCATE, L"\"%s\"", exe);
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    memset(&pi, 0, sizeof(pi));
    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) return;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
}

int spdf_win_setup_install(int quiet, const wchar_t* file, int relaunch) {
    wchar_t running[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t programs[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t dir[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t exe[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t lnk[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t message[2400];
    spdf_win_setup_entry entry;
    HKEY root;
    DWORD n;
    int repaired, shortcut_ok, assoc_ok, key_ok;

    n = GetModuleFileNameW(NULL, running, SPDF_WIN_SETUP_PATH_MAX);
    if (n == 0 || n >= SPDF_WIN_SETUP_PATH_MAX) {
        setup_say(quiet, 1, L"Shenzhen PDF could not work out where it is running from, so it did not install.");
        return 1;
    }
    if (!setup_programs_dir(programs, SPDF_WIN_SETUP_PATH_MAX) ||
        !spdf_win_setup_install_dir_in(programs, dir, SPDF_WIN_SETUP_PATH_MAX) ||
        !spdf_win_setup_install_exe_in(programs, exe, SPDF_WIN_SETUP_PATH_MAX) ||
        !spdf_win_setup_shortcut_path(lnk, SPDF_WIN_SETUP_PATH_MAX)) {
        setup_say(quiet, 1, L"Shenzhen PDF could not resolve the per-user install location, so it did not install.");
        return 1;
    }
    if (!setup_ensure_dir(dir)) {
        _snwprintf_s(message, _countof(message), _TRUNCATE, L"Shenzhen PDF could not create\n\n%s", dir);
        setup_say(quiet, 1, message);
        return 1;
    }

    /* THE IDEMPOTENT CASE: already the installed copy, so there is nothing to
     * copy and this run is a repair of the shortcut, the association and the
     * Apps-list entry. */
    repaired = spdf_win_setup_same_path(running, exe);
    if (!repaired && !setup_copy_over(running, exe)) {
        _snwprintf_s(message, _countof(message), _TRUNCATE,
                     L"Shenzhen PDF could not copy itself to\n\n%s\n\nIs a copy already running from there?", exe);
        setup_say(quiet, 1, message);
        return 1;
    }

    /* The Start Menu's Programs folder exists on every real profile, but
     * IPersistFile::Save will not create a missing parent — and under the
     * test redirection there is none — so it is ensured rather than assumed. */
    {
        wchar_t menu[SPDF_WIN_SETUP_PATH_MAX];
        if (spdf_win_setup_dir_of(lnk, menu, SPDF_WIN_SETUP_PATH_MAX)) setup_ensure_dir(menu);
    }
    shortcut_ok = setup_write_shortcut(lnk, exe, dir);
    root = setup_root_key(1);
    assoc_ok = root && spdf_win_assoc_register_under(root, exe);
    key_ok = 0;
    if (root && spdf_win_setup_uninstall_entry(exe, dir, setup_exe_size_kb(exe), &entry))
        key_ok = spdf_win_setup_write_uninstall_under(root, &entry);
    setup_close_root(root);
    /* The .pdf candidate list changed, so tell the shell rather than waiting for
     * Explorer to notice on its own. FLUSHNOWAIT: a synchronous flush waits on
     * Explorer, and a process that waits on Explorer hangs whenever Explorer
     * does (spdf_win_assoc.cpp says the rest). */
    if (assoc_ok) SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST | SHCNF_FLUSHNOWAIT, NULL, NULL);

    _snwprintf_s(message, _countof(message), _TRUNCATE,
                 L"Shenzhen PDF %s installed for your user account.\n\n"
                 L"  Program      %s\n"
                 L"  Start Menu   %s\n"
                 L"  PDF handler  %s\n"
                 L"  Apps list    %s\n\n"
                 L"No administrator rights were used and nothing outside your profile was written. "
                 L"To remove it, run \"%s\" --uninstall, or use Apps & features.",
                 repaired ? L"was already installed here, and has been repaired -" : L"is", exe,
                 shortcut_ok ? lnk : L"could not be created", assoc_ok ? L"registered" : L"could not be registered",
                 key_ok ? L"listed" : L"could not be written", exe);
    setup_say(quiet, shortcut_ok && assoc_ok && key_ok ? 0 : 1, message);
    if (relaunch) setup_relaunch(exe, file);
    /* The copy is in place either way -- the app IS installed and runnable --
     * but a shortcut, an association or an Apps-list row that did not get
     * written is something that refused, and a script running --install must
     * be able to see that rather than read the message box. */
    return shortcut_ok && assoc_ok && key_ok ? 0 : 1;
}

/* --- --uninstall ------------------------------------------------------------- */

int spdf_win_setup_uninstall(int quiet, int purge) {
    wchar_t programs[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t dir[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t lnk[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t state[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t message[2400];
    const wchar_t* how;
    HKEY root;
    int have_state;

    if (!setup_programs_dir(programs, SPDF_WIN_SETUP_PATH_MAX) ||
        !spdf_win_setup_install_dir_in(programs, dir, SPDF_WIN_SETUP_PATH_MAX) ||
        !spdf_win_setup_shortcut_path(lnk, SPDF_WIN_SETUP_PATH_MAX)) {
        setup_say(quiet, 1, L"Shenzhen PDF could not resolve the per-user install location, so it removed nothing.");
        return 1;
    }
    have_state = setup_state_dir(state, SPDF_WIN_SETUP_PATH_MAX);
    if (!quiet && MessageBoxW(NULL,
                              purge ? L"Remove Shenzhen PDF and DELETE its settings, session and recent documents?"
                                    : L"Remove Shenzhen PDF? Your settings, session and recent documents are kept.",
                              L"Shenzhen PDF", MB_YESNO | MB_ICONQUESTION) != IDYES)
        return 1;

    DeleteFileW(lnk);
    root = setup_root_key(0);
    if (root) {
        spdf_win_setup_remove_uninstall_under(root);
        spdf_win_assoc_unregister_under(root);
        setup_close_root(root);
        SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST | SHCNF_FLUSHNOWAIT, NULL, NULL);
    }

    /* A RUNNING EXE CANNOT DELETE ITSELF. When --uninstall was launched from the
     * installed copy — which is exactly what the Apps list's Uninstall button
     * does — the directory can only go away after this process has, so the
     * straight delete is TRIED and its failure is the signal to hand the job to
     * a detached waiter. Running from anywhere else (a build tree, the copy in
     * Downloads) takes the first branch and is finished here. */
    if (setup_delete_tree(dir)) {
        how = L"removed";
    } else if (setup_spawn_delayed_delete(dir)) {
        how = L"removed as soon as this process exits";
    } else {
        MoveFileExW(dir, NULL, MOVEFILE_DELAY_UNTIL_REBOOT);
        how = L"removed at the next restart (nothing could delete it while it is in use)";
    }

    if (purge && have_state) setup_delete_tree(state);
    _snwprintf_s(message, _countof(message), _TRUNCATE,
                 L"Shenzhen PDF has been removed.\n\n"
                 L"  Program      %s: %s\n"
                 L"  Start Menu   shortcut deleted\n"
                 L"  PDF handler  unregistered\n"
                 L"  Apps list    entry deleted\n"
                 L"  Your data    %s%s\n\n"
                 L"Your documents were not touched.",
                 dir, how, have_state ? state : L"%%APPDATA%%\\ShenzhenPDF",
                 purge ? L" - DELETED, as --purge asked" : L" - kept");
    setup_say(quiet, 0, message);
    return 0;
}

/* --- the first-run question --------------------------------------------------
 *
 * The gate is spdf_win_setup_first_run_action() in the header, pure and covered
 * combination by combination in setup_test.c. This resolves its six arguments
 * from the machine and then does what the answer says.
 *
 * ORDER OF WORK MATTERS FOR LAUNCH TIME, not for correctness. `headless` and
 * `explicit_flag` are answered before any syscall, so a --render-window-png and
 * every harness launch (screenshot-window.ps1 and verify-phase1.ps1 through
 * --state-dir; measure-launch.ps1 and drive-window.ps1 through
 * SPDF_WIN_SETUP_NO_PROMPT, folded into explicit_flag below) leave this
 * function having touched nothing at all. The remembered case costs two
 * GetFileAttributesW calls plus a
 * settings read the windowed launch performs three statements later anyway, and
 * a registry open only when the app is NOT installed. No COM, no shell, no
 * dialog. */

static int setup_uninstall_key_present(void) {
    HKEY root = setup_root_key(0);
    HKEY key;
    int present;
    if (!root) return 0;
    present = RegOpenKeyExW(root, SPDF_WIN_SETUP_UNINSTALL_KEY, 0, KEY_READ, &key) == ERROR_SUCCESS;
    if (present) RegCloseKey(key);
    setup_close_root(root);
    return present;
}

/* The answer, in settings.yaml, through the settings module and its
 * unknown-key carry-through — not a registry value and not a marker file, so a
 * reader who copies their settings.yaml to another machine is not asked again
 * there either. */
static void setup_remember_answered(void) {
    spdf_win_settings* settings = spdf_win_settings_shared();
    if (!settings || settings->setup_prompt_answered) return;
    settings->setup_prompt_answered = 1;
    spdf_win_settings_commit();
}

int spdf_win_setup_first_run(int explicit_flag, int headless, const wchar_t* file, int* exit_code) {
    wchar_t running[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t running_dir[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t marker[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t installed[SPDF_WIN_SETUP_PATH_MAX];
    wchar_t install_dir[SPDF_WIN_SETUP_PATH_MAX];
    int marker_present = 0;
    int from_install_dir = 0;
    int already_installed = 0;
    int answered = 0;
    int action;
    DWORD n;

    if (exit_code) *exit_code = 0;
    /* A tool is driving or timing this launch, or the install is redirected to a
     * test root: all three are "somebody already said what they want", which is
     * what explicit_flag means. GetEnvironmentVariableW with a zero-length
     * buffer is a probe, not a read -- see spdf_win_setup.h for why these two
     * exist at all. */
    if (!explicit_flag &&
        (GetEnvironmentVariableW(SPDF_WIN_SETUP_NO_PROMPT_ENV, NULL, 0) > 0 ||
         GetEnvironmentVariableW(SPDF_WIN_SETUP_PROFILE_ENV, NULL, 0) > 0 ||
         (GetEnvironmentVariableW(SPDF_WIN_SETUP_ROOT_ENV, NULL, 0) > 0 &&
          !spdf_win_setup_prompt_allowed_by_env())))
        explicit_flag = 1;
    /* Before anything else and before any further I/O: see the note above. */
    if (headless || explicit_flag) return SPDF_WIN_SETUP_ACTION_RUN_ONCE;

    n = GetModuleFileNameW(NULL, running, SPDF_WIN_SETUP_PATH_MAX);
    /* Cannot tell where we are, so cannot tell whether to ask. Launch silently:
     * a dialog is never the right answer to an unanswerable question. */
    if (n == 0 || n >= SPDF_WIN_SETUP_PATH_MAX) return SPDF_WIN_SETUP_ACTION_RUN_ONCE;
    running_dir[0] = L'\0';
    if (spdf_win_setup_dir_of(running, running_dir, SPDF_WIN_SETUP_PATH_MAX) &&
        spdf_win_setup_marker_in(running_dir, marker, SPDF_WIN_SETUP_PATH_MAX))
        marker_present = GetFileAttributesW(marker) != INVALID_FILE_ATTRIBUTES;
    if (spdf_win_setup_installed_exe(installed, SPDF_WIN_SETUP_PATH_MAX) &&
        spdf_win_setup_dir_of(installed, install_dir, SPDF_WIN_SETUP_PATH_MAX)) {
        from_install_dir =
            spdf_win_setup_same_path(running, installed) || spdf_win_setup_same_path(running_dir, install_dir);
        already_installed = GetFileAttributesW(installed) != INVALID_FILE_ATTRIBUTES;
    }
    /* The registry only when the exe is absent: an install whose file was
     * deleted by hand still counts as installed, and the Uninstall key is what
     * says so. Skipped entirely once anything else has already decided. */
    if (!already_installed && !from_install_dir && !marker_present)
        already_installed = setup_uninstall_key_present();
    if (!marker_present && !from_install_dir && !already_installed) {
        spdf_win_settings* settings = spdf_win_settings_shared();
        answered = settings && settings->setup_prompt_answered;
    }

    if (spdf_win_setup_first_run_action(already_installed, from_install_dir, marker_present, answered,
                                        explicit_flag, headless) != SPDF_WIN_SETUP_FIRST_RUN_ASK)
        return SPDF_WIN_SETUP_ACTION_RUN_ONCE;

    action = spdf_win_setup_action_for_button(setup_prompt_show());
    switch (action) {
        case SPDF_WIN_SETUP_ACTION_RUN_PORTABLE:
            setup_remember_answered();
            return action;
        case SPDF_WIN_SETUP_ACTION_INSTALL:
            /* No relaunch: this choice installs and closes. */
            setup_remember_answered();
            if (exit_code) *exit_code = spdf_win_setup_install(0, NULL, 0);
            return action;
        case SPDF_WIN_SETUP_ACTION_INSTALL_AND_RUN:
            setup_remember_answered();
            if (exit_code) *exit_code = spdf_win_setup_install(0, file, 1);
            return action;
        default:
            /* Esc, the close box, or a dialog that could not be shown. Run this
             * copy, remember nothing, ask again next time. */
            return SPDF_WIN_SETUP_ACTION_RUN_ONCE;
    }
}
