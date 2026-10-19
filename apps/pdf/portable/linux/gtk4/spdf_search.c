// spdf_search.c — search subsystem for the GTK4 shell. See spdf_search.h for
// the API and spdf_search_internal.h for the pure logic (tested in
// tests/search_test.c).
//
// Ported logic provenance:
//   - incremental search + live counter: GTK3 start_find_for_current_query /
//     find_search_changed (120ms debounce) / update_find_controls
//     (ShenzhenPDFGtk.c @5061/@5193/@1988), lifted onto a worker thread that
//     opens its own core document (the Mac startFindForCurrentQuery model,
//     ShenzhenPDFMac.mm @10540) with generation-checked idle delivery;
//   - regex + multiline incl. graceful invalid-pattern failure: GTK3
//     find_regex_toggled / find_regex_multiline_toggled (@5214/@5238), the
//     hits<0 error path of start_find_for_current_query;
//   - next/prev with wraparound: GTK3 find_step (@5160) + Mac
//     findFromCurrentForward (search first when the query has no results);
//   - type-anywhere: GTK3 key_press printable branch (@9662);
//   - selection-to-search: Mac focusFind (commit 32ae3a2ef, @12123);
//   - paste-to-search: Mac paste: (commit 32ae3a2ef, @12134);
//   - Escape clears search / bar focus rules: GTK3 find_search_key_press
//     (@5330) + Mac documentEscapeKeyDown (commits 81d6a9214, 8b7d43857,
//     34f70a9d4; @10115);
//   - nearest-match jump (searchJumpsToNearestResult): Mac
//     nearestFindMatchIndexToCurrentViewport (@10438) over the pure
//     spdf_search_nearest_match port of SPDFMacFindNearest.mm;
//   - scrollbar heat-map: Mac findScrollbarMarkers proportional layout
//     (@6188) drawn with the GTK3 find_markers_draw colors (@5351);
//   - match snippets for the sidebar: Mac findContextForQuery (@10398);
//   - chapter grouping: Mac sidebar chapter attribution by outline start page;
//   - per-tab query persistence: GTK3 tab search_text/search_regex/
//     search_regex_multiline/find_match_index (@1026) with the lazy re-run on
//     first search-bar open (GTK3 deferred find on tab activation @4270).

#include <string.h>

#include "spdf_app.h"
#include "spdf_password.h"
#include "spdf_search.h"

#define SEARCH_DEBOUNCE_MS 120   /* GTK3 find_search_changed debounce */
#define SEARCH_PAGE_RECT_MAX 256 /* GTK3 per-page rect cap */
#define SEARCH_BATCH_MATCHES 128 /* worker->main delivery granularity */
#define SEARCH_MARKER_LANE_WIDTH 8

// ---------------------------------------------------------------------------
// SpdfSearchController

struct _SpdfSearchController {
    GObject parent_instance;

    SpdfTab* tab; /* borrowed; NULL after detach. The tab's search_text /
                     search_regex / search_regex_multiline / find_match_index
                     fields are the persisted source of truth. */

    SpdfSearchMatchList list;
    int current; /* index into list, -1 = none */
    char* error; /* invalid regex / search failure message, NULL = ok */
    gboolean searching;

    guint debounce_id;
    volatile int generation; /* bumped to cancel; worker polls atomically */

    /* behavior for the next/running search */
    gboolean pending_reveal;
    int pending_index; /* preferred match index (session restore), -1 none */
    int pending_page;  /* preferred page (regex toggle keeps the page), -1 */
};

enum {
    SIG_MATCHES_CHANGED,
    SIG_CURRENT_CHANGED,
    N_SIGNALS
};
static guint signals[N_SIGNALS];

G_DEFINE_FINAL_TYPE(SpdfSearchController, spdf_search_controller, G_TYPE_OBJECT)

static void controller_restart(SpdfSearchController* c, gboolean reveal, int preferred_index, int preferred_page);

static const char* controller_query(SpdfSearchController* c) {
    return c->tab && c->tab->search_text ? c->tab->search_text : "";
}

static SpdfDocView* controller_view(SpdfSearchController* c) {
    return c->tab ? c->tab->view : NULL;
}

static SpdfApp* app_for_window(SpdfWindow* win) {
    GtkApplication* app = win ? gtk_window_get_application(GTK_WINDOW(win)) : NULL;
    return app && SPDF_IS_APP(app) ? SPDF_APP(app) : NULL;
}

static SpdfSettings* settings_for_tab(SpdfTab* tab) {
    SpdfApp* app = tab ? app_for_window(tab->win) : NULL;
    return app ? spdf_state_settings(spdf_app_get_state(app)) : NULL;
}

static void save_session_for_tab(SpdfTab* tab) {
    SpdfApp* app = tab ? app_for_window(tab->win) : NULL;
    if (app) spdf_app_save_session(app); /* coalesced write; cheap per call */
}

/* Push the full match set (and current index) into the doc view overlay. */
static void controller_push_highlights(SpdfSearchController* c) {
    SpdfDocView* view = controller_view(c);
    guint count = spdf_search_match_list_count(&c->list);
    int* pages;
    spdf_rect* rects;

    if (!view) return;
    if (count == 0) {
        spdf_doc_view_set_search_matches(view, NULL, NULL, 0, -1);
        return;
    }
    pages = g_new(int, count);
    rects = g_new(spdf_rect, count);
    for (guint i = 0; i < count; ++i) {
        const SpdfSearchMatch* m = spdf_search_match_list_get(&c->list, i);
        pages[i] = m->page;
        rects[i] = m->rect;
    }
    spdf_doc_view_set_search_matches(view, pages, rects, (int)count, c->current);
    g_free(pages);
    g_free(rects);
}

static void controller_set_current_full(SpdfSearchController* c, int index, gboolean scroll) {
    int count = (int)spdf_search_match_list_count(&c->list);
    SpdfDocView* view = controller_view(c);

    if (count == 0)
        index = -1;
    else
        index = CLAMP(index, -1, count - 1);
    c->current = index;
    if (c->tab) c->tab->find_match_index = index;
    if (view) {
        spdf_doc_view_set_search_current(view, index);
        if (scroll && index >= 0) {
            const SpdfSearchMatch* m = spdf_search_match_list_get(&c->list, (guint)index);
            spdf_doc_view_scroll_to_match(view, m->page, &m->rect);
        }
    }
    g_signal_emit(c, signals[SIG_CURRENT_CHANGED], 0, index);
    save_session_for_tab(c->tab);
}

/* Mac nearestFindMatchIndexToCurrentViewport: document-space centers +
 * visible page range fed to the pure helper. -1 when not computable. */
