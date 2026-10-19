// spdf_window.c — AdwApplicationWindow shell: AdwTabBar/AdwTabView with
// native drag reorder, continuous-drag detach/reattach (::create-window) and
// middle-click close; AdwTabOverview for overflow; GNOME-native header bar
// mirroring the Mac layout; presentation mode with idle inhibition; the
// per-window GAction set (names registered in spdf_shortcuts.c).

#include <stdlib.h>
#include <string.h>

#include "spdf_annot.h"
#include "spdf_app.h"
#include "spdf_default_reader.h"
#include "spdf_minimap.h"
#include "spdf_ocr.h"
#include "spdf_palette.h"
#include "spdf_print.h"
#include "spdf_props.h"
#include "spdf_search.h"
#include "spdf_sidebar.h"
#include "spdf_translate.h"
#include "spdf_updater.h"
#include "spdf_watcher.h"
#include "spdf_window.h"
#include "spdf_window_interactions.h"

#define SPDF_DEFAULT_WINDOW_WIDTH 960
#define SPDF_DEFAULT_WINDOW_HEIGHT 680
#define SPDF_MIN_WINDOW_WIDTH 560
#define SPDF_MIN_WINDOW_HEIGHT 380
#define SPDF_ZOOM_STEP 1.1

struct _SpdfWindow {
    AdwApplicationWindow parent_instance;

    AdwToolbarView* toolbar_view;
    AdwTabView* tab_view;
    AdwTabBar* tab_bar;
    AdwTabOverview* tab_overview;
    AdwToastOverlay* toast_overlay; // Wave C notifications: watcher reloads, OCR/translate completion
    GtkEntry* page_entry;
    GtkLabel* page_total_label;
    GtkButton* zoom_button;
    GtkMenuButton* fit_button; // Mac fit-mode popup; label tracks the current fit
    GtkToggleButton* search_toggle;
    GtkMenuButton* menu_button; // model attached from the deferred-menus idle
    GMenu* recent_menu;         // NULL until the deferred-menus idle built it
    AdwTabPage* context_page;   // page targeted by the tab context menu
    char* session_id;           // session.json window id; NULL until captured/restored
    SpdfWindowTabHistory tab_history;

    gboolean presentation;
    guint inhibit_cookie;
    guint menus_idle_id;
    guint recents_idle_id;
    guint close_if_empty_idle_id;
};

G_DEFINE_FINAL_TYPE(SpdfWindow, spdf_window, ADW_TYPE_APPLICATION_WINDOW)

static void update_page_controls(SpdfWindow* win);

static SpdfApp* window_app(SpdfWindow* win) {
    GtkApplication* app = gtk_window_get_application(GTK_WINDOW(win));
    return app && SPDF_IS_APP(app) ? SPDF_APP(app) : NULL;
}

static SpdfTab* tab_for_page(AdwTabPage* page) {
    return page ? (SpdfTab*)g_object_get_data(G_OBJECT(page), "spdf-tab") : NULL;
}

static gboolean window_contains_page(gpointer page, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    return win->tab_view && page && adw_tab_view_get_page_position(win->tab_view, ADW_TAB_PAGE(page)) >= 0;
}

AdwTabView* spdf_window_get_tab_view(SpdfWindow* win) {
    g_return_val_if_fail(SPDF_IS_WINDOW(win), NULL);
    return win->tab_view;
}

SpdfTab* spdf_window_current_tab(SpdfWindow* win) {
    g_return_val_if_fail(SPDF_IS_WINDOW(win), NULL);
    if (!win->tab_view) return NULL;
    return tab_for_page(adw_tab_view_get_selected_page(win->tab_view));
}

int spdf_window_tab_count(SpdfWindow* win) {
    g_return_val_if_fail(SPDF_IS_WINDOW(win), 0);
    return win->tab_view ? adw_tab_view_get_n_pages(win->tab_view) : 0;
}

SpdfTab* spdf_window_tab_at(SpdfWindow* win, int index) {
    g_return_val_if_fail(SPDF_IS_WINDOW(win), NULL);
    if (!win->tab_view || index < 0 || index >= adw_tab_view_get_n_pages(win->tab_view)) return NULL;
    return tab_for_page(adw_tab_view_get_nth_page(win->tab_view, index));
}

gboolean spdf_window_get_presentation(SpdfWindow* win) {
    g_return_val_if_fail(SPDF_IS_WINDOW(win), FALSE);
    return win->presentation;
}

const char* spdf_window_get_session_id(SpdfWindow* win) {
    g_return_val_if_fail(SPDF_IS_WINDOW(win), NULL);
    return win->session_id;
}

void spdf_window_set_session_id(SpdfWindow* win, const char* id) {
    g_return_if_fail(SPDF_IS_WINDOW(win));
    if (win->session_id == id) return;
    g_free(win->session_id);
    win->session_id = g_strdup(id);
}

// --- watcher (Wave C): subtle notification lane ------------------------------
void spdf_window_show_toast(SpdfWindow* win, const char* text) {
    AdwToast* toast;

    g_return_if_fail(SPDF_IS_WINDOW(win));
    if (!win->toast_overlay || !text || !*text) return; // disposing / nothing to say
    toast = adw_toast_new(text);
    adw_toast_set_timeout(toast, 3);
    adw_toast_overlay_add_toast(win->toast_overlay, toast); // sinks the toast
}

// ---------------------------------------------------------------------------
// Header-bar state

void spdf_window_update_title(SpdfWindow* win) {
    SpdfTab* tab = spdf_window_current_tab(win);

    if (tab && tab->page) {
        const char* name = adw_tab_page_get_title(tab->page);
        char* title = g_strdup_printf("%s — %s", name && *name ? name : "Untitled", SPDF_APP_DISPLAY_NAME);
        gtk_window_set_title(GTK_WINDOW(win), title);
        g_free(title);
    } else {
        gtk_window_set_title(GTK_WINDOW(win), SPDF_APP_DISPLAY_NAME);
    }
}

static void update_page_controls(SpdfWindow* win) {
    SpdfTab* tab = spdf_window_current_tab(win);
    int total = tab && tab->doc ? spdf_page_count(tab->doc) : 0;
    int page = 0;
    char text[32];

    if (!win->page_entry || !win->page_total_label || !win->zoom_button) return; // disposing

    if (tab && tab->view) page = spdf_doc_view_current_page(tab->view);
    if (total > 0) {
        g_snprintf(text, sizeof(text), "%d", page + 1);
        gtk_editable_set_text(GTK_EDITABLE(win->page_entry), text);
        g_snprintf(text, sizeof(text), "/ %d", total);
        gtk_label_set_text(win->page_total_label, text);
    } else {
        gtk_editable_set_text(GTK_EDITABLE(win->page_entry), "");
        gtk_label_set_text(win->page_total_label, "/ –");
    }
    gtk_widget_set_sensitive(GTK_WIDGET(win->page_entry), total > 0);

    if (tab && tab->view) {
        g_snprintf(text, sizeof(text), "%.0f%%", spdf_doc_view_get_zoom(tab->view) * 100.0);
        gtk_button_set_label(win->zoom_button, text);
    } else {
        gtk_button_set_label(win->zoom_button, "100%");
    }

    // Fit-mode dropdown label (Mac _fitModePopup selection).
    if (win->fit_button) {
        const char* fit_label = "Zoom";
        if (tab && tab->view) {
            switch (spdf_doc_view_get_fit(tab->view)) {
                case SPDF_FIT_PAGE:
                    fit_label = "Fit Page";
                    break;
                case SPDF_FIT_WIDTH:
                    fit_label = "Fit Width";
                    break;
                case SPDF_FIT_HEIGHT:
                    fit_label = "Fit Height";
                    break;
                case SPDF_FIT_CUSTOM:
                default:
                    fit_label = "Zoom";
                    break;
            }
        }
        gtk_menu_button_set_label(win->fit_button, fit_label);
    }
}

