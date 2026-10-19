// spdf_tab.c — per-document tab model (contract struct in spdf_internal.h).
// A tab owns its core document, render service and doc view; the AdwTabPage
// owns the widget tree. The tab pointer rides on the page as object data
// ("spdf-tab") so window-level signal handlers can recover it.

#include <string.h>

#include "spdf_annot.h"
#include "spdf_minimap.h"
#include "spdf_password.h"
#include "spdf_search.h"
#include "spdf_sidebar.h"
#include "spdf_watcher.h"
#include "spdf_window.h"

static char* display_name_for_path(const char* path) {
    char* base;
    char* dot;

    base = g_path_get_basename(path && *path ? path : "Untitled");
    dot = strrchr(base, '.');
    if (dot && dot != base && g_ascii_strcasecmp(dot, ".pdf") == 0) *dot = '\0';
    return base;
}

char* spdf_tab_display_name(const SpdfTab* tab) {
    const char* meta;

    if (!tab) return g_strdup("Untitled");
    meta = tab->doc ? spdf_title(tab->doc) : NULL;
    // Read-only shadow copies open from the private working copy, and the
    // core's no-metadata fallback title is the basename of the file it
    // OPENED — the ro-<hash>.pdf copy, not the document. Tab identity stays
    // on the SOURCE (Mac model), so ignore that fallback and derive the
    // label from tab->path below.
    if (meta && *meta && tab->working_path) {
        char* copy_base = g_path_get_basename(tab->working_path);
        gboolean is_copy_fallback = g_strcmp0(meta, copy_base) == 0;
        g_free(copy_base);
        if (is_copy_fallback) meta = NULL;
    }
    if (meta && *meta) {
        // GTK3 parity: labels drop a trailing ".pdf" even from metadata.
        char* copy = g_strdup(meta);
        char* dot = strrchr(copy, '.');
        if (dot && dot != copy && g_ascii_strcasecmp(dot, ".pdf") == 0) *dot = '\0';
        return copy;
    }
    return display_name_for_path(tab->path);
}

const char* spdf_tab_get_path(SpdfTab* tab) {
    return tab ? tab->path : NULL;
}

static cairo_status_t read_only_dot_png_write(void* closure, const unsigned char* data, unsigned int length) {
    g_byte_array_append((GByteArray*)closure, data, length);
    return CAIRO_STATUS_SUCCESS;
}

// The ORANGE read-only dot (Mac SPDFMacTabStripView.mm: kReadOnlyDotDiameter
// 7pt filled with NSColor.systemOrangeColor, 26.6.27-2 release notes). A
// themed *-symbolic icon gets recolored to the theme foreground and reads as
// a gray/white dot, so the dot is rendered once into a PNG-backed GBytesIcon,
// which the tab bar shows as-is: fixed systemOrange (#FF9500) in both light
// and dark. Drawn at 2x with the dot filling half the canvas, mirroring the
// Mac's small-dot-in-tab proportions when scaled to the 16px indicator slot.
static GIcon* read_only_dot_icon(void) {
    static GIcon* icon = NULL;
    static gsize initialized = 0; // same one-shot pattern as render_pool_get
    if (g_once_init_enter(&initialized)) {
        cairo_surface_t* surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 32, 32);
        cairo_t* cr = cairo_create(surface);
        GByteArray* array = g_byte_array_new();
        GBytes* bytes;

        cairo_set_source_rgb(cr, 1.0, 0.584, 0.0); // systemOrange light variant
        cairo_arc(cr, 16.0, 16.0, 8.0, 0.0, 2.0 * G_PI);
        cairo_fill(cr);
        cairo_destroy(cr);
        cairo_surface_write_to_png_stream(surface, read_only_dot_png_write, array);
        cairo_surface_destroy(surface);
        bytes = g_byte_array_free_to_bytes(array);
        icon = g_bytes_icon_new(bytes);
        g_bytes_unref(bytes);
        g_once_init_leave(&initialized, 1);
    }
    return icon;
}

void spdf_tab_set_read_only_shadow(SpdfTab* tab, gboolean read_only) {
    if (!tab || tab->read_only_shadow == read_only) return;
    tab->read_only_shadow = read_only;
    if (!tab->page) return;
    if (read_only) {
        // Indicator slot for the orange read-only dot; the watcher module
        // flips this when it swaps a document for its shadow copy. Tooltip
        // ports the Mac dot tooltip (minus the macOS prompt wording).
        adw_tab_page_set_indicator_icon(tab->page, read_only_dot_icon());
        adw_tab_page_set_indicator_tooltip(tab->page,
                                           "Read-only file. You're viewing a local copy; changes to the "
                                           "original are picked up automatically. Editing will ask to "
                                           "save a copy.");
    } else {
        adw_tab_page_set_indicator_icon(tab->page, NULL);
    }
}

