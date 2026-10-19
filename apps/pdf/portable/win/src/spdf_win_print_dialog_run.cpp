/* spdf_win_print_dialog_run.cpp — the in-app print dialog's dealings with the
 * SPOOLER: which printers exist, the driver's own property sheet, and turning
 * the reader's answer into a device context and a print job. Contract and the
 * reasoning behind all of it in spdf_win_print_dialog.h.
 *
 * SEPARATE FROM THE WINDOW (spdf_win_print_dialog.cpp) because none of it needs
 * one. Everything here can be driven from a console with no desktop -- which is
 * what portable/win/tests/print_dialog_test.c does -- and the window cannot.
 */

#include "spdf_win_print_dialog.h"

#include <winspool.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Neither is in build-native.cmd's SYS_LIBS. Declared here so no other track's
 * build has to change for this one to link, exactly as spdf_win_print.cpp
 * already does for comdlg32. */
#pragma comment(lib, "winspool.lib")
#pragma comment(lib, "user32.lib")

/* --- the printers --------------------------------------------------------- */

int spdf_win_print_dialog_printers(spdf_win_print_printers* out) {
    /* PRINTER_INFO_4W is the cheap level: name, server, attributes, and NO
     * round trip to the driver. Level 2 would open every printer to fill in a
     * DEVMODE and a status, which is what makes a printer list take seconds
     * when a network queue is unreachable -- and this dialog needs the names
     * only. The DEVMODE is fetched for the ONE printer the reader chose, by
     * spdf_win_print_dialog_properties() and by the run below. */
    DWORD needed = 0, returned = 0, i;
    BYTE* buffer;
    PRINTER_INFO_4W* info;
    wchar_t def[SPDF_WIN_PRINT_NAME_MAX];
    DWORD def_len = SPDF_WIN_PRINT_NAME_MAX;

    if (!out) return 0;
    memset(out, 0, sizeof(*out));
    out->selected = -1;

    EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, NULL, 4, NULL, 0, &needed, &returned);
    if (needed == 0) return 0;
    buffer = (BYTE*)malloc(needed);
    if (!buffer) return 0;
    if (!EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, NULL, 4, buffer, needed, &needed, &returned)) {
        free(buffer);
        return 0;
    }
    info = (PRINTER_INFO_4W*)buffer;
    for (i = 0; i < returned && out->count < SPDF_WIN_PRINT_MAX_PRINTERS; ++i) {
        if (!info[i].pPrinterName || !info[i].pPrinterName[0]) continue;
        wcsncpy_s(out->name[out->count], SPDF_WIN_PRINT_NAME_MAX, info[i].pPrinterName, _TRUNCATE);
        ++out->count;
    }
    free(buffer);

    if (out->count > 0) {
        out->selected = 0;
        if (GetDefaultPrinterW(def, &def_len)) {
            int at = spdf_win_print_printers_index_of(out, def);
            if (at >= 0) out->selected = at;
        }
    }
    return out->count;
}

int spdf_win_print_printers_index_of(const spdf_win_print_printers* list, const wchar_t* name) {
    int i;
    if (!list || !name || !name[0]) return -1;
    for (i = 0; i < list->count; ++i)
        if (_wcsicmp(list->name[i], name) == 0) return i;
    return -1;
}

/* --- the request ---------------------------------------------------------- */

void spdf_win_print_request_free(spdf_win_print_request* req) {
    if (!req) return;
    free(req->devmode);
    req->devmode = NULL;
}

int spdf_win_print_dialog_range(const spdf_win_print_request* req, int current_page, int page_count,
                               spdf_win_print_page_range* out) {
    int from, to;

    if (!req || !out || page_count <= 0) return 0;
    if (req->range == SPDF_WIN_PRINT_RANGE_ALL) return 0; /* no range == the whole document */
    if (req->range == SPDF_WIN_PRINT_RANGE_CURRENT) {
        /* A caller that does not know the page (the plain
         * spdf_win_print_document_ex entry point) gets page 1 rather than an
         * empty job -- and the dialog greys the choice out in that case, so the
         * reader is never the one making this substitution. */
        from = to = current_page >= 0 ? current_page + 1 : 1;
    } else {
        from = req->from;
        to = req->to;
        if (from > to) {
            int swap = from;
            from = to;
            to = swap;
        }
    }
    if (from < 1) from = 1;
    if (to < 1) to = 1;
    if (from > page_count) from = page_count;
    if (to > page_count) to = page_count;
    out->from = from;
    out->to = to;
    return 1;
}

