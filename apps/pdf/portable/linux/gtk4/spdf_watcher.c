// spdf_watcher.c — per-tab GFileMonitor auto-reload + read-only shadow-copy
// tabs (Wave C). Mac counterparts and the semantics being matched are listed
// in spdf_watcher.h. The pure half (top of the file) compiles glib-only under
// SPDF_WATCHER_TESTING for tests/watcher_test.c; the GIO/GTK half below the
// guard is the live module.

#include "spdf_watcher.h"

#include <glib/gstdio.h>
#include <math.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "spdf_password_lifecycle.h"
#include "spdf_password_prompt.h"

/* ===========================================================================
 * Live module (GIO monitors + tab plumbing). Everything below runs on the
 * main thread: GFileMonitor delivers on the default main context and every
 * timeout is a main-loop source. */

#include "spdf_annot.h"
#include "spdf_app.h"

/* Per-tab watch state, owned here, riding on SpdfTab::watch. */
typedef struct _SpdfTabWatch SpdfTabWatch;
struct _SpdfTabWatch {
    gint refs;
    SpdfTab* tab;          /* borrowed; the tab outlives its watch */
    GFileMonitor* monitor; /* NULL when the monitor could not start */
    gulong changed_id;
    guint debounce_id; /* pending coalesced check */
    SpdfWatcherDebounce debounce;
    guint retry_id; /* missing-file grace loop */
    int retry_count;
    guint64 baseline_size;  /* authoritative "unchanged" comparison input: */
    double baseline_mtime;  /* shadow tab: source stat the copy reflects;  */
    gboolean have_baseline; /* writable tab: last known on-disk stat.      */
    gboolean stale;         /* missing marker currently shown */
    gboolean reload_pending;
    gboolean detached;
    SpdfPasswordPrompt* prompt;
    char* candidate_path;
    gboolean candidate_read_only;
    guint64 candidate_size;
    double candidate_mtime;
};

static SpdfTabWatch* watch_ref(SpdfTabWatch* w) {
    g_atomic_int_inc(&w->refs);
    return w;
}

static void watch_unref(gpointer data) {
    SpdfTabWatch* w = data;

    if (!w || !g_atomic_int_dec_and_test(&w->refs)) return;
    if (w->candidate_path) g_unlink(w->candidate_path);
    g_free(w->candidate_path);
    g_free(w);
}

/* Session-restore adoptions: canonical source path -> persisted binding,
 * consumed by the first spdf_watcher_resolve_open on that path. */
typedef struct {
    char* working_path;
    guint64 size;
    double mtime;
} watcher_binding;

static GHashTable* watcher_restore_bindings; /* char* -> watcher_binding* */
static gboolean watcher_sweep_armed;

static void watcher_binding_free(gpointer data) {
    watcher_binding* b = data;
    g_free(b->working_path);
    g_free(b);
}

/* Persistent copies directory: survives quit so session restore reopens the
 * same copy (Mac: Application Support/ReadOnlyCopies; XDG data dir here). */
static char* watcher_copies_dir(gboolean create) {
    char* dir = g_build_filename(g_get_user_data_dir(), "shenzhenpdf", "ReadOnlyCopies", NULL);
    if (create) g_mkdir_with_parents(dir, 0700);
    return dir;
}

gboolean spdf_watcher_is_shadow_path(const char* path) {
    char* dir = watcher_copies_dir(FALSE);
    gboolean r = spdf_watcher_path_is_shadow_in(path, dir);
    g_free(dir);
    return r;
}

/* ---------------------------------------------------------------------------
 * Shadow copies. */

/* Author a fresh copy from the source bytes (atomic write). Returns FALSE on
 * any I/O failure — the caller falls back to opening the source directly
 * (Mac fallback: document still loads, no copy binding recorded). */
static gboolean watcher_write_copy(const char* source_path, const char* copy_path) {
    char* contents = NULL;
    gsize length = 0;
    GError* error = NULL;

    if (!g_file_get_contents(source_path, &contents, &length, &error)) {
        g_warning("shenzhenpdf: read-only copy read failed: %s", error ? error->message : "unknown error");
        g_clear_error(&error);
        return FALSE;
    }
    if (!g_file_set_contents_full(copy_path, contents, (gssize)length, G_FILE_SET_CONTENTS_CONSISTENT, 0600, &error)) {
        g_warning("shenzhenpdf: read-only copy write failed: %s", error ? error->message : "unknown error");
        g_clear_error(&error);
        g_free(contents);
        return FALSE;
    }
    g_free(contents);
    return TRUE;
}

