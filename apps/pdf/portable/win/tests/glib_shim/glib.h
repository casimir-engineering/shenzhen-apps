/* A glib shim, just wide enough to compile the GTK4 frontend's PURE headers
 * with MSVC on Windows.
 *
 * WHY THIS EXISTS. portable/win/tests/gtk_differential.c -- the strongest test
 * in the Windows port, because it compares a port against the implementation it
 * was transcribed from rather than against what its author remembered -- is
 * macOS/Linux-only, and `run-tests-native.sh` records it BLOCKED with
 * "needs glib and the GTK4 headers". That block is real for glib the LIBRARY.
 * It is not real for the two headers this port actually transcribes:
 * spdf_docview_internal.h and spdf_minimap_internal.h use glib for its integer
 * typedefs, its MAX/MIN/CLAMP macros and g_new0/g_free, and nothing else that
 * the pure functions touch.
 *
 * So the differential can run natively. Both implementations are compiled by the
 * SAME compiler into the SAME binary, which makes it a purer transcription check
 * than the cross-toolchain one: any difference is a transcription error and
 * cannot be a floating-point difference between two compilers.
 *
 * WHAT IS AND IS NOT REAL HERE.
 *   - The typedefs, TRUE/FALSE and the MAX/MIN/CLAMP macros are glib's OWN
 *     definitions, character for character, including the comparison order that
 *     decides CLAMP(x, lo, hi) with hi < lo and MAX(NaN, b). Getting these
 *     wrong would make the differential lie, so they are copied rather than
 *     re-derived -- the same fidelity spdf_win_layout.h's header comment
 *     documents for its inline versions.
 *   - g_new/g_new0/g_free/g_malloc are real, over malloc/calloc/free. glib
 *     ABORTS on OOM where these return NULL; the ported header documents that
 *     as its one behavioural difference, and no test here exercises OOM.
 *   - GHashTable, GArray and their functions are DECLARED and never defined.
 *     They are reached only from `static inline` functions this differential
 *     does not call (spdf_lru_*, spdf_cursor_region_append_rect), so they
 *     compile and are never emitted. If a future differential wants the LRU,
 *     it needs real glib or a real hash table -- not a bigger shim.
 *
 * This file is NOT a glib port and must never grow into one. It exists so that
 * `spdf_minimap_internal.h` can be compiled on Windows; anything beyond that
 * belongs in a test that links real glib on a host that has it.
 */
#ifndef SPDF_GLIB_SHIM_H
#define SPDF_GLIB_SHIM_H

#include <stddef.h>
#include <stdlib.h>

#ifdef __cplusplus
#define G_BEGIN_DECLS extern "C" {
#define G_END_DECLS }
#else
#define G_BEGIN_DECLS
#define G_END_DECLS
#endif

typedef int gboolean;
typedef int gint;
typedef unsigned int guint;
typedef unsigned long long guint64;
typedef long long gint64;
typedef double gdouble;
typedef float gfloat;
typedef char gchar;
typedef size_t gsize;
typedef void* gpointer;
typedef const void* gconstpointer;

#ifndef TRUE
#define TRUE 1
#endif
#ifndef FALSE
#define FALSE 0
#endif

/* glib's own macro bodies (glib/gmacros.h). The comparison order matters at the
 * edges and is part of what the differential is checking. */
#undef MAX
#undef MIN
#undef ABS
#undef CLAMP
#define MAX(a, b) (((a) > (b)) ? (a) : (b))
#define MIN(a, b) (((a) < (b)) ? (a) : (b))
#define ABS(a) (((a) < 0) ? -(a) : (a))
#define CLAMP(x, low, high) (((x) > (high)) ? (high) : (((x) < (low)) ? (low) : (x)))

#define g_malloc(n) malloc((size_t)(n))
#define g_malloc0(n) calloc(1, (size_t)(n))
#define g_free(p) free(p)
#define g_new(type, n) ((type*)malloc(sizeof(type) * (size_t)(n)))
#define g_new0(type, n) ((type*)calloc((size_t)(n), sizeof(type)))

/* glib's own definition (gmacros.h), character for character. */
#define G_N_ELEMENTS(arr) (sizeof(arr) / sizeof((arr)[0]))

/* glib documents g_snprintf as returning the number of bytes that WOULD have
 * been written, i.e. C99 snprintf semantics -- which MSVC's snprintf has had
 * since VS2015, unlike its older _snprintf. So this is a real equivalence and
 * not an approximation. The differential only uses it to build failure
 * messages, so even a divergence could not change a comparison; mapping it
 * correctly anyway costs nothing and keeps the "nothing here lies" property
 * this file's header claims. */
#define g_snprintf snprintf

/* Declared, never defined -- see this file's header comment. */
typedef struct _GHashTable GHashTable;
typedef struct _GArray GArray;
typedef guint (*GHashFunc)(gconstpointer key);
typedef gboolean (*GEqualFunc)(gconstpointer a, gconstpointer b);
typedef void (*GDestroyNotify)(gpointer data);

typedef struct {
    gpointer dummy1;
    gpointer dummy2;
    gpointer dummy3;
    int dummy4;
    gboolean dummy5;
    gpointer dummy6;
} GHashTableIter;

G_BEGIN_DECLS

GHashTable* g_hash_table_new_full(GHashFunc hash, GEqualFunc equal, GDestroyNotify key_free, GDestroyNotify val_free);
void g_hash_table_destroy(GHashTable* table);
guint g_hash_table_size(GHashTable* table);
gpointer g_hash_table_lookup(GHashTable* table, gconstpointer key);
gboolean g_hash_table_insert(GHashTable* table, gpointer key, gpointer value);
gboolean g_hash_table_remove(GHashTable* table, gconstpointer key);
void g_hash_table_remove_all(GHashTable* table);
void g_hash_table_iter_init(GHashTableIter* iter, GHashTable* table);
gboolean g_hash_table_iter_next(GHashTableIter* iter, gpointer* key, gpointer* value);
void g_array_append_vals(GArray* array, gconstpointer data, guint len);

G_END_DECLS

#endif /* SPDF_GLIB_SHIM_H */
