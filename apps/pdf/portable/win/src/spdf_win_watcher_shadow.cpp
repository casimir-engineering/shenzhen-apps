/* spdf_win_watcher_shadow.cpp — the read-only shadow-copy half of
 * spdf_win_watcher.h: where the copies live, how one is resolved for an open,
 * the session-restore adoption, release and the orphan sweep. Split from
 * spdf_win_watcher.cpp so each file stays about one thing (and under the
 * 500-line cap): that one is threads and timers, this one is files.
 *
 * Mac counterparts: readOnlyCopiesDirectory, readOnlyCopyFileNameForSourcePath,
 * resolveWorkingPathForTab, deleteReadOnlyCopyIfUnsharedForTab,
 * sweepOrphanedReadOnlyCopies (ShenzhenPDFMac.mm :6316-6440); GTK's
 * spdf_watcher_resolve_open / _prime_restore / watcher_sweep_orphans. */
#include "spdf_win_watcher.h"

#include "spdf_win_palette_filter.h" /* spdf_win_palette_canonical_path */
#include "spdf_win_paths.h"
#include "spdf_win_watcher_logic.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <bcrypt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "bcrypt.lib")

namespace {

/* Session-restore adoptions: canonical source -> persisted binding, consumed
 * by the first resolve on that source (GTK watcher_restore_bindings). A tab
 * strip holds at most SPDF_WIN_TABS_MAX documents. */
struct Binding {
    char source[SPDF_WIN_WATCHER_PATH_MAX]; /* canonical */
    char working_path[SPDF_WIN_WATCHER_PATH_MAX];
    unsigned long long size;
    double mtime;
};
Binding g_bindings[64];
int g_binding_count;

wchar_t* widen(const char* utf8) { return utf8 ? spdf_win_utf16_dup_from_utf8(utf8) : NULL; }

int canonical(const char* path, char* out, size_t cap) {
    return path && *path && spdf_win_palette_canonical_path(path, out, cap) && out[0];
}

bool exists_regular(const char* utf8) {
    unsigned long long size;
    double mtime;
    return spdf_win_watcher_stat(utf8, &size, &mtime) != 0;
}

/* Author a fresh copy of the source: CopyFileW to a temp name in the copies
 * directory, then a replacing move onto `copy_path`, so a reader of the old
 * copy never sees a half-written file. Returns 0 on any failure. */
int write_copy(const char* source, const char* copy_path) {
    wchar_t* wsrc = widen(source);
    wchar_t* wdst = widen(copy_path);
    wchar_t tmp[SPDF_WIN_WATCHER_PATH_MAX + 16];
    int ok = 0;
    if (wsrc && wdst) {
        _snwprintf_s(tmp, _TRUNCATE, L"%s.tmp.%lu", wdst, GetCurrentProcessId());
        if (CopyFileW(wsrc, tmp, FALSE)) {
            /* The copy of a read-only source inherits the read-only bit; the
             * copy must be replaceable next time. */
            SetFileAttributesW(tmp, FILE_ATTRIBUTE_NORMAL);
            ok = MoveFileExW(tmp, wdst, MOVEFILE_REPLACE_EXISTING) != 0;
            if (!ok) DeleteFileW(tmp);
        }
    }
    free(wsrc);
    free(wdst);
    return ok;
}

/* 32 hex digits of randomness for a staging name, when the deterministic copy
 * is held open by the document being replaced. */
int random_hex32(char* out) {
    static const char hex[] = "0123456789abcdef";
    unsigned char bytes[16];
    if (BCryptGenRandom(NULL, bytes, sizeof(bytes), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) return 0;
    for (int i = 0; i < 16; ++i) {
        out[i * 2] = hex[bytes[i] >> 4];
        out[i * 2 + 1] = hex[bytes[i] & 0xF];
    }
    out[32] = '\0';
    return 1;
}

} /* namespace */

int spdf_win_watcher_copies_dir(int create, char* out, size_t out_cap) {
    char state[SPDF_WIN_PATH_MAX];
    if (!spdf_win_paths_state_dir(state, sizeof(state))) return 0;
    if (!spdf_win_path_join(state, "ReadOnlyCopies", out, out_cap)) return 0;
    if (create && !spdf_win_paths_ensure_dir(out)) return 0;
    return 1;
}

int spdf_win_watcher_is_shadow_path(const char* utf8_path) {
    char dir[SPDF_WIN_PATH_MAX], cdir[SPDF_WIN_PATH_MAX], cpath[SPDF_WIN_PATH_MAX];
    if (!spdf_win_watcher_copies_dir(0, dir, sizeof(dir))) return 0;
    if (!canonical(dir, cdir, sizeof(cdir)) || !canonical(utf8_path, cpath, sizeof(cpath))) return 0;
    return spdf_win_watcher_path_is_shadow_in(cpath, cdir);
}

int spdf_win_watcher_existing_working_path(const char* utf8_source, char* out, size_t out_cap) {
    char key[SPDF_WIN_WATCHER_PATH_MAX], dir[SPDF_WIN_PATH_MAX], name[64];
    char copy_path[SPDF_WIN_WATCHER_PATH_MAX];

    if (!out || !out_cap) return 0;
    out[0] = '\0';
    /* The DETERMINISTIC name, and only that one: the random staged fallback
     * resolve_open() uses when the deterministic copy is held open is known
     * only to the tab that made it, and a worker asking about it would be
     * guessing. That tab's canvas hands its own workers the right path
     * directly (spdf_win_tabs_open_render_path); this is for the ones that have
     * nothing but a path, and for them the staged case degrades to today's
     * behaviour -- open the source -- rather than to something wrong. */
    if (!canonical(utf8_source, key, sizeof(key))) return 0;
    if (!spdf_win_watcher_copies_dir(0, dir, sizeof(dir))) return 0;
    if (!spdf_win_watcher_shadow_copy_name(key, name, sizeof(name))) return 0;
    if (!spdf_win_path_join(dir, name, copy_path, sizeof(copy_path))) return 0;
    /* The stat FIRST. Almost every open in this process is of a writable file
     * with no copy, and for those this is one GetFileAttributes rather than an
     * open-for-write probe. */
    if (!exists_regular(copy_path)) return 0;
    if (!spdf_win_watcher_source_is_read_only(utf8_source)) return 0;
    strncpy_s(out, out_cap, copy_path, _TRUNCATE);
    return 1;
}

void spdf_win_watcher_prime_restore(const char* utf8_source, const char* utf8_working_path,
                                    unsigned long long copy_file_size, double copy_modified_at) {
    char key[SPDF_WIN_WATCHER_PATH_MAX];
    Binding* b = NULL;
    if (!utf8_working_path || !*utf8_working_path || !canonical(utf8_source, key, sizeof(key))) return;
    for (int i = 0; i < g_binding_count && !b; ++i)
        if (strcmp(g_bindings[i].source, key) == 0) b = &g_bindings[i];
    if (!b) {
        if (g_binding_count >= (int)(sizeof(g_bindings) / sizeof(g_bindings[0]))) return;
        b = &g_bindings[g_binding_count++];
    }
    strncpy_s(b->source, sizeof(b->source), key, _TRUNCATE);
    strncpy_s(b->working_path, sizeof(b->working_path), utf8_working_path, _TRUNCATE);
    b->size = copy_file_size;
    b->mtime = copy_modified_at;
}

int spdf_win_watcher_resolve_open(const char* utf8_source, SpdfWinWatcherResolution* out) {
    char key[SPDF_WIN_WATCHER_PATH_MAX];
    Binding binding;
    int have_binding = 0;
    unsigned long long src_size = 0;
    double src_mtime = 0.0;
    char dir[SPDF_WIN_PATH_MAX];
    char copy_path[SPDF_WIN_WATCHER_PATH_MAX];

    if (!out) return 0;
    memset(out, 0, sizeof(*out));
    if (!canonical(utf8_source, key, sizeof(key))) return 0;

    /* Consume a primed restore binding, whatever the verdict below. */
    for (int i = 0; i < g_binding_count; ++i) {
        if (strcmp(g_bindings[i].source, key) != 0) continue;
        binding = g_bindings[i];
        have_binding = 1;
        memmove(&g_bindings[i], &g_bindings[i + 1], (size_t)(g_binding_count - i - 1) * sizeof(g_bindings[0]));
        g_binding_count--;
        break;
    }

    if (!spdf_win_watcher_source_is_read_only(utf8_source) || !spdf_win_watcher_stat(utf8_source, &src_size, &src_mtime))
        return 0; /* writable, or missing (the open error path owns that): no copy */
    out->read_only = 1;

    if (have_binding && binding.working_path[0]) {
        strncpy_s(copy_path, sizeof(copy_path), binding.working_path, _TRUNCATE);
    } else {
        char name[64];
        if (!spdf_win_watcher_copies_dir(1, dir, sizeof(dir)) || !spdf_win_watcher_shadow_copy_name(key, name, sizeof(name)) ||
            !spdf_win_path_join(dir, name, copy_path, sizeof(copy_path)))
            return 1; /* read-only, but no place for a copy: open the source */
    }

    if (have_binding &&
        spdf_win_watcher_copy_reusable(exists_regular(copy_path), binding.size, binding.mtime, src_size, src_mtime)) {
        /* The source is as the copy left it: reuse, no content read. */
        strncpy_s(out->working_path, sizeof(out->working_path), copy_path, _TRUNCATE);
        out->copy_file_size = binding.size;
        out->copy_modified_at = binding.mtime;
        return 1;
    }
    if (!write_copy(utf8_source, copy_path)) {
        /* The deterministic copy is probably held open by the document being
         * replaced (a reload). GTK stages the candidate under a private random
         * name for exactly this case; the old copy is released with the old
         * document. */
        char hex[33], staged[SPDF_WIN_WATCHER_PATH_MAX];
        const char* ext = spdf_win_watcher_extension(key);
        if (!spdf_win_watcher_copies_dir(1, dir, sizeof(dir)) || !random_hex32(hex)) return 1;
        if (snprintf(staged, sizeof(staged), "%s\\ro-%s.%s", dir, hex, *ext ? ext : "pdf") >= (int)sizeof(staged))
            return 1;
        if (!write_copy(utf8_source, staged)) return 1; /* copy failed: open the source, no binding */
        strncpy_s(copy_path, sizeof(copy_path), staged, _TRUNCATE);
    }
    strncpy_s(out->working_path, sizeof(out->working_path), copy_path, _TRUNCATE);
    out->copy_file_size = src_size;
    out->copy_modified_at = src_mtime;
    return 1;
}

void spdf_win_watcher_release_copy(const char* utf8_working_path, int still_referenced) {
    wchar_t* wide;
    if (still_referenced || !utf8_working_path || !*utf8_working_path) return;
    /* Only ever delete inside the copies directory: a binding restored from a
     * hand-edited session file must not be able to name an arbitrary file. */
    if (!spdf_win_watcher_is_shadow_path(utf8_working_path)) return;
    wide = widen(utf8_working_path);
    if (wide) {
        SetFileAttributesW(wide, FILE_ATTRIBUTE_NORMAL);
        DeleteFileW(wide);
    }
    free(wide);
}

void spdf_win_watcher_sweep_orphans(const char* const* referenced, int count) {
    char dir[SPDF_WIN_PATH_MAX], cdir[SPDF_WIN_PATH_MAX];
    wchar_t* wdir;
    wchar_t pattern[SPDF_WIN_PATH_MAX + 4];
    WIN32_FIND_DATAW found;
    HANDLE it;
    FILETIME now_ft;
    double now;
    if (!spdf_win_watcher_copies_dir(0, dir, sizeof(dir)) || !canonical(dir, cdir, sizeof(cdir))) return;
    wdir = widen(dir);
    if (!wdir) return;
    _snwprintf_s(pattern, _TRUNCATE, L"%s\\*", wdir);
    it = FindFirstFileW(pattern, &found);
    free(wdir);
    if (it == INVALID_HANDLE_VALUE) return; /* the directory may not exist yet */
    GetSystemTimeAsFileTime(&now_ft);
    {
        ULARGE_INTEGER u;
        u.LowPart = now_ft.dwLowDateTime;
        u.HighPart = now_ft.dwHighDateTime;
        now = (double)(u.QuadPart - 116444736000000000ULL) / 1e7;
    }
    do {
        char name[SPDF_WIN_WATCHER_PATH_MAX], full[SPDF_WIN_WATCHER_PATH_MAX], cfull[SPDF_WIN_WATCHER_PATH_MAX];
        double mtime;
        int is_referenced = 0;
        if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
        if (spdf_win_utf8_from_utf16((const spdf_wchar*)found.cFileName, name, sizeof(name)) == SPDF_WIN_CONV_ERROR)
            continue;
        if (!spdf_win_path_join(dir, name, full, sizeof(full)) || !canonical(full, cfull, sizeof(cfull))) continue;
        if (!spdf_win_watcher_path_is_shadow_in(cfull, cdir)) continue; /* not ours to delete */
        for (int i = 0; i < count && !is_referenced; ++i) {
            char cref[SPDF_WIN_WATCHER_PATH_MAX];
            if (referenced && canonical(referenced[i], cref, sizeof(cref)) && strcmp(cref, cfull) == 0) is_referenced = 1;
        }
        {
            ULARGE_INTEGER u;
            u.LowPart = found.ftLastWriteTime.dwLowDateTime;
            u.HighPart = found.ftLastWriteTime.dwHighDateTime;
            mtime = (double)(u.QuadPart - 116444736000000000ULL) / 1e7;
        }
        if (spdf_win_watcher_sweep_should_delete(is_referenced, mtime, now)) spdf_win_watcher_release_copy(full, 0);
    } while (FindNextFileW(it, &found));
    FindClose(it);
}
