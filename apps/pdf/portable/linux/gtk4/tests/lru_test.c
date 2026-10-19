/* LRU eviction accounting tests for the render texture cache
 * (spdf_lru_* in spdf_docview_internal.h, port of the GTK3 minimap
 * thumbnail store generalized to the 96MB decoded-bytes cap). glib-only. */

#include <glib.h>

#include "spdf_docview_internal.h"

static int destroyed_count;

static void counting_destroy(gpointer data) {
    (void)data;
    destroyed_count++;
}

static SpdfLruCache new_cache(gsize cap) {
    SpdfLruCache cache;
    destroyed_count = 0;
    spdf_lru_init(&cache, cap, g_str_hash, g_str_equal, g_free, counting_destroy);
    return cache;
}

static void test_insert_and_lookup(void) {
    SpdfLruCache cache = new_cache(100);
    spdf_lru_insert(&cache, g_strdup("a"), GINT_TO_POINTER(1), 40);
    spdf_lru_insert(&cache, g_strdup("b"), GINT_TO_POINTER(2), 40);
    g_assert_cmpuint(spdf_lru_size(&cache), ==, 2);
    g_assert_cmpuint(spdf_lru_bytes(&cache), ==, 80);
    g_assert_true(spdf_lru_lookup(&cache, "a") == GINT_TO_POINTER(1));
    g_assert_true(spdf_lru_lookup(&cache, "b") == GINT_TO_POINTER(2));
    g_assert_null(spdf_lru_lookup(&cache, "c"));
    spdf_lru_deinit(&cache);
    g_assert_cmpint(destroyed_count, ==, 2);
}

static void test_evicts_least_recently_used(void) {
    SpdfLruCache cache = new_cache(100);
    spdf_lru_insert(&cache, g_strdup("a"), GINT_TO_POINTER(1), 40);
    spdf_lru_insert(&cache, g_strdup("b"), GINT_TO_POINTER(2), 40);
    /* Touch "a" so "b" is the LRU entry. */
    g_assert_nonnull(spdf_lru_lookup(&cache, "a"));
    spdf_lru_insert(&cache, g_strdup("c"), GINT_TO_POINTER(3), 40);
    g_assert_cmpuint(spdf_lru_bytes(&cache), ==, 80);
    g_assert_nonnull(spdf_lru_lookup(&cache, "a"));
    g_assert_null(spdf_lru_lookup(&cache, "b")); /* evicted */
    g_assert_nonnull(spdf_lru_lookup(&cache, "c"));
    g_assert_cmpint(destroyed_count, ==, 1);
    spdf_lru_deinit(&cache);
}

static void test_replace_updates_accounting(void) {
    SpdfLruCache cache = new_cache(100);
    spdf_lru_insert(&cache, g_strdup("a"), GINT_TO_POINTER(1), 40);
    spdf_lru_insert(&cache, g_strdup("a"), GINT_TO_POINTER(9), 60);
    g_assert_cmpuint(spdf_lru_size(&cache), ==, 1);
    g_assert_cmpuint(spdf_lru_bytes(&cache), ==, 60);
    g_assert_true(spdf_lru_lookup(&cache, "a") == GINT_TO_POINTER(9));
    g_assert_cmpint(destroyed_count, ==, 1); /* the replaced value */
    spdf_lru_deinit(&cache);
}

static void test_never_evicts_to_empty(void) {
    SpdfLruCache cache = new_cache(50);
    /* A single entry over the cap stays usable (size > 1 eviction guard,
     * same as minimap_thumbnails_evict_over_budget). */
    spdf_lru_insert(&cache, g_strdup("giant"), GINT_TO_POINTER(1), 5000);
    g_assert_cmpuint(spdf_lru_size(&cache), ==, 1);
    g_assert_nonnull(spdf_lru_lookup(&cache, "giant"));
    /* A second insert evicts down to one entry again. */
    spdf_lru_insert(&cache, g_strdup("next"), GINT_TO_POINTER(2), 5000);
    g_assert_cmpuint(spdf_lru_size(&cache), ==, 1);
    g_assert_nonnull(spdf_lru_lookup(&cache, "next"));
    g_assert_null(spdf_lru_lookup(&cache, "giant"));
    spdf_lru_deinit(&cache);
}

