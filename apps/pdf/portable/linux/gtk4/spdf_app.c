// spdf_app.c — AdwApplication subclass. Owns the launch path (nothing
// synchronous or expensive before the first window is mapped), command-line
// documents (second instances forward here, so launches feel instant),
// multi-window session restore/capture through the spdf_state.c API, the
// recents list and the reopen-last-closed ring (10 entries, persisted state
// side, parity with GTK3 + Mac).

#include <glib-unix.h>
#include <malloc.h> // malloc_trim: return freed heap after last-window close (resident mode)
#include <string.h>

#include "spdf_app.h"
#include "spdf_minimap.h"
#include "spdf_resident.h"
#include "spdf_updater.h"
#include "spdf_watcher.h"
#include "spdf_window.h"

struct _SpdfApp {
    AdwApplication parent_instance;

    SpdfState* state; // lazy; see spdf_app_get_state()
    guint sigterm_id;
    guint sigint_id;
    // --- resident instant-launch (Wave D) ------------------------------------
    gboolean resident_hold;   // g_application_hold currently taken
    gboolean opened_anything; // a window was opened this run (see activate)
};

G_DEFINE_FINAL_TYPE(SpdfApp, spdf_app, ADW_TYPE_APPLICATION)

SpdfState* spdf_app_get_state(SpdfApp* app) {
    g_return_val_if_fail(SPDF_IS_APP(app), NULL);
    if (!app->state) {
        spdf_launch_mark("state-load-begin");
        app->state = spdf_state_load();
        spdf_launch_mark("state-load-end");
    }
    return app->state;
}

// ---------------------------------------------------------------------------
// Recents + reopen-last-closed ring (both live in spdf_state.c)

void spdf_app_remember_recent(SpdfApp* app, const char* path) {
    g_return_if_fail(SPDF_IS_APP(app));
    if (!path || !*path) return;
    spdf_state_add_recent(spdf_app_get_state(app), path);
    for (GList* it = gtk_application_get_windows(GTK_APPLICATION(app)); it; it = it->next)
        if (SPDF_IS_WINDOW(it->data)) spdf_window_refresh_recents(SPDF_WINDOW(it->data));
}

void spdf_app_remember_closed(SpdfApp* app, const char* path) {
    g_return_if_fail(SPDF_IS_APP(app));
    if (!path || !*path) return;
    spdf_state_remember_closed(spdf_app_get_state(app), path);
}

char* spdf_app_pop_closed(SpdfApp* app) {
    g_return_val_if_fail(SPDF_IS_APP(app), NULL);
    return spdf_state_pop_closed(spdf_app_get_state(app));
}

gboolean spdf_app_has_closed(SpdfApp* app) {
    g_return_val_if_fail(SPDF_IS_APP(app), FALSE);
    return spdf_state_closed_count(spdf_app_get_state(app)) > 0;
}

// ---------------------------------------------------------------------------
// Session capture. Each window is snapshotted into an owned SpdfSessionWindow
// and handed to the state module (merge-on-write keeps other processes'
// windows). The WM close (Alt+F4 / titlebar button) snapshots ALL windows and
// closes the whole app (spdf_app_close_all_windows).

static int fit_mode_id_for_view(SpdfDocView* view) {
    // settings/session schema: 0 custom, 1 actual, 2 width, 3 height, 4 page
    switch (spdf_doc_view_get_fit(view)) {
        case SPDF_FIT_PAGE:
            return 4;
        case SPDF_FIT_HEIGHT:
            return 3;
        case SPDF_FIT_WIDTH:
            return 2;
        case SPDF_FIT_CUSTOM:
        default:
            return 0;
    }
}

