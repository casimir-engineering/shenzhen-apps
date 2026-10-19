/* Bounded rendered-page cache conformance for portable/win/src/spdf_win_lru.c.
 *
 * Like layout_geometry_test.c this is both an exit-code test and a transcript:
 * every assertion fails the process, and every observable number is printed in
 * a fixed format so the macOS and Windows builds can be diffed byte for byte by
 * portable/win/tests/t3-verify.sh.
 *
 * The cases mirror portable/linux/gtk4/tests/lru_test.c one for one, because
 * the two caches are required to implement the same policy. Where that file
 * uses string keys and GINT_TO_POINTER values, this one uses real
 * (page, zoom, scale) keys -- the shape the render service actually caches by.
 */
/* spdf-test-sources: portable/win/src/spdf_win_lru.c */

#include <stdio.h>
#include <stdlib.h>

#include "spdf_win_lru.h"

static int failures;
static int destroyed_count;

static void expect(int condition, const char* what) {
    if (!condition) {
        printf("FAIL %s\n", what);
        failures++;
    }
}

static void counting_destroy(void* value) {
    (void)value;
    destroyed_count++;
}

/* Values are non-NULL sentinels derived from the page number; a cache that
 * returns NULL for a present key is indistinguishable from a miss, so no test
 * value is ever NULL. Real storage rather than a cast integer: pointer
 * arithmetic on a null pointer is undefined, and a sanitizer build would be
 * right to say so. */
static char sentinel_storage[128];
static void* sentinel(int n) {
    return &sentinel_storage[(n + 1) % (int)sizeof(sentinel_storage)];
}

static SpdfWinLru new_cache(size_t cap) {
    SpdfWinLru cache;
    destroyed_count = 0;
    spdf_win_lru_init(&cache, cap, counting_destroy);
    return cache;
}

static void report(const char* label, const SpdfWinLru* cache) {
    printf("%-22s size=%llu bytes=%llu cap=%llu destroyed=%d\n", label, (unsigned long long)spdf_win_lru_size(cache),
           (unsigned long long)spdf_win_lru_bytes(cache), (unsigned long long)spdf_win_lru_cap(cache), destroyed_count);
}

static int put(SpdfWinLru* cache, int page, size_t bytes) {
    SpdfWinLruKey key = spdf_win_lru_key(page, 1.0, 2.0);
    return spdf_win_lru_insert(cache, &key, sentinel(page), bytes);
}

static void* get(SpdfWinLru* cache, int page) {
    SpdfWinLruKey key = spdf_win_lru_key(page, 1.0, 2.0);
    return spdf_win_lru_lookup(cache, &key);
}

/* Prints which of pages [0,n) are resident. This walks the table through
 * lookup, so it DOES bump recency, ascending by page. Every call site is at the
 * end of a case for that reason; a case that cared about recency afterwards
 * would want spdf_win_lru_peek instead. */
static void print_membership(const char* label, SpdfWinLru* cache, int n) {
    int i;
    int shown = 0;
    printf("%-22s resident=[", label);
    for (i = 0; i < n; ++i) {
        if (!get(cache, i)) continue;
        printf("%s%d", shown ? "," : "", i);
        shown++;
    }
    printf("]\n");
}

static void test_insert_and_lookup(void) {
    SpdfWinLru cache = new_cache(100);
    expect(put(&cache, 0, 40) == 1, "insert 0 succeeds");
    expect(put(&cache, 1, 40) == 1, "insert 1 succeeds");
    report("insert-and-lookup", &cache);
    expect(spdf_win_lru_size(&cache) == 2, "two entries");
    expect(spdf_win_lru_bytes(&cache) == 80, "80 bytes accounted");
    expect(get(&cache, 0) == sentinel(0), "page 0 round-trips");
    expect(get(&cache, 1) == sentinel(1), "page 1 round-trips");
    expect(get(&cache, 2) == NULL, "absent page misses");
    spdf_win_lru_deinit(&cache);
    expect(destroyed_count == 2, "deinit destroys every value");
    report("after-deinit", &cache);
}

