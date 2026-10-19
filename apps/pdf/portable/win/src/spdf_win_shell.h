/* spdf_win_shell.h — a PATH handed to the desktop: Show in Folder, Copy Path,
 * Open in Browser, Open Path..., where the Open dialog starts, and the Settings
 * menu's two shell rows (Open settings.yaml..., Reveal Settings Folder).
 *
 * WHAT THESE ARE THE PORT OF. GTK4's win.show-in-folder, win.copy-path and
 * win.open-in-browser (portable/linux/gtk4/spdf_shortcuts.c:66-68) and macOS's
 * File > Open Path... (Cmd+Shift+O). The Windows forms are the obvious ones --
 * the shell's own "select in Explorer", CF_UNICODETEXT, the default browser --
 * and portable/docs/windows-feature-matrix.md names the first explicitly:
 * "Windows = SHOpenFolderAndSelectItems". The Shenzhen Files file-manager
 * preference these sit beside on macOS is N/A here by design; the folder is
 * always Explorer's.
 *
 * THE OPEN DIALOG'S START FOLDER is a policy, and the policy is pure:
 * spdf_win_shell_open_start_dir() below takes the two facts it depends on and
 * returns a directory, so portable/win/tests/shell_test.c can pin it with no
 * dialog. 26.8.31-1: "starts in the document's folder"; else the folder of the
 * most recently opened document; else the user's home.
 *
 * Every function takes UTF-8 (the core's and the tab model's currency) and
 * widens at the Win32 boundary. Copy is never permission-gated (shenzhen_pdf_
 * core.h:209-214), and a path is not document text anyway.
 */
#ifndef SPDF_WIN_SHELL_H
#define SPDF_WIN_SHELL_H

#include <stddef.h>
#include <string.h>

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_SHELL_INLINE static __inline
#else
#define SPDF_WIN_SHELL_INLINE static inline
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* --- the start-folder policy (pure) ---------------------------------------- */

/* The directory part of `path` -- everything before its last separator, the
 * root kept ("C:\" for "C:\a.pdf", "\\s\share\" for "\\s\share\a.pdf"). Returns
 * 0 and writes "" when path has no separator or does not fit. */
SPDF_WIN_SHELL_INLINE int spdf_win_shell_dir_of(const char* path, char* out, size_t out_cap) {
    size_t last = 0, i, n;
    int found = 0;
    if (!out || !out_cap) return 0;
    out[0] = '\0';
    if (!path) return 0;
    for (i = 0; path[i]; ++i)
        if (path[i] == '\\' || path[i] == '/') {
            last = i;
            found = 1;
        }
    if (!found) return 0;
    /* Keep the separator when it is the root's ("C:\", "\"); drop it otherwise. */
    n = last;
    if (n == 0 || (n == 2 && path[1] == ':')) n = last + 1;
    if (n >= out_cap) {
        out[0] = '\0';
        return 0;
    }
    memcpy(out, path, n);
    out[n] = '\0';
    return 1;
}

/* Where File > Open... starts. `current_doc` is the selected tab's path (NULL
 * with no document), `last_opened` the most recent entry of the recents list
 * (NULL when empty). Returns 1 with a directory in `out`, or 0 meaning "the
 * user's home" -- resolved by the caller with spdf_win_shell_home_dir(), which
 * needs the shell. */
SPDF_WIN_SHELL_INLINE int spdf_win_shell_open_start_dir(const char* current_doc, const char* last_opened, char* out,
                                                        size_t out_cap) {
    if (spdf_win_shell_dir_of(current_doc, out, out_cap)) return 1;
    if (spdf_win_shell_dir_of(last_opened, out, out_cap)) return 1;
    if (out && out_cap) out[0] = '\0';
    return 0;
}

/* --- Win32 (spdf_win_shell.cpp) -------------------------------------------- */

/* %USERPROFILE% through SHGetKnownFolderPath(FOLDERID_Profile), as UTF-16.
 * Returns 1 on success. */
int spdf_win_shell_home_dir(wchar_t* out, int out_cap);

/* Reveal the file in Explorer with it selected: SHOpenFolderAndSelectItems, or
 * `explorer /select,` when the shell item cannot be parsed. Returns 1 when
 * something was launched. */
int spdf_win_shell_show_in_folder(const char* utf8_path);

/* Reveal a DIRECTORY in Explorer -- Settings > Reveal Settings Folder, the
 * Windows form of the mac's showPathInFolder: on its support directory
 * (ShenzhenPDFMac.mm:15697). SHOpenFolderAndSelectItems as above, with cidl 0
 * and no child items, which opens that folder rather than selecting it inside
 * its parent: the point is to SEE the yaml files, not to look at the folder
 * icon. Falls back to `explorer "<dir>"`. Returns 1 when something was
 * launched. */
int spdf_win_shell_reveal_folder(const char* utf8_dir);

/* Hand a file to whatever the shell opens that kind of file with -- Settings >
 * Open settings.yaml..., the Windows form of the mac's
 * [NSWorkspace openURL:] on the same file (:15675-15694). ShellExecuteW's
 * "open" verb, then its "openas" verb (the "How do you want to open this?"
 * picker) when nothing is registered for the extension, which for .yaml on a
 * stock Windows is the usual case. Returns 1 when something was launched. */
int spdf_win_shell_open_with_default_app(const char* utf8_path);

/* Put `utf8_text` on the clipboard as CF_UNICODETEXT. Returns 1 on success, 0
 * when the clipboard could not be opened (another process holds it, or the
 * workstation is locked -- OpenClipboard fails with ERROR_ACCESS_DENIED there). */
int spdf_win_shell_copy_text(void* hwnd, const char* utf8_text);

/* Open the document in the DEFAULT BROWSER (not the default .pdf handler, which
 * might be this app): the http protocol's registered executable is asked to
 * open the file:// URL; `rundll32 url.dll,FileProtocolHandler` when there is no
 * such registration. Returns 1 when something was launched. */
int spdf_win_shell_open_in_browser(const char* utf8_path);

/* File > Open Path...: a modal prompt for a path. Surrounding whitespace and
 * quotes (a path copied from Explorer's "Copy as path") are stripped. Returns 1
 * with a UTF-16 path in `out`, 0 when cancelled or left empty, -1 when the
 * dialog could not be shown. */
int spdf_win_shell_open_path_dialog(void* hwnd, wchar_t* out, int out_cap);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_SHELL_H */
