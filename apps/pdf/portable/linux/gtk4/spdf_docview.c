/* spdf_docview.c — the page canvas: a custom GtkWidget (snapshot + GdkTexture,
 * no GtkImage-per-page) implementing GtkScrollable so it lives inside the
 * shell's GtkScrolledWindow.
 *
 * Ported logic provenance (portable/linux/ShenzhenPDFGtk.c unless noted):
 *   - continuous layout with per-page slots hugging the page aspect, centered
 *     on the canvas midline: render_current_page slot build +
 *     configure_page_image + Mac SPDFDocumentView ensureLayoutCache
 *     (spdf_layout_* in spdf_docview_internal.h);
 *   - anchored Ctrl+wheel zoom: page_scroll_event + apply_zoom_anchored +
 *     capture_zoom_anchor + zoom_anchor_scroll_idle, with the anchor held in
 *     DOCUMENT space so pixel-capped giant sheets no longer drift;
 *   - pinch zoom: pinch_zoom_begin / pinch_zoom_scale_changed (GtkGestureZoom
 *     ports as-is per the migration audit);
 *   - zoom settle re-render with scaled stale textures shown meanwhile:
 *     zoom_preview_begin/zoom_preview_to/zoom_settle_timeout (the snapshot
 *     path scales stale textures for free by stretching them into the new
 *     slot rects);
 *   - horizontal clamp: clamp_horizontal_scroll (policy from TOTAL content
 *     width — baked into the layout since canvas_w = max(viewport, content));
 *   - scroll-settle maintenance (neighbor renders + eviction):
 *     vertical_scroll_changed + arm_scroll_settle_timeout +
 *     scroll_settle_timeout + evict_distant_page_surfaces;
 *   - current-page tracking: scroll_page_center_nearest binary search;
 *   - keys: the page/arrow branch of key_press_event;
 *   - dynamic selection and deferred links: spdf_docview_selection;
 *   - I-beam/hand cursor regions: spdf_cursor_region_at_point, built per page
 *     off the main thread including plain-text URLs;
 *   - shift+arrow page flip preserving the in-page view:
 *     go_to_adjacent_page_preserving_view.
 */

#include <math.h>
#include <string.h>

#include "spdf_docview_internal.h"
#include "spdf_docview_selection.h"
#include "spdf_internal.h"
#include "spdf_password.h"
#include "spdf_search.h" /* declares this file's search-integration section */

#define ZOOM_WHEEL_STEP 1.1
#define ZOOM_SETTLE_DELAY_MS 120
#define SCROLL_SETTLE_DELAY_MS 200
#define ARROW_SCROLL_STEP 54.0
#define NEIGHBOR_RENDER_RADIUS 2
#define TEXTURE_KEEP_RADIUS 10
#define LINK_CLICK_DRAG_THRESHOLD 4.0

typedef struct {
    GdkTexture* full; /* whole-page texture (render scale may be byte-capped) */
    double full_scale;
    guint64 full_token; /* outstanding request; 0 = none */
    double full_pending_scale;
    GdkTexture* crop;       /* viewport crop for pages in the crop regime */
    GdkRectangle crop_rect; /* page-space device px at crop_scale */
    double crop_scale;
    guint64 crop_token;
    GdkRectangle crop_pending_rect;
    double crop_pending_scale;
} page_slot;

/* Per-request context. The view orphans these on dispose (view = NULL); the
 * render service guarantees the done callback fires exactly once on the main
 * thread, which is where the context is freed. */
typedef struct {
    SpdfDocView* view;
    int page;
    gboolean is_crop;
} render_ctx;

typedef enum {
    ANCHOR_AT_POINT,
    ANCHOR_AT_CENTER,
    ANCHOR_REUSE
} anchor_mode;

struct _SpdfDocView {
    GtkWidget parent_instance;

    SpdfTab* tab; /* borrowed; outlives the view (spdf_tab.c owns both) */

    /* GtkScrollable */
    GtkAdjustment* hadj;
    GtkAdjustment* vadj;
    GtkScrollablePolicy hscroll_policy;
    GtkScrollablePolicy vscroll_policy;
    gulong hadj_handler;
    gulong vadj_handler;
    gboolean configuring_adjustments;
    gboolean clamping_horizontal;

    /* document geometry */
    SpdfPageSizePt* sizes; /* PDF points, one per page */
    int page_count;
    SpdfLayout layout;
    double zoom;
    SpdfFitMode fit;
    int current_page;
    double viewport_w;
    double viewport_h;

    /* render pipeline */
    page_slot* slots;
    GPtrArray* pending_ctxs; /* render_ctx*, borrowed by in-flight requests */
    guint scroll_settle_id;
    guint zoom_settle_id;
    gboolean zoom_active; /* gesture in flight: stale textures scale, no requests */
    double pinch_begin_zoom;
    SpdfZoomAnchor anchor;

    /* dynamic selection + GTK multi-click/deferred-link arbitration */
    SpdfDocViewSelection selection;

    /* middle-button pan */
    gboolean panning;
    double pan_start_h;
    double pan_start_v;

    /* pointer tracking (Ctrl+wheel zoom anchor) */
    double pointer_x;
    double pointer_y;
    gboolean pointer_valid;

    /* cursor regions, cached per page and built OFF the main thread including
     * plain-text URL detection (Mac SPDFMacCursorRegions model +
     * ShenzhenPDFMac.mm buildCursorRegionsForPageIfNeeded, commit ~@11269) */
    GHashTable* region_cache;    /* GINT_TO_POINTER(page) -> region_entry* */
    GHashTable* region_building; /* set of GINT_TO_POINTER(page) */
    guint region_generation;     /* bumped on document change; stale builds drop */

    /* search-highlight overlay (owned copies; spdf_search.c section at the
     * bottom of this file — see spdf_search.h for the setters) */
    int* search_pages;
    spdf_rect* search_rects;
    int search_count;
    int search_current; /* index into the arrays, -1 = none */

    gboolean first_snapshot_marked;

    /* Wave B (spdf_annot.c): comment markers, drawn as a snapshot overlay
     * following the selection pattern. */
    GArray* comment_markers; /* SpdfCommentMarker */
};

enum {
    PROP_0,
    PROP_HADJUSTMENT,
    PROP_VADJUSTMENT,
    PROP_HSCROLL_POLICY,
    PROP_VSCROLL_POLICY
};
enum {
    SIG_PAGE_CHANGED,
    SIG_ZOOM_CHANGED,
    SIG_SELECTION_CHANGED,
    N_SIGNALS
};
static guint signals[N_SIGNALS];

G_DEFINE_FINAL_TYPE_WITH_CODE(SpdfDocView, spdf_doc_view, GTK_TYPE_WIDGET,
                              G_IMPLEMENT_INTERFACE(GTK_TYPE_SCROLLABLE, NULL))

/* --------------------------------------------------------------------------- */

static spdf_document* view_doc(SpdfDocView* view) {
    return view->tab ? view->tab->doc : NULL;
}

static SpdfRenderService* view_render(SpdfDocView* view) {
    return view->tab ? view->tab->render : NULL;
}

static double view_margin_h(SpdfDocView* view) {
    /* GTK3 configure_page_image: fit-width and fit-page drop the horizontal
     * margin, fit-page also the vertical one. */
    return (view->fit == SPDF_FIT_WIDTH || view->fit == SPDF_FIT_PAGE) ? 0.0 : SPDF_PAGE_MARGIN_H;
}

static double view_margin_v(SpdfDocView* view) {
    return (view->fit == SPDF_FIT_PAGE || view->fit == SPDF_FIT_HEIGHT) ? 0.0 : SPDF_PAGE_MARGIN_V;
}

static double view_scroll_x(SpdfDocView* view) {
    return view->hadj ? gtk_adjustment_get_value(view->hadj) : 0.0;
}

static double view_scroll_y(SpdfDocView* view) {
    return view->vadj ? gtk_adjustment_get_value(view->vadj) : 0.0;
}

static double view_render_scale(SpdfDocView* view) {
    return view->zoom * MAX(1, gtk_widget_get_scale_factor(GTK_WIDGET(view)));
}

static void view_relayout(SpdfDocView* view) {
    spdf_layout_compute(&view->layout, view->sizes, view->page_count, view->zoom, view->viewport_w, view_margin_h(view),
                        view_margin_v(view));
}

static void view_configure_adjustment(SpdfDocView* view, GtkAdjustment* adj, double upper, double page_size) {
    double value;
    if (!adj) return;
    value = gtk_adjustment_get_value(adj);
    value = MAX(0.0, MIN(value, MAX(0.0, upper - page_size)));
    view->configuring_adjustments = TRUE;
    gtk_adjustment_configure(adj, value, 0.0, MAX(upper, page_size), ARROW_SCROLL_STEP,
                             MAX(ARROW_SCROLL_STEP, page_size - ARROW_SCROLL_STEP), page_size);
    view->configuring_adjustments = FALSE;
}

static void view_configure_adjustments(SpdfDocView* view) {
    view_configure_adjustment(view, view->hadj, view->layout.canvas_w, view->viewport_w);
    view_configure_adjustment(view, view->vadj, view->layout.canvas_h, view->viewport_h);
}

/* Port of clamp_horizontal_scroll: centers a page that fits the viewport,
 * pans within the page bounds otherwise. The scrollbar-policy half of the
 * June fix is structural here: canvas_w = max(viewport, TOTAL content width),
 * so the h adjustment only scrolls when some page is really wider. */
static void view_clamp_horizontal(SpdfDocView* view) {
    SpdfHScrollClamp clamp;
    double value;

    if (!view->hadj || view->clamping_horizontal || view->layout.count <= 0) return;
    value = gtk_adjustment_get_value(view->hadj);
    clamp = spdf_hscroll_clamp(&view->layout, view->current_page, view->viewport_w, value);
    if (fabs(value - clamp.value) > 0.5) {
        view->clamping_horizontal = TRUE;
        gtk_adjustment_set_value(view->hadj, clamp.value);
        view->clamping_horizontal = FALSE;
    }
}

/* --------------------------------------------------------------------------- */
/* Render scheduling. */

static void view_render_done(GdkTexture* texture, const SpdfRenderSpec* spec, gpointer user_data);