static void test_set_cap_evicts(void) {
    SpdfLruCache cache = new_cache(1000);
    for (int i = 0; i < 10; ++i) {
        char* key = g_strdup_printf("k%d", i);
        spdf_lru_insert(&cache, key, GINT_TO_POINTER(i + 1), 100);
    }
    g_assert_cmpuint(spdf_lru_bytes(&cache), ==, 1000);
    spdf_lru_set_cap(&cache, 300);
    g_assert_cmpuint(spdf_lru_bytes(&cache), <=, 300);
    g_assert_cmpuint(spdf_lru_size(&cache), ==, 3);
    /* The three newest survive. */
    g_assert_nonnull(spdf_lru_lookup(&cache, "k9"));
    g_assert_nonnull(spdf_lru_lookup(&cache, "k8"));
    g_assert_nonnull(spdf_lru_lookup(&cache, "k7"));
    g_assert_null(spdf_lru_lookup(&cache, "k6"));
    spdf_lru_deinit(&cache);
}

static void test_remove_all_resets_accounting(void) {
    SpdfLruCache cache = new_cache(1000);
    spdf_lru_insert(&cache, g_strdup("a"), GINT_TO_POINTER(1), 100);
    spdf_lru_insert(&cache, g_strdup("b"), GINT_TO_POINTER(2), 100);
    spdf_lru_remove_all(&cache);
    g_assert_cmpuint(spdf_lru_size(&cache), ==, 0);
    g_assert_cmpuint(spdf_lru_bytes(&cache), ==, 0);
    g_assert_cmpint(destroyed_count, ==, 2);
    /* Still usable after a clear. */
    spdf_lru_insert(&cache, g_strdup("c"), GINT_TO_POINTER(3), 100);
    g_assert_nonnull(spdf_lru_lookup(&cache, "c"));
    spdf_lru_deinit(&cache);
}

static void test_capped_render_zoom_byte_math(void) {
    /* Under the cap: untouched. */
    g_assert_cmpfloat(spdf_capped_render_zoom(1.0, 612.0, 792.0), ==, 1.0);
    /* Over the cap: scaled so the bitmap lands exactly on the cap. */
    {
        double capped = spdf_capped_render_zoom(2.0, 10900.0, 7539.0);
        double bytes = 10900.0 * 7539.0 * capped * capped * 4.0;
        g_assert_cmpfloat(capped, <, 2.0);
        g_assert_cmpfloat(bytes, <=, (double)SPDF_MAX_RENDER_SURFACE_BYTES * 1.000001);
        g_assert_cmpfloat(bytes, >=, (double)SPDF_MAX_RENDER_SURFACE_BYTES * 0.999);
    }
    /* Degenerate inputs fail open. */
    g_assert_cmpfloat(spdf_capped_render_zoom(0.0, 612.0, 792.0), ==, 0.0);
    g_assert_cmpfloat(spdf_capped_render_zoom(1.0, 0.0, 792.0), ==, 1.0);
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/lru/insert-and-lookup", test_insert_and_lookup);
    g_test_add_func("/lru/evicts-lru", test_evicts_least_recently_used);
    g_test_add_func("/lru/replace-accounting", test_replace_updates_accounting);
    g_test_add_func("/lru/never-empty", test_never_evicts_to_empty);
    g_test_add_func("/lru/set-cap-evicts", test_set_cap_evicts);
    g_test_add_func("/lru/remove-all", test_remove_all_resets_accounting);
    g_test_add_func("/lru/capped-render-zoom", test_capped_render_zoom_byte_math);
    return g_test_run();
}
