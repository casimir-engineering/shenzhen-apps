/* spdf_win_updater_net.cpp — one bounded HTTPS GET through WinHTTP.
 *
 * WHY WinHTTP. The GTK port execs curl because glib offers no HTTPS without a
 * new dependency; macOS has NSURLSession. Windows ships WinHTTP in the OS with
 * the system certificate store, proxy settings and TLS policy already applied,
 * and no console window. The SECURITY BOUNDARY IS NOT THE TRANSPORT --
 * nothing is installed unless spdf_win_updater_verify_pinned() says so -- but
 * the transport still refuses plain http, refuses to leave https on a
 * redirect, and refuses to write past the ceiling the caller computed from
 * the (untrusted) declared size. That last one is the 26.8.31-1 clamp doing
 * its job at the point the bytes arrive.
 *
 * SYNCHRONOUS, ON A WORKER THREAD. The UI half calls this from a thread it
 * owns and polls `cancel` between chunks; a 15 s timeout on the feed and 10 min
 * on the asset bound the wait either way.
 */
#include "spdf_win_updater.h"
#include "spdf_win_updater_internal.h"

#include <windows.h>
#include <winhttp.h>

#include <stdio.h>
#include <string.h>

#pragma comment(lib, "winhttp.lib")

static void set_err(spdf_win_fetch_result* out, const char* msg) {
    strncpy_s(out->err, sizeof(out->err), msg, _TRUNCATE);
}

static void set_err_code(spdf_win_fetch_result* out, const char* what, DWORD code) {
    char msg[200];
    snprintf(msg, sizeof(msg), "%s (WinHTTP error %lu)", what, (unsigned long)code);
    set_err(out, msg);
}

