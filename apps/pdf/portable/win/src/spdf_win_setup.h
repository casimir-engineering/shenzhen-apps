/* spdf_win_setup.h — the exe IS the installer, and this is what it decides.
 *
 * THERE IS NO INSTALLER BINARY. ShenzhenPDF.exe is one statically-linked /MT
 * image with MuPDF embedded: no DLLs, no VC redistributable, nothing to
 * register before it will start. That makes it a portable app already —
 * download it, double-click it, run it — and PORTABLE USE STAYS THE DEFAULT AND
 * THE RECOMMENDED PATH. No NSIS, no WiX, no MSI, no MSIX, no third-party
 * tooling was added for this, and none should be: every one of them would exist
 * only to copy a single file.
 *
 * What was missing is the OPTIONAL half — a Start Menu entry, an "Apps &
 * features" row, a stable path for the .pdf association to point at — and that
 * is two flags on the exe itself:
 *
 *   ShenzhenPDF.exe --install                 no admin, HKCU only, per-user
 *   ShenzhenPDF.exe --uninstall [--quiet] [--purge]
 *
 * --install copies the running exe to %LOCALAPPDATA%\Programs\ShenzhenPDF\ (the
 * standard per-user location — the same one FOLDERID_UserProgramFiles names),
 * writes the shortcut, registers the association for the INSTALLED path through
 * spdf_win_assoc_register_under(), writes the Uninstall key, and relaunches the
 * installed copy. Running it AGAIN from the installed copy skips the copy, so
 * `--install` is also the repair/upgrade command and is idempotent.
 *
 * --uninstall removes exactly those four things and nothing else. The state
 * directory (%APPDATA%\ShenzhenPDF: settings, session, recents, favorites)
 * SURVIVES unless --purge is passed, and the user's documents are never touched.
 *
 * A THIRD MODE, portable, becomes explicit: a file named ShenzhenPDF.portable
 * next to the exe (or --portable) moves the state to <exe dir>\ShenzhenPDF-data,
 * so a copy on a USB stick carries its own session instead of writing into the
 * host machine's profile. --state-dir keeps precedence over both.
 *
 * WHY THE DECISIONS LIVE IN A HEADER. Everything below is pure: given a known
 * folder, a running exe path and an argv, what path, what shortcut, what
 * registry values. portable/win/tests/setup_test.c drives all of it without
 * creating a directory, writing a key or touching the Start Menu, which is the
 * only way an installer's arithmetic can be checked on the machine a person
 * actually works on. The Win32 half — CopyFileW, IShellLinkW, RegSetValueExW,
 * the detached delete — is spdf_win_setup.cpp, and it is a transcription of
 * these answers.
 */
#ifndef SPDF_WIN_SETUP_H
#define SPDF_WIN_SETUP_H

#include <stddef.h>
#include <wchar.h>
#include <wctype.h>

#include "spdf_win_about_version.h"

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_SETUP_INLINE __inline
#else
#define SPDF_WIN_SETUP_INLINE inline
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* THE FIRST-RUN QUESTION: whether the first launch asks "Run this copy" /
 * "Install" / "Install and run", and what each answer means. Pure, and its own
 * file because getting that gate wrong hangs a test run on a modal dialog —
 * read its header before touching the conditions. Included here, after
 * SPDF_WIN_SETUP_INLINE, because it uses it. */
#include "spdf_win_setup_first_run.h"

/* Widen a narrow #define from spdf_win_about_version.h, which is preprocessor
 * only (rc.exe reads it too) and therefore cannot spell its own L"" forms. */
#define SPDF_WIN_SETUP_WIDE_(x) L##x
#define SPDF_WIN_SETUP_WIDE(x) SPDF_WIN_SETUP_WIDE_(x)

/* Composed paths. Long enough for a redirected test root plus the install
 * folder plus the exe name, short enough to sit on a stack frame. */