// SpdfDocView "page-changed" (int) / "zoom-changed" (double) handlers; both
// just re-read the view state, so the extra parameter is ignored.
static void docview_page_changed(SpdfDocView* view, int page, gpointer user_data) {
    (void)view;
    (void)page;
    update_page_controls(SPDF_WINDOW(user_data));
}

static void docview_zoom_changed(SpdfDocView* view, double zoom, gpointer user_data) {
    (void)view;
    (void)zoom;
    update_page_controls(SPDF_WINDOW(user_data));
}

static void page_entry_activated(GtkEntry* entry, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    long value = strtol(gtk_editable_get_text(GTK_EDITABLE(entry)), NULL, 10);

    if (tab && tab->view && value >= 1) {
        spdf_doc_view_goto_page(tab->view, (int)value - 1);
        gtk_widget_grab_focus(GTK_WIDGET(tab->view));
    }
    update_page_controls(win);
}

// ---------------------------------------------------------------------------
// Recents submenu (hamburger menu)

static char* menu_label_escape_underscores(const char* text) {
    GString* out = g_string_new("");
    for (const char* p = text ? text : ""; *p; ++p) {
        if (*p == '_') g_string_append_c(out, '_');
        g_string_append_c(out, *p);
    }
    return g_string_free(out, FALSE);
}

void spdf_window_refresh_recents(SpdfWindow* win) {
    SpdfApp* app = window_app(win);
    SpdfState* state;
    int count;

    g_return_if_fail(SPDF_IS_WINDOW(win));
    // Menus build in the deferred-menus idle (Wave D launch trim); a recents
    // change landing before that (document opened straight from the command
    // line) is picked up when the menu is built.
    if (!app || !win->recent_menu) return;
    state = spdf_app_get_state(app);
    count = spdf_state_recent_count(state);
    g_menu_remove_all(win->recent_menu);
    if (count <= 0) {
        // No action name: rendered insensitive, like the GTK3 placeholder.
        g_menu_append(win->recent_menu, "No Recent Documents", NULL);
        return;
    }
    for (int i = 0; i < count && i < SPDF_RECENT_MENU_LIMIT; ++i) {
        const char* path = spdf_state_recent_path(state, i);
        char* base;
        char* name;
        char* label;
        GMenuItem* item;

        if (!path || !*path) continue;
        base = g_path_get_basename(path);
        name = menu_label_escape_underscores(base);
        label = g_strdup_printf("%d) %s", i + 1, name);
        item = g_menu_item_new(label, NULL);
        g_menu_item_set_action_and_target(item, "app.open-recent", "s", path);
        g_menu_append_item(win->recent_menu, item);
        g_object_unref(item);
        g_free(label);
        g_free(name);
        g_free(base);
    }
}

static gboolean refresh_recents_idle(gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    win->recents_idle_id = 0;
    spdf_window_refresh_recents(win);
    return G_SOURCE_REMOVE;
}

// ---------------------------------------------------------------------------
// Opening documents

void spdf_window_accept_opened(SpdfWindow* win, SpdfTab* tab, const char* canonical, int page_index,
                               gboolean remember_recent) {
    SpdfApp* app;

    if (!tab) return;
    if (page_index > 0 && tab->view) spdf_doc_view_goto_page(tab->view, page_index);
    adw_tab_view_set_selected_page(win->tab_view, tab->page);
    app = window_app(win);
    if (remember_recent && app) spdf_app_remember_recent(app, canonical);
    spdf_window_update_title(win);
    update_page_controls(win);
    // First document open of the run: schedule the default-reader prompt
    // check (Wave D; runs in a LOW idle, never on the open path itself).
    spdf_default_reader_note_document_opened(win);
}

static void open_dialog_finished(GObject* source, GAsyncResult* result, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    GError* error = NULL;
    GListModel* files = gtk_file_dialog_open_multiple_finish(GTK_FILE_DIALOG(source), result, &error);

    if (files) {
        guint n = g_list_model_get_n_items(files);
        for (guint i = 0; i < n; ++i) {
            GFile* file = g_list_model_get_item(files, i);
            char* path = g_file_get_path(file);
            if (path && *path) spdf_window_open_path(win, path, 0, TRUE);
            g_free(path);
            g_object_unref(file);
        }
        g_object_unref(files);
    }
    g_clear_error(&error); // dismissal is not an error worth reporting
    g_object_unref(win);
}

static void run_open_dialog(SpdfWindow* win) {
    GtkFileDialog* dialog = gtk_file_dialog_new();
    GtkFileFilter* pdf = gtk_file_filter_new();
    GtkFileFilter* all = gtk_file_filter_new();
    GListStore* filters = g_list_store_new(GTK_TYPE_FILE_FILTER);

    gtk_file_dialog_set_title(dialog, "Open Document");
    gtk_file_filter_set_name(pdf, "PDF Documents");
    gtk_file_filter_add_mime_type(pdf, "application/pdf");
    gtk_file_filter_add_suffix(pdf, "pdf");
    gtk_file_filter_set_name(all, "All Files");
    gtk_file_filter_add_pattern(all, "*");
    g_list_store_append(filters, pdf);
    g_list_store_append(filters, all);
    gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(filters));
    gtk_file_dialog_set_default_filter(dialog, pdf);
    gtk_file_dialog_open_multiple(dialog, GTK_WINDOW(win), NULL, open_dialog_finished, g_object_ref(win));
    g_object_unref(filters);
    g_object_unref(pdf);
    g_object_unref(all);
    g_object_unref(dialog);
}

// ---------------------------------------------------------------------------
// Presentation mode

void spdf_window_set_presentation(SpdfWindow* win, gboolean enable) {
    GtkApplication* app;
    GAction* action;

    g_return_if_fail(SPDF_IS_WINDOW(win));
    if (win->presentation == enable) return;
    win->presentation = enable;
    app = gtk_window_get_application(GTK_WINDOW(win));

    // All chrome lives in the toolbar view's top bars, so one switch hides it.
    adw_toolbar_view_set_reveal_top_bars(win->toolbar_view, !enable);
    if (enable) {
        gtk_window_fullscreen(GTK_WINDOW(win));
        if (app && SPDF_IS_APP(app) &&
            spdf_state_settings(spdf_app_get_state(SPDF_APP(app)))->prevent_sleep_in_presentation) {
            win->inhibit_cookie =
                gtk_application_inhibit(app, GTK_WINDOW(win), GTK_APPLICATION_INHIBIT_IDLE, "Presenting a document");
        }
    } else {
        gtk_window_unfullscreen(GTK_WINDOW(win));
        if (win->inhibit_cookie && app) gtk_application_uninhibit(app, win->inhibit_cookie);
        win->inhibit_cookie = 0;
    }
    action = g_action_map_lookup_action(G_ACTION_MAP(win), "presentation");
    if (action) g_simple_action_set_state(G_SIMPLE_ACTION(action), g_variant_new_boolean(enable));
}

