/* spdf_render.c — worker render pipeline for the GTK4 frontend.
 *
 * Ported semantics from the GTK3 file (portable/linux/ShenzhenPDFGtk.c):
 *   - one persistent spdf_document per pool thread, keyed by (path, mtime,
 *     size), so the core's per-document display-list cache stays effective
 *     across renders (worker_document_for_path + worker_document_slot);
 *   - display-list adoption via SPDF_RENDER_USE_PAGE_LIST, disabled by
 *     SPDF_DISABLE_LIST_CACHE=1 (page_list_render_flags);
 *   - cooperative cancellation through spdf_render_token / fz_cookie
 *     (register/release/cancel_inflight_render_tokens);
 *   - the 96MB decoded-bytes cap: a single bitmap never exceeds it
 *     (capped_render_zoom) and the finished-texture cache evicts LRU past it
 *     (minimap_thumbnails_evict_over_budget generalized in spdf_lru_*).
 *
 * Semantics beyond the header contract (documented here, relied on by
 * spdf_docview.c):
 *   - the done callback is invoked EXACTLY ONCE per request token, always on
 *     the main thread (g_main_context_invoke_full on the default context),
 *     with a NULL texture on cancellation, error, or service shutdown — so
 *     per-request user_data has a deterministic release point;
 *   - callbacks for requests still in flight when spdf_render_service_free
 *     runs are still delivered (with NULL); callers detach their user_data
 *     before freeing the service.
 *
 * Results are GdkMemoryTextures wrapping the core RGBA buffer via
 * g_bytes_new_take — zero extra copies.
 */

#include <glib/gstdio.h>

#include "spdf_docview_internal.h"
#include "spdf_internal.h"
#include "spdf_password.h"

/* Worker pool size: min(4, cores/2), at least 1. The Mac pipeline learned the
 * hard way that more concurrent page renders saturate memory bandwidth and
 * stall main-thread input even though the work is off-main; re-measure before
 * raising (architecture.md §3.3). */
#define SPDF_RENDER_MAX_WORKERS 4

/* Cache-key scale quantization: 1/4096 of a device pixel per point is far
 * below any visible difference and keeps doubles hashable. */
#define SPDF_RENDER_SCALE_QUANTUM 4096.0

/* ---------------------------------------------------------------------------
 * Persistent per-thread worker documents. Documents are only ever touched
 * from their owning pool thread (the core's one-thread-per-spdf_document
 * contract); the GPrivate destructor closes the cached document when the
 * thread exits. Direct port of the GTK3 worker_document_slot machinery. */

typedef struct worker_document_slot {
    char* path;
    gint64 mtime;
    gint64 size;
    spdf_document* doc;
    SpdfPasswordCredential* credential;
    guint64 credential_generation;
} worker_document_slot;

static void worker_document_slot_free(gpointer data) {
    worker_document_slot* slot = (worker_document_slot*)data;
    if (!slot) return;
    if (slot->doc) spdf_close(slot->doc);
    spdf_password_credential_unref(slot->credential);
    g_free(slot->path);
    g_free(slot);
}

static GPrivate worker_document_slot_private = G_PRIVATE_INIT(worker_document_slot_free);

static gboolean file_state_for_path(const char* path, gint64* mtime, gint64* size) {
    GStatBuf st;
    if (!path || g_stat(path, &st) != 0) return FALSE;
    if (mtime) *mtime = (gint64)st.st_mtime;
    if (size) *size = (gint64)st.st_size;
    return TRUE;
}

/* Exported as spdf_render_worker_document (spdf_internal.h): the docview's
 * cursor-region builder runs on its own worker thread and needs the same
 * per-thread persistent document (the core's one-thread-per-spdf_document
 * contract forbids touching the tab's main-thread doc off-main). */