#define SPDF_WIN_SETUP_PATH_MAX 512
/* One registry value's text: a quoted path plus " --uninstall --quiet". */
#define SPDF_WIN_SETUP_TEXT_MAX 560

/* The install folder's name under %LOCALAPPDATA%\Programs, the Start Menu
 * shortcut's file name, the portable marker and the portable data folder. */
#define SPDF_WIN_SETUP_FOLDER_NAME L"ShenzhenPDF"
#define SPDF_WIN_SETUP_EXE_NAME SPDF_WIN_SETUP_WIDE(SPDF_WIN_EXE_NAME)
#define SPDF_WIN_SETUP_SHORTCUT_NAME L"ShenzhenPDF.lnk"
#define SPDF_WIN_SETUP_PORTABLE_MARKER L"ShenzhenPDF.portable"
#define SPDF_WIN_SETUP_PORTABLE_DATA L"ShenzhenPDF-data"

/* The Apps-list key, relative to a root the caller opens (HKCU for the real
 * thing, a throwaway key in tests — the rule spdf_win_assoc.h set and this
 * follows, so setup_registry_test can read every value back without the user's
 * own "Apps & features" list ever being written). */
#define SPDF_WIN_SETUP_UNINSTALL_KEY L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\ShenzhenPDF"

/* TEST-ONLY. When SPDF_WIN_SETUP_ROOT names a directory, --install and
 * --uninstall work under it instead of the real per-user locations
 * (<root>\Programs\ShenzhenPDF and <root>\Start Menu\Programs), write the
 * registry under HKCU\<SPDF_WIN_SETUP_TEST_KEY> instead of HKCU itself, and
 * skip the relaunch. Honoured only when set; nothing in the app sets it. It
 * exists so portable/win/tests/setup_e2e_test.c can run the REAL install and
 * the REAL uninstall end to end without a leftover Start Menu entry or a row in
 * the user's installed-programs list. */
#define SPDF_WIN_SETUP_ROOT_ENV L"SPDF_WIN_SETUP_ROOT"
#define SPDF_WIN_SETUP_TEST_KEY L"Software\\ShenzhenPDF-setup-test"

/* TOOL-ONLY, and the second half of the same defence. The first-run dialog is
 * MODAL and is shown before the window exists, so a tool that launches the app
 * and then waits for a window does not fail on it — it hangs. --state-dir
 * covers most of the harness (screenshot-window.ps1, and verify-phase1.ps1
 * through it), but portable/win/measure-launch.ps1 launches against the REAL
 * %APPDATA% on purpose, because measuring session restore is the point, and
 * portable/win/drive-window.ps1 takes whatever arguments its caller passes.
 *
 * So two environment facts also suppress the question, and both are honest
 * statements about the launch rather than conveniences:
 *
 *   SPDF_WIN_SETUP_NO_PROMPT   a tool is driving this launch, not a person.
 *   SPDF_WIN_LAUNCH_PROFILE    this launch is being TIMED
 *                              (spdf_win_launch_profile.h). A measurement that
 *                              includes a dialog waiting for a human measures
 *                              the human.
 *
 * They are folded into the `explicit_flag` argument of the pure gate below, so
 * the gate remains the whole rule and this is only how one of its inputs is
 * resolved. */
#define SPDF_WIN_SETUP_NO_PROMPT_ENV L"SPDF_WIN_SETUP_NO_PROMPT"
#define SPDF_WIN_SETUP_PROFILE_ENV L"SPDF_WIN_LAUNCH_PROFILE"

