/* Text said aloud through assistive technology, where GTK can say it.
 *
 * Every announcement of the views goes through szfriends_gtk_announce, never gtk_accessible_announce directly.
 * GTK calls the accessibility backend's announce function without checking that it has one
 * (gtk_at_context_announce, GTK 4.22). GtkTestATContext, the backend GTK falls back to where it was built with
 * none for the platform, has no announce function. That is every widget on macOS with Homebrew's GTK, which
 * Shenzhen Files ships, so the direct call jumped to address 0 there: Copy ID crashed the app. */

#include "gtk/szfriends_gtk_link.h"

static gboolean can_announce(GtkAccessible *accessible) {
    GtkATContext *context = gtk_accessible_get_at_context(accessible);
    if (!context) return FALSE;
    gboolean can = g_strcmp0(G_OBJECT_TYPE_NAME(context), "GtkTestATContext") != 0;
    g_object_unref(context);
    return can;
}

void szfriends_gtk_announce(GtkWidget *widget, const char *text, GtkAccessibleAnnouncementPriority priority) {
    if (!widget || !text || !*text) return;
    if (can_announce(GTK_ACCESSIBLE(widget))) gtk_accessible_announce(GTK_ACCESSIBLE(widget), text, priority);
}
