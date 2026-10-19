// spdf_minimap.c — the document map (see spdf_minimap.h for the contract and
// provenance). One SpdfMinimap per tab, mounted right of the page-content
// overlay (Mac trailing-edge placement: document, divider line, strip).
//
// Structure of this file:
//   - frame snapshot: everything a draw/gesture needs, derived fresh from the
//     doc view + adjustments (the strip has no scroll state of its own);
//   - thumbnail pipeline: warm-priority renders through the tab's
//     SpdfRenderService into a widget-local 32MB LRU of cairo surfaces
//     (GTK3 minimap thumbnail store; the service's own texture cache is
//     shared with the page canvas, so the minimap keeps its own budget and
//     its own bounded page window for deterministic eviction);
//   - cairo draw func (GTK3 minimap_draw colors and placeholder);
//   - gestures: viewport drag (1:1 or Mac long-document accelerated track
//     drag), click-to-jump, strip-scroll wheel with kinetic momentum (Mac
//     db9515802 + SPDFMacMinimapView sendStripScrollForEvent:, which gets the
//     momentum tail from AppKit; GTK animates the GtkKineticScrolling decay
//     itself), Ctrl+scroll zoom forwarded to the doc view (Mac
//     minimapViewDidReceiveZoomScrollWheel:);
//   - visibility + win.minimap action + documents.json persistence.

#include <math.h>
#include <string.h>

#include "spdf_app.h"
#include "spdf_minimap.h"
#include "spdf_minimap_internal.h"
#include "spdf_search.h"

#define MINIMAP_FALLBACK_WIDTH 126 /* Mac kDefaultMinimapWidth (126.5) */
#define MINIMAP_MIN_WIDTH 72       /* settings "minimapWidth" clamp, Mac parity */
#define MINIMAP_MAX_WIDTH 260
#define MINIMAP_THUMB_QUEUE_LIMIT_PER_DRAW 8 /* GTK3 MINIMAP_THUMB_QUEUE_LIMIT_PER_DRAW */
#define MINIMAP_DRAG_THRESHOLD 3.0           /* Mac press-vs-drag slop */
#define MINIMAP_CENTER_ITERATIONS 8          /* Mac documentPointForMinimapCenterPoint */

typedef struct {
    cairo_surface_t* surface;
    double scale; /* device px per PDF point the surface was rendered at */
} minimap_thumb;

/* In-flight thumbnail request. Owned by the render pipeline: the done
 * callback fires exactly once (main thread) and frees it. The widget's
 * pending table only borrows; orphaning (self = NULL) detaches the widget. */
typedef struct {
    SpdfMinimap* self; /* NULL after widget dispose / document change */
    int page;
    guint64 token; /* set only while the ctx is still pending (async path) */
} thumb_ctx;

struct _SpdfMinimap {
    GtkDrawingArea parent_instance;

    SpdfTab* tab; /* borrowed; the tab outlives its widget tree */

    SpdfLruCache thumbs; /* GINT_TO_POINTER(page) -> minimap_thumb*, 32MB cap */
    GHashTable* pending; /* GINT_TO_POINTER(page) -> thumb_ctx* (borrowed) */
    SpdfMinimapThumbWindow window;

    /* Press/drag state (Mac mouseDown/mouseDragged/mouseUp port). */
    gboolean press_pending;
    gboolean drag_moved;
    gboolean dragging_viewport;
    double press_x;
    double press_y;
    double drag_offset_center_x;
    double drag_offset_center_y;
    double drag_thumb_top;
    double drag_last_y;
    gint64 drag_last_time_us;

    /* Pointer tracking: the Ctrl+scroll zoom anchors at the document point
     * under the strip cursor (Mac documentPointForEvent:), but GTK scroll
     * events carry no position, so a motion controller remembers it. */
    double pointer_x;
    double pointer_y;
    gboolean pointer_valid;

    /* Kinetic strip-scroll momentum ("::decelerate" + frame-clock decay;
     * model constants in spdf_minimap_internal.h). */
    guint kinetic_tick_id;   /* gtk_widget_add_tick_callback id; 0 = idle */
    double kinetic_velocity; /* strip px/s, sign convention of scroll dy */
    gint64 kinetic_last_us;  /* monotonic time of the previous tick */
};

G_DEFINE_FINAL_TYPE(SpdfMinimap, spdf_minimap, GTK_TYPE_DRAWING_AREA)

/* --------------------------------------------------------------------------- */
/* Shared state access. */

static SpdfApp* minimap_window_app(SpdfWindow* win) {
    GtkApplication* app = win ? gtk_window_get_application(GTK_WINDOW(win)) : NULL;
    return app && SPDF_IS_APP(app) ? SPDF_APP(app) : NULL;
}

static SpdfState* minimap_state_for_tab(SpdfTab* tab) {
    SpdfApp* app = tab ? minimap_window_app(tab->win) : NULL;
    return app ? spdf_app_get_state(app) : NULL;
}

static SpdfSettings* minimap_settings_for_tab(SpdfTab* tab) {
    SpdfState* state = minimap_state_for_tab(tab);
    return state ? spdf_state_settings(state) : NULL;
}

/* --------------------------------------------------------------------------- */
/* Frame snapshot: geometry derived fresh per draw/gesture. The strip offset
 * derives from the document scroll position (no scroll state of its own), so
 * everything stays consistent by construction. O(page count) arithmetic. */

typedef struct {
    SpdfDocView* view;
    GtkAdjustment* vadj;
    GtkAdjustment* hadj;
    int count;
    double width;
    double height;
    SpdfPageSizePt* sizes; /* PDF points */
    double* doc_x;         /* document-space page slots (content px at zoom) */
    double* doc_y;
    double* doc_w;
    double* doc_h;
    SpdfMinimapStrip strip;
    double content_top;
    double doc_top;
    double doc_visible_h;
    double doc_upper;
    double doc_left;
    double doc_visible_w;
} minimap_frame;

static void minimap_frame_release(minimap_frame* f) {
    if (!f) return;
    g_free(f->sizes);
    g_free(f->doc_x);
    g_free(f->doc_y);
    g_free(f->doc_w);
    g_free(f->doc_h);
    spdf_minimap_strip_clear(&f->strip);
    memset(f, 0, sizeof(*f));
}