static gboolean window_key_pressed(GtkEventControllerKey* controller, guint keyval, guint keycode,
                                   GdkModifierType state, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    (void)controller;
    (void)keycode;
    (void)state;

    if (keyval == GDK_KEY_Escape) {
        if (win->presentation) {
            spdf_window_set_presentation(win, FALSE);
            return GDK_EVENT_STOP;
        }
        // Escape in the canvas clears the active search + hides the bar
        // (spdf_search.c; Mac documentEscapeKeyDown semantics).
        if (spdf_search_dismiss(win)) return GDK_EVENT_STOP;
    }
    return GDK_EVENT_PROPAGATE;
}

// ---------------------------------------------------------------------------
// Tab view signals

static AdwTabView* tab_view_create_window(AdwTabView* view, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    GtkApplication* app = gtk_window_get_application(GTK_WINDOW(win));
    SpdfWindow* created;
    int width = 0;
    int height = 0;

    (void)view;
    if (!app) return NULL;
    created = spdf_window_new(ADW_APPLICATION(app));
    gtk_window_get_default_size(GTK_WINDOW(win), &width, &height);
    if (width > 0 && height > 0) gtk_window_set_default_size(GTK_WINDOW(created), width, height);
    gtk_window_present(GTK_WINDOW(created));
    return created->tab_view;
}

static gboolean tab_view_close_page(AdwTabView* view, AdwTabPage* page, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = tab_for_page(page);
    SpdfApp* app = window_app(win);

    // Reopen-last-closed ring; shadow copies are transient and not recorded.
    if (app && tab && tab->path && *tab->path && !tab->read_only_shadow) spdf_app_remember_closed(app, tab->path);
    // --- watcher (Wave C): a DELIBERATE close deletes an unshared shadow
    // copy (window teardown/quit keeps it so session restore reopens it).
    if (tab) spdf_watcher_tab_deliberate_close(tab);
    // Ctrl+W and the native close affordances share this signal path. Remove
    // the page before AdwTabView selects its normal adjacent close fallback;
    // this intentionally differs from drag-detach restoration below.
    spdf_window_tab_history_remove(&win->tab_history, page, FALSE, window_contains_page, win);
    g_object_set_data(G_OBJECT(page), "spdf-tab", NULL);
    adw_tab_view_close_page_finish(view, page, TRUE); // no confirmation needed
    if (tab) spdf_tab_close(tab);
    return GDK_EVENT_STOP;
}

static void tab_view_page_attached(AdwTabView* view, AdwTabPage* page, gint position, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = tab_for_page(page);

    (void)view;
    (void)position;
    if (tab) {
        tab->win = win; // pages migrate between windows on drag reattach
        if (tab->view) {
            g_signal_connect_object(tab->view, "page-changed", G_CALLBACK(docview_page_changed), win, 0);
            g_signal_connect_object(tab->view, "zoom-changed", G_CALLBACK(docview_zoom_changed), win, 0);
        }
    }
    spdf_window_update_title(win);
    update_page_controls(win);
}

static gboolean close_if_empty_idle(gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    GtkApplication* app = gtk_window_get_application(GTK_WINDOW(win));

    win->close_if_empty_idle_id = 0;
    if (app && win->tab_view && adw_tab_view_get_n_pages(win->tab_view) == 0) {
        int shell_windows = 0;
        for (GList* it = gtk_application_get_windows(app); it; it = it->next)
            if (SPDF_IS_WINDOW(it->data)) shell_windows++;
        // A window emptied by dragging its last tab away closes itself; the
        // last remaining window stays as an empty shell instead.
        if (shell_windows > 1) gtk_window_destroy(GTK_WINDOW(win));
    }
    return G_SOURCE_REMOVE;
}

static void tab_view_page_detached(AdwTabView* view, AdwTabPage* page, gint position, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = tab_for_page(page);

    (void)position;
    if (tab && tab->view) g_signal_handlers_disconnect_by_data(tab->view, win);
    {
        AdwTabPage* restore = spdf_window_tab_history_remove(&win->tab_history, page, TRUE, window_contains_page, win);
        if (restore && adw_tab_view_get_selected_page(view) != restore) adw_tab_view_set_selected_page(view, restore);
    }
    spdf_window_update_title(win);
    update_page_controls(win);
    if (win->tab_view && adw_tab_view_get_n_pages(view) == 0 && !win->close_if_empty_idle_id)
        win->close_if_empty_idle_id =
            g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, close_if_empty_idle, g_object_ref(win), g_object_unref);
}

void spdf_window_tab_linked(SpdfWindow* win, AdwTabPage* page) {
    g_return_if_fail(SPDF_IS_WINDOW(win));
    if (!win->tab_view || !page) return;
    // Re-run the attach handler now that tab_for_page(page) resolves; the
    // NULL-tab run during adw_tab_view_append connected nothing, so this
    // cannot double-connect.
    tab_view_page_attached(win->tab_view, page, 0, win);
    spdf_minimap_window_sync(win);
}

static void tab_view_selected_page_changed(GObject* object, GParamSpec* pspec, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    AdwTabPage* selected = adw_tab_view_get_selected_page(ADW_TAB_VIEW(object));
    AdwTabPage* restore =
        spdf_window_tab_history_selection_changed(&win->tab_history, selected, window_contains_page, win);
    (void)pspec;
    if (restore && restore != selected) {
        adw_tab_view_set_selected_page(win->tab_view, restore);
        return;
    }
    spdf_window_update_title(win);
    update_page_controls(win);
    spdf_watcher_retry_pending(tab_for_page(selected));
}
static void tab_view_setup_menu(AdwTabView* view, AdwTabPage* page, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = tab_for_page(page);
    GAction* copy_document = g_action_map_lookup_action(G_ACTION_MAP(win), "tab-copy-document");
    (void)view;
    win->context_page = page; // NULL when the menu is dismissed
    if (copy_document)
        g_simple_action_set_enabled(G_SIMPLE_ACTION(copy_document),
                                    tab && tab->path && g_file_test(tab->path, G_FILE_TEST_IS_REGULAR));
}

static SpdfTab* context_menu_tab(SpdfWindow* win) {
    SpdfTab* tab = tab_for_page(win->context_page);
    return tab ? tab : spdf_window_current_tab(win);
}

// ---------------------------------------------------------------------------
// Wave C: completion toasts (OCR / translation modules).

void spdf_window_add_toast(SpdfWindow* win, const char* title) {
    g_return_if_fail(SPDF_IS_WINDOW(win));
    if (!win->toast_overlay || !title || !*title) return;
    adw_toast_overlay_add_toast(win->toast_overlay, adw_toast_new(title));
}

// ---------------------------------------------------------------------------
// Simple helpers used by actions

static void copy_text_to_clipboard(SpdfWindow* win, const char* text) {
    if (!text) return;
    gdk_clipboard_set_text(gtk_widget_get_clipboard(GTK_WIDGET(win)), text);
}

static void copy_file_to_clipboard(SpdfWindow* win, const char* path) {
    GFile* file;
    GdkFileList* file_list;
    GdkContentProvider* providers[2];
    GdkContentProvider* provider;

    if (!path || !*path || !g_file_test(path, G_FILE_TEST_IS_REGULAR)) return;
    file = g_file_new_for_path(path);
    file_list = gdk_file_list_new_from_array(&file, 1);
    // GdkFileList provides text/uri-list and the desktop portal file-transfer
    // representation; text/plain remains useful for terminal/text targets.
    providers[0] = gdk_content_provider_new_typed(GDK_TYPE_FILE_LIST, file_list);
    providers[1] = gdk_content_provider_new_typed(G_TYPE_STRING, path);
    provider = gdk_content_provider_new_union(providers, G_N_ELEMENTS(providers));
    gdk_clipboard_set_content(gtk_widget_get_clipboard(GTK_WIDGET(win)), provider);
    g_object_unref(provider);
    g_boxed_free(GDK_TYPE_FILE_LIST, file_list);
    g_object_unref(file);
}