static int controller_nearest_index(SpdfSearchController* c) {
    SpdfDocView* view = controller_view(c);
    int count = (int)spdf_search_match_list_count(&c->list);
    int first = -1;
    int last = -1;
    int* pages;
    double* centers;
    double zoom;
    double scroll_y = 0.0;
    double viewport_center;
    int nearest;

    if (!view || count == 0) return -1;
    if (!spdf_doc_view_visible_pages(view, &first, &last)) return -1;
    zoom = spdf_doc_view_get_zoom(view);
    spdf_doc_view_get_scroll(view, NULL, &scroll_y);
    viewport_center = scroll_y + gtk_widget_get_height(GTK_WIDGET(view)) * 0.5;

    pages = g_new(int, count);
    centers = g_new(double, count);
    for (int i = 0; i < count; ++i) {
        const SpdfSearchMatch* m = spdf_search_match_list_get(&c->list, (guint)i);
        double slot_y = 0.0;
        pages[i] = m->page;
        spdf_doc_view_page_slot(view, m->page, NULL, &slot_y, NULL, NULL);
        /* Same page-to-document mapping as scroll-to-match. */
        centers[i] = slot_y + (m->rect.y0 + m->rect.y1) * 0.5 * zoom;
    }
    nearest = spdf_search_nearest_match(pages, centers, count, first, last, viewport_center);
    g_free(pages);
    g_free(centers);
    return nearest;
}

/* Completion index choice, port of the GTK3 preferred_index/preferred_page
 * logic + the Mac nearest-match refinement. */
