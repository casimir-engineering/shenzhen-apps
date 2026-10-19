/* spdf_win_updater_internal.h — what the updater's Win32 translation units
 * share with each other and with nobody else: the HTTPS fetch, the file
 * helpers, the clock and the self path.
 *
 * Not part of spdf_win_updater.h because none of it is a decision worth
 * pinning in a test on its own terms: fetch() is WinHTTP, read/write are
 * CreateFileW, now() is GetSystemTimeAsFileTime. The install and verify tests
 * reach the two file helpers through this header for their fixtures, which is
 * the one legitimate reason it is a header at all. */
#ifndef SPDF_WIN_UPDATER_INTERNAL_H
#define SPDF_WIN_UPDATER_INTERNAL_H

#include <stddef.h>

#include "spdf_win_updater.h" /* spdf_win_release_info, the store mutator type */

#ifdef __cplusplus
extern "C" {
#endif

/* Read a whole file. `*out` is malloc'd and NUL-terminated (so text can be
 * handed to the parsers as-is), `*out_len` its byte length. A file over
 * `max_bytes` is refused rather than truncated: a truncated store or feed
 * would parse as a different document. */
int spdf_win_updater_read_file(const wchar_t* path, char** out, size_t* out_len, size_t max_bytes);
/* Write atomically: to "<path>.tmp" then MoveFileExW(REPLACE_EXISTING), so a
 * crash mid-write leaves the previous file rather than half of a new one. */
int spdf_win_updater_write_file(const wchar_t* path, const char* data, size_t len);

/* Seconds since 1970-01-01 UTC, from the system clock. */
long long spdf_win_updater_now_epoch(void);
/* Path of the running executable. */
int spdf_win_updater_self_exe(wchar_t* out, size_t out_len);

/* One HTTPS GET to a file. HTTPS ONLY: an http:// URL fails before any socket
 * opens, and WinHTTP is told not to follow a redirect off https either.
 *
 *   etag_in      sent as If-None-Match when non-empty (the silent daily path)
 *   api_request  adds the GitHub API Accept header
 *   max_bytes    the HARD ceiling on bytes written (spdf_win_updater_download_
 *                ceiling(declared) for an asset, MAX_FEED_BYTES for the feed)
 *   cancel       polled between chunks; non-zero aborts with status -2
 *
 * Returns 1 when an HTTP response was obtained (status in out->status, 200 or
 * 304 or anything else), 0 on a transport failure with out->err filled. The
 * body is written only for 200; a 304 leaves no file. */
typedef struct spdf_win_fetch_result {
    int status;
    char etag[256]; /* the response ETag, or "" */
    char err[256];
    long long bytes;
} spdf_win_fetch_result;

int spdf_win_updater_fetch(const char* url, const wchar_t* dest_path, const char* etag_in, int api_request,
                           long long max_bytes, unsigned timeout_ms, volatile long* cancel,
                           spdf_win_fetch_result* out);

/* --- the worker half (spdf_win_updater_work.cpp) --------------------------
 *
 * The check and the install run on threads that touch no window. Each takes
 * one heap-allocated outcome, fills it, and PostMessageW()s it to `sink` (the
 * UI's message-only HWND) as the message below with the outcome in lParam;
 * the UI thread frees it. Split from spdf_win_updater_ui.cpp so each file
 * stays under the repo's 500-line cap and so the thread bodies have no
 * globals: everything they need rides in the outcome. */

#define SPDF_WIN_UPDATER_MSG_CHECK_DONE (0x8000 + 0x51)   /* WM_APP + 0x51 */
#define SPDF_WIN_UPDATER_MSG_INSTALL_DONE (0x8000 + 0x52) /* WM_APP + 0x52 */

typedef struct spdf_win_check_outcome {
    void* sink;            /* HWND to post the result to */
    volatile long* cancel; /* polled by the fetch */
    int user_initiated;    /* Check for Updates... : no ETag, no snooze, no skip */
    int ok;                /* an HTTP outcome was obtained and parsed */
    int not_modified;      /* 304 */
    int available;
    int newer_but_missing_asset;
    spdf_win_release_info release;
    char err[256];
} spdf_win_check_outcome;

typedef struct spdf_win_install_outcome {
    void* sink;
    volatile long* cancel;
    wchar_t self_exe[260];         /* the running binary, to stage beside and swap */
    spdf_win_release_info release; /* a deep copy; cleared by the UI with the outcome */
    int ok;
    char err[512];
} spdf_win_install_outcome;

unsigned long __stdcall spdf_win_updater_check_thread(void* outcome);
unsigned long __stdcall spdf_win_updater_install_thread(void* outcome);

/* The running identity, SPDF_WIN_RELEASE_TAG. */
const char* spdf_win_updater_running_version(void);
/* settings.yaml's autoUpdateEnabled, then the 24-hour gate under the store
 * lock, stamping the slot when it opens. 1 when a silent check should run. */
int spdf_win_updater_claim_daily_slot(void);
/* "Later": deferredTag = tag, remindAfter = now + 7 days. */
void spdf_win_updater_snooze(const char* tag);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_UPDATER_INTERNAL_H */