static void show_path_in_folder(SpdfWindow* win, const char* path) {
    GFile* file;
    GtkFileLauncher* launcher;

    if (!path || !*path) return;
    file = g_file_new_for_path(path);
    launcher = gtk_file_launcher_new(file);
    gtk_file_launcher_open_containing_folder(launcher, GTK_WINDOW(win), NULL, NULL, NULL);
    g_object_unref(launcher);
    g_object_unref(file);
}

// ---------------------------------------------------------------------------
// Window actions. Every name here is registered (with its accels and cheat
// sheet entry) in the table in spdf_shortcuts.c.

static void action_open(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    (void)action;
    (void)parameter;
    run_open_dialog(SPDF_WINDOW(user_data));
}

static void action_close_tab(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    AdwTabPage* page = adw_tab_view_get_selected_page(win->tab_view);
    (void)action;
    (void)parameter;
    if (page) adw_tab_view_close_page(win->tab_view, page);
}

static void action_reopen_closed(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfApp* app = window_app(win);
    char* path;

    (void)action;
    (void)parameter;
    if (!app) return;
    path = spdf_app_pop_closed(app);
    if (!path) return;
    spdf_window_open_path(win, path, 0, TRUE);
    g_free(path);
}

static void action_next_tab(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    (void)action;
    (void)parameter;
    if (!adw_tab_view_select_next_page(win->tab_view) && adw_tab_view_get_n_pages(win->tab_view) > 1)
        adw_tab_view_set_selected_page(win->tab_view, adw_tab_view_get_nth_page(win->tab_view, 0));
}

static void action_prev_tab(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    int count = adw_tab_view_get_n_pages(win->tab_view);
    (void)action;
    (void)parameter;
    if (!adw_tab_view_select_previous_page(win->tab_view) && count > 1)
        adw_tab_view_set_selected_page(win->tab_view, adw_tab_view_get_nth_page(win->tab_view, count - 1));
}

static void action_tab_overview(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    (void)action;
    (void)parameter;
    adw_tab_overview_set_open(win->tab_overview, !adw_tab_overview_get_open(win->tab_overview));
}

static void action_goto_page(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    (void)action;
    (void)parameter;
    gtk_widget_grab_focus(GTK_WIDGET(win->page_entry));
    gtk_editable_select_region(GTK_EDITABLE(win->page_entry), 0, -1);
}

static void action_shortcuts(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    (void)action;
    (void)parameter;
    spdf_shortcuts_present_window(GTK_WINDOW(user_data));
}

// --- auto-updater (spdf_updater.c) ------------------------------------------
static void action_check_updates(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfApp* app = window_app(win);
    (void)action;
    (void)parameter;
    if (app) spdf_updater_check_interactive(app, GTK_WINDOW(win));
}

static void action_search(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    (void)action;
    (void)parameter;
    // Ctrl+F: selection-to-search or reveal + focus the bar (spdf_search.c;
    // the header toggle tracks the bar through a property binding).
    spdf_search_focus(SPDF_WINDOW(user_data));
}

static void action_find_next(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    (void)action;
    (void)parameter;
    spdf_search_find_next(SPDF_WINDOW(user_data));
}

static void action_find_prev(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    (void)action;
    (void)parameter;
    spdf_search_find_prev(SPDF_WINDOW(user_data));
}

static void action_zoom_in(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    (void)action;
    (void)parameter;
    if (tab && tab->view)
        spdf_doc_view_set_zoom(tab->view, spdf_doc_view_get_zoom(tab->view) * SPDF_ZOOM_STEP, FALSE, 0, 0);
    update_page_controls(win);
}

static void action_zoom_out(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    (void)action;
    (void)parameter;
    if (tab && tab->view)
        spdf_doc_view_set_zoom(tab->view, spdf_doc_view_get_zoom(tab->view) / SPDF_ZOOM_STEP, FALSE, 0, 0);
    update_page_controls(win);
}

static void action_zoom_actual(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    (void)action;
    (void)parameter;
    if (tab && tab->view) spdf_doc_view_set_zoom(tab->view, 1.0, FALSE, 0, 0);
    update_page_controls(win);
}

static void action_fit_page(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    (void)action;
    (void)parameter;
    if (tab && tab->view) spdf_doc_view_set_fit(tab->view, SPDF_FIT_PAGE);
    update_page_controls(win);
}

static void action_fit_width(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    (void)action;
    (void)parameter;
    if (tab && tab->view) spdf_doc_view_set_fit(tab->view, SPDF_FIT_WIDTH);
    update_page_controls(win);
}

static void action_fit_height(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    (void)action;
    (void)parameter;
    if (tab && tab->view) spdf_doc_view_set_fit(tab->view, SPDF_FIT_HEIGHT);
    update_page_controls(win);
}

// Mac toolbar "<" / ">" page-step buttons.
static void action_prev_page(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    (void)action;
    (void)parameter;
    if (tab && tab->view) spdf_doc_view_goto_page(tab->view, spdf_doc_view_current_page(tab->view) - 1);
    update_page_controls(win);
}

static void action_next_page(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    (void)action;
    (void)parameter;
    if (tab && tab->view) spdf_doc_view_goto_page(tab->view, spdf_doc_view_current_page(tab->view) + 1);
    update_page_controls(win);
}

static void action_copy(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    char* text;
    (void)action;
    (void)parameter;
    /* Keyboard copy obeys the same document permission as the context menu. */
    if (!tab || !tab->doc || !spdf_has_permission(tab->doc, 'c')) return;
    text = tab->view ? spdf_doc_view_copy_selection(tab->view) : NULL;
    if (text) {
        copy_text_to_clipboard(win, text);
        g_free(text);
    }
}

static void action_copy_path(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    (void)action;
    (void)parameter;
    if (tab && tab->path) copy_text_to_clipboard(win, tab->path);
}

static void action_show_in_folder(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    (void)action;
    (void)parameter;
    if (tab) show_path_in_folder(win, tab->path);
}

static void action_open_in_browser(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    char* uri;
    GtkUriLauncher* launcher;

    (void)action;
    (void)parameter;
    if (!tab || !tab->path) return;
    uri = g_filename_to_uri(tab->path, NULL, NULL);
    if (!uri) return;
    launcher = gtk_uri_launcher_new(uri);
    gtk_uri_launcher_launch(launcher, GTK_WINDOW(win), NULL, NULL, NULL);
    g_object_unref(launcher);
    g_free(uri);
}

static void action_tab_show_in_folder(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = context_menu_tab(win);
    (void)action;
    (void)parameter;
    if (tab) show_path_in_folder(win, tab->path);
}

static void action_tab_copy_path(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = context_menu_tab(win);
    (void)action;
    (void)parameter;
    if (tab && tab->path) copy_text_to_clipboard(win, tab->path);
}

static void action_tab_copy_document(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = context_menu_tab(win);
    (void)action;
    (void)parameter;
    if (tab) copy_file_to_clipboard(win, tab->path);
}

static void action_tab_copy_title(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = context_menu_tab(win);
    char* title;

    (void)action;
    (void)parameter;
    if (!tab) return;
    title = spdf_tab_display_name(tab);
    copy_text_to_clipboard(win, title);
    g_free(title);
}

// Palette module bodies (spdf_palette.c).
static void action_palette(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    (void)action;
    (void)parameter;
    spdf_palette_open(SPDF_WINDOW(user_data));
}

static void action_favorite_page(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    (void)action;
    (void)parameter;
    spdf_palette_toggle_favorite_page(SPDF_WINDOW(user_data));
}