static gboolean minimap_frame_acquire(SpdfMinimap* self, minimap_frame* f) {
    SpdfTab* tab = self->tab;
    double zoom;
    double max_scroll;
    double fraction;

    memset(f, 0, sizeof(*f));
    if (!tab || !tab->view || !tab->doc) return FALSE;
    f->view = tab->view;
    f->width = gtk_widget_get_width(GTK_WIDGET(self));
    f->height = gtk_widget_get_height(GTK_WIDGET(self));
    if (f->width < 16.0 || f->height < 16.0) return FALSE;
    f->count = spdf_page_count(tab->doc);
    zoom = spdf_doc_view_get_zoom(f->view);
    if (f->count <= 0 || zoom <= 0.0) return FALSE;

    f->sizes = g_new0(SpdfPageSizePt, f->count);
    f->doc_x = g_new0(double, f->count);
    f->doc_y = g_new0(double, f->count);
    f->doc_w = g_new0(double, f->count);
    f->doc_h = g_new0(double, f->count);
    for (int i = 0; i < f->count; ++i) {
        if (!spdf_doc_view_page_slot(f->view, i, &f->doc_x[i], &f->doc_y[i], &f->doc_w[i], &f->doc_h[i])) {
            minimap_frame_release(f); /* layout not ready (mid document change) */
            return FALSE;
        }
        f->sizes[i].width = f->doc_w[i] / zoom;
        f->sizes[i].height = f->doc_h[i] / zoom;
    }
    spdf_minimap_strip_compute(&f->strip, f->sizes, f->count, f->width);
    if (f->strip.content_h <= 0.0) {
        minimap_frame_release(f);
        return FALSE;
    }

    f->vadj = gtk_scrollable_get_vadjustment(GTK_SCROLLABLE(f->view));
    f->hadj = gtk_scrollable_get_hadjustment(GTK_SCROLLABLE(f->view));
    f->doc_top = f->vadj ? gtk_adjustment_get_value(f->vadj) : 0.0;
    f->doc_visible_h = f->vadj ? gtk_adjustment_get_page_size(f->vadj) : f->height;
    f->doc_upper = f->vadj ? gtk_adjustment_get_upper(f->vadj) : 0.0;
    f->doc_left = f->hadj ? gtk_adjustment_get_value(f->hadj) : 0.0;
    f->doc_visible_w = f->hadj ? gtk_adjustment_get_page_size(f->hadj) : 0.0;
    max_scroll = MAX(0.0, f->doc_upper - f->doc_visible_h);
    fraction = max_scroll > 0.0 ? f->doc_top / max_scroll : 0.0;
    f->content_top = spdf_minimap_content_top(f->strip.content_h, f->height, fraction);
    return TRUE;
}

static void minimap_frame_viewport_rect(const minimap_frame* f, double* x, double* y, double* w, double* h) {
    spdf_minimap_viewport_rect(&f->strip, f->doc_x, f->doc_y, f->doc_w, f->doc_h, f->count, f->doc_left, f->doc_top,
                               f->doc_visible_w, f->doc_visible_h, f->width, x, y, w, h);
    if (y) *y += f->content_top;
}

/* --------------------------------------------------------------------------- */
/* Thumbnail pipeline. */

static void minimap_thumb_free(gpointer data) {
    minimap_thumb* thumb = (minimap_thumb*)data;
    if (!thumb) return;
    if (thumb->surface) cairo_surface_destroy(thumb->surface);
    g_free(thumb);
}

/* Direct removal must keep the LRU byte accounting straight (spdf_lru_* only
 * adjusts totals through insert/evict). */
static void minimap_thumbs_remove_page(SpdfMinimap* self, int page) {
    SpdfLruEntry* entry;

    if (!self->thumbs.table) return;
    entry = g_hash_table_lookup(self->thumbs.table, GINT_TO_POINTER(page));
    if (!entry) return;
    self->thumbs.total_bytes -= MIN(self->thumbs.total_bytes, entry->bytes);
    g_hash_table_remove(self->thumbs.table, GINT_TO_POINTER(page));
}

static minimap_thumb* minimap_thumb_lookup(SpdfMinimap* self, int page, double desired_scale) {
    minimap_thumb* thumb = spdf_lru_lookup(&self->thumbs, GINT_TO_POINTER(page));
    if (!thumb || !thumb->surface) return NULL;
    /* Same 1% tolerance as the Mac thumbnail zoom match. */
    if (desired_scale > 0.0 && fabs(thumb->scale - desired_scale) > desired_scale * 0.01) return NULL;
    return thumb;
}

static void minimap_store_thumb(SpdfMinimap* self, int page, GdkTexture* texture, double scale) {
    int w = gdk_texture_get_width(texture);
    int h = gdk_texture_get_height(texture);
    cairo_surface_t* surface;
    minimap_thumb* thumb;
    int sf;

    if (w <= 0 || h <= 0) return;
    surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        return;
    }
    /* gdk_texture_download writes premultiplied BGRA — cairo ARGB32 layout. */
    gdk_texture_download(texture, cairo_image_surface_get_data(surface),
                         (gsize)cairo_image_surface_get_stride(surface));
    cairo_surface_mark_dirty(surface);
    sf = gtk_widget_get_scale_factor(GTK_WIDGET(self));
    cairo_surface_set_device_scale(surface, MAX(1, sf), MAX(1, sf));

    thumb = g_new0(minimap_thumb, 1);
    thumb->surface = surface;
    thumb->scale = scale;
    spdf_lru_insert(&self->thumbs, GINT_TO_POINTER(page), thumb, (gsize)w * (gsize)h * 4);
}

static void minimap_thumb_done(GdkTexture* texture, const SpdfRenderSpec* spec, gpointer user_data) {
    thumb_ctx* ctx = (thumb_ctx*)user_data;
    SpdfMinimap* self = ctx->self;

    if (self && self->pending && g_hash_table_lookup(self->pending, GINT_TO_POINTER(ctx->page)) == ctx) {
        g_hash_table_remove(self->pending, GINT_TO_POINTER(ctx->page));
        if (texture) {
            minimap_store_thumb(self, ctx->page, texture, spec->scale);
            gtk_widget_queue_draw(GTK_WIDGET(self));
        }
    }
    if (texture) g_object_unref(texture);
    g_free(ctx);
}

static double minimap_thumb_scale(SpdfMinimap* self, const minimap_frame* f, int page) {
    double page_w = MAX(1.0, f->sizes[page].width);
    int sf = MAX(1, gtk_widget_get_scale_factor(GTK_WIDGET(self)));
    return f->strip.rects[page].w * (double)sf / page_w;
}

static void minimap_request_thumb(SpdfMinimap* self, const minimap_frame* f, int page) {
    SpdfRenderService* svc = self->tab ? self->tab->render : NULL;
    double scale = minimap_thumb_scale(self, f, page);
    SpdfRenderSpec spec;
    thumb_ctx* ctx;
    guint64 token;

    if (!svc || scale <= 0.0) return;
    if (g_hash_table_lookup(self->pending, GINT_TO_POINTER(page))) return;

    spec.page = page;
    spec.scale = scale;
    spec.crop.x = spec.crop.y = spec.crop.width = spec.crop.height = 0;
    spec.token = 0;
    ctx = g_new0(thumb_ctx, 1);
    ctx->self = self;
    ctx->page = page;
    g_hash_table_insert(self->pending, GINT_TO_POINTER(page), ctx);
    /* A cache hit in the service delivers synchronously (main-thread invoke),
     * freeing ctx before this call returns — only touch it if still pending. */
    token = spdf_render_request(svc, &spec, 2 /* warm */, minimap_thumb_done, ctx);
    if (g_hash_table_lookup(self->pending, GINT_TO_POINTER(page)) == ctx) ctx->token = token;
}

