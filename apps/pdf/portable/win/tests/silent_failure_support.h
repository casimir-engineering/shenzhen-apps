/* silent_failure_support.h — the harness half of silent_failure_test.c.
 *
 * Split out because the checks themselves and the platform plumbing they need
 * are two different kinds of reading, and because the file-size ratchet is a
 * release gate: extraction, not a cap bump.
 *
 * Everything here is deliberately INDEPENDENT of the modules under test. It
 * still has to be UTF-16-correct on Windows, because the scratch directories
 * carry non-ASCII leaves on purpose and a narrow fopen() in the harness would
 * fail on them under the ANSI code page — turning a passing module into a
 * failing test, which is the very confusion these tests are about.
 *
 * Header-only and included exactly once; there is no second translation unit.
 */
#ifndef SPDF_SILENT_FAILURE_SUPPORT_H
#define SPDF_SILENT_FAILURE_SUPPORT_H

#include "../src/spdf_win_paths.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
/* aclapi.h after windows.h: SetNamedSecurityInfoW/SetEntriesInAclW, used to
 * reproduce a permissions blip on one file. advapi32.lib is already in
 * portable/win/guest-build.cmd's SYS_LIBS. */
#include <aclapi.h>
#else
#include <sys/stat.h>
#include <unistd.h>
#endif

static int g_failures = 0;

static void check(int ok, const char* what) {
    if (!ok) {
        printf("FAIL: %s\n", what);
        g_failures++;
    }
}

static void note(const char* what) { printf("note: %s\n", what); }

/* A file made unreadable to this process, and the state needed to undo it. */
typedef struct {
    int held;
} unreadable_guard;

#if defined(_WIN32)

static int to_wide(const char* utf8, spdf_wchar* out, size_t units) {
    char extended[SPDF_WIN_PATH_MAX];
    if (!spdf_win_path_to_extended(utf8, extended, sizeof(extended))) return 0;
    return spdf_win_utf16_from_utf8(extended, out, units) != SPDF_WIN_CONV_ERROR;
}

static int path_exists(const char* path) {
    spdf_wchar wide[SPDF_WIN_PATH_MAX];
    if (!to_wide(path, wide, SPDF_WIN_PATH_MAX)) return 0;
    return GetFileAttributesW((LPCWSTR)wide) != INVALID_FILE_ATTRIBUTES;
}