static void view_request_full(SpdfDocView* view, int page, double scale, int priority) {
    page_slot* slot = &view->slots[page];
    SpdfRenderSpec spec;
    render_ctx* ctx;
    SpdfRenderService* svc = view_render(view);

    if (!svc) return;
    if (slot->full && slot->full_scale == scale) return;
    if (slot->full_token && slot->full_pending_scale == scale) return;
    if (slot->full_token) {
        spdf_render_cancel(svc, slot->full_token);
        slot->full_token = 0;
    }
    spec.page = page;
    spec.scale = scale;
    spec.crop.x = spec.crop.y = spec.crop.width = spec.crop.height = 0;
    spec.token = 0;
    ctx = g_new0(render_ctx, 1);
    ctx->view = view;
    ctx->page = page;
    g_ptr_array_add(view->pending_ctxs, ctx);
    slot->full_pending_scale = scale;
    slot->full_token = spdf_render_request(svc, &spec, priority, view_render_done, ctx);
}

/* Desired crop for a page in the crop regime: the visible region of the page
 * in page-space device px, optionally expanded by half a viewport on every
 * side so small pans stay sharp without a re-render (Mac crop prefetch). */
static gboolean view_desired_crop(SpdfDocView* view, int page, double scale, gboolean expand, GdkRectangle* out) {
    const SpdfPageRect* rect = &view->layout.rects[page];
    double sf = view->zoom > 0.0 ? scale / view->zoom : 1.0;
    double vx0 = view_scroll_x(view);
    double vy0 = view_scroll_y(view);
    double x0 = MAX(rect->x, vx0);
    double y0 = MAX(rect->y, vy0);
    double x1 = MIN(rect->x + rect->w, vx0 + view->viewport_w);
    double y1 = MIN(rect->y + rect->h, vy0 + view->viewport_h);
    double dev_w = view->sizes[page].width * scale;
    double dev_h = view->sizes[page].height * scale;
    double expand_x = expand ? view->viewport_w * sf * 0.5 : 0.0;
    double expand_y = expand ? view->viewport_h * sf * 0.5 : 0.0;

    if (x1 <= x0 || y1 <= y0) return FALSE;
    x0 = (x0 - rect->x) * sf - expand_x;
    x1 = (x1 - rect->x) * sf + expand_x;
    y0 = (y0 - rect->y) * sf - expand_y;
    y1 = (y1 - rect->y) * sf + expand_y;
    x0 = MAX(0.0, x0);
    y0 = MAX(0.0, y0);
    x1 = MIN(dev_w, x1);
    y1 = MIN(dev_h, y1);
    if (x1 <= x0 || y1 <= y0) return FALSE;
    out->x = (int)floor(x0);
    out->y = (int)floor(y0);
    out->width = MAX(1, (int)ceil(x1) - out->x);
    out->height = MAX(1, (int)ceil(y1) - out->y);
    return TRUE;
}

static gboolean crop_contains(const GdkRectangle* outer, double outer_scale, const GdkRectangle* inner,
                              double inner_scale) {
    if (outer_scale != inner_scale) return FALSE;
    return inner->x >= outer->x && inner->y >= outer->y && inner->x + inner->width <= outer->x + outer->width &&
           inner->y + inner->height <= outer->y + outer->height;
}

static void view_request_crop(SpdfDocView* view, int page, double scale) {
    page_slot* slot = &view->slots[page];
    SpdfRenderService* svc = view_render(view);
    GdkRectangle want;
    GdkRectangle visible_only;
    SpdfRenderSpec spec;
    render_ctx* ctx;

    if (!svc || !view_desired_crop(view, page, scale, TRUE, &want)) return;
    /* Re-request only when the *visible* region (the unexpanded core of the
     * desired rect) is no longer covered by what we have or await. */
    if (!view_desired_crop(view, page, scale, FALSE, &visible_only)) return;
    if (slot->crop && crop_contains(&slot->crop_rect, slot->crop_scale, &visible_only, scale)) return;
    if (slot->crop_token && crop_contains(&slot->crop_pending_rect, slot->crop_pending_scale, &visible_only, scale))
        return;
    if (slot->crop_token) {
        spdf_render_cancel(svc, slot->crop_token);
        slot->crop_token = 0;
    }
    spec.page = page;
    spec.scale = scale;
    spec.crop = want;
    spec.token = 0;
    ctx = g_new0(render_ctx, 1);
    ctx->view = view;
    ctx->page = page;
    ctx->is_crop = TRUE;
    g_ptr_array_add(view->pending_ctxs, ctx);
    slot->crop_pending_rect = want;
    slot->crop_pending_scale = scale;
    slot->crop_token = spdf_render_request(svc, &spec, 0, view_render_done, ctx);
}

/* Drops textures and cancels requests for pages far outside the viewport.
 * Port of evict_distant_page_surfaces (RENDERED_PAGE_EVICT_RADIUS). The
 * render service's byte-capped LRU keeps its own copies bounded. */
static void view_evict_distant(SpdfDocView* view) {
    SpdfRenderService* svc = view_render(view);
    for (int p = 0; p < view->page_count; ++p) {
        page_slot* slot = &view->slots[p];
        if (ABS(p - view->current_page) <= TEXTURE_KEEP_RADIUS) continue;
        if (slot->full_token && svc) {
            spdf_render_cancel(svc, slot->full_token);
            slot->full_token = 0;
        }
        if (slot->crop_token && svc) {
            spdf_render_cancel(svc, slot->crop_token);
            slot->crop_token = 0;
        }
        g_clear_object(&slot->full);
        g_clear_object(&slot->crop);
    }
}

/* Visible pages first at full priority, ±2 neighbors near, others none;
 * crop-to-viewport for pages in the crop regime. Port of the GTK3
 * queue_page_render / queue_background_pages_near_current split. */
static void view_schedule_renders(SpdfDocView* view, gboolean include_near) {
    double scale;
    int first = 0;
    int last = -1;
    double y0 = view_scroll_y(view);
    double y1 = y0 + view->viewport_h;

    if (!view_doc(view) || !view_render(view) || view->layout.count <= 0) return;
    if (view->zoom_active) return; /* stale textures scale until the settle render */
    scale = view_render_scale(view);

    if (!spdf_layout_visible_range(&view->layout, y0, y1, &first, &last)) return;
    for (int p = first; p <= last; ++p) {
        view_request_full(view, p, scale, 0);
        if (spdf_slot_needs_crop(&view->layout.rects[p], view->viewport_w, view->viewport_h))
            view_request_crop(view, p, scale);
    }
    if (include_near) {
        for (int d = 1; d <= NEIGHBOR_RENDER_RADIUS; ++d) {
            int before = first - d;
            int after = last + d;
            if (before >= 0 && !spdf_slot_needs_crop(&view->layout.rects[before], view->viewport_w, view->viewport_h))
                view_request_full(view, before, scale, 1);
            if (after < view->page_count &&
                !spdf_slot_needs_crop(&view->layout.rects[after], view->viewport_w, view->viewport_h))
                view_request_full(view, after, scale, 1);
        }
        view_evict_distant(view);
    }
}

static void view_cancel_all_renders(SpdfDocView* view) {
    SpdfRenderService* svc = view_render(view);
    if (!svc || !view->slots) return;
    for (int p = 0; p < view->page_count; ++p) {
        page_slot* slot = &view->slots[p];
        if (slot->full_token) {
            spdf_render_cancel(svc, slot->full_token);
            slot->full_token = 0;
        }
        if (slot->crop_token) {
            spdf_render_cancel(svc, slot->crop_token);
            slot->crop_token = 0;
        }
    }
}

static void view_render_done(GdkTexture* texture, const SpdfRenderSpec* spec, gpointer user_data) {
    render_ctx* ctx = (render_ctx*)user_data;
    SpdfDocView* view = ctx->view;

    if (view) {
        g_ptr_array_remove_fast(view->pending_ctxs, ctx);
        if (ctx->page >= 0 && ctx->page < view->page_count) {
            page_slot* slot = &view->slots[ctx->page];
            if (ctx->is_crop && slot->crop_token == spec->token) {
                slot->crop_token = 0;
                if (texture) {
                    g_clear_object(&slot->crop);
                    slot->crop = texture; /* callee-owned ref adopted */
                    texture = NULL;
                    slot->crop_rect = spec->crop;
                    slot->crop_scale = spec->scale;
                    gtk_widget_queue_draw(GTK_WIDGET(view));
                }
            } else if (!ctx->is_crop && slot->full_token == spec->token) {
                slot->full_token = 0;
                if (texture) {
                    g_clear_object(&slot->full);
                    slot->full = texture;
                    texture = NULL;
                    slot->full_scale = spec->scale;
                    gtk_widget_queue_draw(GTK_WIDGET(view));
                }
            }
        }
    }
    if (texture) g_object_unref(texture); /* superseded or orphaned result */
    g_free(ctx);
}

/* --------------------------------------------------------------------------- */
/* Scroll handling. */

static gboolean view_scroll_settle_timeout(gpointer data) {
    SpdfDocView* view = SPDF_DOC_VIEW(data);
    view->scroll_settle_id = 0;
    view_schedule_renders(view, TRUE);
    return G_SOURCE_REMOVE;
}

static void view_arm_scroll_settle(SpdfDocView* view) {
    if (view->scroll_settle_id) g_source_remove(view->scroll_settle_id);
    view->scroll_settle_id = g_timeout_add(SCROLL_SETTLE_DELAY_MS, view_scroll_settle_timeout, view);
}

static void view_update_current_page(SpdfDocView* view) {
    double mid = view_scroll_y(view) + view->viewport_h * 0.5;
    int page = spdf_layout_page_nearest_center(&view->layout, mid);
    if (page >= 0 && page != view->current_page) {
        view->current_page = page;
        view_clamp_horizontal(view);
        g_signal_emit(view, signals[SIG_PAGE_CHANGED], 0, page);
    }
}

static void on_vadj_value_changed(SpdfDocView* view, GtkAdjustment* adj) {
    (void)adj;
    if (view->configuring_adjustments) return;
    gtk_widget_queue_draw(GTK_WIDGET(view));
    view_update_current_page(view);
    /* Visible pages render immediately (dedup makes this cheap per tick);
     * neighbors + eviction wait for the rest timer (scroll_settle_timeout). */
    view_schedule_renders(view, FALSE);
    view_arm_scroll_settle(view);
}

