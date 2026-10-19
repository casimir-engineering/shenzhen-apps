/* A glib shim for the SEARCH differential, layered on the minimap one.
 *
 * WHY A SECOND DIRECTORY RATHER THAN A BIGGER SHIM.
 * portable/win/tests/glib_shim/glib.h says in its own header comment that it
 * "is NOT a glib port and must never grow into one", and it is explicit that
 * GArray is DECLARED and never defined because the functions that touch it are
 * unreachable from the minimap differential. That is no longer true for search:
 * portable/linux/gtk4/spdf_search_internal.h's match list IS a GArray, and its
 * counter, query and snippet helpers need g_strlcpy, g_snprintf, g_strdup,
 * g_strndup and g_strstrip.
 *
 * So this file adds exactly those, and adds them HERE rather than there, for two
 * reasons. The shared shim is compiled into the minimap differential and into
 * whatever unblocks layout.differential next, and a real GArray in it would be
 * dead code in both. And the shared file is the one another track is most likely
 * to be editing at the same time as this one.
 *
 * The include path decides which of the two is `<glib.h>`: the search
 * differential's .cmd puts THIS directory first, and this file reaches the
 * shared one by relative path for the typedefs, TRUE/FALSE, MAX/MIN/CLAMP and
 * g_free/g_new -- so glib's macro bodies are still defined in exactly one place
 * and cannot drift between the two differentials.
 *
 * WHAT IS AND IS NOT REAL HERE.
 *   - GArray is real: `data` and `len` are its two public fields, and
 *     g_array_index / g_array_append_val are glib's own macros over them. What
 *     is NOT reproduced is glib's zero_terminated flag and its OOM abort; the
 *     search header passes zero_terminated = FALSE and never observes an OOM,
 *     which the differential's own allocations make certain.
 *   - g_strlcpy is the real truncating semantic (copy at most len-1 bytes and
 *     always NUL-terminate), because spdf_search_counter_text relies on it and
 *     the port's replacement is checked against it.
 *   - g_strstrip strips glib's g_ascii_isspace set, NOT isspace(): the port
 *     spells that set out for the same reason, and a locale-dependent shim here
 *     would make the differential agree by accident.
 *   - Everything is `static`, so this header emits nothing a second translation
 *     unit could collide with. g_array_append_vals is the one name the shared
 *     shim already DECLARES as an extern function, so it is redirected with a
 *     macro after that declaration has been parsed rather than redefined.
 *
 * Same rule as the shared shim: this is not a glib port and must not grow into
 * one. Anything beyond what spdf_search_internal.h touches belongs in a test
 * that links real glib on a host that has it.
 */
#ifndef SPDF_GLIB_SHIM_SEARCH_H
#define SPDF_GLIB_SHIM_SEARCH_H

#include "../glib_shim/glib.h"

#include <float.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#ifndef G_MAXINT
#define G_MAXINT INT_MAX
#endif
#ifndef G_MAXDOUBLE
#define G_MAXDOUBLE DBL_MAX
#endif
#ifndef G_PRIORITY_DEFAULT
#define G_PRIORITY_DEFAULT 0
#endif

/* --- strings ------------------------------------------------------------- */

static gchar* g_strdup(const gchar* s) {
    size_t n;
    gchar* out;
    if (!s) return NULL;
    n = strlen(s);
    out = (gchar*)malloc(n + 1);
    if (!out) return NULL;
    memcpy(out, s, n + 1);
    return out;
}

static gchar* g_strndup(const gchar* s, gsize n) {
    gchar* out = (gchar*)malloc(n + 1);
    if (!out) return NULL;
    if (n) memcpy(out, s, n);
    out[n] = '\0';
    return out;
}

/* glib's semantics: at most dest_size-1 bytes copied, always NUL-terminated,
 * returns the length of src. */
static gsize g_strlcpy(gchar* dest, const gchar* src, gsize dest_size) {
    gsize n = strlen(src);
    if (dest_size > 0) {
        gsize copy = n < dest_size - 1 ? n : dest_size - 1;
        if (copy) memcpy(dest, src, copy);
        dest[copy] = '\0';
    }
    return n;
}

