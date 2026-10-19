/* page_export_test.c -- Save As, Save Page As, Copy Page, Copy Page Text and
 * Copy Page Image: the naming policy, the exact bytes each clipboard format
 * would receive, and -- now that this workstation is unlocked -- the real
 * round trip through the real clipboard.
 *
 * WHAT IS PROVED WITHOUT A DIALOG, AND WHY THAT SPLIT EXISTS. IFileSaveDialog
 * and PrintDlgEx cannot be shown from a test: they are modal, they need a
 * desktop, and nobody is there to click them. So every decision the save paths
 * make BEFORE opening anything -- the proposed file name, the ".pdf" the user
 * did not type, the UTF-8 encoding the core needs -- is a pure function, and
 * this suite drives those directly. The dialog call itself is a dozen lines
 * around them.
 *
 * THE CLIPBOARD IS REAL, NOT MOCKED. A mock would prove nothing about
 * GlobalAlloc/GMEM_MOVEABLE ownership, which is the half of this code that can
 * corrupt a process. It is also split in two on purpose, exactly as
 * clipboard_test.c splits the selection copy: the ALLOCATION is a pure
 * function whose bytes are asserted here without opening anything, and the
 * publish is a thin call around it. That split is what let this suite say
 * something while the workstation was locked and OpenClipboard(NULL) returned
 * ERROR_ACCESS_DENIED (5) -- and the layer-down assertions are kept now that
 * the round trip runs, because they check things the round trip cannot see
 * (the DIB header fields, the bottom-up row order, the BGRA channel order).
 *
 * IF THE CLIPBOARD CANNOT BE OPENED the round-trip cases report SKIP with the
 * OS error and the suite still checks every composition, rather than failing
 * for a reason that is not about this code.
 *
 * THE USER IS AT THIS MACHINE. Like clipboard_test.c, this suite RESTORES
 * NOTHING: a test that copies leaves its last payload on the clipboard, the
 * same as any copy would.
 */
/* spdf-test-sources: portable/win/src/spdf_win_export.cpp portable/win/src/spdf_win_clipboard_page.cpp portable/win/src/spdf_win_selection.cpp portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c portable/core/spdf_markdown.c portable/core/spdf_markdown_support.c portable/core/spdf_markdown_html.c portable/core/spdf_markdown_lang.c portable/core/spdf_markdown_lex.c portable/core/spdf_markdown_math.c portable/core/spdf_markdown_open.c ext/md4c/md4c.c */
/* spdf-test-args: portable/win/tests/fixtures/golden.pdf portable/win/tests/fixtures/selection.pdf */
/* spdf-test-needs: mupdf */
#include <windows.h>

#include <shlobj.h>