int spdf_win_updater_fetch(const char* url, const wchar_t* dest_path, const char* etag_in, int api_request,
                           long long max_bytes, unsigned timeout_ms, volatile long* cancel,
                           spdf_win_fetch_result* out) {
    wchar_t wurl[2048];
    wchar_t host[256];
    wchar_t path[1800];
    URL_COMPONENTS parts;
    HINTERNET session = NULL, connect = NULL, request = NULL;
    HANDLE file = INVALID_HANDLE_VALUE;
    DWORD status = 0, status_len = sizeof(status);
    DWORD flags;
    wchar_t headers[512] = L"";
    wchar_t etag_w[256];
    int ok = 0;

    if (!out) return 0;
    memset(out, 0, sizeof(*out));
    if (!url || !*url) {
        set_err(out, "no URL");
        return 0;
    }
    if (_strnicmp(url, "https://", 8) != 0) {
        set_err(out, "the update server address is not https");
        return 0;
    }
    if (MultiByteToWideChar(CP_UTF8, 0, url, -1, wurl, _countof(wurl)) <= 0) {
        set_err(out, "the update server address could not be parsed");
        return 0;
    }
    memset(&parts, 0, sizeof(parts));
    parts.dwStructSize = sizeof(parts);
    parts.lpszHostName = host;
    parts.dwHostNameLength = _countof(host);
    parts.lpszUrlPath = path;
    parts.dwUrlPathLength = _countof(path);
    if (!WinHttpCrackUrl(wurl, 0, 0, &parts) || parts.nScheme != INTERNET_SCHEME_HTTPS) {
        set_err(out, "the update server address could not be parsed");
        return 0;
    }

    session = WinHttpOpen(L"ShenzhenPDF-Windows-Updater", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME,
                          WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) {
        set_err_code(out, "could not start the HTTP client", GetLastError());
        goto out;
    }
    WinHttpSetTimeouts(session, (int)timeout_ms, (int)timeout_ms, (int)timeout_ms, (int)timeout_ms);
    {
        /* Never leave https on a redirect: GitHub's asset download redirects
         * to a CDN, and that CDN must be https too. */
        DWORD policy = WINHTTP_OPTION_REDIRECT_POLICY_DISALLOW_HTTPS_TO_HTTP;
        WinHttpSetOption(session, WINHTTP_OPTION_REDIRECT_POLICY, &policy, sizeof(policy));
        DWORD protocols = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2 | 0x00002000 /* TLS1_3 */;
        if (!WinHttpSetOption(session, WINHTTP_OPTION_SECURE_PROTOCOLS, &protocols, sizeof(protocols))) {
            protocols = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2;
            WinHttpSetOption(session, WINHTTP_OPTION_SECURE_PROTOCOLS, &protocols, sizeof(protocols));
        }
    }
    connect = WinHttpConnect(session, host, parts.nPort, 0);
    if (!connect) {
        set_err_code(out, "could not reach the update server", GetLastError());
        goto out;
    }
    flags = WINHTTP_FLAG_SECURE;
    request = WinHttpOpenRequest(connect, L"GET", path, NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!request) {
        set_err_code(out, "could not build the request", GetLastError());
        goto out;
    }
    if (api_request) {
        wcscat_s(headers, _countof(headers), L"Accept: application/vnd.github+json\r\nX-GitHub-Api-Version: 2022-11-28\r\n");
    } else {
        wcscat_s(headers, _countof(headers), L"Accept: application/octet-stream\r\n");
    }
    if (etag_in && *etag_in && MultiByteToWideChar(CP_UTF8, 0, etag_in, -1, etag_w, _countof(etag_w)) > 0) {
        wcscat_s(headers, _countof(headers), L"If-None-Match: ");
        wcscat_s(headers, _countof(headers), etag_w);
        wcscat_s(headers, _countof(headers), L"\r\n");
    }
    if (!WinHttpSendRequest(request, headers, (DWORD)-1, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(request, NULL)) {
        DWORD code = GetLastError();
        if (code == ERROR_WINHTTP_TIMEOUT) set_err(out, "the update server did not answer in time");
        else if (code == ERROR_WINHTTP_SECURE_FAILURE) set_err(out, "the update server's certificate was rejected");
        else set_err_code(out, "the update server could not be reached", code);
        goto out;
    }
    if (!WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                             &status, &status_len, WINHTTP_NO_HEADER_INDEX)) {
        set_err(out, "the update server's answer had no status");
        goto out;
    }
    out->status = (int)status;
    {
        wchar_t etag[256];
        DWORD etag_len = sizeof(etag);
        if (WinHttpQueryHeaders(request, WINHTTP_QUERY_ETAG, WINHTTP_HEADER_NAME_BY_INDEX, etag, &etag_len,
                                WINHTTP_NO_HEADER_INDEX))
            WideCharToMultiByte(CP_UTF8, 0, etag, -1, out->etag, sizeof(out->etag), NULL, NULL);
    }
    if (status != 200) {
        ok = 1; /* an answer, just not a body we want (304, 404, 403 ...) */
        goto out;
    }
    {
        /* Reject an announced monster before reading a byte of it. */
        wchar_t clen[32];
        DWORD clen_len = sizeof(clen);
        long long announced = -1;
        if (WinHttpQueryHeaders(request, WINHTTP_QUERY_CONTENT_LENGTH, WINHTTP_HEADER_NAME_BY_INDEX, clen, &clen_len,
                                WINHTTP_NO_HEADER_INDEX))
            announced = _wtoi64(clen);
        if (announced > max_bytes) {
            set_err(out, "the update server announced a file larger than this app will accept");
            goto out;
        }
    }
    if (dest_path) {
        file = CreateFileW(dest_path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (file == INVALID_HANDLE_VALUE) {
            set_err(out, "the download could not be written");
            goto out;
        }
    }
    for (;;) {
        DWORD avail = 0, got = 0, wrote = 0;
        static char buf[64 * 1024];
        if (cancel && *cancel) {
            out->status = -2;
            set_err(out, "cancelled");
            goto out;
        }
        if (!WinHttpQueryDataAvailable(request, &avail)) {
            set_err_code(out, "the download was interrupted", GetLastError());
            goto out;
        }
        if (avail == 0) break;
        if (avail > sizeof(buf)) avail = sizeof(buf);
        if (!WinHttpReadData(request, buf, avail, &got)) {
            set_err_code(out, "the download was interrupted", GetLastError());
            goto out;
        }
        if (got == 0) break;
        out->bytes += got;
        /* THE HARD BOUND: one byte past the ceiling and the download stops,
         * whatever Content-Length said (or did not say). */
        if (out->bytes > max_bytes) {
            set_err(out, "the download grew past the size the release declared; it was discarded");
            goto out;
        }
        if (file != INVALID_HANDLE_VALUE && (!WriteFile(file, buf, got, &wrote, NULL) || wrote != got)) {
            set_err(out, "the download could not be written");
            goto out;
        }
    }
    ok = 1;

out:
    if (file != INVALID_HANDLE_VALUE) {
        CloseHandle(file);
        if (!ok) DeleteFileW(dest_path); /* never leave a partial file behind */
    }
    if (request) WinHttpCloseHandle(request);
    if (connect) WinHttpCloseHandle(connect);
    if (session) WinHttpCloseHandle(session);
    return ok;
}