/* Recompute the bounded thumbnail window, cancel queued renders that fell out
 * of it and evict cached thumbnails past the slack band (Mac
 * cancelQueuedMinimapThumbnailRenders + evictMinimapThumbnails). */
static void minimap_update_thumb_window(SpdfMinimap* self, const minimap_frame* f, int visible_first,
                                        int visible_last) {
    GHashTableIter iter;
    gpointer key;
    gpointer value;
    GArray* drop = g_array_new(FALSE, FALSE, sizeof(int));

    self->window = spdf_minimap_thumb_window_for_visible_range(f->count, visible_first, visible_last, self->window);

    g_hash_table_iter_init(&iter, self->pending);
    while (g_hash_table_iter_next(&iter, &key, &value)) {
        thumb_ctx* ctx = (thumb_ctx*)value;
        if (spdf_minimap_thumb_window_contains(self->window, ctx->page)) continue;
        if (self->tab && self->tab->render && ctx->token) spdf_render_cancel(self->tab->render, ctx->token);
        /* Dropping the pending entry detaches the widget; the delivery (NULL
         * texture) still frees the ctx. */
        g_hash_table_iter_remove(&iter);
    }

    if (self->thumbs.table) {
        g_hash_table_iter_init(&iter, self->thumbs.table);
        while (g_hash_table_iter_next(&iter, &key, &value)) {
            int page = GPOINTER_TO_INT(key);
            if (spdf_minimap_thumb_window_should_evict(self->window, page)) g_array_append_val(drop, page);
        }
        for (guint i = 0; i < drop->len; ++i) minimap_thumbs_remove_page(self, g_array_index(drop, int, i));
    }
    g_array_free(drop, TRUE);
}

/* Orphan every in-flight request without touching the render service (it may
 * already have been swapped/freed by a Save As retarget). */
static void minimap_orphan_pending(SpdfMinimap* self) {
    GHashTableIter iter;
    gpointer value;

    if (!self->pending) return;
    g_hash_table_iter_init(&iter, self->pending);
    while (g_hash_table_iter_next(&iter, NULL, &value)) ((thumb_ctx*)value)->self = NULL;
    g_hash_table_remove_all(self->pending);
}

/* --------------------------------------------------------------------------- */
/* Drawing (GTK3 minimap_draw colors; the placeholder and search-tick colors
 * are shared with the Mac strip / the scrollbar heat-map lane). */

static void minimap_draw_placeholder(cairo_t* cr, double x, double y, double width, double height) {
    int lines;
    double line_y;

    if (width < 10.0 || height < 6.0) return;
    cairo_set_source_rgba(cr, 0.50, 0.50, 0.50, 0.24);
    lines = (int)MAX(2.0, MIN(16.0, floor(height / 7.0)));
    line_y = y + MAX(2.0, height * 0.08);
    for (int i = 0; i < lines; ++i) {
        double factor = i % 5 == 4 ? 0.56 : 0.78;
        double line_height = MAX(1.0, height * 0.018);
        cairo_rectangle(cr, x + width * 0.12, line_y, width * factor, line_height);
        cairo_fill(cr);
        line_y += MAX(3.0, height / (double)(lines + 2));
        if (line_y > y + height - 2.0) break;
    }
}

static void minimap_draw_thumb(cairo_t* cr, cairo_surface_t* surface, double x, double y, double width,
                               double height) {
    double sx = 1.0;
    double sy = 1.0;
    double logical_w;
    double logical_h;

    cairo_surface_get_device_scale(surface, &sx, &sy);
    logical_w = (double)cairo_image_surface_get_width(surface) / (sx > 0.0 ? sx : 1.0);
    logical_h = (double)cairo_image_surface_get_height(surface) / (sy > 0.0 ? sy : 1.0);
    if (logical_w < 1.0 || logical_h < 1.0) return;

    cairo_save(cr);
    cairo_rectangle(cr, x, y, width, height);
    cairo_clip(cr);
    cairo_translate(cr, x, y);
    cairo_scale(cr, width / logical_w, height / logical_h);
    cairo_set_source_surface(cr, surface, 0.0, 0.0);
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD);
    cairo_paint(cr);
    cairo_restore(cr);
}

static void minimap_draw_marker_tick(cairo_t* cr, const SpdfPageRect* rect, double content_top,
                                     double match_center_y_pt, double page_h_pt, gboolean active) {
    double y = content_top + spdf_minimap_marker_y(rect, match_center_y_pt, page_h_pt, SPDF_MINIMAP_MARKER_TICK_H);
    /* Heat-map lane colors (GTK3 draw_find_marker): hot orange = current. */
    if (active) cairo_set_source_rgba(cr, 1.0, 0.45, 0.02, 0.95);
    else cairo_set_source_rgba(cr, 1.0, 0.86, 0.08, 0.90);
    cairo_rectangle(cr, rect->x + 1.0, y, MAX(1.0, rect->w - 2.0), SPDF_MINIMAP_MARKER_TICK_H);
    cairo_fill(cr);
}

static void minimap_draw_search_markers(SpdfMinimap* self, cairo_t* cr, const minimap_frame* f, int first,
                                        int last) {
    SpdfSearchController* ctrl = self->tab ? self->tab->search : NULL;
    SpdfSettings* settings = minimap_settings_for_tab(self->tab);
    guint count;
    int current;

    if (!ctrl || (settings && !settings->show_find_markers)) return;
    count = spdf_search_controller_match_count(ctrl);
    if (count == 0) return;
    current = spdf_search_controller_current(ctrl);

    for (guint i = 0; i < count; ++i) {
        SpdfSearchMatch m;
        if ((int)i == current) continue; /* current drawn last, on top */
        if (!spdf_search_controller_match(ctrl, i, &m)) continue;
        if (m.page < first || m.page > last || m.page >= f->count) continue;
        minimap_draw_marker_tick(cr, &f->strip.rects[m.page], f->content_top, (m.rect.y0 + m.rect.y1) * 0.5,
                                 f->sizes[m.page].height, FALSE);
    }
    if (current >= 0) {
        SpdfSearchMatch m;
        if (spdf_search_controller_match(ctrl, (guint)current, &m) && m.page >= first && m.page <= last &&
            m.page < f->count)
            minimap_draw_marker_tick(cr, &f->strip.rects[m.page], f->content_top, (m.rect.y0 + m.rect.y1) * 0.5,
                                     f->sizes[m.page].height, TRUE);
    }
}