static void test_key_identity(void) {
    SpdfWinLru cache = new_cache(1000);
    SpdfWinLruKey whole = spdf_win_lru_key(3, 1.5, 2.0);
    SpdfWinLruKey crop = spdf_win_lru_key_crop(3, 1.5, 2.0, 0, 100, 800, 600);
    SpdfWinLruKey other_zoom = spdf_win_lru_key(3, 1.75, 2.0);
    SpdfWinLruKey other_scale = spdf_win_lru_key(3, 1.5, 1.0);
    /* Two zooms closer together than the quantum are the same cache entry: the
     * point of quantising is that a scroll-driven hair of zoom drift does not
     * evict the texture it should have reused. */
    SpdfWinLruKey nudged = spdf_win_lru_key(3, 1.5 + 1.0 / (4.0 * SPDF_WIN_LRU_SCALE_QUANTUM), 2.0);

    /* The quantum itself, pinned to a literal. It has to equal
     * SPDF_RENDER_SCALE_QUANTUM in portable/linux/gtk4/spdf_render.c, which is
     * a #define inside a .c file and so cannot be included and compared;
     * asserting the number here is the only way the agreement is checkable at
     * all. Change one and this fails, which is the point. */
    expect(SPDF_WIN_LRU_SCALE_QUANTUM == 4096.0, "the scale quantum matches the GTK render service's");
    expect(spdf_win_lru_key(0, 1.0, 1.0).zoom_q == 4096, "zoom 1.0 quantises to 4096");
    expect(spdf_win_lru_key(0, 0.25, 1.0).zoom_q == 1024, "zoom 0.25 quantises to 1024");
    /* A quarter of a quantum apart collapses; four quanta apart does not. Both
     * deltas are absolute, so shrinking the quantum breaks the second one. */
    expect(spdf_win_lru_key_equal(&whole, &nudged) == 1, "sub-quantum zoom drift is the same key");
    {
        SpdfWinLruKey coarse = spdf_win_lru_key(3, 1.5 + 4.0 / 4096.0, 2.0);
        expect(spdf_win_lru_key_equal(&whole, &coarse) == 0, "a four-quantum zoom step is a different key");
    }
    expect(spdf_win_lru_key_equal(&whole, &crop) == 0, "a crop is a different key");
    expect(spdf_win_lru_key_equal(&whole, &other_zoom) == 0, "another zoom is a different key");
    expect(spdf_win_lru_key_equal(&whole, &other_scale) == 0, "another display scale is a different key");

    spdf_win_lru_insert(&cache, &whole, sentinel(1), 10);
    spdf_win_lru_insert(&cache, &crop, sentinel(2), 20);
    spdf_win_lru_insert(&cache, &other_zoom, sentinel(3), 30);
    spdf_win_lru_insert(&cache, &other_scale, sentinel(4), 40);
    report("key-identity", &cache);
    expect(spdf_win_lru_size(&cache) == 4, "four distinct keys coexist");
    expect(spdf_win_lru_lookup(&cache, &nudged) == sentinel(1), "the nudged key hits the whole-page entry");
    spdf_win_lru_deinit(&cache);
}

static void test_evicts_least_recently_used(void) {
    SpdfWinLru cache = new_cache(100);
    put(&cache, 0, 40);
    put(&cache, 1, 40);
    /* Touch page 0 so page 1 is the least recently used. */
    expect(get(&cache, 0) != NULL, "page 0 present before eviction");
    put(&cache, 2, 40);
    report("lru-eviction", &cache);
    expect(spdf_win_lru_bytes(&cache) == 80, "budget respected");
    expect(get(&cache, 0) != NULL, "recently used survived");
    expect(get(&cache, 1) == NULL, "least recently used evicted");
    expect(get(&cache, 2) != NULL, "new entry present");
    expect(destroyed_count == 1, "exactly one value destroyed");
    print_membership("lru-eviction", &cache, 3);
    spdf_win_lru_deinit(&cache);
}

static void test_replace_updates_accounting(void) {
    SpdfWinLru cache = new_cache(100);
    SpdfWinLruKey key = spdf_win_lru_key(0, 1.0, 2.0);
    spdf_win_lru_insert(&cache, &key, sentinel(0), 40);
    spdf_win_lru_insert(&cache, &key, sentinel(9), 60);
    report("replace", &cache);
    expect(spdf_win_lru_size(&cache) == 1, "replacement is not a second entry");
    expect(spdf_win_lru_bytes(&cache) == 60, "byte total follows the new value");
    expect(spdf_win_lru_lookup(&cache, &key) == sentinel(9), "the new value is what is served");
    expect(destroyed_count == 1, "the replaced value was destroyed");
    spdf_win_lru_deinit(&cache);
}