static int controller_choose_current(SpdfSearchController* c) {
    int count = (int)spdf_search_match_list_count(&c->list);
    SpdfSettings* settings;

    if (count == 0) return -1;
    if (c->pending_index >= 0 && c->pending_index < count) return c->pending_index;
    if (c->pending_page >= 0) {
        for (int i = 0; i < count; ++i) {
            if (spdf_search_match_list_get(&c->list, (guint)i)->page == c->pending_page) return i;
        }
    }
    settings = settings_for_tab(c->tab);
    if (settings && settings->search_jumps_to_nearest_result) {
        int nearest = controller_nearest_index(c);
        if (nearest >= 0) return nearest;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Worker thread. Owns its own core document (Mac model) so the main-thread
// doc is never touched off-thread; results arrive as generation-checked
// idle batches.

typedef struct {
    SpdfSearchController* ctrl; /* strong ref; handed to the final delivery */
    int generation;
    SpdfPasswordSource source;
    char* query;
    gboolean regex;
    gboolean multiline;
} SearchJob;

typedef struct {
    SpdfSearchController* ctrl; /* strong ref */
    int generation;
    SpdfSearchMatchList batch;
    char* error;
    gboolean final;
} SearchDelivery;

static void delivery_free(gpointer data) {
    SearchDelivery* d = data;
    spdf_search_match_list_deinit(&d->batch); /* frees undelivered snippets */
    g_free(d->error);
    g_object_unref(d->ctrl);
    g_free(d);
}

static gboolean deliver_idle(gpointer data) {
    SearchDelivery* d = data;
    SpdfSearchController* c = d->ctrl;

    if (g_atomic_int_get(&c->generation) != d->generation || !c->tab) return G_SOURCE_REMOVE;

    if (spdf_search_match_list_count(&d->batch) > 0) spdf_search_match_list_steal_into(&c->list, &d->batch);

    if (!d->final) {
        /* Partial batch: highlights + live counter, selection waits. */
        controller_push_highlights(c);
        g_signal_emit(c, signals[SIG_MATCHES_CHANGED], 0);
        return G_SOURCE_REMOVE;
    }

    c->searching = FALSE;
    g_free(c->error);
    c->error = g_steal_pointer(&d->error);
    if (c->current < 0) {
        /* Only pick a current if the user hasn't already stepped to one
         * mid-search (indices are stable: batches append). Recomputing here
         * would yank the view away from their choice. */
        c->current = controller_choose_current(c);
        if (c->pending_reveal && c->current >= 0 && controller_view(c)) {
            const SpdfSearchMatch* m = spdf_search_match_list_get(&c->list, (guint)c->current);
            spdf_doc_view_scroll_to_match(controller_view(c), m->page, &m->rect);
        }
    }
    if (c->tab) c->tab->find_match_index = c->current;
    controller_push_highlights(c);
    g_signal_emit(c, signals[SIG_MATCHES_CHANGED], 0);
    g_signal_emit(c, signals[SIG_CURRENT_CHANGED], 0, c->current);
    save_session_for_tab(c->tab);
    return G_SOURCE_REMOVE;
}

static void post_delivery(SpdfSearchController* ctrl_ref /* transferred */, int generation,
                          SpdfSearchMatchList* batch /* contents moved */, char* error, gboolean final) {
    SearchDelivery* d = g_new0(SearchDelivery, 1);
    d->ctrl = ctrl_ref;
    d->generation = generation;
    spdf_search_match_list_init(&d->batch);
    if (batch) spdf_search_match_list_steal_into(&d->batch, batch);
    d->error = error;
    d->final = final;
    g_idle_add_full(G_PRIORITY_DEFAULT, deliver_idle, d, delivery_free);
}

static gpointer search_worker(gpointer data) {
    SearchJob* job = data;
    char err[1024] = "";
    char* error = NULL;
    spdf_document* doc;
    int* chapter_pages = NULL;
    int chapter_count = 0;
    SpdfSearchMatchList batch;
    int total = 0;

    spdf_search_match_list_init(&batch);
    doc = spdf_password_source_open(&job->source, err, sizeof(err));
    if (!doc) {
        error = g_strdup(err[0] ? err : "Could not open the document for search.");
    } else {
        spdf_outline outline;
        int page_count = spdf_page_count(doc);

        memset(&outline, 0, sizeof(outline));
        if (spdf_load_outline(doc, &outline, err, sizeof(err)) && outline.count > 0) {
            chapter_count = outline.count;
            chapter_pages = g_new(int, chapter_count);
            for (int i = 0; i < chapter_count; ++i) chapter_pages[i] = outline.items[i].page_index;
        }
        spdf_free_outline(&outline);

        for (int page = 0; page < page_count && total < SPDF_SEARCH_MAX_MATCHES; ++page) {
            spdf_rect rects[SEARCH_PAGE_RECT_MAX];
            int hits;
            spdf_text_lines lines;
            const char** texts = NULL;
            spdf_rect* bounds = NULL;
            gboolean has_lines;
            int chapter;

            if (g_atomic_int_get(&job->ctrl->generation) != job->generation) break; /* canceled */

            hits = spdf_search_page_rects_options(doc, page, job->query, job->regex ? 1 : 0, job->multiline ? 1 : 0,
                                                  rects, SEARCH_PAGE_RECT_MAX, err, sizeof(err));
            if (hits < 0) {
                /* Graceful invalid-pattern failure: first error wins, matches
                 * so far are dropped by the controller (GTK3 semantics). */
                error = g_strdup(err[0] ? err : (job->regex ? "Invalid regular expression." : "Search failed."));
                break;
            }
            if (hits == 0) continue;

            memset(&lines, 0, sizeof(lines));
            has_lines = spdf_extract_page_text_lines(doc, page, &lines, err, sizeof(err)) && lines.count > 0;
            if (has_lines) {
                texts = g_new(const char*, lines.count);
                bounds = g_new(spdf_rect, lines.count);
                for (int i = 0; i < lines.count; ++i) {
                    texts[i] = lines.items[i].text;
                    bounds[i] = lines.items[i].bounds;
                }
            }
            chapter = spdf_search_chapter_for_page(chapter_pages, chapter_count, page);

            for (int i = 0; i < hits && total < SPDF_SEARCH_MAX_MATCHES; ++i) {
                char* snippet = has_lines ? spdf_search_snippet(texts, bounds, lines.count, rects[i]) : g_strdup("");
                spdf_search_match_list_append(&batch, page, rects[i], snippet, chapter);
                total++;
            }
            g_free(texts);
            g_free(bounds);
            if (has_lines) spdf_free_text_lines(&lines);

            if (spdf_search_match_list_count(&batch) >= SEARCH_BATCH_MATCHES)
                post_delivery(g_object_ref(job->ctrl), job->generation, &batch, NULL, FALSE);
        }
        spdf_close(doc);
    }

    if (error) spdf_search_match_list_clear(&batch);                /* GTK3: a failed search shows no matches */
    post_delivery(job->ctrl, job->generation, &batch, error, TRUE); /* job's ref moves */
    spdf_search_match_list_deinit(&batch);
    g_free(chapter_pages);
    spdf_password_source_clear(&job->source);
    g_free(job->query);
    g_free(job);
    return NULL;
}

// ---------------------------------------------------------------------------
// Controller search lifecycle (main thread).

static void controller_cancel_debounce(SpdfSearchController* c) {
    if (c->debounce_id) {
        g_source_remove(c->debounce_id);
        c->debounce_id = 0;
    }
}

/* Cancel + drop everything shown; emits when there was anything to drop. */
static void controller_reset_results(SpdfSearchController* c) {
    gboolean had = spdf_search_match_list_count(&c->list) > 0 || c->current >= 0 || c->error != NULL;

    g_atomic_int_inc(&c->generation);
    c->searching = FALSE;
    g_clear_pointer(&c->error, g_free);
    spdf_search_match_list_clear(&c->list);
    if (c->tab) c->tab->find_match_index = -1;
    if (had || c->current >= 0) {
        c->current = -1;
        controller_push_highlights(c);
        g_signal_emit(c, signals[SIG_MATCHES_CHANGED], 0);
        g_signal_emit(c, signals[SIG_CURRENT_CHANGED], 0, -1);
    }
    c->current = -1;
}

static void controller_restart(SpdfSearchController* c, gboolean reveal, int preferred_index, int preferred_page) {
    SearchJob* job;
    const char* query;

    controller_cancel_debounce(c);
    controller_reset_results(c);
    if (!c->tab) return;

    c->pending_reveal = reveal;
    c->pending_index = preferred_index;
    c->pending_page = preferred_page;

    query = controller_query(c);
    if (!c->tab->doc || !*query) {
        save_session_for_tab(c->tab);
        return;
    }

    c->searching = TRUE;
    g_signal_emit(c, signals[SIG_MATCHES_CHANGED], 0); /* counter shows the run */
    job = g_new0(SearchJob, 1);
    job->ctrl = g_object_ref(c);
    job->generation = g_atomic_int_get(&c->generation);
    spdf_password_source_init(&job->source, c->tab->path, c->tab->credential);
    job->query = g_strdup(query);
    job->regex = c->tab->search_regex;
    job->multiline = c->tab->search_regex_multiline;
    g_thread_unref(g_thread_new("spdf-search", search_worker, job));
}

static gboolean debounce_fired(gpointer data) {
    SpdfSearchController* c = data;
    c->debounce_id = 0;
    controller_restart(c, c->pending_reveal, c->pending_index, c->pending_page);
    return G_SOURCE_REMOVE;
}

// ---------------------------------------------------------------------------
// Controller public API.

SpdfSearchController* spdf_search_controller_new(SpdfTab* tab) {
    SpdfSearchController* c = g_object_new(SPDF_TYPE_SEARCH_CONTROLLER, NULL);
    c->tab = tab;
    return c;
}

void spdf_search_controller_detach(SpdfSearchController* c) {
    g_return_if_fail(SPDF_IS_SEARCH_CONTROLLER(c));
    controller_cancel_debounce(c);
    g_atomic_int_inc(&c->generation); /* in-flight idles become no-ops */
    c->searching = FALSE;
    c->tab = NULL;
}

void spdf_search_controller_set_query(SpdfSearchController* c, const char* query, gboolean reveal) {
    char* limited;

    g_return_if_fail(SPDF_IS_SEARCH_CONTROLLER(c));
    if (!c->tab) return;
    limited = spdf_search_dup_query(query);
    if (g_strcmp0(limited, controller_query(c)) == 0 &&
        (c->searching || c->debounce_id || !*limited || spdf_search_match_list_count(&c->list) > 0 || c->error)) {
        g_free(limited); /* nothing new to do */
        return;
    }
    g_free(c->tab->search_text);
    c->tab->search_text = limited;

    /* GTK3 find_search_changed: 120ms debounce, then reveal the first match. */
    c->pending_reveal = reveal;
    c->pending_index = -1;
    c->pending_page = -1;
    controller_cancel_debounce(c);
    c->debounce_id = g_timeout_add(SEARCH_DEBOUNCE_MS, debounce_fired, c);
}

const char* spdf_search_controller_get_query(SpdfSearchController* c) {
    g_return_val_if_fail(SPDF_IS_SEARCH_CONTROLLER(c), "");
    return controller_query(c);
}

void spdf_search_controller_set_regex(SpdfSearchController* c, gboolean regex) {
    g_return_if_fail(SPDF_IS_SEARCH_CONTROLLER(c));
    if (!c->tab || c->tab->search_regex == !!regex) return;
    c->tab->search_regex = !!regex;
    /* GTK3 find_regex_toggled: immediate re-run preferring the current page. */
    controller_restart(c, TRUE, -1, c->tab->view ? spdf_doc_view_current_page(c->tab->view) : -1);
}

gboolean spdf_search_controller_get_regex(SpdfSearchController* c) {
    g_return_val_if_fail(SPDF_IS_SEARCH_CONTROLLER(c), FALSE);
    return c->tab ? c->tab->search_regex : FALSE;
}

void spdf_search_controller_set_multiline(SpdfSearchController* c, gboolean multiline) {
    g_return_if_fail(SPDF_IS_SEARCH_CONTROLLER(c));
    if (!c->tab || c->tab->search_regex_multiline == !!multiline) return;
    c->tab->search_regex_multiline = !!multiline;
    controller_restart(c, TRUE, -1, c->tab->view ? spdf_doc_view_current_page(c->tab->view) : -1);
}

gboolean spdf_search_controller_get_multiline(SpdfSearchController* c) {
    g_return_val_if_fail(SPDF_IS_SEARCH_CONTROLLER(c), FALSE);
    return c->tab ? c->tab->search_regex_multiline : FALSE;
}

guint spdf_search_controller_match_count(SpdfSearchController* c) {
    g_return_val_if_fail(SPDF_IS_SEARCH_CONTROLLER(c), 0);
    return spdf_search_match_list_count(&c->list);
}

gboolean spdf_search_controller_match(SpdfSearchController* c, guint index, SpdfSearchMatch* out) {
    const SpdfSearchMatch* m;

    g_return_val_if_fail(SPDF_IS_SEARCH_CONTROLLER(c), FALSE);
    m = spdf_search_match_list_get(&c->list, index);
    if (!m) return FALSE;
    if (out) *out = *m; /* snippet stays owned by the controller */
    return TRUE;
}

int spdf_search_controller_current(SpdfSearchController* c) {
    g_return_val_if_fail(SPDF_IS_SEARCH_CONTROLLER(c), -1);
    return c->current;
}

void spdf_search_controller_set_current(SpdfSearchController* c, int index) {
    g_return_if_fail(SPDF_IS_SEARCH_CONTROLLER(c));
    controller_set_current_full(c, index, TRUE);
}

static void controller_step(SpdfSearchController* c, gboolean forward) {
    int count = (int)spdf_search_match_list_count(&c->list);
    int next;

    if (!c->tab) return;
    if (count <= 0) {
        /* Mac findFromCurrentForward: no results yet for a live query means
         * the search runs first. */
        if (*controller_query(c) && !c->searching) controller_restart(c, TRUE, -1, -1);
        return;
    }
    next = c->current;
    if (next < 0) {
        /* No current yet — Enter lands here whenever the final batch hasn't
         * arrived (large docs) or before any step. Honor the nearest-match
         * rule against the live viewport (Mac findFromCurrentForward), not
         * the document's first match. */
        SpdfSettings* settings = settings_for_tab(c->tab);
        int nearest = settings && settings->search_jumps_to_nearest_result ? controller_nearest_index(c) : -1;
        next = nearest >= 0 ? nearest : (forward ? 0 : count - 1);
    } else {
        next = (next + (forward ? 1 : -1) + count) % count; /* GTK3 find_step wraparound */
    }
    controller_set_current_full(c, next, TRUE);
}

void spdf_search_controller_next(SpdfSearchController* c) {
    g_return_if_fail(SPDF_IS_SEARCH_CONTROLLER(c));
    controller_step(c, TRUE);
}

void spdf_search_controller_prev(SpdfSearchController* c) {
    g_return_if_fail(SPDF_IS_SEARCH_CONTROLLER(c));
    controller_step(c, FALSE);
}

void spdf_search_controller_counter(SpdfSearchController* c, char* buf, gsize len) {
    g_return_if_fail(SPDF_IS_SEARCH_CONTROLLER(c));
    spdf_search_counter_text(buf, len, *controller_query(c) != '\0', c->current,
                             (int)spdf_search_match_list_count(&c->list));
}

gboolean spdf_search_controller_is_searching(SpdfSearchController* c) {
    g_return_val_if_fail(SPDF_IS_SEARCH_CONTROLLER(c), FALSE);
    return c->searching;
}

const char* spdf_search_controller_error(SpdfSearchController* c) {
    g_return_val_if_fail(SPDF_IS_SEARCH_CONTROLLER(c), NULL);
    return c->error;
}

void spdf_search_controller_refresh(SpdfSearchController* c) {
    g_return_if_fail(SPDF_IS_SEARCH_CONTROLLER(c));
    if (!c->tab || !*controller_query(c)) return;
    /* Lazy session re-run: keep the stored match index, prefer the current
     * page, don't move the viewport (GTK3 tab-activation deferred find). */
    controller_restart(c, FALSE, c->tab->find_match_index,
                       c->tab->view ? spdf_doc_view_current_page(c->tab->view) : -1);
}

void spdf_search_controller_clear(SpdfSearchController* c) {
    gboolean had;

    g_return_if_fail(SPDF_IS_SEARCH_CONTROLLER(c));
    controller_cancel_debounce(c);
    had =
        *controller_query(c) != '\0' || spdf_search_match_list_count(&c->list) > 0 || c->searching || c->error != NULL;
    if (c->tab) {
        g_free(c->tab->search_text);
        c->tab->search_text = g_strdup("");
    }
    controller_reset_results(c);
    if (had) save_session_for_tab(c->tab);
}

static void spdf_search_controller_dispose(GObject* object) {
    SpdfSearchController* c = SPDF_SEARCH_CONTROLLER(object);

    controller_cancel_debounce(c);
    g_atomic_int_inc(&c->generation);
    c->tab = NULL;
    g_clear_pointer(&c->error, g_free);
    spdf_search_match_list_deinit(&c->list);
    G_OBJECT_CLASS(spdf_search_controller_parent_class)->dispose(object);
}

static void spdf_search_controller_class_init(SpdfSearchControllerClass* klass) {
    GObjectClass* object_class = G_OBJECT_CLASS(klass);
    object_class->dispose = spdf_search_controller_dispose;

    signals[SIG_MATCHES_CHANGED] = g_signal_new("matches-changed", G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_FIRST, 0,
                                                NULL, NULL, NULL, G_TYPE_NONE, 0);
    signals[SIG_CURRENT_CHANGED] = g_signal_new("current-changed", G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_FIRST, 0,
                                                NULL, NULL, NULL, G_TYPE_NONE, 1, G_TYPE_INT);
}

static void spdf_search_controller_init(SpdfSearchController* c) {
    spdf_search_match_list_init(&c->list);
    c->current = -1;
    c->pending_index = -1;
    c->pending_page = -1;
}

// ---------------------------------------------------------------------------
// Scrollbar heat-map lane (per tab). Mac findScrollbarMarkers proportional
// layout, GTK3 find_markers_draw colors, honoring showFindMarkers.

static void markers_update_visibility(GtkWidget* area) {
    SpdfTab* tab = g_object_get_data(G_OBJECT(area), "spdf-tab");
    SpdfSettings* settings = tab ? settings_for_tab(tab) : NULL;
    gboolean show = tab && tab->search && spdf_search_controller_match_count(tab->search) > 0 &&
                    (!settings || settings->show_find_markers) && !(tab->win && spdf_window_get_presentation(tab->win));

    gtk_widget_set_visible(area, show);
    gtk_widget_queue_draw(area);
}

static void markers_on_matches(SpdfSearchController* c, gpointer area) {
    (void)c;
    markers_update_visibility(GTK_WIDGET(area));
}

static void markers_on_current(SpdfSearchController* c, int index, gpointer area) {
    (void)c;
    (void)index;
    markers_update_visibility(GTK_WIDGET(area));
}

/* Wave D dark-mode audit: theme flips repaint with the other backdrop. */
static void markers_style_dark_changed(GObject* manager, GParamSpec* pspec, gpointer area) {
    (void)manager;
    (void)pspec;
    gtk_widget_queue_draw(GTK_WIDGET(area));
}

static void markers_draw_tick(cairo_t* cr, double lane_w, double lane_h, double fraction, gboolean active) {
    double y = spdf_search_marker_y(fraction, lane_h, SPDF_SEARCH_MARKER_TICK_H);
    /* GTK3 draw_find_marker colors: hot orange for the current match. */
    if (active)
        cairo_set_source_rgba(cr, 1.0, 0.45, 0.02, 0.95);
    else
        cairo_set_source_rgba(cr, 1.0, 0.86, 0.08, 0.90);
    cairo_rectangle(cr, 1.0, y, MAX(1.0, lane_w - 2.0), SPDF_SEARCH_MARKER_TICK_H);
    cairo_fill(cr);
}

static double markers_match_fraction(SpdfDocView* view, double zoom, double doc_h, const SpdfSearchMatch* m) {
    double slot_y = 0.0;
    spdf_doc_view_page_slot(view, m->page, NULL, &slot_y, NULL, NULL);
    return spdf_search_marker_fraction(slot_y + (m->rect.y0 + m->rect.y1) * 0.5 * zoom, doc_h);
}

static void markers_draw(GtkDrawingArea* area, cairo_t* cr, int width, int height, gpointer user_data) {
    SpdfTab* tab = user_data;
    SpdfSearchController* ctrl = tab ? tab->search : NULL;
    SpdfDocView* view = tab ? tab->view : NULL;
    GtkAdjustment* vadj;
    double doc_h;
    double zoom;
    guint count;
    int current;

    (void)area;
    if (!ctrl || !view) return;
    count = spdf_search_controller_match_count(ctrl);
    if (count == 0) return;
    vadj = gtk_scrollable_get_vadjustment(GTK_SCROLLABLE(view));
    doc_h = vadj ? gtk_adjustment_get_upper(vadj) : 0.0;
    if (doc_h <= 0.0) return;
    zoom = spdf_doc_view_get_zoom(view);
    current = spdf_search_controller_current(ctrl);

    /* GTK3 find_markers_draw backdrop. Dark-mode audit (Wave D): the lane
     * floats over the doc-view background (dark in dark mode), where the
     * light theme's black wash disappears — use a white wash there. The
     * yellow/orange ticks themselves carry enough contrast in both themes. */
    if (adw_style_manager_get_dark(adw_style_manager_get_default()))
        cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.10);
    else
        cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.08);
    cairo_rectangle(cr, 0.0, 0.0, width, height);
    cairo_fill(cr);

    for (guint i = 0; i < count; ++i) {
        SpdfSearchMatch m;
        if ((int)i == current) continue; /* current drawn last, on top */
        if (!spdf_search_controller_match(ctrl, i, &m)) continue;
        markers_draw_tick(cr, width, height, markers_match_fraction(view, zoom, doc_h, &m), FALSE);
    }
    if (current >= 0) {
        SpdfSearchMatch m;
        if (spdf_search_controller_match(ctrl, (guint)current, &m))
            markers_draw_tick(cr, width, height, markers_match_fraction(view, zoom, doc_h, &m), TRUE);
    }
}

