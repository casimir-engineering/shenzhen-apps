/* Shenzhen Friends client library: status names, the state directory, the socket path and its directory check.
 *
 * The helper and every client call these same functions, so the socket path and the directory rule exist once
 * (PROTOCOL.md § Transport). Pure libc. */

#define _DARWIN_C_SOURCE 1 /* confstr(_CS_DARWIN_USER_TEMP_DIR), getpwuid_r */

#include "client/szfriends_client.h"

#include <errno.h>
#include <limits.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

const char *szfriends_status_name(szfriends_status status) {
    switch (status) {
    case SZFRIENDS_OK: return "ok";
    case SZFRIENDS_ERR_INVALID_ARGUMENT: return "invalid_argument";
    case SZFRIENDS_ERR_PATH_TOO_LONG: return "path_too_long";
    case SZFRIENDS_ERR_UNSAFE_DIRECTORY: return "unsafe_directory";
    case SZFRIENDS_ERR_NO_HELPER: return "no_helper";
    case SZFRIENDS_ERR_PEER_UID: return "peer_uid";
    case SZFRIENDS_ERR_PROTOCOL: return "protocol";
    case SZFRIENDS_ERR_FRAME_TOO_LARGE: return "frame_too_large";
    case SZFRIENDS_ERR_VERSION: return "version";
    case SZFRIENDS_ERR_NOT_READY: return "not_ready";
    case SZFRIENDS_ERR_CLOSED: return "closed";
    case SZFRIENDS_ERR_IO: return "io";
    case SZFRIENDS_ERR_NO_MEMORY: return "no_memory";
    case SZFRIENDS_ERR_PEER_SIGNATURE: return "peer_signature";
    }
    return "unknown";
}

static szfriends_status copy_string(char *out, size_t out_cap, const char *value) {
    size_t length = strlen(value);
    if (length + 1 > out_cap) return SZFRIENDS_ERR_PATH_TOO_LONG;
    memcpy(out, value, length + 1);
    return SZFRIENDS_OK;
}

szfriends_status szfriends_default_state_dir(char *out, size_t out_cap) {
    const char *override;
    const char *home;
    char buffer[4096];
    struct passwd entry;
    struct passwd *found = NULL;
    int written;

    if (!out || out_cap == 0) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    override = getenv(SZFRIENDS_ENV_STATE_DIR);
    /* A relative override is ignored rather than resolved against the cwd: every process that hosts Friends
     * would then derive a different socket path from the same variable. A team-signed app ignores it entirely
     * (szfriends_set_signing_policy()), as its helper does. */
    if (override && override[0] == '/' && szfriends_environment_overrides_allowed())
        return copy_string(out, out_cap, override);
    home = getenv("HOME");
    if (!home || home[0] != '/') {
        if (getpwuid_r(getuid(), &entry, buffer, sizeof buffer, &found) != 0 || !found || !found->pw_dir)
            return SZFRIENDS_ERR_IO;
        home = found->pw_dir;
    }
    written = snprintf(out, out_cap, "%s/Library/Application Support/Shenzhen Friends", home);
    if (written < 0) return SZFRIENDS_ERR_IO;
    if ((size_t)written >= out_cap) return SZFRIENDS_ERR_PATH_TOO_LONG;
    return SZFRIENDS_OK;
}

uint64_t szfriends_fnv1a64(const void *bytes, size_t length) {
    const unsigned char *p = (const unsigned char *)bytes;
    uint64_t hash = UINT64_C(0xcbf29ce484222325);
    size_t i;
    for (i = 0; i < length; i++) {
        hash ^= p[i];
        hash *= UINT64_C(0x100000001b3);
    }
    return hash;
}

/* PROTOCOL.md § Transport, canonical form: realpath() of the deepest existing ancestor, then the missing
 * components appended verbatim. "." and ".." in the missing part are refused because they cannot be resolved
 * without the directories existing, and helper and client would disagree about them. */
static szfriends_status canonical_state_dir(const char *state_dir, char *out, size_t out_cap) {
    char work[SZFRIENDS_PATH_CAP];
    char prefix[SZFRIENDS_PATH_CAP];
    char resolved[PATH_MAX];
    size_t length, prefix_length;
    const char *missing;

    if (!state_dir || state_dir[0] != '/') return SZFRIENDS_ERR_INVALID_ARGUMENT;
    length = strlen(state_dir);
    if (length >= sizeof work) return SZFRIENDS_ERR_PATH_TOO_LONG;
    memcpy(work, state_dir, length + 1);
    while (length > 1 && work[length - 1] == '/') work[--length] = '\0';

    /* work[0..prefix_length) is the ancestor being tried; work[prefix_length..] does not exist yet. */
    prefix_length = length;
    for (;;) {
        size_t i;
        memcpy(prefix, work, prefix_length);
        prefix[prefix_length] = '\0';
        if (realpath(prefix, resolved)) break;
        if (errno != ENOENT) return SZFRIENDS_ERR_IO;
        i = prefix_length;
        while (i > 0 && work[i - 1] != '/') i--;
        if (i == 0) return SZFRIENDS_ERR_IO; /* not absolute; unreachable after the check above */
        /* i - 1 is the slash before the last component; keep "/" itself when that is the root. */
        prefix_length = i - 1 == 0 ? 1 : i - 1;
    }

    missing = work + prefix_length;
    while (*missing == '/') missing++;
    {
        /* Refuse dot components in the part that does not exist yet. */
        const char *p = missing;
        while (*p) {
            const char *end = strchr(p, '/');
            size_t n = end ? (size_t)(end - p) : strlen(p);
            if ((n == 1 && p[0] == '.') || (n == 2 && p[0] == '.' && p[1] == '.'))
                return SZFRIENDS_ERR_INVALID_ARGUMENT;
            p += n;
            while (*p == '/') p++;
        }
    }
    if (*missing == '\0') return copy_string(out, out_cap, resolved);
    {
        int written = snprintf(out, out_cap, "%s%s%s", resolved, strcmp(resolved, "/") == 0 ? "" : "/", missing);
        if (written < 0) return SZFRIENDS_ERR_IO;
        if ((size_t)written >= out_cap) return SZFRIENDS_ERR_PATH_TOO_LONG;
    }
    /* Collapse doubled slashes the caller may have written inside the missing part ("a//b"). */
    {
        char *read = out, *write = out;
        while (*read) {
            *write = *read;
            if (!(*read == '/' && write > out && *(write - 1) == '/')) write++;
            read++;
        }
        *write = '\0';
    }
    return SZFRIENDS_OK;
}

