/* Implementation of the bounded rendered-page cache. See spdf_win_lru.h for the
 * policy and its provenance.
 *
 * The GTK original is a GHashTable plus a per-entry recency counter. There is
 * no GHashTable here, so this file carries a small open-addressed table with
 * linear probing: power-of-two capacity, tombstones on removal, and a rehash
 * that reclaims them once live entries plus tombstones pass 70% of capacity.
 * That is the whole of the difference between the two implementations — the
 * eviction arithmetic below is line-for-line the GTK one, because the tests
 * compare the two caches step by step and any cleverness here would show up as
 * a divergence rather than as an improvement.
 *
 * Eviction is a linear scan for the oldest entry, exactly as in
 * spdf_lru_evict_over_budget. It is O(n) per evicted entry, which is fine at
 * the sizes involved (a 96MB budget over multi-megabyte page bitmaps holds tens
 * of entries, not thousands) and keeps the victim identical to GTK's without
 * having to reproduce a heap's tie-breaking.
 */

#include "spdf_win_lru.h"

#include <stdlib.h>
#include <string.h>

#define SPDF_WIN_LRU_SLOT_EMPTY 0
#define SPDF_WIN_LRU_SLOT_LIVE 1
#define SPDF_WIN_LRU_SLOT_DEAD 2 /* tombstone: probing continues through it */

#define SPDF_WIN_LRU_MIN_CAPACITY 16

typedef struct {
    int state;
    SpdfWinLruKey key;
    void* value;
    size_t bytes;
    unsigned long long last_used;
} spdf_win_lru_slot;

/* ---------------------------------------------------------------------------
 * Keys */

static long long spdf_win_lru_quantize(double v) {
    /* llround, but defined for a NaN or an out-of-range zoom rather than
     * undefined: a bad zoom must produce a bad cache key, not a trap. */
    double scaled = v * SPDF_WIN_LRU_SCALE_QUANTUM;
    if (!(scaled > -9.0e15 && scaled < 9.0e15)) return 0;
    return (long long)(scaled < 0.0 ? scaled - 0.5 : scaled + 0.5);
}

SpdfWinLruKey spdf_win_lru_key_crop(int page, double zoom, double scale, int crop_x, int crop_y, int crop_w,
                                    int crop_h) {
    SpdfWinLruKey key;
    key.page = page;
    key.zoom_q = spdf_win_lru_quantize(zoom);
    key.scale_q = spdf_win_lru_quantize(scale);
    key.crop_x = crop_x;
    key.crop_y = crop_y;
    key.crop_w = crop_w;
    key.crop_h = crop_h;
    return key;
}

SpdfWinLruKey spdf_win_lru_key(int page, double zoom, double scale) {
    return spdf_win_lru_key_crop(page, zoom, scale, 0, 0, 0, 0);
}

int spdf_win_lru_key_equal(const SpdfWinLruKey* a, const SpdfWinLruKey* b) {
    if (!a || !b) return a == b;
    /* Field-by-field rather than memcmp: the struct has padding on every ABI
     * this builds for, and padding bytes are indeterminate. */
    return a->page == b->page && a->zoom_q == b->zoom_q && a->scale_q == b->scale_q && a->crop_x == b->crop_x &&
                   a->crop_y == b->crop_y && a->crop_w == b->crop_w && a->crop_h == b->crop_h
               ? 1
               : 0;
}

/* Mixed the way render_cache_key_hash mixes: multiply each field by an odd
 * constant and fold. The table is power-of-two sized, so the low bits do the
 * work and the multipliers exist to get entropy down there. */
static size_t spdf_win_lru_key_hash(const SpdfWinLruKey* key) {
    unsigned long long hash = (unsigned long long)(unsigned int)key->page * 2654435761u;
    unsigned long long zoom = (unsigned long long)key->zoom_q;
    unsigned long long scale = (unsigned long long)key->scale_q;
    hash ^= (zoom ^ (zoom >> 32)) * 40503u;
    hash ^= (scale ^ (scale >> 32)) * 2246822519u;
    hash ^= (unsigned long long)(unsigned int)key->crop_x * 31u + (unsigned long long)(unsigned int)key->crop_y * 37u;
    hash ^= (unsigned long long)(unsigned int)key->crop_w * 41u + (unsigned long long)(unsigned int)key->crop_h * 43u;
    hash ^= hash >> 29;
    return (size_t)hash;
}

