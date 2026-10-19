/* spdf_win_clipboard_page.cpp — see spdf_win_clipboard_page.h. */

#include "spdf_win_clipboard_page.h"

#include "spdf_win_export.h"    /* the light-theme rule, the scratch dir, UTF-8 */
#include "spdf_win_selection.h" /* spdf_win_utf8_to_utf16, spdf_win_clipboard_alloc_utf16 */

/* DROPFILES, for CF_HDROP. <windows.h> does not pull it in, and it is NOT in
 * <shellapi.h> as its name suggests -- this SDK defines it in ShlObj_core.h,
 * which <shlobj.h> is the documented way to reach. */
#include <shlobj.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "user32.lib")

/* --- composition ---------------------------------------------------------- */

UINT spdf_win_clipboard_pdf_format(void) {
    static UINT cached = 0;
    if (!cached) cached = RegisterClipboardFormatW(L"PDF");
    return cached;
}

HGLOBAL spdf_win_clipboard_alloc_dib(const spdf_bitmap* bitmap, int v5, SIZE_T* size_out) {
    SIZE_T header_size;
    SIZE_T row_bytes;
    SIZE_T total;
    HGLOBAL handle;
    unsigned char* base;
    unsigned char* pixels;
    int y;

    if (size_out) *size_out = 0;
    if (!bitmap || !bitmap->rgba) return NULL;
    if (bitmap->width <= 0 || bitmap->height <= 0) return NULL;
    if (bitmap->stride < bitmap->width * 4) return NULL;

    header_size = v5 ? sizeof(BITMAPV5HEADER) : sizeof(BITMAPINFOHEADER);
    row_bytes = (SIZE_T)bitmap->width * 4;
    /* A 96 MB render at 4 bytes a pixel is 24 M pixels; the multiply below
     * cannot overflow a 64-bit SIZE_T for any bitmap the core will produce,
     * but the port also builds 32-bit in principle, so the guard stays. */
    if (row_bytes != 0 && (SIZE_T)bitmap->height > (~(SIZE_T)0 - header_size) / row_bytes) return NULL;
    total = header_size + row_bytes * (SIZE_T)bitmap->height;

    handle = GlobalAlloc(GMEM_MOVEABLE, total);
    if (!handle) return NULL;
    base = (unsigned char*)GlobalLock(handle);
    if (!base) {
        GlobalFree(handle);
        return NULL;
    }
    memset(base, 0, header_size);

    if (v5) {
        BITMAPV5HEADER* h = (BITMAPV5HEADER*)base;
        h->bV5Size = sizeof(BITMAPV5HEADER);
        h->bV5Width = bitmap->width;
        h->bV5Height = bitmap->height; /* positive: bottom-up, the DIB default */
        h->bV5Planes = 1;
        h->bV5BitCount = 32;
        h->bV5Compression = BI_BITFIELDS;
        h->bV5SizeImage = (DWORD)(row_bytes * (SIZE_T)bitmap->height);
        h->bV5RedMask = 0x00FF0000;
        h->bV5GreenMask = 0x0000FF00;
        h->bV5BlueMask = 0x000000FF;
        h->bV5AlphaMask = 0xFF000000;
        h->bV5CSType = LCS_sRGB;
        h->bV5Intent = LCS_GM_IMAGES;
    } else {
        BITMAPINFOHEADER* h = (BITMAPINFOHEADER*)base;
        h->biSize = sizeof(BITMAPINFOHEADER);
        h->biWidth = bitmap->width;
        h->biHeight = bitmap->height;
        h->biPlanes = 1;
        h->biBitCount = 32;
        h->biCompression = BI_RGB;
        h->biSizeImage = (DWORD)(row_bytes * (SIZE_T)bitmap->height);
    }

    /* RGBA (core, top-down) -> BGRA (DIB, bottom-up). Row by row, because the
     * core's stride is not required to equal width*4 and a wholesale memcpy
     * would smear a padded render diagonally — the failure mode
     * d2d.compose-plain exists to catch on the screen path. */
    pixels = base + header_size;
    for (y = 0; y < bitmap->height; ++y) {
        const unsigned char* src = bitmap->rgba + (size_t)y * (size_t)bitmap->stride;
        unsigned char* dst = pixels + (SIZE_T)(bitmap->height - 1 - y) * row_bytes;
        int x;
        for (x = 0; x < bitmap->width; ++x) {
            dst[x * 4 + 0] = src[x * 4 + 2]; /* B */
            dst[x * 4 + 1] = src[x * 4 + 1]; /* G */
            dst[x * 4 + 2] = src[x * 4 + 0]; /* R */
            dst[x * 4 + 3] = src[x * 4 + 3]; /* A */
        }
    }
    GlobalUnlock(handle);
    if (size_out) *size_out = total;
    return handle;
}

