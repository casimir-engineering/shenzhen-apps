/* The request card (szfriends_gtk_conversation.h): what a pending request's conversation shows in place of the
 * history and the composer, as mac/SZFriendsRequestCard does. Avatar, name, the comparison code both screens show,
 * Accept and Decline side by side, Cancel request and Block each on a line of their own, and the footnote. */

#include "gtk/szfriends_gtk_conversation.h"
#include "gtk/szfriends_gtk_avatars.h"

typedef struct {
    SZFriendsGtkConversation *conversation;
    GtkWidget *avatar, *title, *subtitle, *prompt, *code, *buttons, *links, *footnote;
    GHashTable *keys; /* button -> the action it was made for, so unchanged ones keep an armed pill */
} SZFriendsGtkRequestParts;

static void request_parts_free(gpointer data) {
    SZFriendsGtkRequestParts *parts = data;
    g_hash_table_unref(parts->keys);
    szfriends_gtk_conversation_unref(parts->conversation);
    g_free(parts);
}

static GtkWidget *centred_label(const char *css_class) {
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_justify(GTK_LABEL(label), GTK_JUSTIFY_CENTER);
    if (css_class) gtk_widget_add_css_class(label, css_class);
    gtk_widget_set_visible(label, FALSE);
    return label;
}

GtkWidget *szfriends_gtk_request_card_new(SZFriendsGtkConversation *conversation) {
    SZFriendsGtkRequestParts *parts = g_new0(SZFriendsGtkRequestParts, 1);
    parts->conversation = szfriends_gtk_conversation_ref(conversation);
    parts->keys = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, g_free);
    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_add_css_class(card, "szfriends-request-card");
    parts->avatar = szfriends_gtk_avatar_new(conversation->link, 64);
    gtk_widget_set_halign(parts->avatar, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_bottom(parts->avatar, 12);
    gtk_box_append(GTK_BOX(card), parts->avatar);
    parts->title = centred_label("szfriends-request-title");
    parts->subtitle = centred_label("szfriends-secondary");
    gtk_box_append(GTK_BOX(card), parts->title);
    gtk_box_append(GTK_BOX(card), parts->subtitle);
    GtkWidget *code_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_add_css_class(code_box, "szfriends-code-box");
    parts->prompt = centred_label(NULL);
    parts->code = centred_label("szfriends-code");
    gtk_box_append(GTK_BOX(code_box), parts->prompt);
    gtk_box_append(GTK_BOX(code_box), parts->code);
    gtk_box_append(GTK_BOX(card), code_box);
    parts->buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_widget_set_halign(parts->buttons, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_top(parts->buttons, 12);
    parts->links = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_halign(parts->links, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(card), parts->buttons);
    gtk_box_append(GTK_BOX(card), parts->links);
    GtkWidget *space = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0); /* the footnote sits at the card's foot */
    gtk_widget_set_vexpand(space, TRUE);
    gtk_box_append(GTK_BOX(card), space);
    parts->footnote = centred_label("szfriends-secondary");
    gtk_box_append(GTK_BOX(card), parts->footnote);
    g_object_set_data_full(G_OBJECT(card), "szfriends-request", parts, request_parts_free);
    return card;
}

static void set_label(GtkWidget *label, const char *text) {
    gtk_label_set_text(GTK_LABEL(label), text ? text : "");
    gtk_widget_set_visible(label, text && *text);
}

void szfriends_gtk_request_card_apply(GtkWidget *card, const SZFriendsGtkRequestCard *request) {
    SZFriendsGtkRequestParts *parts = g_object_get_data(G_OBJECT(card), "szfriends-request");
    if (!parts || !request) return;
    szfriends_gtk_avatar_set(parts->avatar, &request->avatar);
    set_label(parts->title, request->title);
    set_label(parts->subtitle, request->subtitle);
    set_label(parts->prompt, request->code_prompt);
    set_label(parts->code, request->comparison_code);
    /* Letter-spaced, tabular digits, so both people read the code at the same rhythm; the digits are untouched. */
    PangoAttrList *attributes = pango_attr_list_new();
    pango_attr_list_insert(attributes, pango_attr_letter_spacing_new(3 * PANGO_SCALE));
    pango_attr_list_insert(attributes, pango_attr_font_features_new("tnum 1"));
    gtk_label_set_attributes(GTK_LABEL(parts->code), attributes);
    pango_attr_list_unref(attributes);
    if (request->comparison_code_accessibility_label)
        gtk_accessible_update_property(GTK_ACCESSIBLE(parts->code), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                       request->comparison_code_accessibility_label, -1);
    set_label(parts->footnote, request->footnote);
    SZFriendsGtkActionIds ids = {.conversation_id = parts->conversation->conversation_id};
    GPtrArray *wanted = szfriends_gtk_action_buttons_update(parts->conversation, parts->keys, request->actions,
                                                           request->n_actions, &ids, NULL, NULL);
    /* Accept and Decline side by side; Cancel request and Block each on a line of their own under them. */
    for (guint i = 0; i < wanted->len; i++) {
        GtkWidget *widget = g_ptr_array_index(wanted, i);
        const SZFriendsGtkAction *action = szfriends_gtk_action_button_action(widget);
        gboolean in_row = action && (action->style == SZFRIENDS_GTK_STYLE_PRIMARY ||
                                     action->style == SZFRIENDS_GTK_STYLE_SECONDARY);
        if (in_row) gtk_widget_set_size_request(widget, 84, -1);
        gtk_box_append(GTK_BOX(in_row ? parts->buttons : parts->links), widget);
    }
    gtk_widget_set_visible(parts->buttons, gtk_widget_get_first_child(parts->buttons) != NULL);
    gtk_widget_set_visible(parts->links, gtk_widget_get_first_child(parts->links) != NULL);
    g_ptr_array_unref(wanted);
}