static void minimap_draw(GtkDrawingArea* area, cairo_t* cr, int width, int height, gpointer user_data) {
    SpdfMinimap* self = SPDF_MINIMAP(user_data);
    /* Dark-mode audit (Wave D): two palettes keyed off AdwStyleManager's dark
     * state (the Mac tunes the same chrome surfaces per appearance,
     * SPDFMacDocumentView.mm:34-47). Backdrop/divider/page borders/viewport
     * swap; thumbnails, the white page backing and the yellow/orange search
     * ticks stay — pages render white in both themes. notify::dark repaints
     * (connected in init). */
    gboolean dark = adw_style_manager_get_dark(adw_style_manager_get_default());
    minimap_frame f;
    int first = 0;
    int last = -1;
    int current_page;
    int queued = 0;
    double vx;
    double vy;
    double vw;
    double vh;

    (void)area;
    /* GTK3 minimap_draw backdrop + the Mac leading-edge separator (the strip
     * sits on the right, so the divider is its left edge). */
    if (dark) cairo_set_source_rgb(cr, 0.13, 0.13, 0.14);
    else cairo_set_source_rgb(cr, 0.94, 0.94, 0.94);
    cairo_rectangle(cr, 0.0, 0.0, width, height);
    cairo_fill(cr);
    if (dark) cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.12);
    else cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.16);
    cairo_rectangle(cr, 0.0, 0.0, 1.0, height);
    cairo_fill(cr);

    if (!minimap_frame_acquire(self, &f)) return;
    current_page = spdf_doc_view_current_page(f.view);

    if (spdf_minimap_strip_visible_range(&f.strip, -f.content_top, -f.content_top + f.height, &first, &last)) {
        minimap_update_thumb_window(self, &f, first, last);
        for (int i = first; i <= last; ++i) {
            const SpdfPageRect* rect = &f.strip.rects[i];
            double x = rect->x;
            double y = rect->y + f.content_top;
            minimap_thumb* thumb = minimap_thumb_lookup(self, i, minimap_thumb_scale(self, &f, i));

            cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
            cairo_rectangle(cr, x, y, rect->w, rect->h);
            cairo_fill(cr);
            if (thumb) {
                minimap_draw_thumb(cr, thumb->surface, x, y, rect->w, rect->h);
            } else {
                minimap_draw_placeholder(cr, x, y, rect->w, rect->h);
                if (queued < MINIMAP_THUMB_QUEUE_LIMIT_PER_DRAW && rect->w >= 8.0 && rect->h >= 8.0 &&
                    spdf_minimap_thumb_window_contains(self->window, i)) {
                    minimap_request_thumb(self, &f, i);
                    queued++;
                }
            }
            /* Current-page emphasis (GTK3 border weights; dark flips the
             * border to white — black is invisible on the dark backdrop). */
            if (dark) cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, i == current_page ? 0.55 : 0.20);
            else cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, i == current_page ? 0.36 : 0.14);
            cairo_set_line_width(cr, i == current_page ? 1.5 : 1.0);
            cairo_rectangle(cr, x + 0.5, y + 0.5, MAX(1.0, rect->w - 1.0), MAX(1.0, rect->h - 1.0));
            cairo_stroke(cr);
        }
        minimap_draw_search_markers(self, cr, &f, first, last);
    }

    minimap_frame_viewport_rect(&f, &vx, &vy, &vw, &vh);
    vy = MAX(1.0, MIN(vy, f.height - 1.0));
    vh = MAX(1.0, MIN(vh, f.height - vy - 1.0));
    /* Viewport: same blue family, lifted for dark so the stroke clears the
     * dark backdrop (the light stroke reads near-black there). */
    if (dark) cairo_set_source_rgba(cr, 0.40, 0.62, 0.92, 0.22);
    else cairo_set_source_rgba(cr, 0.18, 0.48, 0.86, 0.18);
    cairo_rectangle(cr, vx, vy, vw, vh);
    cairo_fill(cr);
    if (dark) cairo_set_source_rgba(cr, 0.55, 0.72, 0.98, 0.95);
    else cairo_set_source_rgba(cr, 0.06, 0.36, 0.76, 0.95);
    cairo_set_line_width(cr, 1.3);
    cairo_rectangle(cr, vx + 0.5, vy + 0.5, MAX(1.0, vw - 1.0), MAX(1.0, vh - 1.0));
    cairo_stroke(cr);

    minimap_frame_release(&f);
}

/* --------------------------------------------------------------------------- */
/* Scrolling the document from strip coordinates. */

/* Pan the document horizontally so the strip x fraction of the page holding
 * doc_center_y lands under the viewport center (Mac
 * longDocumentDragDocumentXForStripX / GTK3 minimap_document_center_x). */
static void minimap_follow_horizontal(const minimap_frame* f, double doc_center_y, double strip_x) {
    if (!f->hadj) return;
    if (gtk_adjustment_get_upper(f->hadj) - gtk_adjustment_get_page_size(f->hadj) <= 0.5) return;
    for (int i = 0; i < f->count; ++i) {
        double x_fraction;
        double doc_x;
        if (doc_center_y < f->doc_y[i] || doc_center_y > f->doc_y[i] + f->doc_h[i]) continue;
        x_fraction = CLAMP((strip_x - f->strip.rects[i].x) / MAX(1.0, f->strip.rects[i].w), 0.0, 1.0);
        doc_x = f->doc_x[i] + x_fraction * f->doc_w[i];
        gtk_adjustment_set_value(f->hadj, doc_x - gtk_adjustment_get_page_size(f->hadj) * 0.5);
        return;
    }
}

/* Center the document viewport on the document point under a widget-space
 * strip point. content_top depends on the resulting scroll, so iterate to a
 * fixed point like the Mac documentPointForMinimapCenterPoint. */
static void minimap_center_document_at(const minimap_frame* f, double widget_x, double widget_y) {
    double content_top = f->content_top;
    double max_scroll = MAX(0.0, f->doc_upper - f->doc_visible_h);
    double doc_yv = f->doc_top + f->doc_visible_h * 0.5;
    double target = f->doc_top;

    if (!f->vadj) return;
    if (widget_y <= 0.0) {
        target = 0.0;
    } else if (widget_y >= f->height - 1.0) {
        target = max_scroll;
    } else {
        for (int k = 0; k < MINIMAP_CENTER_ITERATIONS; ++k) {
            double fraction;
            doc_yv = spdf_minimap_document_y_for_strip_y(&f->strip, f->doc_y, f->doc_h, f->count,
                                                         widget_y - content_top);
            target = CLAMP(doc_yv - f->doc_visible_h * 0.5, 0.0, max_scroll);
            fraction = max_scroll > 0.0 ? target / max_scroll : 0.0;
            content_top = spdf_minimap_content_top(f->strip.content_h, f->height, fraction);
        }
    }
    gtk_adjustment_set_value(f->vadj, target);
    minimap_follow_horizontal(f, doc_yv, widget_x);
}