static void snapshot_window(SpdfApp* app, SpdfWindow* win) {
    SpdfState* state = spdf_app_get_state(app);
    SpdfSessionWindow* snapshot;
    const SpdfSessionWindow* previous;
    SpdfTab* selected;
    int tabs;
    int width;
    int height;

    snapshot = spdf_session_window_new(spdf_window_get_session_id(win));
    if (!spdf_window_get_session_id(win)) spdf_window_set_session_id(win, snapshot->id);

    width = gtk_widget_get_width(GTK_WIDGET(win));
    height = gtk_widget_get_height(GTK_WIDGET(win));
    if (width <= 1 || height <= 1) gtk_window_get_default_size(GTK_WINDOW(win), &width, &height);
    snapshot->frame.width = width;
    snapshot->frame.height = height;
    // Wayland has no global window coordinates; keep the previously stored
    // origin (Mac/GTK3 files may carry one) instead of clobbering it.
    previous = spdf_state_session_window_by_id(state, snapshot->id);
    if (previous && previous->has_frame) {
        snapshot->frame.x = previous->frame.x;
        snapshot->frame.y = previous->frame.y;
    }
    snapshot->has_frame = TRUE;

    selected = spdf_window_current_tab(win);
    snapshot->selected_tab = 0;
    tabs = spdf_window_tab_count(win);
    for (int t = 0; t < tabs; ++t) {
        SpdfTab* tab = spdf_window_tab_at(win, t);
        SpdfSessionTab* session_tab;

        if (!tab || !tab->path || !*tab->path) continue;
        session_tab = spdf_session_window_add_tab(snapshot);
        session_tab->path = g_strdup(tab->path);
        if (tab->page) session_tab->title = g_strdup(adw_tab_page_get_title(tab->page));
        session_tab->search_text = g_strdup(tab->search_text ? tab->search_text : "");
        session_tab->search_regex = tab->search_regex;
        session_tab->search_regex_multiline = tab->search_regex_multiline;
        session_tab->find_match_index = tab->find_match_index;
        session_tab->read_only = tab->read_only_shadow;
        // --- watcher (Wave C): persist the shadow-copy binding so restore
        // reopens the same copy (Mac keys workingPath/roCopyFileSize/
        // roCopyModifiedAt; path above stays the SOURCE).
        session_tab->working_path = g_strdup(tab->working_path ? tab->working_path : "");
        session_tab->ro_copy_file_size = tab->ro_copy_file_size;
        session_tab->ro_copy_modified_at = tab->ro_copy_modified_at;
        // --- minimap module (wave B): per-tab visibility rides the session
        // like the Mac schema (documents.json keeps the per-document truth).
        session_tab->show_minimap = tab->show_minimap;
        session_tab->has_show_minimap = TRUE;
        if (tab->view) {
            session_tab->page = spdf_doc_view_current_page(tab->view);
            session_tab->zoom = spdf_doc_view_get_zoom(tab->view);
            session_tab->custom_zoom = session_tab->zoom;
            session_tab->fit_mode = fit_mode_id_for_view(tab->view);
            spdf_doc_view_get_scroll(tab->view, &session_tab->scroll_x, &session_tab->scroll_y);
            session_tab->has_scroll_origin = TRUE;
        }
        if (tab == selected) snapshot->selected_tab = (int)snapshot->tabs->len - 1;
    }
    if (snapshot->tabs->len == 0) {
        // Never persist tab-less windows: the session parser skips them on
        // read but the merge-on-write would keep the entry on disk forever.
        spdf_state_remove_session_window(state, snapshot->id);
        spdf_session_window_free(snapshot);
        return;
    }
    spdf_state_update_session_window(state, snapshot); // takes ownership
}

