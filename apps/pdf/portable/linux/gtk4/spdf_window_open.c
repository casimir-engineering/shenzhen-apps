#include "spdf_window.h"

#include <string.h>

#include "spdf_password_prompt.h"

typedef struct {
    SpdfWindow* win;
    char* canonical;
    int page_index;
    gboolean remember_recent;
    SpdfWindowOpenReady ready;
    gpointer user_data;
    GDestroyNotify destroy;
} SpdfWindowOpenContext;

static SpdfTab* window_find_open_tab(SpdfWindow* win, const char* canonical) {
    int count = spdf_window_tab_count(win);

    for (int i = 0; i < count; ++i) {
        SpdfTab* tab = spdf_window_tab_at(win, i);
        if (tab && tab->path && strcmp(tab->path, canonical) == 0) return tab;
    }
    return NULL;
}

static void window_show_open_error(SpdfWindow* win, const char* path, const char* message) {
    GtkAlertDialog* alert = gtk_alert_dialog_new("Could not open document");
    char* detail = g_strdup_printf("%s\n%s", path ? path : "", message && *message ? message : "Unknown error.");

    gtk_alert_dialog_set_detail(alert, detail);
    gtk_alert_dialog_show(alert, GTK_WINDOW(win));
    g_object_unref(alert);
    g_free(detail);
}

static void window_open_context_free(gpointer data) {
    SpdfWindowOpenContext* context = data;

    if (context->destroy) context->destroy(context->user_data);
    g_object_unref(context->win);
    g_free(context->canonical);
    g_free(context);
}

static void window_tab_opened(SpdfTab* tab, gboolean cancelled, const char* error, gpointer user_data) {
    SpdfWindowOpenContext* context = user_data;

    if (tab)
        spdf_window_accept_opened(context->win, tab, context->canonical, context->page_index, context->remember_recent);
    else if (!cancelled && error)
        window_show_open_error(context->win, context->canonical, error);
    if (context->ready) context->ready(tab, cancelled, context->user_data);
}

SpdfPasswordPrompt* spdf_window_open_path_async(SpdfWindow* win, const char* path, int page_index,
                                                gboolean remember_recent, SpdfWindowOpenReady ready, gpointer user_data,
                                                GDestroyNotify destroy) {
    SpdfWindowOpenContext* context;
    SpdfTab* existing;
    char* canonical;

    g_return_val_if_fail(SPDF_IS_WINDOW(win), NULL);
    if (!path || !*path) return NULL;
    canonical = g_canonicalize_filename(path, NULL);
    existing = window_find_open_tab(win, canonical);
    if (existing) {
        adw_tab_view_set_selected_page(spdf_window_get_tab_view(win), existing->page);
        if (ready) ready(existing, FALSE, user_data);
        if (destroy) destroy(user_data);
        g_free(canonical);
        return NULL;
    }
    context = g_new0(SpdfWindowOpenContext, 1);
    context->win = g_object_ref(win);
    context->canonical = canonical;
    context->page_index = page_index;
    context->remember_recent = remember_recent;
    context->ready = ready;
    context->user_data = user_data;
    context->destroy = destroy;
    return spdf_tab_open_async(win, canonical, window_tab_opened, context, window_open_context_free);
}

SpdfTab* spdf_window_open_path(SpdfWindow* win, const char* path, int page_index, gboolean remember_recent) {
    SpdfTab* existing;
    char* canonical;

    g_return_val_if_fail(SPDF_IS_WINDOW(win), NULL);
    if (!path || !*path) return NULL;
    canonical = g_canonicalize_filename(path, NULL);
    existing = window_find_open_tab(win, canonical);
    g_free(canonical);
    if (existing) {
        adw_tab_view_set_selected_page(spdf_window_get_tab_view(win), existing->page);
        return existing;
    }
    spdf_window_open_path_async(win, path, page_index, remember_recent, NULL, NULL, NULL);
    return NULL;
}
