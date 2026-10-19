/* spdf_win_md_images.cpp -- see spdf_win_md_images.h. */
#include "spdf_win_md_images.h"

#include "spdf_win_md_webp.h"
#include "spdf_win_paths.h"

#include <shlobj.h>
#include <winhttp.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "winhttp.lib")

namespace {

CRITICAL_SECTION g_lock;
LONG g_lock_ready = 0;
char g_dir_override[1024];
char g_dir[1024];

/* The pending list: distinct URLs, newest last. Small by nature (a README has
 * tens of badges), so a flat array is the right size of machinery. */
char** g_pending = NULL;
int g_pending_count = 0;
int g_pending_cap = 0;
volatile LONG g_fetching = 0;
HWND g_notify;
UINT g_message;

void lock() {
    if (InterlockedCompareExchange(&g_lock_ready, 1, 0) == 0) InitializeCriticalSection(&g_lock);
    while (g_lock_ready != 2 && g_lock_ready != 1) Sleep(0);
    EnterCriticalSection(&g_lock);
}

void unlock() {
    LeaveCriticalSection(&g_lock);
}

int is_https(const char* url) {
    return url && _strnicmp(url, "https://", 8) == 0 && url[8];
}

int file_exists_utf8(const char* path) {
    wchar_t wide[2048];
    if (!spdf_win_utf16_from_utf8(path, wide, sizeof(wide) / sizeof(wide[0]))) return 0;
    DWORD attrs = GetFileAttributesW(wide);
    return attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY);
}

int default_cache_dir(char* out, size_t cap) {
    PWSTR local = NULL;
    char base[1024];
    int ok = 0;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, NULL, &local))) return 0;
    if (spdf_win_utf8_from_utf16(local, base, sizeof(base)) != SPDF_WIN_CONV_ERROR) {
        char app[1024];
        ok = spdf_win_path_join(base, SPDF_WIN_APP_DIR_NAME, app, sizeof(app)) &&
             spdf_win_path_join(app, "markdown-images", out, cap);
    }
    CoTaskMemFree(local);
    return ok;
}

void remember_pending(const char* url) {
    int i;
    for (i = 0; i < g_pending_count; ++i)
        if (strcmp(g_pending[i], url) == 0) return;
    if (g_pending_count == g_pending_cap) {
        int cap = g_pending_cap ? g_pending_cap * 2 : 16;
        char** grown = (char**)realloc(g_pending, (size_t)cap * sizeof(char*));
        if (!grown) return;
        g_pending = grown;
        g_pending_cap = cap;
    }
    g_pending[g_pending_count] = _strdup(url);
    if (g_pending[g_pending_count]) ++g_pending_count;
}

/* Read the whole response body, bounded. Returns bytes read or -1. */
long read_body(HINTERNET request, unsigned char** out) {
    unsigned char* buf = NULL;
    size_t len = 0, cap = 0;
    for (;;) {
        DWORD avail = 0, got = 0;
        if (!WinHttpQueryDataAvailable(request, &avail)) {
            free(buf);
            return -1;
        }
        if (avail == 0) break;
        if (len + avail > SPDF_WIN_MD_IMAGES_MAX_BYTES) {
            free(buf);
            return -1;
        }
        if (len + avail > cap) {
            size_t grow = cap ? cap * 2 : 65536;
            unsigned char* g;
            while (grow < len + avail) grow *= 2;
            g = (unsigned char*)realloc(buf, grow);
            if (!g) {
                free(buf);
                return -1;
            }
            buf = g;
            cap = grow;
        }
        if (!WinHttpReadData(request, buf + len, avail, &got)) {
            free(buf);
            return -1;
        }
        len += got;
    }
    *out = buf;
    return (long)len;
}

