#include "spdf_palette_open.h"

typedef struct {
    int page;
    char* search_text;
} PaletteOpenRequest;

static SpdfTab* palette_tab_in_window(SpdfWindow* win, const char* path) {
    char* canonical = g_canonicalize_filename(path, NULL);
    SpdfTab* found = NULL;

    for (int i = 0; i < spdf_window_tab_count(win); ++i) {
        SpdfTab* tab = spdf_window_tab_at(win, i);
        if (tab && tab->path && g_strcmp0(tab->path, canonical) == 0) {
            found = tab;
            break;
        }
    }
    g_free(canonical);
    return found;
}

static void palette_apply_jump(SpdfTab* tab, int page, const char* search_text) {
    if (!tab) return;
    if (tab->view && page >= 0) spdf_doc_view_goto_page(tab->view, page);
    if (search_text && *search_text) {
        g_free(tab->search_text);
        tab->search_text = g_strdup(search_text);
    }
}

static void palette_opened(SpdfTab* tab, gboolean cancelled, gpointer user_data) {
    PaletteOpenRequest* request = user_data;
    (void)cancelled;
    palette_apply_jump(tab, request->page, request->search_text);
}

static void palette_open_request_free(gpointer data) {
    PaletteOpenRequest* request = data;
    g_free(request->search_text);
    g_free(request);
}

void spdf_palette_open_document(SpdfWindow* win, const char* path, int page, const char* search_text,
                                gboolean remember_recent) {
    GtkApplication* app = gtk_window_get_application(GTK_WINDOW(win));
    SpdfWindow* owner = NULL;
    SpdfTab* tab = palette_tab_in_window(win, path);

    if (tab) owner = win;
    for (GList* it = tab || !app ? NULL : gtk_application_get_windows(app); it; it = it->next) {
        if (!SPDF_IS_WINDOW(it->data) || it->data == (gpointer)win) continue;
        tab = palette_tab_in_window(SPDF_WINDOW(it->data), path);
        if (tab) {
            owner = SPDF_WINDOW(it->data);
            break;
        }
    }
    if (tab) {
        adw_tab_view_set_selected_page(spdf_window_get_tab_view(owner), tab->page);
        if (owner != win) gtk_window_present(GTK_WINDOW(owner));
        palette_apply_jump(tab, page, search_text);
        return;
    }
    PaletteOpenRequest* request = g_new0(PaletteOpenRequest, 1);
    request->page = page;
    request->search_text = g_strdup(search_text);
    spdf_window_open_path_async(win, path, page > 0 ? page : 0, remember_recent, palette_opened, request,
                                palette_open_request_free);
}
