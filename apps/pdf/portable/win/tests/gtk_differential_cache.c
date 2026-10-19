/* The cache half of the differential: portable/win/src/spdf_win_lru.c against
 * the GTK4 spdf_lru_* it was ported from. See gtk_differential.h for why this
 * is a separate translation unit, and gtk_differential.c for the layout half
 * and for `main`.
 *
 * The two caches cannot share a key type -- GTK's is a void* into a GHashTable,
 * the port's is a value struct -- so page N maps to the string "N" on the GTK
 * side and to spdf_win_lru_key(N, 1, 1) on the port side, and both are driven
 * through the SAME operation script. What is compared is the POLICY: entry
 * count, byte total, destroy count and, at each checkpoint, exactly which pages
 * are resident.
 */

#include <glib.h>
#include <stdio.h>

#include "spdf_docview_internal.h" /* the GTK4 original */
#include "spdf_win_lru.h"          /* the port */

#include "gtk_differential.h"

static int win_destroyed;
static int gtk_destroyed;
static char cache_sentinels[128];

static void win_destroy(void* v) {
    (void)v;
    win_destroyed++;
}
static void gtk_destroy(gpointer v) {
    (void)v;
    gtk_destroyed++;
}

#define CACHE_PAGES 48

/* Compares the two caches' observable state.
 *
 * `touch` says whether the residency sweep is allowed to go through lookup,
 * which BUMPS RECENCY on both. That distinction matters: a sweep after every
 * step keeps recency pinned to page order on both sides and hides a cache that
 * has stopped tracking recency at all (a lookup that forgets to bump turns LRU
 * into FIFO, and a mutant doing exactly that survived the first version of this
 * test). With touch=0 the sweep reads the tables directly and the workload's
 * own access pattern is the only thing setting recency. */
static void compare_caches(const char* label, SpdfWinLru* win, SpdfLruCache* gtk, int touch) {
    int page;
    spdf_diff_same_i("cache size", (long long)spdf_win_lru_size(win), (long long)spdf_lru_size(gtk));
    spdf_diff_same_i("cache bytes", (long long)spdf_win_lru_bytes(win), (long long)spdf_lru_bytes(gtk));
    spdf_diff_same_i("cache destroyed", win_destroyed, gtk_destroyed);
    for (page = 0; page < CACHE_PAGES; ++page) {
        SpdfWinLruKey key = spdf_win_lru_key(page, 1.0, 1.0);
        char text[16];
        int wpresent;
        int gpresent;
        g_snprintf(text, sizeof(text), "%d", page);
        if (touch) {
            wpresent = spdf_win_lru_lookup(win, &key) != NULL;
            gpresent = spdf_lru_lookup(gtk, text) != NULL;
        } else {
            wpresent = spdf_win_lru_peek(win, &key);
            gpresent = g_hash_table_lookup(gtk->table, text) != NULL;
        }
        if (wpresent != gpresent) {
            char detail[96];
            g_snprintf(detail, sizeof(detail), "residency of page %d: win=%d gtk=%d", page, wpresent, gpresent);
            spdf_diff_report(label, detail);
        }
        spdf_diff_comparisons++;
    }
}

/* The recency rule on its own, mirroring
 * portable/linux/gtk4/tests/lru_test.c test_evicts_least_recently_used: three
 * entries, a budget for two, and a lookup deciding which of the first two
 * survives. If lookup stops bumping recency, this is what notices. */
void differential_cache_recency(void) {
    SpdfWinLru win;
    SpdfLruCache gtk;
    int touched;

    for (touched = 0; touched < 2; ++touched) {
        SpdfWinLruKey k0 = spdf_win_lru_key(0, 1.0, 1.0);
        SpdfWinLruKey k1 = spdf_win_lru_key(1, 1.0, 1.0);
        SpdfWinLruKey k2 = spdf_win_lru_key(2, 1.0, 1.0);
        win_destroyed = 0;
        gtk_destroyed = 0;
        spdf_win_lru_init(&win, 100, win_destroy);
        spdf_lru_init(&gtk, 100, g_str_hash, g_str_equal, g_free, gtk_destroy);

        spdf_win_lru_insert(&win, &k0, &cache_sentinels[0], 40);
        spdf_lru_insert(&gtk, g_strdup("0"), &cache_sentinels[0], 40);
        spdf_win_lru_insert(&win, &k1, &cache_sentinels[1], 40);
        spdf_lru_insert(&gtk, g_strdup("1"), &cache_sentinels[1], 40);
        /* touched==1: read page 0 so page 1 becomes the least recently used.
         * touched==0: read nothing, so page 0 is still the oldest. The two runs
         * must evict DIFFERENT pages, and both caches must agree on which. */
        if (touched) {
            spdf_win_lru_lookup(&win, &k0);
            spdf_lru_lookup(&gtk, "0");
        }
        spdf_win_lru_insert(&win, &k2, &cache_sentinels[2], 40);
        spdf_lru_insert(&gtk, g_strdup("2"), &cache_sentinels[2], 40);
        compare_caches(touched ? "recency-touched" : "recency-untouched", &win, &gtk, 0);
        /* And the eviction actually depended on the touch, or the case proves
         * nothing about recency. */
        spdf_diff_same_i("recency victim", spdf_win_lru_peek(&win, touched ? &k1 : &k0), 0);
        spdf_diff_same_i("recency survivor", spdf_win_lru_peek(&win, touched ? &k0 : &k1), 1);

        spdf_win_lru_deinit(&win);
        spdf_lru_deinit(&gtk);
    }
}

