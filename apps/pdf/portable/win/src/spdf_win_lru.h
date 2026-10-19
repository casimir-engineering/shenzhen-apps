/* spdf_win_lru.h — the Win32 frontend's bounded cache of rendered pages.
 *
 * A rendered page is expensive to produce and cheap to throw away, so every
 * ShenzhenPDF frontend keeps a cache of them under a byte budget. This is the
 * Windows port of the GTK4 one (spdf_lru_* in
 * portable/linux/gtk4/spdf_docview_internal.h, itself the GTK3 minimap
 * thumbnail store generalised for the render texture cache), and it implements
 * that policy exactly — portable/win/tests/lru_cache_test.c drives this cache
 * and the real GTK cache through the same operation script and asserts the two
 * agree on size, byte total, membership and destroy count after every step.
 *
 * THE POLICY, and why it is this one:
 *
 *   - The budget is in DECODED BYTES, not entries. Page bitmaps differ in size
 *     by three orders of magnitude between an A5 page at 25% and a 10900pt
 *     schematic sheet at 400%; an entry-count cap either wastes memory or
 *     thrashes, depending on the document.
 *   - Eviction is strictly least-recently-USED: `lookup` bumps recency, insert
 *     bumps recency. Recency is a monotonically increasing counter, so ties are
 *     impossible and the victim is deterministic — which is what makes a
 *     cross-implementation differential test meaningful at all.
 *   - The cache NEVER evicts to empty. A single entry larger than the whole
 *     budget stays resident, because the alternative is that the page you are
 *     looking at is the one page that can never be cached. This is the
 *     `g_hash_table_size(...) > 1` guard in the GTK original.
 *   - `set_cap` evicts immediately, so shrinking the budget takes effect now
 *     rather than at the next insert.
 *
 * Budget default: SPDF_WIN_MAX_RENDER_SURFACE_BYTES (96MB), the same default
 * the GTK render service passes to spdf_lru_init. The mac frontend bounds the
 * same thing differently — a 192MB soft limit that drains to a 128MB target,
 * with a ±12-page keep window pinned around the current page
 * (kRenderedImageSoftByteLimit / kRenderedImageTargetByteLimit /
 * kRenderedImageKeepRadius in ShenzhenPDFMac.mm). The keep window is really a
 * prefetch policy dressed as an eviction policy: on both platforms the pages
 * near the viewport are the pages most recently drawn, so LRU keeps them for
 * the same reason mac pins them, without the frontend having to tell the cache
 * where the viewport is. The Windows port takes the GTK shape because it is the
 * one that is already pure, already tested, and already agrees with mac on
 * observable behaviour; a caller that wants mac's larger budget calls
 * spdf_win_lru_set_cap.
 *
 * Pure C, no Windows headers. Thread safety is the caller's: the GTK render
 * service holds its own mutex across every cache call, and spdf_win_render is
 * expected to do the same.
 */
#ifndef SPDF_WIN_LRU_H
#define SPDF_WIN_LRU_H

#include <stddef.h>

#include "spdf_win_layout.h" /* SPDF_WIN_MAX_RENDER_SURFACE_BYTES */