static void test_never_evicts_to_empty(void) {
    SpdfWinLru cache = new_cache(50);
    /* A single entry over the whole budget stays usable -- otherwise the page
     * being looked at is the one page that can never be cached. */
    put(&cache, 0, 5000);
    report("oversized-single", &cache);
    expect(spdf_win_lru_size(&cache) == 1, "oversized entry is kept");
    expect(get(&cache, 0) != NULL, "oversized entry is servable");
    /* A second insert evicts back down to one entry. */
    put(&cache, 1, 5000);
    report("oversized-second", &cache);
    expect(spdf_win_lru_size(&cache) == 1, "still exactly one entry");
    expect(get(&cache, 1) != NULL, "the newest oversized entry is the survivor");
    expect(get(&cache, 0) == NULL, "the older oversized entry went");
    spdf_win_lru_deinit(&cache);
}

static void test_set_cap_evicts_now(void) {
    SpdfWinLru cache = new_cache(1000);
    int i;
    for (i = 0; i < 10; ++i) put(&cache, i, 100);
    report("before-set-cap", &cache);
    expect(spdf_win_lru_bytes(&cache) == 1000, "full to the budget");
    spdf_win_lru_set_cap(&cache, 300);
    report("after-set-cap", &cache);
    expect(spdf_win_lru_bytes(&cache) <= 300, "shrinking the cap evicts immediately");
    expect(spdf_win_lru_size(&cache) == 3, "down to three entries");
    print_membership("after-set-cap", &cache, 10);
    expect(get(&cache, 9) != NULL, "newest kept");
    expect(get(&cache, 8) != NULL, "second newest kept");
    expect(get(&cache, 7) != NULL, "third newest kept");
    expect(get(&cache, 6) == NULL, "fourth newest evicted");
    spdf_win_lru_deinit(&cache);
}

static void test_remove_and_clear(void) {
    SpdfWinLru cache = new_cache(1000);
    SpdfWinLruKey key = spdf_win_lru_key(0, 1.0, 2.0);
    put(&cache, 0, 100);
    put(&cache, 1, 100);
    spdf_win_lru_remove(&cache, &key);
    report("after-remove", &cache);
    expect(spdf_win_lru_size(&cache) == 1, "remove drops exactly one");
    expect(spdf_win_lru_bytes(&cache) == 100, "remove refunds its bytes");
    expect(destroyed_count == 1, "remove destroys the value");
    spdf_win_lru_remove_all(&cache);
    report("after-remove-all", &cache);
    expect(spdf_win_lru_size(&cache) == 0, "clear empties the cache");
    expect(spdf_win_lru_bytes(&cache) == 0, "clear resets the byte total");
    expect(destroyed_count == 2, "clear destroys what was left");
    /* Still usable after a clear. */
    put(&cache, 5, 100);
    expect(get(&cache, 5) != NULL, "cache works again after a clear");
    spdf_win_lru_deinit(&cache);
}

/* A long scripted workload: many more pages than fit, interleaved lookups, a
 * cap change in the middle. It exists to exercise table growth, tombstone
 * reclamation and repeated eviction, and its transcript is the part of this
 * file most likely to catch a divergence between the two toolchains. */
static void test_scripted_workload(void) {
    SpdfWinLru cache = new_cache(SPDF_WIN_MAX_RENDER_SURFACE_BYTES);
    unsigned int seed = 0x5eed1234u;
    int step;

    for (step = 0; step < 400; ++step) {
        int page;
        seed = seed * 1103515245u + 12345u;
        page = (int)((seed >> 16) % 64u);
        if (step % 7 == 3) {
            get(&cache, page);
        } else {
            put(&cache, page, spdf_win_lru_bitmap_bytes(1224 + page * 8, 1584));
        }
        if (step == 199) spdf_win_lru_set_cap(&cache, 32u * 1024u * 1024u);
        if (step % 50 == 49) report("workload", &cache);
    }
    print_membership("workload", &cache, 64);
    expect(spdf_win_lru_bytes(&cache) <= spdf_win_lru_cap(&cache) || spdf_win_lru_size(&cache) == 1,
           "workload ends inside the budget");
    expect(spdf_win_lru_size(&cache) > 0, "workload did not evict to empty");
    spdf_win_lru_deinit(&cache);
}

static void test_bitmap_byte_cost(void) {
    printf("bitmap letter@2x=%llu sheet@1x=%llu degenerate=%llu\n",
           (unsigned long long)spdf_win_lru_bitmap_bytes(1224, 1584),
           (unsigned long long)spdf_win_lru_bitmap_bytes(10900, 7539),
           (unsigned long long)spdf_win_lru_bitmap_bytes(-1, 100));
    expect(spdf_win_lru_bitmap_bytes(1224, 1584) == (size_t)1224 * 1584 * 4, "4 bytes per pixel");
    expect(spdf_win_lru_bitmap_bytes(0, 100) == 0, "a zero dimension costs nothing");
    expect(spdf_win_lru_bitmap_bytes(-1, 100) == 0, "a negative dimension costs nothing");
}