gboolean spdf_watcher_resolve_open(const char* source_path, SpdfWatcherResolution* out) {
    char* canonical;
    watcher_binding* binding = NULL;
    char* copy_path = NULL;
    guint64 src_size = 0;
    double src_mtime = 0.0;
    gboolean copy_exists;

    memset(out, 0, sizeof(*out));
    if (!source_path || !*source_path) return FALSE;
    canonical = g_canonicalize_filename(source_path, NULL);
    if (watcher_restore_bindings) {
        gpointer stolen_key = NULL;
        gpointer stolen_value = NULL;

        if (g_hash_table_steal_extended(watcher_restore_bindings, canonical, &stolen_key, &stolen_value)) {
            g_free(stolen_key);
            binding = stolen_value;
        }
    }

    if (!spdf_watcher_source_is_read_only(canonical) || !spdf_watcher_stat_path(canonical, &src_size, &src_mtime)) {
        /* Writable (or missing — the open error path owns that): no copy. */
        if (binding) watcher_binding_free(binding);
        g_free(canonical);
        return FALSE;
    }

    if (binding && binding->working_path && *binding->working_path) {
        copy_path = g_strdup(binding->working_path);
    } else {
        char* dir = watcher_copies_dir(TRUE);
        char* name = spdf_watcher_shadow_copy_name(canonical);
        copy_path = g_build_filename(dir, name, NULL);
        g_free(name);
        g_free(dir);
    }

    copy_exists = g_file_test(copy_path, G_FILE_TEST_IS_REGULAR);
    if (binding && spdf_watcher_copy_reusable(copy_exists, binding->size, binding->mtime, src_size, src_mtime)) {
        /* Source unchanged vs the stat the copy reflects: reuse, no content
         * read (Mac "unchanged" branch — preserves the binding). */
        out->working_path = copy_path;
        out->copy_file_size = binding->size;
        out->copy_modified_at = binding->mtime;
    } else if (watcher_write_copy(canonical, copy_path)) {
        out->working_path = copy_path;
        out->copy_file_size = src_size;
        out->copy_modified_at = src_mtime;
    } else {
        /* Copy failed: open the source directly, no binding (Mac fallback).
         * The tab still shows the read-only dot. */
        g_free(copy_path);
    }

    if (binding) watcher_binding_free(binding);
    g_free(canonical);
    return TRUE;
}

void spdf_watcher_prime_restore(const char* source_path, const char* working_path, guint64 copy_file_size,
                                double copy_modified_at) {
    watcher_binding* b;

    if (!source_path || !*source_path || !working_path || !*working_path) return;
    if (!watcher_restore_bindings)
        watcher_restore_bindings = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, watcher_binding_free);
    b = g_new0(watcher_binding, 1);
    b->working_path = g_strdup(working_path);
    b->size = copy_file_size;
    b->mtime = copy_modified_at;
    g_hash_table_replace(watcher_restore_bindings, g_canonicalize_filename(source_path, NULL), b);
}

/* Delete tab's copy unless another tab — in ANY window — still references the
 * same copy file (deterministic naming shares copies of one source; Mac
 * deleteReadOnlyCopyIfUnsharedForTab). */
static void watcher_delete_path_if_unshared(SpdfTab* tab, const char* path) {
    GApplication* app = g_application_get_default();

    if (!path || !*path) return;
    if (app && GTK_IS_APPLICATION(app)) {
        for (GList* it = gtk_application_get_windows(GTK_APPLICATION(app)); it; it = it->next) {
            SpdfWindow* win;
            int count;

            if (!SPDF_IS_WINDOW(it->data)) continue;
            win = SPDF_WINDOW(it->data);
            count = spdf_window_tab_count(win);
            for (int t = 0; t < count; ++t) {
                SpdfTab* other = spdf_window_tab_at(win, t);
                if (!other || other == tab) continue;
                if (g_strcmp0(other->working_path, path) == 0) return; /* still in use */
            }
        }
    }
    g_unlink(path);
}

static void watcher_delete_copy_if_unshared(SpdfTab* tab) {
    watcher_delete_path_if_unshared(tab, tab->working_path);
}

/* Clear the shadow binding on the tab (the copy file itself is handled by
 * the callers: deliberate close / repoint delete it when unshared). */
static void watcher_clear_binding(SpdfTab* tab) {
    g_clear_pointer(&tab->working_path, g_free);
    tab->ro_copy_file_size = 0;
    tab->ro_copy_modified_at = 0.0;
}