void spdf_app_save_session(SpdfApp* app) {
    SpdfState* state;
    GList* windows;
    GPtrArray* stale;
    guint stored;

    g_return_if_fail(SPDF_IS_APP(app));
    state = spdf_app_get_state(app);
    windows = g_list_copy(gtk_application_get_windows(GTK_APPLICATION(app)));
    // Resident mode (Wave D) makes quit reachable with ZERO windows (Ctrl+Q,
    // SIGTERM, updater restart while idling after the last window closed).
    // What is on disk then is the last-window-close capture — running the
    // stale-prune below against an empty window list would wipe it.
    if (!windows) return;
    windows = g_list_reverse(windows); // stable order: oldest window first
    for (GList* it = windows; it; it = it->next)
        if (SPDF_IS_WINDOW(it->data)) snapshot_window(app, SPDF_WINDOW(it->data));

    // GApplication uniqueness means no other process owns session windows, so
    // stored ids without a live window are leftovers from crashed/old runs —
    // prune them or every launch resurrects them forever.
    stale = g_ptr_array_new_with_free_func(g_free);
    stored = spdf_state_session_window_count(state);
    for (guint i = 0; i < stored; ++i) {
        const SpdfSessionWindow* sw = spdf_state_session_window(state, i);
        gboolean live = FALSE;

        if (!sw || !sw->id) continue;
        for (GList* it = windows; it && !live; it = it->next)
            if (SPDF_IS_WINDOW(it->data) && g_strcmp0(spdf_window_get_session_id(SPDF_WINDOW(it->data)), sw->id) == 0)
                live = TRUE;
        if (!live) g_ptr_array_add(stale, g_strdup(sw->id));
    }
    for (guint i = 0; i < stale->len; ++i) spdf_state_remove_session_window(state, g_ptr_array_index(stale, i));
    g_ptr_array_unref(stale);
    g_list_free(windows);
    spdf_state_save_session(state);
}

void spdf_app_close_all_windows(SpdfApp* app, SpdfWindow* keep) {
    GList* windows;

    g_return_if_fail(SPDF_IS_APP(app));
    // Alt+F4 / the WM close button quits the whole app, not just one window
    // (user request): snapshot every window while they are all still alive,
    // flush synchronously, and tear the others down. `keep` is the window
    // whose close-request is in flight — GTK destroys it when the handler
    // propagates. Under the resident hold the process idles on invisibly
    // (instant relaunch); without it the last destroy exits. Either way the
    // next activate restores the full multi-window session.
    spdf_app_save_session(app);
    spdf_state_flush(spdf_app_get_state(app));
    app->opened_anything = FALSE; // re-arm session restore for the next activate
    windows = g_list_copy(gtk_application_get_windows(GTK_APPLICATION(app)));
    for (GList* it = windows; it; it = it->next)
        if (SPDF_IS_WINDOW(it->data) && it->data != keep) gtk_window_destroy(GTK_WINDOW(it->data));
    g_list_free(windows);
    spdf_app_notify_last_window_closed(app);
}

// ---------------------------------------------------------------------------
// Session restore starts only after each parent window is mapped.
static void apply_session_geometry(SpdfWindow* win, const SpdfSessionWindow* stored) {
    GdkRectangle frame;
    GdkRectangle workarea = {0, 0, 0, 0}; // invalid => hard caps only; the
                                          // compositor places the window

    if (!stored->has_frame || stored->frame.width <= 0 || stored->frame.height <= 0) return;
    frame = stored->frame;
    spdf_state_clamp_geometry(&workarea, &frame);
    gtk_window_set_default_size(GTK_WINDOW(win), frame.width, frame.height);
}

static void apply_session_tab(SpdfTab* tab, const SpdfSessionTab* stored) {
    if (!tab || !stored) return;
    if (stored->search_text && *stored->search_text) {
        g_free(tab->search_text);
        tab->search_text = g_strdup(stored->search_text);
    }
    tab->search_regex = stored->search_regex;
    tab->search_regex_multiline = stored->search_regex_multiline;
    tab->find_match_index = stored->find_match_index;
    if (stored->has_show_minimap) spdf_minimap_set_visible(tab, stored->show_minimap, FALSE);
    if (tab->view) {
        switch (stored->fit_mode) {
            case 4:
                spdf_doc_view_set_fit(tab->view, SPDF_FIT_PAGE);
                break;
            case 3:
                spdf_doc_view_set_fit(tab->view, SPDF_FIT_HEIGHT);
                break;
            case 2:
                spdf_doc_view_set_fit(tab->view, SPDF_FIT_WIDTH);
                break;
            case 1:
                spdf_doc_view_set_zoom(tab->view, 1.0, FALSE, 0, 0);
                break;
            default:
                if (stored->zoom > 0.0) spdf_doc_view_set_zoom(tab->view, stored->zoom, FALSE, 0, 0);
                break;
        }
        if (stored->has_scroll_origin) spdf_doc_view_set_scroll(tab->view, stored->scroll_x, stored->scroll_y);
    }
}