/* --------------------------------------------------------------------------- */
/* Gestures. */

static void minimap_kinetic_cancel(SpdfMinimap* self); /* defined with the scroll section below */

static void minimap_reset_press(SpdfMinimap* self) {
    self->press_pending = FALSE;
    self->drag_moved = FALSE;
    self->dragging_viewport = FALSE;
    self->press_x = self->press_y = 0.0;
    self->drag_offset_center_x = self->drag_offset_center_y = 0.0;
    self->drag_thumb_top = 0.0;
    self->drag_last_y = 0.0;
    self->drag_last_time_us = 0;
}

static void minimap_drag_begin(GtkGestureDrag* gesture, double x, double y, gpointer user_data) {
    SpdfMinimap* self = SPDF_MINIMAP(user_data);
    minimap_frame f;
    double vx;
    double vy;
    double vw;
    double vh;

    (void)gesture;
    minimap_kinetic_cancel(self); /* press/drag/click stops the momentum tail */
    minimap_reset_press(self);
    if (!minimap_frame_acquire(self, &f)) return;
    self->press_pending = TRUE;
    self->press_x = x;
    self->press_y = y;
    minimap_frame_viewport_rect(&f, &vx, &vy, &vw, &vh);
    self->dragging_viewport = x >= vx && x <= vx + vw && y >= vy && y <= vy + vh;
    if (self->dragging_viewport) {
        self->drag_offset_center_x = x - (vx + vw * 0.5);
        self->drag_offset_center_y = y - (vy + vh * 0.5);
        if (spdf_minimap_use_long_document_drag(f.sizes, f.count)) {
            double track_h = MAX(1.0, f.height - 2.0);
            double thumb_h = spdf_minimap_drag_thumb_height(f.doc_visible_h, f.doc_upper, track_h);
            double min_top = 1.0;
            double max_top = MAX(min_top, f.height - thumb_h - 1.0);
            double max_scroll = MAX(0.0, f.doc_upper - f.doc_visible_h);
            double fraction = max_scroll > 0.0 ? CLAMP(f.doc_top / max_scroll, 0.0, 1.0) : 0.0;
            self->drag_thumb_top = min_top + fraction * (max_top - min_top);
        }
    }
    self->drag_last_y = y;
    self->drag_last_time_us = g_get_monotonic_time();
    if (self->tab && self->tab->view) gtk_widget_grab_focus(GTK_WIDGET(self->tab->view));
    minimap_frame_release(&f);
}

static void minimap_drag_update(GtkGestureDrag* gesture, double offset_x, double offset_y, gpointer user_data) {
    SpdfMinimap* self = SPDF_MINIMAP(user_data);
    double x = self->press_x + offset_x;
    double y = self->press_y + offset_y;
    minimap_frame f;

    (void)gesture;
    if (!self->press_pending && !self->drag_moved) return;
    if (!self->drag_moved && hypot(offset_x, offset_y) < MINIMAP_DRAG_THRESHOLD) return;
    self->drag_moved = TRUE;
    self->press_pending = FALSE;
    if (!minimap_frame_acquire(self, &f)) return;

    if (self->dragging_viewport && spdf_minimap_use_long_document_drag(f.sizes, f.count)) {
        /* Mac accelerated long-document drag: the thumb moves on a track. */
        double track_h = MAX(1.0, f.height - 2.0);
        double thumb_h = spdf_minimap_drag_thumb_height(f.doc_visible_h, f.doc_upper, track_h);
        double min_top = 1.0;
        double max_top = MAX(min_top, f.height - thumb_h - 1.0);
        gint64 now = g_get_monotonic_time();
        double delta_t = (double)(now - self->drag_last_time_us) / (double)G_USEC_PER_SEC;
        double delta_y = y - self->drag_last_y;
        double scale = spdf_minimap_long_drag_scale(delta_y, delta_t, f.count);
        double fraction;
        double max_scroll = MAX(0.0, f.doc_upper - f.doc_visible_h);

        self->drag_thumb_top = CLAMP(self->drag_thumb_top + delta_y * scale, min_top, max_top);
        self->drag_last_y = y;
        self->drag_last_time_us = now;
        fraction = max_top <= min_top ? 0.0 : (self->drag_thumb_top - min_top) / (max_top - min_top);
        if (f.vadj) gtk_adjustment_set_value(f.vadj, fraction * max_scroll);
        minimap_follow_horizontal(&f, fraction * max_scroll + f.doc_visible_h * 0.5,
                                  x - self->drag_offset_center_x);
    } else if (self->dragging_viewport) {
        /* 1:1 drag: the grabbed point keeps its offset from the rect center. */
        minimap_center_document_at(&f, x - self->drag_offset_center_x, y - self->drag_offset_center_y);
    } else {
        /* Drag outside the viewport rect scrubs the document (GTK3
         * minimap_scroll_to_y). */
        minimap_center_document_at(&f, x, y);
    }
    gtk_widget_queue_draw(GTK_WIDGET(self));
    minimap_frame_release(&f);
}

static void minimap_drag_end(GtkGestureDrag* gesture, double offset_x, double offset_y, gpointer user_data) {
    SpdfMinimap* self = SPDF_MINIMAP(user_data);

    (void)gesture;
    (void)offset_x;
    (void)offset_y;
    if (self->press_pending && !self->drag_moved) {
        /* Click-to-jump: center the viewport on the clicked page point (Mac
         * minimapViewDidRequestCenterOnPage). */
        minimap_frame f;
        if (minimap_frame_acquire(self, &f)) {
            int page = -1;
            double x_fraction = 0.5;
            double y_fraction = 0.0;
            if (spdf_minimap_page_hit(&f.strip, self->press_x, self->press_y - f.content_top, &page, &x_fraction,
                                      &y_fraction) &&
                f.vadj) {
                double target_y = f.doc_y[page] + y_fraction * f.doc_h[page];
                gtk_adjustment_set_value(f.vadj, target_y - f.doc_visible_h * 0.5);
                minimap_follow_horizontal(&f, target_y, f.strip.rects[page].x + x_fraction * f.strip.rects[page].w);
                gtk_widget_queue_draw(GTK_WIDGET(self));
            }
            minimap_frame_release(&f);
        }
    }
    minimap_reset_press(self);
}

/* Stop the momentum tail. Called from every competing input (new scroll,
 * press/drag, Ctrl+zoom), on unmap (tab switch hides the strip) and on
 * document change/dispose. */
