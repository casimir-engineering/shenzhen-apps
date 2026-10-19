/* tools_panel_probe.c -- opens the REAL tool panel (spdf_win_panel.h) on the
 * real toolchain without the rest of the app, drives its primary button, waits
 * for the job to finish and writes a screenshot of the window. The evidence
 * that the panel itself -- pickers, status, progress, live log, buttons -- does
 * what spdf_win_panel_jobs.cpp says, and looks like something.
 *
 *   tools_panel_probe ocr <pdf> <out.bmp> [dark]
 *       open the OCR panel on the PDF, click Run OCR, wait, screenshot; the
 *       host callback swaps the validated output in as the app would
 *   tools_panel_probe selection <pdf> <out.bmp> <text> [dark]
 *       open the Translate Selection panel (it runs at once), wait, screenshot
 *   tools_panel_probe document <pdf> <out.bmp> <from> <to> [dark]
 *       open the Translate Document panel, pick the pair, click Translate,
 *       wait, screenshot; the host callback reports the opened copy
 *
 * Why not the app itself: a second ShenzhenPDF.exe would merge its window
 * into the reader's session.yaml. This probe owns no session. Not a test (it
 * runs the real tools and needs them installed); its name keeps it out of the
 * harness. Built by tools_panel.sh beside it. */
#include "spdf_win_ocr.h"
#include "spdf_win_panel.h"

#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_busy_seen, g_idle_after_busy, g_swapped;
static char g_opened[1024];

static int host_ocr_finished(void* user, const char* pdf, const char* out, char* err, size_t err_len) {
    (void)user;
    g_swapped = spdf_win_ocr_install_output(out, pdf, err, err_len);
    printf("host: ocr_finished -> swap %s\n", g_swapped ? "ok" : err);
    return g_swapped;
}
static void host_open(void* user, const char* path) {
    (void)user;
    snprintf(g_opened, sizeof(g_opened), "%s", path);
    printf("host: open_document %s\n", path);
}
static void host_busy(void* user, int busy) {
    (void)user;
    printf("host: busy=%d\n", busy);
    if (busy) g_busy_seen = 1;
    else if (g_busy_seen) g_idle_after_busy = 1;
}

/* PrintWindow into a 24-bit BMP; the panel is our own top-level window, so
 * this works occluded and without a desktop capture. */
static int screenshot(HWND hwnd, const char* path) {
    RECT rc;
    HDC screen = GetDC(NULL);
    HDC mem = CreateCompatibleDC(screen);
    HBITMAP bmp;
    BITMAPINFOHEADER bih;
    BITMAPFILEHEADER bfh;
    int w, h, stride;
    unsigned char* pixels;
    FILE* f;
    GetWindowRect(hwnd, &rc);
    w = rc.right - rc.left;
    h = rc.bottom - rc.top;
    bmp = CreateCompatibleBitmap(screen, w, h);
    SelectObject(mem, bmp);
    PrintWindow(hwnd, mem, 2 /* PW_RENDERFULLCONTENT */);
    memset(&bih, 0, sizeof(bih));
    bih.biSize = sizeof(bih);
    bih.biWidth = w;
    bih.biHeight = h; /* bottom-up, as BMP wants */
    bih.biPlanes = 1;
    bih.biBitCount = 24;
    stride = ((w * 3 + 3) / 4) * 4;
    pixels = (unsigned char*)malloc((size_t)stride * (size_t)h);
    GetDIBits(mem, bmp, 0, (UINT)h, pixels, (BITMAPINFO*)&bih, DIB_RGB_COLORS);
    memset(&bfh, 0, sizeof(bfh));
    bfh.bfType = 0x4D42;
    bfh.bfOffBits = sizeof(bfh) + sizeof(bih);
    bfh.bfSize = bfh.bfOffBits + (DWORD)(stride * h);
    f = fopen(path, "wb");
    if (f) {
        fwrite(&bfh, sizeof(bfh), 1, f);
        fwrite(&bih, sizeof(bih), 1, f);
        fwrite(pixels, (size_t)stride * (size_t)h, 1, f);
        fclose(f);
    }
    free(pixels);
    DeleteObject(bmp);
    DeleteDC(mem);
    ReleaseDC(NULL, screen);
    return f != NULL;
}

static HWND find_button(HWND panel, const wchar_t* text) {
    HWND child = GetWindow(panel, GW_CHILD);
    for (; child; child = GetWindow(child, GW_HWNDNEXT)) {
        wchar_t cls[32], title[64];
        GetClassNameW(child, cls, 32);
        GetWindowTextW(child, title, 64);
        if (_wcsicmp(cls, L"Button") == 0 && wcscmp(title, text) == 0) return child;
    }
    return NULL;
}

static void pump(DWORD ms) {
    DWORD until = GetTickCount() + ms;
    MSG msg;
    while (GetTickCount() < until) {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        Sleep(20);
    }
}