GtkWidget* spdf_search_markers_new(SpdfTab* tab) {
    GtkWidget* area = gtk_drawing_area_new();

    g_return_val_if_fail(tab != NULL, area);
    gtk_widget_set_halign(area, GTK_ALIGN_END);
    gtk_widget_set_valign(area, GTK_ALIGN_FILL);
    gtk_widget_set_size_request(area, SEARCH_MARKER_LANE_WIDTH, -1);
    gtk_widget_set_can_target(area, FALSE); /* the scrollbar underneath keeps working */
    gtk_widget_set_visible(area, FALSE);
    g_object_set_data(G_OBJECT(area), "spdf-tab", tab);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), markers_draw, tab, NULL);
    if (tab->search) {
        g_signal_connect_object(tab->search, "matches-changed", G_CALLBACK(markers_on_matches), area, 0);
        g_signal_connect_object(tab->search, "current-changed", G_CALLBACK(markers_on_current), area, 0);
    }
    /* Wave D dark-mode audit: repaint with the other backdrop wash when the
     * app-wide dark state flips (markers_draw picks it per paint). */
    g_signal_connect_object(adw_style_manager_get_default(), "notify::dark", G_CALLBACK(markers_style_dark_changed),
                            area, 0);
    return area;
}

// ---------------------------------------------------------------------------
// Per-window search bar + key behaviors.

