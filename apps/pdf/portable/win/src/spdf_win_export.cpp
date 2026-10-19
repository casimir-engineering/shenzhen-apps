/* spdf_win_export.cpp — see spdf_win_export.h for the contract and for the
 * light-theme rule this file is the canonical home of. */

#include "spdf_win_export.h"

#include <shlobj.h>
#include <shobjidl.h>

#include <stdio.h>
#include <string.h>
#include <wchar.h>

/* comdlg32 is not needed here (IFileSaveDialog is a shell COM object), but
 * ole32/shell32 are, and build-native.cmd already lists them. Declared anyway
 * so a target that links this file alone still resolves. */
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")

/* --- 1. the light-theme rule ---------------------------------------------- */

/* SPDF_RENDER_DEFAULT, unconditionally and with no way to ask for anything
 * else. The reasoning is in spdf_win_export.h; the regression is
 * portable/win/tests/light_theme_test.c. Do not add a parameter. */
unsigned spdf_win_export_render_flags(void) {
    return (unsigned)SPDF_RENDER_DEFAULT;
}

/* Whether the document behind a save or a copy is a Markdown file, from its
 * path: the one question the export verbs ask before choosing the core call.
 * A NULL or unencodable path is not Markdown. */
int spdf_win_export_source_is_markdown(const wchar_t* doc_path) {
    char utf8[MAX_PATH * 4];
    if (!doc_path || !doc_path[0]) return 0;
    if (!spdf_win_export_utf8_path(doc_path, utf8, (int)sizeof(utf8))) return 0;
    return spdf_path_is_markdown(utf8);
}

/* --- 2. pure naming -------------------------------------------------------
 *
 * Hand-written rather than PathFindFileNameW/PathCchRemoveExtension: shlwapi's
 * path functions are the ANSI-era API with wide wrappers, PathCch* needs
 * pathcch.lib and Windows 8, and neither is testable without linking a library
 * this port otherwise does not use. Twenty lines of wchar_t arithmetic here
 * are driven exhaustively by page_export_test.c instead. */

const wchar_t* spdf_win_export_file_name(const wchar_t* path) {
    const wchar_t* name;
    const wchar_t* p;

    if (!path) return NULL;
    name = path;
    for (p = path; *p; ++p) {
        /* ':' is a separator too: "C:file.pdf" names a file on C:'s current
         * directory, and a drive-relative path is a real thing a command line
         * can produce. */
        if (*p == L'\\' || *p == L'/' || *p == L':') name = p + 1;
    }
    return name;
}

int spdf_win_export_file_stem(const wchar_t* path, wchar_t* out, int out_cap) {
    const wchar_t* name;
    const wchar_t* dot;
    const wchar_t* p;
    size_t n;

    if (!out || out_cap <= 0) return 0;
    out[0] = L'\0';
    name = spdf_win_export_file_name(path);
    if (!name) return 0;
    dot = NULL;
    for (p = name; *p; ++p)
        if (*p == L'.' && p != name) dot = p; /* a leading dot is not an extension */
    n = dot ? (size_t)(dot - name) : wcslen(name);
    if (n + 1 > (size_t)out_cap) return 0;
    memcpy(out, name, n * sizeof(wchar_t));
    out[n] = L'\0';
    return 1;
}

int spdf_win_export_page_file_name(const wchar_t* doc_path, int page_index, wchar_t* out, int out_cap) {
    wchar_t stem[MAX_PATH];

    if (!out || out_cap <= 0) return 0;
    out[0] = L'\0';
    if (!spdf_win_export_file_stem(doc_path, stem, (int)(sizeof(stem) / sizeof(stem[0])))) stem[0] = L'\0';
    /* Both originals fall back to "Page" for an empty base — macOS with
     * `base.length ? base : @"Page"`, GTK with `base && *base ? base :
     * "Page"`. Reproduced so the three platforms name the same file. */
    if (!stem[0]) wcscpy_s(stem, sizeof(stem) / sizeof(stem[0]), L"Page");
    if (_snwprintf_s(out, (size_t)out_cap, _TRUNCATE, L"%s - page %d.pdf", stem, page_index + 1) < 0) {
        out[0] = L'\0';
        return 0;
    }
    return 1;
}

int spdf_win_export_has_pdf_extension(const wchar_t* path) {
    size_t n;
    if (!path) return 0;
    n = wcslen(path);
    if (n < 4) return 0;
    return _wcsicmp(path + n - 4, L".pdf") == 0;
}

