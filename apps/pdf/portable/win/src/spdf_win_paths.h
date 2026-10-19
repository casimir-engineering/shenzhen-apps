/* spdf_win_paths.h — where a Windows build keeps its state, and the UTF-8/UTF-16
 * boundary that gets it there intact.
 *
 * Two jobs:
 *
 *   1. Resolve the Windows equivalent of the mac app's
 *      ~/Library/Application Support/ShenzhenPDF and the GTK app's
 *      $XDG_CONFIG_HOME/shenzhenpdf, namely
 *
 *          <FOLDERID_RoamingAppData>\ShenzhenPDF        (i.e. %APPDATA%\ShenzhenPDF)
 *
 *      resolved through SHGetKnownFolderPath, NOT through the %APPDATA%
 *      environment variable: the variable is spoofable by whoever launched the
 *      process and is simply absent in service/SYSTEM contexts (which is
 *      exactly the context `prlctl exec` uses, so a test that passed on the
 *      env var would be testing nothing).
 *
 *   2. Convert between Win32's UTF-16 and portable/core's UTF-8. This is the
 *      only place mojibake can enter the state layer, so the conversion is
 *      implemented here in portable C rather than delegated to
 *      MultiByteToWideChar: the code that ships on Windows is then literally
 *      the code exercised by portable/win/tests/paths_test.c on macOS,
 *      non-ASCII user names included. It is strict — unpaired surrogates,
 *      overlong forms, CESU-8 surrogate encodings and out-of-range scalars are
 *      rejected rather than silently replaced, because a state path that got
 *      "mostly" converted writes the user's session to the wrong directory.
 *
 * Buffer contract: every composer takes (out, out_bytes) and returns 0 without
 * touching out when the result would not fit. Nothing here truncates.
 */
#ifndef SPDF_WIN_PATHS_H
#define SPDF_WIN_PATHS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A UTF-16 code unit. On MSVC wchar_t is 16-bit and identical to WCHAR, so
 * Win32 pointers pass through with no cast; elsewhere (macOS/clang, where
 * wchar_t is 32-bit) it is unsigned short, so the native tests exercise real
 * 16-bit units and real surrogate pairs. */
#if defined(_WIN32)
typedef wchar_t spdf_wchar;
#else
typedef unsigned short spdf_wchar;
#endif

/* Comfortable size for a composed state path. The state directory is short;
 * this leaves room for %APPDATA% under a long profile name plus a file name,
 * without putting a 32K extended-length buffer on the stack. Callers that
 * handle arbitrary document paths should size their own buffers. */
#define SPDF_WIN_PATH_MAX 4096

/* The directory name appended to the roaming app-data folder. Matches the mac
 * app's "ShenzhenPDF" support directory exactly, so a settings.yaml is
 * recognisable across platforms. */
#define SPDF_WIN_APP_DIR_NAME "ShenzhenPDF"

/* Sentinel returned by the two bounded converters on failure. */
#define SPDF_WIN_CONV_ERROR ((size_t)-1)

/* --- UTF-16 <-> UTF-8 ---------------------------------------------------- */

/* Convert NUL-terminated UTF-16 to UTF-8. Returns the byte count written
 * (excluding the NUL) and NUL-terminates, or SPDF_WIN_CONV_ERROR when the
 * input is not well-formed UTF-16 or the result does not fit. */
size_t spdf_win_utf8_from_utf16(const spdf_wchar* src, char* out, size_t out_bytes);

/* Convert NUL-terminated UTF-8 to UTF-16. Returns the code-unit count written
 * (excluding the NUL) and NUL-terminates, or SPDF_WIN_CONV_ERROR when the
 * input is not well-formed UTF-8 or the result does not fit. */
size_t spdf_win_utf16_from_utf8(const char* src, spdf_wchar* out, size_t out_units);

/* Allocating variants for the Win32 call boundary, where the length is not
 * known up front. Caller free()s. NULL on malformed input or out of memory. */
char* spdf_win_utf8_dup_from_utf16(const spdf_wchar* src);
spdf_wchar* spdf_win_utf16_dup_from_utf8(const char* src);