typedef struct {
    SpdfWindow* win; /* borrowed */
    GtkSearchBar* bar;
    GtkSearchEntry* entry;
    GtkLabel* count;
    GtkWidget* prev_btn;
    GtkWidget* next_btn;
    GtkToggleButton* regex;
    GtkToggleButton* multiline;
    SpdfSearchController* connected; /* weak pointer; signals via connect_object */
    gboolean suppress;
    gint64 reveal_grace_until_us; /* capture-phase key takeover deadline */
} SearchUi;

/* How long after a bar reveal the window's capture-phase controller commits
 * printable keys straight into the query. The entry's input method (ibus on
 * GNOME) consumes-and-drops keys while its async focus-in setup runs, so
 * during this window keys must not reach the entry at all ("connector"
 * landed as "cctor" even with the bubble-phase append fix, because dropped
 * keys never bubble). Trade-off: IM composition (e.g. pinyin) is bypassed
 * for these few hundred ms right after the reveal. */
#define SEARCH_REVEAL_GRACE_US ((gint64)500 * 1000)

static GQuark search_ui_quark(void) {
    static GQuark quark;
    if (!quark) quark = g_quark_from_static_string("spdf-search-ui");
    return quark;
}

static SearchUi* search_ui(SpdfWindow* win) {
    return win ? g_object_get_qdata(G_OBJECT(win), search_ui_quark()) : NULL;
}

static void search_ui_free(gpointer data) {
    SearchUi* ui = data;
    if (ui->connected) g_object_remove_weak_pointer(G_OBJECT(ui->connected), (gpointer*)&ui->connected);
    g_free(ui);
}

static SpdfSearchController* current_controller(SpdfWindow* win) {
    SpdfTab* tab = spdf_window_current_tab(win);
    return tab ? tab->search : NULL;
}

static void focus_canvas(SpdfWindow* win) {
    SpdfTab* tab = spdf_window_current_tab(win);
    if (tab && tab->view) gtk_widget_grab_focus(GTK_WIDGET(tab->view));
}

/* Mac SPDFTextByCollapsingWhitespace: runs of whitespace become one space,
 * leading/trailing whitespace is trimmed. Returns NULL when nothing is left. */
static char* collapse_whitespace(const char* text) {
    GString* out;
    gboolean pending_space = FALSE;

    if (!text) return NULL;
    out = g_string_new("");
    for (const char* p = text; *p; p = g_utf8_next_char(p)) {
        gunichar ch = g_utf8_get_char(p);
        if (g_unichar_isspace(ch)) {
            if (out->len > 0) pending_space = TRUE;
            continue;
        }
        if (pending_space) {
            g_string_append_c(out, ' ');
            pending_space = FALSE;
        }
        g_string_append_unichar(out, ch);
    }
    if (out->len == 0) {
        g_string_free(out, TRUE);
        return NULL;
    }
    return g_string_free(out, FALSE);
}