int spdf_win_export_with_pdf_extension(const wchar_t* path, wchar_t* out, int out_cap) {
    size_t n;

    if (!out || out_cap <= 0) return 0;
    out[0] = L'\0';
    if (!path || !*path) return 0;
    n = wcslen(path);
    if (spdf_win_export_has_pdf_extension(path)) {
        if (n + 1 > (size_t)out_cap) return 0;
        memcpy(out, path, (n + 1) * sizeof(wchar_t));
        return 1;
    }
    if (n + 5 > (size_t)out_cap) return 0;
    memcpy(out, path, n * sizeof(wchar_t));
    memcpy(out + n, L".pdf", 5 * sizeof(wchar_t));
    return 1;
}

/* --- 5. UTF-8 (defined before its callers) -------------------------------- */

int spdf_win_export_utf8_path(const wchar_t* path, char* out, int out_len) {
    int written;
    if (!path) return 0;
    if (!out || out_len <= 0) return WideCharToMultiByte(CP_UTF8, 0, path, -1, NULL, 0, NULL, NULL);
    written = WideCharToMultiByte(CP_UTF8, 0, path, -1, out, out_len, NULL, NULL);
    if (written <= 0) {
        out[0] = '\0';
        return 0;
    }
    return written;
}

/* --- 3. dialogs ----------------------------------------------------------- */

int spdf_win_export_choose_save_path(HWND parent, const wchar_t* title, const wchar_t* default_name, wchar_t* out,
                                     int out_cap, HRESULT* hr_out) {
    IFileSaveDialog* dialog = NULL;
    IShellItem* item = NULL;
    PWSTR chosen = NULL;
    COMDLG_FILTERSPEC filter;
    HRESULT hr;
    HRESULT com;
    int result = -1;

    if (hr_out) *hr_out = S_OK;
    if (!out || out_cap <= 0) return -1;
    out[0] = L'\0';

    /* Apartment-threaded, and a prior initialisation on this thread is fine:
     * RPC_E_CHANGED_MODE means somebody already picked a model, and the shell
     * dialog works under either. Uninitialise only what we initialised. */
    com = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    hr = CoCreateInstance(CLSID_FileSaveDialog, NULL, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
    if (FAILED(hr)) goto done;

    filter.pszName = L"PDF Document (*.pdf)";
    filter.pszSpec = L"*.pdf";
    dialog->SetFileTypes(1, &filter);
    dialog->SetFileTypeIndex(1);
    dialog->SetDefaultExtension(L"pdf");
    if (title && *title) dialog->SetTitle(title);
    if (default_name && *default_name) dialog->SetFileName(default_name);

    hr = dialog->Show(parent);
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
        result = 0; /* the user cancelled: not an error, and nothing to report */
        goto done;
    }
    if (FAILED(hr)) goto done;
    hr = dialog->GetResult(&item);
    if (FAILED(hr)) goto done;
    hr = item->GetDisplayName(SIGDN_FILESYSPATH, &chosen);
    if (FAILED(hr)) goto done;
    /* The dialog's default extension covers the common case, but a user who
     * types "report.txt" with the PDF filter selected gets exactly that back,
     * and the core would then write a PDF under a name nothing opens. */
    result = spdf_win_export_with_pdf_extension(chosen, out, out_cap) ? 1 : -1;

done:
    if (hr_out) *hr_out = hr;
    if (chosen) CoTaskMemFree(chosen);
    if (item) item->Release();
    if (dialog) dialog->Release();
    if (SUCCEEDED(com)) CoUninitialize();
    return result;
}

/* One body for both saves: the only differences are the proposed name, the
 * dialog title and which core call runs. Written once so the two cannot drift
 * in their handling of a cancelled dialog, which is the case a copy-paste
 * would get wrong. page_index < 0 means the whole document. */
