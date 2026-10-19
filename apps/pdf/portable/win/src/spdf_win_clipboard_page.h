/* spdf_win_clipboard_page.h — Copy Page and Copy Page Image.
 *
 * THREE PAYLOADS, MATCHING THE OTHER TWO FRONTENDS:
 *
 *   Copy Page        a standalone single-page PDF (spdf_save_single_page_pdf)
 *                    written under %TEMP%\ShenzhenPDF-copy and published as
 *                    CF_HDROP + the registered "PDF" format + CF_UNICODETEXT
 *                    holding the path. macOS publishes NSPasteboardTypePDF plus
 *                    a file URL (SPDFMacMarkdownFileActions.mm:141-190); GTK
 *                    publishes GdkFileList plus the path as a string
 *                    (spdf_annot.c action_copy_page_pdf). The Windows spelling
 *                    of "a file plus its path as text" is CF_HDROP plus
 *                    CF_UNICODETEXT, and the registered "PDF" format is what
 *                    Word, Illustrator and Acrobat actually paste from.
 *
 *   Copy Page Text   the page's text, CF_UNICODETEXT. Not a macOS menu item —
 *                    there, page text arrives through a selection — but the
 *                    same clipboard rules apply and the Windows shell track
 *                    asked for it, so it is here rather than reinvented later.
 *
 *   Copy Page Image  the rendered page, CF_DIBV5 and CF_DIB.
 *
 * CF_UNICODETEXT AND NOTHING NARROW, for the reason the selection track
 * MEASURED on this machine (clipboard_test.c test_ansi_would_mangle): the ANSI
 * code page here is 1252, so CF_TEXT would run the payload through
 * WideCharToMultiByte(CP_ACP) and paste every CJK character as '?'. That is not
 * hypothetical for a path either — a document under a folder named in Chinese
 * produces exactly that. Windows synthesises CF_TEXT from CF_UNICODETEXT for
 * the consumers that still ask, so publishing wide alone loses nothing.
 *
 * THE LIGHT-THEME RULE. Copy Page Image renders through
 * spdf_win_export_render_flags(), never through the reading theme. A pasted
 * page carrying our dark paper would be wrong wherever it lands, and macOS goes
 * as far as re-rendering a cached dark page to avoid it
 * (SPDFMacMarkdownFileActions.mm:110-130). See spdf_win_export.h; the
 * regression is portable/win/tests/light_theme_test.c.
 *
 * NO COPY PERMISSION GATE, AND NONE MAY BE ADDED. spdf_has_permission(doc, 'c')
 * returns 1 unconditionally by product decision (shenzhen_pdf_core.h:209-214),
 * and spdf_win_selection.h section 5 says the same for the selection copy.
 *
 * WHAT IS TESTABLE ON A LOCKED WORKSTATION. OpenClipboard(NULL) fails with
 * ERROR_ACCESS_DENIED (5) while the session is locked, so the publish half
 * cannot run here. Every function that COMPOSES a payload is therefore
 * separate, returns the exact GMEM_MOVEABLE block SetClipboardData would
 * receive, and is driven byte for byte by page_export_test.c — the same split
 * spdf_win_selection.h made for spdf_win_clipboard_alloc_utf16(), and for the
 * same reason: everything that can corrupt is in the composition.
 */
#ifndef SPDF_WIN_CLIPBOARD_PAGE_H
#define SPDF_WIN_CLIPBOARD_PAGE_H

#include <windows.h>

#include "shenzhen_pdf_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/* --- composition (pure, no clipboard) ------------------------------------- */