/* Launch sweep (deferred; Mac sweepOrphanedReadOnlyCopies): delete any file
 * in the copies directory not referenced by a live tab, skipping files
 * touched within the recency window. */
static gboolean watcher_sweep_orphans(gpointer user_data) {
    GApplication* app = g_application_get_default();
    GHashTable* referenced = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    char* dir;
    GDir* listing;

    (void)user_data;
    if (app && GTK_IS_APPLICATION(app)) {
        for (GList* it = gtk_application_get_windows(GTK_APPLICATION(app)); it; it = it->next) {
            SpdfWindow* win;
            int count;

            if (!SPDF_IS_WINDOW(it->data)) continue;
            win = SPDF_WINDOW(it->data);
            count = spdf_window_tab_count(win);
            for (int t = 0; t < count; ++t) {
                SpdfTab* tab = spdf_window_tab_at(win, t);
                if (tab && tab->working_path && *tab->working_path)
                    g_hash_table_add(referenced, g_path_get_basename(tab->working_path));
            }
        }
    }

    dir = watcher_copies_dir(FALSE);
    listing = g_dir_open(dir, 0, NULL); /* may not exist yet — fine */
    if (listing) {
        double now = (double)g_get_real_time() / 1e6;
        const char* name;

        while ((name = g_dir_read_name(listing))) {
            char* full = g_build_filename(dir, name, NULL);
            double mtime = 0.0;

            if (spdf_watcher_stat_path(full, NULL, &mtime) &&
                spdf_watcher_sweep_should_delete(g_hash_table_contains(referenced, name), mtime, now))
                g_unlink(full);
            g_free(full);
        }
        g_dir_close(listing);
    }
    g_free(dir);
    g_hash_table_unref(referenced);
    return G_SOURCE_REMOVE;
}

/* ---------------------------------------------------------------------------
 * Stale (missing-file) tab marking. The Mac tints the tab red and shows
 * "File moved or deleted"; AdwTabPage offers the indicator + attention
 * mechanism instead. The missing marker takes precedence over the read-only
 * dot (Mac: never both). */

static void watch_mark_stale(SpdfTabWatch* w) {
    SpdfTab* tab = w->tab;
    char* tooltip;
    GIcon* icon;

    if (w->stale || !tab->page) return;
    w->stale = TRUE;
    icon = g_themed_icon_new("dialog-warning-symbolic");
    adw_tab_page_set_indicator_icon(tab->page, icon);
    adw_tab_page_set_indicator_tooltip(tab->page, "File moved or deleted");
    g_object_unref(icon);
    adw_tab_page_set_needs_attention(tab->page, TRUE);
    tooltip = g_markup_escape_text(tab->path, -1);
    {
        char* full = g_strdup_printf("File moved or deleted\n%s", tooltip);
        adw_tab_page_set_tooltip(tab->page, full);
        g_free(full);
    }
    g_free(tooltip);
    if (tab->win) {
        char* base = g_path_get_basename(tab->path);
        char* text = g_strdup_printf("File moved or deleted: %s", base);
        spdf_window_show_toast(tab->win, text);
        g_free(text);
        g_free(base);
    }
}

static void watch_clear_stale(SpdfTabWatch* w) {
    SpdfTab* tab = w->tab;
    char* tooltip;

    if (!w->stale || !tab->page) {
        w->stale = FALSE;
        return;
    }
    w->stale = FALSE;
    adw_tab_page_set_needs_attention(tab->page, FALSE);
    tooltip = g_markup_escape_text(tab->path, -1);
    adw_tab_page_set_tooltip(tab->page, tooltip);
    g_free(tooltip);
    /* Restore the indicator to the read-only dot (or nothing). */
    if (tab->read_only_shadow) {
        tab->read_only_shadow = FALSE;
        spdf_tab_set_read_only_shadow(tab, TRUE);
    } else {
        adw_tab_page_set_indicator_icon(tab->page, NULL);
    }
}

/* ---------------------------------------------------------------------------
 * Watch lifecycle + reload. */

static void watch_monitor_changed(GFileMonitor* monitor, GFile* file, GFile* other, GFileMonitorEvent event,
                                  gpointer user_data);

