/* spdf_win_paths.c — see spdf_win_paths.h for the contract and the rationale.
 *
 * Everything above the "--- Win32" divider is portable C and runs unchanged on
 * macOS under portable/win/tests/paths_test.c. Only the known-folder lookup and
 * the directory creation are platform-split, and the POSIX branch exists so the
 * whole module stays exercisable natively rather than as a compile-only stub.
 */
#include "spdf_win_paths.h"

#include <stdlib.h>
#include <string.h>

/* --- UTF-16 <-> UTF-8 ---------------------------------------------------- */

/* Decode one UTF-16 code point at *pos, advancing it. Returns -1 on an
 * unpaired surrogate in either direction. */
static long utf16_next(const spdf_wchar* src, size_t* pos) {
    unsigned unit = (unsigned)src[(*pos)++] & 0xFFFFu;
    if (unit >= 0xD800u && unit <= 0xDBFFu) {
        unsigned low = (unsigned)src[*pos] & 0xFFFFu;
        if (low < 0xDC00u || low > 0xDFFFu) return -1; /* also catches the NUL */
        (*pos)++;
        return (long)(0x10000u + ((unit - 0xD800u) << 10) + (low - 0xDC00u));
    }
    if (unit >= 0xDC00u && unit <= 0xDFFFu) return -1; /* low surrogate first */
    return (long)unit;
}

size_t spdf_win_utf8_from_utf16(const spdf_wchar* src, char* out, size_t out_bytes) {
    size_t pos = 0, written = 0;
    if (!src || !out || out_bytes == 0) return SPDF_WIN_CONV_ERROR;
    while (src[pos]) {
        long cp = utf16_next(src, &pos);
        unsigned char buf[4];
        size_t need;
        if (cp < 0) return SPDF_WIN_CONV_ERROR;
        if (cp < 0x80) {
            need = 1;
            buf[0] = (unsigned char)cp;
        } else if (cp < 0x800) {
            need = 2;
            buf[0] = (unsigned char)(0xC0 | (cp >> 6));
            buf[1] = (unsigned char)(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            need = 3;
            buf[0] = (unsigned char)(0xE0 | (cp >> 12));
            buf[1] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F));
            buf[2] = (unsigned char)(0x80 | (cp & 0x3F));
        } else {
            need = 4;
            buf[0] = (unsigned char)(0xF0 | (cp >> 18));
            buf[1] = (unsigned char)(0x80 | ((cp >> 12) & 0x3F));
            buf[2] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F));
            buf[3] = (unsigned char)(0x80 | (cp & 0x3F));
        }
        if (written + need + 1 > out_bytes) return SPDF_WIN_CONV_ERROR;
        memcpy(out + written, buf, need);
        written += need;
    }
    out[written] = 0;
    return written;
}

/* Decode one UTF-8 scalar at *pos, advancing it. Returns -1 for any
 * ill-formed sequence: bad lead byte, bad continuation, overlong encoding, a
 * surrogate encoded as three bytes (CESU-8), or a scalar above U+10FFFF. */
static long utf8_next(const char* src, size_t* pos) {
    const unsigned char* s = (const unsigned char*)src + *pos;
    unsigned lead = s[0];
    unsigned need, i;
    long cp;

    if (lead < 0x80u) {
        *pos += 1;
        return (long)lead;
    }
    if (lead >= 0xC2u && lead <= 0xDFu) {
        need = 1;
        cp = (long)(lead & 0x1Fu);
    } else if (lead >= 0xE0u && lead <= 0xEFu) {
        need = 2;
        cp = (long)(lead & 0x0Fu);
    } else if (lead >= 0xF0u && lead <= 0xF4u) {
        need = 3;
        cp = (long)(lead & 0x07u);
    } else {
        return -1; /* continuation byte in lead position, 0xC0/0xC1, 0xF5+ */
    }
    for (i = 1; i <= need; i++) {
        if ((s[i] & 0xC0u) != 0x80u) return -1;
        cp = (cp << 6) | (long)(s[i] & 0x3Fu);
    }
    if (need == 2 && (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF))) return -1;
    if (need == 3 && (cp < 0x10000 || cp > 0x10FFFF)) return -1;
    *pos += need + 1;
    return cp;
}