/* ---------------------------------------------------------------------------
 * Table */

static void spdf_win_lru_destroy_value(SpdfWinLru* cache, void* value) {
    if (cache->value_destroy && value) cache->value_destroy(value);
}

/* The slot a key occupies, or the first free slot it could occupy. Returns NULL
 * only for an unallocated table. `found` is set when the slot holds the key. */
static spdf_win_lru_slot* spdf_win_lru_probe(const SpdfWinLru* cache, const SpdfWinLruKey* key, int* found) {
    spdf_win_lru_slot* slots = (spdf_win_lru_slot*)cache->slots;
    spdf_win_lru_slot* first_dead = NULL;
    size_t mask;
    size_t index;
    size_t step;

    *found = 0;
    if (!slots || cache->capacity == 0) return NULL;
    mask = cache->capacity - 1;
    index = spdf_win_lru_key_hash(key) & mask;
    for (step = 0; step < cache->capacity; ++step) {
        spdf_win_lru_slot* slot = &slots[index];
        if (slot->state == SPDF_WIN_LRU_SLOT_EMPTY) return first_dead ? first_dead : slot;
        if (slot->state == SPDF_WIN_LRU_SLOT_DEAD) {
            if (!first_dead) first_dead = slot;
        } else if (spdf_win_lru_key_equal(&slot->key, key)) {
            *found = 1;
            return slot;
        }
        index = (index + 1) & mask;
    }
    return first_dead;
}

/* Grows (or compacts) to `capacity` slots. Returns 0 and leaves the cache
 * untouched when the allocation fails. */
static int spdf_win_lru_rehash(SpdfWinLru* cache, size_t capacity) {
    spdf_win_lru_slot* old_slots = (spdf_win_lru_slot*)cache->slots;
    size_t old_capacity = cache->capacity;
    spdf_win_lru_slot* slots;
    size_t i;

    if (capacity < SPDF_WIN_LRU_MIN_CAPACITY) capacity = SPDF_WIN_LRU_MIN_CAPACITY;
    slots = (spdf_win_lru_slot*)calloc(capacity, sizeof(spdf_win_lru_slot));
    if (!slots) return 0;

    cache->slots = slots;
    cache->capacity = capacity;
    cache->tombstones = 0;
    for (i = 0; i < old_capacity; ++i) {
        spdf_win_lru_slot* src = &old_slots[i];
        spdf_win_lru_slot* dst;
        int found;
        if (src->state != SPDF_WIN_LRU_SLOT_LIVE) continue;
        dst = spdf_win_lru_probe(cache, &src->key, &found);
        *dst = *src;
    }
    free(old_slots);
    return 1;
}

/* Keep live + tombstoned slots under 70% of capacity so probing stays short. */
static int spdf_win_lru_reserve(SpdfWinLru* cache) {
    size_t used = cache->count + cache->tombstones + 1;
    if (cache->capacity && used * 10 < cache->capacity * 7) return 1;
    /* Double only when live entries justify it; otherwise this is a compaction
     * that reclaims tombstones at the current size. */
    return spdf_win_lru_rehash(cache, (cache->count + 1) * 10 >= cache->capacity * 7
                                          ? (cache->capacity ? cache->capacity * 2 : SPDF_WIN_LRU_MIN_CAPACITY)
                                          : cache->capacity);
}

static void spdf_win_lru_drop_slot(SpdfWinLru* cache, spdf_win_lru_slot* slot) {
    cache->total_bytes -= slot->bytes < cache->total_bytes ? slot->bytes : cache->total_bytes;
    spdf_win_lru_destroy_value(cache, slot->value);
    slot->state = SPDF_WIN_LRU_SLOT_DEAD;
    slot->value = NULL;
    slot->bytes = 0;
    cache->count--;
    cache->tombstones++;
}