int write_atomically(const char* dir, const char* name, const unsigned char* data, size_t len) {
    char final_utf8[2048], temp_utf8[2048];
    wchar_t final_w[2048], temp_w[2048];
    HANDLE h;
    DWORD written = 0;
    int ok;
    if (!spdf_win_path_join(dir, name, final_utf8, sizeof(final_utf8))) return 0;
    snprintf(temp_utf8, sizeof(temp_utf8), "%s.%lu.part", final_utf8, (unsigned long)GetCurrentThreadId());
    if (!spdf_win_utf16_from_utf8(final_utf8, final_w, 2048) || !spdf_win_utf16_from_utf8(temp_utf8, temp_w, 2048))
        return 0;
    h = CreateFileW(temp_w, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    ok = WriteFile(h, data, (DWORD)len, &written, NULL) && written == len;
    CloseHandle(h);
    if (ok) ok = MoveFileExW(temp_w, final_w, MOVEFILE_REPLACE_EXISTING) != 0;
    if (!ok) DeleteFileW(temp_w);
    return ok;
}

DWORD WINAPI fetch_thread(LPVOID) {
    int arrived = 0;
    for (;;) {
        char* url = NULL;
        lock();
        if (g_pending_count > 0) url = g_pending[--g_pending_count];
        unlock();
        if (!url) break;
        if (spdf_win_md_images_fetch_one(url)) ++arrived;
        free(url);
    }
    InterlockedExchange(&g_fetching, 0);
    if (arrived && g_notify) PostMessageW(g_notify, g_message, (WPARAM)arrived, 0);
    return 0;
}

} // namespace

/* --- directory ------------------------------------------------------------------ */

void spdf_win_md_images_set_dir_override(const char* dir) {
    lock();
    if (dir) snprintf(g_dir_override, sizeof(g_dir_override), "%s", dir);
    else g_dir_override[0] = '\0';
    g_dir[0] = '\0';
    unlock();
}

int spdf_win_md_images_dir(char* out, size_t cap) {
    int ok = 1;
    lock();
    if (!g_dir[0]) {
        if (g_dir_override[0]) snprintf(g_dir, sizeof(g_dir), "%s", g_dir_override);
        else if (!default_cache_dir(g_dir, sizeof(g_dir))) g_dir[0] = '\0';
        if (g_dir[0] && !spdf_win_paths_ensure_dir(g_dir)) g_dir[0] = '\0';
    }
    if (!g_dir[0] || strlen(g_dir) >= cap) ok = 0;
    else strcpy(out, g_dir);
    unlock();
    return ok;
}

/* --- naming ----------------------------------------------------------------------- */

void spdf_win_md_images_cache_name(const char* url, char* out, size_t cap) {
    unsigned long long h = 1469598103934665603ULL;
    const char* p;
    const char* path_end;
    const char* dot = NULL;
    char ext[8] = ".img";

    for (p = url; *p; ++p) {
        h ^= (unsigned char)*p;
        h *= 1099511628211ULL;
    }
    /* The extension of the path part: the last '.' after the last '/', with
     * 1-5 alphanumerics, before any '?' or '#'. */
    path_end = url;
    while (*path_end && *path_end != '?' && *path_end != '#') ++path_end;
    for (p = url; p < path_end; ++p) {
        if (*p == '/') dot = NULL;
        else if (*p == '.') dot = p;
    }
    if (dot && path_end - dot >= 2 && path_end - dot <= 6) {
        size_t i;
        int ok = 1;
        for (i = 1; i < (size_t)(path_end - dot); ++i)
            if (!isalnum((unsigned char)dot[i])) ok = 0;
        if (ok) {
            for (i = 0; i < (size_t)(path_end - dot); ++i) ext[i] = (char)tolower((unsigned char)dot[i]);
            ext[path_end - dot] = '\0';
        }
    }
    snprintf(out, cap, "%016llx%s", h, ext);
}

/* --- lookup and the pending list --------------------------------------------------- */

int spdf_win_md_images_lookup(void* user, const char* url, char* name_out, size_t cap) {
    char dir[1024], path[2048], name[64];
    (void)user;
    if (!is_https(url)) return 0;
    spdf_win_md_images_cache_name(url, name, sizeof(name));
    if (strlen(name) >= cap) return 0;
    if (spdf_win_md_images_dir(dir, sizeof(dir)) && spdf_win_path_join(dir, name, path, sizeof(path)) &&
        file_exists_utf8(path)) {
        /* A downloaded WebP is a file MuPDF cannot decode, whatever the URL
         * called it. Hand back the transcoded PNG beside it instead; a failure
         * (no WIC codec) falls through to the original name and the "[image]"
         * placeholder, which is what an older Windows has always shown. */
        char png[64];
        if (spdf_win_md_webp_lookup(NULL, path, png, sizeof(png)) && strlen(png) < cap) {
            strcpy(name_out, png);
            return 1;
        }
        strcpy(name_out, name);
        return 1;
    }
    lock();
    remember_pending(url);
    unlock();
    return 0;
}

