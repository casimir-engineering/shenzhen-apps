/* Held snapshots, Copy with its moment of "Copied", announcements and replies, for the details, profile and Settings
 * pages (szfriends_gtk_details_page.h). Confirmations, performing an action and what reaches outside the process are
 * every page's, in szfriends_gtk_list_support.c. */

#include "gtk/szfriends_gtk_details_page.h"

#include <adwaita.h>
#include <string.h>

/* ---- Held snapshots ------------------------------------------------------------------------------------------ */

struct _SZFriendsGtkDetailsHeld {
    const SZFriendsGtkType *type;
    gpointer value;
};

SZFriendsGtkDetailsHeld *szfriends_gtk_details_held_new(const SZFriendsGtkType *type, gpointer value) {
    SZFriendsGtkDetailsHeld *held = g_rc_box_new0(SZFriendsGtkDetailsHeld);
    held->type = type;
    held->value = value;
    return held;
}

SZFriendsGtkDetailsHeld *szfriends_gtk_details_held_ref(SZFriendsGtkDetailsHeld *held) {
    return held ? g_rc_box_acquire(held) : NULL;
}

static void held_clear(gpointer data) {
    SZFriendsGtkDetailsHeld *held = data;
    if (held->value) szfriends_gtk_value_free(held->type, held->value);
}

void szfriends_gtk_details_held_unref(SZFriendsGtkDetailsHeld *held) {
    if (held) g_rc_box_release_full(held, held_clear);
}

gpointer szfriends_gtk_details_held_value(SZFriendsGtkDetailsHeld *held) {
    return held ? held->value : NULL;
}

/* ---- Copy and announcements -------------------------------------------------------------------------------- */

void szfriends_gtk_details_announce(GtkWidget *widget, const char *text) {
    if (widget && text && *text)
        gtk_accessible_announce(GTK_ACCESSIBLE(widget), text, GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM);
}

typedef struct {
    GtkWidget *button;
    char *label, *icon;
    guint source;
} SZFriendsGtkCopied;

static void copied_free(gpointer data) {
    SZFriendsGtkCopied *copied = data;
    if (copied->source) g_source_remove(copied->source);
    g_free(copied->label);
    g_free(copied->icon);
    g_free(copied);
}

static gboolean copied_restore(gpointer data) {
    SZFriendsGtkCopied *copied = data;
    copied->source = 0;
    GtkButton *button = GTK_BUTTON(copied->button);
    GtkWidget *glyph = gtk_button_get_child(button);
    if (copied->icon && GTK_IS_IMAGE(glyph)) gtk_image_set_from_icon_name(GTK_IMAGE(glyph), copied->icon);
    else if (copied->label) gtk_button_set_label(button, copied->label);
    g_object_set_data(G_OBJECT(button), "szfriends-copied", NULL);
    return G_SOURCE_REMOVE;
}

void szfriends_gtk_details_copy(SZFriendsGtkPage *page, GtkWidget *button, const char *text) {
    if (!text || !*text) return;
    szfriends_gtk_copy_text(button, text);
    const char *copied = szfriends_gtk_link_string(szfriends_gtk_page_get_link(page), "copied");
    szfriends_gtk_details_announce(button, copied);
    if (!*copied || !GTK_IS_BUTTON(button)) return;
    /* For a moment the button itself says it worked: Copy changes nothing else on screen. */
    SZFriendsGtkCopied *state = g_object_get_data(G_OBJECT(button), "szfriends-copied");
    /* The image itself changes, not the button's icon, so a glyph sized by its page keeps its size. */
    GtkWidget *glyph = gtk_button_get_child(GTK_BUTTON(button));
    if (!state) {
        state = g_new0(SZFriendsGtkCopied, 1);
        state->button = button;
        state->icon = GTK_IS_IMAGE(glyph) ? g_strdup(gtk_image_get_icon_name(GTK_IMAGE(glyph))) : NULL;
        state->label = state->icon ? NULL : g_strdup(gtk_button_get_label(GTK_BUTTON(button)));
        g_object_set_data_full(G_OBJECT(button), "szfriends-copied", state, copied_free);
    }
    if (state->icon) gtk_image_set_from_icon_name(GTK_IMAGE(glyph), "object-select-symbolic");
    else if (state->label) gtk_button_set_label(GTK_BUTTON(button), copied);
    if (state->source) g_source_remove(state->source);
    state->source = g_timeout_add(1500, copied_restore, state);
}

/* ---- Replies --------------------------------------------------------------------------------------------- */

/* A reply reaches the page only while it exists: the person may have gone back before the helper answered. The page
 * lives as long as its widget, so a weak reference to the widget says whether the page is still there. */
typedef struct {
    GWeakRef widget;
    SZFriendsGtkPage *page;
    SZFriendsGtkDetailsReply func;
} SZFriendsGtkDetailsSend;

static void page_send_free(gpointer data) {
    SZFriendsGtkDetailsSend *send = data;
    g_weak_ref_clear(&send->widget);
    g_free(send);
}

static void page_send_reply(JsonObject *result, const SZFriendsGtkError *error, gpointer data) {
    SZFriendsGtkDetailsSend *send = data;
    GtkWidget *widget = g_weak_ref_get(&send->widget);
    if (!widget) return;
    send->func(send->page, result, error);
    g_object_unref(widget);
}

guint szfriends_gtk_details_send(SZFriendsGtkPage *page, szfriends_intent *intent, SZFriendsGtkDetailsReply func) {
    SZFriendsGtkLink *link = szfriends_gtk_page_get_link(page);
    if (!func) return szfriends_gtk_link_send(link, intent, NULL, NULL, NULL);
    SZFriendsGtkDetailsSend *send = g_new0(SZFriendsGtkDetailsSend, 1);
    g_weak_ref_init(&send->widget, szfriends_gtk_page_get_widget(page));
    send->page = page;
    send->func = func;
    return szfriends_gtk_link_send(link, intent, page_send_reply, send, page_send_free);
}