static void action_favorite_document(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    (void)action;
    (void)parameter;
    spdf_palette_toggle_favorite_document(SPDF_WINDOW(user_data));
}

static void presentation_change_state(GSimpleAction* action, GVariant* value, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    (void)action;
    spdf_window_set_presentation(win, g_variant_get_boolean(value));
}

// win.search-nearest — stateful toggle behind the hamburger menu item and the
// command palette for the searchJumpsToNearestResult setting (Mac "Search
// Jumps to Nearest Result" Settings menu item, ShenzhenPDFMac.mm @2501-2504,
// toggle @15768-15771). Takes effect on the next find: spdf_search.c reads
// the setting live on every query/step.
static void search_nearest_change_state(GSimpleAction* action, GVariant* value, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    GtkApplication* app = gtk_window_get_application(GTK_WINDOW(win));
    gboolean enabled = g_variant_get_boolean(value);
    SpdfState* state;

    g_simple_action_set_state(action, value);
    if (!app || !SPDF_IS_APP(app)) return;
    state = spdf_app_get_state(SPDF_APP(app));
    if (spdf_state_settings(state)->search_jumps_to_nearest_result == enabled) return;
    spdf_state_settings(state)->search_jumps_to_nearest_result = enabled;
    spdf_state_save_settings(state); // coalesced write
}

static const GActionEntry k_window_actions[] = {
    {"open", action_open, NULL, NULL, NULL, {0}},
    {"new-tab", action_open, NULL, NULL, NULL, {0}}, // new tab = pick a document, like the GTK3 "+" button
    {"close-tab", action_close_tab, NULL, NULL, NULL, {0}},
    {"reopen-closed", action_reopen_closed, NULL, NULL, NULL, {0}},
    {"next-tab", action_next_tab, NULL, NULL, NULL, {0}},
    {"prev-tab", action_prev_tab, NULL, NULL, NULL, {0}},
    {"tab-overview", action_tab_overview, NULL, NULL, NULL, {0}},
    {"goto-page", action_goto_page, NULL, NULL, NULL, {0}},
    {"shortcuts", action_shortcuts, NULL, NULL, NULL, {0}},
    {"search", action_search, NULL, NULL, NULL, {0}},
    {"zoom-in", action_zoom_in, NULL, NULL, NULL, {0}},
    {"zoom-out", action_zoom_out, NULL, NULL, NULL, {0}},
    {"zoom-actual", action_zoom_actual, NULL, NULL, NULL, {0}},
    {"fit-page", action_fit_page, NULL, NULL, NULL, {0}},
    {"fit-width", action_fit_width, NULL, NULL, NULL, {0}},
    {"fit-height", action_fit_height, NULL, NULL, NULL, {0}},
    {"prev-page", action_prev_page, NULL, NULL, NULL, {0}},
    {"next-page", action_next_page, NULL, NULL, NULL, {0}},
    {"copy", action_copy, NULL, NULL, NULL, {0}},
    {"check-updates", action_check_updates, NULL, NULL, NULL, {0}},
    {"copy-path", action_copy_path, NULL, NULL, NULL, {0}},
    {"show-in-folder", action_show_in_folder, NULL, NULL, NULL, {0}},
    {"open-in-browser", action_open_in_browser, NULL, NULL, NULL, {0}},
    {"tab-show-in-folder", action_tab_show_in_folder, NULL, NULL, NULL, {0}},
    {"tab-copy-document", action_tab_copy_document, NULL, NULL, NULL, {0}},
    {"tab-copy-path", action_tab_copy_path, NULL, NULL, NULL, {0}},
    {"tab-copy-title", action_tab_copy_title, NULL, NULL, NULL, {0}},
    // Stateful; activating with no parameter toggles and calls change-state.
    {"presentation", NULL, NULL, "false", presentation_change_state, {0}},
    // "sidebar" (stateful) moved to spdf_sidebar.c (Wave B), registered by
    // spdf_sidebar_new below.
    // Palette + favorites (spdf_palette.c).
    {"palette", action_palette, NULL, NULL, NULL, {0}},
    {"favorite-page", action_favorite_page, NULL, NULL, NULL, {0}},
    {"favorite-document", action_favorite_document, NULL, NULL, NULL, {0}},
    // Search (spdf_search.c).
    {"find-next", action_find_next, NULL, NULL, NULL, {0}},
    {"find-prev", action_find_prev, NULL, NULL, NULL, {0}},
    // rotate-cw / rotate-ccw / save-as moved to spdf_annot.c (Wave B);
    // properties to spdf_props.c (Wave B); print to spdf_print.c (Wave C);
    // ocr / translate to spdf_ocr.c / spdf_translate.c (Wave C). Each is
    // registered by its module's _install call below — no stubs remain.
};

// ---------------------------------------------------------------------------
// Menus

static GMenuModel* build_tab_context_menu(void) {
    GMenu* menu = g_menu_new();
    g_menu_append(menu, "Show in Folder", "win.tab-show-in-folder");
    g_menu_append(menu, "Copy Document", "win.tab-copy-document");
    g_menu_append(menu, "Copy Title", "win.tab-copy-title");
    g_menu_append(menu, "Copy Path", "win.tab-copy-path");
    return G_MENU_MODEL(menu);
}

static GMenuModel* build_primary_menu(SpdfWindow* win) {
    GMenu* menu = g_menu_new();
    GMenu* files = g_menu_new();
    GMenu* view = g_menu_new();
    GMenu* favorites = g_menu_new();
    GMenu* tools = g_menu_new();
    GMenu* help = g_menu_new();

    win->recent_menu = g_menu_new();
    g_menu_append(win->recent_menu, "No Recent Documents", NULL);

    g_menu_append(files, "_Open…", "win.open");
    g_menu_append_submenu(files, "Recently _Opened", G_MENU_MODEL(win->recent_menu));
    g_menu_append(files, "Reopen Last _Closed", "win.reopen-closed");
    g_menu_append_section(menu, NULL, G_MENU_MODEL(files));

    // View section (Mac View menu): fit modes plus the stateful side panel /
    // minimap / presentation toggles (check items via the stateful actions).
    {
        GMenu* fit = g_menu_new();
        g_menu_append(fit, "Fit _Page", "win.fit-page");
        g_menu_append(fit, "Fit _Width", "win.fit-width");
        g_menu_append(fit, "Fit _Height", "win.fit-height");
        g_menu_append(fit, "Actual Size", "win.zoom-actual");
        g_menu_append_submenu(view, "_Zoom", G_MENU_MODEL(fit));
        g_object_unref(fit);
    }
    g_menu_append(view, "Show Side Panel", "win.sidebar");
    g_menu_append(view, "Show Minimap", "win.minimap");
    g_menu_append(view, "Presentation Mode", "win.presentation");
    g_menu_append_section(menu, NULL, G_MENU_MODEL(view));

    g_menu_append(favorites, "Search Favorites…", "win.palette");
    g_menu_append(favorites, "Favorite Current Page", "win.favorite-page");
    g_menu_append(favorites, "Favorite Current Document", "win.favorite-document");
    g_menu_append_section(menu, NULL, G_MENU_MODEL(favorites));

    g_menu_append(tools, "OCR Document…", "win.ocr");
    g_menu_append(tools, "Translate…", "win.translate");
    g_menu_append(tools, "_Print…", "win.print");
    g_menu_append(tools, "Propert_ies…", "win.properties");
    g_menu_append(tools, "Save _As…", "win.save-as");
    g_menu_append(tools, "Show in Folder", "win.show-in-folder");
    g_menu_append_section(menu, NULL, G_MENU_MODEL(tools));

    // --- Wave D: default-reader registration (spdf_default_reader.c) and the
    // resident instant-launch toggle (stateful app action -> check item).
    g_menu_append(help, "Set as Default PDF Reader", "win.make-default");
    g_menu_append(help, "Instant Launch in Background", "app.instant-launch");
    // Stateful toggle -> check item, same pattern as instant-launch (Mac
    // Settings menu "Search Jumps to Nearest Result").
    g_menu_append(help, "Search Jumps to Nearest Result", "win.search-nearest");
    g_menu_append(help, "_Keyboard Shortcuts", "win.shortcuts");
    g_menu_append(help, "Check for _Updates…", "win.check-updates");
    g_menu_append(help, "_About Shenzhen PDF", "app.about");
    g_menu_append_section(menu, NULL, G_MENU_MODEL(help));

    g_object_unref(files);
    g_object_unref(view);
    g_object_unref(favorites);
    g_object_unref(tools);
    g_object_unref(help);
    return G_MENU_MODEL(menu);
}