static void on_hadj_value_changed(SpdfDocView* view, GtkAdjustment* adj) {
    (void)adj;
    if (view->configuring_adjustments) return;
    gtk_widget_queue_draw(GTK_WIDGET(view));
    view_clamp_horizontal(view);
    view_schedule_renders(view, FALSE); /* crop regime pans horizontally too */
    view_arm_scroll_settle(view);
}

static void view_set_scroll_values(SpdfDocView* view, double x, double y) {
    if (view->hadj) gtk_adjustment_set_value(view->hadj, x);
    if (view->vadj) gtk_adjustment_set_value(view->vadj, y);
}

/* --------------------------------------------------------------------------- */
/* Zoom. */

static gboolean view_zoom_settle_timeout(gpointer data) {
    SpdfDocView* view = SPDF_DOC_VIEW(data);
    view->zoom_settle_id = 0;
    if (!view->zoom_active) return G_SOURCE_REMOVE;
    view->zoom_active = FALSE;
    view->anchor.valid = FALSE;
    view_schedule_renders(view, TRUE);
    return G_SOURCE_REMOVE;
}

/* Every zoom entry point funnels through here (port of apply_zoom_anchored +
 * zoom_preview_*): one cancel sweep per gesture, cheap scaled previews from
 * the stale textures, one crisp settle pass ZOOM_SETTLE_DELAY_MS after the
 * last event. */
static void view_apply_zoom(SpdfDocView* view, double new_zoom, anchor_mode mode, double anchor_x, double anchor_y) {
    if (!view_doc(view)) return;
    new_zoom = CLAMP(new_zoom, SPDF_MIN_ZOOM, SPDF_MAX_ZOOM);

    if (!view->zoom_active) {
        /* One sweep per zoom sequence: every in-flight render is superseded
         * and canceled so the pool is free for the settle render (port of
         * zoom_preview_begin's generation bump). */
        view->zoom_active = TRUE;
        view_cancel_all_renders(view);
    }
    if (mode == ANCHOR_AT_POINT) {
        spdf_zoom_anchor_capture(&view->anchor, &view->layout, view->sizes, view->zoom, anchor_x, anchor_y,
                                 view_scroll_x(view), view_scroll_y(view));
    } else if (mode == ANCHOR_AT_CENTER) {
        spdf_zoom_anchor_capture(&view->anchor, &view->layout, view->sizes, view->zoom, view->viewport_w * 0.5,
                                 view->viewport_h * 0.5, view_scroll_x(view), view_scroll_y(view));
    } /* ANCHOR_REUSE keeps the anchor captured at gesture begin */

    if (new_zoom != view->zoom) {
        double sx;
        double sy;
        view->zoom = new_zoom;
        view_relayout(view);
        view_configure_adjustments(view);
        if (spdf_zoom_anchor_apply(&view->anchor, &view->layout, view->zoom, view->viewport_w, view->viewport_h, &sx,
                                   &sy))
            view_set_scroll_values(view, sx, sy);
        view_clamp_horizontal(view);
        view_update_current_page(view);
        gtk_widget_queue_resize(GTK_WIDGET(view));
        gtk_widget_queue_draw(GTK_WIDGET(view));
        g_signal_emit(view, signals[SIG_ZOOM_CHANGED], 0, view->zoom);
    }

    /* Re-arm even when clamped at the bounds so a gesture riding the limit
     * still ends with a crisp pass. */
    if (view->zoom_settle_id) g_source_remove(view->zoom_settle_id);
    view->zoom_settle_id = g_timeout_add(ZOOM_SETTLE_DELAY_MS, view_zoom_settle_timeout, view);
}

static double view_fit_zoom(SpdfDocView* view) {
    const SpdfPageSizePt* size;
    if (view->page_count <= 0 || view->current_page < 0 || view->current_page >= view->page_count) return 0.0;
    size = &view->sizes[view->current_page];
    if (view->fit == SPDF_FIT_WIDTH) return spdf_fit_width_zoom(size->width, view->viewport_w);
    if (view->fit == SPDF_FIT_HEIGHT) return spdf_fit_height_zoom(size->height, view->viewport_h);
    if (view->fit == SPDF_FIT_PAGE)
        return spdf_fit_page_zoom(size->width, size->height, view->viewport_w, view->viewport_h);
    return 0.0;
}

/* --------------------------------------------------------------------------- */
/* Hit testing. */

static gboolean view_page_point_at(SpdfDocView* view, double widget_x, double widget_y, int* page, double* page_x,
                                   double* page_y) {
    double cx = widget_x + view_scroll_x(view);
    double cy = widget_y + view_scroll_y(view);
    int p;
    const SpdfPageRect* rect;

    if (view->layout.count <= 0 || view->zoom <= 0.0) return FALSE;
    p = spdf_layout_page_nearest_center(&view->layout, cy);
    if (p < 0) return FALSE;
    /* nearest-center can land one page off right at a boundary */
    if (cy < view->layout.rects[p].y && p > 0)
        p--;
    else if (cy > view->layout.rects[p].y + view->layout.rects[p].h && p < view->layout.count - 1)
        p++;
    rect = &view->layout.rects[p];
    if (cx < rect->x || cx > rect->x + rect->w || cy < rect->y || cy > rect->y + rect->h) return FALSE;
    if (page) *page = p;
    if (page_x) *page_x = MIN((cx - rect->x) / view->zoom, view->sizes[p].width);
    if (page_y) *page_y = MIN((cy - rect->y) / view->zoom, view->sizes[p].height);
    return TRUE;
}

/* Port of page_point_for_page_from_widget_point: resolve against a fixed page
 * regardless of containment (selection drags leave the page), clamped. */
static void view_page_point_for_page(SpdfDocView* view, int page, double widget_x, double widget_y, double* page_x,
                                     double* page_y) {
    const SpdfPageRect* rect = &view->layout.rects[page];
    double x = (widget_x + view_scroll_x(view) - rect->x) / MAX(0.001, view->zoom);
    double y = (widget_y + view_scroll_y(view) - rect->y) / MAX(0.001, view->zoom);
    if (page_x) *page_x = MAX(0.0, MIN(x, view->sizes[page].width));
    if (page_y) *page_y = MAX(0.0, MIN(y, view->sizes[page].height));
}

/* --------------------------------------------------------------------------- */
/* Selection. */

static gboolean view_has_selection(SpdfDocView* view) {
    return spdf_docview_selection_has_text(&view->selection);
}

/* --------------------------------------------------------------------------- */
/* Links + cursor regions. */

static gboolean external_uri_scheme_allowed(const char* uri) {
    const char* colon;
    gsize len;
    if (!uri || !*uri) return FALSE;
    colon = strchr(uri, ':');
    if (!colon || colon == uri) return FALSE;
    for (const char* p = uri; p < colon; ++p) {
        if (!g_ascii_isalnum(*p) && *p != '+' && *p != '-' && *p != '.') return FALSE;
    }
    len = (gsize)(colon - uri);
    return (len == 4 && g_ascii_strncasecmp(uri, "http", len) == 0) ||
           (len == 5 && g_ascii_strncasecmp(uri, "https", len) == 0) ||
           (len == 6 && g_ascii_strncasecmp(uri, "mailto", len) == 0);
}

static void view_scroll_to_page_point(SpdfDocView* view, int page, double x, double y, gboolean has_point) {
    const SpdfPageRect* rect;
    double target_h;
    double target_v;

    if (page < 0 || page >= view->layout.count) return;
    rect = &view->layout.rects[page];
    if (has_point) {
        target_h = rect->x + x * view->zoom - view->viewport_w * 0.5;
        target_v = rect->y + y * view->zoom - 20.0;
    } else {
        target_h = rect->x + rect->w * 0.5 - view->viewport_w * 0.5;
        target_v = rect->y;
    }
    view_set_scroll_values(view, target_h, target_v);
    view_clamp_horizontal(view);
}

/* Port of open_link_at_page_point: full check including plain-text URLs
 * (detect_text_links=1) because this runs on activation, not hover. */
static gboolean view_open_link_at(SpdfDocView* view, int page, double page_x, double page_y) {
    char err[512];
    spdf_link_target target;
    int hit;

    if (!view_doc(view) || page < 0) return FALSE;
    hit = spdf_link_at_point(view_doc(view), page, (float)page_x, (float)page_y, &target, 1, err, sizeof(err));
    if (hit <= 0) return FALSE;

    if (target.kind == SPDF_LINK_URI && target.uri) {
        if (external_uri_scheme_allowed(target.uri)) {
            GtkRoot* root = gtk_widget_get_root(GTK_WIDGET(view));
            GtkUriLauncher* launcher = gtk_uri_launcher_new(target.uri);
            gtk_uri_launcher_launch(launcher, GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL, NULL, NULL, NULL);
            g_object_unref(launcher);
        }
        spdf_free_link_target(&target);
        return TRUE;
    }
    if (target.kind == SPDF_LINK_INTERNAL && target.page_index >= 0) {
        int dest = CLAMP(target.page_index, 0, view->page_count - 1);
        gboolean has_point = isfinite(target.x) && isfinite(target.y);
        view_scroll_to_page_point(view, dest, target.x, target.y, has_point);
        view_update_current_page(view);
        spdf_free_link_target(&target);
        return TRUE;
    }
    spdf_free_link_target(&target);
    return FALSE;
}

static gboolean view_activate_delayed_link(gpointer user_data, int page, double page_x, double page_y) {
    return view_open_link_at(SPDF_DOC_VIEW(user_data), page, page_x, page_y);
}

/* Cursor-region cache, per page, built off the main thread. Port of
 * ShenzhenPDFMac.mm buildCursorRegionsForPageIfNeeded (commit ~@11269):
 * hover cursor hit-testing runs on every mouse-move, so it never queries the
 * core — per-page text-line and link rects (page space, zoom-independent)
 * are built ONCE per page on a worker thread, INCLUDING text-URL detection
 * (detect_text_links=1 builds the page's stext and would stall the main
 * thread for hundreds of ms on dense pages), and cached until the document's
 * content changes. A page whose cache is still building resolves to "none"
 * (arrow) and the cursor corrects itself when the build lands
 * (view_refresh_cursor_at_pointer = Mac refreshCursorForMouseLocation). */

