/* Pages: the per-link builders, and the frame every dropdown page shares (szfriends_gtk_dropdown.h).
 *
 * Each page is an AdwNavigationPage holding an AdwToolbarView whose AdwHeaderBar has the back arrow at the top left
 * (ours, not the header bar's, so it can carry the waiting count) and the title centred. The header bar's window
 * buttons stay off: inside a popover they would act on the window. */

#include "gtk/szfriends_gtk_link_private.h"
#include "gtk/szfriends_gtk_internal.h"

#include <adwaita.h>

typedef struct {
    SZFriendsGtkPageClass klass;
    gpointer user_data;
    gboolean registered;
} SZFriendsGtkPageEntry;

struct _SZFriendsGtkPage {
    SZFriendsGtkPageKind kind;
    char *argument, *message_id;
    SZFriendsGtkLink *link;
    SZFriendsGtkDropdown *dropdown;
    SZFriendsGtkPageEntry entry;
    GtkWidget *widget;  /* AdwNavigationPage, or the Settings section's box */
    GtkWidget *toolbar; /* AdwToolbarView; NULL for Settings */
    GtkWidget *header, *back_button, *back_badge, *title;
    gpointer data;
    GDestroyNotify data_destroy;
    gboolean presented;
};

void szfriends_gtk_register_page(SZFriendsGtkLink *link, SZFriendsGtkPageKind kind,
                                 const SZFriendsGtkPageClass *page_class, gpointer user_data) {
    g_return_if_fail(link && kind < SZFRIENDS_GTK_PAGE_KIND_COUNT && page_class && page_class->build);
    if (!link->pages) link->pages = g_new0(SZFriendsGtkPageEntry, SZFRIENDS_GTK_PAGE_KIND_COUNT);
    SZFriendsGtkPageEntry *entry = &((SZFriendsGtkPageEntry *)link->pages)[kind];
    entry->klass = *page_class;
    entry->user_data = user_data;
    entry->registered = TRUE;
}

void szfriends_gtk_pages_unregister(SZFriendsGtkLink *link) {
    g_clear_pointer(&link->pages, g_free);
}

static void page_free(gpointer data) {
    SZFriendsGtkPage *page = data;
    /* A page destroyed while on screen still hears it left, so it releases its subscriptions. */
    if (page->presented && page->entry.klass.presented) page->entry.klass.presented(page, FALSE, page->entry.user_data);
    if (page->entry.klass.dispose) page->entry.klass.dispose(page, page->entry.user_data);
    if (page->data_destroy) page->data_destroy(page->data);
    szfriends_gtk_link_unref(page->link);
    g_free(page->argument);
    g_free(page->message_id);
    g_free(page);
}

static void back_clicked(GtkButton *button, gpointer data) {
    (void)button;
    SZFriendsGtkPage *page = data;
    if (page->dropdown) szfriends_gtk_dropdown_go_back(page->dropdown);
}

static GtkWidget *make_back_button(SZFriendsGtkPage *page) {
    GtkWidget *overlay = gtk_overlay_new();
    page->back_button = gtk_button_new_from_icon_name("go-previous-symbolic");
    gtk_widget_add_css_class(page->back_button, "flat");
    gtk_widget_add_css_class(page->back_button, "szfriends-back");
    const char *back = szfriends_gtk_link_string(page->link, "back");
    if (*back) {
        gtk_widget_set_tooltip_text(page->back_button, back);
        gtk_accessible_update_property(GTK_ACCESSIBLE(page->back_button), GTK_ACCESSIBLE_PROPERTY_LABEL, back, -1);
    }
    g_signal_connect(page->back_button, "clicked", G_CALLBACK(back_clicked), page);
    gtk_overlay_set_child(GTK_OVERLAY(overlay), page->back_button);
    page->back_badge = gtk_label_new(NULL);
    gtk_widget_add_css_class(page->back_badge, "szfriends-badge");
    gtk_widget_set_halign(page->back_badge, GTK_ALIGN_END);
    gtk_widget_set_valign(page->back_badge, GTK_ALIGN_START);
    gtk_widget_set_can_target(page->back_badge, FALSE); /* the whole arrow stays one hit area */
    gtk_widget_set_visible(page->back_badge, FALSE);
    gtk_overlay_add_overlay(GTK_OVERLAY(overlay), page->back_badge);
    return overlay;
}

/* What names a page before its own words arrive: the Friends button's name from the helper, or while no helper has
 * answered yet the client library's line ("Starting Friends…"), or the host app's name. libadwaita warns about a
 * page mapped with no title, and assistive technology announces the page by it (UX verification, wave 6d). */