static void minimap_kinetic_cancel(SpdfMinimap* self) {
    if (self->kinetic_tick_id) {
        gtk_widget_remove_tick_callback(GTK_WIDGET(self), self->kinetic_tick_id);
        self->kinetic_tick_id = 0;
    }
    self->kinetic_velocity = 0.0;
}

/* Apply one strip-scroll step of strip_dy px through the shared model (Mac
 * db9515802 spdf_minimap_document_top_for_strip_scroll). Returns -1 without
 * a frame (no document/degenerate layout), 0 when the document position did
 * not move (clamped at an end), 1 when it moved. */
static int minimap_apply_strip_scroll(SpdfMinimap* self, double strip_dy, gboolean discrete_wheel) {
    minimap_frame f;
    double available;
    double new_top;
    int moved;

    if (!minimap_frame_acquire(self, &f)) return -1;
    available = MAX(1.0, f.height - SPDF_MINIMAP_EDGE_INSET);
    new_top = spdf_minimap_document_top_for_strip_scroll(f.doc_top, strip_dy, f.strip.content_h, available, f.doc_upper,
                                                         f.doc_visible_h);
    if (discrete_wheel) {
        new_top = spdf_minimap_document_top_capped_for_discrete_wheel(f.doc_top, new_top,
                                                                      spdf_doc_view_current_page(f.view), f.doc_y,
                                                                      f.doc_h, f.count, f.doc_upper, f.doc_visible_h);
    }
    moved = fabs(new_top - f.doc_top) > 0.001 ? 1 : 0;
    if (f.vadj) gtk_adjustment_set_value(f.vadj, new_top);
    gtk_widget_queue_draw(GTK_WIDGET(self));
    minimap_frame_release(&f);
    return moved;
}

/* Frame-clock tick of the momentum tail: advance the GtkKineticScrolling
 * decay (spdf_minimap_kinetic_step) and feed the covered strip distance
 * through the same strip-scroll model as live wheel events. */
static gboolean minimap_kinetic_tick(GtkWidget* widget, GdkFrameClock* clock, gpointer user_data) {
    SpdfMinimap* self = SPDF_MINIMAP(user_data);
    gint64 now = gdk_frame_clock_get_frame_time(clock);
    double dt_s = (double)(now - self->kinetic_last_us) / (double)G_USEC_PER_SEC;
    double strip_dy;
    (void)widget;

    self->kinetic_last_us = now;
    strip_dy = spdf_minimap_kinetic_step(&self->kinetic_velocity, dt_s);
    /* Stop at the decay threshold or when the document stopped moving (the
     * strip-scroll clamp caught an end of the document). */
    if (minimap_apply_strip_scroll(self, strip_dy, FALSE) != 1 || spdf_minimap_kinetic_done(self->kinetic_velocity)) {
        self->kinetic_tick_id = 0;
        self->kinetic_velocity = 0.0;
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

/* "::decelerate" (GTK_EVENT_CONTROLLER_SCROLL_KINETIC): the fingers left the
 * touchpad with vel_y px/s imprinted. The Mac gets this for free — AppKit
 * keeps sending momentumPhase events through sendStripScrollForEvent:
 * (SPDFMacMinimapView.mm: "a flick traverses the document at the strip's
 * page-per-pixel scale, momentum included") — GTK animates the decay itself. */
static void minimap_scroll_decelerate(GtkEventControllerScroll* controller, double vel_x, double vel_y,
                                      gpointer user_data) {
    SpdfMinimap* self = SPDF_MINIMAP(user_data);
    GdkModifierType state = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(controller));
    (void)vel_x;

    if (state & GDK_CONTROL_MASK) return; /* the fling was zooming, not strip-scrolling */
    if (gtk_event_controller_scroll_get_unit(controller) == GDK_SCROLL_UNIT_WHEEL)
        vel_y *= SPDF_MINIMAP_WHEEL_POINTS_PER_LINE;
    if (spdf_minimap_kinetic_done(vel_y)) return;
    self->kinetic_velocity = vel_y;
    self->kinetic_last_us = g_get_monotonic_time(); /* same clock as the frame clock */
    if (!self->kinetic_tick_id)
        self->kinetic_tick_id = gtk_widget_add_tick_callback(GTK_WIDGET(self), minimap_kinetic_tick, self, NULL);
}

/* Ctrl+scroll over the strip zooms the DOCUMENT, anchored at the document
 * point under the strip cursor (Mac scrollWheel: command/control branch ->
 * minimapViewDidReceiveZoomScrollWheel:documentPoint:, which anchors the
 * zoom at that document point). Previously the event was propagated and died
 * on a sibling widget without ever reaching the doc view. */
static gboolean minimap_forward_zoom_scroll(SpdfMinimap* self, double dy) {
    minimap_frame f;
    double doc_px;
    double doc_py;

    if (!minimap_frame_acquire(self, &f)) return GDK_EVENT_PROPAGATE;
    if (self->pointer_valid) {
        int page = -1;
        double x_fraction = 0.5;
        double y_fraction = 0.0;
        doc_py = spdf_minimap_document_y_for_strip_y(&f.strip, f.doc_y, f.doc_h, f.count,
                                                     self->pointer_y - f.content_top);
        if (spdf_minimap_page_hit(&f.strip, self->pointer_x, self->pointer_y - f.content_top, &page, &x_fraction,
                                  &y_fraction))
            doc_px = f.doc_x[page] + x_fraction * f.doc_w[page];
        else
            doc_px = f.doc_left + f.doc_visible_w * 0.5; /* strip gap: keep the horizontal center */
        /* Doc-view widget coordinates = document space minus its scroll. */
        spdf_doc_view_zoom_scroll(f.view, dy, TRUE, doc_px - f.doc_left, doc_py - f.doc_top);
    } else {
        spdf_doc_view_zoom_scroll(f.view, dy, FALSE, 0.0, 0.0); /* visible-center fallback */
    }
    minimap_frame_release(&f);
    return GDK_EVENT_STOP;
}

/* Strip-scroll (Mac db9515802): the gesture moves the STRIP by its own
 * distance; the document follows at the maxDoc/maxStrip ratio, which keeps
 * the strip glued 1:1 to the gesture because the strip offset derives from
 * the document position. */
static gboolean minimap_scroll(GtkEventControllerScroll* controller, double dx, double dy, gpointer user_data) {
    SpdfMinimap* self = SPDF_MINIMAP(user_data);
    GdkModifierType state = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(controller));
    double strip_dy = dy;
    gboolean discrete_wheel;

    (void)dx;
    minimap_kinetic_cancel(self); /* any new scroll input supersedes the tail */
    if (state & GDK_CONTROL_MASK) return minimap_forward_zoom_scroll(self, dy);
    discrete_wheel = gtk_event_controller_scroll_get_unit(controller) == GDK_SCROLL_UNIT_WHEEL;
    if (discrete_wheel) strip_dy *= SPDF_MINIMAP_WHEEL_POINTS_PER_LINE;
    /* No frame (no document): keep the historical fall-through to siblings. */
    return minimap_apply_strip_scroll(self, strip_dy, discrete_wheel) < 0 ? GDK_EVENT_PROPAGATE : GDK_EVENT_STOP;
}