typedef struct {
    GArray* links; /* spdf_rect: annotation links + plain-text URLs */
    GArray* text;  /* spdf_rect: text-line bounds */
} region_entry;

static void region_entry_free(gpointer data) {
    region_entry* entry = (region_entry*)data;
    if (!entry) return;
    if (entry->links) g_array_free(entry->links, TRUE);
    if (entry->text) g_array_free(entry->text, TRUE);
    g_free(entry);
}

/* Build context. The worker fills the arrays; the main-thread done step
 * adopts them into the cache (or drops them when the generation moved). The
 * view reference is strong, so the done step always finds a live object; the
 * dispose guard is region_cache = NULL. */
typedef struct {
    SpdfDocView* view;         /* strong ref */
    SpdfPasswordSource source; /* working path + credential snapshot */
    int page;
    guint generation;
    GArray* links;
    GArray* text;
} region_build_ctx;
static void view_refresh_cursor_at_pointer(SpdfDocView* view);

/* Main-thread tail: cache the result (empty arrays on failure too — unlike
 * retrying, mouse moves cannot re-kick a doomed build every event, Mac
 * comment) and refresh the cursor under the pointer. */
static gboolean region_build_done(gpointer data) {
    region_build_ctx* ctx = (region_build_ctx*)data;
    SpdfDocView* view = ctx->view;

    if (view->region_building) g_hash_table_remove(view->region_building, GINT_TO_POINTER(ctx->page));
    if (view->region_cache && ctx->generation == view->region_generation && view_doc(view)) {
        region_entry* entry = g_new0(region_entry, 1);
        entry->links = ctx->links;
        entry->text = ctx->text;
        ctx->links = NULL;
        ctx->text = NULL;
        g_hash_table_insert(view->region_cache, GINT_TO_POINTER(ctx->page), entry);
        view_refresh_cursor_at_pointer(view);
    }
    if (ctx->links) g_array_free(ctx->links, TRUE);
    if (ctx->text) g_array_free(ctx->text, TRUE);
    g_object_unref(ctx->view);
    spdf_password_source_clear(&ctx->source);
    g_free(ctx);
    return G_SOURCE_REMOVE;
}

/* Worker: same extraction as the Mac block, against the per-thread persistent
 * worker document (never the tab's main-thread doc — the core is
 * one-thread-per-spdf_document). */
static void region_build_worker(gpointer data, gpointer user_data) {
    region_build_ctx* ctx = (region_build_ctx*)data;
    char err[1024];
    spdf_document* doc = spdf_render_worker_document(&ctx->source, err, sizeof(err));
    (void)user_data;

    if (doc) {
        spdf_text_lines lines;
        spdf_rect rects[SPDF_CURSOR_REGION_MAX_LINK_RECTS];
        int count;

        memset(&lines, 0, sizeof(lines));
        if (spdf_extract_page_text_lines(doc, ctx->page, &lines, err, sizeof(err))) {
            for (int i = 0; i < lines.count; ++i) {
                if (!lines.items[i].text || !*lines.items[i].text) continue;
                spdf_cursor_region_append_rect(ctx->text, &lines.items[i].bounds);
            }
            spdf_free_text_lines(&lines);
        }
        count = spdf_page_link_rects(doc, ctx->page, /*detect_text_links=*/1, rects, SPDF_CURSOR_REGION_MAX_LINK_RECTS,
                                     err, sizeof(err));
        for (int i = 0; i < count; ++i) spdf_cursor_region_append_rect(ctx->links, &rects[i]);
    }
    g_main_context_invoke_full(NULL, G_PRIORITY_DEFAULT, region_build_done, ctx, NULL);
}

/* One serial worker, process-wide (Mac _cursorRegionQueue:
 * maxConcurrentOperationCount = 1) — stext builds are memory-bandwidth heavy
 * and must not compete with the page render pool. */
static GThreadPool* region_pool_get(void) {
    static GThreadPool* pool = NULL;
    static gsize initialized = 0;
    if (g_once_init_enter(&initialized)) {
        pool = g_thread_pool_new(region_build_worker, NULL, 1, FALSE, NULL);
        g_once_init_leave(&initialized, 1);
    }
    return pool;
}

/* The path the render service opened: the shadow working copy when the
 * source is read-only (Mac activeWorkingPath). */
static const char* view_active_path(SpdfDocView* view) {
    if (!view->tab) return NULL;
    return view->tab->working_path ? view->tab->working_path : view->tab->path;
}

/* Cache lookup; a miss kicks the worker build once and returns NULL (arrow
 * cursor) until the build lands. */
static region_entry* view_ensure_cursor_regions(SpdfDocView* view, int page) {
    region_entry* entry;
    const char* path;

    if (!view->region_cache || !view_doc(view) || page < 0) return NULL;
    entry = g_hash_table_lookup(view->region_cache, GINT_TO_POINTER(page));
    if (entry) return entry;
    if (g_hash_table_contains(view->region_building, GINT_TO_POINTER(page))) return NULL;
    path = view_active_path(view);
    if (!path || !*path) return NULL;
    {
        region_build_ctx* ctx = g_new0(region_build_ctx, 1);
        ctx->view = g_object_ref(view);
        spdf_password_source_init(&ctx->source, path, view->tab->credential);
        ctx->page = page;
        ctx->generation = view->region_generation;
        ctx->links = g_array_new(FALSE, FALSE, sizeof(spdf_rect));
        ctx->text = g_array_new(FALSE, FALSE, sizeof(spdf_rect));
        g_hash_table_add(view->region_building, GINT_TO_POINTER(page));
        g_thread_pool_push(region_pool_get(), ctx, NULL);
    }
    return NULL;
}

/* Every cached texture and region is stale: bump the generation so in-flight
 * builds drop their result, and clear the cache. */
static void view_invalidate_cursor_regions(SpdfDocView* view) {
    view->region_generation++;
    if (view->region_cache) g_hash_table_remove_all(view->region_cache);
    if (view->region_building) g_hash_table_remove_all(view->region_building);
}

static const char* view_cursor_name_at(SpdfDocView* view, int page, double page_x, double page_y) {
    region_entry* entry = view_ensure_cursor_regions(view, page);
    if (!entry) return NULL; /* still building: arrow until the build lands */
    switch (spdf_cursor_region_at_point((const spdf_rect*)entry->links->data, entry->links->len,
                                        (const spdf_rect*)entry->text->data, entry->text->len, page_x, page_y,
                                        SPDF_CURSOR_LINK_HIT_PADDING)) {
        case SPDF_CURSOR_REGION_LINK:
            return "pointer";
        case SPDF_CURSOR_REGION_TEXT:
            return "text";
        default:
            return NULL;
    }
}

/* --------------------------------------------------------------------------- */
/* Event controllers. */

/* The Ctrl+wheel zoom step, reusable by widgets that forward their own
 * Ctrl+scroll here (the minimap, matching the Mac's
 * minimapViewDidReceiveZoomScrollWheel -> zoomWithScrollWheelEvent path).
 * The anchor is a widget-space point of THIS view; without one the zoom
 * anchors at the center of the visible document area. */
void spdf_doc_view_zoom_scroll(SpdfDocView* view, double dy, gboolean has_anchor, double anchor_x, double anchor_y) {
    double factor;

    g_return_if_fail(SPDF_IS_DOC_VIEW(view));
    if (!view_doc(view)) return;
    factor = dy != 0.0 ? pow(ZOOM_WHEEL_STEP, -dy) : 0.0;
    if (factor <= 0.0) return;
    if (has_anchor)
        view_apply_zoom(view, view->zoom * factor, ANCHOR_AT_POINT, anchor_x, anchor_y);
    else
        view_apply_zoom(view, view->zoom * factor, ANCHOR_AT_CENTER, 0.0, 0.0);
}

static gboolean on_scroll(GtkEventControllerScroll* controller, double dx, double dy, gpointer user_data) {
    SpdfDocView* view = SPDF_DOC_VIEW(user_data);
    GdkModifierType state = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(controller));
    (void)dx;

    if (!view_doc(view)) return FALSE;
    if ((state & GDK_CONTROL_MASK) != 0) {
        spdf_doc_view_zoom_scroll(view, dy, view->pointer_valid, view->pointer_x, view->pointer_y);
        return TRUE; /* Ctrl+scroll never pans (page_scroll_event) */
    }
    return FALSE; /* plain scrolling belongs to the GtkScrolledWindow */
}

static void on_pinch_begin(GtkGesture* gesture, GdkEventSequence* sequence, gpointer user_data) {
    SpdfDocView* view = SPDF_DOC_VIEW(user_data);
    double cx = 0.0;
    double cy = 0.0;
    (void)sequence;

    if (!view_doc(view)) {
        gtk_gesture_set_state(gesture, GTK_EVENT_SEQUENCE_DENIED);
        return;
    }
    view->pinch_begin_zoom = view->zoom;
    if (!view->zoom_active) {
        view->zoom_active = TRUE;
        view_cancel_all_renders(view);
    }
    /* The anchor is captured once per gesture and reused for every tick, so
     * repeated scale changes cannot accumulate drift. */
    if (gtk_gesture_get_bounding_box_center(gesture, &cx, &cy)) {
        spdf_zoom_anchor_capture(&view->anchor, &view->layout, view->sizes, view->zoom, cx, cy, view_scroll_x(view),
                                 view_scroll_y(view));
    } else {
        spdf_zoom_anchor_capture(&view->anchor, &view->layout, view->sizes, view->zoom, view->viewport_w * 0.5,
                                 view->viewport_h * 0.5, view_scroll_x(view), view_scroll_y(view));
    }
}

static void on_pinch_scale_changed(GtkGestureZoom* gesture, double scale, gpointer user_data) {
    SpdfDocView* view = SPDF_DOC_VIEW(user_data);
    (void)gesture;
    if (!view_doc(view) || !view->zoom_active || scale <= 0.0) return;
    view_apply_zoom(view, view->pinch_begin_zoom * scale, ANCHOR_REUSE, 0.0, 0.0);
}

static void view_selection_changed(SpdfDocView* view) {
    g_signal_emit(view, signals[SIG_SELECTION_CHANGED], 0);
    gtk_widget_queue_draw(GTK_WIDGET(view));
}