static spdf_document* worker_document_for_source(const SpdfPasswordSource* source, char* err, size_t err_len) {
    gint64 mtime = 0;
    gint64 size = 0;
    worker_document_slot* slot = g_private_get(&worker_document_slot_private);
    const char* path = source ? source->path : NULL;
    SpdfPasswordCredential* credential = source ? source->credential : NULL;
    guint64 credential_generation = source ? source->generation : 0;

    if (!file_state_for_path(path, &mtime, &size)) {
        g_snprintf(err, err_len, "%s", "File moved or deleted.");
        return NULL;
    }
    if (slot && slot->doc && g_strcmp0(slot->path, path) == 0 && slot->mtime == mtime && slot->size == size &&
        slot->credential == credential && slot->credential_generation == credential_generation)
        return slot->doc;
    if (!slot) {
        slot = g_new0(worker_document_slot, 1);
        g_private_set(&worker_document_slot_private, slot);
    }
    if (slot->doc) {
        spdf_close(slot->doc);
        slot->doc = NULL;
    }
    g_free(slot->path);
    spdf_password_credential_unref(slot->credential);
    slot->path = g_strdup(path);
    slot->mtime = mtime;
    slot->size = size;
    slot->credential = spdf_password_credential_ref(credential);
    slot->credential_generation = credential_generation;
    slot->doc = spdf_password_source_open(source, err, err_len);
    return slot->doc;
}

spdf_document* spdf_render_worker_document(const SpdfPasswordSource* source, char* err, size_t err_len) {
    return worker_document_for_source(source, err, err_len);
}

static unsigned page_list_render_flags(void) {
    static gsize initialized = 0;
    static unsigned flags = SPDF_RENDER_USE_PAGE_LIST;
    if (g_once_init_enter(&initialized)) {
        if (g_strcmp0(g_getenv("SPDF_DISABLE_LIST_CACHE"), "1") == 0) flags = SPDF_RENDER_DEFAULT;
        g_once_init_leave(&initialized, 1);
    }
    return flags;
}

/* ---------------------------------------------------------------------------
 * Texture cache key: (page, quantized scale, crop). */

typedef struct {
    int page;
    gint64 scale_q;
    GdkRectangle crop;
} render_cache_key;

static guint render_cache_key_hash(gconstpointer data) {
    const render_cache_key* key = (const render_cache_key*)data;
    guint hash = (guint)key->page * 2654435761u;
    hash ^= (guint)(key->scale_q ^ (key->scale_q >> 32)) * 40503u;
    hash ^= (guint)key->crop.x * 31u + (guint)key->crop.y * 37u;
    hash ^= (guint)key->crop.width * 41u + (guint)key->crop.height * 43u;
    return hash;
}

static gboolean render_cache_key_equal(gconstpointer a, gconstpointer b) {
    const render_cache_key* ka = (const render_cache_key*)a;
    const render_cache_key* kb = (const render_cache_key*)b;
    return ka->page == kb->page && ka->scale_q == kb->scale_q && ka->crop.x == kb->crop.x && ka->crop.y == kb->crop.y &&
           ka->crop.width == kb->crop.width && ka->crop.height == kb->crop.height;
}

static render_cache_key* render_cache_key_for_spec(const SpdfRenderSpec* spec) {
    render_cache_key* key = g_new0(render_cache_key, 1);
    key->page = spec->page;
    key->scale_q = (gint64)llround(spec->scale * SPDF_RENDER_SCALE_QUANTUM);
    key->crop = spec->crop;
    return key;
}

/* ---------------------------------------------------------------------------
 * Service, tasks, deliveries. */

struct _SpdfRenderService {
    gint refcount;
    char* path;
    GMutex lock;
    GHashTable* inflight; /* token (guintptr) -> render_task*, borrowed */
    guint64 next_token;
    guint64 next_seq;
    SpdfLruCache cache; /* render_cache_key* -> GdkTexture* (cache's own ref) */
    SpdfPasswordCredential* credential;
    gboolean shutdown;
    gint first_render_marked;
};

typedef struct {
    SpdfRenderService* svc; /* strong ref */
    SpdfRenderSpec spec;    /* spec.token holds the assigned token */
    int priority;
    guint64 seq;
    SpdfRenderDone done;
    gpointer user_data;
    spdf_render_token* core_token;
    SpdfPasswordSource source;
    gint canceled; /* atomic */
} render_task;

typedef struct {
    SpdfRenderService* svc; /* strong ref */
    SpdfRenderSpec spec;
    GdkTexture* texture; /* transferred to the callee; NULL on cancel/error */
    SpdfRenderDone done;
    gpointer user_data;
} render_delivery;