static void ui_refresh_counts(SearchUi* ui) {
    SpdfSearchController* ctrl = current_controller(ui->win);
    char counter[64] = "";
    gboolean has_query = FALSE;
    gboolean has_matches = FALSE;
    const char* error = NULL;

    if (ctrl) {
        spdf_search_controller_counter(ctrl, counter, sizeof(counter));
        has_query = *spdf_search_controller_get_query(ctrl) != '\0';
        has_matches = spdf_search_controller_match_count(ctrl) > 0;
        error = spdf_search_controller_error(ctrl);
    }
    gtk_label_set_text(ui->count, counter);
    gtk_widget_set_visible(GTK_WIDGET(ui->count), has_query);
    gtk_widget_set_sensitive(ui->prev_btn, has_matches);
    gtk_widget_set_sensitive(ui->next_btn, has_matches);
    /* Graceful invalid-regex feedback: error style + tooltip on the entry
     * (the GTK4 shell has no status bar). */
    if (error && *error) {
        gtk_widget_add_css_class(GTK_WIDGET(ui->entry), "error");
        gtk_widget_set_tooltip_text(GTK_WIDGET(ui->entry), error);
    } else {
        gtk_widget_remove_css_class(GTK_WIDGET(ui->entry), "error");
        gtk_widget_set_tooltip_text(GTK_WIDGET(ui->entry), NULL);
    }
}

static void on_ctrl_matches(SpdfSearchController* c, gpointer user_data) {
    SearchUi* ui = search_ui(SPDF_WINDOW(user_data));
    if (ui && current_controller(ui->win) == c) ui_refresh_counts(ui);
}

static void on_ctrl_current(SpdfSearchController* c, int index, gpointer user_data) {
    SearchUi* ui = search_ui(SPDF_WINDOW(user_data));
    (void)index;
    if (ui && current_controller(ui->win) == c) ui_refresh_counts(ui);
}

void spdf_search_bar_sync(SpdfWindow* win) {
    SearchUi* ui = search_ui(win);
    SpdfSearchController* ctrl;

    if (!ui) return;
    ctrl = current_controller(win);

    if (ui->connected != ctrl) {
        if (ui->connected) {
            g_signal_handlers_disconnect_by_data(ui->connected, win);
            g_object_remove_weak_pointer(G_OBJECT(ui->connected), (gpointer*)&ui->connected);
            ui->connected = NULL;
        }
        if (ctrl) {
            g_signal_connect_object(ctrl, "matches-changed", G_CALLBACK(on_ctrl_matches), win, 0);
            g_signal_connect_object(ctrl, "current-changed", G_CALLBACK(on_ctrl_current), win, 0);
            ui->connected = ctrl;
            g_object_add_weak_pointer(G_OBJECT(ctrl), (gpointer*)&ui->connected);
        }
    }

    ui->suppress = TRUE;
    gtk_editable_set_text(GTK_EDITABLE(ui->entry), ctrl ? spdf_search_controller_get_query(ctrl) : "");
    gtk_toggle_button_set_active(ui->regex, ctrl ? spdf_search_controller_get_regex(ctrl) : FALSE);
    gtk_toggle_button_set_active(ui->multiline, ctrl ? spdf_search_controller_get_multiline(ctrl) : TRUE);
    ui->suppress = FALSE;
    ui_refresh_counts(ui);

    /* Persisted query with no results yet (session restore / GTK3 tab
     * activation): re-run lazily while the bar is open, keeping the viewport. */
    if (ctrl && gtk_search_bar_get_search_mode(ui->bar) && *spdf_search_controller_get_query(ctrl) &&
        spdf_search_controller_match_count(ctrl) == 0 && !spdf_search_controller_is_searching(ctrl) &&
        !spdf_search_controller_error(ctrl))
        spdf_search_controller_refresh(ctrl);
}

static void on_selected_page_changed(GObject* object, GParamSpec* pspec, gpointer user_data) {
    (void)object;
    (void)pspec;
    spdf_search_bar_sync(SPDF_WINDOW(user_data));
}

static void on_search_changed(GtkSearchEntry* entry, gpointer user_data) {
    SearchUi* ui = search_ui(SPDF_WINDOW(user_data));
    SpdfSearchController* ctrl;

    if (!ui || ui->suppress) return;
    ctrl = current_controller(ui->win);
    if (!ctrl) return;
    spdf_search_controller_set_query(ctrl, gtk_editable_get_text(GTK_EDITABLE(entry)), TRUE);
    ui_refresh_counts(ui);
}

static void on_entry_activate(GtkSearchEntry* entry, gpointer user_data) {
    SpdfSearchController* ctrl = current_controller(SPDF_WINDOW(user_data));
    (void)entry;
    /* GTK3 find_activate: Enter steps forward (or starts the search). */
    if (ctrl) spdf_search_controller_next(ctrl);
}

static void on_stop_search(GtkSearchEntry* entry, gpointer user_data) {
    (void)entry;
    /* Escape in the bar: clear query + highlights, hide, refocus canvas
     * (GTK3 find_search_key_press Escape + Mac cancelOperation). */
    spdf_search_dismiss(SPDF_WINDOW(user_data));
}

static gboolean on_entry_key(GtkEventControllerKey* controller, guint keyval, guint keycode, GdkModifierType state,
                             gpointer user_data) {
    (void)controller;
    (void)keycode;
    /* Shift+Enter steps backwards (GTK3 find_search_key_press). */
    if ((keyval == GDK_KEY_Return || keyval == GDK_KEY_KP_Enter || keyval == GDK_KEY_ISO_Enter) &&
        (state & GDK_SHIFT_MASK) != 0) {
        SpdfSearchController* ctrl = current_controller(SPDF_WINDOW(user_data));
        if (ctrl) spdf_search_controller_prev(ctrl);
        return GDK_EVENT_STOP;
    }
    return GDK_EVENT_PROPAGATE;
}

static void on_regex_toggled(GtkToggleButton* button, gpointer user_data) {
    SearchUi* ui = search_ui(SPDF_WINDOW(user_data));
    SpdfSearchController* ctrl;

    if (!ui || ui->suppress) return;
    ctrl = current_controller(ui->win);
    if (ctrl) spdf_search_controller_set_regex(ctrl, gtk_toggle_button_get_active(button));
}

static void on_multiline_toggled(GtkToggleButton* button, gpointer user_data) {
    SearchUi* ui = search_ui(SPDF_WINDOW(user_data));
    SpdfSearchController* ctrl;

    if (!ui || ui->suppress) return;
    ctrl = current_controller(ui->win);
    if (ctrl) spdf_search_controller_set_multiline(ctrl, gtk_toggle_button_get_active(button));
}

static void on_search_mode_changed(GObject* object, GParamSpec* pspec, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SearchUi* ui = search_ui(win);
    SpdfSearchController* ctrl;

    (void)object;
    (void)pspec;
    if (!ui) return;
    ctrl = current_controller(win);
    if (gtk_search_bar_get_search_mode(ui->bar)) {
        /* First open with a persisted per-tab query: sync prefills the entry
         * and toggles from the tab and re-runs the query lazily. */
        spdf_search_bar_sync(win);
    } else {
        /* Closing the bar dismisses the search (Escape semantics: query +
         * highlights cleared, canvas refocused). */
        if (ctrl) spdf_search_controller_clear(ctrl);
        ui->suppress = TRUE;
        gtk_editable_set_text(GTK_EDITABLE(ui->entry), "");
        ui->suppress = FALSE;
        ui_refresh_counts(ui);
        focus_canvas(win);
    }
}

/* Reveal the bar with `text`, focus the entry and run the search. select_all:
 * TRUE keeps the query selected so typing replaces it (Mac startSearchForText);
 * FALSE puts the caret at the end (type-anywhere continues typing). */