int main(int argc, char** argv) {
    SpdfWinPanelRequest req;
    SpdfWinPanelHost host;
    HWND panel;
    const char* mode = argc > 1 ? argv[1] : "";
    const char* pdf = argc > 2 ? argv[2] : "";
    const char* out = argc > 3 ? argv[3] : "panel.bmp";
    int is_selection = strcmp(mode, "selection") == 0;
    const char* text = is_selection && argc > 4 ? argv[4] : NULL;
    static char file_text[4096];
    /* "@file": the text is read from a UTF-8 file, because main()'s argv is
     * the ANSI code page and CJK on a 1252 console would arrive as '?'. */
    if (text && text[0] == '@') {
        FILE* f = fopen(text + 1, "rb");
        size_t n = f ? fread(file_text, 1, sizeof(file_text) - 1, f) : 0;
        if (f) fclose(f);
        file_text[n] = '\0';
        text = file_text;
    }
    int dark = argc > 1 && strcmp(argv[argc - 1], "dark") == 0;
    DWORD deadline;

    if (!*mode || !*pdf) {
        fprintf(stderr, "usage: see the header of tools_panel_probe.c\n");
        return 64;
    }
    memset(&req, 0, sizeof(req));
    req.mode = strcmp(mode, "ocr") == 0 ? SPDF_WIN_PANEL_OCR
               : is_selection          ? SPDF_WIN_PANEL_TRANSLATE_SELECTION
                                       : SPDF_WIN_PANEL_TRANSLATE_DOCUMENT;
    req.dark = dark;
    req.pdf_path = pdf;
    req.selection = text;
    memset(&host, 0, sizeof(host));
    host.ocr_finished = host_ocr_finished;
    host.open_document = host_open;
    host.busy_changed = host_busy;
    if (!spdf_win_panel_open(&req, &host)) {
        printf("panel did not open\n");
        return 1;
    }
    panel = FindWindowW(L"SpdfWinToolPanel", NULL);
    printf("panel hwnd=%p\n", (void*)panel);
    pump(800);
    /* document <pdf> <out.bmp> <from> <to>: pick the pair in the two combos
     * by their "(code)" suffix, as a reader would. */
    if (req.mode == SPDF_WIN_PANEL_TRANSLATE_DOCUMENT && argc > 5) {
        HWND child = GetWindow(panel, GW_CHILD);
        int which = 0;
        for (; child && which < 2; child = GetWindow(child, GW_HWNDNEXT)) {
            wchar_t cls[32], want[16], item[128];
            char narrow[16];
            int count, i;
            GetClassNameW(child, cls, 32);
            if (_wcsicmp(cls, L"ComboBox") != 0) continue;
            snprintf(narrow, sizeof(narrow), "(%s)", argv[4 + which]);
            MultiByteToWideChar(CP_UTF8, 0, narrow, -1, want, 16);
            count = (int)SendMessageW(child, CB_GETCOUNT, 0, 0);
            for (i = 0; i < count; ++i) {
                item[0] = 0;
                SendMessageW(child, CB_GETLBTEXT, (WPARAM)i, (LPARAM)item);
                if (wcsstr(item, want)) {
                    SendMessageW(child, CB_SETCURSEL, (WPARAM)i, 0);
                    break;
                }
            }
            printf("combo %d (%d entries) -> %s: %s\n", which, count, narrow, i < count ? "set" : "NOT FOUND");
            ++which;
        }
    }
    if (!is_selection) {
        HWND button = find_button(panel, req.mode == SPDF_WIN_PANEL_OCR ? L"Run OCR" : L"Translate");
        printf("primary button %s\n", button ? "found; clicking" : "NOT FOUND");
        if (button) SendMessageW(button, BM_CLICK, 0, 0);
    }
    /* Until the job reports idle after having been busy, or 10 minutes. An
     * idle that offers Install is taken (up to three times: the flow re-probes
     * after an install and may offer again), which is the readme's "installs
     * it and resumes automatically" seen from the button's side. */
    deadline = GetTickCount() + 600000;
    for (int round = 0; round < 4; ++round) {
        HWND install;
        while (!g_idle_after_busy && GetTickCount() < deadline && IsWindow(panel)) pump(100);
        pump(300);
        install = IsWindow(panel) ? find_button(panel, L"Install") : NULL;
        if (!install || !IsWindowVisible(install) || !IsWindowEnabled(install)) break;
        printf("install offered; clicking\n");
        g_idle_after_busy = 0;
        SendMessageW(install, BM_CLICK, 0, 0);
    }
    pump(600); /* let the last status paint */
    if (IsWindow(panel)) {
        wchar_t status[512] = L"";
        HWND child = GetWindow(panel, GW_CHILD);
        for (; child; child = GetWindow(child, GW_HWNDNEXT)) {
            wchar_t cls[32];
            GetClassNameW(child, cls, 32);
            if (_wcsicmp(cls, L"Static") == 0) {
                GetWindowTextW(child, status, 512);
                if (wcslen(status) > 20) break; /* the status line, not a label */
            }
        }
        printf("status: %ls\n", status);
        printf("screenshot %s: %s\n", out, screenshot(panel, out) ? "written" : "FAILED");
    }
    printf("busy_seen=%d idle_after_busy=%d swapped=%d opened=%s\n", g_busy_seen, g_idle_after_busy, g_swapped,
           g_opened);
    spdf_win_panel_close();
    return g_idle_after_busy ? 0 : 1;
}
