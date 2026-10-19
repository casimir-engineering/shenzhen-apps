#pragma once

#include "spdf_win_open.h" /* the process opener: Markdown-aware once main() has installed it */

/* spdf_win_window_doc.h -- the ONE document the headless paths open, how an
 * error is reported, and the UTF-16 -> UTF-8 step every path argument takes.
 *
 * Header-only and included from spdf_win_main.cpp immediately after `struct
 * app`, before every other glue header: report() is what all of them report
 * through, open_document() is what spdf_win_headless.h and
 * spdf_win_headless_viewport.h open through, and utf8_from_wide() is what a
 * dropped or dialog-chosen path goes through in spdf_win_chrome_tabs_ui.h.
 * Every function here was in spdf_win_main.cpp and does exactly what it did
 * there; they moved out when the session and presentation work pushed that
 * file past its 500-line cap, and tools/file-size-limits.md asks for an
 * extracted file rather than a raised one. Not part of the port's public
 * surface.
 */

/* Local, static and small on purpose. T6 owns the shared UTF-8/UTF-16 helpers
 * in spdf_win_paths.{h,c}; duplicating six lines here rather than taking a
 * cross-track build dependency keeps this binary buildable from its own
 * sources plus the core and T3's two files. */
static char* utf8_from_wide(const wchar_t* w) {
    if (!w) return NULL;
    int need = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (need <= 0) return NULL;
    char* out = (char*)malloc((size_t)need);
    if (!out) return NULL;
    if (WideCharToMultiByte(CP_UTF8, 0, w, -1, out, need, NULL, NULL) <= 0) {
        free(out);
        return NULL;
    }
    return out;
}

static void report(const wchar_t* text, bool interactive) {
    fwprintf(stderr, L"ShenzhenPDF: %s\n", text);
    if (interactive) MessageBoxW(NULL, text, L"ShenzhenPDF", MB_OK | MB_ICONERROR);
}

static bool open_document(app* a, const wchar_t* wpath, int page_index, bool interactive) {
    char err[256] = {0};
    wchar_t message[600];

    a->path = utf8_from_wide(wpath);
    if (!a->path) {
        report(L"That path could not be converted to UTF-8.", interactive);
        return false;
    }
    a->doc = spdf_win_open_document(a->path, err, sizeof(err));
    if (!a->doc) {
        _snwprintf_s(message, _TRUNCATE, L"Could not open %s\n\n%hs", wpath, err[0] ? err : "unknown error");
        report(message, interactive);
        return false;
    }

    int pages = spdf_page_count(a->doc);
    if (page_index < 0 || page_index >= pages) {
        _snwprintf_s(message, _TRUNCATE, L"Page %d is outside this document (0-%d).", page_index, pages - 1);
        report(message, interactive);
        return false;
    }

    /* The canvas reads page 0's size and nothing else. Every other page is
     * measured when the viewport reaches it, so opening a 500-page document
     * costs the same as opening a 2-page one. The path goes with it so the
     * render workers can open their own handle -- the core allows one
     * spdf_document per thread, so they cannot borrow ours. */
    a->canvas = spdf_win_canvas_create(a->doc, a->path, a->render_flags, err, sizeof(err));
    if (!a->canvas) {
        _snwprintf_s(message, _TRUNCATE, L"Could not lay out %s: %hs", wpath, err[0] ? err : "unknown error");
        report(message, interactive);
        return false;
    }
    return true;
}

static void close_document(app* a) {
    spdf_win_canvas_destroy(a->canvas);
    a->canvas = NULL;
    if (a->doc) spdf_close(a->doc);
    a->doc = NULL;
    free(a->path);
    a->path = NULL;
}