static void minimap_motion(GtkEventControllerMotion* controller, double x, double y, gpointer user_data) {
    SpdfMinimap* self = SPDF_MINIMAP(user_data);
    (void)controller;
    self->pointer_x = x;
    self->pointer_y = y;
    self->pointer_valid = TRUE;
}

static void minimap_motion_leave(GtkEventControllerMotion* controller, gpointer user_data) {
    SpdfMinimap* self = SPDF_MINIMAP(user_data);
    (void)controller;
    self->pointer_valid = FALSE;
}

static void minimap_unmap_cb(GtkWidget* widget, gpointer user_data) {
    (void)widget;
    /* Tab switch / strip hidden: the momentum tail must not keep scrolling
     * an invisible document. */
    minimap_kinetic_cancel(SPDF_MINIMAP(user_data));
}

/* --------------------------------------------------------------------------- */
/* Visibility + persistence. */

static gboolean minimap_should_show(SpdfMinimap* self) {
    SpdfTab* tab = self->tab;
    return tab && tab->doc && tab->show_minimap && !(tab->win && spdf_window_get_presentation(tab->win));
}

static void minimap_sync_visible(SpdfMinimap* self) {
    gtk_widget_set_visible(GTK_WIDGET(self), minimap_should_show(self));
}

/* documents.json upsert; the update API stamps both view prefs, so the
 * sidebar value is carried forward (existing entry, else the settings
 * default) rather than clobbered. */
static void minimap_persist_doc_state(SpdfTab* tab) {
    SpdfState* state = minimap_state_for_tab(tab);
    SpdfSettings* settings = state ? spdf_state_settings(state) : NULL;
    const SpdfDocState* existing;
    SpdfDocState doc_state;
    char* title;

    if (!state || !tab->path || !*tab->path) return;
    existing = spdf_state_document_lookup(state, tab->path);
    memset(&doc_state, 0, sizeof(doc_state));
    title = spdf_tab_display_name(tab);
    doc_state.path = tab->path;
    doc_state.title = title;
    doc_state.show_sidebar = existing && existing->has_show_sidebar
                                 ? existing->show_sidebar
                                 : (settings ? settings->default_sidebar_visible : TRUE);
    doc_state.show_minimap = tab->show_minimap;
    spdf_state_document_update(state, &doc_state);
    g_free(title);
}

void spdf_minimap_set_visible(SpdfTab* tab, gboolean show, gboolean persist) {
    if (!tab) return;
    tab->show_minimap = show;
    if (tab->minimap && SPDF_IS_MINIMAP(tab->minimap)) minimap_sync_visible(SPDF_MINIMAP(tab->minimap));
    if (persist) minimap_persist_doc_state(tab);
    if (tab->win) spdf_minimap_window_sync(tab->win);
}

void spdf_minimap_document_changed(SpdfTab* tab) {
    SpdfMinimap* self;

    if (!tab || !tab->minimap || !SPDF_IS_MINIMAP(tab->minimap)) return;
    self = SPDF_MINIMAP(tab->minimap);
    minimap_kinetic_cancel(self); /* the flicked document is gone */
    minimap_orphan_pending(self);
    spdf_lru_remove_all(&self->thumbs);
    self->thumbs.total_bytes = 0;
    self->window = spdf_minimap_thumb_window_empty();
    gtk_widget_queue_draw(GTK_WIDGET(self));
}

/* --------------------------------------------------------------------------- */
/* win.minimap action (registered here, listed in the spdf_shortcuts.c table;
 * no accelerator — neither GTK3 nor the Mac app bound a key). */

static void minimap_change_state(GSimpleAction* action, GVariant* value, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);

    g_simple_action_set_state(action, value);
    if (tab) spdf_minimap_set_visible(tab, g_variant_get_boolean(value), TRUE);
}

void spdf_minimap_window_sync(SpdfWindow* win) {
    GAction* action;
    SpdfTab* tab;

    g_return_if_fail(SPDF_IS_WINDOW(win));
    action = g_action_map_lookup_action(G_ACTION_MAP(win), "minimap");
    if (!action) return;
    tab = spdf_window_current_tab(win);
    g_simple_action_set_enabled(G_SIMPLE_ACTION(action), tab != NULL);
    /* set_state (not change-state) so syncing never re-persists. */
    g_simple_action_set_state(G_SIMPLE_ACTION(action), g_variant_new_boolean(tab ? tab->show_minimap : FALSE));
}

static void minimap_selected_page_changed(GObject* object, GParamSpec* pspec, gpointer user_data) {
    (void)object;
    (void)pspec;
    spdf_minimap_window_sync(SPDF_WINDOW(user_data));
}

void spdf_minimap_install(SpdfWindow* win) {
    static const GActionEntry entries[] = {
        /* Stateful; activating with no parameter toggles via change-state. */
        {"minimap", NULL, NULL, "true", minimap_change_state, {0}},
    };
    AdwTabView* view;

    g_return_if_fail(SPDF_IS_WINDOW(win));
    g_action_map_add_action_entries(G_ACTION_MAP(win), entries, G_N_ELEMENTS(entries), win);
    view = spdf_window_get_tab_view(win);
    if (view)
        g_signal_connect_object(view, "notify::selected-page", G_CALLBACK(minimap_selected_page_changed), win, 0);
    spdf_minimap_window_sync(win);
}

/* --------------------------------------------------------------------------- */
/* Widget lifecycle. */

static void minimap_queue_draw_cb(gpointer ignored, gpointer user_data) {
    (void)ignored;
    gtk_widget_queue_draw(GTK_WIDGET(user_data));
}

/* GtkAdjustment value-changed / doc-view page-changed(int) / zoom-changed
 * (double) / search matches-changed all just repaint; the extra parameters of
 * the int/double signals land in unused varargs slots of the closure. */
static void minimap_adjustment_changed(GtkAdjustment* adjustment, gpointer user_data) {
    (void)adjustment;
    gtk_widget_queue_draw(GTK_WIDGET(user_data));
}

static void minimap_view_page_changed(SpdfDocView* view, int page, gpointer user_data) {
    (void)view;
    (void)page;
    gtk_widget_queue_draw(GTK_WIDGET(user_data));
}

static void minimap_view_zoom_changed(SpdfDocView* view, double zoom, gpointer user_data) {
    (void)view;
    (void)zoom;
    gtk_widget_queue_draw(GTK_WIDGET(user_data));
}