static void watch_set_baseline(SpdfTabWatch* w) {
    SpdfTab* tab = w->tab;

    if (tab->read_only_shadow && tab->ro_copy_modified_at > 0.0) {
        /* Canonical baseline for a shadow tab: the source stat the copy
         * reflects (Mac copiedSource*). */
        w->baseline_size = tab->ro_copy_file_size;
        w->baseline_mtime = tab->ro_copy_modified_at;
        w->have_baseline = TRUE;
    } else {
        w->have_baseline = spdf_watcher_stat_path(tab->path, &w->baseline_size, &w->baseline_mtime);
    }
}
static void watch_start_monitor(SpdfTabWatch* w) {
    GFile* file;
    GError* error = NULL;

    if (w->monitor) {
        if (w->changed_id) g_signal_handler_disconnect(w->monitor, w->changed_id);
        g_file_monitor_cancel(w->monitor);
        g_clear_object(&w->monitor);
        w->changed_id = 0;
    }
    file = g_file_new_for_path(w->tab->path);
    w->monitor = g_file_monitor_file(file, G_FILE_MONITOR_WATCH_MOVES, NULL, &error);
    g_object_unref(file);
    if (!w->monitor) {
        g_warning("shenzhenpdf: file monitor failed for %s: %s", w->tab->path,
                  error ? error->message : "unknown error");
        g_clear_error(&error);
        return;
    }
    w->changed_id = g_signal_connect(w->monitor, "changed", G_CALLBACK(watch_monitor_changed), w);
}

static char* watcher_reload_copy_path(const char* source_path) {
    char* dir = watcher_copies_dir(TRUE);
    char* path = spdf_password_reload_staging_path(dir, source_path);
    g_free(dir);
    return path;
}

static void watch_candidate_clear(SpdfTabWatch* w) {
    if (w->candidate_path) g_unlink(w->candidate_path);
    g_clear_pointer(&w->candidate_path, g_free);
    w->candidate_size = 0;
    w->candidate_mtime = 0.0;
}

static void watch_reload_ready(spdf_document* candidate_doc, SpdfPasswordCredential* candidate_credential,
                               gboolean cancelled, const char* error, gpointer user_data) {
    SpdfTabWatch* w = user_data;
    SpdfTab* tab = w->tab;
    SpdfRenderService* candidate_render;
    SpdfPasswordReloadPolicy policy = spdf_password_reload_policy(candidate_doc != NULL, cancelled);
    double scroll_x = 0.0, scroll_y = 0.0;
    const char* target;

    w->prompt = NULL;
    if (w->detached || !tab) {
        if (candidate_doc) spdf_close(candidate_doc);
        spdf_password_credential_unref(candidate_credential);
        watch_candidate_clear(w);
        return;
    }
    target = w->candidate_path ? w->candidate_path : tab->path;
    if (!policy.replace_live_state) {
        if (!cancelled)
            g_warning("shenzhenpdf: reload after disk change failed for %s: %s", target,
                      error && *error ? error : "unknown error");
        else if (tab->win)
            spdf_window_show_toast(tab->win, "Reload canceled; current view kept. Switch tabs to retry.");
        spdf_password_credential_unref(candidate_credential);
        watch_candidate_clear(w);
        w->reload_pending = policy.retry_pending;
        return;
    }
    if (!spdf_password_credential_refresh_source(candidate_credential, tab->path)) {
        spdf_close(candidate_doc);
        spdf_password_credential_unref(candidate_credential);
        watch_candidate_clear(w);
        w->reload_pending = TRUE;
        return;
    }
    candidate_render = spdf_render_service_new(target, candidate_credential, NULL);
    if (!candidate_render) {
        spdf_close(candidate_doc);
        spdf_password_credential_unref(candidate_credential);
        watch_candidate_clear(w);
        w->reload_pending = TRUE;
        return;
    }
    if (tab->view) spdf_doc_view_get_scroll(tab->view, &scroll_x, &scroll_y);
    {
        spdf_document* old_doc = tab->doc;
        SpdfRenderService* old_render = tab->render;
        SpdfPasswordCredential* old_credential = tab->credential;
        char* old_working_path = g_steal_pointer(&tab->working_path);
        tab->doc = candidate_doc;
        tab->render = candidate_render;
        tab->credential = candidate_credential;
        tab->working_path = g_steal_pointer(&w->candidate_path);
        tab->ro_copy_file_size = tab->working_path ? w->candidate_size : 0;
        tab->ro_copy_modified_at = tab->working_path ? w->candidate_mtime : 0.0;
        spdf_tab_set_read_only_shadow(tab, w->candidate_read_only);
        if (tab->view) spdf_doc_view_document_changed(tab->view);
        spdf_password_credential_revoke(old_credential);
        if (old_render) spdf_render_service_free(old_render);
        if (old_doc) spdf_close(old_doc);
        spdf_password_credential_unref(old_credential);
        watcher_delete_path_if_unshared(tab, old_working_path);
        g_free(old_working_path);
    }
    if (tab->view) spdf_doc_view_set_scroll(tab->view, scroll_x, scroll_y);
    spdf_annot_document_reloaded(tab);
    w->reload_pending = FALSE;
    watch_set_baseline(w);
    watch_clear_stale(w);
    if (tab->page) {
        char* title = spdf_tab_display_name(tab);
        adw_tab_page_set_title(tab->page, title);
        g_free(title);
    }
    if (tab->win) {
        spdf_window_update_title(tab->win);
        spdf_window_show_toast(tab->win, "Reloaded after the file changed on disk.");
    }
}

