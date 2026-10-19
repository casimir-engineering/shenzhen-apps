#include "spdf_update_version.h"

static gboolean version_components(const char* version, GArray* out) {
    const char* p = version;
    gboolean any = FALSE;

    if (!p || !*p) return FALSE;
    while (*p) {
        char* end = NULL;
        gint64 value;

        while (*p == '.' || *p == '-' || *p == ' ') p++;
        if (!*p) break;
        value = g_ascii_strtoll(p, &end, 10);
        if (end == p) return FALSE;
        if (*end && *end != '.' && *end != '-' && *end != ' ') return FALSE;
        g_array_append_val(out, value);
        any = TRUE;
        p = end;
    }
    return any;
}

int spdf_updater_compare_versions(const char* a, const char* b) {
    GArray* ca = g_array_new(FALSE, FALSE, sizeof(gint64));
    GArray* cb = g_array_new(FALSE, FALSE, sizeof(gint64));
    int result = 0;

    if (version_components(a, ca) && version_components(b, cb)) {
        guint n = MAX(ca->len, cb->len);
        for (guint i = 0; i < n && result == 0; ++i) {
            gint64 va = i < ca->len ? g_array_index(ca, gint64, i) : 0;
            gint64 vb = i < cb->len ? g_array_index(cb, gint64, i) : 0;
            if (va < vb)
                result = -1;
            else if (va > vb)
                result = 1;
        }
    }
    g_array_unref(ca);
    g_array_unref(cb);
    return result;
}

gboolean spdf_updater_versions_match_primary(const char* a, const char* b) {
    GArray* ca = g_array_new(FALSE, FALSE, sizeof(gint64));
    GArray* cb = g_array_new(FALSE, FALSE, sizeof(gint64));
    gboolean match = FALSE;

    if (version_components(a, ca) && version_components(b, cb) && ca->len >= 3 && cb->len >= 3) {
        match = g_array_index(ca, gint64, 0) == g_array_index(cb, gint64, 0) &&
                g_array_index(ca, gint64, 1) == g_array_index(cb, gint64, 1) &&
                g_array_index(ca, gint64, 2) == g_array_index(cb, gint64, 2);
    }
    g_array_unref(ca);
    g_array_unref(cb);
    return match;
}

gboolean spdf_update_versions_match_release_target(const char* target, const char* running) {
    GArray* target_components = g_array_new(FALSE, FALSE, sizeof(gint64));
    GArray* running_components = g_array_new(FALSE, FALSE, sizeof(gint64));
    gboolean match = FALSE;

    if (version_components(target, target_components) && version_components(running, running_components) &&
        target_components->len == 4 && running_components->len == 4) {
        match = TRUE;
        for (guint i = 0; i < 4 && match; ++i) {
            match = g_array_index(target_components, gint64, i) == g_array_index(running_components, gint64, i);
        }
    }
    g_array_unref(target_components);
    g_array_unref(running_components);
    return match;
}