/* TEST-ONLY, and the exact inverse of the two above. The three suppressors
 * meant to keep a modal dialog out of a tool's way also made the dialog
 * untestable: SPDF_WIN_SETUP_ROOT redirects everything an install touches, and
 * --state-dir redirects everything the answer is written to, and BOTH of them
 * suppress the question -- so "the prompt is shown" and "nothing real is
 * written" could not hold at once, and the three command links could only ever
 * be exercised against the user's own machine.
 *
 * This lifts precisely those two suppressors, and only them: --install,
 * --uninstall, --quiet, --purge, --portable, a headless mode, and
 * SPDF_WIN_SETUP_NO_PROMPT / SPDF_WIN_LAUNCH_PROFILE all still mean no
 * question, so no harness script and no test can grow a hang by accident.
 * Nothing in the app sets it; it exists so a live check can drive the real
 * dialog with the install redirected under SPDF_WIN_SETUP_ROOT and the answer
 * written into a --state-dir nobody reads afterwards. */
#define SPDF_WIN_SETUP_ALLOW_PROMPT_ENV L"SPDF_WIN_SETUP_ALLOW_PROMPT"

/* Whether that variable is set. Declared here because spdf_win_main.cpp needs
 * the same answer when it decides whether --state-dir counts as explicit. */
int spdf_win_setup_prompt_allowed_by_env(void);

/* --- argv ------------------------------------------------------------------
 *
 * The setup flags are scanned out of the WHOLE command line before
 * spdf_win_main.cpp's own option loop runs, because --install must act and exit
 * before a window, a Direct2D device or a session restore exists. */

typedef struct spdf_win_setup_args {
    int install;    /* --install */
    int uninstall;  /* --uninstall */
    int quiet;      /* --quiet: no message boxes, no confirmation, stdout instead */
    int purge;      /* --purge: --uninstall also deletes %APPDATA%\ShenzhenPDF */
    int portable;   /* --portable: state beside the exe, as the marker file asks */
    int state_dir;  /* --state-dir was given, and therefore wins over --portable */
    /* The document to hand the relaunched copy after --install, or NULL. */
    const wchar_t* file;
} spdf_win_setup_args;

/* The flags spdf_win_main.cpp's loop consumes a VALUE after. Only the four a
 * windowed launch can carry are listed: the rest (--zoom, --frames, --fit …)
 * belong to the headless render paths, which nobody combines with --install.
 * This is used for one thing only — deciding whether a trailing token is a
 * document to pass through the relaunch. */
static SPDF_WIN_SETUP_INLINE int spdf_win_setup_flag_takes_value(const wchar_t* flag) {
    if (!flag) return 0;
    return wcscmp(flag, L"--state-dir") == 0 || wcscmp(flag, L"--window") == 0 ||
           wcscmp(flag, L"--page") == 0 || wcscmp(flag, L"--find") == 0;
}

/* Fill `out` from argv. Returns 1 when it could (i.e. out is non-NULL); the
 * caller reads the fields. Unknown flags are IGNORED here rather than rejected:
 * the real parser next door is the one that decides what is valid, and this
 * pass must not turn `--render-png` into a usage error. */
static SPDF_WIN_SETUP_INLINE int spdf_win_setup_parse(int argc, const wchar_t* const* argv,
                                                      spdf_win_setup_args* out) {
    int i;
    if (!out) return 0;
    out->install = out->uninstall = out->quiet = out->purge = out->portable = out->state_dir = 0;
    out->file = NULL;
    if (!argv) return 1;
    for (i = 1; i < argc; ++i) {
        const wchar_t* a = argv[i];
        if (!a) continue;
        if (wcscmp(a, L"--install") == 0) out->install = 1;
        else if (wcscmp(a, L"--uninstall") == 0) out->uninstall = 1;
        else if (wcscmp(a, L"--quiet") == 0) out->quiet = 1;
        else if (wcscmp(a, L"--purge") == 0) out->purge = 1;
        else if (wcscmp(a, L"--portable") == 0) out->portable = 1;
        else if (wcscmp(a, L"--state-dir") == 0) out->state_dir = 1;
        /* A token that is not a flag and does not follow a value-taking flag is
         * the document. The LAST such token wins, matching the real parser,
         * which takes at most one. */
        if (a[0] != L'-' && !(i > 1 && spdf_win_setup_flag_takes_value(argv[i - 1]))) out->file = a;
    }
    return 1;
}