/* Transactional asynchronous reload: live state and baseline change only in
 * watch_reload_ready after authentication and renderer construction. */
static void watch_reload(SpdfTabWatch* w) {
    SpdfTab* tab = w->tab;
    const char* target;
    SpdfPasswordCredential* candidate;

    if (!tab || w->detached || w->prompt) return;
    watch_candidate_clear(w);
    w->candidate_read_only = spdf_watcher_source_is_read_only(tab->path);
    if (w->candidate_read_only && spdf_watcher_stat_path(tab->path, &w->candidate_size, &w->candidate_mtime)) {
        w->candidate_path = watcher_reload_copy_path(tab->path);
        if (!watcher_write_copy(tab->path, w->candidate_path)) g_clear_pointer(&w->candidate_path, g_free);
    }
    target = w->candidate_path ? w->candidate_path : tab->path;
    candidate = spdf_password_credential_clone(tab->credential);
    w->prompt = spdf_password_open_async(tab->win ? GTK_WINDOW(tab->win) : NULL, tab->path, target, candidate,
                                         watch_reload_ready, watch_ref(w), watch_unref);
    spdf_password_credential_unref(candidate);
}

/* Reload only when disk differs from baseline, avoiding self-save loops. */
static void watch_check(SpdfTabWatch* w);

