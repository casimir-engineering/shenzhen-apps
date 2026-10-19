/* spdf_win_toolchain_run.cpp -- the WIN32 half of spdf_win_toolchain.h:
 * probing the real machine (environment, filesystem, registry) and the one
 * subprocess seam every power tool goes through -- CreateProcessW with pipes,
 * a job object so a cancel kills the whole tree, output streamed as UTF-8
 * lines to the calling thread.
 *
 * Every path is UTF-8 inside and UTF-16 at the Win32 boundary, converted
 * here; documents with CJK names must reach ocrmypdf intact (this machine's
 * ANSI code page is 1252). */
#include "spdf_win_toolchain.h"

#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "spdf_win_state.h"

#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "shell32.lib")

/* --- UTF-8 <-> UTF-16 ------------------------------------------------------- */

static int to_wide(const char* utf8, wchar_t* out, int cap) {
    return utf8 && MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out, cap) > 0;
}

static int to_utf8(const wchar_t* wide, char* out, size_t cap) {
    return wide && WideCharToMultiByte(CP_UTF8, 0, wide, -1, out, (int)cap, NULL, NULL) > 0;
}

static wchar_t* wide_dup(const char* utf8) {
    int need = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    wchar_t* w = need > 0 ? (wchar_t*)malloc(sizeof(wchar_t) * (size_t)need) : NULL;
    if (w && MultiByteToWideChar(CP_UTF8, 0, utf8, -1, w, need) <= 0) {
        free(w);
        w = NULL;
    }
    return w;
}

static void env_utf8(const wchar_t* name, char* out, size_t cap) {
    wchar_t w[SPDF_WIN_TC_ENV];
    out[0] = '\0';
    if (GetEnvironmentVariableW(name, w, (DWORD)(sizeof(w) / sizeof(w[0]))) > 0) to_utf8(w, out, cap);
}

static int file_exists(const char* path, void* user) {
    wchar_t w[SPDF_WIN_TC_PATH];
    DWORD attrs;
    (void)user;
    if (!to_wide(path, w, SPDF_WIN_TC_PATH)) return 0;
    attrs = GetFileAttributesW(w);
    return attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY);
}

int spdf_win_toolchain_dirname(const char* path, char* out, size_t out_bytes) {
    const char* a = path ? strrchr(path, '\\') : NULL;
    const char* b = path ? strrchr(path, '/') : NULL;
    const char* cut = a > b ? a : b;
    size_t n;
    if (!cut) return 0;
    n = (size_t)(cut - path);
    if (n + 1 > out_bytes) return 0;
    memcpy(out, path, n);
    out[n] = '\0';
    return 1;
}

/* --- roots --------------------------------------------------------------------- */

static void resolve_user_scripts(SpdfWinToolchainRoots* roots) {
    static char cached[SPDF_WIN_TC_PATH];
    static int resolved = 0;
    /* Re-asked while empty: Python may be installed by our own plan mid-session. */
    if (!resolved || !cached[0]) {
        char python[SPDF_WIN_TC_PATH];
        resolved = 1;
        cached[0] = '\0';
        if (spdf_win_toolchain_find(SPDF_WIN_TOOL_PYTHON, roots, python, sizeof(python))) {
            const char* argv[3] = {python, "-c", "import sysconfig;print(sysconfig.get_path('scripts','nt_user'))"};
            char cmd[SPDF_WIN_TC_CMD];
            char* out = NULL;
            SpdfWinToolchainRun run;
            memset(&run, 0, sizeof(run));
            spdf_win_toolchain_join_argv(argv, 3, cmd, sizeof(cmd));
            run.command_line = cmd;
            run.stdout_out = &out;
            if (spdf_win_toolchain_run_capture(&run) == 0 && out) {
                size_t n = strcspn(out, "\r\n");
                if (n > 0 && n < sizeof(cached)) {
                    memcpy(cached, out, n);
                    cached[n] = '\0';
                }
            }
            free(out);
        }
    }
    strcpy(roots->user_scripts, cached);
}

void spdf_win_toolchain_roots_from_env(SpdfWinToolchainRoots* roots) {
    if (!roots) return;
    memset(roots, 0, sizeof(*roots));
    env_utf8(L"ProgramFiles", roots->program_files, sizeof(roots->program_files));
    env_utf8(L"LOCALAPPDATA", roots->local_appdata, sizeof(roots->local_appdata));
    env_utf8(L"USERPROFILE", roots->user_profile, sizeof(roots->user_profile));
    env_utf8(L"SystemRoot", roots->system_root, sizeof(roots->system_root));
    env_utf8(L"PATH", roots->path_env, sizeof(roots->path_env));
    resolve_user_scripts(roots); /* needs the four above to find python */
}