/* --- the driver's own property sheet -------------------------------------- */

int spdf_win_print_dialog_properties(HWND parent, const wchar_t* printer, DEVMODEW** devmode) {
    HANDLE handle = NULL;
    DEVMODEW* work = NULL;
    LONG bytes;
    LONG rc;

    if (!printer || !printer[0] || !devmode) return 0;
    if (!OpenPrinterW((LPWSTR)printer, &handle, NULL) || !handle) return 0;
    bytes = DocumentPropertiesW(NULL, handle, (LPWSTR)printer, NULL, NULL, 0);
    if (bytes <= 0) {
        ClosePrinter(handle);
        return 0;
    }
    /* The sheet writes its answer into the SAME buffer it was given, and the
     * driver may need more room than the DEVMODE the caller is holding (a
     * private area grows when a driver is updated). So the round trip always
     * happens through a buffer of the size the driver asks for now. */
    work = (DEVMODEW*)calloc(1, (size_t)bytes);
    if (!work) {
        ClosePrinter(handle);
        return 0;
    }
    if (*devmode && (LONG)((*devmode)->dmSize + (*devmode)->dmDriverExtra) <= bytes)
        memcpy(work, *devmode, (size_t)((*devmode)->dmSize + (*devmode)->dmDriverExtra));
    else if (DocumentPropertiesW(NULL, handle, (LPWSTR)printer, work, NULL, DM_OUT_BUFFER) != IDOK) {
        free(work);
        ClosePrinter(handle);
        return 0;
    }
    rc = DocumentPropertiesW(parent, handle, (LPWSTR)printer, work, work,
                             DM_IN_BUFFER | DM_IN_PROMPT | DM_OUT_BUFFER);
    ClosePrinter(handle);
    if (rc != IDOK) {
        free(work);
        return 0;
    }
    free(*devmode);
    *devmode = work;
    return 1;
}

/* --- the job -------------------------------------------------------------- */

spdf_win_print_status spdf_win_print_dialog_run(const spdf_win_print_request* req, spdf_document* doc,
                                                const wchar_t* job_name, int page_count, int current_page, char* err,
                                                size_t err_len) {
    spdf_win_print_page_range range;
    int range_count;
    int* pages;
    int selected;
    HDC dc;
    spdf_win_print_status status;

    if (err && err_len) err[0] = '\0';
    if (!req || !doc || page_count <= 0) return SPDF_WIN_PRINT_NO_DOCUMENT;
    if (!req->printer[0]) {
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "No printer was chosen.");
        return SPDF_WIN_PRINT_FAILED;
    }

    range_count = spdf_win_print_dialog_range(req, current_page, page_count, &range);
    pages = (int*)malloc(sizeof(int) * (size_t)page_count);
    if (!pages) return SPDF_WIN_PRINT_FAILED;
    /* The SAME expansion the system dialog's ranges go through
     * (spdf_win_print_math.h), so "pages 3-5" means the same three sheets
     * whichever dialog asked. */
    selected = spdf_win_print_expand_ranges(range_count ? &range : NULL, range_count, page_count, pages, page_count);
    if (selected <= 0) {
        free(pages);
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "No pages were selected.");
        return SPDF_WIN_PRINT_CANCELLED;
    }

    /* The dialog's own DEVMODE when the reader visited Properties, the driver's
     * defaults otherwise. This is the one call the print dialog would have made
     * for us. */
    dc = CreateDCW(L"WINSPOOL", req->printer, NULL, req->devmode);
    if (!dc) {
        free(pages);
        if (err && err_len)
            _snprintf_s(err, err_len, _TRUNCATE, "Windows could not open \"%ls\" for printing (error %lu).",
                        req->printer, (unsigned long)GetLastError());
        return SPDF_WIN_PRINT_FAILED;
    }
    status = spdf_win_print_run_job(dc, doc, job_name, NULL, pages, selected, req->copies > 0 ? req->copies : 1,
                                    req->choice.mode, req->choice.custom_scale, err, err_len);
    DeleteDC(dc);
    free(pages);
    return status;
}