/* Port of spdf_lru_evict_over_budget, guard included: never below one entry. */
static void spdf_win_lru_evict_over_budget(SpdfWinLru* cache) {
    spdf_win_lru_slot* slots = (spdf_win_lru_slot*)cache->slots;
    if (!slots) return;
    while (cache->total_bytes > cache->cap_bytes && cache->count > 1) {
        spdf_win_lru_slot* oldest = NULL;
        size_t i;
        for (i = 0; i < cache->capacity; ++i) {
            spdf_win_lru_slot* slot = &slots[i];
            if (slot->state != SPDF_WIN_LRU_SLOT_LIVE) continue;
            if (!oldest || slot->last_used < oldest->last_used) oldest = slot;
        }
        if (!oldest) break;
        spdf_win_lru_drop_slot(cache, oldest);
    }
}

/* ---------------------------------------------------------------------------
 * Public API */

void spdf_win_lru_init(SpdfWinLru* cache, size_t cap_bytes, SpdfWinLruDestroy value_destroy) {
    if (!cache) return;
    memset(cache, 0, sizeof(*cache));
    cache->cap_bytes = cap_bytes ? cap_bytes : SPDF_WIN_MAX_RENDER_SURFACE_BYTES;
    cache->value_destroy = value_destroy;
}

void spdf_win_lru_deinit(SpdfWinLru* cache) {
    if (!cache) return;
    spdf_win_lru_remove_all(cache);
    free(cache->slots);
    cache->slots = NULL;
    cache->capacity = 0;
    cache->tombstones = 0;
}

void* spdf_win_lru_lookup(SpdfWinLru* cache, const SpdfWinLruKey* key) {
    spdf_win_lru_slot* slot;
    int found = 0;
    if (!cache || !key) return NULL;
    slot = spdf_win_lru_probe(cache, key, &found);
    if (!slot || !found) return NULL;
    slot->last_used = ++cache->use_counter;
    return slot->value;
}

void* spdf_win_lru_lookup_nearest_zoom(SpdfWinLru* cache, int page, double scale, double zoom,
                                       SpdfWinLruKey* out_key) {
    spdf_win_lru_slot* slots;
    spdf_win_lru_slot* best = NULL;
    long long want;
    long long scale_q;
    size_t i;

    if (out_key) memset(out_key, 0, sizeof(*out_key));
    if (!cache) return NULL;
    slots = (spdf_win_lru_slot*)cache->slots;
    if (!slots) return NULL;
    want = spdf_win_lru_quantize(zoom);
    scale_q = spdf_win_lru_quantize(scale);
    for (i = 0; i < cache->capacity; ++i) {
        spdf_win_lru_slot* slot = &slots[i];
        long long d;
        long long bd;
        if (slot->state != SPDF_WIN_LRU_SLOT_LIVE) continue;
        if (slot->key.page != page || slot->key.scale_q != scale_q) continue;
        /* Whole-page renders only. A crop covers a region of the page, so
         * stretching it over the whole slot would draw the wrong part of the
         * page at the wrong size -- a hole would be better. */
        if (slot->key.crop_w != 0 || slot->key.crop_h != 0) continue;
        d = slot->key.zoom_q > want ? slot->key.zoom_q - want : want - slot->key.zoom_q;
        if (!best) {
            best = slot;
            continue;
        }
        bd = best->key.zoom_q > want ? best->key.zoom_q - want : want - best->key.zoom_q;
        /* Nearest zoom, and on a tie the SHARPER one -- a tie means one entry
         * either side of the wanted zoom, and upscaling a bigger texture down
         * looks better than blowing a smaller one up. Total order, so the
         * answer never depends on table layout. */
        if (d < bd || (d == bd && slot->key.zoom_q > best->key.zoom_q)) best = slot;
    }
    if (!best) return NULL;
    best->last_used = ++cache->use_counter;
    if (out_key) *out_key = best->key;
    return best->value;
}