static SpdfRenderService* render_service_ref(SpdfRenderService* svc) {
    g_atomic_int_inc(&svc->refcount);
    return svc;
}

static void render_service_unref(SpdfRenderService* svc) {
    if (!svc || !g_atomic_int_dec_and_test(&svc->refcount)) return;
    spdf_lru_deinit(&svc->cache);
    g_hash_table_destroy(svc->inflight);
    g_mutex_clear(&svc->lock);
    g_free(svc->path);
    spdf_password_credential_unref(svc->credential);
    g_free(svc);
}

/* Main-thread tail of every request: exactly one callback per token. */
static gboolean render_delivery_invoke(gpointer data) {
    render_delivery* delivery = (render_delivery*)data;
    if (delivery->done)
        delivery->done(delivery->texture, &delivery->spec, delivery->user_data);
    else if (delivery->texture)
        g_object_unref(delivery->texture);
    render_service_unref(delivery->svc);
    g_free(delivery);
    return G_SOURCE_REMOVE;
}

/* texture: transfer full (may be NULL). */
static void render_deliver(SpdfRenderService* svc, const SpdfRenderSpec* spec, GdkTexture* texture, SpdfRenderDone done,
                           gpointer user_data) {
    render_delivery* delivery = g_new0(render_delivery, 1);
    delivery->svc = render_service_ref(svc);
    delivery->spec = *spec;
    delivery->texture = texture;
    delivery->done = done;
    delivery->user_data = user_data;
    g_main_context_invoke_full(NULL, G_PRIORITY_DEFAULT, render_delivery_invoke, delivery, NULL);
}

/* ---------------------------------------------------------------------------
 * Shared worker pool. One process-wide pool (like the GTK3 state->render_pool)
 * so worker count stays bounded across tabs; tasks are sorted by
 * (priority, sequence), so visible (0) preempts near (1) preempts warm (2)
 * within the pending queue. */

static gint render_task_compare(gconstpointer a, gconstpointer b, gpointer user_data) {
    const render_task* ta = (const render_task*)a;
    const render_task* tb = (const render_task*)b;
    (void)user_data;
    if (ta->priority != tb->priority) return ta->priority - tb->priority;
    return ta->seq < tb->seq ? -1 : (ta->seq > tb->seq ? 1 : 0);
}

static void render_worker(gpointer data, gpointer user_data);

static GThreadPool* render_pool_get(void) {
    static GThreadPool* pool = NULL;
    static gsize initialized = 0;
    if (g_once_init_enter(&initialized)) {
        guint cores = g_get_num_processors();
        gint workers = (gint)MIN(SPDF_RENDER_MAX_WORKERS, MAX(1u, cores / 2u));
        pool = g_thread_pool_new(render_worker, NULL, workers, FALSE, NULL);
        g_thread_pool_set_sort_function(pool, render_task_compare, NULL);
        g_once_init_leave(&initialized, 1);
    }
    return pool;
}

/* ---------------------------------------------------------------------------
 * The worker: render one task on a pool thread, wrap the RGBA buffer in a
 * GdkMemoryTexture (zero-copy via g_bytes_new_take), cache it, deliver it. */