size_t spdf_win_utf16_from_utf8(const char* src, spdf_wchar* out, size_t out_units) {
    size_t pos = 0, written = 0;
    if (!src || !out || out_units == 0) return SPDF_WIN_CONV_ERROR;
    while (src[pos]) {
        long cp = utf8_next(src, &pos);
        if (cp < 0) return SPDF_WIN_CONV_ERROR;
        if (cp < 0x10000) {
            if (written + 2 > out_units) return SPDF_WIN_CONV_ERROR;
            out[written++] = (spdf_wchar)cp;
        } else {
            if (written + 3 > out_units) return SPDF_WIN_CONV_ERROR;
            cp -= 0x10000;
            out[written++] = (spdf_wchar)(0xD800u + (unsigned)(cp >> 10));
            out[written++] = (spdf_wchar)(0xDC00u + (unsigned)(cp & 0x3FF));
        }
    }
    out[written] = 0;
    return written;
}

char* spdf_win_utf8_dup_from_utf16(const spdf_wchar* src) {
    size_t units = 0, bytes, got;
    char* out;
    if (!src) return NULL;
    while (src[units]) units++;
    bytes = units * 3 + 5; /* worst case 3 bytes/unit; a pair costs 4 for 2 units */
    out = (char*)malloc(bytes);
    if (!out) return NULL;
    got = spdf_win_utf8_from_utf16(src, out, bytes);
    if (got == SPDF_WIN_CONV_ERROR) {
        free(out);
        return NULL;
    }
    return out;
}

spdf_wchar* spdf_win_utf16_dup_from_utf8(const char* src) {
    size_t units, got;
    spdf_wchar* out;
    if (!src) return NULL;
    units = strlen(src) + 1; /* UTF-8 never yields more code units than bytes */
    out = (spdf_wchar*)malloc(units * sizeof(spdf_wchar));
    if (!out) return NULL;
    got = spdf_win_utf16_from_utf8(src, out, units);
    if (got == SPDF_WIN_CONV_ERROR) {
        free(out);
        return NULL;
    }
    return out;
}

/* --- path composition ---------------------------------------------------- */

static int is_sep(char c) { return c == '\\' || c == '/'; }

static int is_drive_letter(char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}

/* Length through the "\\server\share" (or "server\share") run starting at p. */
static size_t unc_body_len(const char* p) {
    size_t i = 0, parts = 0;
    while (parts < 2) {
        if (!p[i]) return 0; /* incomplete: no share component */
        while (p[i] && !is_sep(p[i])) i++;
        parts++;
        if (parts < 2) {
            if (!is_sep(p[i])) return 0;
            i++;
        }
    }
    if (is_sep(p[i])) i++;
    return i;
}

size_t spdf_win_path_root_len(const char* path) {
    size_t prefix = 0, body;
    if (!path || !*path) return 0;
    if (is_sep(path[0]) && is_sep(path[1]) && path[2] == '?' && is_sep(path[3])) {
        prefix = 4;
        if ((path[4] == 'U' || path[4] == 'u') && (path[5] == 'N' || path[5] == 'n') &&
            (path[6] == 'C' || path[6] == 'c') && is_sep(path[7])) {
            body = unc_body_len(path + 8);
            return body ? prefix + 4 + body : 0;
        }
    }
    if (is_drive_letter(path[prefix]) && path[prefix + 1] == ':')
        return prefix + (is_sep(path[prefix + 2]) ? 3 : 2);
    if (prefix) return 0; /* "\\?\" must be followed by a drive or UNC\ */
    if (is_sep(path[0]) && is_sep(path[1])) {
        body = unc_body_len(path + 2);
        return body ? 2 + body : 0;
    }
    if (is_sep(path[0])) return 1;
    return 0;
}

int spdf_win_path_is_absolute(const char* path) { return spdf_win_path_root_len(path) >= 3; }

const char* spdf_win_path_basename(const char* path) {
    const char* base;
    size_t i;
    if (!path) return "";
    base = path;
    for (i = 0; path[i]; i++)
        if (is_sep(path[i])) base = path + i + 1;
    return base;
}

int spdf_win_path_join(const char* dir, const char* name, char* out, size_t out_bytes) {
    size_t dir_len, name_len, total, i;
    if (!out || out_bytes == 0) return 0;
    if (!name) name = "";
    dir_len = dir ? strlen(dir) : 0;
    while (dir_len > 0 && is_sep(dir[dir_len - 1])) dir_len--;
    while (*name && is_sep(*name)) name++;
    name_len = strlen(name);

    total = dir_len + (dir_len && name_len ? 1 : 0) + name_len;
    if (total + 1 > out_bytes) return 0;
    if (dir_len) memcpy(out, dir, dir_len);
    if (dir_len && name_len) out[dir_len] = '\\';
    if (name_len) memcpy(out + dir_len + (dir_len ? 1 : 0), name, name_len);
    out[total] = 0;
    for (i = 0; i < total; i++)
        if (out[i] == '/') out[i] = '\\';
    return 1;
}