/* --- paths ----------------------------------------------------------------- */

/* Join with exactly one backslash, tolerating a trailing separator on dir. An
 * empty dir yields name alone. 0 when the result would not fit — nothing here
 * truncates a path. */
static SPDF_WIN_SETUP_INLINE int spdf_win_setup_join(const wchar_t* dir, const wchar_t* name, wchar_t* out,
                                                     size_t out_len) {
    size_t d, n;
    if (!name || !out || !out_len) return 0;
    n = wcslen(name);
    d = dir ? wcslen(dir) : 0;
    while (d && (dir[d - 1] == L'\\' || dir[d - 1] == L'/')) --d;
    if (!d) {
        if (n + 1 > out_len) return 0;
        wcscpy_s(out, out_len, name);
        return 1;
    }
    if (d + 1 + n + 1 > out_len) return 0;
    wmemcpy(out, dir, d);
    out[d] = L'\\';
    wmemcpy(out + d + 1, name, n);
    out[d + 1 + n] = L'\0';
    return 1;
}

/* The directory a path sits in, splitting on both separators and with the
 * trailing separator removed — EXCEPT at the root, where the separator is part
 * of the name: "C:" without it is drive-relative and means "wherever this
 * process last was on C:", which is not a location an installer may resolve.
 * 0 when there is no directory part at all — a bare "ShenzhenPDF.exe" has none,
 * and inventing "." for it would put the portable marker somewhere that depends
 * on the current directory. (Not a canonicaliser: a UNC share's root is trimmed
 * like any other component. Nothing here is ever handed a UNC path — the
 * install location is a known folder and the exe path is GetModuleFileNameW's.) */
static SPDF_WIN_SETUP_INLINE int spdf_win_setup_dir_of(const wchar_t* path, wchar_t* out, size_t out_len) {
    size_t n, root = 0;
    if (!path || !out || !out_len) return 0;
    n = wcslen(path);
    if (n >= 3 && path[1] == L':' && (path[2] == L'\\' || path[2] == L'/')) root = 3;
    else if (n >= 1 && (path[0] == L'\\' || path[0] == L'/')) root = 1;
    while (n && path[n - 1] != L'\\' && path[n - 1] != L'/') --n;
    while (n > root && (path[n - 1] == L'\\' || path[n - 1] == L'/')) --n;
    if (!n || n + 1 > out_len) return 0;
    wmemcpy(out, path, n);
    out[n] = L'\0';
    return 1;
}

/* <programs>\ShenzhenPDF and the exe inside it. `programs` is
 * FOLDERID_UserProgramFiles, i.e. %LOCALAPPDATA%\Programs. */
static SPDF_WIN_SETUP_INLINE int spdf_win_setup_install_dir_in(const wchar_t* programs, wchar_t* out,
                                                               size_t out_len) {
    if (!programs || !*programs) return 0;
    return spdf_win_setup_join(programs, SPDF_WIN_SETUP_FOLDER_NAME, out, out_len);
}

static SPDF_WIN_SETUP_INLINE int spdf_win_setup_install_exe_in(const wchar_t* programs, wchar_t* out,
                                                               size_t out_len) {
    wchar_t dir[SPDF_WIN_SETUP_PATH_MAX];
    if (!spdf_win_setup_install_dir_in(programs, dir, SPDF_WIN_SETUP_PATH_MAX)) return 0;
    return spdf_win_setup_join(dir, SPDF_WIN_SETUP_EXE_NAME, out, out_len);
}

/* <Start Menu\Programs>\ShenzhenPDF.lnk. Flat, not in a company sub-folder:
 * Windows 11's Start Menu ignores folders in the All Apps list anyway, and a
 * one-app folder is one more thing --uninstall could leave behind. */