static void on_click_pressed(GtkGestureClick* gesture, int press_count, double x, double y, gpointer user_data) {
    SpdfDocView* view = SPDF_DOC_VIEW(user_data);
    (void)gesture;
    int page = -1;
    double page_x = 0.0;
    double page_y = 0.0;

    gtk_widget_grab_focus(GTK_WIDGET(view));
    if (view_doc(view)) view_page_point_at(view, x, y, &page, &page_x, &page_y);
    if (spdf_docview_selection_press(&view->selection, view_doc(view), page, x, y, page_x, page_y,
                                     (unsigned)MAX(1, press_count)))
        view_selection_changed(view);
}

static void on_click_released(GtkGestureClick* gesture, int press_count, double x, double y, gpointer user_data) {
    SpdfDocView* view = SPDF_DOC_VIEW(user_data);
    int delay = 250;
    (void)gesture;
    (void)press_count;
    (void)x;
    (void)y;

    if (!view->selection.active) return;
    g_object_get(gtk_widget_get_settings(GTK_WIDGET(view)), "gtk-double-click-time", &delay, NULL);
    spdf_docview_selection_release(&view->selection, (guint)CLAMP(delay, 1, 2000), view_activate_delayed_link, view);
}

static void on_selection_cancel(GtkGesture* gesture, GdkEventSequence* sequence, gpointer user_data) {
    (void)gesture;
    (void)sequence;
    spdf_docview_selection_cancel(&SPDF_DOC_VIEW(user_data)->selection);
}

static void on_click_stopped(GtkGestureClick* gesture, gpointer user_data) {
    (void)gesture;
    spdf_docview_selection_click_stopped(&SPDF_DOC_VIEW(user_data)->selection);
}

static void on_drag_update(GtkGestureDrag* gesture, double offset_x, double offset_y, gpointer user_data) {
    SpdfDocView* view = SPDF_DOC_VIEW(user_data);
    (void)gesture;

    if (view->selection.active && view->selection.page >= 0) {
        double page_x;
        double page_y;
        double widget_x = view->selection.start_widget_x + offset_x;
        double widget_y = view->selection.start_widget_y + offset_y;
        view_page_point_for_page(view, view->selection.page, widget_x, widget_y, &page_x, &page_y);
        if (spdf_docview_selection_drag(&view->selection, view_doc(view), widget_x, widget_y, page_x, page_y,
                                        LINK_CLICK_DRAG_THRESHOLD))
            view_selection_changed(view);
        if (spdf_docview_selection_is_dragging(&view->selection))
            gtk_widget_set_cursor_from_name(GTK_WIDGET(view), "text");
    }
}

static void on_pan_begin(GtkGestureDrag* gesture, double x, double y, gpointer user_data) {
    SpdfDocView* view = SPDF_DOC_VIEW(user_data);
    (void)gesture;
    (void)x;
    (void)y;
    if (!view_doc(view)) return;
    view->panning = TRUE;
    view->pan_start_h = view_scroll_x(view);
    view->pan_start_v = view_scroll_y(view);
    gtk_widget_set_cursor_from_name(GTK_WIDGET(view), "grabbing");
}

static void on_pan_update(GtkGestureDrag* gesture, double offset_x, double offset_y, gpointer user_data) {
    SpdfDocView* view = SPDF_DOC_VIEW(user_data);
    (void)gesture;
    if (!view->panning) return;
    view_set_scroll_values(view, view->pan_start_h - offset_x, view->pan_start_v - offset_y);
    view_clamp_horizontal(view);
}

static void on_pan_end(GtkGestureDrag* gesture, double offset_x, double offset_y, gpointer user_data) {
    SpdfDocView* view = SPDF_DOC_VIEW(user_data);
    (void)gesture;
    (void)offset_x;
    (void)offset_y;
    view->panning = FALSE;
    gtk_widget_set_cursor_from_name(GTK_WIDGET(view), NULL);
}

/* Re-resolve the cursor for the last known pointer position (Mac
 * refreshCursorForMouseLocation): motion events call it directly, and the
 * async region build calls it when a page's regions land so the cursor
 * corrects itself without the mouse moving. */
static void view_refresh_cursor_at_pointer(SpdfDocView* view) {
    int page = -1;
    double page_x = 0.0;
    double page_y = 0.0;
    const char* cursor = NULL;

    if (!view->pointer_valid || view->panning) return;
    if (spdf_docview_selection_is_dragging(&view->selection)) return; /* I-beam until release */
    if (view_doc(view) && view_page_point_at(view, view->pointer_x, view->pointer_y, &page, &page_x, &page_y))
        cursor = view_cursor_name_at(view, page, page_x, page_y);
    gtk_widget_set_cursor_from_name(GTK_WIDGET(view), cursor);
}

static void on_motion(GtkEventControllerMotion* controller, double x, double y, gpointer user_data) {
    SpdfDocView* view = SPDF_DOC_VIEW(user_data);
    (void)controller;

    view->pointer_x = x;
    view->pointer_y = y;
    view->pointer_valid = TRUE;
    view_refresh_cursor_at_pointer(view);
}

static void on_leave(GtkEventControllerMotion* controller, gpointer user_data) {
    SpdfDocView* view = SPDF_DOC_VIEW(user_data);
    (void)controller;
    view->pointer_valid = FALSE;
    gtk_widget_set_cursor_from_name(GTK_WIDGET(view), NULL);
}

/* Port of go_to_adjacent_page_preserving_view: keep the in-page scroll
 * fractions across the flip. */
static gboolean view_goto_adjacent_preserving_view(SpdfDocView* view, int delta) {
    int target;
    const SpdfPageRect* rect;
    double x_fraction = 0.0;
    double y_fraction = 0.0;

    if (view->page_count <= 0 || delta == 0) return FALSE;
    target = CLAMP(view->current_page + delta, 0, view->page_count - 1);
    if (target == view->current_page) return TRUE;

    rect = &view->layout.rects[view->current_page];
    if (rect->w > 0.0 && rect->h > 0.0) {
        double max_h = MAX(1.0, rect->w - view->viewport_w);
        double max_v = MAX(1.0, rect->h - view->viewport_h);
        x_fraction = CLAMP((view_scroll_x(view) - rect->x) / max_h, 0.0, 1.0);
        y_fraction = CLAMP((view_scroll_y(view) - rect->y) / max_v, 0.0, 1.0);
    }
    rect = &view->layout.rects[target];
    view_set_scroll_values(view, rect->x + x_fraction * MAX(0.0, rect->w - view->viewport_w),
                           rect->y + y_fraction * MAX(0.0, rect->h - view->viewport_h));
    view_update_current_page(view);
    view_clamp_horizontal(view);
    return TRUE;
}

static void view_step_adjustment(SpdfDocView* view, GtkAdjustment* adj, double delta) {
    double lower;
    double upper;
    if (!adj) return;
    lower = gtk_adjustment_get_lower(adj);
    upper = gtk_adjustment_get_upper(adj) - gtk_adjustment_get_page_size(adj);
    gtk_adjustment_set_value(adj, MAX(lower, MIN(gtk_adjustment_get_value(adj) + delta, upper)));
}

static gboolean on_key_pressed(GtkEventControllerKey* controller, guint keyval, guint keycode, GdkModifierType state,
                               gpointer user_data) {
    SpdfDocView* view = SPDF_DOC_VIEW(user_data);
    gboolean shift = (state & GDK_SHIFT_MASK) != 0;
    double page_step;
    (void)controller;
    (void)keycode;

    if (!view_doc(view) || (state & GDK_CONTROL_MASK) != 0) return FALSE;
    page_step = MAX(ARROW_SCROLL_STEP,
                    (view->vadj ? gtk_adjustment_get_page_size(view->vadj) : view->viewport_h) - ARROW_SCROLL_STEP);

    switch (keyval) {
        case GDK_KEY_Left:
        case GDK_KEY_Up:
        case GDK_KEY_Right:
        case GDK_KEY_Down: {
            gboolean back = keyval == GDK_KEY_Left || keyval == GDK_KEY_Up;
            if (shift) return view_goto_adjacent_preserving_view(view, back ? -1 : 1);
            if (keyval == GDK_KEY_Left || keyval == GDK_KEY_Right) {
                view_step_adjustment(view, view->hadj, back ? -ARROW_SCROLL_STEP : ARROW_SCROLL_STEP);
                view_clamp_horizontal(view);
            } else {
                view_step_adjustment(view, view->vadj, back ? -ARROW_SCROLL_STEP : ARROW_SCROLL_STEP);
            }
            return TRUE;
        }
        case GDK_KEY_Page_Up:
        case GDK_KEY_KP_Page_Up:
            view_step_adjustment(view, view->vadj, -page_step);
            return TRUE;
        case GDK_KEY_Page_Down:
        case GDK_KEY_KP_Page_Down:
            view_step_adjustment(view, view->vadj, page_step);
            return TRUE;
        case GDK_KEY_space:
        case GDK_KEY_KP_Space:
            view_step_adjustment(view, view->vadj, shift ? -page_step : page_step);
            return TRUE;
        case GDK_KEY_Home:
        case GDK_KEY_KP_Home:
            if (view->vadj) gtk_adjustment_set_value(view->vadj, 0.0);
            return TRUE;
        case GDK_KEY_End:
        case GDK_KEY_KP_End:
            if (view->vadj)
                gtk_adjustment_set_value(
                    view->vadj, gtk_adjustment_get_upper(view->vadj) - gtk_adjustment_get_page_size(view->vadj));
            return TRUE;
        default:
            return FALSE;
    }
}

/* --------------------------------------------------------------------------- */
/* Widget vfuncs. */

static void spdf_doc_view_measure(GtkWidget* widget, GtkOrientation orientation, int for_size, int* minimum,
                                  int* natural, int* minimum_baseline, int* natural_baseline) {
    SpdfDocView* view = SPDF_DOC_VIEW(widget);
    double widest = 0.0;
    (void)for_size;

    *minimum = 1;
    if (orientation == GTK_ORIENTATION_HORIZONTAL) {
        for (int i = 0; i < view->page_count; ++i) widest = MAX(widest, view->sizes[i].width * view->zoom);
        *natural = MAX(1, (int)ceil(widest + 2.0 * view_margin_h(view)));
    } else {
        *natural = MAX(1, (int)ceil(view->layout.canvas_h));
    }
    *minimum_baseline = -1;
    *natural_baseline = -1;
}