int spdf_win_path_to_extended(const char* path, char* out, size_t out_bytes) {
    size_t len, root;
    if (!path || !out || out_bytes == 0) return 0;
    len = strlen(path);
    root = spdf_win_path_root_len(path);

    if (root >= 4 && is_sep(path[0]) && is_sep(path[1]) && path[2] == '?') {
        if (len + 1 > out_bytes) return 0;
        memcpy(out, path, len + 1);
        return 1;
    }
    if (root < 3) { /* relative, or a bare "\" — nothing to anchor the prefix to */
        if (len + 1 > out_bytes) return 0;
        memcpy(out, path, len + 1);
        return 1;
    }
    if (is_sep(path[0]) && is_sep(path[1])) { /* \\server\share\... -> \\?\UNC\server\share\... */
        if (8 + (len - 2) + 1 > out_bytes) return 0;
        memcpy(out, "\\\\?\\UNC\\", 8);
        memcpy(out + 8, path + 2, len - 2 + 1);
    } else { /* C:\... -> \\?\C:\... */
        if (4 + len + 1 > out_bytes) return 0;
        memcpy(out, "\\\\?\\", 4);
        memcpy(out + 4, path, len + 1);
    }
    for (len = 0; out[len]; len++)
        if (out[len] == '/') out[len] = '\\';
    return 1;
}

int spdf_win_paths_state_dir_in(const char* roaming_dir, char* out, size_t out_bytes) {
    if (!roaming_dir || !*roaming_dir) return 0;
    return spdf_win_path_join(roaming_dir, SPDF_WIN_APP_DIR_NAME, out, out_bytes);
}

int spdf_win_path_to_native(const char* path, char* out, size_t out_bytes) {
    size_t i, len;
    if (!path || !out) return 0;
    len = strlen(path);
    if (len + 1 > out_bytes) return 0;
#if defined(_WIN32)
    memcpy(out, path, len + 1);
#else
    for (i = 0; i <= len; i++) out[i] = path[i] == '\\' ? '/' : path[i];
#endif
    (void)i;
    return 1;
}

/* --- Win32 (and the POSIX branch that keeps this testable) --------------- */

#if defined(_WIN32)

#include <windows.h>
#include <shlobj.h>

#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")

/* FOLDERID_RoamingAppData, {3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}. Spelled out
 * rather than pulled from knownfolders.h's extern GUIDs so the module needs
 * neither uuid.lib nor a fragile <initguid.h> include order — the guest build
 * (portable/win/guest-build.cmd) passes no /link arguments at all. */
static const GUID spdf_folderid_roaming_appdata = {
    0x3EB685DB, 0x65F9, 0x4CF6, {0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D}};

/* SILENT FAILURE IF WRONG: CreateDirectoryW answers ERROR_ALREADY_EXISTS for a
 * plain FILE sitting at the directory's name, not just for a directory. Taking
 * that as success makes spdf_win_paths_state_dir() hand back a path that is not
 * a directory; every later CreateFileW beneath it fails with
 * ERROR_PATH_NOT_FOUND, and the state layer reports that as "you have no
 * settings" -- so the user's recent files, window positions and session appear
 * to have vanished, with no message and nothing pointing at the file that is in
 * the way. Ask what is actually there, exactly as the POSIX branch below does
 * with stat()+S_ISDIR. */
