/* Your links in the profile (szfriends_gtk_details_page.h; PROTOCOL.md § Links). Mirrors mac/SZFriendsYourLinks.m:
 * the friend link with Copy and Reset link, then each live download link with its file, downloads so far, expiry and
 * Revoke. Hidden while the snapshot has no `links`. */

#include "gtk/szfriends_gtk_details_page.h"

#include <string.h>

typedef struct {
    SZFriendsGtkPage *page;
    SZFriendsGtkDetailsHeld *held;
    GtkWidget *title, *friend_label, *friend_url, *friend_note, *copy, *reset_slot, *downloads_title,
        *downloads_empty, *downloads;
} SZFriendsGtkProfileLinksView;

static const SZFriendsGtkProfileLinks *links_of(SZFriendsGtkProfileLinksView *view) {
    const SZFriendsGtkProfileSnapshot *snapshot = view->held ? szfriends_gtk_details_held_value(view->held) : NULL;
    return snapshot ? snapshot->links : NULL;
}

static void copy_clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkProfileLinksView *view = data;
    const SZFriendsGtkProfileLinks *links = links_of(view);
    if (links && *links->friend_link.url)
        szfriends_gtk_details_copy(view->page, GTK_WIDGET(button), links->friend_link.url);
}

static void view_free(gpointer data) {
    SZFriendsGtkProfileLinksView *view = data;
    g_clear_pointer(&view->held, szfriends_gtk_details_held_unref);
    g_free(view);
}

static void clear(GtkWidget *box) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(box))) gtk_box_remove(GTK_BOX(box), child);
}

GtkWidget *szfriends_gtk_profile_links_new(SZFriendsGtkPage *page) {
    SZFriendsGtkProfileLinksView *view = g_new0(SZFriendsGtkProfileLinksView, 1);
    view->page = page;
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_name(box, "szfriends.profile.links");
    g_object_set_data_full(G_OBJECT(box), "szfriends-links", view, view_free);
    view->title = szfriends_gtk_details_label("heading");
    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(card, "card");
    GtkWidget *inner = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_margin_top(inner, 12);
    gtk_widget_set_margin_bottom(inner, 12);
    gtk_widget_set_margin_start(inner, 12);
    gtk_widget_set_margin_end(inner, 12);
    view->friend_label = szfriends_gtk_details_label("szfriends-secondary caption-heading");
    view->friend_url = szfriends_gtk_details_label(NULL);
    gtk_label_set_wrap(GTK_LABEL(view->friend_url), FALSE);
    gtk_label_set_ellipsize(GTK_LABEL(view->friend_url), PANGO_ELLIPSIZE_MIDDLE);
    GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    view->copy = gtk_button_new();
    gtk_widget_set_name(view->copy, "szfriends.profile.links.copy");
    g_signal_connect(view->copy, "clicked", G_CALLBACK(copy_clicked), view);
    view->reset_slot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_box_append(GTK_BOX(buttons), view->copy);
    gtk_box_append(GTK_BOX(buttons), view->reset_slot);
    view->friend_note = szfriends_gtk_details_label("szfriends-secondary");
    for (GtkWidget **child = (GtkWidget *[]){view->friend_label, view->friend_url, buttons, view->friend_note, NULL};
         *child; child++)
        gtk_box_append(GTK_BOX(inner), *child);
    gtk_box_append(GTK_BOX(card), inner);
    view->downloads_title = szfriends_gtk_details_label("szfriends-secondary caption-heading");
    view->downloads_empty = szfriends_gtk_details_label("szfriends-secondary");
    view->downloads = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    for (GtkWidget **child = (GtkWidget *[]){view->title, card, view->downloads_title, view->downloads_empty,
                                            view->downloads, NULL};
         *child; child++)
        gtk_box_append(GTK_BOX(box), *child);
    gtk_widget_set_visible(box, FALSE);
    return box;
}

static GtkWidget *download_row(SZFriendsGtkProfileLinksView *view, const SZFriendsGtkDownloadLink *download) {
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_hexpand(text, TRUE);
    GtkWidget *file = szfriends_gtk_details_label(NULL);
    gtk_widget_set_name(file, "szfriends.profile.links.file");
    gtk_label_set_wrap(GTK_LABEL(file), FALSE);
    gtk_label_set_ellipsize(GTK_LABEL(file), PANGO_ELLIPSIZE_MIDDLE);
    szfriends_gtk_details_label_set(file, download->file_name);
    gtk_widget_set_tooltip_text(file, download->file_name);
    GtkWidget *detail = szfriends_gtk_details_label("szfriends-secondary");
    char *joined = *download->downloads_label && *download->expires_label
                       ? g_strconcat(download->downloads_label, " · ", download->expires_label, NULL)
                       : g_strconcat(download->downloads_label, download->expires_label, NULL);
    szfriends_gtk_details_label_set(detail, joined);
    g_free(joined);
    gtk_box_append(GTK_BOX(text), file);
    gtk_box_append(GTK_BOX(text), detail);
    gtk_box_append(GTK_BOX(row), text);
    SZFriendsGtkActionIds ids = {0};
    GtkWidget *revoke = szfriends_gtk_details_button_new(view->page, view->held, &download->revoke, &ids);
    if (revoke) {
        gtk_widget_set_valign(revoke, GTK_ALIGN_CENTER);
        gtk_widget_set_name(revoke, "szfriends.profile.links.revoke");
        gtk_box_append(GTK_BOX(row), revoke);
    }
    return row;
}

void szfriends_gtk_profile_links_apply(GtkWidget *box, SZFriendsGtkDetailsHeld *held) {
    SZFriendsGtkProfileLinksView *view = g_object_get_data(G_OBJECT(box), "szfriends-links");
    if (!view) return;
    SZFriendsGtkDetailsHeld *previous = view->held;
    view->held = held ? szfriends_gtk_details_held_ref(held) : NULL;
    if (previous) szfriends_gtk_details_held_unref(previous);
    const SZFriendsGtkProfileLinks *links = links_of(view);
    gtk_widget_set_visible(box, links != NULL);
    if (!links) return;
    const SZFriendsGtkFriendLink *friend_link = &links->friend_link;
    szfriends_gtk_details_label_set(view->title, links->title);
    szfriends_gtk_details_label_set(view->friend_label, friend_link->label);
    szfriends_gtk_details_label_set(view->friend_url, friend_link->url);
    gtk_widget_set_tooltip_text(view->friend_url, friend_link->url);
    szfriends_gtk_details_label_set(view->friend_note, friend_link->note);
    gtk_button_set_label(GTK_BUTTON(view->copy), friend_link->copy_label);
    gtk_widget_set_visible(view->copy, *friend_link->copy_label && *friend_link->url);
    SZFriendsGtkActionIds ids = {0};
    GtkWidget *reset = gtk_widget_get_first_child(view->reset_slot);
    if (!reset || !szfriends_gtk_details_button_matches(reset, &friend_link->reset, &ids)) {
        clear(view->reset_slot);
        reset = szfriends_gtk_details_button_new(view->page, view->held, &friend_link->reset, &ids);
        if (reset) {
            gtk_widget_set_name(reset, "szfriends.profile.links.reset");
            gtk_box_append(GTK_BOX(view->reset_slot), reset);
        }
    }
    szfriends_gtk_details_label_set(view->downloads_title, links->downloads_label);
    szfriends_gtk_details_label_set(view->downloads_empty, links->n_downloads ? NULL : links->downloads_empty);
    clear(view->downloads);
    for (gsize i = 0; i < links->n_downloads; i++)
        gtk_box_append(GTK_BOX(view->downloads), download_row(view, &links->downloads[i]));
}