int spdf_win_md_images_pending_count(void) {
    int n;
    lock();
    n = g_pending_count;
    unlock();
    return n;
}

void spdf_win_md_images_clear_pending(void) {
    lock();
    while (g_pending_count > 0) free(g_pending[--g_pending_count]);
    unlock();
}

/* --- fetching --------------------------------------------------------------------- */

int spdf_win_md_images_fetch_one(const char* url) {
    wchar_t wide[2048], host[256], path[2048];
    URL_COMPONENTS parts;
    HINTERNET session = NULL, connection = NULL, request = NULL;
    DWORD status = 0, size;
    wchar_t content_type[64];
    unsigned char* body = NULL;
    long len = -1;
    char dir[1024], name[64];
    int ok = 0;

    if (!is_https(url) || !spdf_win_md_images_dir(dir, sizeof(dir))) return 0;
    if (!spdf_win_utf16_from_utf8(url, wide, 2048)) return 0;
    memset(&parts, 0, sizeof(parts));
    parts.dwStructSize = sizeof(parts);
    parts.lpszHostName = host;
    parts.dwHostNameLength = 256;
    parts.lpszUrlPath = path;
    parts.dwUrlPathLength = 2048;
    if (!WinHttpCrackUrl(wide, 0, 0, &parts) || parts.nScheme != INTERNET_SCHEME_HTTPS) return 0;

    session = WinHttpOpen(L"ShenzhenPDF Markdown/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME,
                          WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) return 0;
    WinHttpSetTimeouts(session, SPDF_WIN_MD_IMAGES_TIMEOUT_MS, SPDF_WIN_MD_IMAGES_TIMEOUT_MS,
                       SPDF_WIN_MD_IMAGES_TIMEOUT_MS, SPDF_WIN_MD_IMAGES_TIMEOUT_MS);
    connection = WinHttpConnect(session, host, parts.nPort, 0);
    if (connection) {
        /* The path includes the query when WinHttpCrackUrl is given a length of
         * 0 for lpszExtraInfo -- it is appended to lpszUrlPath. */
        request = WinHttpOpenRequest(connection, L"GET", path, NULL, WINHTTP_NO_REFERER,
                                     WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
    }
    if (request && WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
        WinHttpReceiveResponse(request, NULL)) {
        size = sizeof(status);
        WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                            &status, &size, WINHTTP_NO_HEADER_INDEX);
        size = sizeof(content_type);
        content_type[0] = 0;
        WinHttpQueryHeaders(request, WINHTTP_QUERY_CONTENT_TYPE, WINHTTP_HEADER_NAME_BY_INDEX, content_type, &size,
                            WINHTTP_NO_HEADER_INDEX);
        if (status == 200 && _wcsnicmp(content_type, L"image/", 6) == 0) len = read_body(request, &body);
    }
    if (request) WinHttpCloseHandle(request);
    if (connection) WinHttpCloseHandle(connection);
    WinHttpCloseHandle(session);

    if (len > 0) {
        spdf_win_md_images_cache_name(url, name, sizeof(name));
        ok = write_atomically(dir, name, body, (size_t)len);
    }
    free(body);
    return ok;
}

int spdf_win_md_images_fetching(void) {
    return g_fetching != 0;
}

int spdf_win_md_images_fetch_pending(HWND notify, UINT message) {
    HANDLE thread;
    if (spdf_win_md_images_pending_count() == 0) return 0;
    if (InterlockedCompareExchange(&g_fetching, 1, 0) != 0) return 0;
    g_notify = notify;
    g_message = message;
    thread = CreateThread(NULL, 0, fetch_thread, NULL, 0, NULL);
    if (!thread) {
        InterlockedExchange(&g_fetching, 0);
        return 0;
    }
    CloseHandle(thread);
    return 1;
}