static const char *fallback_name(SZFriendsGtkPage *page) {
    const char *name = szfriends_gtk_link_string(page->link, "button_label");
    if (!*name) name = szfriends_gtk_link_status_text(page->link);
    if (!name || !*name) name = page->link->host.app_name;
    return name ? name : "";
}

void szfriends_gtk_page_set_name(SZFriendsGtkPage *page, const char *name) {
    if (!page || !ADW_IS_NAVIGATION_PAGE(page->widget)) return;
    adw_navigation_page_set_title(ADW_NAVIGATION_PAGE(page->widget), name && *name ? name : fallback_name(page));
}

static void build_frame(SZFriendsGtkPage *page) {
    page->toolbar = adw_toolbar_view_new();
    page->header = adw_header_bar_new();
    adw_header_bar_set_show_start_title_buttons(ADW_HEADER_BAR(page->header), FALSE);
    adw_header_bar_set_show_end_title_buttons(ADW_HEADER_BAR(page->header), FALSE);
    adw_header_bar_set_show_back_button(ADW_HEADER_BAR(page->header), FALSE);
    if (page->kind != SZFRIENDS_GTK_PAGE_LIST) adw_header_bar_pack_start(ADW_HEADER_BAR(page->header),
                                                                         make_back_button(page));
    page->title = adw_window_title_new("", "");
    adw_header_bar_set_title_widget(ADW_HEADER_BAR(page->header), page->title);
    adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(page->toolbar), page->header);
    /* Tags are for the navigation view's own lookups; titles are what people read, set by the page. */
    page->widget = GTK_WIDGET(adw_navigation_page_new(page->toolbar, fallback_name(page)));
    adw_navigation_page_set_can_pop(ADW_NAVIGATION_PAGE(page->widget), page->kind != SZFRIENDS_GTK_PAGE_LIST);
}

SZFriendsGtkPage *szfriends_gtk_page_new(SZFriendsGtkLink *link, SZFriendsGtkDropdown *dropdown,
                                         SZFriendsGtkPageKind kind, const char *argument, const char *message_id) {
    SZFriendsGtkPage *page = g_new0(SZFriendsGtkPage, 1);
    page->kind = kind;
    page->link = link;
    szfriends_gtk_link_ref(link);
    page->dropdown = dropdown;
    page->argument = g_strdup(argument);
    page->message_id = g_strdup(message_id);
    if (link->pages && kind < SZFRIENDS_GTK_PAGE_KIND_COUNT) page->entry = ((SZFriendsGtkPageEntry *)link->pages)[kind];
    if (kind == SZFRIENDS_GTK_PAGE_SETTINGS) page->widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    else build_frame(page);
    gtk_widget_add_css_class(page->widget, "szfriends-page");
    /* The page lives as long as its widget: popping it from the navigation view, or the host dropping the
     * Settings section, frees it. */
    g_object_set_data_full(G_OBJECT(page->widget), "szfriends-page", page, page_free);
    if (page->entry.registered) page->entry.klass.build(page, page->entry.user_data);
    return page;
}

SZFriendsGtkPage *szfriends_gtk_page_from_widget(GtkWidget *widget) {
    return widget ? g_object_get_data(G_OBJECT(widget), "szfriends-page") : NULL;
}

void szfriends_gtk_page_set_presented(SZFriendsGtkPage *page, gboolean presented) {
    if (!page || page->presented == presented) return;
    page->presented = presented;
    if (page->entry.klass.presented) page->entry.klass.presented(page, presented, page->entry.user_data);
}

gboolean szfriends_gtk_page_escape(SZFriendsGtkPage *page) {
    return page && page->entry.klass.escape && page->entry.klass.escape(page, page->entry.user_data);
}

void szfriends_gtk_page_highlight(SZFriendsGtkPage *page, const char *message_id) {
    if (!page || !message_id) return;
    gboolean presented = page->presented;
    szfriends_gtk_page_set_presented(page, FALSE);
    g_free(page->message_id);
    page->message_id = g_strdup(message_id);
    szfriends_gtk_page_set_presented(page, presented);
}

SZFriendsGtkPageKind szfriends_gtk_page_get_kind(SZFriendsGtkPage *page) {
    return page->kind;
}

const char *szfriends_gtk_page_get_argument(SZFriendsGtkPage *page) {
    return page->argument;
}

const char *szfriends_gtk_page_get_message_id(SZFriendsGtkPage *page) {
    return page->message_id;
}

SZFriendsGtkLink *szfriends_gtk_page_get_link(SZFriendsGtkPage *page) {
    return page->link;
}