// ---------------------------------------------------------------------------
// Construction

static gboolean window_close_request(GtkWindow* window, gpointer user_data) {
    GtkApplication* app = gtk_window_get_application(window);

    (void)user_data;
    if (!app || !SPDF_IS_APP(app)) return GDK_EVENT_PROPAGATE;
    // Alt+F4 / the titlebar close button quits the whole APP, not just this
    // window (user request): the full multi-window session is captured and
    // flushed first, every other window is destroyed, and this one closes by
    // propagating. The next launch/activate restores everything as it was.
    spdf_app_close_all_windows(SPDF_APP(app), SPDF_WINDOW(window));
    return GDK_EVENT_PROPAGATE;
}

static gboolean header_target_is_control(GtkWidget* header, GtkWidget* target) {
    for (GtkWidget* widget = target; widget && widget != header; widget = gtk_widget_get_parent(widget))
        if (GTK_IS_ACTIONABLE(widget) || GTK_IS_EDITABLE(widget)) return TRUE;
    return FALSE;
}

static void header_pressed(GtkGestureClick* gesture, int n_press, double x, double y, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    GtkWidget* header = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    GtkWidget* target = gtk_widget_pick(header, x, y, GTK_PICK_DEFAULT);
    SpdfHeaderHitKind hit = header_target_is_control(header, target) ? SPDF_HEADER_HIT_CONTROL : SPDF_HEADER_HIT_EMPTY;
    gboolean fullscreen = win->presentation || gtk_window_is_fullscreen(GTK_WINDOW(win));

    if (!spdf_window_header_should_toggle_maximize((guint)n_press, GDK_BUTTON_PRIMARY, hit, fullscreen)) return;
    gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
    if (gtk_window_is_maximized(GTK_WINDOW(win)))
        gtk_window_unmaximize(GTK_WINDOW(win));
    else
        gtk_window_maximize(GTK_WINDOW(win));
}

static GtkWidget* header_bar_new(SpdfWindow* self) {
    GtkWidget* header = adw_header_bar_new();
    GtkGesture* header_click;
    GtkWidget* open_button;
    GtkWidget* page_box;
    GtkWidget* zoom_box;
    GtkWidget* zoom_out;
    GtkWidget* zoom_in;
    GtkWidget* menu_button;
    GtkWidget* tab_button;
    GtkWidget* sidebar_toggle;

    // Explicitly handle only empty header chrome. The gesture lives on the
    // header, never the AdwTabBar, and does not claim single clicks, so native
    // window dragging plus tab reorder/detach keep their complete sequences.
    header_click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(header_click), GDK_BUTTON_PRIMARY);
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(header_click), GTK_PHASE_CAPTURE);
    g_signal_connect(header_click, "pressed", G_CALLBACK(header_pressed), self);
    gtk_widget_add_controller(header, GTK_EVENT_CONTROLLER(header_click));

    // Same layout as the Mac toolbar: open, page "n / total", zoom cluster on
    // the left; search, sidebar, tabs and the menu on the right.
    open_button = gtk_button_new_from_icon_name("document-open-symbolic");
    gtk_widget_set_tooltip_text(open_button, "Open a document (Ctrl+O)");
    gtk_actionable_set_action_name(GTK_ACTIONABLE(open_button), "win.open");
    adw_header_bar_pack_start(ADW_HEADER_BAR(header), open_button);

    page_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    // Mac toolbar "<" / ">" page-step buttons flank the page field.
    {
        GtkWidget* prev_page = gtk_button_new_from_icon_name("go-up-symbolic");
        GtkWidget* next_page = gtk_button_new_from_icon_name("go-down-symbolic");
        gtk_widget_add_css_class(prev_page, "flat");
        gtk_widget_add_css_class(next_page, "flat");
        gtk_widget_set_tooltip_text(prev_page, "Previous page");
        gtk_widget_set_tooltip_text(next_page, "Next page");
        gtk_actionable_set_action_name(GTK_ACTIONABLE(prev_page), "win.prev-page");
        gtk_actionable_set_action_name(GTK_ACTIONABLE(next_page), "win.next-page");
        gtk_box_append(GTK_BOX(page_box), prev_page);
        gtk_box_append(GTK_BOX(page_box), next_page);
    }
    self->page_entry = GTK_ENTRY(gtk_entry_new());
    gtk_entry_set_input_purpose(self->page_entry, GTK_INPUT_PURPOSE_DIGITS);
    gtk_editable_set_width_chars(GTK_EDITABLE(self->page_entry), 4);
    gtk_editable_set_alignment(GTK_EDITABLE(self->page_entry), 1.0f);
    gtk_widget_set_tooltip_text(GTK_WIDGET(self->page_entry), "Current page (Ctrl+L)");
    gtk_widget_set_sensitive(GTK_WIDGET(self->page_entry), FALSE);
    g_signal_connect(self->page_entry, "activate", G_CALLBACK(page_entry_activated), self);
    self->page_total_label = GTK_LABEL(gtk_label_new("/ –"));
    gtk_widget_add_css_class(GTK_WIDGET(self->page_total_label), "dim-label");
    gtk_box_append(GTK_BOX(page_box), GTK_WIDGET(self->page_entry));
    gtk_box_append(GTK_BOX(page_box), GTK_WIDGET(self->page_total_label));
    adw_header_bar_pack_start(ADW_HEADER_BAR(header), page_box);

    zoom_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(zoom_box, "linked");
    zoom_out = gtk_button_new_from_icon_name("zoom-out-symbolic");
    gtk_widget_set_tooltip_text(zoom_out, "Zoom out (Ctrl+-)");
    gtk_actionable_set_action_name(GTK_ACTIONABLE(zoom_out), "win.zoom-out");
    self->zoom_button = GTK_BUTTON(gtk_button_new_with_label("100%"));
    gtk_widget_set_tooltip_text(GTK_WIDGET(self->zoom_button), "Reset zoom (Ctrl+0)");
    gtk_actionable_set_action_name(GTK_ACTIONABLE(self->zoom_button), "win.zoom-actual");
    zoom_in = gtk_button_new_from_icon_name("zoom-in-symbolic");
    gtk_widget_set_tooltip_text(zoom_in, "Zoom in (Ctrl++)");
    gtk_actionable_set_action_name(GTK_ACTIONABLE(zoom_in), "win.zoom-in");
    gtk_box_append(GTK_BOX(zoom_box), zoom_out);
    gtk_box_append(GTK_BOX(zoom_box), GTK_WIDGET(self->zoom_button));
    gtk_box_append(GTK_BOX(zoom_box), zoom_in);
    adw_header_bar_pack_start(ADW_HEADER_BAR(header), zoom_box);

    // Fit-mode dropdown (Mac _fitModePopup: 100% / Fit Width / Fit Height /
    // Fit Page). The model attaches in deferred_menus_idle (launch trim);
    // the label tracks the current tab's fit in update_page_controls.
    {
        GtkWidget* fit_button = gtk_menu_button_new();
        gtk_menu_button_set_label(GTK_MENU_BUTTON(fit_button), "Zoom");
        gtk_menu_button_set_always_show_arrow(GTK_MENU_BUTTON(fit_button), TRUE);
        gtk_widget_set_tooltip_text(fit_button, "Zoom to fit");
        self->fit_button = GTK_MENU_BUTTON(fit_button);
        adw_header_bar_pack_start(ADW_HEADER_BAR(header), fit_button);
    }

    menu_button = gtk_menu_button_new();
    gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(menu_button), "open-menu-symbolic");
    gtk_menu_button_set_primary(GTK_MENU_BUTTON(menu_button), TRUE);
    gtk_widget_set_tooltip_text(menu_button, "Main menu");
    // Launch trim (Wave D): setting the model here makes GtkMenuButton build
    // its whole GtkPopoverMenu item tree (rows, icons, accels) before the
    // window ever maps. The model attaches from the deferred-menus idle in
    // spdf_window_init — the popover cannot open before the loop runs it.
    self->menu_button = GTK_MENU_BUTTON(menu_button);
    adw_header_bar_pack_end(ADW_HEADER_BAR(header), menu_button);

    tab_button = adw_tab_button_new();
    adw_tab_button_set_view(ADW_TAB_BUTTON(tab_button), self->tab_view);
    gtk_actionable_set_action_name(GTK_ACTIONABLE(tab_button), "win.tab-overview");
    gtk_widget_set_tooltip_text(tab_button, "Tab overview (Ctrl+Shift+O)");
    adw_header_bar_pack_end(ADW_HEADER_BAR(header), tab_button);

    sidebar_toggle = gtk_toggle_button_new();
    gtk_button_set_icon_name(GTK_BUTTON(sidebar_toggle), "sidebar-show-symbolic");
    gtk_widget_set_tooltip_text(sidebar_toggle, "Toggle side panel (F9)");
    gtk_actionable_set_action_name(GTK_ACTIONABLE(sidebar_toggle), "win.sidebar");
    adw_header_bar_pack_end(ADW_HEADER_BAR(header), sidebar_toggle);

    // --- minimap module (wave B): header-bar toggle for win.minimap (the Mac
    // "Map" toolbar toggle); the action lives in spdf_minimap.c and tracks
    // the selected tab's per-document showMinimap state.
    {
        GtkWidget* minimap_toggle = gtk_toggle_button_new();
        gtk_button_set_icon_name(GTK_BUTTON(minimap_toggle), "view-dual-symbolic");
        gtk_widget_set_tooltip_text(minimap_toggle, "Toggle the minimap");
        gtk_actionable_set_action_name(GTK_ACTIONABLE(minimap_toggle), "win.minimap");
        adw_header_bar_pack_end(ADW_HEADER_BAR(header), minimap_toggle);
    }

    self->search_toggle = GTK_TOGGLE_BUTTON(gtk_toggle_button_new());
    gtk_button_set_icon_name(GTK_BUTTON(self->search_toggle), "system-search-symbolic");
    gtk_widget_set_tooltip_text(GTK_WIDGET(self->search_toggle), "Search (Ctrl+F)");
    // The search module binds the toggle to the bar's search mode.
    adw_header_bar_pack_end(ADW_HEADER_BAR(header), GTK_WIDGET(self->search_toggle));

    return header;
}