static int spdf_win_export_save_common(HWND parent, spdf_document* doc, const wchar_t* doc_path, int page_index,
                                       char* err, size_t err_len, char* out_saved_utf8, size_t out_saved_cap) {
    wchar_t proposed[MAX_PATH];
    wchar_t chosen[MAX_PATH * 2];
    char utf8[MAX_PATH * 4];
    const wchar_t* title;
    int picked;
    int wrote;

    if (err && err_len) err[0] = '\0';
    if (out_saved_utf8 && out_saved_cap) out_saved_utf8[0] = '\0';
    if (!doc) return 0;

    if (page_index >= 0) {
        title = L"Save Page As";
        if (!spdf_win_export_page_file_name(doc_path, page_index,
                                            proposed, (int)(sizeof(proposed) / sizeof(proposed[0]))))
            return 0;
    } else {
        title = L"Save PDF As";
        const wchar_t* name = spdf_win_export_file_name(doc_path);
        if (!spdf_win_export_with_pdf_extension(name && *name ? name : L"Document.pdf", proposed,
                                                (int)(sizeof(proposed) / sizeof(proposed[0]))))
            return 0;
    }

    picked = spdf_win_export_choose_save_path(parent, title, proposed, chosen,
                                              (int)(sizeof(chosen) / sizeof(chosen[0])), NULL);
    if (picked == 0) return 0; /* cancelled: err stays empty */
    if (picked < 0) {
        if (err && err_len) {
            /* The locked-workstation case reaches here. Naming it is the
             * difference between a reader who knows to unlock and one who
             * thinks the app is broken. */
            _snprintf_s(err, err_len, _TRUNCATE, "The save dialog could not be shown.");
        }
        return 0;
    }
    if (!spdf_win_export_utf8_path(chosen, utf8, (int)sizeof(utf8))) {
        if (err && err_len) _snprintf_s(err, err_len, _TRUNCATE, "That location could not be encoded as a path.");
        return 0;
    }
    /* A MARKDOWN DOCUMENT HAS NO ORIGINAL BYTES TO KEEP: it is written out
     * through the core's document writer, vector text and all, and always in
     * the light rendition -- spdf_export_pdf never sees a render flag, which is
     * this file's light-theme rule met by construction (spdf_win_md.h, "THE
     * DARK THEME NEEDS NOTHING HERE"). A PDF keeps its bytes, as before. */
    if (spdf_win_export_source_is_markdown(doc_path)) wrote = spdf_export_pdf(doc, utf8, page_index, err, err_len);
    else if (page_index >= 0) wrote = spdf_save_single_page_pdf(doc, page_index, utf8, err, err_len);
    else wrote = spdf_save_document(doc, utf8, err, err_len);
    /* Only on success, so a caller cannot mistake a failed write for one the
     * file watcher should be told about. */
    if (wrote && out_saved_utf8 && out_saved_cap) _snprintf_s(out_saved_utf8, out_saved_cap, _TRUNCATE, "%s", utf8);
    return wrote;
}

int spdf_win_export_save_document_as(HWND parent, spdf_document* doc, const wchar_t* doc_path, char* err,
                                     size_t err_len, char* out_saved_utf8, size_t out_saved_cap) {
    return spdf_win_export_save_common(parent, doc, doc_path, -1, err, err_len, out_saved_utf8, out_saved_cap);
}

int spdf_win_export_save_page_as(HWND parent, spdf_document* doc, const wchar_t* doc_path, int page_index, char* err,
                                 size_t err_len, char* out_saved_utf8, size_t out_saved_cap) {
    if (page_index < 0) return 0;
    return spdf_win_export_save_common(parent, doc, doc_path, page_index, err, err_len, out_saved_utf8, out_saved_cap);
}

/* --- 4. the copy scratch directory ---------------------------------------- */

int spdf_win_export_copy_scratch_dir(wchar_t* out, int out_cap) {
    wchar_t temp[MAX_PATH];
    DWORD n;
    DWORD attr;

    if (!out || out_cap <= 0) return 0;
    out[0] = L'\0';
    n = GetTempPathW((DWORD)(sizeof(temp) / sizeof(temp[0])), temp);
    if (n == 0 || n >= sizeof(temp) / sizeof(temp[0])) return 0;
    if (_snwprintf_s(out, (size_t)out_cap, _TRUNCATE, L"%sShenzhenPDF-copy", temp) < 0) {
        out[0] = L'\0';
        return 0;
    }
    /* GetTempPathW always ends in a backslash, so no separator is inserted. */
    attr = GetFileAttributesW(out);
    if (attr != INVALID_FILE_ATTRIBUTES) return (attr & FILE_ATTRIBUTE_DIRECTORY) ? 1 : 0;
    if (CreateDirectoryW(out, NULL)) return 1;
    /* A concurrent copy in another window may have won the race. */
    return GetLastError() == ERROR_ALREADY_EXISTS ? 1 : 0;
}