/* --- path composition (pure; no Win32, testable anywhere) ---------------- */

/* Join dir and name with a single '\'. Forward slashes in either part are
 * normalised to '\' (Windows accepts both, but a mixed path defeats the
 * prefix comparison in spdf_win_path_to_extended). An empty dir yields name
 * alone. Returns 1 on success, 0 when the result would not fit. */
int spdf_win_path_join(const char* dir, const char* name, char* out, size_t out_bytes);

/* Length of the unremovable root of path: 3 for "C:\", 2 for the
 * drive-relative "C:", 1 for "\", the run through "\\server\share\" for UNC,
 * and the corresponding lengths under a "\\?\" or "\\?\UNC\" prefix. 0 for a
 * relative path. Used to know where mkdir -p may start creating. */
size_t spdf_win_path_root_len(const char* path);

/* 1 when path names an absolute location (has a root of at least 3, i.e. a
 * drive with a separator, or a UNC share). */
int spdf_win_path_is_absolute(const char* path);

/* Pointer to the final component of path, splitting on BOTH separators. The
 * core's own splitters accept only '/', so anything handing a Windows path to
 * portable/core must reduce it here first — notably
 * spdf_state_header_for_file(), which would otherwise derive a state file's
 * header comment from "C:\Users\..." instead of "settings". Never NULL for a
 * non-NULL argument. */
const char* spdf_win_path_basename(const char* path);

/* Rewrite an absolute path into extended-length form so it escapes MAX_PATH:
 *   C:\dir\f            -> \\?\C:\dir\f
 *   \\server\share\f    -> \\?\UNC\server\share\f
 * A path already carrying the prefix, and any relative path (which cannot be
 * prefixed), is copied through unchanged. Returns 1 on success, 0 when the
 * result would not fit.
 *
 * Note the prefix also disables Win32 path normalisation, so "." and ".."
 * components stop being resolved. Everything this module opens is composed
 * from a known-good root plus a plain file name, so that is a feature: it is
 * the only way to open a path longer than 260 characters without depending on
 * the per-machine LongPathsEnabled policy. */
int spdf_win_path_to_extended(const char* path, char* out, size_t out_bytes);

/* Compose <roaming_dir>\ShenzhenPDF. Pure — this is the half of
 * spdf_win_paths_state_dir() that does not need a Windows session, so the
 * layout is asserted natively. Returns 1 on success, 0 when it would not fit
 * or roaming_dir is empty. */
int spdf_win_paths_state_dir_in(const char* roaming_dir, char* out, size_t out_bytes);

/* Copy path into the form the host's file APIs actually accept: identity on
 * Windows, '\' -> '/' everywhere else. Only the POSIX build needs it — it is
 * what lets the native tests open the '\'-separated paths this module composes
 * (on macOS '\' is an ordinary filename character, so without this a joined
 * path becomes one long file name). Returns 1 on success, 0 when it would not
 * fit. */
int spdf_win_path_to_native(const char* path, char* out, size_t out_bytes);

/* --- resolution (Win32 on Windows, $HOME fallback elsewhere) ------------- */

/* mkdir -p. Returns 1 when dir exists afterwards. */
int spdf_win_paths_ensure_dir(const char* dir);

/* The state directory in UTF-8, created if it does not exist yet. Resolved
 * once and cached. Returns 1 on success, 0 when the known folder cannot be
 * resolved or the directory cannot be created. */
int spdf_win_paths_state_dir(char* out, size_t out_bytes);

/* <state dir>\<name>, e.g. spdf_win_paths_state_file("settings.yaml", ...). */
int spdf_win_paths_state_file(const char* name, char* out, size_t out_bytes);

/* Point the state directory somewhere else. For tests and for an explicit
 * portable-mode switch decided by the frontend; deliberately NOT an
 * environment variable, for the same reason %APPDATA% is not consulted.
 * Pass NULL to restore the resolved location. */
void spdf_win_paths_set_state_dir_override(const char* dir);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_PATHS_H */