static void start_search_text(SpdfWindow* win, const char* text, gboolean select_all) {
    SearchUi* ui = search_ui(win);
    SpdfSearchController* ctrl = current_controller(win);

    if (!ui || !ctrl) return;
    /* Arm the capture-phase takeover while the entry's focus/IM setup
     * settles (see SEARCH_REVEAL_GRACE_US). Only when the entry does not
     * already own focus — steady-state typing must go through the IM. */
    {
        GtkWidget* focus = gtk_root_get_focus(GTK_ROOT(win));
        if (!focus || !(focus == GTK_WIDGET(ui->entry) || gtk_widget_is_ancestor(focus, GTK_WIDGET(ui->entry))))
            ui->reveal_grace_until_us = g_get_monotonic_time() + SEARCH_REVEAL_GRACE_US;
    }
    gtk_search_bar_set_search_mode(ui->bar, TRUE); /* first: its handler syncs old state */
    ui->suppress = TRUE;
    gtk_editable_set_text(GTK_EDITABLE(ui->entry), text);
    ui->suppress = FALSE;
    gtk_widget_grab_focus(GTK_WIDGET(ui->entry));
    if (select_all)
        gtk_editable_select_region(GTK_EDITABLE(ui->entry), 0, -1);
    else
        gtk_editable_set_position(GTK_EDITABLE(ui->entry), -1);
    spdf_search_controller_set_query(ctrl, text, TRUE);
    ui_refresh_counts(ui);
}

static void clipboard_text_ready(GObject* source, GAsyncResult* result, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    char* text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(source), result, NULL);
    char* query = collapse_whitespace(text);

    if (query && *query && spdf_window_current_tab(win)) start_search_text(win, query, TRUE);
    g_free(query);
    g_free(text);
    g_object_unref(win);
}

/* Capture-phase companion to on_window_key: for SEARCH_REVEAL_GRACE_US after
 * a type-anywhere reveal, printable unmodified keys are committed straight
 * into the query BEFORE the toolkit can route them to the just-focused entry,
 * whose input method silently drops keys while its async focus-in completes
 * (GNOME/ibus; the bubble-phase append never sees a dropped key). */
static gboolean on_window_key_capture(GtkEventControllerKey* controller, guint keyval, guint keycode,
                                      GdkModifierType state, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SearchUi* ui = search_ui(win);
    gunichar ch;

    (void)controller;
    (void)keycode;
    if (!ui || !gtk_search_bar_get_search_mode(ui->bar)) return GDK_EVENT_PROPAGATE;
    if (g_get_monotonic_time() >= ui->reveal_grace_until_us) return GDK_EVENT_PROPAGATE;
    if ((state & (GDK_CONTROL_MASK | GDK_ALT_MASK | GDK_SUPER_MASK | GDK_META_MASK)) != 0) return GDK_EVENT_PROPAGATE;
    ch = gdk_keyval_to_unicode(keyval);
    if (ch < 0x20 || ch == 0x7f) return GDK_EVENT_PROPAGATE;
    {
        char typed[8] = {0};
        char* joined;
        g_unichar_to_utf8(ch, typed);
        joined = g_strconcat(gtk_editable_get_text(GTK_EDITABLE(ui->entry)), typed, NULL);
        start_search_text(win, joined, FALSE);
        g_free(joined);
    }
    return GDK_EVENT_STOP;
}

/* Window-level keys: type-anywhere (GTK3 key_press printable branch) and
 * Ctrl+V paste-to-search (Mac paste:). Bubble phase, so a focused editable
 * consumes its keys first; the explicit focus check covers the rest. */
static gboolean on_window_key(GtkEventControllerKey* controller, guint keyval, guint keycode, GdkModifierType state,
                              gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    GtkWidget* focus = gtk_root_get_focus(GTK_ROOT(win));
    gunichar ch;

    (void)controller;
    (void)keycode;
    if (!tab || !tab->doc || spdf_window_get_presentation(win)) return GDK_EVENT_PROPAGATE;
    if (focus && GTK_IS_EDITABLE(focus)) {
        /* Focused editables consume their keys in the target/bubble phase, so
         * a key reaching this bubble-phase window handler was NOT consumed.
         * For every editable but the search entry that means "not ours" —
         * propagate. For the search entry it means the entry dropped the key
         * (the reveal animation window: focus is granted before the entry
         * accepts input, which lost mid-word keystrokes — "connector" landed
         * as "cctor"). Fall through so the append branch below re-injects it;
         * no double-insert is possible because a consumed key never bubbles
         * here. */
        SearchUi* focus_ui = search_ui(win);
        gboolean in_search_entry = focus_ui && (focus == GTK_WIDGET(focus_ui->entry) ||
                                                gtk_widget_is_ancestor(focus, GTK_WIDGET(focus_ui->entry)));
        if (!in_search_entry) return GDK_EVENT_PROPAGATE;
    }

    if ((state & GDK_CONTROL_MASK) != 0 && (state & (GDK_SHIFT_MASK | GDK_ALT_MASK)) == 0 &&
        (keyval == GDK_KEY_v || keyval == GDK_KEY_V)) {
        gdk_clipboard_read_text_async(gtk_widget_get_clipboard(GTK_WIDGET(win)), NULL, clipboard_text_ready,
                                      g_object_ref(win));
        return GDK_EVENT_STOP;
    }

    if ((state & (GDK_CONTROL_MASK | GDK_ALT_MASK | GDK_SUPER_MASK | GDK_META_MASK)) != 0) return GDK_EVENT_PROPAGATE;
    ch = gdk_keyval_to_unicode(keyval);
    if (ch >= 0x20 && ch != 0x7f) {
        char typed[8] = {0};
        SearchUi* ui = search_ui(win);

        g_unichar_to_utf8(ch, typed);
        if (ui && gtk_search_bar_get_search_mode(ui->bar)) {
            /* Bar already revealed but the entry hasn't received focus yet
             * (reveal animation races the grab): APPEND to the live query
             * instead of restarting it, so fast typists lose no keystrokes
             * ("connector" was landing as "cnnector"). */
            char* joined = g_strconcat(gtk_editable_get_text(GTK_EDITABLE(ui->entry)), typed, NULL);
            start_search_text(win, joined, FALSE);
            g_free(joined);
        } else {
            start_search_text(win, typed, FALSE);
        }
        return GDK_EVENT_STOP;
    }
    return GDK_EVENT_PROPAGATE;
}