SpdfTab* spdf_tab_attach_opened(SpdfWindow* win, char* canonical, char* working_path, guint64 copy_size,
                                double copy_mtime, gboolean source_read_only, spdf_document* doc,
                                SpdfPasswordCredential* credential) {
    SpdfTab* tab;
    GtkWidget* content;
    AdwTabView* view;
    char* title;
    char* tooltip;
    tab = g_new0(SpdfTab, 1);
    tab->path = canonical;
    tab->working_path = working_path; // owned; NULL when writable
    tab->ro_copy_file_size = copy_size;
    tab->ro_copy_modified_at = copy_mtime;
    tab->doc = doc;
    tab->credential = credential;
    tab->win = win;
    tab->search_text = g_strdup("");
    tab->search_regex_multiline = TRUE; // GTK3/session default
    tab->find_match_index = -1;

    {
        char* render_error = NULL;
        tab->render =
            spdf_render_service_new(tab->working_path ? tab->working_path : tab->path, tab->credential, &render_error);
        if (!tab->render) {
            // The doc view tolerates a missing render service (blank canvas);
            // keep the tab usable for metadata/search rather than failing.
            g_warning("shenzhenpdf: no render service for %s: %s", tab->path,
                      render_error && *render_error ? render_error : "unknown error");
        }
        g_free(render_error);
    }
    spdf_launch_mark("tab-render-svc");
    tab->view = spdf_doc_view_new(tab);
    spdf_launch_mark("tab-view-built");
    // --- search module (wave B): the doc view implements GtkScrollable, so
    // it gets its GtkScrolledWindow here; a GtkOverlay on top hosts the
    // scrollbar heat-map lane (and later overlay lanes from other modules).
    tab->scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(tab->scroller), GTK_WIDGET(tab->view));
    tab->overlay = gtk_overlay_new();
    gtk_overlay_set_child(GTK_OVERLAY(tab->overlay), tab->scroller);
    tab->search = spdf_search_controller_new(tab);
    gtk_overlay_add_overlay(GTK_OVERLAY(tab->overlay), spdf_search_markers_new(tab));
    // --- minimap module (wave B): the strip takes real width on the RIGHT of
    // the page content (Mac trailing-edge placement: document — with its
    // scrollbar + heat-map lane — then the map), so the overlay and the strip
    // share a horizontal row. tab->overlay stays the page-content root.
    {
        GtkWidget* row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
        gtk_widget_set_hexpand(tab->overlay, TRUE);
        gtk_box_append(GTK_BOX(row), tab->overlay);
        tab->minimap = spdf_minimap_new(tab);
        gtk_box_append(GTK_BOX(row), tab->minimap);
        content = row;
    }

    view = spdf_window_get_tab_view(win);
    tab->page = adw_tab_view_append(view, content);
    g_object_set_data(G_OBJECT(tab->page), "spdf-tab", tab);
    // adw_tab_view_append fired page-attached (and, for the first page,
    // notify::selected-page) synchronously — before the "spdf-tab" link
    // above existed. Re-run the window's attach work (docview page/zoom
    // signal hookup, minimap action sync) now that the link resolves.
    spdf_window_tab_linked(win, tab->page);
    title = spdf_tab_display_name(tab);
    adw_tab_page_set_title(tab->page, title);
    tooltip = g_markup_escape_text(tab->path, -1); // tab tooltip = full path
    adw_tab_page_set_tooltip(tab->page, tooltip);
    g_free(tooltip);
    g_free(title);
    if (source_read_only) spdf_tab_set_read_only_shadow(tab, TRUE); // orange dot (Wave C)
    spdf_launch_mark("tab-page-appended");
    spdf_annot_tab_attached(tab);   // context menu, comment markers (Wave B)
    spdf_watcher_tab_attached(tab); // file monitor on tab->path (Wave C)
    spdf_launch_mark("tab-open-end");
    return tab;
}

void spdf_tab_close(SpdfTab* tab) {
    if (!tab) return;
    spdf_password_credential_revoke(tab->credential);
    if (tab->search) {
        // Cancels any in-flight search; late idle deliveries hold their own
        // controller refs and drop themselves on the generation check.
        spdf_search_controller_detach(tab->search);
        g_clear_object(&tab->search);
    }
    spdf_annot_tab_closing(tab);    // comment cache + pending idle (Wave B)
    spdf_sidebar_tab_closing(tab);  // outline cache + sidebar refs (Wave B)
    spdf_watcher_tab_detached(tab); // monitor + timers + shadow fields (Wave C)
    g_clear_pointer(&tab->render, spdf_render_service_free);
    if (tab->doc) {
        spdf_close(tab->doc);
        tab->doc = NULL;
    }
    spdf_password_credential_unref(tab->credential);
    tab->credential = NULL;
    g_free(tab->path);
    g_free(tab->search_text);
    tab->page = NULL;
    tab->view = NULL;
    tab->scroller = NULL; // owned by the page's widget tree, like view
    tab->overlay = NULL;
    tab->minimap = NULL; // owned by the page's widget tree (spdf_minimap.c)
    tab->win = NULL;
    g_free(tab);
}