HGLOBAL spdf_win_clipboard_alloc_hdrop(const wchar_t* path) {
    SIZE_T chars;
    SIZE_T total;
    HGLOBAL handle;
    DROPFILES* drop;
    wchar_t* text;

    if (!path || !*path) return NULL;
    chars = wcslen(path) + 2; /* the path's NUL, then the list terminator */
    total = sizeof(DROPFILES) + chars * sizeof(wchar_t);
    handle = GlobalAlloc(GMEM_MOVEABLE, total);
    if (!handle) return NULL;
    drop = (DROPFILES*)GlobalLock(handle);
    if (!drop) {
        GlobalFree(handle);
        return NULL;
    }
    memset(drop, 0, total);
    drop->pFiles = sizeof(DROPFILES);
    drop->fWide = TRUE;
    text = (wchar_t*)((unsigned char*)drop + sizeof(DROPFILES));
    memcpy(text, path, (chars - 1) * sizeof(wchar_t)); /* leaves both NULs zero */
    GlobalUnlock(handle);
    return handle;
}

HGLOBAL spdf_win_clipboard_alloc_file_bytes(const wchar_t* path, SIZE_T* size_out) {
    HANDLE file;
    LARGE_INTEGER size;
    HGLOBAL handle;
    unsigned char* base;
    DWORD read = 0;
    BOOL ok;

    if (size_out) *size_out = 0;
    if (!path || !*path) return NULL;
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return NULL;
    if (!GetFileSizeEx(file, &size) || size.QuadPart <= 0 || size.QuadPart > (LONGLONG)0x7FFFFFFF) {
        CloseHandle(file);
        return NULL;
    }
    handle = GlobalAlloc(GMEM_MOVEABLE, (SIZE_T)size.QuadPart);
    if (!handle) {
        CloseHandle(file);
        return NULL;
    }
    base = (unsigned char*)GlobalLock(handle);
    if (!base) {
        GlobalFree(handle);
        CloseHandle(file);
        return NULL;
    }
    ok = ReadFile(file, base, (DWORD)size.QuadPart, &read, NULL);
    GlobalUnlock(handle);
    CloseHandle(file);
    if (!ok || read != (DWORD)size.QuadPart) {
        GlobalFree(handle);
        return NULL;
    }
    if (size_out) *size_out = (SIZE_T)size.QuadPart;
    return handle;
}

/* --- rendering ------------------------------------------------------------ */

int spdf_win_clipboard_render_page(spdf_document* doc, int page_index, double dpi, spdf_bitmap* out, char* err,
                                   size_t err_len) {
    double zoom;

    if (err && err_len) err[0] = '\0';
    if (!doc || !out) return 0;
    if (dpi <= 0.0) dpi = SPDF_WIN_COPY_IMAGE_DEFAULT_DPI;
    zoom = dpi / 72.0;
    /* spdf_win_export_render_flags() and NOTHING ELSE. See spdf_win_export.h. */
    return spdf_render_page_rgba_opts(doc, page_index, (float)zoom, spdf_win_export_render_flags(), NULL, out, err,
                                      err_len);
}

