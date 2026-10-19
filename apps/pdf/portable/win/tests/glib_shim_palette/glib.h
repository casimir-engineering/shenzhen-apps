/* A glib shim for the PALETTE differential, layered on the shared one.
 *
 * Same arrangement, and same reason, as glib_shim_search/glib.h: the shared
 * portable/win/tests/glib_shim/glib.h must not grow into a glib port, and what
 * the pure half of portable/linux/gtk4/spdf_palette.c needs that the minimap and
 * search differentials do not is exactly the set defined here -- the g_ascii_*
 * classifiers, g_strdup_printf, a REAL string-keyed GHashTable (the open-document
 * dedupe is a set of canonical paths), GString for the snippet builder, and
 * g_canonicalize_filename for the dedupe key.
 *
 * WHAT IS AND IS NOT REAL HERE.
 *   - The g_ascii_* classifiers are glib's own ASCII-only sets, not <ctype.h>:
 *     the port spells the same sets out, and a locale-dependent shim would make
 *     the two sides agree by accident.
 *   - GHashTable is a real, small, string-keyed hash set/map -- enough for
 *     g_hash_table_add / _contains / _size / _unref with g_str_hash and
 *     g_str_equal, which is all the palette's pure half calls. The shared shim
 *     DECLARES g_hash_table_new_full and g_hash_table_size as extern functions,
 *     so those two names are redirected with macros after that declaration is
 *     parsed, exactly as the search shim does for g_array_append_vals.
 *   - g_canonicalize_filename is a LEXICAL canonicalisation of an absolute
 *     POSIX path ("//" collapsed, "." dropped, ".." resolved), which is what
 *     glib does for an absolute path with no symlink resolution. Relative paths
 *     are not handled (glib would prepend `relative_to` or the cwd), and the
 *     differential never passes one.
 *   - Everything is `static`; this header emits nothing another translation
 *     unit could collide with.
 *
 * This is not a glib port and must not grow into one.
 */
#ifndef SPDF_GLIB_SHIM_PALETTE_H
#define SPDF_GLIB_SHIM_PALETTE_H

#include "../glib_shim/glib.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#ifndef __cplusplus
/* spdf_password.h says `static inline`; MSVC's C front end spells it __inline. */
#define inline __inline
#endif

typedef unsigned char guchar;
typedef long long gssize;

/* The shared shim spells g_free as a function-like macro over free(). The
 * palette passes it as a GDestroyNotify (g_hash_table_new_full's key
 * destructor), which needs a real function. Same behaviour, addressable. */
static void g_shim_free(gpointer p) { free(p); }
#undef g_free
#define g_free g_shim_free

/* --- g_ascii_* ------------------------------------------------------------- */

static int g_ascii_isalnum(gchar c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}
static int g_ascii_isspace(gchar c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}
static int g_ascii_isxdigit(gchar c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}
static gchar g_ascii_tolower(gchar c) { return c >= 'A' && c <= 'Z' ? (gchar)(c + ('a' - 'A')) : c; }

static gint g_ascii_strncasecmp(const gchar* a, const gchar* b, gsize n) {
    gsize i;
    for (i = 0; i < n; ++i) {
        int ca = (guchar)g_ascii_tolower(a[i]);
        int cb = (guchar)g_ascii_tolower(b[i]);
        if (ca != cb) return ca - cb;
        if (!ca) return 0;
    }
    return 0;
}

/* --- strings ------------------------------------------------------------- */

static gchar* g_strdup(const gchar* s) {
    size_t n;
    gchar* out;
    if (!s) return NULL;
    n = strlen(s);
    out = (gchar*)malloc(n + 1);
    if (!out) abort();
    memcpy(out, s, n + 1);
    return out;
}

static gchar* g_strdup_printf(const gchar* fmt, ...) {
    va_list ap;
    int n;
    gchar* out;
    va_start(ap, fmt);
    n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n < 0) abort();
    out = (gchar*)malloc((size_t)n + 1);
    if (!out) abort();
    va_start(ap, fmt);
    vsnprintf(out, (size_t)n + 1, fmt, ap);
    va_end(ap);
    return out;
}

static gchar* g_strstrip(gchar* text) {
    size_t len;
    gchar* start;
    if (!text) return NULL;
    start = text;
    while (*start && g_ascii_isspace(*start)) start++;
    if (start != text) memmove(text, start, strlen(start) + 1);
    len = strlen(text);
    while (len > 0 && g_ascii_isspace(text[len - 1])) text[--len] = '\0';
    return text;
}

static int g_strcmp0(const gchar* a, const gchar* b) {
    if (!a) return b ? -1 : 0;
    if (!b) return 1;
    return strcmp(a, b);
}

