/* spdf_win_about.h — About Shenzhen PDF, and the app's identity on the taskbar.
 *
 * ABOUT (SPDF_WIN_CMD_ABOUT): the version and build from
 * spdf_win_about_version.h -- the same constants the exe's VERSIONINFO and the
 * updater read, so the box can never disagree with either -- the rendering
 * core's version (MuPDF's FZ_VERSION, the one component version the core
 * exposes), the Windows build it runs on, and the icon out of the exe's own
 * resources. The text is built by a pure function so about_test.c can pin it
 * without a window.
 *
 * IDENTITY: spdf_win_about_apply_identity() sets the process's
 * AppUserModelID (so every ShenzhenPDF window groups under one taskbar button
 * with one icon, and a pinned shortcut is recognised as this app) and hands the
 * window its big and small icons from the resource (the title bar and Alt+Tab
 * take the window's icon, not the exe's). Called once, after the window
 * exists; it reads two resources and writes nothing to disk or registry.
 */
#ifndef SPDF_WIN_ABOUT_H
#define SPDF_WIN_ABOUT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The lines of the About box, UTF-8, "\n"-separated:
 *   Shenzhen PDF
 *   Version 26.9.2 (build 1)
 *   Rendering: MuPDF 1.27.2
 *   Windows <major>.<minor> build <n>, x64        (omitted when os_build is NULL)
 *   <copyright>
 * Returns the number of bytes written, excluding the NUL. */
int spdf_win_about_text(const char* os_build, char* out, size_t out_len);

/* The one-line "Windows 11 build 26100" string for the box, from the running
 * OS. Returns 0 (and "") when it cannot be read. */
int spdf_win_about_os_build(char* out, size_t out_len);

/* Show the box, modal against `hwnd` (an HWND), dark or light. 1 when shown
 * and dismissed, 0 when no window could be created. */
int spdf_win_about_show(void* hwnd, int dark);

/* AppUserModelID + the window's icons. Idempotent; safe to call with NULL
 * (sets only the process id). */
void spdf_win_about_apply_identity(void* hwnd);

/* DWMWA_USE_IMMERSIVE_DARK_MODE on a top-level window (an HWND), so a dark
 * dialog gets a dark caption. Shared by the About box and the shortcuts sheet. */
void spdf_win_about_dark_caption(void* hwnd, int dark);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_ABOUT_H */