static SPDF_WIN_SETUP_INLINE int spdf_win_setup_shortcut_in(const wchar_t* start_menu_programs, wchar_t* out,
                                                            size_t out_len) {
    if (!start_menu_programs || !*start_menu_programs) return 0;
    return spdf_win_setup_join(start_menu_programs, SPDF_WIN_SETUP_SHORTCUT_NAME, out, out_len);
}

static SPDF_WIN_SETUP_INLINE int spdf_win_setup_marker_in(const wchar_t* exe_dir, wchar_t* out, size_t out_len) {
    if (!exe_dir || !*exe_dir) return 0;
    return spdf_win_setup_join(exe_dir, SPDF_WIN_SETUP_PORTABLE_MARKER, out, out_len);
}

static SPDF_WIN_SETUP_INLINE int spdf_win_setup_portable_data_in(const wchar_t* exe_dir, wchar_t* out,
                                                                 size_t out_len) {
    if (!exe_dir || !*exe_dir) return 0;
    return spdf_win_setup_join(exe_dir, SPDF_WIN_SETUP_PORTABLE_DATA, out, out_len);
}

/* --- "am I already installed here?" ---------------------------------------
 *
 * The comparison --install rests on: when the running exe IS the installed one,
 * the copy is skipped and the run is a repair. Case-insensitive because NTFS
 * and the registry are; separator-agnostic and trailing-separator-tolerant
 * because a path can arrive from a shell, a shortcut or an argv and each
 * spells the same location differently. NOT a canonicalisation — no 8.3 name,
 * no symlink resolution, no relative path is resolved here; the caller passes
 * GetModuleFileNameW's answer and a path this header composed, and both are
 * already absolute. */
static SPDF_WIN_SETUP_INLINE int spdf_win_setup_same_path(const wchar_t* a, const wchar_t* b) {
    size_t na, nb, i;
    if (!a || !b) return 0;
    na = wcslen(a);
    nb = wcslen(b);
    while (na > 1 && (a[na - 1] == L'\\' || a[na - 1] == L'/')) --na;
    while (nb > 1 && (b[nb - 1] == L'\\' || b[nb - 1] == L'/')) --nb;
    if (na != nb || !na) return 0;
    for (i = 0; i < na; ++i) {
        wchar_t ca = a[i] == L'/' ? L'\\' : (wchar_t)towlower(a[i]);
        wchar_t cb = b[i] == L'/' ? L'\\' : (wchar_t)towlower(b[i]);
        if (ca != cb) return 0;
    }
    return 1;
}

/* --- portable mode --------------------------------------------------------
 *
 * The marker file or the flag turns it on; --state-dir turns it off, because an
 * explicit directory is a stronger statement than a file someone left in the
 * folder. (spdf_win_paths.h reserves exactly one override, so the two cannot
 * both be honoured and the more specific one wins.) */
static SPDF_WIN_SETUP_INLINE int spdf_win_setup_portable_wanted(int marker_present, int flag_passed,
                                                                int state_dir_given) {
    if (state_dir_given) return 0;
    return marker_present || flag_passed ? 1 : 0;
}

/* --- the Apps-list entry --------------------------------------------------- */

typedef struct spdf_win_setup_value {
    const wchar_t* name;
    int is_dword; /* 0: REG_SZ in `text`. 1: REG_DWORD in `number`. */
    wchar_t text[SPDF_WIN_SETUP_TEXT_MAX];
    unsigned long number;
} spdf_win_setup_value;

#define SPDF_WIN_SETUP_MAX_VALUES 12

typedef struct spdf_win_setup_entry {
    spdf_win_setup_value values[SPDF_WIN_SETUP_MAX_VALUES];
    int count;
} spdf_win_setup_entry;

static SPDF_WIN_SETUP_INLINE int spdf_win_setup_add_sz(spdf_win_setup_entry* e, const wchar_t* name,
                                                       const wchar_t* value) {
    spdf_win_setup_value* v;
    if (!e || e->count >= SPDF_WIN_SETUP_MAX_VALUES || !name || !value) return 0;
    if (wcslen(value) + 1 > SPDF_WIN_SETUP_TEXT_MAX) return 0;
    v = &e->values[e->count++];
    v->name = name;
    v->is_dword = 0;
    v->number = 0;
    wcscpy_s(v->text, SPDF_WIN_SETUP_TEXT_MAX, value);
    return 1;
}

