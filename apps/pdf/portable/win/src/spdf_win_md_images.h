/* spdf_win_md_images.h -- the shared disk cache for a Markdown document's
 * https images, and the WinHTTP fetch that fills it.
 *
 * THE CONTRACT WITH THE CORE. The converter never opens a connection. While a
 * document is being opened it asks, per https image, "is this URL cached, and
 * under what file name?" (spdf_markdown_image_hook). This module answers from
 * the cache DIRECTORY only -- a stat, never a socket -- so opening a README
 * with forty badges costs forty stats, is deterministic, and works offline.
 * Every miss is remembered. After the open, the frontend calls
 * spdf_win_md_images_fetch_pending(); the downloads run on one background
 * thread, land in the cache, and a single window message says "something
 * arrived", at which point the frontend re-shows the tab, the converter finds
 * the files, and the placeholders become pictures. That is the Mac's
 * lazy-load-then-rerender shape (markdown/README.md, "Remote images") with
 * the rerender being a reopen.
 *
 * WHAT IS FETCHED, AND HOW FAR IT CAN GO. https only (an http image is a
 * placeholder for good); WinHTTP's default redirect policy, which already
 * refuses https -> http; 20 seconds per request; 20 MB per image; the
 * response must declare an image/* content type. Bytes go to a temporary
 * file and are moved into place, so a half-written file is never served.
 * The cache is %LocalAppData%\ShenzhenPDF\markdown-images -- the Windows
 * counterpart of ~/Library/Caches/ShenzhenPDF/markdown-images -- and the file
 * name is a 64-bit FNV-1a hash of the URL plus the URL's own extension, kept
 * because MuPDF decides "this is SVG" from the source's ".svg" and sniffs
 * everything else from the bytes.
 *
 * NEVER FETCHED IN A TEST. run-tests-native.sh must not touch the network;
 * md_win_test.c exercises the naming, the lookup and the miss list against a
 * scratch directory through spdf_win_md_images_set_dir_override(), and leaves
 * the fetch itself to a human with a network.
 */
#ifndef SPDF_WIN_MD_IMAGES_H
#define SPDF_WIN_MD_IMAGES_H

#include <windows.h>

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SPDF_WIN_MD_IMAGES_MAX_BYTES (20u * 1024u * 1024u)
#define SPDF_WIN_MD_IMAGES_TIMEOUT_MS 20000

/* The cache directory (UTF-8), created on first use. 0 when it cannot be
 * resolved or created -- the caller then opens without remote images. */
int spdf_win_md_images_dir(char* out, size_t cap);
/* Tests: use this directory instead of %LocalAppData%; NULL restores. */
void spdf_win_md_images_set_dir_override(const char* dir);

/* Pure: the cache file name for a URL -- 16 hex digits of FNV-1a 64 plus the
 * URL path's extension (".svg", ".png", ...; ".img" when it has none or an
 * implausible one). Deterministic, no I/O. */
void spdf_win_md_images_cache_name(const char* url, char* out, size_t cap);

/* The core hook (spdf_markdown_image_hook). Answers 1 with the cache file name
 * when the file exists, else records the URL as pending and answers 0. Only
 * https URLs are ever recorded. Thread-safe: opens run on several threads. */
int spdf_win_md_images_lookup(void* user, const char* url, char* name_out, size_t cap);

/* How many distinct URLs have been asked for and not found since the last
 * fetch. */
int spdf_win_md_images_pending_count(void);
/* Forget the pending list (a test hook; the fetch drains it itself). */
void spdf_win_md_images_clear_pending(void);

/* Download every pending URL on a background thread. When at least one file
 * landed, PostMessage(notify, message, arrived_count, 0) once at the end.
 * Returns 1 when a fetch was started, 0 when nothing was pending or a fetch is
 * already running (its completion message covers the new misses too, since
 * they are drained at the end of the run). */
int spdf_win_md_images_fetch_pending(HWND notify, UINT message);
/* 1 while a background fetch is running. */
int spdf_win_md_images_fetching(void);

/* Fetch ONE https URL synchronously into the cache (the worker's unit of
 * work, exposed for a manual check with a network). Returns 1 on success. */
int spdf_win_md_images_fetch_one(const char* url);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_MD_IMAGES_H */