typedef struct {
    const SpdfSessionTab* stored;
    int index;
    gboolean selected;
} session_tab_request;

static void session_tab_opened(SpdfTab* tab, gboolean cancelled, gpointer user_data) {
    session_tab_request* request = user_data;
    AdwTabView* view;
    (void)cancelled;
    if (!tab) return;
    apply_session_tab(tab, request->stored);
    view = spdf_window_get_tab_view(tab->win);
    adw_tab_view_reorder_page(view, tab->page, MIN(request->index, adw_tab_view_get_n_pages(view) - 1));
    if (request->selected) adw_tab_view_set_selected_page(view, tab->page);
}

static void open_session_tab(SpdfWindow* win, const SpdfSessionTab* stored, int index, gboolean selected) {
    session_tab_request* request;
    if (!stored || !stored->path || !*stored->path) return;
    if (stored->read_only)
        spdf_watcher_prime_restore(stored->path, stored->working_path, stored->ro_copy_file_size,
                                   stored->ro_copy_modified_at);
    request = g_new0(session_tab_request, 1);
    *request = (session_tab_request){stored, index, selected};
    spdf_window_open_path_async(win, stored->path, stored->page, FALSE, session_tab_opened, request, g_free);
}

typedef struct session_restore_request {
    SpdfApp* app;             // owned ref
    SpdfWindow* first_window; // owned ref, may be NULL
    int first_index;          // stored session index of first_window
    int first_selected;
} session_restore_request;

static gboolean session_restore_idle(gpointer user_data) {
    session_restore_request* req = user_data;
    SpdfApp* app = req->app;
    SpdfState* state = spdf_app_get_state(app);
    guint windows = spdf_state_session_window_count(state);
    if (req->first_window) {
        SpdfWindow* win = req->first_window;
        const SpdfSessionWindow* stored = spdf_state_session_window(state, (guint)req->first_index);
        if (stored) {
            for (guint t = 0; t < stored->tabs->len; ++t) {
                if ((int)t == req->first_selected) continue;
                open_session_tab(win, g_ptr_array_index(stored->tabs, t), (int)t, FALSE);
            }
        }
    }

    for (guint w = 0; w < windows; ++w) {
        const SpdfSessionWindow* stored = spdf_state_session_window(state, w);
        SpdfWindow* win;

        if ((int)w == req->first_index) continue;
        if (!stored || stored->tabs->len == 0) continue; // stale empty entry
        win = spdf_window_new(ADW_APPLICATION(app));
        spdf_window_set_session_id(win, stored->id);
        apply_session_geometry(win, stored);
        gtk_window_present(GTK_WINDOW(win));
        for (guint t = 0; t < stored->tabs->len; ++t) {
            open_session_tab(win, g_ptr_array_index(stored->tabs, t), (int)t, (int)t == stored->selected_tab);
        }
    }

    spdf_launch_mark("session-restored");
    g_clear_object(&req->first_window);
    g_clear_object(&req->app);
    g_free(req);
    return G_SOURCE_REMOVE;
}

static void restore_session_or_open_empty(SpdfApp* app) {
    SpdfState* state = spdf_app_get_state(app);
    guint windows = spdf_state_session_window_count(state);
    SpdfWindow* win = spdf_window_new(ADW_APPLICATION(app));
    int first_index = -1;

    // Fast path: the first stored window that actually has tabs, so the
    // first paint already shows a document.
    for (guint w = 0; w < windows; ++w) {
        const SpdfSessionWindow* stored = spdf_state_session_window(state, w);
        if (stored && stored->tabs->len > 0) {
            first_index = (int)w;
            break;
        }
    }
    if (first_index < 0 && windows > 0 && spdf_state_session_window(state, 0)) first_index = 0;

    if (first_index >= 0) {
        const SpdfSessionWindow* stored = spdf_state_session_window(state, (guint)first_index);
        session_restore_request* req;
        int selected = CLAMP(stored->selected_tab, 0, MAX((int)stored->tabs->len - 1, 0));

        spdf_window_set_session_id(win, stored->id);
        apply_session_geometry(win, stored);
        gtk_window_present(GTK_WINDOW(win));
        spdf_launch_mark("first-window-present");
        if (stored->tabs->len > 0)
            open_session_tab(win, g_ptr_array_index(stored->tabs, (guint)selected), selected, TRUE);

        req = g_new0(session_restore_request, 1);
        req->app = g_object_ref(app);
        req->first_window = g_object_ref(win);
        req->first_index = first_index;
        req->first_selected = selected;
        g_idle_add(session_restore_idle, req);
        return;
    }
    gtk_window_present(GTK_WINDOW(win));
    spdf_launch_mark("first-window-present");
}