static SPDF_WIN_SETUP_INLINE int spdf_win_setup_add_dword(spdf_win_setup_entry* e, const wchar_t* name,
                                                          unsigned long number) {
    spdf_win_setup_value* v;
    if (!e || e->count >= SPDF_WIN_SETUP_MAX_VALUES || !name) return 0;
    v = &e->values[e->count++];
    v->name = name;
    v->is_dword = 1;
    v->number = number;
    v->text[0] = L'\0';
    return 1;
}

/* Everything HKCU\…\Uninstall\ShenzhenPDF carries, in one pure answer.
 *
 * DisplayName / DisplayVersion / Publisher come from spdf_win_about_version.h —
 * the ONE version source the About box, the updater's compare and VERSIONINFO
 * already share, so an "Apps & features" row can never claim a version the
 * running binary does not. UninstallString is the exe's own --uninstall, which
 * is what makes this an installer with no installer: Windows' Uninstall button
 * runs the app.
 *
 * NoModify and NoRepair are 1 because there is nothing to modify — the whole
 * install is one file — and because a Repair button that did nothing would be
 * worse than no button. (`--install` re-run IS the repair, from a command line,
 * where the person asking for it can see what it says.)
 *
 * Returns 1 when every value fit. 0 leaves `out` half-built and must abort the
 * write: a partial Uninstall key is a row the user cannot remove. */
static SPDF_WIN_SETUP_INLINE int spdf_win_setup_uninstall_entry(const wchar_t* installed_exe,
                                                                const wchar_t* install_dir, unsigned long size_kb,
                                                                spdf_win_setup_entry* out) {
    wchar_t quoted[SPDF_WIN_SETUP_TEXT_MAX];
    wchar_t command[SPDF_WIN_SETUP_TEXT_MAX];
    int ok = 1;

    if (!out) return 0;
    out->count = 0;
    if (!installed_exe || !*installed_exe || !install_dir || !*install_dir) return 0;
    if (wcslen(installed_exe) + 3 > SPDF_WIN_SETUP_TEXT_MAX) return 0;
    quoted[0] = L'"';
    wcscpy_s(quoted + 1, SPDF_WIN_SETUP_TEXT_MAX - 1, installed_exe);
    wcscat_s(quoted, SPDF_WIN_SETUP_TEXT_MAX, L"\"");

    ok &= spdf_win_setup_add_sz(out, L"DisplayName", SPDF_WIN_SETUP_WIDE(SPDF_WIN_PRODUCT_NAME));
    ok &= spdf_win_setup_add_sz(out, L"DisplayVersion", SPDF_WIN_SETUP_WIDE(SPDF_WIN_VERSION_STR));
    ok &= spdf_win_setup_add_sz(out, L"Publisher", SPDF_WIN_SETUP_WIDE(SPDF_WIN_COMPANY_NAME));
    ok &= spdf_win_setup_add_sz(out, L"DisplayIcon", installed_exe);
    ok &= spdf_win_setup_add_sz(out, L"InstallLocation", install_dir);
    ok &= spdf_win_setup_add_dword(out, L"EstimatedSize", size_kb);
    if (!ok) return 0;

    if (wcslen(quoted) + wcslen(L" --uninstall --quiet") + 1 > SPDF_WIN_SETUP_TEXT_MAX) return 0;
    wcscpy_s(command, SPDF_WIN_SETUP_TEXT_MAX, quoted);
    wcscat_s(command, SPDF_WIN_SETUP_TEXT_MAX, L" --uninstall");
    ok &= spdf_win_setup_add_sz(out, L"UninstallString", command);
    wcscat_s(command, SPDF_WIN_SETUP_TEXT_MAX, L" --quiet");
    ok &= spdf_win_setup_add_sz(out, L"QuietUninstallString", command);
    ok &= spdf_win_setup_add_dword(out, L"NoModify", 1);
    ok &= spdf_win_setup_add_dword(out, L"NoRepair", 1);
    return ok;
}