SZFriendsGtkDropdown *szfriends_gtk_page_get_dropdown(SZFriendsGtkPage *page) {
    return page->dropdown;
}

GtkWidget *szfriends_gtk_page_get_widget(SZFriendsGtkPage *page) {
    return page->widget;
}

gboolean szfriends_gtk_page_is_presented(SZFriendsGtkPage *page) {
    return page->presented;
}

GtkWidget *szfriends_gtk_page_get_back_button(SZFriendsGtkPage *page) {
    return page->back_button;
}

void szfriends_gtk_page_set_content(SZFriendsGtkPage *page, GtkWidget *content) {
    if (page->toolbar) {
        adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(page->toolbar), content);
        return;
    }
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(page->widget))) gtk_box_remove(GTK_BOX(page->widget), child);
    if (content) gtk_box_append(GTK_BOX(page->widget), content);
}

void szfriends_gtk_page_add_top_bar(SZFriendsGtkPage *page, GtkWidget *bar) {
    if (page->toolbar) adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(page->toolbar), bar);
}

void szfriends_gtk_page_add_bottom_bar(SZFriendsGtkPage *page, GtkWidget *bar) {
    if (page->toolbar) adw_toolbar_view_add_bottom_bar(ADW_TOOLBAR_VIEW(page->toolbar), bar);
}

void szfriends_gtk_page_set_title(SZFriendsGtkPage *page, const char *title, const char *subtitle) {
    if (!page->header) return;
    if (!page->title || !ADW_IS_WINDOW_TITLE(page->title)) {
        page->title = adw_window_title_new("", "");
        adw_header_bar_set_title_widget(ADW_HEADER_BAR(page->header), page->title);
    }
    /* AdwWindowTitle shows its strings as plain text (use-markup stays off): names come from other people. */
    adw_window_title_set_title(ADW_WINDOW_TITLE(page->title), title ? title : "");
    adw_window_title_set_subtitle(ADW_WINDOW_TITLE(page->title), subtitle ? subtitle : "");
    szfriends_gtk_page_set_name(page, title);
}

void szfriends_gtk_page_set_title_widget(SZFriendsGtkPage *page, GtkWidget *widget) {
    if (!page->header) return;
    page->title = widget;
    adw_header_bar_set_title_widget(ADW_HEADER_BAR(page->header), widget);
}

void szfriends_gtk_page_set_back(SZFriendsGtkPage *page, const SZFriendsGtkBack *back) {
    if (!page->back_button) return;
    const char *label = back && back->badge_label ? back->badge_label : "";
    gtk_label_set_text(GTK_LABEL(page->back_badge), label);
    gtk_widget_set_visible(page->back_badge, *label != '\0');
    const char *name = back && back->accessibility_label && *back->accessibility_label
                           ? back->accessibility_label : szfriends_gtk_link_string(page->link, "back");
    if (*name) gtk_accessible_update_property(GTK_ACCESSIBLE(page->back_button), GTK_ACCESSIBLE_PROPERTY_LABEL, name,
                                              -1);
    gtk_widget_set_tooltip_text(page->back_button, *name ? name : NULL);
}

void szfriends_gtk_page_set_data(SZFriendsGtkPage *page, gpointer data, GDestroyNotify destroy) {
    if (page->data_destroy) page->data_destroy(page->data);
    page->data = data;
    page->data_destroy = destroy;
}

gpointer szfriends_gtk_page_get_data(SZFriendsGtkPage *page) {
    return page->data;
}

/* ---- The Settings section ------------------------------------------------------------------------ */

static void section_mapped(GtkWidget *widget, gpointer data) {
    (void)widget;
    szfriends_gtk_page_set_presented(data, TRUE);
}

static void section_unmapped(GtkWidget *widget, gpointer data) {
    (void)widget;
    szfriends_gtk_page_set_presented(data, FALSE);
}

GtkWidget *szfriends_gtk_settings_section_new(SZFriendsGtkLink *link) {
    g_return_val_if_fail(link, NULL);
    SZFriendsGtkPage *page = szfriends_gtk_page_new(link, NULL, SZFRIENDS_GTK_PAGE_SETTINGS, NULL, NULL);
    gtk_widget_set_name(page->widget, "szfriends.settings");
    /* Subscribed only while the section is on screen, as the AppKit section holds its subscription. */
    g_signal_connect(page->widget, "map", G_CALLBACK(section_mapped), page);
    g_signal_connect(page->widget, "unmap", G_CALLBACK(section_unmapped), page);
    return page->widget;
}