// ---------------------------------------------------------------------------
// Resident instant-launch (Wave D; spec "Launch speed", two-track strategy).
// State machine of the hold:
//
//   setting on  + not held  ->  g_application_hold    (startup, or toggle on)
//   setting off + held      ->  g_application_release (toggle off; with no
//                                windows the use count hits 0 and the process
//                                exits — exactly today's non-resident life)
//
// The hold keeps the process alive after the last window closes, so the next
// `shenzhenpdf file.pdf` is a D-Bus forward into spdf_app_command_line
// (measured 30 ms) instead of a cold GTK4 init (~285 ms empty-window floor).
// Paths that must STILL quit for real — app.quit (Ctrl+Q), SIGTERM/SIGINT,
// the updater restart flow — all go through g_application_quit, which exits
// the main loop regardless of the hold count. No release bookkeeping needed.

static void resident_update_hold(SpdfApp* app) {
    gboolean want = spdf_state_settings(spdf_app_get_state(app))->instant_launch_resident;

    if (want == app->resident_hold) return;
    app->resident_hold = want;
    if (want)
        g_application_hold(G_APPLICATION(app));
    else
        g_application_release(G_APPLICATION(app));
}

// Deferred autostart reconcile (one stat + at most one small file write):
// runs at LOW priority so it lands after the first window painted; also
// repairs a stale Exec line when the binary moved (user-local installs).
static gboolean resident_autostart_idle(gpointer user_data) {
    SpdfApp* app = SPDF_APP(user_data);
    spdf_resident_sync_autostart(spdf_state_settings(spdf_app_get_state(app))->instant_launch_resident);
    return G_SOURCE_REMOVE;
}

static gboolean resident_trim_idle(gpointer user_data) {
    SpdfApp* app = SPDF_APP(user_data);
    GList* windows = gtk_application_get_windows(GTK_APPLICATION(app));

    // Runs after gtk_window_destroy finished tearing down tabs, render
    // services and thumbnail caches; with no window left, hand the freed
    // heap back to the OS so the resident process idles at a small RSS.
    if (!windows) malloc_trim(0);
    return G_SOURCE_REMOVE;
}

void spdf_app_notify_last_window_closed(SpdfApp* app) {
    g_return_if_fail(SPDF_IS_APP(app));
    if (!app->resident_hold) return; // non-resident: this close quits anyway
    g_idle_add_full(G_PRIORITY_LOW, resident_trim_idle, g_object_ref(app), g_object_unref);
}

// app.instant-launch — stateful toggle behind the hamburger menu item and the
// command palette. Takes effect immediately: hold/release + autostart file.
static void instant_launch_change_state(GSimpleAction* action, GVariant* value, gpointer user_data) {
    SpdfApp* app = SPDF_APP(user_data);
    SpdfState* state = spdf_app_get_state(app);
    gboolean enabled = g_variant_get_boolean(value);

    g_simple_action_set_state(action, value);
    if (spdf_state_settings(state)->instant_launch_resident == enabled) return;
    spdf_state_settings(state)->instant_launch_resident = enabled;
    spdf_state_save_settings(state);
    spdf_resident_sync_autostart(enabled); // user intent, not the launch path: sync now
    resident_update_hold(app);
}