static void minimap_search_current_changed(SpdfSearchController* controller, int index, gpointer user_data) {
    (void)controller;
    (void)index;
    gtk_widget_queue_draw(GTK_WIDGET(user_data));
}

static void minimap_presentation_state_changed(GObject* action, GParamSpec* pspec, gpointer user_data) {
    (void)action;
    (void)pspec;
    minimap_sync_visible(SPDF_MINIMAP(user_data));
}

/* Wave D dark-mode audit: theme flips repaint with the other palette. */
static void minimap_style_dark_changed(GObject* manager, GParamSpec* pspec, gpointer user_data) {
    (void)manager;
    (void)pspec;
    gtk_widget_queue_draw(GTK_WIDGET(user_data));
}

static void spdf_minimap_dispose(GObject* object) {
    SpdfMinimap* self = SPDF_MINIMAP(object);

    minimap_kinetic_cancel(self);
    minimap_orphan_pending(self);
    g_clear_pointer(&self->pending, g_hash_table_destroy);
    spdf_lru_deinit(&self->thumbs);
    self->tab = NULL;
    G_OBJECT_CLASS(spdf_minimap_parent_class)->dispose(object);
}

static void spdf_minimap_class_init(SpdfMinimapClass* klass) {
    GObjectClass* object_class = G_OBJECT_CLASS(klass);
    object_class->dispose = spdf_minimap_dispose;
    gtk_widget_class_set_css_name(GTK_WIDGET_CLASS(klass), "spdf-minimap");
}

static void spdf_minimap_init(SpdfMinimap* self) {
    GtkGesture* drag;
    GtkEventController* scroll;
    GtkEventController* motion;

    spdf_lru_init(&self->thumbs, SPDF_MINIMAP_THUMB_MAX_BYTES, g_direct_hash, g_direct_equal, NULL,
                  minimap_thumb_free);
    self->pending = g_hash_table_new(g_direct_hash, g_direct_equal);
    self->window = spdf_minimap_thumb_window_empty();

    gtk_widget_set_vexpand(GTK_WIDGET(self), TRUE);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(self), minimap_draw, self, NULL);

    drag = gtk_gesture_drag_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(drag), GDK_BUTTON_PRIMARY);
    g_signal_connect(drag, "drag-begin", G_CALLBACK(minimap_drag_begin), self);
    g_signal_connect(drag, "drag-update", G_CALLBACK(minimap_drag_update), self);
    g_signal_connect(drag, "drag-end", G_CALLBACK(minimap_drag_end), self);
    gtk_widget_add_controller(GTK_WIDGET(self), GTK_EVENT_CONTROLLER(drag));

    /* KINETIC: "::decelerate" reports the fling velocity when the fingers
     * leave the touchpad; the momentum tail is animated on the frame clock
     * (minimap_kinetic_tick). */
    scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL |
                                             GTK_EVENT_CONTROLLER_SCROLL_KINETIC);
    g_signal_connect(scroll, "scroll", G_CALLBACK(minimap_scroll), self);
    g_signal_connect(scroll, "decelerate", G_CALLBACK(minimap_scroll_decelerate), self);
    gtk_widget_add_controller(GTK_WIDGET(self), scroll);

    /* Pointer position for the Ctrl+scroll zoom anchor (Mac
     * documentPointForEvent:). */
    motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(minimap_motion), self);
    g_signal_connect(motion, "enter", G_CALLBACK(minimap_motion), self);
    g_signal_connect(motion, "leave", G_CALLBACK(minimap_motion_leave), self);
    gtk_widget_add_controller(GTK_WIDGET(self), motion);

    g_signal_connect(self, "unmap", G_CALLBACK(minimap_unmap_cb), self);

    /* Wave D dark-mode audit: minimap_draw picks its palette per paint;
     * repaint when the app-wide dark state flips (object-scoped, detaches
     * with the widget). */
    g_signal_connect_object(adw_style_manager_get_default(), "notify::dark",
                            G_CALLBACK(minimap_style_dark_changed), self, 0);
}

GtkWidget* spdf_minimap_new(SpdfTab* tab) {
    SpdfMinimap* self = g_object_new(SPDF_TYPE_MINIMAP, NULL);
    SpdfState* state = minimap_state_for_tab(tab);
    SpdfSettings* settings = state ? spdf_state_settings(state) : NULL;
    const SpdfDocState* doc_state;
    int width = MINIMAP_FALLBACK_WIDTH;

    g_return_val_if_fail(tab != NULL, GTK_WIDGET(self));
    self->tab = tab;

    if (settings && settings->minimap_width > 0.0)
        width = (int)CLAMP(settings->minimap_width, MINIMAP_MIN_WIDTH, MINIMAP_MAX_WIDTH);
    gtk_widget_set_size_request(GTK_WIDGET(self), width, -1);

    /* Initial visibility: documents.json showMinimap when the document has
     * been seen before, else the settings default (Mac semantics; a stored
     * session value overrides later via spdf_minimap_set_visible). */
    doc_state = state ? spdf_state_document_lookup(state, tab->path) : NULL;
    tab->show_minimap = doc_state && doc_state->has_show_minimap
                            ? doc_state->show_minimap
                            : (settings ? settings->default_minimap_visible : TRUE);
    minimap_sync_visible(self);

    /* Live tracking; object-scoped connections detach with the widget. */
    if (tab->view) {
        GtkAdjustment* vadj = gtk_scrollable_get_vadjustment(GTK_SCROLLABLE(tab->view));
        GtkAdjustment* hadj = gtk_scrollable_get_hadjustment(GTK_SCROLLABLE(tab->view));
        g_signal_connect_object(tab->view, "page-changed", G_CALLBACK(minimap_view_page_changed), self, 0);
        g_signal_connect_object(tab->view, "zoom-changed", G_CALLBACK(minimap_view_zoom_changed), self, 0);
        if (vadj) {
            g_signal_connect_object(vadj, "value-changed", G_CALLBACK(minimap_adjustment_changed), self, 0);
            g_signal_connect_object(vadj, "changed", G_CALLBACK(minimap_adjustment_changed), self, 0);
        }
        if (hadj)
            g_signal_connect_object(hadj, "value-changed", G_CALLBACK(minimap_adjustment_changed), self, 0);
    }
    if (tab->search) {
        g_signal_connect_object(tab->search, "matches-changed", G_CALLBACK(minimap_queue_draw_cb), self, 0);
        g_signal_connect_object(tab->search, "current-changed", G_CALLBACK(minimap_search_current_changed), self, 0);
    }
    if (tab->win) {
        GAction* presentation = g_action_map_lookup_action(G_ACTION_MAP(tab->win), "presentation");
        if (presentation)
            g_signal_connect_object(presentation, "notify::state", G_CALLBACK(minimap_presentation_state_changed),
                                    self, 0);
    }
    return GTK_WIDGET(self);
}