// Wave D launch trim: menu MODELS (hamburger + tab context) attach in this
// idle instead of during window construction. Building them is GMenu appends,
// but attaching makes GtkMenuButton/AdwTabView construct their popover item
// trees — measurable widget work for UI that cannot be opened before the
// main loop runs anyway (the window is not even mapped yet).
static gboolean deferred_menus_idle(gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    GMenuModel* primary;
    GMenuModel* context_menu;

    win->menus_idle_id = 0;
    if (!win->menu_button || !win->tab_view) return G_SOURCE_REMOVE; // disposing
    // Sync win.search-nearest to the persisted setting (the action predates
    // the application property being set; see spdf_window_init).
    {
        GtkApplication* app = gtk_window_get_application(GTK_WINDOW(win));
        GAction* nearest = g_action_map_lookup_action(G_ACTION_MAP(win), "search-nearest");

        if (nearest && app && SPDF_IS_APP(app)) {
            gboolean enabled = spdf_state_settings(spdf_app_get_state(SPDF_APP(app)))->search_jumps_to_nearest_result;
            g_simple_action_set_state(G_SIMPLE_ACTION(nearest), g_variant_new_boolean(enabled));
        }
    }
    primary = build_primary_menu(win); // also creates win->recent_menu
    gtk_menu_button_set_menu_model(win->menu_button, primary);
    g_object_unref(primary);
    // Fit-mode dropdown model (Mac fit popup items, same order).
    if (win->fit_button) {
        GMenu* fit_menu = g_menu_new();
        g_menu_append(fit_menu, "100%", "win.zoom-actual");
        g_menu_append(fit_menu, "Fit Width", "win.fit-width");
        g_menu_append(fit_menu, "Fit Height", "win.fit-height");
        g_menu_append(fit_menu, "Fit Page", "win.fit-page");
        gtk_menu_button_set_menu_model(win->fit_button, G_MENU_MODEL(fit_menu));
        g_object_unref(fit_menu);
    }
    context_menu = build_tab_context_menu();
    adw_tab_view_set_menu_model(win->tab_view, context_menu);
    g_object_unref(context_menu);
    // Recents that landed before the menu existed (command-line document
    // opens) render now; the separate recents idle stays as the state read.
    spdf_window_refresh_recents(win);
    return G_SOURCE_REMOVE;
}

