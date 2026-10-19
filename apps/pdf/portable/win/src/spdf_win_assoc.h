/* spdf_win_assoc.h — the .pdf file association and "Make Default PDF Reader".
 *
 * A PORT of portable/linux/gtk4/spdf_default_reader.c (263 lines) and its
 * macOS original SPDFMacDefaultReader.mm. The DECISIONS are theirs, unchanged
 * and testable without a registry; only the mechanics are Windows':
 *
 *   Linux                          Windows
 *   ----------------------------   -----------------------------------------
 *   shenzhenpdf.desktop installed  the ProgID ShenzhenPDF.Document registered
 *   xdg-mime query default         .pdf's UserChoice ProgId (Explorer's own
 *                                  record of the user's choice) / AssocQueryString
 *   xdg-mime default <id> ...      NOT POSSIBLE. Since Windows 10 an app cannot
 *                                  set itself as a default: UserChoice is
 *                                  hash-protected and only Settings writes it.
 *                                  The app REGISTERS (so it appears in the
 *                                  list) and OPENS Settings on its own page:
 *                                  ms-settings:defaultapps?registeredAppUser=…
 *
 * REGISTRY WRITES GO UNDER HKCU, ONLY FROM A COMMAND THE USER INVOKES, NEVER AT
 * LAUNCH. That is a rule of this port (a viewer that edits the registry when
 * opened is a viewer that gets uninstalled), so the registration lives behind
 * SPDF_WIN_CMD_SET_DEFAULT_READER and nothing else calls it. What is written:
 *
 *   HKCU\Software\Classes\ShenzhenPDF.Document            the ProgID: name,
 *     \DefaultIcon                                        icon, and the open
 *     \shell\open\command                                 verb "<exe>" "%1"
 *   HKCU\Software\Classes\.pdf\OpenWithProgids            ShenzhenPDF.Document
 *   HKCU\Software\Classes\Applications\ShenzhenPDF.exe    the "Open with" entry
 *   HKCU\Software\ShenzhenPDF\Capabilities                what Settings lists:
 *     ApplicationName, ApplicationDescription,            name, blurb, and
 *     \FileAssociations  .pdf = ShenzhenPDF.Document      the .pdf claim
 *   HKCU\Software\RegisteredApplications  ShenzhenPDF = Software\ShenzhenPDF\Capabilities
 *
 * All of it is relative to a ROOT KEY the caller opens, so
 * portable/win/tests/assoc_test.c registers under a throwaway
 * HKCU\Software\ShenzhenPDF-test-<pid> key, reads it back, and deletes it,
 * and the user's real HKCU is never touched by a test.
 */
#ifndef SPDF_WIN_ASSOC_H
#define SPDF_WIN_ASSOC_H

#include <stddef.h>
#include <wchar.h>

#include "spdf_win_about_version.h"

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_ASSOC_INLINE __inline
#else
#define SPDF_WIN_ASSOC_INLINE inline
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* The ProgID, as a wide string for the registry calls. */
#define SPDF_WIN_ASSOC_PROGID L"ShenzhenPDF.Document"
/* The RegisteredApplications name, which is also what the Settings deep link
 * takes after registeredAppUser=. */
#define SPDF_WIN_ASSOC_APP_NAME L"ShenzhenPDF"
#define SPDF_WIN_ASSOC_SETTINGS_URI L"ms-settings:defaultapps?registeredAppUser=ShenzhenPDF"
#define SPDF_WIN_ASSOC_SETTINGS_URI_FALLBACK L"ms-settings:defaultapps"

/* --- the decisions (pure, header-only) ------------------------------------
 *
 * spdf_default_reader_should_prompt, name for name: prompt iff we are
 * registered, not already the default, the user never dismissed the prompt,
 * and this process has not prompted yet. The Windows shell has no first-open
 * hook wired to it yet; the rule is here so the hook, when it comes, cannot
 * invent a different one. */
static SPDF_WIN_ASSOC_INLINE int spdf_win_assoc_should_prompt(int registered, int is_default, int prompt_dismissed,
                                                              int already_prompted) {
    return registered && !is_default && !prompt_dismissed && !already_prompted;
}

/* spdf_default_reader_output_is_us: the ProgId Explorer records for .pdf,
 * whitespace-trimmed, exact match, case-insensitive because the registry is.
 * "ShenzhenPDF.Document.bak" is not us and neither is "ShenzhenPDF". */
static SPDF_WIN_ASSOC_INLINE int spdf_win_assoc_progid_is_us(const wchar_t* progid) {
    const wchar_t* want = SPDF_WIN_ASSOC_PROGID;
    size_t n;
    if (!progid) return 0;
    while (*progid == L' ' || *progid == L'\t' || *progid == L'\r' || *progid == L'\n') progid++;
    n = wcslen(progid);
    while (n && (progid[n - 1] == L' ' || progid[n - 1] == L'\t' || progid[n - 1] == L'\r' ||
                 progid[n - 1] == L'\n' || progid[n - 1] == L'\0'))
        n--;
    if (n != wcslen(want)) return 0;
    return _wcsnicmp(progid, want, n) == 0;
}

/* The open-verb command line for an exe path: the exe quoted, then "%1"
 * quoted, which is the only spelling that survives a path with spaces AND a
 * document with spaces. */
static SPDF_WIN_ASSOC_INLINE int spdf_win_assoc_open_command(const wchar_t* exe, wchar_t* out, size_t out_len) {
    size_t need;
    if (!exe || !out || !out_len) return 0;
    need = wcslen(exe) + 8; /* quotes, space, "%1", NUL */
    if (need > out_len) return 0;
    out[0] = L'"';
    wcscpy_s(out + 1, out_len - 1, exe);
    wcscat_s(out, out_len, L"\" \"%1\"");
    return 1;
}

/* --- the mechanics (spdf_win_assoc.cpp) ------------------------------------
 *
 * Handles are void* so this header carries no <windows.h>; each is an HKEY or
 * HWND and is documented as such. */

/* Write the registration described above under `root` (an HKEY: HKCU for the
 * real thing, a throwaway key in tests), naming `exe` as the handler. Returns
 * 1 when every key was written. Idempotent. */
int spdf_win_assoc_register_under(void* root, const wchar_t* exe);
/* Remove exactly what register_under wrote, under the same root. */
int spdf_win_assoc_unregister_under(void* root);
/* Is the ProgID registered under `root`? (The Windows form of "is
 * shenzhenpdf.desktop installed".) */
int spdf_win_assoc_is_registered_under(void* root);

/* The user's CURRENT default for .pdf, as Explorer resolves it: 1 and the
 * ProgId in `out` when there is one, 0 when nothing is set. Reads only. */
int spdf_win_assoc_current_default(wchar_t* out, size_t out_len);
/* current_default() run through progid_is_us(). */
int spdf_win_assoc_is_default(void);

/* THE COMMAND. Registers under HKCU with the running exe, then opens the
 * Windows Settings "Default apps" page on this app (falling back to the
 * general page on a Windows that lacks the deep link). Returns 1 when
 * Settings was launched. When the app is already the default it says so on
 * `hwnd` and returns 2 without opening Settings. */
int spdf_win_assoc_make_default(void* hwnd);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_ASSOC_H */