GtkWidget* spdf_search_bar_new(SpdfWindow* win, GtkToggleButton* search_toggle) {
    SearchUi* ui = g_new0(SearchUi, 1);
    GtkWidget* box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget* bar = gtk_search_bar_new();
    GtkEventController* entry_keys;
    GtkEventController* window_keys;

    g_return_val_if_fail(SPDF_IS_WINDOW(win), bar);
    ui->win = win;
    ui->bar = GTK_SEARCH_BAR(bar);

    ui->entry = GTK_SEARCH_ENTRY(gtk_search_entry_new());
    /* The controller owns the debounce (GTK3's 120ms); the entry stays raw. */
    g_object_set(ui->entry, "search-delay", 0u, "placeholder-text", "Search document", NULL);
    gtk_editable_set_width_chars(GTK_EDITABLE(ui->entry), 28);
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(ui->entry));

    ui->count = GTK_LABEL(gtk_label_new(""));
    gtk_widget_add_css_class(GTK_WIDGET(ui->count), "dim-label");
    gtk_widget_add_css_class(GTK_WIDGET(ui->count), "numeric");
    gtk_widget_set_visible(GTK_WIDGET(ui->count), FALSE);
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(ui->count));

    ui->prev_btn = gtk_button_new_from_icon_name("go-up-symbolic");
    gtk_widget_add_css_class(ui->prev_btn, "flat");
    gtk_widget_set_tooltip_text(ui->prev_btn, "Previous match (Ctrl+Shift+G)");
    gtk_actionable_set_action_name(GTK_ACTIONABLE(ui->prev_btn), "win.find-prev");
    gtk_widget_set_sensitive(ui->prev_btn, FALSE);
    gtk_box_append(GTK_BOX(box), ui->prev_btn);

    ui->next_btn = gtk_button_new_from_icon_name("go-down-symbolic");
    gtk_widget_add_css_class(ui->next_btn, "flat");
    gtk_widget_set_tooltip_text(ui->next_btn, "Next match (Ctrl+G)");
    gtk_actionable_set_action_name(GTK_ACTIONABLE(ui->next_btn), "win.find-next");
    gtk_widget_set_sensitive(ui->next_btn, FALSE);
    gtk_box_append(GTK_BOX(box), ui->next_btn);

    /* GTK3 toolbar toggles; there was no case toggle (core search is always
     * case-insensitive: FZ_SEARCH_IGNORE_CASE in spdf_search_options). */
    ui->regex = GTK_TOGGLE_BUTTON(gtk_toggle_button_new_with_label("Regex"));
    gtk_widget_set_tooltip_text(GTK_WIDGET(ui->regex), "Regular-expression search");
    g_signal_connect(ui->regex, "toggled", G_CALLBACK(on_regex_toggled), win);
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(ui->regex));

    ui->multiline = GTK_TOGGLE_BUTTON(gtk_toggle_button_new_with_label("Multiline"));
    gtk_widget_set_tooltip_text(GTK_WIDGET(ui->multiline), "Regex . matches across lines");
    g_signal_connect(ui->multiline, "toggled", G_CALLBACK(on_multiline_toggled), win);
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(ui->multiline));
    /* GTK3 update_controls: multiline is only meaningful in regex mode. */
    g_object_bind_property(ui->regex, "active", ui->multiline, "sensitive", G_BINDING_SYNC_CREATE);

    gtk_search_bar_set_child(GTK_SEARCH_BAR(bar), box);
    gtk_search_bar_connect_entry(GTK_SEARCH_BAR(bar), GTK_EDITABLE(ui->entry));

    /* The header search toggle and the bar stay in lockstep. */
    g_object_bind_property(search_toggle, "active", bar, "search-mode-enabled",
                           G_BINDING_BIDIRECTIONAL | G_BINDING_SYNC_CREATE);
    g_signal_connect(bar, "notify::search-mode-enabled", G_CALLBACK(on_search_mode_changed), win);

    g_signal_connect(ui->entry, "search-changed", G_CALLBACK(on_search_changed), win);
    g_signal_connect(ui->entry, "activate", G_CALLBACK(on_entry_activate), win);
    g_signal_connect(ui->entry, "stop-search", G_CALLBACK(on_stop_search), win);
    entry_keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(entry_keys, GTK_PHASE_CAPTURE);
    g_signal_connect(entry_keys, "key-pressed", G_CALLBACK(on_entry_key), win);
    gtk_widget_add_controller(GTK_WIDGET(ui->entry), entry_keys);

    window_keys = gtk_event_controller_key_new();
    g_signal_connect(window_keys, "key-pressed", G_CALLBACK(on_window_key), win);
    gtk_widget_add_controller(GTK_WIDGET(win), window_keys);

    /* Reveal-race takeover (see on_window_key_capture). */
    {
        GtkEventController* capture_keys = gtk_event_controller_key_new();
        gtk_event_controller_set_propagation_phase(capture_keys, GTK_PHASE_CAPTURE);
        g_signal_connect(capture_keys, "key-pressed", G_CALLBACK(on_window_key_capture), win);
        gtk_widget_add_controller(GTK_WIDGET(win), capture_keys);
    }

    g_signal_connect_object(spdf_window_get_tab_view(win), "notify::selected-page",
                            G_CALLBACK(on_selected_page_changed), win, 0);

    g_object_set_qdata_full(G_OBJECT(win), search_ui_quark(), ui, search_ui_free);
    spdf_search_bar_sync(win);
    return bar;
}

void spdf_search_focus(SpdfWindow* win) {
    SearchUi* ui = search_ui(win);
    SpdfTab* tab = spdf_window_current_tab(win);

    g_return_if_fail(SPDF_IS_WINDOW(win));
    if (!ui) return;

    /* Selection-to-search (Mac focusFind): Ctrl+F with a live selection
     * searches for it immediately; the query stays selected so typing
     * replaces it. */
    if (tab && tab->view) {
        char* selection = spdf_doc_view_copy_selection(tab->view);
        char* query = collapse_whitespace(selection);
        g_free(selection);
        if (query && *query && g_strcmp0(query, gtk_editable_get_text(GTK_EDITABLE(ui->entry))) != 0) {
            start_search_text(win, query, TRUE);
            g_free(query);
            return;
        }
        g_free(query);
    }

    gtk_search_bar_set_search_mode(ui->bar, TRUE); /* lazy per-tab prefill happens here */
    gtk_widget_grab_focus(GTK_WIDGET(ui->entry));
    gtk_editable_select_region(GTK_EDITABLE(ui->entry), 0, -1);
}

void spdf_search_find_next(SpdfWindow* win) {
    SpdfSearchController* ctrl = current_controller(win);
    if (ctrl) spdf_search_controller_next(ctrl);
}

void spdf_search_find_prev(SpdfWindow* win) {
    SpdfSearchController* ctrl = current_controller(win);
    if (ctrl) spdf_search_controller_prev(ctrl);
}

gboolean spdf_search_dismiss(SpdfWindow* win) {
    SearchUi* ui = search_ui(win);
    SpdfSearchController* ctrl = current_controller(win);
    gboolean bar_open;
    gboolean search_active;

    if (!ui) return FALSE;
    bar_open = gtk_search_bar_get_search_mode(ui->bar);
    search_active = ctrl && (*spdf_search_controller_get_query(ctrl) != '\0' ||
                             spdf_search_controller_match_count(ctrl) > 0 || spdf_search_controller_is_searching(ctrl));
    if (!bar_open && !search_active) return FALSE;

    if (bar_open) {
        gtk_search_bar_set_search_mode(ui->bar, FALSE); /* mode handler clears + refocuses */
    } else {
        spdf_search_controller_clear(ctrl);
        ui_refresh_counts(ui);
        focus_canvas(win);
    }
    return TRUE;
}