#ifdef __cplusplus
extern "C" {
#endif

/* Zoom and scale are quantised before they enter the key so that two requests
 * a hair apart share a texture instead of each allocating one. 4096 is the GTK
 * render service's SPDF_RENDER_SCALE_QUANTUM; keeping the same quantum keeps
 * the two frontends' hit/miss sequences identical for identical interactions. */
#define SPDF_WIN_LRU_SCALE_QUANTUM 4096.0

/* What a cached bitmap is keyed by: the page, the zoom and display scale it was
 * rendered at, and — for the crop regime (spdf_win_slot_needs_crop) — the
 * device-pixel region of the page it covers. A whole-page render has a zeroed
 * crop, which is what spdf_win_lru_key produces. */
typedef struct {
    int page;
    long long zoom_q;
    long long scale_q;
    int crop_x;
    int crop_y;
    int crop_w;
    int crop_h;
} SpdfWinLruKey;

SpdfWinLruKey spdf_win_lru_key(int page, double zoom, double scale);
SpdfWinLruKey spdf_win_lru_key_crop(int page, double zoom, double scale, int crop_x, int crop_y, int crop_w,
                                    int crop_h);
int spdf_win_lru_key_equal(const SpdfWinLruKey* a, const SpdfWinLruKey* b);

/* Called when the cache drops a value. On Windows this releases the
 * ID2D1Bitmap; in tests it counts. */
typedef void (*SpdfWinLruDestroy)(void* value);

typedef struct {
    void* slots; /* private: an open-addressed table of entries */
    size_t capacity;
    size_t count;
    size_t tombstones;
    size_t cap_bytes;
    size_t total_bytes;
    unsigned long long use_counter;
    SpdfWinLruDestroy value_destroy;
} SpdfWinLru;

/* Zero-initialised is a valid empty cache, but init sets the budget and the
 * destructor. cap_bytes of 0 means SPDF_WIN_MAX_RENDER_SURFACE_BYTES. */
void spdf_win_lru_init(SpdfWinLru* cache, size_t cap_bytes, SpdfWinLruDestroy value_destroy);
void spdf_win_lru_deinit(SpdfWinLru* cache);

/* Returns the cached value and bumps its recency, or NULL when absent. The
 * value stays owned by the cache. */
void* spdf_win_lru_lookup(SpdfWinLru* cache, const SpdfWinLruKey* key);

/* THE STAND-IN LOOKUP: this page, at whatever zoom we happen to have it.
 *
 * Returns the cached whole-page bitmap for `page` at this display `scale` whose
 * zoom is NEAREST `zoom`, bumping its recency like an ordinary lookup, or NULL
 * when the page is not cached at any zoom. `out_key` (optional) comes back with
 * the key that was found, so a caller can tell an exact hit from a stand-in.
 *
 * It exists so that a view rendering the visible page ASYNCHRONOUSLY has
 * something honest to draw for the frame or two before the real bitmap lands:
 * the same page, the same content, the same aspect ratio, one resolution out of
 * date -- and the compose layer already stretches a bitmap over its slot for the
 * byte-cap case, so nothing downstream needs to know. Without it the choice is
 * a hole in the frame or a synchronous render, which is the asymmetry
 * spdf_win_canvas.cpp's header used to have to defend.
 *
 * CROPS ARE NEVER RETURNED. A crop key covers a device-pixel region of the
 * page; stretched over the whole slot it would draw the wrong part of the page,
 * which is worse than drawing nothing.
 *
 * O(capacity), not O(1), and that is the one place this cache scans. The table
 * holds tens of entries under a 96 MB budget and this is asked at most once per
 * visible page per frame -- but it is a scan, so it must not migrate onto a
 * path that runs per page of the document rather than per page on screen. */
void* spdf_win_lru_lookup_nearest_zoom(SpdfWinLru* cache, int page, double scale, double zoom,
                                       SpdfWinLruKey* out_key);

/* Is this key resident? Answers WITHOUT bumping recency, so an
 * is-it-already-rendered check made while deciding what to prefetch cannot make
 * a page that nobody is looking at outlive one that is on screen. The GTK
 * original has no such call — it only ever asks in order to draw — so this is
 * the one operation the port adds beyond spdf_lru_*. */
int spdf_win_lru_peek(const SpdfWinLru* cache, const SpdfWinLruKey* key);

/* Takes ownership of `value` and inserts (or replaces) it under `key`, then
 * evicts down to the budget. A replaced value is destroyed. Returns 1 on
 * success; on the only failure path — the table could not grow — `value` is
 * destroyed and 0 is returned, so ownership never dangles. */
int spdf_win_lru_insert(SpdfWinLru* cache, const SpdfWinLruKey* key, void* value, size_t bytes);

void spdf_win_lru_remove(SpdfWinLru* cache, const SpdfWinLruKey* key);
void spdf_win_lru_remove_all(SpdfWinLru* cache);

/* Changes the budget and evicts immediately. */
void spdf_win_lru_set_cap(SpdfWinLru* cache, size_t cap_bytes);

size_t spdf_win_lru_size(const SpdfWinLru* cache);
size_t spdf_win_lru_bytes(const SpdfWinLru* cache);
size_t spdf_win_lru_cap(const SpdfWinLru* cache);

/* The byte cost both frontends charge a rendered page: 4 bytes per device
 * pixel (BGRA). Saturates rather than overflowing, so a nonsensical size is
 * charged the whole budget instead of wrapping to something tiny that would
 * defeat eviction. */
size_t spdf_win_lru_bitmap_bytes(int width_px, int height_px);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SPDF_WIN_LRU_H */