/* --- glob + registry + find ------------------------------------------------ */

/* Expand the first "*" path component to the newest matching directory. */
static int glob_newest(const char* pattern, char* out, size_t out_bytes) {
    const char* star = strchr(pattern, '*');
    const char* seg_start;
    const char* seg_end;
    char parent[SPDF_WIN_TC_PATH], mask[SPDF_WIN_TC_PATH];
    wchar_t wmask[SPDF_WIN_TC_PATH];
    WIN32_FIND_DATAW fd;
    HANDLE h;
    char names[32][MAX_PATH];
    const char* name_ptrs[32];
    int count = 0, best;

    if (!star) {
        if (strlen(pattern) + 1 > out_bytes) return 0;
        strcpy(out, pattern);
        return 1;
    }
    seg_start = star;
    while (seg_start > pattern && seg_start[-1] != '\\' && seg_start[-1] != '/') --seg_start;
    seg_end = star;
    while (*seg_end && *seg_end != '\\' && *seg_end != '/') ++seg_end;
    if ((size_t)(seg_start - pattern) >= sizeof(parent) || (size_t)(seg_end - pattern) >= sizeof(mask)) return 0;
    memcpy(parent, pattern, (size_t)(seg_start - pattern));
    parent[seg_start - pattern] = '\0';
    memcpy(mask, pattern, (size_t)(seg_end - pattern));
    mask[seg_end - pattern] = '\0';
    if (!to_wide(mask, wmask, SPDF_WIN_TC_PATH)) return 0;
    h = FindFirstFileW(wmask, &fd);
    if (h == INVALID_HANDLE_VALUE) return 0;
    do {
        if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && count < 32 &&
            to_utf8(fd.cFileName, names[count], sizeof(names[count]))) {
            name_ptrs[count] = names[count];
            ++count;
        }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    best = spdf_win_toolchain_newest_version_index(name_ptrs, count);
    if (best < 0) return 0;
    if (snprintf(out, out_bytes, "%s%s%s", parent, names[best], seg_end) >= (int)out_bytes) return 0;
    /* A second "*" (none today) would recurse here. */
    return strchr(out, '*') == NULL;
}

static int registry_tesseract(char* out, size_t out_bytes) {
    HKEY key;
    wchar_t value[SPDF_WIN_TC_PATH];
    DWORD size = sizeof(value), type = 0;
    char dir[SPDF_WIN_TC_PATH];
    int ok = 0;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Tesseract-OCR", 0, KEY_READ | KEY_WOW64_64KEY, &key) !=
        ERROR_SUCCESS)
        return 0;
    if (RegQueryValueExW(key, L"InstallDir", NULL, &type, (BYTE*)value, &size) == ERROR_SUCCESS ||
        (size = sizeof(value), RegQueryValueExW(key, L"Path", NULL, &type, (BYTE*)value, &size) == ERROR_SUCCESS)) {
        if (to_utf8(value, dir, sizeof(dir)) && snprintf(out, out_bytes, "%s\\tesseract.exe", dir) < (int)out_bytes)
            ok = file_exists(out, NULL);
    }
    RegCloseKey(key);
    return ok;
}

int spdf_win_toolchain_find(spdf_win_tool tool, const SpdfWinToolchainRoots* roots, char* out, size_t out_bytes) {
    char cands[SPDF_WIN_TC_MAX_CANDIDATES][SPDF_WIN_TC_PATH];
    int n;
    if (!roots || !out || out_bytes < SPDF_WIN_TC_PATH) return 0;
    if (spdf_win_toolchain_search_path_env(roots->path_env, spdf_win_tool_exe(tool), file_exists, NULL, out, out_bytes))
        return 1;
    n = spdf_win_toolchain_candidates(tool, roots, cands);
    for (int i = 0; i < n; ++i) {
        char expanded[SPDF_WIN_TC_PATH];
        if (glob_newest(cands[i], expanded, sizeof(expanded)) && file_exists(expanded, NULL)) {
            strcpy(out, expanded);
            return 1;
        }
    }
    if (tool == SPDF_WIN_TOOL_TESSERACT) return registry_tesseract(out, out_bytes);
    return 0;
}