#include "shenzhen_pdf_core.h"
#include "spdf_win_clipboard_page.h"
#include "spdf_win_export.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;
static int g_skipped = 0;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (!(cond)) {                                                                                                 \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                                     \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

#define CHECK_WSTR(got, want)                                                                                          \
    do {                                                                                                               \
        ++g_checks;                                                                                                    \
        if (wcscmp((got), (want)) != 0) {                                                                              \
            printf("FAIL %s:%d: got \"%ls\" want \"%ls\"\n", __FILE__, __LINE__, (got), (want));                       \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

/* --- 1. naming ------------------------------------------------------------ */

static void test_naming(void) {
    wchar_t buf[MAX_PATH];

    CHECK_WSTR(spdf_win_export_file_name(L"C:\\docs\\golden.pdf"), L"golden.pdf");
    CHECK_WSTR(spdf_win_export_file_name(L"C:/docs/golden.pdf"), L"golden.pdf");
    CHECK_WSTR(spdf_win_export_file_name(L"golden.pdf"), L"golden.pdf");
    /* A drive-relative path is a real thing a command line can produce. */
    CHECK_WSTR(spdf_win_export_file_name(L"C:golden.pdf"), L"golden.pdf");
    CHECK_WSTR(spdf_win_export_file_name(L"C:\\docs\\"), L"");

    CHECK(spdf_win_export_file_stem(L"C:\\docs\\golden.pdf", buf, MAX_PATH));
    CHECK_WSTR(buf, L"golden");
    CHECK(spdf_win_export_file_stem(L"C:\\docs\\two.dots.pdf", buf, MAX_PATH));
    CHECK_WSTR(buf, L"two.dots"); /* the LAST dot is the extension */
    /* A leading dot is not an extension: ".profile" is the whole name. */
    CHECK(spdf_win_export_file_stem(L"C:\\docs\\.profile", buf, MAX_PATH));
    CHECK_WSTR(buf, L".profile");
    CHECK(spdf_win_export_file_stem(L"C:\\docs\\noext", buf, MAX_PATH));
    CHECK_WSTR(buf, L"noext");

    /* "<stem> - page N.pdf", byte for byte what macOS
     * (SPDFMacMarkdownFileActions.mm:161) and GTK
     * (spdf_annot_single_page_filename) produce, so the same page copied on
     * three machines arrives with the same name. N is 1-based. */
    CHECK(spdf_win_export_page_file_name(L"C:\\docs\\golden.pdf", 1, buf, MAX_PATH));
    CHECK_WSTR(buf, L"golden - page 2.pdf");
    CHECK(spdf_win_export_page_file_name(L"C:\\docs\\golden.pdf", 0, buf, MAX_PATH));
    CHECK_WSTR(buf, L"golden - page 1.pdf");
    /* Both originals fall back to "Page" for an empty base. */
    CHECK(spdf_win_export_page_file_name(L"", 0, buf, MAX_PATH));
    CHECK_WSTR(buf, L"Page - page 1.pdf");
    CHECK(spdf_win_export_page_file_name(NULL, 4, buf, MAX_PATH));
    CHECK_WSTR(buf, L"Page - page 5.pdf");

    /* The extension the dialog may not have added. A user who types "report"
     * with the PDF filter selected must not get a file Windows cannot open. */
    CHECK(spdf_win_export_has_pdf_extension(L"a.pdf"));
    CHECK(spdf_win_export_has_pdf_extension(L"a.PDF"));
    CHECK(spdf_win_export_has_pdf_extension(L"a.PdF"));
    CHECK(!spdf_win_export_has_pdf_extension(L"a.pdfx"));
    CHECK(spdf_win_export_has_pdf_extension(L".pdf")); /* ".pdf" alone IS one */
    CHECK(!spdf_win_export_has_pdf_extension(L"pdf"));
    CHECK(!spdf_win_export_has_pdf_extension(NULL));

    CHECK(spdf_win_export_with_pdf_extension(L"C:\\a\\report", buf, MAX_PATH));
    CHECK_WSTR(buf, L"C:\\a\\report.pdf");
    CHECK(spdf_win_export_with_pdf_extension(L"C:\\a\\report.PDF", buf, MAX_PATH));
    CHECK_WSTR(buf, L"C:\\a\\report.PDF"); /* left exactly as the user typed it */
    CHECK(spdf_win_export_with_pdf_extension(L"C:\\a\\report.txt", buf, MAX_PATH));
    CHECK_WSTR(buf, L"C:\\a\\report.txt.pdf");
    /* Refusals, not truncations: half a path is worse than none. */
    CHECK(!spdf_win_export_with_pdf_extension(L"C:\\a\\report", buf, 8));
    CHECK_WSTR(buf, L"");
    CHECK(!spdf_win_export_with_pdf_extension(L"", buf, MAX_PATH));
}

/* --- 2. UTF-8 for the core ------------------------------------------------ */

static void test_utf8_path(void) {
    char utf8[256];
    /* MuPDF opens every path through fz_fopen_utf8 on Windows
     * (mupdf/source/fitz/output.c:291) and the core through spdf_compat_fopen,
     * which widens with CP_UTF8. So a path with a character outside this
     * machine's ANSI code page (1252) must come out as UTF-8 BYTES here, not
     * as question marks -- which is exactly what CP_ACP would have produced.
     * U+4E2D U+6587 = e4 b8 ad e6 96 87. */
    CHECK(spdf_win_export_utf8_path(L"C:\\\x4e2d\x6587\\a.pdf", utf8, (int)sizeof(utf8)) > 0);
    CHECK(strcmp(utf8, "C:\\\xe4\xb8\xad\xe6\x96\x87\\a.pdf") == 0);
    if (strcmp(utf8, "C:\\\xe4\xb8\xad\xe6\x96\x87\\a.pdf") != 0) printf("      got \"%s\"\n", utf8);
    /* Sizing pass. */
    CHECK(spdf_win_export_utf8_path(L"abc", NULL, 0) == 4);
    CHECK(spdf_win_export_utf8_path(NULL, utf8, (int)sizeof(utf8)) == 0);
}

/* --- 3. the DIB, byte for byte -------------------------------------------- */

/* A 3x2 bitmap with a deliberately WIDER stride than width*4, because MuPDF
 * pads and a wholesale memcpy would smear the image diagonally -- the failure
 * the screen path's d2d.compose cases exist to catch. */
static void test_dib_composition(void) {
    unsigned char pixels[2 * 20];
    spdf_bitmap bitmap;
    HGLOBAL v5;
    HGLOBAL plain;
    SIZE_T size = 0;
    const unsigned char* base;
    const BITMAPINFOHEADER* info;
    const BITMAPV5HEADER* v5h;
    const unsigned char* bits;

    memset(pixels, 0xAA, sizeof(pixels)); /* the padding, which must not be copied */
    /* Row 0: red, green, blue. Row 1: white, black, half-alpha grey. */
    memcpy(pixels + 0, "\xff\x00\x00\xff" "\x00\xff\x00\xff" "\x00\x00\xff\xff", 12);
    memcpy(pixels + 20, "\xff\xff\xff\xff" "\x00\x00\x00\xff" "\x80\x80\x80\x40", 12);

    bitmap.rgba = pixels;
    bitmap.width = 3;
    bitmap.height = 2;
    bitmap.stride = 20;

    plain = spdf_win_clipboard_alloc_dib(&bitmap, 0, &size);
    CHECK(plain != NULL);
    if (plain) {
        base = (const unsigned char*)GlobalLock(plain);
        CHECK(base != NULL);
        if (base) {
            info = (const BITMAPINFOHEADER*)base;
            CHECK(size == sizeof(BITMAPINFOHEADER) + 3 * 2 * 4);
            CHECK(info->biSize == sizeof(BITMAPINFOHEADER));
            CHECK(info->biWidth == 3);
            CHECK(info->biHeight == 2); /* POSITIVE: bottom-up, the DIB default */
            CHECK(info->biBitCount == 32);
            CHECK(info->biCompression == BI_RGB);
            CHECK(info->biSizeImage == 3 * 2 * 4);
            bits = base + sizeof(BITMAPINFOHEADER);
            /* Bottom-up, so the FIRST DIB row is the LAST source row, and the
             * channel order is BGRA. */
            CHECK(memcmp(bits, "\xff\xff\xff\xff" "\x00\x00\x00\xff" "\x80\x80\x80\x40", 12) == 0);
            /* Row 0 of the source: red becomes 00 00 ff, blue becomes ff 00 00. */
            CHECK(memcmp(bits + 12, "\x00\x00\xff\xff" "\x00\xff\x00\xff" "\xff\x00\x00\xff", 12) == 0);
            GlobalUnlock(plain);
        }
        GlobalFree(plain);
    }

    v5 = spdf_win_clipboard_alloc_dib(&bitmap, 1, &size);
    CHECK(v5 != NULL);
    if (v5) {
        base = (const unsigned char*)GlobalLock(v5);
        CHECK(base != NULL);
        if (base) {
            v5h = (const BITMAPV5HEADER*)base;
            CHECK(size == sizeof(BITMAPV5HEADER) + 3 * 2 * 4);
            CHECK(v5h->bV5Size == sizeof(BITMAPV5HEADER));
            CHECK(v5h->bV5Compression == BI_BITFIELDS);
            CHECK(v5h->bV5RedMask == 0x00FF0000);
            CHECK(v5h->bV5GreenMask == 0x0000FF00);
            CHECK(v5h->bV5BlueMask == 0x000000FF);
            /* The alpha mask is what makes CF_DIBV5 worth publishing; a
             * consumer that reads it and finds a zeroed alpha channel shows a
             * fully transparent image, so the channel is PRESERVED and not
             * forced opaque. */
            CHECK(v5h->bV5AlphaMask == 0xFF000000);
            CHECK(v5h->bV5CSType == LCS_sRGB);
            bits = base + sizeof(BITMAPV5HEADER);
            CHECK(bits[3] == 0xff);   /* white, opaque */
            CHECK(bits[11] == 0x40);  /* the half-alpha pixel kept its alpha */
            GlobalUnlock(v5);
        }
        GlobalFree(v5);
    }

    /* Refusals rather than a bad block. */
    bitmap.width = 0;
    CHECK(spdf_win_clipboard_alloc_dib(&bitmap, 0, &size) == NULL);
    bitmap.width = 3;
    bitmap.stride = 4; /* narrower than width*4: not a bitmap we can read */
    CHECK(spdf_win_clipboard_alloc_dib(&bitmap, 0, &size) == NULL);
    CHECK(spdf_win_clipboard_alloc_dib(NULL, 0, &size) == NULL);
}

/* --- 4. CF_HDROP, byte for byte ------------------------------------------- */

static void test_hdrop_composition(void) {
    HGLOBAL handle = spdf_win_clipboard_alloc_hdrop(L"C:\\tmp\\golden - page 1.pdf");
    const DROPFILES* drop;
    const wchar_t* text;

    CHECK(handle != NULL);
    if (!handle) return;
    drop = (const DROPFILES*)GlobalLock(handle);
    CHECK(drop != NULL);
    if (drop) {
        CHECK(drop->pFiles == sizeof(DROPFILES));
        CHECK(drop->fWide == TRUE); /* wide, for the same reason as CF_UNICODETEXT */
        text = (const wchar_t*)((const unsigned char*)drop + drop->pFiles);
        CHECK(wcscmp(text, L"C:\\tmp\\golden - page 1.pdf") == 0);
        /* The list is DOUBLE-NUL terminated; a shell that reads one NUL and
         * keeps going walks off the block. */
        CHECK(text[wcslen(text) + 1] == L'\0');
        GlobalUnlock(handle);
    }
    GlobalFree(handle);
    CHECK(spdf_win_clipboard_alloc_hdrop(NULL) == NULL);
    CHECK(spdf_win_clipboard_alloc_hdrop(L"") == NULL);
}

/* --- 5. the scratch directory is LAZY ------------------------------------- */

static void test_scratch_is_lazy(void) {
    wchar_t dir[MAX_PATH];
    wchar_t probe[MAX_PATH];

    /* NOTHING creates it but a copy. This is the port's standing speed rule --
     * a feature costs nothing for documents that do not use it, and nothing
     * new runs on the launch path -- and it is asserted rather than claimed:
     * the directory is removed, the app's OTHER entry points are not called,
     * and it must still be absent until spdf_win_export_copy_scratch_dir()
     * itself is. */
    CHECK(GetTempPathW(MAX_PATH, probe) > 0);
    wcscat_s(probe, MAX_PATH, L"ShenzhenPDF-copy");
    RemoveDirectoryW(probe); /* fails harmlessly when it holds earlier copies */
    if (GetFileAttributesW(probe) != INVALID_FILE_ATTRIBUTES) {
        printf("SKIP scratch-is-lazy: %ls already holds files from an earlier copy\n", probe);
        ++g_skipped;
    } else {
        CHECK(GetFileAttributesW(probe) == INVALID_FILE_ATTRIBUTES);
    }
    CHECK(spdf_win_export_copy_scratch_dir(dir, MAX_PATH));
    CHECK(wcscmp(dir, probe) == 0);
    CHECK(GetFileAttributesW(dir) != INVALID_FILE_ATTRIBUTES);
    /* Idempotent: a second copy must not fail because the first made it. */
    CHECK(spdf_win_export_copy_scratch_dir(dir, MAX_PATH));
}

/* --- 6. Copy Page: the file it writes ------------------------------------- */

static void test_copy_page_writes_one_page(const char* path) {
    char err[512] = "";
    spdf_document* doc = spdf_open(path, err, sizeof(err));
    wchar_t wide[MAX_PATH];
    wchar_t dir[MAX_PATH];
    wchar_t name[MAX_PATH];
    wchar_t written[MAX_PATH * 2];
    char written_utf8[MAX_PATH * 4];
    DWORD os_error = 0;
    spdf_document* copy;

    if (!doc) {
        printf("FAIL could not open %s: %s\n", path, err);
        ++g_failures;
        return;
    }
    CHECK(spdf_page_count(doc) == 2); /* golden.pdf */
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, MAX_PATH);

    /* NO COPY PERMISSION GATE, AND NONE MAY BE ADDED: 'c' is 1 unconditionally
     * by product decision (shenzhen_pdf_core.h:209-214). Asserted here so a
     * future gate would have to delete this line to be added. */
    CHECK(spdf_has_permission(doc, 'c') == 1);

    if (!spdf_win_copy_page_pdf(doc, 1, wide, err, sizeof(err), &os_error)) {
        if (os_error) {
            printf("SKIP copy-page-pdf: the clipboard could not be opened, GetLastError=%lu\n",
                   (unsigned long)os_error);
            ++g_skipped;
        } else {
            printf("FAIL copy-page-pdf: %s\n", err);
            ++g_failures;
        }
    }

    /* The FILE is written whether or not the clipboard accepted it, and it is
     * the thing a paste actually delivers -- so it is checked separately: one
     * page, and it reopens. */
    CHECK(spdf_win_export_copy_scratch_dir(dir, MAX_PATH));
    CHECK(spdf_win_export_page_file_name(wide, 1, name, MAX_PATH));
    _snwprintf_s(written, MAX_PATH * 2, _TRUNCATE, L"%s\\%s", dir, name);
    CHECK(GetFileAttributesW(written) != INVALID_FILE_ATTRIBUTES);
    CHECK(spdf_win_export_utf8_path(written, written_utf8, (int)sizeof(written_utf8)) > 0);
    copy = spdf_open(written_utf8, err, sizeof(err));
    CHECK(copy != NULL);
    if (copy) {
        CHECK(spdf_page_count(copy) == 1);
        spdf_close(copy);
    }
    spdf_close(doc);
}

/* --- 7. the real clipboard ------------------------------------------------ */

static void test_clipboard_round_trip(const char* selection_path) {
    char err[512] = "";
    spdf_document* doc = spdf_open(selection_path, err, sizeof(err));
    char* text;
    DWORD os_error = 0;

    if (!doc) {
        printf("FAIL could not open %s: %s\n", selection_path, err);
        ++g_failures;
        return;
    }

    /* The join, without a clipboard: lines separated by CRLF, which is the
     * clipboard's convention and not the core's. */
    text = spdf_win_page_text_utf8(doc, 0, err, sizeof(err));
    CHECK(text != NULL);
    if (text) {
        CHECK(strstr(text, "\r\n") != NULL);
        /* selection.pdf carries CJK page text. It must survive as UTF-8 bytes
         * here and as UTF-16 on the clipboard; CF_TEXT would have made it
         * "????" on this machine, which clipboard_test.c measured. */
        CHECK(strstr(text, "\xe4\xb8\xad") != NULL || strstr(text, "\xe6\x96\x87") != NULL);
    }

    if (spdf_win_copy_page_text(doc, 0, err, sizeof(err), &os_error)) {
        wchar_t* pasted;
        HANDLE data;
        if (OpenClipboard(NULL)) {
            data = GetClipboardData(CF_UNICODETEXT);
            CHECK(data != NULL);
            if (data) {
                pasted = (wchar_t*)GlobalLock(data);
                CHECK(pasted != NULL);
                if (pasted && text) {
                    /* Round trip: what came back, narrowed to UTF-8, is what
                     * went in. */
                    char back[8192];
                    int n = WideCharToMultiByte(CP_UTF8, 0, pasted, -1, back, (int)sizeof(back), NULL, NULL);
                    CHECK(n > 0);
                    if (n > 0) CHECK(strcmp(back, text) == 0);
                }
                if (data) GlobalUnlock(data);
            }
            CloseClipboard();
        } else {
            printf("SKIP copy-page-text read-back: OpenClipboard failed, GetLastError=%lu\n",
                   (unsigned long)GetLastError());
            ++g_skipped;
        }
    } else if (os_error) {
        printf("SKIP copy-page-text: the clipboard could not be opened, GetLastError=%lu\n",
               (unsigned long)os_error);
        ++g_skipped;
    } else {
        printf("FAIL copy-page-text: %s\n", err);
        ++g_failures;
    }
    if (text) free(text);

    /* Copy Page Image, and the two formats it must publish. */
    os_error = 0;
    if (spdf_win_copy_page_image(doc, 0, 72.0, err, sizeof(err), &os_error)) {
        if (OpenClipboard(NULL)) {
            CHECK(IsClipboardFormatAvailable(CF_DIBV5));
            CHECK(IsClipboardFormatAvailable(CF_DIB));
            {
                HANDLE data = GetClipboardData(CF_DIB);
                CHECK(data != NULL);
                if (data) {
                    const BITMAPINFOHEADER* info = (const BITMAPINFOHEADER*)GlobalLock(data);
                    float w = 0.0f, h = 0.0f;
                    CHECK(info != NULL);
                    if (info && spdf_page_size(doc, 0, &w, &h, err, sizeof(err))) {
                        /* At 72 dpi one PDF point is one pixel. */
                        CHECK(info->biWidth > 0 && info->biHeight > 0);
                        CHECK(info->biWidth == (LONG)(w + 0.5f) || info->biWidth == (LONG)w);
                    }
                    if (info) GlobalUnlock(data);
                }
            }
            CloseClipboard();
        } else {
            printf("SKIP copy-page-image read-back: OpenClipboard failed, GetLastError=%lu\n",
                   (unsigned long)GetLastError());
            ++g_skipped;
        }
    } else if (os_error) {
        printf("SKIP copy-page-image: the clipboard could not be opened, GetLastError=%lu\n",
               (unsigned long)os_error);
        ++g_skipped;
    } else {
        printf("FAIL copy-page-image: %s\n", err);
        ++g_failures;
    }

    spdf_close(doc);
}

int main(int argc, char** argv) {
    const char* golden = argc > 1 ? argv[1] : "portable/win/tests/fixtures/golden.pdf";
    const char* selection = argc > 2 ? argv[2] : "portable/win/tests/fixtures/selection.pdf";

    test_naming();
    test_utf8_path();
    test_dib_composition();
    test_hdrop_composition();
    test_scratch_is_lazy();
    test_copy_page_writes_one_page(golden);
    test_clipboard_round_trip(selection);

    printf("page_export_test: %d checks, %d failures, %d skipped\n", g_checks, g_failures, g_skipped);
    return g_failures ? 1 : 0;
}
