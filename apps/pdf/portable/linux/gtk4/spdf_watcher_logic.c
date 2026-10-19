#include "spdf_watcher.h"

#include <glib/gstdio.h>
#include <math.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

gint64 spdf_watcher_debounce_event(SpdfWatcherDebounce* d, gint64 now_us, gint64 delay_us) {
    d->fire_at_us = now_us + delay_us;
    return d->fire_at_us;
}

gboolean spdf_watcher_debounce_fire(SpdfWatcherDebounce* d, gint64 now_us) {
    if (d->fire_at_us == 0 || now_us < d->fire_at_us) return FALSE;
    d->fire_at_us = 0;
    return TRUE;
}

static const char* watcher_path_extension(const char* path) {
    const char* base = strrchr(path, '/');
    const char* dot;

    base = base ? base + 1 : path;
    dot = strrchr(base, '.');
    if (!dot || dot == base || !dot[1]) return "";
    return dot + 1;
}

char* spdf_watcher_shadow_copy_name(const char* source_path) {
    char* canonical;
    char* checksum;
    const char* ext;
    char* name;

    if (!source_path || !*source_path) return NULL;
    canonical = g_canonicalize_filename(source_path, "/");
    checksum = g_compute_checksum_for_string(G_CHECKSUM_SHA256, canonical, -1);
    ext = watcher_path_extension(canonical);
    name = g_strdup_printf("ro-%.32s.%s", checksum, *ext ? ext : "pdf");
    g_free(checksum);
    g_free(canonical);
    return name;
}

gboolean spdf_watcher_path_is_shadow_in(const char* path, const char* copies_dir) {
    char* canonical;
    char* dir;
    char* parent;
    char* base;
    gboolean match = FALSE;

    if (!path || !*path || !copies_dir || !*copies_dir) return FALSE;
    canonical = g_canonicalize_filename(path, "/");
    dir = g_canonicalize_filename(copies_dir, "/");
    parent = g_path_get_dirname(canonical);
    base = g_path_get_basename(canonical);
    if (strcmp(parent, dir) == 0 && g_str_has_prefix(base, "ro-")) {
        const char* hex = base + 3;
        int n = 0;
        while (g_ascii_isxdigit(hex[n])) n++;
        match = n == 32 && hex[n] == '.' && hex[n + 1] != '\0';
    }
    g_free(base);
    g_free(parent);
    g_free(dir);
    g_free(canonical);
    return match;
}

gboolean spdf_watcher_read_only_verdict(gboolean exists, gboolean is_regular, gboolean writable) {
    return exists && is_regular && !writable;
}

gboolean spdf_watcher_stat_differs(guint64 a_size, double a_mtime, guint64 b_size, double b_mtime) {
    if (a_size != b_size) return TRUE;
    return fabs(a_mtime - b_mtime) > SPDF_WATCHER_MTIME_TOLERANCE;
}

gboolean spdf_watcher_copy_reusable(gboolean copy_exists, guint64 bound_size, double bound_mtime, guint64 source_size,
                                    double source_mtime) {
    if (!copy_exists || bound_mtime <= 0.0) return FALSE;
    return !spdf_watcher_stat_differs(bound_size, bound_mtime, source_size, source_mtime);
}

gboolean spdf_watcher_sweep_should_delete(gboolean referenced, double copy_mtime, double now) {
    return !referenced && (now - copy_mtime) > SPDF_WATCHER_SWEEP_RECENCY_S;
}

gboolean spdf_watcher_stat_path(const char* path, guint64* size, double* modified_at) {
    GStatBuf st;

    if (!path || !*path || g_stat(path, &st) != 0) return FALSE;
    if (size) *size = (guint64)st.st_size;
#ifdef __linux__
    if (modified_at) *modified_at = (double)st.st_mtim.tv_sec + (double)st.st_mtim.tv_nsec / 1e9;
#else
    if (modified_at) *modified_at = (double)st.st_mtime;
#endif
    return TRUE;
}

gboolean spdf_watcher_source_is_read_only(const char* path) {
    GStatBuf st;
    gboolean exists;
    gboolean regular;

    if (!path || !*path) return FALSE;
    exists = g_stat(path, &st) == 0;
    regular = exists && S_ISREG(st.st_mode);
    return spdf_watcher_read_only_verdict(exists, regular, exists && g_access(path, W_OK) == 0);
}