static void spdf_window_init(SpdfWindow* self) {
    GtkWidget* header;
    GtkWidget* new_tab_button;
    GtkEventController* keys;

    gtk_window_set_title(GTK_WINDOW(self), SPDF_APP_DISPLAY_NAME);
    gtk_window_set_default_size(GTK_WINDOW(self), SPDF_DEFAULT_WINDOW_WIDTH, SPDF_DEFAULT_WINDOW_HEIGHT);
    gtk_widget_set_size_request(GTK_WIDGET(self), SPDF_MIN_WINDOW_WIDTH, SPDF_MIN_WINDOW_HEIGHT);
    spdf_window_tab_history_init(&self->tab_history);

    spdf_launch_mark("win-init-begin");
    g_action_map_add_action_entries(G_ACTION_MAP(self), k_window_actions, G_N_ELEMENTS(k_window_actions), self);
    // win.search-nearest: registered here so the palette lists it from the
    // first open; the state starts at the settings default (TRUE) and syncs
    // to the persisted value in deferred_menus_idle, once the application
    // (and with it spdf_state) is reachable.
    {
        GSimpleAction* nearest = g_simple_action_new_stateful("search-nearest", NULL, g_variant_new_boolean(TRUE));
        g_signal_connect_object(nearest, "change-state", G_CALLBACK(search_nearest_change_state), self, 0);
        g_action_map_add_action(G_ACTION_MAP(self), G_ACTION(nearest));
        g_object_unref(nearest);
    }
    spdf_annot_install(self);          // win.rotate-cw/ccw, win.save-as, context-menu actions
    spdf_print_install(self);          // win.print (GtkPrintOperation, Fit/Actual/Custom)
    spdf_props_install(self);          // win.properties (Ctrl+I) — spdf_props.c (Wave B)
    spdf_ocr_install(self);            // win.ocr (Wave C)
    spdf_translate_install(self);      // win.translate (Wave C)
    spdf_default_reader_install(self); // win.make-default (Wave D)

    self->tab_view = ADW_TAB_VIEW(adw_tab_view_new());
    // Tab context menu model attaches in deferred_menus_idle (Wave D).
    g_signal_connect(self->tab_view, "create-window", G_CALLBACK(tab_view_create_window), self);
    g_signal_connect(self->tab_view, "close-page", G_CALLBACK(tab_view_close_page), self);
    g_signal_connect(self->tab_view, "page-attached", G_CALLBACK(tab_view_page_attached), self);
    g_signal_connect(self->tab_view, "page-detached", G_CALLBACK(tab_view_page_detached), self);
    g_signal_connect(self->tab_view, "setup-menu", G_CALLBACK(tab_view_setup_menu), self);
    g_signal_connect(self->tab_view, "notify::selected-page", G_CALLBACK(tab_view_selected_page_changed), self);
    // --- minimap module (wave B): win.minimap action + selected-tab state
    // sync (needs the tab view, so installed after it exists).
    spdf_minimap_install(self);

    spdf_launch_mark("win-actions+tabview");
    self->tab_bar = ADW_TAB_BAR(adw_tab_bar_new());
    adw_tab_bar_set_view(self->tab_bar, self->tab_view);
    // Mac keeps the tab strip visible even with a single document (the
    // titlebar tab row in the readme screenshot); AdwTabBar's default
    // autohide would collapse it until a second tab opens.
    adw_tab_bar_set_autohide(self->tab_bar, FALSE);
    new_tab_button = gtk_button_new_from_icon_name("tab-new-symbolic");
    gtk_widget_add_css_class(new_tab_button, "flat");
    gtk_widget_set_tooltip_text(new_tab_button, "Open document in a new tab (Ctrl+T)");
    gtk_actionable_set_action_name(GTK_ACTIONABLE(new_tab_button), "win.new-tab");
    adw_tab_bar_set_end_action_widget(self->tab_bar, new_tab_button);

    spdf_launch_mark("win-tabbar");
    header = header_bar_new(self);
    spdf_launch_mark("win-header");

    self->toolbar_view = ADW_TOOLBAR_VIEW(adw_toolbar_view_new());
    adw_toolbar_view_add_top_bar(self->toolbar_view, header);
    adw_toolbar_view_add_top_bar(self->toolbar_view, GTK_WIDGET(self->tab_bar));
    // Search bar (spdf_search.c): entry, live counter, prev/next, regex +
    // multiline toggles; also installs the window-level type-anywhere and
    // paste-to-search key handling.
    adw_toolbar_view_add_top_bar(self->toolbar_view, spdf_search_bar_new(self, self->search_toggle));
    spdf_launch_mark("win-searchbar");
    // Sidebar (spdf_sidebar.c, Wave B): wraps the tab view in a GtkPaned with
    // the chapters/comments/search-results panel; owns the win.sidebar action
    // and the persisted width + per-document visibility.
    adw_toolbar_view_set_content(self->toolbar_view, spdf_sidebar_new(self, GTK_WIDGET(self->tab_view)));
    spdf_launch_mark("win-sidebar");

    self->tab_overview = ADW_TAB_OVERVIEW(adw_tab_overview_new());
    adw_tab_overview_set_view(self->tab_overview, self->tab_view);
    adw_tab_overview_set_child(self->tab_overview, GTK_WIDGET(self->toolbar_view));
    // One toast overlay wraps the whole content so notifications (watcher
    // auto-reload, OCR/translate completion) show over any state, including
    // the tab overview.
    self->toast_overlay = ADW_TOAST_OVERLAY(adw_toast_overlay_new());
    adw_toast_overlay_set_child(self->toast_overlay, GTK_WIDGET(self->tab_overview));
    adw_application_window_set_content(ADW_APPLICATION_WINDOW(self), GTK_WIDGET(self->toast_overlay));

    keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(window_key_pressed), self);
    gtk_widget_add_controller(GTK_WIDGET(self), keys);

    g_signal_connect(self, "close-request", G_CALLBACK(window_close_request), NULL);
    spdf_launch_mark("win-init-end");

    // Off-launch-path work, in scheduling order (same priority => FIFO):
    // menu models first (creates recent_menu), then the recents state read.
    self->menus_idle_id = g_idle_add(deferred_menus_idle, self);
    self->recents_idle_id = g_idle_add(refresh_recents_idle, self);
}

static void spdf_window_dispose(GObject* object) {
    SpdfWindow* self = SPDF_WINDOW(object);
    GtkApplication* app = gtk_window_get_application(GTK_WINDOW(self));
    GSList* orphan_tabs = NULL;

    if (self->menus_idle_id) {
        g_source_remove(self->menus_idle_id);
        self->menus_idle_id = 0;
    }
    if (self->recents_idle_id) {
        g_source_remove(self->recents_idle_id);
        self->recents_idle_id = 0;
    }
    if (self->close_if_empty_idle_id) {
        g_source_remove(self->close_if_empty_idle_id);
        self->close_if_empty_idle_id = 0;
    }
    if (self->inhibit_cookie && app) {
        gtk_application_uninhibit(app, self->inhibit_cookie);
        self->inhibit_cookie = 0;
    }
    g_clear_object(&self->recent_menu);
    // Pages disposed with the window never see ::close-page, so reclaim
    // their tab models here — after the widget tree is gone, since the doc
    // view may touch its tab until then.
    if (self->tab_view) {
        int n = adw_tab_view_get_n_pages(self->tab_view);
        for (int i = 0; i < n; ++i) {
            AdwTabPage* page = adw_tab_view_get_nth_page(self->tab_view, i);
            SpdfTab* tab = tab_for_page(page);
            if (!tab) continue;
            g_object_set_data(G_OBJECT(page), "spdf-tab", NULL);
            orphan_tabs = g_slist_prepend(orphan_tabs, tab);
        }
    }
    // Widgets die with the window; drop the borrowed pointers so late
    // callbacks (idles, app iteration during shutdown) see an empty shell.
    self->tab_view = NULL;
    self->tab_bar = NULL;
    self->tab_overview = NULL;
    self->toast_overlay = NULL;
    self->toolbar_view = NULL;
    self->page_entry = NULL;
    self->page_total_label = NULL;
    self->zoom_button = NULL;
    self->fit_button = NULL;
    self->search_toggle = NULL;
    self->menu_button = NULL;
    self->context_page = NULL;
    spdf_window_tab_history_clear(&self->tab_history);
    G_OBJECT_CLASS(spdf_window_parent_class)->dispose(object);
    g_slist_free_full(orphan_tabs, (GDestroyNotify)spdf_tab_close);
    g_clear_pointer(&self->session_id, g_free);
}

static void spdf_window_class_init(SpdfWindowClass* klass) {
    GObjectClass* object_class = G_OBJECT_CLASS(klass);
    object_class->dispose = spdf_window_dispose;
}

SpdfWindow* spdf_window_new(AdwApplication* app) {
    g_return_val_if_fail(ADW_IS_APPLICATION(app), NULL);
    return g_object_new(SPDF_TYPE_WINDOW, "application", app, NULL);
}