static void spdf_doc_view_size_allocate(GtkWidget* widget, int width, int height, int baseline) {
    SpdfDocView* view = SPDF_DOC_VIEW(widget);
    (void)baseline;

    view->viewport_w = width;
    view->viewport_h = height;

    if (view->fit != SPDF_FIT_CUSTOM) {
        double fit_zoom = view_fit_zoom(view);
        if (fit_zoom > 0.0 && fit_zoom != view->zoom) {
            spdf_zoom_anchor_capture(&view->anchor, &view->layout, view->sizes, view->zoom, width * 0.5, height * 0.5,
                                     view_scroll_x(view), view_scroll_y(view));
            view->zoom = fit_zoom;
            view_relayout(view);
            view_configure_adjustments(view);
            {
                double sx;
                double sy;
                if (spdf_zoom_anchor_apply(&view->anchor, &view->layout, view->zoom, view->viewport_w, view->viewport_h,
                                           &sx, &sy))
                    view_set_scroll_values(view, sx, sy);
            }
            view->anchor.valid = FALSE;
            g_signal_emit(view, signals[SIG_ZOOM_CHANGED], 0, view->zoom);
        }
    }

    view_relayout(view); /* canvas width tracks the viewport */
    view_configure_adjustments(view);
    view_clamp_horizontal(view);
    view_update_current_page(view);
    view_schedule_renders(view, FALSE);
    view_arm_scroll_settle(view);
}

static void snapshot_page_border(GtkSnapshot* snapshot, const graphene_rect_t* bounds, const GdkRGBA* color) {
    GskRoundedRect outline;
    float widths[4] = {1.0f, 1.0f, 1.0f, 1.0f};
    GdkRGBA colors[4];
    colors[0] = colors[1] = colors[2] = colors[3] = *color;
    gsk_rounded_rect_init_from_rect(&outline, bounds, 0.0f);
    gtk_snapshot_append_border(snapshot, &outline, widths, colors);
}

static void spdf_doc_view_snapshot(GtkWidget* widget, GtkSnapshot* snapshot) {
    SpdfDocView* view = SPDF_DOC_VIEW(widget);
    gboolean dark = adw_style_manager_get_dark(adw_style_manager_get_default());
    GdkRGBA background = dark ? (GdkRGBA){0.11, 0.11, 0.12, 1.0} : (GdkRGBA){0.92, 0.92, 0.93, 1.0};
    GdkRGBA page_white = {1.0, 1.0, 1.0, 1.0};
    GdkRGBA border = dark ? (GdkRGBA){0.0, 0.0, 0.0, 0.55} : (GdkRGBA){0.0, 0.0, 0.0, 0.16};
    GdkRGBA selection = {0.40, 0.62, 0.86, 0.34}; /* decorate_page_surface's color */
    double sx = view_scroll_x(view);
    double sy = view_scroll_y(view);
    int width = gtk_widget_get_width(widget);
    int height = gtk_widget_get_height(widget);
    int first = 0;
    int last = -1;
    gboolean drew_texture = FALSE;

    gtk_snapshot_append_color(snapshot, &background, &GRAPHENE_RECT_INIT(0, 0, width, height));
    if (view->layout.count <= 0) return;

    gtk_snapshot_save(snapshot);
    gtk_snapshot_translate(snapshot, &GRAPHENE_POINT_INIT((float)-sx, (float)-sy));

    if (spdf_layout_visible_range(&view->layout, sy, sy + height, &first, &last)) {
        for (int p = first; p <= last; ++p) {
            const SpdfPageRect* rect = &view->layout.rects[p];
            page_slot* slot = &view->slots[p];
            graphene_rect_t bounds = GRAPHENE_RECT_INIT((float)rect->x, (float)rect->y, (float)rect->w, (float)rect->h);

            /* Light placeholder under everything: rendered pages are opaque
             * white anyway, pending ones read as an empty sheet. */
            gtk_snapshot_append_color(snapshot, &page_white, &bounds);

            if (slot->full) {
                /* Stale or byte-capped textures stretch over the exact slot
                 * rect — geometry never depends on the rendered scale. */
                gtk_snapshot_append_texture(snapshot, slot->full, &bounds);
                drew_texture = TRUE;
            }
            if (slot->crop && slot->crop_scale > 0.0) {
                double inv = view->zoom / slot->crop_scale;
                graphene_rect_t crop_bounds = GRAPHENE_RECT_INIT(
                    (float)(rect->x + slot->crop_rect.x * inv), (float)(rect->y + slot->crop_rect.y * inv),
                    (float)(slot->crop_rect.width * inv), (float)(slot->crop_rect.height * inv));
                gtk_snapshot_append_texture(snapshot, slot->crop, &crop_bounds);
                drew_texture = TRUE;
            }
            snapshot_page_border(snapshot, &bounds, &border);

            if (p == view->selection.page && view->selection.result.rect_count > 0) {
                for (size_t i = 0; i < view->selection.result.rect_count; ++i) {
                    const spdf_rect* r = &view->selection.result.rects[i];
                    graphene_rect_t sel = GRAPHENE_RECT_INIT(
                        (float)(rect->x + r->x0 * view->zoom), (float)(rect->y + r->y0 * view->zoom),
                        (float)((r->x1 - r->x0) * view->zoom), (float)((r->y1 - r->y0) * view->zoom));
                    gtk_snapshot_append_color(snapshot, &selection, &sel);
                }
            }

            /* --- search-module overlay (same pattern as the selection):
             * every match pale yellow (GTK3 decorate_page_surface's find
             * color), the current one hot yellow on top. --- */
            if (view->search_count > 0) {
                GdkRGBA match_all = {1.0, 0.84, 0.12, 0.34};
                GdkRGBA match_hot = {1.0, 0.62, 0.00, 0.55};
                for (int i = 0; i < view->search_count; ++i) {
                    const spdf_rect* r;
                    graphene_rect_t hl;
                    if (view->search_pages[i] != p) continue;
                    r = &view->search_rects[i];
                    hl = GRAPHENE_RECT_INIT(
                        (float)(rect->x + r->x0 * view->zoom), (float)(rect->y + r->y0 * view->zoom),
                        (float)((r->x1 - r->x0) * view->zoom), (float)((r->y1 - r->y0) * view->zoom));
                    gtk_snapshot_append_color(snapshot, i == view->search_current ? &match_hot : &match_all, &hl);
                }
            }

            /* Wave B: comment marker badges (amber square hugging the
             * annotation's top-right corner; geometry shared with the
             * click-to-edit hit test via spdf_comment_marker_badge).
             * Dark-mode audit (Wave D): badge, selection and search-match
             * colors are deliberately theme-invariant — they composite onto
             * the page surface, which renders white in both themes
             * (page_white above); only the widget chrome (background/border
             * at the top of this function) swaps palettes. */
            if (view->comment_markers) {
                GdkRGBA marker_fill = {0.98, 0.74, 0.18, 0.92};
                GdkRGBA marker_border = {0.55, 0.35, 0.0, 0.9};
                for (guint i = 0; i < view->comment_markers->len; ++i) {
                    const SpdfCommentMarker* m = &g_array_index(view->comment_markers, SpdfCommentMarker, i);
                    spdf_rect badge;
                    graphene_rect_t br;
                    if (m->page != p) continue;
                    badge = spdf_comment_marker_badge(&m->bounds);
                    br = GRAPHENE_RECT_INIT(
                        (float)(rect->x + badge.x0 * view->zoom), (float)(rect->y + badge.y0 * view->zoom),
                        (float)((badge.x1 - badge.x0) * view->zoom), (float)((badge.y1 - badge.y0) * view->zoom));
                    gtk_snapshot_append_color(snapshot, &marker_fill, &br);
                    snapshot_page_border(snapshot, &br, &marker_border);
                }
            }
        }
    }

    gtk_snapshot_restore(snapshot);

    if (drew_texture && !view->first_snapshot_marked) {
        view->first_snapshot_marked = TRUE;
        spdf_launch_mark("first-snapshot");
    }
}

/* --------------------------------------------------------------------------- */
/* GtkScrollable plumbing. */

static void view_set_adjustment(SpdfDocView* view, GtkAdjustment* adjustment, gboolean horizontal) {
    GtkAdjustment** slot = horizontal ? &view->hadj : &view->vadj;
    gulong* handler = horizontal ? &view->hadj_handler : &view->vadj_handler;

    if (*slot == adjustment) return;
    if (*slot && *handler) {
        g_signal_handler_disconnect(*slot, *handler);
        *handler = 0;
    }
    g_set_object(slot, adjustment);
    if (*slot) {
        *handler = g_signal_connect_swapped(
            *slot, "value-changed", horizontal ? G_CALLBACK(on_hadj_value_changed) : G_CALLBACK(on_vadj_value_changed),
            view);
        view_configure_adjustments(view);
    }
}

static void spdf_doc_view_set_property(GObject* object, guint prop_id, const GValue* value, GParamSpec* pspec) {
    SpdfDocView* view = SPDF_DOC_VIEW(object);
    switch (prop_id) {
        case PROP_HADJUSTMENT:
            view_set_adjustment(view, g_value_get_object(value), TRUE);
            break;
        case PROP_VADJUSTMENT:
            view_set_adjustment(view, g_value_get_object(value), FALSE);
            break;
        case PROP_HSCROLL_POLICY:
            view->hscroll_policy = g_value_get_enum(value);
            break;
        case PROP_VSCROLL_POLICY:
            view->vscroll_policy = g_value_get_enum(value);
            break;
        default:
            G_OBJECT_WARN_INVALID_PROPERTY_ID(object, prop_id, pspec);
    }
}

static void spdf_doc_view_get_property(GObject* object, guint prop_id, GValue* value, GParamSpec* pspec) {
    SpdfDocView* view = SPDF_DOC_VIEW(object);
    switch (prop_id) {
        case PROP_HADJUSTMENT:
            g_value_set_object(value, view->hadj);
            break;
        case PROP_VADJUSTMENT:
            g_value_set_object(value, view->vadj);
            break;
        case PROP_HSCROLL_POLICY:
            g_value_set_enum(value, view->hscroll_policy);
            break;
        case PROP_VSCROLL_POLICY:
            g_value_set_enum(value, view->vscroll_policy);
            break;
        default:
            G_OBJECT_WARN_INVALID_PROPERTY_ID(object, prop_id, pspec);
    }
}