/* The shared shim maps g_snprintf onto C99 snprintf with a macro. Defined here
 * only if it has not, and always through a differently-named function plus an
 * alias, so whichever spelling arrives first wins and neither breaks the other.
 * A `static int g_snprintf(...)` would be macro-expanded into a redefinition of
 * snprintf itself the moment the shared shim defines that macro. */
#ifndef g_snprintf
static int g_shim_snprintf(gchar* dest, gsize n, const gchar* fmt, ...) {
    int written;
    va_list ap;
    va_start(ap, fmt);
    written = vsnprintf(dest, (size_t)n, fmt, ap);
    va_end(ap);
    return written;
}
#define g_snprintf g_shim_snprintf
#endif

static int g_shim_ascii_isspace(gchar c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}

static gchar* g_strstrip(gchar* text) {
    size_t len;
    gchar* start;
    if (!text) return NULL;
    start = text;
    while (*start && g_shim_ascii_isspace(*start)) start++;
    if (start != text) memmove(text, start, strlen(start) + 1);
    len = strlen(text);
    while (len > 0 && g_shim_ascii_isspace(text[len - 1])) text[--len] = '\0';
    return text;
}

/* --- GArray ------------------------------------------------------------- */

/* glib's own public layout (glib/garray.h): only these two fields are ABI. */
struct _GArray {
    gchar* data;
    guint len;
};

typedef struct {
    GArray pub;
    guint capacity;
    guint element_size;
    gboolean clear;
} GShimArray;

static GArray* g_array_new(gboolean zero_terminated, gboolean clear, guint element_size) {
    GShimArray* a = (GShimArray*)calloc(1, sizeof(GShimArray));
    (void)zero_terminated; /* the search header always passes FALSE */
    if (!a) return NULL;
    a->element_size = element_size;
    a->clear = clear;
    return &a->pub;
}

static void g_shim_array_reserve(GShimArray* a, guint want) {
    guint capacity = a->capacity ? a->capacity : 64u;
    gchar* grown;
    if (want <= a->capacity) return;
    while (capacity < want) capacity *= 2u;
    grown = (gchar*)realloc(a->pub.data, (size_t)capacity * a->element_size);
    if (!grown) abort(); /* glib aborts on OOM; matching it keeps the two sides equal */
    a->pub.data = grown;
    if (a->clear)
        memset(grown + (size_t)a->capacity * a->element_size, 0,
               (size_t)(capacity - a->capacity) * a->element_size);
    a->capacity = capacity;
}

static void g_shim_array_append_vals(GArray* array, gconstpointer data, guint len) {
    GShimArray* a = (GShimArray*)array;
    if (!a || len == 0) return;
    g_shim_array_reserve(a, a->pub.len + len);
    memcpy(a->pub.data + (size_t)a->pub.len * a->element_size, data, (size_t)len * a->element_size);
    a->pub.len += len;
}

static void g_array_set_size(GArray* array, guint length) {
    GShimArray* a = (GShimArray*)array;
    if (!a) return;
    if (length > a->pub.len) {
        g_shim_array_reserve(a, length);
        if (a->clear)
            memset(a->pub.data + (size_t)a->pub.len * a->element_size, 0,
                   (size_t)(length - a->pub.len) * a->element_size);
    }
    a->pub.len = length;
}

static gchar* g_array_free(GArray* array, gboolean free_segment) {
    GShimArray* a = (GShimArray*)array;
    gchar* data;
    if (!a) return NULL;
    data = a->pub.data;
    if (free_segment) {
        free(data);
        data = NULL;
    }
    free(a);
    return data;
}

/* The shared shim declares g_array_append_vals as an extern function. Redirect
 * the NAME after that declaration is parsed rather than defining it, so nothing
 * here needs external linkage. */
#define g_array_append_vals g_shim_array_append_vals
#define g_array_index(a, t, i) (((t*)(void*)(a)->data)[(i)])
#define g_array_append_val(a, v) g_array_append_vals(a, &(v), 1)

#endif /* SPDF_GLIB_SHIM_SEARCH_H */