/* A packed DIB of an spdf_bitmap, as a GMEM_MOVEABLE block: header, then
 * BOTTOM-UP 32-bit BGRA rows with no padding (a 32bpp row is always 4-byte
 * aligned, so the DIB stride equals width*4 and the core's stride is copied row
 * by row rather than wholesale — they differ whenever MuPDF pads).
 *
 * `v5` selects the header: 1 for BITMAPV5HEADER (CF_DIBV5, BI_BITFIELDS with an
 * explicit alpha mask and LCS_sRGB) and 0 for BITMAPINFOHEADER (CF_DIB, BI_RGB).
 * BOTH are published, because consumers are split: CF_DIB is what a decades-old
 * Win32 app understands, and CF_DIBV5 is what carries the colour space.
 *
 * The core renders a page onto opaque white, so every alpha byte is 255 and the
 * two headers describe the same pixels; the alpha channel is preserved anyway
 * rather than zeroed, because a consumer that reads CF_DIBV5's alpha mask and
 * finds zeros shows a fully transparent image.
 *
 * The caller owns the handle and must GlobalFree it if it is not handed to
 * SetClipboardData. `size_out`, when non-NULL, receives the block size.
 * NULL on failure (no bitmap, non-positive dimensions, or an allocation that
 * would exceed the addressable size). */
HGLOBAL spdf_win_clipboard_alloc_dib(const spdf_bitmap* bitmap, int v5, SIZE_T* size_out);

/* A CF_HDROP block naming exactly one file: DROPFILES with fWide = TRUE,
 * followed by the path and a second terminating NUL. The caller owns it. */
HGLOBAL spdf_win_clipboard_alloc_hdrop(const wchar_t* path);

/* The whole file at `path` as a GMEM_MOVEABLE block, for the registered "PDF"
 * clipboard format. NULL when the file cannot be read or is empty. `size_out`
 * receives the byte count. */
HGLOBAL spdf_win_clipboard_alloc_file_bytes(const wchar_t* path, SIZE_T* size_out);

/* The registered clipboard format id for "PDF" — the name Acrobat, Word and
 * Illustrator all agree on. Registered lazily on first use and cached;
 * RegisterClipboardFormat is idempotent and returns the same id process-wide,
 * so nothing about this runs before a copy actually happens. 0 on failure. */
UINT spdf_win_clipboard_pdf_format(void);

/* --- rendering ------------------------------------------------------------
 *
 * The page rendered for the clipboard, at `dpi` device pixels per inch, ALWAYS
 * in the document's own colours. Returns 1 and fills *out (caller calls
 * spdf_free_bitmap) or 0 with err filled.
 *
 * dpi <= 0 means the Copy Page Image default of 144 (2x), which is what macOS
 * pastes: -copyCurrentPageImage: writes the cached page image, and the reader's
 * cache holds pages at the display scale, 2x on every Mac shipped this decade.
 * A pasted page that is crisp when the recipient zooms is the point. */
#define SPDF_WIN_COPY_IMAGE_DEFAULT_DPI 144.0

int spdf_win_clipboard_render_page(spdf_document* doc, int page_index, double dpi, spdf_bitmap* out, char* err,
                                   size_t err_len);

/* --- publishing (needs the clipboard) -------------------------------------
 *
 * Each returns 1 on success, 0 on failure. A failure to OPEN the clipboard is
 * reported through `os_error`, when non-NULL, as the GetLastError() value —
 * ERROR_ACCESS_DENIED (5) on a locked workstation — so a caller can tell "the
 * session is locked" from "the payload could not be built", and so a test can
 * report SKIP with the errno instead of failing. */

/* Copy Page: write the single-page PDF and publish the three formats. */
int spdf_win_copy_page_pdf(spdf_document* doc, int page_index, const wchar_t* doc_path, char* err, size_t err_len,
                           DWORD* os_error);

/* Copy Page Text: the page's text as CF_UNICODETEXT, lines joined with CRLF
 * (the clipboard's line convention, not the core's). */
int spdf_win_copy_page_text(spdf_document* doc, int page_index, char* err, size_t err_len, DWORD* os_error);

/* Copy Page Image: CF_DIBV5 + CF_DIB. */
int spdf_win_copy_page_image(spdf_document* doc, int page_index, double dpi, char* err, size_t err_len,
                             DWORD* os_error);

/* The page's text as one UTF-8 string with CRLF line breaks, which is what
 * spdf_win_copy_page_text() puts on the clipboard. Exported so the join is
 * testable without a clipboard. Caller frees with free(). NULL on failure or
 * on a page with no text. */
char* spdf_win_page_text_utf8(spdf_document* doc, int page_index, char* err, size_t err_len);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SPDF_WIN_CLIPBOARD_PAGE_H */