/* THE STAND-IN LOOKUP. Windows-only, like spdf_win_lru_peek: the GTK cache has
 * no equivalent because GTK never draws a page at a zoom it did not ask for.
 * It is what lets the canvas render the visible page off-thread and still hand
 * back a frame with no hole in it, so its answer has to be exactly specified --
 * nearest zoom, sharper on a tie, never a crop, never another page or scale. */
static void test_nearest_zoom_stand_in(void) {
    SpdfWinLru cache = new_cache(1000);
    SpdfWinLruKey half = spdf_win_lru_key(4, 0.5, 2.0);
    SpdfWinLruKey two = spdf_win_lru_key(4, 2.0, 2.0);
    SpdfWinLruKey crop = spdf_win_lru_key_crop(4, 1.0, 2.0, 0, 0, 400, 300);
    SpdfWinLruKey other_page = spdf_win_lru_key(5, 1.0, 2.0);
    SpdfWinLruKey other_scale = spdf_win_lru_key(4, 1.0, 1.0);
    SpdfWinLruKey found;

    expect(spdf_win_lru_lookup_nearest_zoom(&cache, 4, 2.0, 1.0, &found) == NULL, "an empty cache has no stand-in");
    spdf_win_lru_insert(&cache, &crop, sentinel(9), 10);
    spdf_win_lru_insert(&cache, &other_page, sentinel(8), 10);
    spdf_win_lru_insert(&cache, &other_scale, sentinel(7), 10);
    expect(spdf_win_lru_lookup_nearest_zoom(&cache, 4, 2.0, 1.0, &found) == NULL,
           "a crop, another page and another scale are not stand-ins for this page");

    spdf_win_lru_insert(&cache, &half, sentinel(1), 10);
    expect(spdf_win_lru_lookup_nearest_zoom(&cache, 4, 2.0, 1.0, &found) == sentinel(1),
           "the only cached zoom stands in");
    expect(found.zoom_q == spdf_win_lru_key(4, 0.5, 2.0).zoom_q, "and says which zoom it was");
    spdf_win_lru_insert(&cache, &two, sentinel(2), 10);
    expect(spdf_win_lru_lookup_nearest_zoom(&cache, 4, 2.0, 1.75, &found) == sentinel(2), "2.0 is nearer 1.75 than 0.5");
    expect(spdf_win_lru_lookup_nearest_zoom(&cache, 4, 2.0, 0.75, &found) == sentinel(1), "0.5 is nearer 0.75 than 2.0");
    /* Equidistant: 1.25 is 0.75 from both. The sharper texture wins, because
     * downsampling a bigger one beats magnifying a smaller one. */
    expect(spdf_win_lru_lookup_nearest_zoom(&cache, 4, 2.0, 1.25, &found) == sentinel(2),
           "a tie picks the sharper texture");
    /* An EXACT hit is still just the nearest, and the returned key is how a
     * caller tells the two apart. */
    expect(spdf_win_lru_lookup_nearest_zoom(&cache, 4, 2.0, 2.0, &found) == sentinel(2), "an exact zoom is the nearest");
    expect(found.zoom_q == two.zoom_q, "the exact key comes back");
    /* It bumps recency like a lookup, so a stand-in in use is not the next
     * victim: page 4 at 2.0 was just touched, so shrinking to one entry keeps
     * it and drops everything else. */
    spdf_win_lru_set_cap(&cache, 10);
    report("nearest-zoom", &cache);
    expect(spdf_win_lru_peek(&cache, &two) == 1, "the stand-in that was touched survived the squeeze");
    spdf_win_lru_deinit(&cache);
}

int main(void) {
    printf("== spdf_win_lru transcript ==\n");
    test_insert_and_lookup();
    test_key_identity();
    test_evicts_least_recently_used();
    test_replace_updates_accounting();
    test_never_evicts_to_empty();
    test_set_cap_evicts_now();
    test_remove_and_clear();
    test_scripted_workload();
    test_nearest_zoom_stand_in();
    test_bitmap_byte_cost();
    printf("== %d failures ==\n", failures);
    return failures == 0 ? 0 : 1;
}