int spdf_win_toolchain_missing_components(const char* tesseract, const char* tessdata_parent, const char* language,
                                          char out[8][32]) {
    char parts[8][32];
    char* listing = NULL;
    char* errs = NULL;
    int n = spdf_win_ocr_language_components(language, parts), missing = 0;
    if (tesseract && *tesseract) {
        const char* argv[2] = {tesseract, "--list-langs"};
        char cmd[SPDF_WIN_TC_CMD];
        SpdfWinToolchainRun run;
        memset(&run, 0, sizeof(run));
        spdf_win_toolchain_join_argv(argv, 2, cmd, sizeof(cmd));
        run.command_line = cmd;
        run.stdout_out = &listing;
        run.stderr_out = &errs; /* --list-langs historically printed to stderr */
        spdf_win_toolchain_run_capture(&run);
    }
    for (int i = 0; i < n; ++i) {
        char file[SPDF_WIN_TC_PATH];
        int have = spdf_win_toolchain_list_output_has_language(listing, parts[i]) ||
                   spdf_win_toolchain_list_output_has_language(errs, parts[i]);
        if (!have && tessdata_parent && *tessdata_parent &&
            snprintf(file, sizeof(file), "%s\\tessdata\\%s.traineddata", tessdata_parent, parts[i]) < (int)sizeof(file))
            have = file_exists(file, NULL);
        if (!have) strcpy(out[missing++], parts[i]);
    }
    free(listing);
    free(errs);
    return missing;
}

int spdf_win_toolchain_tessdata_parent_for_language(const SpdfWinToolchainRoots* roots, const char* language,
                                                    char* out, size_t out_bytes) {
    char parts[8][32];
    int n = spdf_win_ocr_language_components(language, parts), any = 0;
    if (!spdf_win_toolchain_tessdata_parent(roots, out, out_bytes)) return 0;
    /* The prefix is only worth setting when it holds something tesseract's own
     * tessdata lacks; every component must then be present there, because a
     * TESSDATA_PREFIX replaces the search path rather than extending it. */
    for (int i = 0; i < n; ++i) {
        char file[SPDF_WIN_TC_PATH];
        if (snprintf(file, sizeof(file), "%s\\tessdata\\%s.traineddata", out, parts[i]) >= (int)sizeof(file) ||
            !file_exists(file, NULL))
            return 0;
        any = 1;
    }
    return any;
}

/* Copy every file directly inside <src_dir> into <dst_dir> (created), skipping
 * ones already there. For tesseract's configs/ and tessconfigs/: output formats
 * such as hocr are config files there, and with TESSDATA_PREFIX pointing at our
 * directory tesseract looks for them under it and nowhere else. */
static void copy_flat_dir(const char* src_dir, const char* dst_dir) {
    wchar_t wmask[SPDF_WIN_TC_PATH], wsrc[SPDF_WIN_TC_PATH], wdst[SPDF_WIN_TC_PATH];
    WIN32_FIND_DATAW fd;
    HANDLE h;
    char mask[SPDF_WIN_TC_PATH];
    if (!to_wide(dst_dir, wdst, SPDF_WIN_TC_PATH)) return;
    CreateDirectoryW(wdst, NULL);
    if (snprintf(mask, sizeof(mask), "%s\\*", src_dir) >= (int)sizeof(mask) || !to_wide(mask, wmask, SPDF_WIN_TC_PATH))
        return;
    h = FindFirstFileW(wmask, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
        if (!to_wide(src_dir, wsrc, SPDF_WIN_TC_PATH) || !to_wide(dst_dir, wdst, SPDF_WIN_TC_PATH)) continue;
        if (wcslen(wsrc) + wcslen(fd.cFileName) + 2 > SPDF_WIN_TC_PATH ||
            wcslen(wdst) + wcslen(fd.cFileName) + 2 > SPDF_WIN_TC_PATH)
            continue;
        wcscat(wsrc, L"\\");
        wcscat(wsrc, fd.cFileName);
        wcscat(wdst, L"\\");
        wcscat(wdst, fd.cFileName);
        CopyFileW(wsrc, wdst, TRUE); /* FALSE + ERROR_FILE_EXISTS is the "already there" case */
    } while (FindNextFileW(h, &fd));
    FindClose(h);
}