/* --- page text ------------------------------------------------------------ */

char* spdf_win_page_text_utf8(spdf_document* doc, int page_index, char* err, size_t err_len) {
    spdf_text_lines lines;
    size_t total = 1;
    char* out;
    size_t used = 0;
    int i;

    if (err && err_len) err[0] = '\0';
    if (!doc) return NULL;
    memset(&lines, 0, sizeof(lines));
    if (!spdf_extract_page_text_lines(doc, page_index, &lines, err, err_len)) return NULL;
    if (lines.count <= 0) {
        spdf_free_text_lines(&lines);
        return NULL;
    }
    for (i = 0; i < lines.count; ++i) total += (lines.items[i].text ? strlen(lines.items[i].text) : 0) + 2;
    out = (char*)malloc(total);
    if (!out) {
        spdf_free_text_lines(&lines);
        return NULL;
    }
    for (i = 0; i < lines.count; ++i) {
        const char* text = lines.items[i].text ? lines.items[i].text : "";
        size_t n = strlen(text);
        memcpy(out + used, text, n);
        used += n;
        /* CRLF, not the core's LF: the clipboard's line convention is CRLF and
         * Notepad still shows a lone LF as one run-on line. */
        if (i + 1 < lines.count) {
            out[used++] = '\r';
            out[used++] = '\n';
        }
    }
    out[used] = '\0';
    spdf_free_text_lines(&lines);
    return out;
}

/* --- publishing ----------------------------------------------------------- */

/* Open the clipboard with the same brief retry the selection track uses: the
 * owner is usually another process finishing a paste, and it lets go within
 * milliseconds. A locked workstation, by contrast, fails every attempt with
 * ERROR_ACCESS_DENIED, so the retries cost 100 ms and then report it. */
static int page_clipboard_open(DWORD* os_error) {
    int attempt;
    if (os_error) *os_error = 0;
    for (attempt = 0; attempt < 10; ++attempt) {
        if (OpenClipboard(NULL)) return 1;
        if (os_error) *os_error = GetLastError();
        Sleep(10);
    }
    return 0;
}

int spdf_win_copy_page_image(spdf_document* doc, int page_index, double dpi, char* err, size_t err_len,
                             DWORD* os_error) {
    spdf_bitmap bitmap;
    HGLOBAL v5;
    HGLOBAL plain;

    if (os_error) *os_error = 0;
    memset(&bitmap, 0, sizeof(bitmap));
    if (!spdf_win_clipboard_render_page(doc, page_index, dpi, &bitmap, err, err_len)) return 0;
    v5 = spdf_win_clipboard_alloc_dib(&bitmap, 1, NULL);
    plain = spdf_win_clipboard_alloc_dib(&bitmap, 0, NULL);
    spdf_free_bitmap(&bitmap);
    if (!v5 || !plain) {
        if (v5) GlobalFree(v5);
        if (plain) GlobalFree(plain);
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "The page image could not be prepared.");
        return 0;
    }
    if (!page_clipboard_open(os_error)) {
        GlobalFree(v5);
        GlobalFree(plain);
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "The clipboard could not be opened.");
        return 0;
    }
    EmptyClipboard();
    /* Ownership passes to the clipboard on success and stays with us on
     * failure; getting that backwards is the classic way to corrupt a
     * process, which is why the allocation lives in a tested pure function. */
    if (!SetClipboardData(CF_DIBV5, v5)) GlobalFree(v5);
    if (!SetClipboardData(CF_DIB, plain)) GlobalFree(plain);
    CloseClipboard();
    return 1;
}