/* --------------------------------------------------------------------------- */
/* Lifecycle. */

static void spdf_doc_view_dispose(GObject* object) {
    SpdfDocView* view = SPDF_DOC_VIEW(object);

    view_cancel_all_renders(view);
    if (view->pending_ctxs) {
        /* Orphan in-flight contexts; the render service still delivers each
         * done callback exactly once, which frees them. */
        for (guint i = 0; i < view->pending_ctxs->len; ++i)
            ((render_ctx*)g_ptr_array_index(view->pending_ctxs, i))->view = NULL;
        g_ptr_array_free(view->pending_ctxs, TRUE);
        view->pending_ctxs = NULL;
    }
    if (view->scroll_settle_id) {
        g_source_remove(view->scroll_settle_id);
        view->scroll_settle_id = 0;
    }
    if (view->zoom_settle_id) {
        g_source_remove(view->zoom_settle_id);
        view->zoom_settle_id = 0;
    }
    if (view->slots) {
        for (int p = 0; p < view->page_count; ++p) {
            g_clear_object(&view->slots[p].full);
            g_clear_object(&view->slots[p].crop);
        }
        g_free(view->slots);
        view->slots = NULL;
    }
    view_set_adjustment(view, NULL, TRUE);
    view_set_adjustment(view, NULL, FALSE);
    /* In-flight region builds hold a strong view ref; NULL region_cache is
     * the "disposing" guard their done step checks before caching. */
    view->region_generation++;
    g_clear_pointer(&view->region_cache, g_hash_table_destroy);
    g_clear_pointer(&view->region_building, g_hash_table_destroy);
    if (view->comment_markers) {
        g_array_free(view->comment_markers, TRUE);
        view->comment_markers = NULL;
    }
    spdf_docview_selection_reset(&view->selection);
    /* search-module overlay copies */
    g_clear_pointer(&view->search_pages, g_free);
    g_clear_pointer(&view->search_rects, g_free);
    view->search_count = 0;
    view->search_current = -1;
    g_free(view->sizes);
    view->sizes = NULL;
    view->page_count = 0;
    spdf_layout_clear(&view->layout);
    view->tab = NULL;

    G_OBJECT_CLASS(spdf_doc_view_parent_class)->dispose(object);
}

static void spdf_doc_view_class_init(SpdfDocViewClass* klass) {
    GObjectClass* object_class = G_OBJECT_CLASS(klass);
    GtkWidgetClass* widget_class = GTK_WIDGET_CLASS(klass);

    object_class->dispose = spdf_doc_view_dispose;
    object_class->set_property = spdf_doc_view_set_property;
    object_class->get_property = spdf_doc_view_get_property;

    widget_class->measure = spdf_doc_view_measure;
    widget_class->size_allocate = spdf_doc_view_size_allocate;
    widget_class->snapshot = spdf_doc_view_snapshot;

    g_object_class_override_property(object_class, PROP_HADJUSTMENT, "hadjustment");
    g_object_class_override_property(object_class, PROP_VADJUSTMENT, "vadjustment");
    g_object_class_override_property(object_class, PROP_HSCROLL_POLICY, "hscroll-policy");
    g_object_class_override_property(object_class, PROP_VSCROLL_POLICY, "vscroll-policy");

    signals[SIG_PAGE_CHANGED] = g_signal_new("page-changed", G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_FIRST, 0, NULL,
                                             NULL, NULL, G_TYPE_NONE, 1, G_TYPE_INT);
    signals[SIG_ZOOM_CHANGED] = g_signal_new("zoom-changed", G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_FIRST, 0, NULL,
                                             NULL, NULL, G_TYPE_NONE, 1, G_TYPE_DOUBLE);
    signals[SIG_SELECTION_CHANGED] = g_signal_new("selection-changed", G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_FIRST, 0,
                                                  NULL, NULL, NULL, G_TYPE_NONE, 0);

    gtk_widget_class_set_css_name(widget_class, "spdf-docview");
}

static void spdf_doc_view_init(SpdfDocView* view) {
    GtkEventController* scroll;
    GtkEventController* motion;
    GtkEventController* key;
    GtkGesture* pinch;
    GtkGesture* click;
    GtkGesture* drag;
    GtkGesture* pan;

    view->zoom = 1.0;
    view->fit = SPDF_FIT_CUSTOM;
    view->current_page = 0;
    spdf_docview_selection_init(&view->selection);
    view->search_current = -1;
    view->pending_ctxs = g_ptr_array_new();
    view->region_cache = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, region_entry_free);
    view->region_building = g_hash_table_new(g_direct_hash, g_direct_equal);
    view->comment_markers = g_array_new(FALSE, FALSE, sizeof(SpdfCommentMarker));

    gtk_widget_set_focusable(GTK_WIDGET(view), TRUE);
    gtk_widget_set_hexpand(GTK_WIDGET(view), TRUE);
    gtk_widget_set_vexpand(GTK_WIDGET(view), TRUE);
    /* The snapshot draws page textures in canvas coordinates translated by
     * the scroll offset; when the canvas is larger than the allocation the
     * pages extend past the widget bounds. GTK4 does not clip by default
     * (GTK_OVERFLOW_VISIBLE), so without this the zoomed-in document paints
     * over the sidebar and minimap (GtkViewport sets the same flag). */
    gtk_widget_set_overflow(GTK_WIDGET(view), GTK_OVERFLOW_HIDDEN);

    scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
    g_signal_connect(scroll, "scroll", G_CALLBACK(on_scroll), view);
    gtk_widget_add_controller(GTK_WIDGET(view), scroll);

    pinch = gtk_gesture_zoom_new();
    g_signal_connect(pinch, "begin", G_CALLBACK(on_pinch_begin), view);
    g_signal_connect(pinch, "scale-changed", G_CALLBACK(on_pinch_scale_changed), view);
    gtk_widget_add_controller(GTK_WIDGET(view), GTK_EVENT_CONTROLLER(pinch));

    click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), GDK_BUTTON_PRIMARY);
    g_signal_connect(click, "pressed", G_CALLBACK(on_click_pressed), view);
    g_signal_connect(click, "released", G_CALLBACK(on_click_released), view);
    g_signal_connect(click, "stopped", G_CALLBACK(on_click_stopped), view);
    g_signal_connect(click, "cancel", G_CALLBACK(on_selection_cancel), view);
    gtk_widget_add_controller(GTK_WIDGET(view), GTK_EVENT_CONTROLLER(click));

    drag = gtk_gesture_drag_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(drag), GDK_BUTTON_PRIMARY);
    g_signal_connect(drag, "drag-update", G_CALLBACK(on_drag_update), view);
    g_signal_connect(drag, "cancel", G_CALLBACK(on_selection_cancel), view);
    gtk_widget_add_controller(GTK_WIDGET(view), GTK_EVENT_CONTROLLER(drag));
    gtk_gesture_group(click, drag);

    pan = gtk_gesture_drag_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(pan), GDK_BUTTON_MIDDLE);
    g_signal_connect(pan, "drag-begin", G_CALLBACK(on_pan_begin), view);
    g_signal_connect(pan, "drag-update", G_CALLBACK(on_pan_update), view);
    g_signal_connect(pan, "drag-end", G_CALLBACK(on_pan_end), view);
    gtk_widget_add_controller(GTK_WIDGET(view), GTK_EVENT_CONTROLLER(pan));

    motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(on_motion), view);
    g_signal_connect(motion, "leave", G_CALLBACK(on_leave), view);
    gtk_widget_add_controller(GTK_WIDGET(view), motion);

    key = gtk_event_controller_key_new();
    g_signal_connect(key, "key-pressed", G_CALLBACK(on_key_pressed), view);
    gtk_widget_add_controller(GTK_WIDGET(view), key);
}

static void view_load_document(SpdfDocView* view) {
    spdf_document* doc = view_doc(view);
    char err[256];

    view->page_count = doc ? spdf_page_count(doc) : 0;
    if (view->page_count <= 0) {
        view->page_count = 0;
        return;
    }
    view->sizes = g_new0(SpdfPageSizePt, view->page_count);
    view->slots = g_new0(page_slot, view->page_count);
    for (int i = 0; i < view->page_count; ++i) {
        float w = 0.0f;
        float h = 0.0f;
        if (spdf_page_size(doc, i, &w, &h, err, sizeof(err)) && w > 0.0f && h > 0.0f) {
            view->sizes[i].width = w;
            view->sizes[i].height = h;
        } else {
            view->sizes[i].width = 612.0; /* US Letter fallback, like the GTK3 slot build */
            view->sizes[i].height = 792.0;
        }
    }
    view_relayout(view);
}

/* --------------------------------------------------------------------------- */
/* Contract API. */

SpdfDocView* spdf_doc_view_new(SpdfTab* tab) {
    SpdfDocView* view = g_object_new(SPDF_TYPE_DOC_VIEW, NULL);
    view->tab = tab;
    view_load_document(view);
    return view;
}

void spdf_doc_view_goto_page(SpdfDocView* view, int page) {
    const SpdfPageRect* rect;

    g_return_if_fail(SPDF_IS_DOC_VIEW(view));
    if (view->layout.count <= 0) {
        view->current_page = MAX(0, page);
        return;
    }
    page = CLAMP(page, 0, view->layout.count - 1);
    rect = &view->layout.rects[page];
    view_set_scroll_values(view, view_scroll_x(view), MAX(0.0, rect->y - view_margin_v(view)));
    if (page != view->current_page) {
        view->current_page = page;
        g_signal_emit(view, signals[SIG_PAGE_CHANGED], 0, page);
    }
    view_clamp_horizontal(view);
    view_schedule_renders(view, FALSE);
    view_arm_scroll_settle(view);
}

int spdf_doc_view_current_page(SpdfDocView* view) {
    g_return_val_if_fail(SPDF_IS_DOC_VIEW(view), 0);
    return view->current_page;
}

