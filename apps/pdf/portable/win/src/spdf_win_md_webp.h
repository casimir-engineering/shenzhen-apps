/* spdf_win_md_webp.h -- WebP for the Markdown reader, through WIC.
 *
 * WHY THIS FILE EXISTS. MuPDF 1.27 has no WebP decoder: mupdf/source/fitz holds
 * load-png.c, load-jpeg.c, load-gif.c, load-bmp.c, load-tiff.c, load-jpx.c,
 * load-psd.c, load-pnm.c, load-jbig2.c and load-jxr.c, and no load-webp.c. So a
 * `![](shot.webp)` reaches load_html_image(), fails to decode, and MuPDF draws
 * its own placeholder word -- html-parse.c:714 literally adds the text
 * "[image]". This repository's own readme.md is the case in point: its four
 * screenshots are WebP.
 *
 * THE ROUTE. Windows can already read WebP: WIC gained the "Microsoft Webp
 * Decoder" in Windows 10 1809. So the frontend decodes the file through WIC and
 * writes a PNG into the SAME cache directory the remote-image fetch fills, then
 * answers the converter's local-image hook with that file name. The converter
 * rewrites the source to ".spdf-remote/<name>", which is a directory MuPDF has
 * already mounted (spdf_markdown_open.c), and the picture appears with no core
 * knowledge of WebP at all. A transcoded file is a PNG by content, so search,
 * selection, print, export and the dark rendition are unaffected.
 *
 * IF THE CODEC IS ABSENT the transcode fails, the hook answers 0, the converter
 * leaves the original relative source in place and the reader sees exactly
 * today's "[image]". That is the whole degradation story: no error dialog, no
 * missing page, no retry loop.
 *
 * WHERE THE FILES GO, AND WHEN THEY ARE STALE. The cache is
 * spdf_win_md_images_dir() -- %LocalAppData%\ShenzhenPDF\markdown-images -- and
 * the name is a 64-bit FNV-1a hash of the source's absolute path, its byte size
 * and its last-write time, plus ".png". Editing the .webp changes the size or
 * the time, so the name changes and the stale PNG is simply never asked for
 * again; two different documents referring to the same file share one PNG.
 *
 * THREADS. A Markdown document is opened by several threads at once (the
 * canvas, its render workers, the search worker, the thumbnail strip), so this
 * hook runs concurrently for the same file. Writes go to a per-thread temporary
 * and are moved into place with MOVEFILE_REPLACE_EXISTING, so a reader never
 * sees a half-written PNG and the losing racer's work is merely discarded.
 * There is no lock and no network: it is a decode and a rename.
 */
#ifndef SPDF_WIN_MD_WEBP_H
#define SPDF_WIN_MD_WEBP_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Pure: 1 when `path` ends in ".webp" (case-insensitively) -- the extension
 * gate the core applies before it ever calls the hook, repeated here so the
 * hook is safe to call with anything. */
int spdf_win_md_webp_is_webp_name(const char* path);

/* Pure: 1 when these first bytes are a WebP container ("RIFF" + 4 size bytes +
 * "WEBP"). `len` may be shorter than 12, in which case the answer is 0. Used to
 * catch a WebP that arrived over https under some other name. */
int spdf_win_md_webp_is_webp_bytes(const void* data, size_t len);

/* 1 when the file's first 12 bytes are a WebP container. One 12-byte read; the
 * answer for an unreadable file is 0. This, not the extension, is what decides
 * for a cached https image: a badge served as WebP from a URL ending ".svg" is
 * still a WebP. */
int spdf_win_md_webp_file_is_webp(const char* path_utf8);

/* Pure: the cache file name for one source -- 16 hex digits of FNV-1a 64 over
 * `path`, `size` and `mtime`, then ".png". Deterministic, no I/O, so a test can
 * pin it without a cache directory. */
void spdf_win_md_webp_cache_name(const char* path, unsigned long long size, unsigned long long mtime, char* out,
                                 size_t cap);

/* Decode `src_utf8` through WIC and write it to `dst_utf8` as a 32bpp BGRA PNG.
 * 1 on success; 0 when the file is unreadable, WIC has no decoder for it (an
 * older Windows), or the write failed. Atomic: a temporary in the destination's
 * directory, moved into place. */
int spdf_win_md_webp_transcode(const char* src_utf8, const char* dst_utf8);

/* The core hook for spdf_markdown_options.local_image, and the same answer the
 * remote-image cache needs for a WebP it downloaded. `abs_path` is any image
 * file on disk; it is transcoded when its name says ".webp" or its bytes say
 * WebP, and left alone otherwise. Answers 1 with the cache file name when a PNG
 * for it is in the cache or could be made; 0 otherwise, which leaves the
 * "[image]" fallback. */
int spdf_win_md_webp_lookup(void* user, const char* abs_path, char* name_out, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_MD_WEBP_H */