int spdf_win_lru_peek(const SpdfWinLru* cache, const SpdfWinLruKey* key) {
    int found = 0;
    if (!cache || !key) return 0;
    return spdf_win_lru_probe(cache, key, &found) && found ? 1 : 0;
}

int spdf_win_lru_insert(SpdfWinLru* cache, const SpdfWinLruKey* key, void* value, size_t bytes) {
    spdf_win_lru_slot* slot;
    int found = 0;

    if (!cache || !key) return 0;
    slot = spdf_win_lru_probe(cache, key, &found);
    if (slot && found) {
        /* Replace in place, exactly as spdf_lru_insert does: the old value's
         * bytes leave the total, the old value is destroyed, recency bumps. */
        cache->total_bytes -= slot->bytes < cache->total_bytes ? slot->bytes : cache->total_bytes;
        spdf_win_lru_destroy_value(cache, slot->value);
        slot->value = value;
        slot->bytes = bytes;
        slot->last_used = ++cache->use_counter;
        cache->total_bytes += bytes;
        spdf_win_lru_evict_over_budget(cache);
        return 1;
    }

    if (!spdf_win_lru_reserve(cache)) {
        /* Out of memory growing the table. Destroy the value we were handed
         * rather than leaking it or pretending the insert happened. */
        spdf_win_lru_destroy_value(cache, value);
        return 0;
    }
    slot = spdf_win_lru_probe(cache, key, &found);
    if (!slot) {
        spdf_win_lru_destroy_value(cache, value);
        return 0;
    }
    if (slot->state == SPDF_WIN_LRU_SLOT_DEAD) cache->tombstones--;
    slot->state = SPDF_WIN_LRU_SLOT_LIVE;
    slot->key = *key;
    slot->value = value;
    slot->bytes = bytes;
    slot->last_used = ++cache->use_counter;
    cache->count++;
    cache->total_bytes += bytes;
    spdf_win_lru_evict_over_budget(cache);
    return 1;
}

void spdf_win_lru_remove(SpdfWinLru* cache, const SpdfWinLruKey* key) {
    spdf_win_lru_slot* slot;
    int found = 0;
    if (!cache || !key) return;
    slot = spdf_win_lru_probe(cache, key, &found);
    if (!slot || !found) return;
    spdf_win_lru_drop_slot(cache, slot);
}

void spdf_win_lru_remove_all(SpdfWinLru* cache) {
    spdf_win_lru_slot* slots;
    size_t i;
    if (!cache) return;
    slots = (spdf_win_lru_slot*)cache->slots;
    for (i = 0; slots && i < cache->capacity; ++i) {
        if (slots[i].state == SPDF_WIN_LRU_SLOT_LIVE) spdf_win_lru_destroy_value(cache, slots[i].value);
        slots[i].state = SPDF_WIN_LRU_SLOT_EMPTY;
        slots[i].value = NULL;
        slots[i].bytes = 0;
        slots[i].last_used = 0;
    }
    cache->count = 0;
    cache->tombstones = 0;
    cache->total_bytes = 0;
}

void spdf_win_lru_set_cap(SpdfWinLru* cache, size_t cap_bytes) {
    if (!cache) return;
    cache->cap_bytes = cap_bytes;
    spdf_win_lru_evict_over_budget(cache);
}

size_t spdf_win_lru_size(const SpdfWinLru* cache) {
    return cache ? cache->count : 0;
}
size_t spdf_win_lru_bytes(const SpdfWinLru* cache) {
    return cache ? cache->total_bytes : 0;
}
size_t spdf_win_lru_cap(const SpdfWinLru* cache) {
    return cache ? cache->cap_bytes : 0;
}

size_t spdf_win_lru_bitmap_bytes(int width_px, int height_px) {
    unsigned long long w;
    unsigned long long h;
    unsigned long long total;
    if (width_px <= 0 || height_px <= 0) return 0;
    w = (unsigned long long)width_px;
    h = (unsigned long long)height_px;
    total = w * h * 4ull;
    if (total > (unsigned long long)(size_t)-1) return (size_t)-1;
    return (size_t)total;
}