void spdf_doc_view_set_zoom(SpdfDocView* view, double zoom, gboolean anchored, double anchor_x, double anchor_y) {
    g_return_if_fail(SPDF_IS_DOC_VIEW(view));
    view->fit = SPDF_FIT_CUSTOM;
    view_apply_zoom(view, zoom, anchored ? ANCHOR_AT_POINT : ANCHOR_AT_CENTER, anchor_x, anchor_y);
}

double spdf_doc_view_get_zoom(SpdfDocView* view) {
    g_return_val_if_fail(SPDF_IS_DOC_VIEW(view), 1.0);
    return view->zoom;
}

void spdf_doc_view_set_fit(SpdfDocView* view, SpdfFitMode mode) {
    double fit_zoom;

    g_return_if_fail(SPDF_IS_DOC_VIEW(view));
    if (view->fit == mode) return;
    view->fit = mode;
    if (mode == SPDF_FIT_CUSTOM) {
        view_relayout(view); /* margins changed */
        view_configure_adjustments(view);
        gtk_widget_queue_draw(GTK_WIDGET(view));
        return;
    }
    fit_zoom = view_fit_zoom(view);
    if (fit_zoom > 0.0) {
        view_apply_zoom(view, fit_zoom, ANCHOR_AT_CENTER, 0.0, 0.0);
        view->fit = mode; /* view_apply_zoom is fit-agnostic; keep the mode */
    } else {
        view_relayout(view);
        view_configure_adjustments(view);
        gtk_widget_queue_draw(GTK_WIDGET(view));
    }
}

SpdfFitMode spdf_doc_view_get_fit(SpdfDocView* view) {
    g_return_val_if_fail(SPDF_IS_DOC_VIEW(view), SPDF_FIT_CUSTOM);
    return view->fit;
}

void spdf_doc_view_get_scroll(SpdfDocView* view, double* x, double* y) {
    g_return_if_fail(SPDF_IS_DOC_VIEW(view));
    if (x) *x = view_scroll_x(view);
    if (y) *y = view_scroll_y(view);
}

void spdf_doc_view_set_scroll(SpdfDocView* view, double x, double y) {
    g_return_if_fail(SPDF_IS_DOC_VIEW(view));
    view_set_scroll_values(view, x, y);
    view_clamp_horizontal(view);
    view_update_current_page(view);
    view_schedule_renders(view, FALSE);
    view_arm_scroll_settle(view);
}

/* Returns the raw selected text; whitespace collapsing is the caller's
 * decision (Copy handler, per the collapse_whitespace_on_copy setting). */
char* spdf_doc_view_copy_selection(SpdfDocView* view) {
    g_return_val_if_fail(SPDF_IS_DOC_VIEW(view), NULL);
    return spdf_docview_selection_copy_text(&view->selection);
}

/* Contract addition (returned to the integrator): kick the first page render
 * before the window maps so the first snapshot has pixels. The scale factor
 * is still trustworthy unmapped; the fit zoom is not (no allocation yet), so
 * this renders at the session-restored zoom and the settle pass after the
 * first allocate re-renders if fit disagrees. */
void spdf_doc_view_prime_first_page(SpdfDocView* view) {
    g_return_if_fail(SPDF_IS_DOC_VIEW(view));
    if (!view_doc(view) || !view_render(view) || view->page_count <= 0) return;
    spdf_launch_mark("prime-first-page");
    view_request_full(view, CLAMP(view->current_page, 0, view->page_count - 1), view_render_scale(view), 0);
}

/* --------------------------------------------------------------------------- */
/* Search integration (declared in spdf_search.h; the search module owns the
 * match data, this section only stores overlay copies, scrolls and exposes
 * layout facts). Kept self-contained: other wave-B agents edit other regions
 * of this file. */

void spdf_doc_view_set_search_matches(SpdfDocView* view, const int* pages, const spdf_rect* rects, int count,
                                      int current) {
    g_return_if_fail(SPDF_IS_DOC_VIEW(view));
    g_clear_pointer(&view->search_pages, g_free);
    g_clear_pointer(&view->search_rects, g_free);
    view->search_count = 0;
    view->search_current = -1;
    if (pages && rects && count > 0) {
        view->search_pages = g_new(int, count);
        view->search_rects = g_new(spdf_rect, count);
        memcpy(view->search_pages, pages, (gsize)count * sizeof(int));
        memcpy(view->search_rects, rects, (gsize)count * sizeof(spdf_rect));
        view->search_count = count;
        view->search_current = current >= 0 && current < count ? current : -1;
    }
    gtk_widget_queue_draw(GTK_WIDGET(view));
}

void spdf_doc_view_set_search_current(SpdfDocView* view, int current) {
    g_return_if_fail(SPDF_IS_DOC_VIEW(view));
    view->search_current = current >= 0 && current < view->search_count ? current : -1;
    gtk_widget_queue_draw(GTK_WIDGET(view));
}

/* Center the match rect in the viewport (Mac scrollToPageRect:pageIndex:);
 * the adjustments clamp to the scrollable range. */
void spdf_doc_view_scroll_to_match(SpdfDocView* view, int page, const spdf_rect* rect) {
    const SpdfPageRect* slot;
    double cx;
    double cy;

    g_return_if_fail(SPDF_IS_DOC_VIEW(view));
    if (view->layout.count <= 0) return;
    page = CLAMP(page, 0, view->layout.count - 1);
    if (!rect) {
        spdf_doc_view_goto_page(view, page);
        return;
    }
    slot = &view->layout.rects[page];
    cx = slot->x + (rect->x0 + rect->x1) * 0.5 * view->zoom;
    cy = slot->y + (rect->y0 + rect->y1) * 0.5 * view->zoom;
    view_set_scroll_values(view, cx - view->viewport_w * 0.5, cy - view->viewport_h * 0.5);
    view_update_current_page(view);
    view_clamp_horizontal(view);
    view_schedule_renders(view, FALSE);
    view_arm_scroll_settle(view);
}

/* ---------------------------------------------------------------------------
 * Wave B additions (contract in spdf_internal.h; spdf_annot.c is the
 * consumer). Kept in one section so parallel edits elsewhere in this file
 * never collide with it. */

/* The document behind the view was rewritten (rotate/comment save/OCR) or the
 * tab was retargeted at a different file (Save As): every cached texture is
 * stale and the page geometry may have changed. In-flight render contexts are
 * orphaned rather than merely canceled — after a render-service swap their
 * tokens could collide with fresh tokens from the new service, and the old
 * service still delivers each done callback exactly once, which frees them. */
void spdf_doc_view_document_changed(SpdfDocView* view) {
    int restore_page;
    gboolean selection_changed;

    g_return_if_fail(SPDF_IS_DOC_VIEW(view));
    restore_page = view->current_page;

    view_cancel_all_renders(view);
    if (view->pending_ctxs) {
        for (guint i = 0; i < view->pending_ctxs->len; ++i)
            ((render_ctx*)g_ptr_array_index(view->pending_ctxs, i))->view = NULL;
        g_ptr_array_set_size(view->pending_ctxs, 0);
    }

    if (view->slots) {
        for (int p = 0; p < view->page_count; ++p) {
            g_clear_object(&view->slots[p].full);
            g_clear_object(&view->slots[p].crop);
        }
        g_free(view->slots);
        view->slots = NULL;
    }
    g_free(view->sizes);
    view->sizes = NULL;
    view->page_count = 0;
    spdf_layout_clear(&view->layout);

    selection_changed = view_has_selection(view);
    spdf_docview_selection_reset(&view->selection);
    if (selection_changed) g_signal_emit(view, signals[SIG_SELECTION_CHANGED], 0);
    view_invalidate_cursor_regions(view); /* rotation/save/OCR moved every rect */
    if (view->comment_markers) g_array_set_size(view->comment_markers, 0);
    view->anchor.valid = FALSE;

    view_load_document(view);
    view->current_page = view->page_count > 0 ? CLAMP(restore_page, 0, view->page_count - 1) : 0;
    view_configure_adjustments(view);
    view_clamp_horizontal(view);
    gtk_widget_queue_resize(GTK_WIDGET(view));
    gtk_widget_queue_draw(GTK_WIDGET(view));
    g_signal_emit(view, signals[SIG_PAGE_CHANGED], 0, view->current_page);
    view_schedule_renders(view, FALSE);
    view_arm_scroll_settle(view);
}

gboolean spdf_doc_view_page_slot(SpdfDocView* view, int page, double* x, double* y, double* w, double* h) {
    const SpdfPageRect* slot;

    g_return_val_if_fail(SPDF_IS_DOC_VIEW(view), FALSE);
    if (page < 0 || page >= view->layout.count) return FALSE;
    slot = &view->layout.rects[page];
    if (x) *x = slot->x;
    if (y) *y = slot->y;
    if (w) *w = slot->w;
    if (h) *h = slot->h;
    return TRUE;
}

gboolean spdf_doc_view_visible_pages(SpdfDocView* view, int* first, int* last) {
    double y0;

    g_return_val_if_fail(SPDF_IS_DOC_VIEW(view), FALSE);
    if (view->layout.count <= 0 || view->viewport_h <= 0.0) return FALSE;
    y0 = view_scroll_y(view);
    return spdf_layout_visible_range(&view->layout, y0, y0 + view->viewport_h, first, last);
}

gboolean spdf_doc_view_widget_point_to_page(SpdfDocView* view, double widget_x, double widget_y, int* page,
                                            double* page_x, double* page_y) {
    g_return_val_if_fail(SPDF_IS_DOC_VIEW(view), FALSE);
    return view_page_point_at(view, widget_x, widget_y, page, page_x, page_y);
}

int spdf_doc_view_get_selection_rects(SpdfDocView* view, int* page, spdf_rect* rects, int rect_max) {
    g_return_val_if_fail(SPDF_IS_DOC_VIEW(view), 0);
    return spdf_docview_selection_copy_rects(&view->selection, page, rects, rect_max);
}

void spdf_doc_view_set_comment_markers(SpdfDocView* view, const SpdfCommentMarker* markers, int count) {
    g_return_if_fail(SPDF_IS_DOC_VIEW(view));
    if (!view->comment_markers) return; /* disposing */
    g_array_set_size(view->comment_markers, 0);
    if (markers && count > 0) g_array_append_vals(view->comment_markers, markers, (guint)count);
    gtk_widget_queue_draw(GTK_WIDGET(view));
}