static int mkdir_one(const char* utf8_dir) {
    wchar_t wide[SPDF_WIN_PATH_MAX];
    char extended[SPDF_WIN_PATH_MAX];
    DWORD attrs;
    if (!spdf_win_path_to_extended(utf8_dir, extended, sizeof(extended))) return 0;
    if (spdf_win_utf16_from_utf8(extended, wide, SPDF_WIN_PATH_MAX) == SPDF_WIN_CONV_ERROR) return 0;
    if (CreateDirectoryW(wide, NULL)) return 1;
    if (GetLastError() != ERROR_ALREADY_EXISTS) return 0;
    attrs = GetFileAttributesW(wide);
    return attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

static int resolve_roaming_dir(char* out, size_t out_bytes) {
    PWSTR wide = NULL;
    HRESULT hr;
    size_t got;
    /* KF_FLAG_CREATE so a brand-new profile that has never had a roaming
     * folder materialised still yields a usable directory. */
    hr = SHGetKnownFolderPath(&spdf_folderid_roaming_appdata, KF_FLAG_CREATE, NULL, &wide);
    if (FAILED(hr) || !wide) {
        if (wide) CoTaskMemFree(wide);
        return 0;
    }
    got = spdf_win_utf8_from_utf16(wide, out, out_bytes);
    CoTaskMemFree(wide);
    return got != SPDF_WIN_CONV_ERROR;
}

#else /* POSIX: macOS/Linux, so the native tests drive the real code paths */

#include <sys/stat.h>
#include <sys/types.h>

static int mkdir_one(const char* dir) {
    struct stat st;
    char native[SPDF_WIN_PATH_MAX];
    if (!spdf_win_path_to_native(dir, native, sizeof(native))) return 0;
    if (mkdir(native, 0700) == 0) return 1;
    return stat(native, &st) == 0 && S_ISDIR(st.st_mode);
}

/* Scaffolding only. There is no roaming app-data folder off Windows, so this
 * stands in with $HOME purely so spdf_win_paths_state_dir() has a code path to
 * exercise; the tests set an override and never rely on this location. */
static int resolve_roaming_dir(char* out, size_t out_bytes) {
    const char* home = getenv("HOME");
    size_t len;
    if (!home || !*home) return 0;
    len = strlen(home);
    if (len + 1 > out_bytes) return 0;
    memcpy(out, home, len + 1);
    return 1;
}

#endif

int spdf_win_paths_ensure_dir(const char* dir) {
    char work[SPDF_WIN_PATH_MAX];
    size_t root, i, len;
    if (!dir || !*dir) return 0;
    len = strlen(dir);
    if (len + 1 > sizeof(work)) return 0;
    memcpy(work, dir, len + 1);
    for (i = 0; i < len; i++)
        if (work[i] == '/') work[i] = '\\';

    root = spdf_win_path_root_len(work);
    /* Trailing separators would make the last iteration re-create the same
     * directory with a "...\" spelling, which CreateDirectoryW rejects under
     * the \\?\ prefix. */
    while (len > root && work[len - 1] == '\\') work[--len] = 0;
    if (len == 0) return 0;
    for (i = root; i <= len; i++) {
        if (i < len && work[i] != '\\') continue;
        if (i == root) continue; /* an empty component right after the root */
        work[i] = 0;
        if (!mkdir_one(work)) return 0;
        if (i < len) work[i] = '\\';
    }
    return 1;
}

static char g_state_dir_override[SPDF_WIN_PATH_MAX];
static char g_state_dir_cache[SPDF_WIN_PATH_MAX];

void spdf_win_paths_set_state_dir_override(const char* dir) {
    g_state_dir_cache[0] = 0;
    if (!dir || !*dir || strlen(dir) + 1 > sizeof(g_state_dir_override)) {
        g_state_dir_override[0] = 0;
        return;
    }
    memcpy(g_state_dir_override, dir, strlen(dir) + 1);
}

int spdf_win_paths_state_dir(char* out, size_t out_bytes) {
    char roaming[SPDF_WIN_PATH_MAX];
    const char* resolved;
    size_t len;

    if (g_state_dir_override[0]) {
        resolved = g_state_dir_override;
    } else {
        if (!g_state_dir_cache[0]) {
            if (!resolve_roaming_dir(roaming, sizeof(roaming))) return 0;
            if (!spdf_win_paths_state_dir_in(roaming, g_state_dir_cache, sizeof(g_state_dir_cache)))
                return 0;
        }
        resolved = g_state_dir_cache;
    }
    if (!spdf_win_paths_ensure_dir(resolved)) return 0;
    len = strlen(resolved);
    if (!out || len + 1 > out_bytes) return 0;
    memcpy(out, resolved, len + 1);
    return 1;
}

int spdf_win_paths_state_file(const char* name, char* out, size_t out_bytes) {
    char dir[SPDF_WIN_PATH_MAX];
    if (!name || !*name) return 0;
    if (!spdf_win_paths_state_dir(dir, sizeof(dir))) return 0;
    return spdf_win_path_join(dir, name, out, out_bytes);
}