// ---------------------------------------------------------------------------
// Application actions

static SpdfWindow* ensure_window_for_documents(SpdfApp* app) {
    GtkWindow* active = gtk_application_get_active_window(GTK_APPLICATION(app));
    // Never adopt the transparent resident-warmup window (it is being torn
    // down); a document arriving during the ~100 ms login warmup gets its
    // own real window.
    if (active && SPDF_IS_WINDOW(active) && !g_object_get_data(G_OBJECT(active), "spdf-warmup"))
        return SPDF_WINDOW(active);
    return spdf_window_new(ADW_APPLICATION(app));
}

static void action_quit(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfApp* app = SPDF_APP(user_data);
    (void)action;
    (void)parameter;
    spdf_app_save_session(app);
    spdf_state_flush(spdf_app_get_state(app));
    g_application_quit(G_APPLICATION(app));
}

static void action_about(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfApp* app = SPDF_APP(user_data);
    GtkWindow* active = gtk_application_get_active_window(GTK_APPLICATION(app));
    AdwDialog* dialog = adw_about_dialog_new();

    (void)action;
    (void)parameter;
    g_object_set(dialog, "application-name", SPDF_APP_DISPLAY_NAME, "application-icon", SPDF_APP_ID, "developer-name",
                 "Intuition", "version", SPDF_APP_VERSION, NULL);
    adw_dialog_present(dialog, active ? GTK_WIDGET(active) : NULL);
}

static void action_open_recent(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfApp* app = SPDF_APP(user_data);
    const char* path = g_variant_get_string(parameter, NULL);
    SpdfWindow* win;

    (void)action;
    if (!path || !*path) return;
    win = ensure_window_for_documents(app);
    gtk_window_present(GTK_WINDOW(win));
    spdf_window_open_path(win, path, 0, TRUE);
}

static const GActionEntry k_app_actions[] = {
    {"quit", action_quit, NULL, NULL, NULL, {0}},
    {"about", action_about, NULL, NULL, NULL, {0}},
    {"open-recent", action_open_recent, "s", NULL, NULL, {0}},
};

// ---------------------------------------------------------------------------
// GApplication vfuncs

static gboolean terminate_signal(gpointer user_data) {
    SpdfApp* app = SPDF_APP(user_data);
    app->sigterm_id = 0;
    app->sigint_id = 0;
    spdf_app_save_session(app);
    spdf_state_flush(spdf_app_get_state(app));
    g_application_quit(G_APPLICATION(app));
    return G_SOURCE_REMOVE;
}

static void spdf_app_startup(GApplication* app) {
    SpdfApp* self = SPDF_APP(app);

    spdf_launch_mark("startup-begin");
    G_APPLICATION_CLASS(spdf_app_parent_class)->startup(app);
    // Window icon: without an explicit name GTK falls back to the prgname,
    // which resolves for the deb (hicolor "shenzhenpdf") but not under
    // Flatpak (icon exported as the app id) — decoration layouts that show
    // the window icon then render the broken-image glyph.
    gtk_window_set_default_icon_name(g_getenv("FLATPAK_ID") ? g_getenv("FLATPAK_ID") : "shenzhenpdf");
    g_action_map_add_action_entries(G_ACTION_MAP(app), k_app_actions, G_N_ELEMENTS(k_app_actions), app);
    spdf_shortcuts_install(GTK_APPLICATION(app)); // hash inserts only; cheap
    self->sigterm_id = g_unix_signal_add(SIGTERM, terminate_signal, self);
    self->sigint_id = g_unix_signal_add(SIGINT, terminate_signal, self);
    // Auto-updater (spdf_updater.c): registers two timers only — the launch
    // health check + first daily check fire seconds after the main loop
    // settles, and autoUpdateEnabled is read live inside the trigger, so
    // nothing here touches state or the network on the launch path.
    spdf_updater_start(self);
    // --- resident instant-launch (Wave D): take the hold as soon as the
    // setting is known (state load is one settings.json+session.json read
    // that activate/command-line needs moments later anyway) and register
    // the toggle with its persisted state.
    resident_update_hold(self);
    spdf_launch_mark(self->resident_hold ? "resident-hold" : "resident-off");
    {
        GSimpleAction* instant = g_simple_action_new_stateful(
            "instant-launch", NULL,
            g_variant_new_boolean(spdf_state_settings(spdf_app_get_state(self))->instant_launch_resident));
        g_signal_connect(instant, "change-state", G_CALLBACK(instant_launch_change_state), self);
        g_action_map_add_action(G_ACTION_MAP(app), G_ACTION(instant));
        g_object_unref(instant);
    }
    // Autostart entry reconcile: deferred to a LOW idle (after first paint).
    g_idle_add_full(G_PRIORITY_LOW, resident_autostart_idle, g_object_ref(self), g_object_unref);
    spdf_launch_mark("startup-end");
}