static int write_whole(const char* path, const char* text) {
    spdf_wchar wide[SPDF_WIN_PATH_MAX];
    HANDLE h;
    DWORD written = 0;
    DWORD len = (DWORD)strlen(text);
    if (!to_wide(path, wide, SPDF_WIN_PATH_MAX)) return 0;
    h = CreateFileW((LPCWSTR)wide, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                    NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    if (len > 0 && (!WriteFile(h, text, len, &written, NULL) || written != len)) {
        CloseHandle(h);
        return 0;
    }
    CloseHandle(h);
    return 1;
}

static char* read_whole(const char* path) {
    spdf_wchar wide[SPDF_WIN_PATH_MAX];
    HANDLE h;
    LARGE_INTEGER size;
    DWORD got = 0;
    char* data;
    if (!to_wide(path, wide, SPDF_WIN_PATH_MAX)) return NULL;
    h = CreateFileW((LPCWSTR)wide, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return NULL;
    if (!GetFileSizeEx(h, &size) || size.QuadPart > (1 << 20)) {
        CloseHandle(h);
        return NULL;
    }
    data = (char*)malloc((size_t)size.QuadPart + 1);
    if (!data) {
        CloseHandle(h);
        return NULL;
    }
    if (size.QuadPart > 0 &&
        (!ReadFile(h, data, (DWORD)size.QuadPart, &got, NULL) || got != (DWORD)size.QuadPart)) {
        CloseHandle(h);
        free(data);
        return NULL;
    }
    CloseHandle(h);
    data[(size_t)size.QuadPart] = 0;
    return data;
}

static void remove_file(const char* path) {
    spdf_wchar wide[SPDF_WIN_PATH_MAX];
    if (!to_wide(path, wide, SPDF_WIN_PATH_MAX)) return;
    DeleteFileW((LPCWSTR)wide);
}

/* Deny (or restore) FILE_READ_DATA on one file, for Everyone.
 *
 * This is the permissions blip in its smallest honest form. Only the DATA read
 * is denied: attributes, DELETE and the parent directory are all untouched, so
 * a rename over the top still goes through — which is exactly what makes the
 * defect data loss rather than a failed save. Denying the whole of
 * FILE_GENERIC_READ would also block the replace and hide the bug. */
static int set_read_denied(const char* path, int deny) {
    spdf_wchar wide[SPDF_WIN_PATH_MAX];
    SID_IDENTIFIER_AUTHORITY world = {SECURITY_WORLD_SID_AUTHORITY};
    EXPLICIT_ACCESS_W ea[2];
    PSID everyone = NULL;
    PACL acl = NULL;
    int ok = 0;

    /* The ACL APIs take an ordinary path, not an extended-length one. */
    if (spdf_win_utf16_from_utf8(path, wide, SPDF_WIN_PATH_MAX) == SPDF_WIN_CONV_ERROR) return 0;
    if (!deny) {
        /* A NULL DACL grants everyone everything: all a scratch file needs. */
        return SetNamedSecurityInfoW((LPWSTR)wide, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, NULL,
                                     NULL, NULL, NULL) == ERROR_SUCCESS;
    }
    if (!AllocateAndInitializeSid(&world, 1, SECURITY_WORLD_RID, 0, 0, 0, 0, 0, 0, 0, &everyone))
        return 0;
    memset(ea, 0, sizeof(ea));
    ea[0].grfAccessPermissions = FILE_READ_DATA;
    ea[0].grfAccessMode = DENY_ACCESS;
    ea[0].grfInheritance = NO_INHERITANCE;
    ea[0].Trustee.TrusteeForm = TRUSTEE_IS_SID;
    ea[0].Trustee.TrusteeType = TRUSTEE_IS_WELL_KNOWN_GROUP;
    ea[0].Trustee.ptstrName = (LPWSTR)everyone;
    ea[1] = ea[0];
    ea[1].grfAccessPermissions = FILE_ALL_ACCESS;
    ea[1].grfAccessMode = SET_ACCESS;
    /* SetEntriesInAclW orders the deny ACE ahead of the allow ACE for us. */
    if (SetEntriesInAclW(2, ea, NULL, &acl) == ERROR_SUCCESS)
        ok = SetNamedSecurityInfoW((LPWSTR)wide, SE_FILE_OBJECT,
                                   DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                                   NULL, NULL, acl, NULL) == ERROR_SUCCESS;
    if (acl) LocalFree(acl);
    FreeSid(everyone);
    return ok;
}

#else /* POSIX */

static int native_of(const char* path, char* out, size_t out_bytes) {
    return spdf_win_path_to_native(path, out, out_bytes);
}

static int path_exists(const char* path) {
    char native[SPDF_WIN_PATH_MAX];
    struct stat st;
    if (!native_of(path, native, sizeof(native))) return 0;
    return stat(native, &st) == 0;
}

static int write_whole(const char* path, const char* text) {
    char native[SPDF_WIN_PATH_MAX];
    FILE* f;
    size_t len = strlen(text);
    if (!native_of(path, native, sizeof(native))) return 0;
    f = fopen(native, "wb");
    if (!f) return 0;
    if (len && fwrite(text, 1, len, f) != len) {
        fclose(f);
        return 0;
    }
    return fclose(f) == 0;
}

static char* read_whole(const char* path) {
    char native[SPDF_WIN_PATH_MAX];
    FILE* f;
    char* data;
    long size;
    size_t got;
    if (!native_of(path, native, sizeof(native))) return NULL;
    f = fopen(native, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0 || (size = ftell(f)) < 0 || fseek(f, 0, SEEK_SET) != 0) {
        fclose(f);
        return NULL;
    }
    data = (char*)malloc((size_t)size + 1);
    if (!data) {
        fclose(f);
        return NULL;
    }
    got = fread(data, 1, (size_t)size, f);
    fclose(f);
    data[got] = 0;
    return data;
}

static void remove_file(const char* path) {
    char native[SPDF_WIN_PATH_MAX];
    if (!native_of(path, native, sizeof(native))) return;
    remove(native);
}

/* The POSIX shape of the same accident: the file loses its mode bits while the
 * directory stays writable, so the read fails and the rename does not. */
static int set_read_denied(const char* path, int deny) {
    char native[SPDF_WIN_PATH_MAX];
    if (!native_of(path, native, sizeof(native))) return 0;
    return chmod(native, deny ? 0 : 0600) == 0;
}

#endif

/* Make `path` unreadable to this process, and PROVE it: the guard verifies with
 * its own read. Returns 0 when the environment refuses to deny anything —
 * running as root, an exotic filesystem — so a skip can never be mistaken for a
 * pass. */
static int make_unreadable(const char* path, unreadable_guard* guard) {
    char* proof;
    guard->held = 0;
    if (!set_read_denied(path, 1)) return 0;
    proof = read_whole(path);
    if (proof) {
        free(proof);
        set_read_denied(path, 0);
        return 0;
    }
    guard->held = 1;
    return 1;
}

static void make_readable(const char* path, unreadable_guard* guard) {
    if (!guard->held) return;
    set_read_denied(path, 0);
    guard->held = 0;
}

#endif /* SPDF_SILENT_FAILURE_SUPPORT_H */