static GdkTexture* render_task_texture(render_task* task, spdf_document* doc, char* err, size_t err_len) {
    SpdfRenderSpec* spec = &task->spec;
    spdf_bitmap bitmap;
    float page_width = 0.0f;
    float page_height = 0.0f;
    char size_err[256];
    double scale = spec->scale;
    gboolean full_page = spec->crop.width <= 0 || spec->crop.height <= 0;
    int ok;

    if (!spdf_page_size(doc, spec->page, &page_width, &page_height, size_err, sizeof(size_err))) {
        g_snprintf(err, err_len, "%s", size_err);
        return NULL;
    }

    if (full_page) {
        /* Cap the render scale so the bitmap stays under the byte cap; the
         * view stretches the texture back over the uncapped slot rect, so
         * layout geometry (and the zoom anchor) never see the cap. */
        scale = spdf_capped_render_zoom(scale, page_width, page_height);
        ok = spdf_render_page_rgba_opts(doc, spec->page, (float)scale, page_list_render_flags(), task->core_token,
                                        &bitmap, err, err_len);
    } else {
        /* Crop-to-viewport: spec->crop is page-space device px at spec->scale;
         * the core wants PDF points. */
        spdf_rect region;
        region.x0 = (float)(spec->crop.x / spec->scale);
        region.y0 = (float)(spec->crop.y / spec->scale);
        region.x1 = (float)((spec->crop.x + spec->crop.width) / spec->scale);
        region.y1 = (float)((spec->crop.y + spec->crop.height) / spec->scale);
        scale = spdf_capped_render_zoom(scale, region.x1 - region.x0, region.y1 - region.y0);
        ok = spdf_render_page_region_rgba_opts(doc, spec->page, (float)scale, region, page_list_render_flags(),
                                               task->core_token, &bitmap, err, err_len);
    }
    if (!ok) return NULL;

    {
        gsize byte_count = (gsize)bitmap.stride * (gsize)bitmap.height;
        /* Steal the core's malloc'd buffer: g_bytes_new_take releases with
         * g_free, which is the system allocator under GLib. No copy. */
        GBytes* bytes = g_bytes_new_take(bitmap.rgba, byte_count);
        GdkTexture* texture =
            gdk_memory_texture_new(bitmap.width, bitmap.height, GDK_MEMORY_R8G8B8A8, bytes, (gsize)bitmap.stride);
        g_bytes_unref(bytes);
        return texture;
    }
}

static void render_worker(gpointer data, gpointer user_data) {
    render_task* task = (render_task*)data;
    SpdfRenderService* svc = task->svc;
    GdkTexture* texture = NULL;
    char err[1024] = "";
    (void)user_data;

    if (!g_atomic_int_get(&task->canceled) && !svc->shutdown) {
        spdf_document* doc = worker_document_for_source(&task->source, err, sizeof(err));
        if (doc) texture = render_task_texture(task, doc, err, sizeof(err));
        if (texture && !spdf_password_credential_is_current(task->source.credential, task->source.generation)) {
            g_object_unref(texture);
            texture = NULL;
        }
        if (!texture && err[0] && g_strcmp0(err, "Render canceled.") != 0)
            g_warning("spdf_render: page %d: %s", task->spec.page, err);
    }

    if (texture) {
        g_mutex_lock(&svc->lock);
        if (!svc->shutdown) {
            gsize bytes = (gsize)gdk_texture_get_width(texture) * (gsize)gdk_texture_get_height(texture) * 4;
            spdf_lru_insert(&svc->cache, render_cache_key_for_spec(&task->spec), g_object_ref(texture), bytes);
        }
        g_mutex_unlock(&svc->lock);
        if (g_atomic_int_compare_and_exchange(&svc->first_render_marked, 0, 1)) spdf_launch_mark("first-render-done");
    }

    /* Drop the in-flight registration before freeing the token: the core
     * cancel API requires the token to stay alive while a render is running,
     * and spdf_render_cancel touches it only under the service lock. */
    g_mutex_lock(&svc->lock);
    g_hash_table_remove(svc->inflight, (gpointer)(guintptr)task->spec.token);
    g_mutex_unlock(&svc->lock);
    spdf_render_token_free(task->core_token);
    task->core_token = NULL;

    render_deliver(svc, &task->spec, texture, task->done, task->user_data);
    spdf_password_source_clear(&task->source);
    render_service_unref(task->svc);
    g_free(task);
}

/* ---------------------------------------------------------------------------
 * Contract API. */

SpdfRenderService* spdf_render_service_new(const char* path, SpdfPasswordCredential* credential, char** error) {
    SpdfRenderService* svc;

    if (error) *error = NULL;
    if (!path || !*path || !file_state_for_path(path, NULL, NULL)) {
        if (error) *error = g_strdup_printf("Could not open %s: file is missing.", path ? path : "(null)");
        return NULL;
    }

    svc = g_new0(SpdfRenderService, 1);
    svc->refcount = 1;
    svc->path = g_strdup(path);
    /* Keep the shared authority, not a one-time clone. Worker opens take an
     * isolated generation snapshot, so trusted edits refresh future renders
     * while in-flight work from the old generation is discarded. */
    svc->credential = spdf_password_credential_ref(credential);
    g_mutex_init(&svc->lock);
    svc->inflight = g_hash_table_new(g_direct_hash, g_direct_equal);
    svc->next_token = 1;
    spdf_lru_init(&svc->cache, SPDF_MAX_RENDER_SURFACE_BYTES, render_cache_key_hash, render_cache_key_equal, g_free,
                  g_object_unref);
    spdf_launch_mark("doc-open");
    return svc;
}