int spdf_win_toolchain_tessdata_complete(const SpdfWinToolchainRoots* roots, const char* tesseract_exe,
                                         const char* language, char* out, size_t out_bytes) {
    char parts[8][32];
    char tess_dir[SPDF_WIN_TC_PATH], src[SPDF_WIN_TC_PATH], dst[SPDF_WIN_TC_PATH];
    wchar_t wsrc[SPDF_WIN_TC_PATH], wdst[SPDF_WIN_TC_PATH];
    int n = spdf_win_ocr_language_components(language, parts), ours = 0;
    if (!spdf_win_toolchain_tessdata_parent(roots, out, out_bytes)) return 0;
    for (int i = 0; i < n; ++i) {
        if (snprintf(dst, sizeof(dst), "%s\\tessdata\\%s.traineddata", out, parts[i]) < (int)sizeof(dst) &&
            file_exists(dst, NULL))
            ours = 1;
    }
    if (!ours) return 0; /* nothing downloaded: tesseract's own data serves */
    if (!tesseract_exe || !spdf_win_toolchain_dirname(tesseract_exe, tess_dir, sizeof(tess_dir))) return 0;
    /* The output-format configs (hocr, pdf, tsv...) live beside the language
     * data and are looked up under the prefix too. */
    {
        static const char* const subdirs[] = {"configs", "tessconfigs"};
        for (int i = 0; i < 2; ++i) {
            if (snprintf(src, sizeof(src), "%s\\tessdata\\%s", tess_dir, subdirs[i]) < (int)sizeof(src) &&
                snprintf(dst, sizeof(dst), "%s\\tessdata\\%s", out, subdirs[i]) < (int)sizeof(dst))
                copy_flat_dir(src, dst);
        }
    }
    /* osd rides along: --rotate-pages asks tesseract for it. */
    if (n < 8) strcpy(parts[n++], "osd");
    for (int i = 0; i < n; ++i) {
        if (snprintf(dst, sizeof(dst), "%s\\tessdata\\%s.traineddata", out, parts[i]) >= (int)sizeof(dst)) return 0;
        if (file_exists(dst, NULL)) continue;
        if (snprintf(src, sizeof(src), "%s\\tessdata\\%s.traineddata", tess_dir, parts[i]) >= (int)sizeof(src) ||
            !file_exists(src, NULL) || !to_wide(src, wsrc, SPDF_WIN_TC_PATH) || !to_wide(dst, wdst, SPDF_WIN_TC_PATH))
            return strcmp(parts[i], "osd") == 0 ? 1 : 0; /* no osd anywhere: rotation is skipped, OCR still runs */
        if (!CopyFileW(wsrc, wdst, TRUE) && GetLastError() != ERROR_FILE_EXISTS) return 0;
        /* A freshly written 10 MB osd.traineddata is exactly what an on-access
         * scanner holds for a moment; tesseract opened it a second later and
         * reported "Error opening data file" on a file that was there. Wait
         * until it can be read before naming the directory. */
        for (int attempt = 0; attempt < 50; ++attempt) {
            HANDLE h = CreateFileW(wdst, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
            if (h != INVALID_HANDLE_VALUE) {
                CloseHandle(h);
                break;
            }
            Sleep(100);
        }
    }
    return 1;
}

void spdf_win_toolchain_probe(const SpdfWinToolchainRoots* roots, const char* ocr_language,
                              SpdfWinToolchainState* st) {
    char parent[SPDF_WIN_TC_PATH];
    if (!st) return;
    memset(st, 0, sizeof(*st));
    for (int t = 0; t < SPDF_WIN_TOOL_COUNT; ++t)
        spdf_win_toolchain_find((spdf_win_tool)t, roots, st->path[t], sizeof(st->path[t]));
    if (ocr_language && *ocr_language) {
        if (!spdf_win_toolchain_tessdata_parent(roots, parent, sizeof(parent))) parent[0] = '\0';
        st->missing_language_count = spdf_win_toolchain_missing_components(
            st->path[SPDF_WIN_TOOL_TESSERACT], parent, ocr_language, st->missing_languages);
    }
}

unsigned spdf_win_toolchain_cpu_count(void) {
    DWORD n = GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
    return n > 0 ? (unsigned)n : 1u;
}

/* --- settings.yaml --------------------------------------------------------- */

int spdf_win_toolchain_setting_get(const char* key, char* out, size_t out_bytes) {
    char* json = spdf_win_state_read_json(SPDF_WIN_STATE_SETTINGS);
    int ok = json ? spdf_win_toolchain_json_get_string(json, key, out, out_bytes) : 0;
    free(json);
    return ok;
}

int spdf_win_toolchain_setting_set(const char* key, const char* value) {
    spdf_win_state_read_status status = SPDF_WIN_STATE_READ_ABSENT;
    char* json = spdf_win_state_read_json_checked(SPDF_WIN_STATE_SETTINGS, &status);
    char* updated;
    int ok;
    /* A file that is there and unreadable must not be written over -- the
     * state layer's own rule (spdf_win_state.h). */
    if (status == SPDF_WIN_STATE_READ_FAILED) return 0;
    updated = (char*)malloc(SPDF_WIN_TC_ENV);
    if (!updated) {
        free(json);
        return 0;
    }
    ok = spdf_win_toolchain_json_set_string(json, key, value, updated, SPDF_WIN_TC_ENV) &&
         spdf_win_state_write_json(SPDF_WIN_STATE_SETTINGS, updated);
    free(updated);
    free(json);
    return ok;
}