void differential_cache(void) {
    SpdfWinLru win;
    SpdfLruCache gtk;
    unsigned int seed = 0x5eed1234u;
    int step;

    /* A budget that holds roughly fifteen of these entries. Too small a budget
     * makes every eviction forced, which is the same reason a two-entry cache
     * cannot distinguish LRU from any other policy. */
    win_destroyed = 0;
    gtk_destroyed = 0;
    spdf_win_lru_init(&win, 24u * 1024u * 1024u, win_destroy);
    spdf_lru_init(&gtk, (gsize)(24u * 1024u * 1024u), g_str_hash, g_str_equal, g_free, gtk_destroy);

    for (step = 0; step < 600; ++step) {
        int page;
        size_t bytes;
        seed = seed * 1103515245u + 12345u;
        page = (int)((seed >> 16) % (unsigned)CACHE_PAGES);
        bytes = spdf_win_lru_bitmap_bytes(400 + page * 11, 500 + page * 7);

        if (step % 9 == 4) {
            SpdfWinLruKey key = spdf_win_lru_key(page, 1.0, 1.0);
            char text[16];
            g_snprintf(text, sizeof(text), "%d", page);
            spdf_win_lru_lookup(&win, &key);
            spdf_lru_lookup(&gtk, text);
        } else if (step % 53 == 17) {
            SpdfWinLruKey key = spdf_win_lru_key(page, 1.0, 1.0);
            char text[16];
            g_snprintf(text, sizeof(text), "%d", page);
            spdf_win_lru_remove(&win, &key);
            /* GTK has no remove(); the store drops entries only through
             * eviction and remove_all, so mirror it by hand to keep the two
             * states identical. This is the one operation the port adds. */
            {
                SpdfLruEntry* entry = (SpdfLruEntry*)g_hash_table_lookup(gtk.table, text);
                if (entry) {
                    gtk.total_bytes -= MIN(gtk.total_bytes, entry->bytes);
                    g_hash_table_remove(gtk.table, text);
                }
            }
        } else {
            SpdfWinLruKey key = spdf_win_lru_key(page, 1.0, 1.0);
            spdf_win_lru_insert(&win, &key, &cache_sentinels[page], bytes);
            spdf_lru_insert(&gtk, g_strdup_printf("%d", page), &cache_sentinels[page], (gsize)bytes);
        }

        if (step == 250) {
            spdf_win_lru_set_cap(&win, 6u * 1024u * 1024u);
            spdf_lru_set_cap(&gtk, (gsize)(6u * 1024u * 1024u));
        }
        if (step == 420) {
            spdf_win_lru_remove_all(&win);
            spdf_lru_remove_all(&gtk);
        }
        /* Non-perturbing comparison every 25 steps, and a perturbing one every
         * 175, so both the untouched access pattern and the sweep-touched one
         * are exercised. */
        if (step % 25 == 24) compare_caches("workload", &win, &gtk, 0);
        if (step % 175 == 174) compare_caches("workload-touched", &win, &gtk, 1);
    }
    compare_caches("final", &win, &gtk, 0);

    /* The never-evict-to-empty guard, on both. */
    spdf_win_lru_remove_all(&win);
    spdf_lru_remove_all(&gtk);
    spdf_win_lru_set_cap(&win, 64);
    spdf_lru_set_cap(&gtk, 64);
    {
        SpdfWinLruKey key = spdf_win_lru_key(1, 1.0, 1.0);
        spdf_win_lru_insert(&win, &key, &cache_sentinels[1], 1000000);
        spdf_lru_insert(&gtk, g_strdup("1"), &cache_sentinels[1], 1000000);
        compare_caches("oversized", &win, &gtk, 0);
    }

    spdf_win_lru_deinit(&win);
    spdf_lru_deinit(&gtk);
}