static void spdf_app_activate(GApplication* app) {
    SpdfApp* self = SPDF_APP(app);
    GtkWindow* active = gtk_application_get_active_window(GTK_APPLICATION(app));

    spdf_launch_mark("activate");
    if (active) {
        gtk_window_present(active);
        return;
    }
    // --- resident (Wave D): session restore runs whenever nothing has been
    // opened yet THIS cycle. spdf_app_close_all_windows (the Alt+F4 path)
    // re-arms opened_anything, so a relaunch after a WM close restores the
    // full session even when the resident process never exited; a
    // `--resident` login start has opened nothing yet, so the first real
    // activate after login also restores like a cold launch. Only an
    // activate arriving while this cycle already opened something (e.g. the
    // user closed every TAB but kept the shell) gets a fresh empty window.
    if (self->opened_anything) {
        SpdfWindow* win = spdf_window_new(ADW_APPLICATION(app));
        gtk_window_present(GTK_WINDOW(win));
        spdf_launch_mark("warm-window-present"); // resident warm path (<=100ms budget)
        return;
    }
    self->opened_anything = TRUE;
    restore_session_or_open_empty(self);
}

// Resident warmup (see the resident-start branch below): realize a throwaway
// shell window (never mapped) and push one text render node through its GSK
// renderer, forcing the process-global first-frame work — font map, glyph
// rasterization + atlas upload, CSS, icon theme, shader compilation — to
// happen at login instead of on the user's first open.
static gboolean resident_warmup_teardown(gpointer win) {
    gtk_window_destroy(GTK_WINDOW(win));
    spdf_launch_mark("resident-warmup-done");
    return G_SOURCE_REMOVE;
}

static void resident_warmup_mapped(GtkWidget* warm, gpointer user_data) {
    (void)user_data;
    // Destroy from an idle, after the frame that mapping produced — that
    // frame is exactly the warmup payload.
    g_idle_add_full(G_PRIORITY_LOW, resident_warmup_teardown, warm, NULL);
}

static gboolean resident_warmup_idle(gpointer user_data) {
    SpdfApp* self = SPDF_APP(user_data);
    GtkWidget* warm;
    GskRenderer* renderer;

    // A real open raced us and already paid the bill.
    if (gtk_application_get_windows(GTK_APPLICATION(self))) return G_SOURCE_REMOVE;

    warm = GTK_WIDGET(spdf_window_new(ADW_APPLICATION(self)));
    g_object_set_data(G_OBJECT(warm), "spdf-warmup", GINT_TO_POINTER(1));
    (void)renderer;
    // Realize alone rasterizes nothing (measured: the first real present
    // still blocked ~220 ms). The full bill is only paid by an actual first
    // frame of a real widget tree, so present the throwaway window fully
    // transparent and tear it down right after it maps. This happens only on
    // the --resident login start, before any user-visible window exists.
    gtk_widget_set_opacity(warm, 0.0);
    g_signal_connect(warm, "map", G_CALLBACK(resident_warmup_mapped), self);
    gtk_window_present(GTK_WINDOW(warm));
    return G_SOURCE_REMOVE;
}