static gboolean g_str_has_prefix(const gchar* s, const gchar* prefix) {
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

/* Lexical canonicalisation of an ABSOLUTE POSIX path. */
static gchar* g_canonicalize_filename(const gchar* filename, const gchar* relative_to) {
    size_t n = 0;
    const char* p = filename;
    gchar* out = (gchar*)malloc(strlen(filename) + 2);
    (void)relative_to;
    if (!out) abort();
    if (*p != '/') abort(); /* the differential passes absolute paths only */
    out[n++] = '/';
    while (*p == '/') p++;
    while (*p) {
        const char* seg = p;
        size_t len;
        while (*p && *p != '/') p++;
        len = (size_t)(p - seg);
        while (*p == '/') p++;
        if (len == 0 || (len == 1 && seg[0] == '.')) continue;
        if (len == 2 && seg[0] == '.' && seg[1] == '.') {
            if (n > 1) {
                n--;
                while (n > 1 && out[n - 1] != '/') n--;
            }
            continue;
        }
        memcpy(out + n, seg, len);
        n += len;
        out[n++] = '/';
    }
    if (n > 1 && out[n - 1] == '/') n--;
    out[n] = '\0';
    return out;
}

static gchar* g_path_get_basename(const gchar* path) {
    const char* slash = strrchr(path, '/');
    return g_strdup(slash ? slash + 1 : path);
}

/* --- GString --------------------------------------------------------------- */

typedef struct {
    gchar* str;
    gsize len;
    gsize allocated_len;
} GString;

static void g_shim_string_reserve(GString* s, gsize want) {
    if (want < s->allocated_len) return;
    while (s->allocated_len <= want) s->allocated_len *= 2;
    s->str = (gchar*)realloc(s->str, s->allocated_len);
    if (!s->str) abort();
}

static GString* g_string_new(const gchar* init) {
    GString* s = (GString*)calloc(1, sizeof(GString));
    if (!s) abort();
    s->allocated_len = 64;
    s->str = (gchar*)malloc(s->allocated_len);
    if (!s->str) abort();
    s->str[0] = '\0';
    if (init) {
        s->len = strlen(init);
        g_shim_string_reserve(s, s->len);
        memcpy(s->str, init, s->len + 1);
    }
    return s;
}

static GString* g_string_append_len(GString* s, const gchar* text, gssize len) {
    gsize n = len < 0 ? strlen(text) : (gsize)len;
    g_shim_string_reserve(s, s->len + n);
    memcpy(s->str + s->len, text, n);
    s->len += n;
    s->str[s->len] = '\0';
    return s;
}

static GString* g_string_append(GString* s, const gchar* text) { return g_string_append_len(s, text, -1); }

static gchar* g_string_free(GString* s, gboolean free_segment) {
    gchar* str = s->str;
    if (free_segment) {
        free(str);
        str = NULL;
    }
    free(s);
    return str;
}

/* --- a real string-keyed GHashTable ------------------------------------------ */

static guint g_str_hash(gconstpointer v) {
    const guchar* p = (const guchar*)v;
    guint h = 5381;
    for (; *p; ++p) h = (h << 5) + h + *p;
    return h;
}

static gboolean g_str_equal(gconstpointer a, gconstpointer b) { return strcmp((const char*)a, (const char*)b) == 0; }

typedef struct GShimHashNode {
    gpointer key;
    gpointer value;
    struct GShimHashNode* next;
} GShimHashNode;

typedef struct {
    GShimHashNode* buckets[257];
    guint size;
    GHashFunc hash;
    GEqualFunc equal;
    GDestroyNotify key_free;
    GDestroyNotify value_free;
} GShimHashTable;

static GHashTable* g_shim_hash_new_full(GHashFunc hash, GEqualFunc equal, GDestroyNotify key_free,
                                        GDestroyNotify value_free) {
    GShimHashTable* t = (GShimHashTable*)calloc(1, sizeof(GShimHashTable));
    if (!t) abort();
    t->hash = hash;
    t->equal = equal;
    t->key_free = key_free;
    t->value_free = value_free;
    return (GHashTable*)t;
}

static GHashTable* g_hash_table_new(GHashFunc hash, GEqualFunc equal) {
    return g_shim_hash_new_full(hash, equal, NULL, NULL);
}

static GShimHashNode* g_shim_hash_find(GShimHashTable* t, gconstpointer key) {
    GShimHashNode* node = t->buckets[t->hash(key) % 257];
    for (; node; node = node->next)
        if (t->equal(node->key, key)) return node;
    return NULL;
}

static gboolean g_hash_table_contains(GHashTable* table, gconstpointer key) {
    return g_shim_hash_find((GShimHashTable*)table, key) != NULL;
}

/* glib: an existing key is REPLACED, and the passed key is the one that
 * survives (g_hash_table_add frees the old key). */
static gboolean g_hash_table_add(GHashTable* table, gpointer key) {
    GShimHashTable* t = (GShimHashTable*)table;
    GShimHashNode* node = g_shim_hash_find(t, key);
    if (node) {
        if (t->key_free && node->key != key) t->key_free(node->key);
        node->key = key;
        return FALSE;
    }
    node = (GShimHashNode*)calloc(1, sizeof(GShimHashNode));
    if (!node) abort();
    node->key = key;
    {
        guint b = t->hash(key) % 257;
        node->next = t->buckets[b];
        t->buckets[b] = node;
    }
    t->size++;
    return TRUE;
}

static guint g_shim_hash_size(GHashTable* table) { return ((GShimHashTable*)table)->size; }

static void g_hash_table_unref(GHashTable* table) {
    GShimHashTable* t = (GShimHashTable*)table;
    int b;
    if (!t) return;
    for (b = 0; b < 257; ++b) {
        GShimHashNode* node = t->buckets[b];
        while (node) {
            GShimHashNode* next = node->next;
            if (t->key_free) t->key_free(node->key);
            if (t->value_free) t->value_free(node->value);
            free(node);
            node = next;
        }
    }
    free(t);
}

/* Redirect the two names the shared shim declares as extern functions. */
#define g_hash_table_new_full g_shim_hash_new_full
#define g_hash_table_size g_shim_hash_size

#endif /* SPDF_GLIB_SHIM_PALETTE_H */