/* --- the mechanics (spdf_win_setup.cpp) ------------------------------------ */

/* --install. Returns the process exit code: 0 when the app is installed (or
 * already was and was repaired), 1 when something refused. `file` is the
 * document handed to the relaunched copy, or NULL. `quiet` reports on stdout
 * instead of in a message box. `relaunch` starts the installed copy afterwards,
 * which is what the --install flag and the dialog's "Install and run" want and
 * what its plain "Install" does not. */
int spdf_win_setup_install(int quiet, const wchar_t* file, int relaunch);

/* THE FIRST-RUN STEP, whole: decide (through spdf_win_setup_first_run_action
 * above, with every condition resolved from this machine), show the dialog if
 * it is warranted, carry out the answer, and remember it. Returns an
 * spdf_win_setup_action; when spdf_win_setup_action_exits() is true of it,
 * *exit_code holds the process exit code and main() must stop.
 *
 * COSTS ALMOST NOTHING WHEN THE ANSWER IS IN. `headless` and `explicit_flag`
 * short-circuit before any I/O at all; otherwise it is two GetFileAttributesW
 * calls, a settings read that the windowed launch performs anyway, and a
 * registry open only in the case where the app is NOT installed. No COM is
 * initialised unless a dialog is actually shown. */
int spdf_win_setup_first_run(int explicit_flag, int headless, const wchar_t* file, int* exit_code);

/* --uninstall. 0 when the shortcut, the key, the association and the install
 * directory are gone (or scheduled to go at the next reboot, which is reported
 * as such), 1 when the user declined or something refused. */
int spdf_win_setup_uninstall(int quiet, int purge);

/* Portable mode, applied before spdf_win_main.cpp's option loop: when the
 * marker sits next to the exe (or `flag_passed`), point spdf_win_paths at
 * <exe dir>\ShenzhenPDF-data. Returns 1 when it did. A no-op when
 * `state_dir_given`, whose own override the loop installs a moment later. */
int spdf_win_setup_apply_portable(int flag_passed, int state_dir_given);

/* The Apps-list entry, under a root the caller opens. `root` is an HKEY, void*
 * so this header carries no <windows.h> — spdf_win_assoc.h's convention, and
 * what lets portable/win/tests/setup_registry_test.c write the real values
 * under HKCU\Software\ShenzhenPDF-test-<pid>, read every one of them back and
 * delete the tree, with the user's own installed-programs list untouched. */
int spdf_win_setup_write_uninstall_under(void* root, const spdf_win_setup_entry* entry);
int spdf_win_setup_remove_uninstall_under(void* root);

/* A .lnk's target path, through IShellLinkW — the read-back half of what
 * --install writes, so a test can assert the shortcut points at the installed
 * exe rather than merely that a file called ShenzhenPDF.lnk exists. */
int spdf_win_setup_read_shortcut(const wchar_t* lnk, wchar_t* out, size_t out_len);

/* Where --install would put things, so a test (and --uninstall) can look
 * without repeating the known-folder lookup. Both honour SPDF_WIN_SETUP_ROOT. */
int spdf_win_setup_installed_exe(wchar_t* out, size_t out_len);
int spdf_win_setup_shortcut_path(wchar_t* out, size_t out_len);
/* %APPDATA%\ShenzhenPDF: what --uninstall KEEPS and only --purge deletes.
 * Redirected by SPDF_WIN_SETUP_ROOT like the other two, so a test can exercise
 * --purge without the real settings and session being reachable at all. */
int spdf_win_setup_state_dir(wchar_t* out, size_t out_len);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_SETUP_H */