static gboolean watch_missing_retry(gpointer user_data) {
    SpdfTabWatch* w = user_data;
    guint64 size = 0;
    double mtime = 0.0;

    if (spdf_watcher_stat_path(w->tab->path, &size, &mtime)) {
        /* Reappeared (atomic replace landed): re-arm the monitor, reload if
         * it really changed. */
        w->retry_id = 0;
        w->retry_count = 0;
        watch_start_monitor(w);
        if (!w->have_baseline || spdf_watcher_stat_differs(size, mtime, w->baseline_size, w->baseline_mtime))
            watch_reload(w);
        else
            watch_clear_stale(w);
        return G_SOURCE_REMOVE;
    }
    if (++w->retry_count >= SPDF_WATCHER_MISSING_RETRIES) {
        /* Stayed gone: stale UI. The monitor keeps watching the path (GIO
         * watches the parent directory for the name), so a later
         * re-creation still reloads and clears the marker. */
        w->retry_id = 0;
        w->retry_count = 0;
        watch_mark_stale(w);
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

static void watch_begin_missing_grace(SpdfTabWatch* w) {
    if (w->retry_id) return;
    w->retry_count = 0;
    w->retry_id = g_timeout_add(SPDF_WATCHER_MISSING_RETRY_MS, watch_missing_retry, w);
}

static void watch_check(SpdfTabWatch* w) {
    guint64 size = 0;
    double mtime = 0.0;

    if (!spdf_watcher_stat_path(w->tab->path, &size, &mtime)) {
        /* Temporarily absent (atomic replace in flight) or genuinely gone. */
        watch_begin_missing_grace(w);
        return;
    }
    if (w->have_baseline && !spdf_watcher_stat_differs(size, mtime, w->baseline_size, w->baseline_mtime)) {
        w->reload_pending = FALSE;
        watch_clear_stale(w);
        return;
    }
    watch_reload(w);
}

static gboolean watch_debounce_fired(gpointer user_data) {
    SpdfTabWatch* w = user_data;

    if (!spdf_watcher_debounce_fire(&w->debounce, g_get_monotonic_time())) return G_SOURCE_CONTINUE;
    w->debounce_id = 0;
    watch_check(w);
    return G_SOURCE_REMOVE;
}

static void watch_debounce_kick(SpdfTabWatch* w) {
    spdf_watcher_debounce_event(&w->debounce, g_get_monotonic_time(), (gint64)SPDF_WATCHER_DEBOUNCE_MS * 1000);
    if (w->debounce_id) g_source_remove(w->debounce_id);
    w->debounce_id = g_timeout_add(SPDF_WATCHER_DEBOUNCE_MS, watch_debounce_fired, w);
    /* A change event supersedes any missing-grace loop in flight. */
    if (w->retry_id) {
        g_source_remove(w->retry_id);
        w->retry_id = 0;
        w->retry_count = 0;
    }
}

static void watch_monitor_changed(GFileMonitor* monitor, GFile* file, GFile* other, GFileMonitorEvent event,
                                  gpointer user_data) {
    SpdfTabWatch* w = user_data;

    (void)monitor;
    (void)file;
    (void)other;
    switch (event) {
        case G_FILE_MONITOR_EVENT_DELETED:
        case G_FILE_MONITOR_EVENT_MOVED_OUT:
        case G_FILE_MONITOR_EVENT_RENAMED:
            watch_begin_missing_grace(w);
            break;
        case G_FILE_MONITOR_EVENT_CHANGED:
        case G_FILE_MONITOR_EVENT_CHANGES_DONE_HINT:
        case G_FILE_MONITOR_EVENT_CREATED:
        case G_FILE_MONITOR_EVENT_MOVED_IN:
        case G_FILE_MONITOR_EVENT_ATTRIBUTE_CHANGED:
            watch_debounce_kick(w);
            break;
        default:
            break;
    }
}

/* ---------------------------------------------------------------------------
 * Public tab hooks. */

void spdf_watcher_tab_attached(SpdfTab* tab) {
    SpdfTabWatch* w;

    if (!tab || !tab->path || !*tab->path || tab->watch) return;
    w = g_new0(SpdfTabWatch, 1);
    w->refs = 1;
    w->tab = tab;
    tab->watch = w;
    watch_set_baseline(w);
    watch_start_monitor(w);
    if (!watcher_sweep_armed) {
        /* Deferred launch sweep (Mac: after restore + catch-up save). */
        watcher_sweep_armed = TRUE;
        g_timeout_add_seconds(10, watcher_sweep_orphans, NULL);
    }
}

void spdf_watcher_tab_detached(SpdfTab* tab) {
    SpdfTabWatch* w;

    if (!tab) return;
    w = tab->watch;
    if (w) {
        w->detached = TRUE;
        w->tab = NULL;
        tab->watch = NULL;
        if (w->debounce_id) g_source_remove(w->debounce_id);
        if (w->retry_id) g_source_remove(w->retry_id);
        if (w->monitor) {
            if (w->changed_id) g_signal_handler_disconnect(w->monitor, w->changed_id);
            g_file_monitor_cancel(w->monitor);
            g_object_unref(w->monitor);
        }
        if (w->prompt) spdf_password_prompt_cancel(w->prompt);
        watch_unref(w);
    }
    /* The copy file is NOT deleted here: it must survive quit so session
     * restore reopens it (deliberate close / Save-As delete it instead). */
    watcher_clear_binding(tab);
}

void spdf_watcher_tab_deliberate_close(SpdfTab* tab) {
    if (!tab) return;
    watcher_delete_copy_if_unshared(tab);
}

void spdf_watcher_tab_repoint(SpdfTab* tab) {
    SpdfTabWatch* w;

    if (!tab) return;
    /* Save-As landed on a writable, non-temp file: the shadow binding (if
     * any) is obsolete. */
    if (tab->working_path) watcher_delete_copy_if_unshared(tab);
    watcher_clear_binding(tab);
    spdf_tab_set_read_only_shadow(tab, FALSE);
    w = tab->watch;
    if (!w) {
        spdf_watcher_tab_attached(tab);
        return;
    }
    if (w->retry_id) {
        g_source_remove(w->retry_id);
        w->retry_id = 0;
        w->retry_count = 0;
    }
    watch_clear_stale(w);
    watch_set_baseline(w);
    watch_start_monitor(w);
}

void spdf_watcher_note_self_save(SpdfTab* tab) {
    if (!tab || !tab->watch) return;
    watch_set_baseline(tab->watch);
}

void spdf_watcher_retry_pending(SpdfTab* tab) {
    if (tab && tab->watch && tab->watch->reload_pending) watch_check(tab->watch);
}
