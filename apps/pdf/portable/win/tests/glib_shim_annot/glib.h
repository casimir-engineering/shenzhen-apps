/* The annotations differential's glib: what portable/linux/gtk4/spdf_annot.c
 * sections 1 and 2 need under SPDF_ANNOT_TESTING, layered on the search shim
 * (g_strdup, g_strstrip) which layers on the base shim (typedefs, TRUE/FALSE,
 * g_free, G_BEGIN_DECLS).
 *
 * Section 1 is the pure path/preflight logic the differential compares;
 * section 2 is its probing wrappers (g_access, g_get_tmp_dir, ...), which
 * compile but are not compared -- they are given stubs so the translation
 * unit links, nothing more.
 *
 * TWO DELIBERATE DEFINITIONS, both stated in spdf_win_annot_model.h's header:
 *
 *   - g_canonicalize_filename is g_strdup. The port compares paths as given
 *     (the caller canonicalises with GetFullPathNameW), so the GTK side must
 *     see the same bytes for the CONTAINMENT rule to be what is compared.
 *   - G_DIR_SEPARATOR is '/', the original's Linux value. The port accepts
 *     both separators; the differential feeds forward-slash paths, on which
 *     the two agree by construction, and annot_model_test.c pins the
 *     backslash acceptance.
 */
#ifndef SPDF_GLIB_SHIM_ANNOT_H
#define SPDF_GLIB_SHIM_ANNOT_H

#include "../glib_shim_search/glib.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define G_DIR_SEPARATOR '/'
#define G_DIR_SEPARATOR_S "/"

static int g_ascii_strcasecmp(const gchar* a, const gchar* b) {
    for (;; ++a, ++b) {
        int ca = (unsigned char)*a, cb = (unsigned char)*b;
        if (ca >= 'A' && ca <= 'Z') ca += 'a' - 'A';
        if (cb >= 'A' && cb <= 'Z') cb += 'a' - 'A';
        if (ca != cb) return ca - cb;
        if (!ca) return 0;
    }
}

static gchar* g_canonicalize_filename(const gchar* filename, const gchar* relative_to) {
    (void)relative_to;
    return g_strdup(filename);
}

static gboolean g_str_has_prefix(const gchar* str, const gchar* prefix) {
    return strncmp(str, prefix, strlen(prefix)) == 0;
}

static gchar* g_strdup_printf(const gchar* fmt, ...) {
    va_list ap;
    int n;
    gchar* out;
    va_start(ap, fmt);
    n = _vscprintf(fmt, ap);
    va_end(ap);
    if (n < 0) return NULL;
    out = (gchar*)malloc((size_t)n + 1);
    if (!out) return NULL;
    va_start(ap, fmt);
    vsnprintf(out, (size_t)n + 1, fmt, ap);
    va_end(ap);
    return out;
}

/* glib's g_path_get_basename, Unix build: "." for "", the separator for a
 * run of separators, else the last component with trailing separators cut. */
static gchar* g_path_get_basename(const gchar* file_name) {
    size_t end, start;
    gchar* out;
    if (!file_name || !*file_name) return g_strdup(".");
    end = strlen(file_name);
    while (end > 0 && file_name[end - 1] == G_DIR_SEPARATOR) --end;
    if (end == 0) return g_strdup(G_DIR_SEPARATOR_S);
    start = end;
    while (start > 0 && file_name[start - 1] != G_DIR_SEPARATOR) --start;
    out = (gchar*)malloc(end - start + 1);
    if (!out) return NULL;
    memcpy(out, file_name + start, end - start);
    out[end - start] = '\0';
    return out;
}

/* Section 2's probes: present so the unit compiles; never compared. */
static gchar* g_path_get_dirname(const gchar* file_name) {
    (void)file_name;
    return g_strdup(".");
}
static const gchar* g_get_tmp_dir(void) { return "/tmp"; }
static const gchar* g_get_user_runtime_dir(void) { return "/run/user/1000"; }
static int g_access(const gchar* filename, int mode) {
    (void)filename;
    (void)mode;
    return -1;
}

#endif /* SPDF_GLIB_SHIM_ANNOT_H */