static int spdf_app_command_line(GApplication* app, GApplicationCommandLine* cmdline) {
    SpdfApp* self = SPDF_APP(app);
    int argc = 0;
    char** argv = g_application_command_line_get_arguments(cmdline, &argc);
    SpdfWindow* win = NULL;
    gboolean resident_flag = FALSE;

    spdf_launch_mark("command-line");
    for (int i = 1; i < argc; ++i) {
        GFile* file;
        char* path;

        if (!argv[i] || !argv[i][0]) continue;
        // --resident (Wave D, login autostart): start held with no window.
        if (strcmp(argv[i], "--resident") == 0) {
            resident_flag = TRUE;
            continue;
        }
        if (argv[i][0] == '-') continue;
        // Resolve against the invoker's cwd — this runs in the primary
        // instance even when a second process forwarded the arguments.
        file = g_application_command_line_create_file_for_arg(cmdline, argv[i]);
        path = g_file_get_path(file);
        if (path && *path) {
            if (!win) {
                win = ensure_window_for_documents(self);
                spdf_launch_mark("present-begin");
                gtk_window_present(GTK_WINDOW(win));
                spdf_launch_mark("first-window-present");
            }
            spdf_window_open_path(win, path, 0, TRUE);
        }
        g_free(path);
        g_object_unref(file);
    }
    g_strfreev(argv);

    if (win) {
        // Launched with documents: skip session restore (GTK3 behavior).
        self->opened_anything = TRUE;
    } else if (resident_flag) {
        // Fast path (spec: skip session restore, skip everything but gtk
        // init): no activate, no window. With the setting on, startup
        // already took the hold and the process idles until the next open
        // forwards here over D-Bus. With it off (stale autostart entry)
        // there is no hold: remove the entry now and fall through to a
        // natural exit — use count 0, no window.
        spdf_launch_mark("resident-start");
        if (!spdf_state_settings(spdf_app_get_state(self))->instant_launch_resident) {
            spdf_resident_sync_autostart(FALSE);
        } else {
            // Warm the process-global first-frame costs (fontconfig/Pango
            // glyph rasterization, CSS, icon theme, GSK shader + atlas
            // uploads) at login, without mapping anything: measured on the
            // dev machine, the FIRST gtk_window_present of a process blocks
            // ~450 ms while the second takes ~1 ms. Realizing a throwaway
            // shell window off-screen pays that bill so the first real open
            // presents instantly. Deferred to an idle: keeps resident-start
            // itself cheap and off the login critical path.
            g_idle_add_full(G_PRIORITY_LOW, resident_warmup_idle, g_object_ref(self), g_object_unref);
        }
    } else {
        g_application_activate(app);
    }
    return 0;
}

static void spdf_app_shutdown(GApplication* app) {
    SpdfApp* self = SPDF_APP(app);

    if (self->state) spdf_state_flush(self->state);
    if (self->sigterm_id) {
        g_source_remove(self->sigterm_id);
        self->sigterm_id = 0;
    }
    if (self->sigint_id) {
        g_source_remove(self->sigint_id);
        self->sigint_id = 0;
    }
    G_APPLICATION_CLASS(spdf_app_parent_class)->shutdown(app);
}

static void spdf_app_finalize(GObject* object) {
    SpdfApp* self = SPDF_APP(object);

    g_clear_pointer(&self->state, spdf_state_free);
    G_OBJECT_CLASS(spdf_app_parent_class)->finalize(object);
}

static void spdf_app_init(SpdfApp* self) {
    (void)self;
}

static void spdf_app_class_init(SpdfAppClass* klass) {
    GObjectClass* object_class = G_OBJECT_CLASS(klass);
    GApplicationClass* app_class = G_APPLICATION_CLASS(klass);

    object_class->finalize = spdf_app_finalize;
    app_class->startup = spdf_app_startup;
    app_class->activate = spdf_app_activate;
    app_class->command_line = spdf_app_command_line;
    app_class->shutdown = spdf_app_shutdown;
}

SpdfApp* spdf_app_new(void) {
    return g_object_new(SPDF_TYPE_APP, "application-id", SPDF_APP_ID, "flags", G_APPLICATION_HANDLES_COMMAND_LINE,
                        NULL);
}