void spdf_render_service_free(SpdfRenderService* svc) {
    GHashTableIter iter;
    gpointer key;
    gpointer value;

    if (!svc) return;
    g_mutex_lock(&svc->lock);
    svc->shutdown = TRUE;
    g_hash_table_iter_init(&iter, svc->inflight);
    while (g_hash_table_iter_next(&iter, &key, &value)) {
        render_task* task = (render_task*)value;
        g_atomic_int_set(&task->canceled, 1);
        spdf_render_token_cancel(task->core_token);
    }
    spdf_lru_remove_all(&svc->cache);
    g_mutex_unlock(&svc->lock);
    render_service_unref(svc);
}

guint64 spdf_render_request(SpdfRenderService* svc, const SpdfRenderSpec* spec,
                            int priority /*0=visible,1=near,2=warm*/, SpdfRenderDone done, gpointer user_data) {
    render_task* task;
    guint64 token;
    GdkTexture* cached = NULL;
    SpdfRenderSpec assigned;

    g_return_val_if_fail(svc != NULL && spec != NULL, 0);

    g_mutex_lock(&svc->lock);
    token = svc->next_token++;
    assigned = *spec;
    assigned.token = token;
    if (!svc->shutdown) {
        render_cache_key key;
        key.page = assigned.page;
        key.scale_q = (gint64)llround(assigned.scale * SPDF_RENDER_SCALE_QUANTUM);
        key.crop = assigned.crop;
        cached = (GdkTexture*)spdf_lru_lookup(&svc->cache, &key);
        if (cached) g_object_ref(cached);
    }
    if (cached || svc->shutdown) {
        g_mutex_unlock(&svc->lock);
        render_deliver(svc, &assigned, cached, done, user_data);
        return token;
    }

    task = g_new0(render_task, 1);
    task->svc = render_service_ref(svc);
    task->spec = assigned;
    task->priority = CLAMP(priority, 0, 2);
    task->seq = svc->next_seq++;
    task->done = done;
    task->user_data = user_data;
    task->core_token = spdf_render_token_new();
    spdf_password_source_init(&task->source, svc->path, svc->credential);
    g_hash_table_insert(svc->inflight, (gpointer)(guintptr)token, task);
    g_mutex_unlock(&svc->lock);

    /* A FALSE return only means a new pool thread could not be spawned; the
     * task is still appended to the queue and runs on an existing worker, so
     * the exactly-once delivery guarantee holds either way. */
    g_thread_pool_push(render_pool_get(), task, NULL);
    return token;
}

void spdf_render_cancel(SpdfRenderService* svc, guint64 token) {
    render_task* task;

    if (!svc || token == 0) return;
    g_mutex_lock(&svc->lock);
    task = (render_task*)g_hash_table_lookup(svc->inflight, (gpointer)(guintptr)token);
    if (task) {
        g_atomic_int_set(&task->canceled, 1);
        /* Thread-safe while a render is running: sets cookie.abort, mupdf
         * stops within milliseconds (see shenzhen_pdf_core.h). */
        spdf_render_token_cancel(task->core_token);
    }
    g_mutex_unlock(&svc->lock);
}

void spdf_render_set_byte_cap(SpdfRenderService* svc, gsize bytes) {
    if (!svc) return;
    g_mutex_lock(&svc->lock);
    spdf_lru_set_cap(&svc->cache, bytes);
    g_mutex_unlock(&svc->lock);
}

/* Contract addition (returned to the integrator): drop every cached texture,
 * e.g. after rotation/OCR/save rewrote the file. Worker documents re-open by
 * themselves because they are keyed on (path, mtime, size). */
void spdf_render_service_invalidate(SpdfRenderService* svc) {
    if (!svc) return;
    g_mutex_lock(&svc->lock);
    spdf_lru_remove_all(&svc->cache);
    g_mutex_unlock(&svc->lock);
}