int spdf_win_copy_page_text(spdf_document* doc, int page_index, char* err, size_t err_len, DWORD* os_error) {
    char* text;
    HGLOBAL block;

    if (os_error) *os_error = 0;
    text = spdf_win_page_text_utf8(doc, page_index, err, err_len);
    if (!text) {
        if (err && err_len && !err[0]) _snprintf_s(err, err_len, _TRUNCATE, "This page has no text to copy.");
        return 0;
    }
    block = spdf_win_clipboard_alloc_utf16(text);
    free(text);
    if (!block) {
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "The page text could not be converted.");
        return 0;
    }
    if (!page_clipboard_open(os_error)) {
        GlobalFree(block);
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "The clipboard could not be opened.");
        return 0;
    }
    EmptyClipboard();
    if (!SetClipboardData(CF_UNICODETEXT, block)) {
        GlobalFree(block);
        CloseClipboard();
        return 0;
    }
    CloseClipboard();
    return 1;
}

int spdf_win_copy_page_pdf(spdf_document* doc, int page_index, const wchar_t* doc_path, char* err, size_t err_len,
                           DWORD* os_error) {
    wchar_t dir[MAX_PATH];
    wchar_t name[MAX_PATH];
    wchar_t path[MAX_PATH * 2];
    char utf8[MAX_PATH * 4];
    HGLOBAL hdrop = NULL;
    HGLOBAL bytes = NULL;
    HGLOBAL text = NULL;
    UINT pdf_format;
    SIZE_T byte_size = 0;

    if (os_error) *os_error = 0;
    if (err && err_len) err[0] = '\0';
    if (!doc || page_index < 0) return 0;
    if (!spdf_win_export_copy_scratch_dir(dir, (int)(sizeof(dir) / sizeof(dir[0])))) {
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "A temporary folder for the copy was not available.");
        return 0;
    }
    if (!spdf_win_export_page_file_name(doc_path, page_index, name, (int)(sizeof(name) / sizeof(name[0])))) return 0;
    if (_snwprintf_s(path, sizeof(path) / sizeof(path[0]), _TRUNCATE, L"%s\\%s", dir, name) < 0) return 0;
    if (!spdf_win_export_utf8_path(path, utf8, (int)sizeof(utf8))) return 0;
    /* Markdown pages are written through the core's document writer, light
     * rendition, as Save Page As does (spdf_win_export.cpp). */
    if (spdf_win_export_source_is_markdown(doc_path) ? !spdf_export_pdf(doc, utf8, page_index, err, err_len)
                                                     : !spdf_save_single_page_pdf(doc, page_index, utf8, err, err_len))
        return 0;

    hdrop = spdf_win_clipboard_alloc_hdrop(path);
    bytes = spdf_win_clipboard_alloc_file_bytes(path, &byte_size);
    {
        /* The path as text, which is what GTK publishes beside the file and
         * what macOS publishes as a file URL. Wide, for the CP1252 reason in
         * this file's header. */
        char path_utf8[MAX_PATH * 4];
        if (spdf_win_export_utf8_path(path, path_utf8, (int)sizeof(path_utf8)))
            text = spdf_win_clipboard_alloc_utf16(path_utf8);
    }
    if (!hdrop && !bytes && !text) {
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "The copied page could not be prepared.");
        return 0;
    }
    if (!page_clipboard_open(os_error)) {
        if (hdrop) GlobalFree(hdrop);
        if (bytes) GlobalFree(bytes);
        if (text) GlobalFree(text);
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "The clipboard could not be opened.");
        return 0;
    }
    EmptyClipboard();
    pdf_format = spdf_win_clipboard_pdf_format();
    if (bytes && pdf_format) {
        if (!SetClipboardData(pdf_format, bytes)) GlobalFree(bytes);
    } else if (bytes) {
        GlobalFree(bytes);
    }
    if (hdrop && !SetClipboardData(CF_HDROP, hdrop)) GlobalFree(hdrop);
    if (text && !SetClipboardData(CF_UNICODETEXT, text)) GlobalFree(text);
    CloseClipboard();
    return 1;
}