static szfriends_status user_temp_dir(char *out, size_t out_cap) {
#if defined(__APPLE__)
    size_t needed = confstr(_CS_DARWIN_USER_TEMP_DIR, out, out_cap);
    if (needed == 0) return SZFRIENDS_ERR_IO;
    if (needed > out_cap) return SZFRIENDS_ERR_PATH_TOO_LONG;
    return SZFRIENDS_OK;
#else
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    return copy_string(out, out_cap, runtime && runtime[0] == '/' ? runtime : "/tmp");
#endif
}

szfriends_status szfriends_socket_path(const char *state_dir, char *out, size_t out_cap, bool *used_fallback) {
    char canonical[SZFRIENDS_PATH_CAP];
    char temp[SZFRIENDS_PATH_CAP];
    char candidate[SZFRIENDS_PATH_CAP + 64];
    szfriends_status status;
    int written;
    size_t temp_length;

    if (!out || out_cap == 0) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    if (used_fallback) *used_fallback = false;
    status = canonical_state_dir(state_dir, canonical, sizeof canonical);
    if (status != SZFRIENDS_OK) return status;

    written = snprintf(candidate, sizeof candidate, "%s/ipc/helper.sock", canonical);
    if (written > 0 && (size_t)written < SZFRIENDS_SUN_PATH_MAX) return copy_string(out, out_cap, candidate);

    status = user_temp_dir(temp, sizeof temp);
    if (status != SZFRIENDS_OK) return status;
    temp_length = strlen(temp);
    written = snprintf(candidate, sizeof candidate, "%s%sszfriends-%016llx/helper.sock", temp,
                       temp_length > 0 && temp[temp_length - 1] == '/' ? "" : "/",
                       (unsigned long long)szfriends_fnv1a64(canonical, strlen(canonical)));
    if (written < 0) return SZFRIENDS_ERR_IO;
    if ((size_t)written >= SZFRIENDS_SUN_PATH_MAX) return SZFRIENDS_ERR_PATH_TOO_LONG;
    if (used_fallback) *used_fallback = true;
    return copy_string(out, out_cap, candidate);
}

/* mkdir -p with 0700 for every directory it creates. Existing ancestors are left alone. */
static int make_directories(char *path) {
    char *p;
    for (p = path + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0';
        if (mkdir(path, 0700) != 0 && errno != EEXIST) {
            *p = '/';
            return -1;
        }
        *p = '/';
    }
    if (mkdir(path, 0700) != 0 && errno != EEXIST) return -1;
    return 0;
}

szfriends_status szfriends_socket_directory_check(const char *socket_path, bool create) {
    char directory[SZFRIENDS_PATH_CAP];
    char *slash;
    struct stat info;
    size_t length;

    if (!socket_path || socket_path[0] != '/') return SZFRIENDS_ERR_INVALID_ARGUMENT;
    length = strlen(socket_path);
    if (length >= sizeof directory) return SZFRIENDS_ERR_PATH_TOO_LONG;
    memcpy(directory, socket_path, length + 1);
    slash = strrchr(directory, '/');
    if (!slash || slash == directory) return SZFRIENDS_ERR_INVALID_ARGUMENT; /* never the root directory */
    *slash = '\0';

    if (create && make_directories(directory) != 0) return SZFRIENDS_ERR_IO;
    if (lstat(directory, &info) != 0) {
        if (errno == ENOENT && !create) return SZFRIENDS_ERR_NO_HELPER;
        return SZFRIENDS_ERR_IO;
    }
    if (!S_ISDIR(info.st_mode)) return SZFRIENDS_ERR_UNSAFE_DIRECTORY; /* includes a symlink, via lstat */
    if (info.st_uid != geteuid()) return SZFRIENDS_ERR_UNSAFE_DIRECTORY;
    if ((info.st_mode & 077) != 0) return SZFRIENDS_ERR_UNSAFE_DIRECTORY;
    return SZFRIENDS_OK;
}
