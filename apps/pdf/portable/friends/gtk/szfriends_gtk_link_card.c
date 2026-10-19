/* The link page, and what a host calls for links (szfriends_gtk.h § Links; PROTOCOL.md § Links). Mirrors
 * mac/SZFriendsLinkPage.m: open_link with the payload the host checked, then the helper's card (avatar, title,
 * subtitle, note, its actions) or its refusal's words. Nothing happens until the person presses one of the card's
 * actions; while the helper is not answering, the page waits and asks again once it does. */

#include "gtk/szfriends_gtk_avatars.h"
#include "gtk/szfriends_gtk_details_page.h"
#include "gtk/szfriends_gtk_internal.h"
#include "gtk/szfriends_gtk_link_private.h"

#include <string.h>

typedef struct {
    SZFriendsGtkPage *page;
    SZFriendsGtkOpenLinkResult *result; /* the card the buttons' actions live in */
    GtkWidget *avatar, *title, *subtitle, *note, *buttons, *message;
    guint watch;
    gboolean asked;
} SZFriendsGtkLinkCardPage;

static void ask(SZFriendsGtkLinkCardPage *card);

static void show_message(SZFriendsGtkLinkCardPage *card, const char *message, gboolean failed) {
    szfriends_gtk_details_label_set(card->message, message);
    if (failed) gtk_widget_add_css_class(card->message, "error");
    else gtk_widget_remove_css_class(card->message, "error");
    /* It appears where nothing had focus: assistive technology hears it too. */
    szfriends_gtk_details_announce(card->message, message);
}

static void clear_buttons(SZFriendsGtkLinkCardPage *card) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(card->buttons))) gtk_box_remove(GTK_BOX(card->buttons), child);
}

static void set_buttons_sensitive(SZFriendsGtkLinkCardPage *card, gboolean sensitive) {
    GtkWidget *child = gtk_widget_get_first_child(card->buttons);
    for (; child; child = gtk_widget_get_next_sibling(child)) gtk_widget_set_sensitive(child, sensitive);
}

/* A reply to the card's action, heard only while the page still exists. */
static void action_replied(JsonObject *result, const SZFriendsGtkError *error, gpointer data) {
    GWeakRef *ref = data;
    GtkWidget *widget = g_weak_ref_get(ref);
    SZFriendsGtkPage *page = szfriends_gtk_page_from_widget(widget);
    SZFriendsGtkLinkCardPage *card = page ? szfriends_gtk_page_get_data(page) : NULL;
    if (card && (result || error)) {
        set_buttons_sensitive(card, error != NULL);
        const char *message = error ? error->message
                                    : json_object_get_string_member_with_default(result, "message", NULL);
        show_message(card, message, error != NULL);
        /* The request or the incoming file lives in its conversation from now on, with its progress. */
        const char *conversation = result ? json_object_get_string_member_with_default(result, "conversation_id",
                                                                                       NULL) : NULL;
        SZFriendsGtkDropdown *dropdown = szfriends_gtk_page_get_dropdown(page);
        if (conversation && *conversation && dropdown)
            szfriends_gtk_dropdown_open_conversation(dropdown, conversation, NULL);
    }
    if (widget) g_object_unref(widget);
    g_weak_ref_clear(ref);
    g_free(ref);
}

static void action_clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkLinkCardPage *card = data;
    const SZFriendsGtkAction *action = g_object_get_data(G_OBJECT(button), "szfriends-action");
    if (!action) return;
    /* The buttons rest until the reply, so a double click asks once. */
    set_buttons_sensitive(card, FALSE);
    GWeakRef *ref = g_new0(GWeakRef, 1);
    g_weak_ref_init(ref, szfriends_gtk_page_get_widget(card->page));
    szfriends_gtk_perform(szfriends_gtk_page_get_link(card->page), szfriends_gtk_page_get_dropdown(card->page),
                          GTK_WIDGET(button), action, NULL, action_replied, ref); /* the reply frees `ref` */
}

static void apply_card(SZFriendsGtkLinkCardPage *card, SZFriendsGtkOpenLinkResult *result) {
    if (card->result) szfriends_gtk_value_free(&szfriends_gtk_type_open_link_result, card->result);
    card->result = result;
    const SZFriendsGtkLinkCard *shown = &result->card;
    if (shown->avatar) szfriends_gtk_avatar_set(card->avatar, shown->avatar);
    gtk_widget_set_visible(card->avatar, shown->avatar != NULL);
    szfriends_gtk_details_label_set(card->title, shown->title);
    szfriends_gtk_details_label_set(card->subtitle, shown->subtitle);
    szfriends_gtk_details_label_set(card->note, shown->note);
    szfriends_gtk_page_set_name(card->page, shown->title);
    clear_buttons(card);
    for (gsize i = 0; i < shown->n_actions; i++) {
        const SZFriendsGtkAction *action = &shown->actions[i];
        if (!szfriends_gtk_action_is_known(action->action) || !*action->label) continue;
        GtkWidget *button = gtk_button_new_with_label(action->label);
        gtk_widget_set_name(button, "szfriends.link.action");
        gtk_widget_set_size_request(button, 96, -1);
        if (action->style == SZFRIENDS_GTK_STYLE_PRIMARY) gtk_widget_add_css_class(button, "suggested-action");
        g_object_set_data(G_OBJECT(button), "szfriends-action", (gpointer)action);
        g_signal_connect(button, "clicked", G_CALLBACK(action_clicked), card);
        gtk_box_append(GTK_BOX(card->buttons), button);
    }
    gtk_widget_set_visible(card->buttons, gtk_widget_get_first_child(card->buttons) != NULL);
    show_message(card, NULL, FALSE);
}

static void apply_refusal(SZFriendsGtkLinkCardPage *card, const char *message) {
    gtk_widget_set_visible(card->avatar, FALSE);
    for (GtkWidget **label = (GtkWidget *[]){card->title, card->subtitle, card->note, NULL}; *label; label++)
        szfriends_gtk_details_label_set(*label, NULL);
    clear_buttons(card);
    gtk_widget_set_visible(card->buttons, FALSE);
    show_message(card, message, TRUE);
}

static void state_changed(SZFriendsGtkLink *link, SZFriendsGtkLinkState state, gpointer data) {
    SZFriendsGtkLinkCardPage *card = data;
    if (state != SZFRIENDS_GTK_LINK_READY || !card->watch) return;
    szfriends_gtk_link_remove_state_watch(link, card->watch);
    card->watch = 0;
    ask(card);
}

static void answered(SZFriendsGtkPage *page, JsonObject *result, const SZFriendsGtkError *error) {
    SZFriendsGtkLinkCardPage *card = szfriends_gtk_page_get_data(page);
    SZFriendsGtkLink *link = szfriends_gtk_page_get_link(page);
    if (error && (!g_strcmp0(error->code, "not_ready") || !g_strcmp0(error->code, "connection_lost"))) {
        /* The helper is starting or handing over: the dropdown's line says so, and the link is asked about again
         * as soon as it answers, so the person never has to open the link twice. */
        if (szfriends_gtk_link_get_state(link) == SZFRIENDS_GTK_LINK_READY) ask(card);
        else if (!card->watch) card->watch = szfriends_gtk_link_add_state_watch(link, state_changed, card, NULL);
        return;
    }
    if (error) apply_refusal(card, error->message);
    else apply_card(card, szfriends_gtk_open_link_result_parse(result));
}

static void ask(SZFriendsGtkLinkCardPage *card) {
    card->asked = TRUE;
    szfriends_gtk_details_send(card->page, szfriends_intent_open_link(szfriends_gtk_page_get_argument(card->page)),
                               answered);
}

static GtkWidget *centered(GtkWidget *label) {
    gtk_label_set_justify(GTK_LABEL(label), GTK_JUSTIFY_CENTER);
    gtk_label_set_xalign(GTK_LABEL(label), 0.5f);
    return label;
}

static void build(SZFriendsGtkPage *page, gpointer user_data) {
    (void)user_data;
    SZFriendsGtkLinkCardPage *card = g_new0(SZFriendsGtkLinkCardPage, 1);
    card->page = page;
    szfriends_gtk_page_set_data(page, card, g_free);
    szfriends_gtk_list_style_ensure(szfriends_gtk_page_get_widget(page));
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_margin_top(box, 20);
    gtk_widget_set_margin_start(box, 24);
    gtk_widget_set_margin_end(box, 24);
    gtk_widget_set_valign(box, GTK_ALIGN_START);
    card->avatar = szfriends_gtk_avatar_new(szfriends_gtk_page_get_link(page), 56);
    gtk_widget_set_halign(card->avatar, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_bottom(card->avatar, 6);
    gtk_widget_set_visible(card->avatar, FALSE);
    card->title = centered(szfriends_gtk_details_label("title-3"));
    card->subtitle = centered(szfriends_gtk_details_label("szfriends-secondary"));
    card->note = centered(szfriends_gtk_details_label("szfriends-secondary"));
    card->buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_halign(card->buttons, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_top(card->buttons, 12);
    gtk_widget_set_visible(card->buttons, FALSE);
    card->message = centered(szfriends_gtk_details_label(NULL));
    gtk_widget_set_name(card->message, "szfriends.link.message");
    gtk_widget_set_margin_top(card->message, 6);
    for (GtkWidget **child = (GtkWidget *[]){card->avatar, card->title, card->subtitle, card->note, card->buttons,
                                            card->message, NULL};
         *child; child++)
        gtk_box_append(GTK_BOX(box), *child);
    szfriends_gtk_page_set_content(page, box);
}

static void presented(SZFriendsGtkPage *page, gboolean presented, gpointer user_data) {
    (void)user_data;
    SZFriendsGtkLinkCardPage *card = szfriends_gtk_page_get_data(page);
    if (presented && !card->asked) ask(card);
}

static void dispose(SZFriendsGtkPage *page, gpointer user_data) {
    (void)user_data;
    SZFriendsGtkLinkCardPage *card = szfriends_gtk_page_get_data(page);
    if (card->watch) szfriends_gtk_link_remove_state_watch(szfriends_gtk_page_get_link(page), card->watch);
    card->watch = 0;
    if (card->result) szfriends_gtk_value_free(&szfriends_gtk_type_open_link_result, card->result);
    card->result = NULL;
}

void szfriends_gtk_link_card_register(SZFriendsGtkLink *link) {
    static const SZFriendsGtkPageClass klass = {build, presented, NULL, dispose};
    szfriends_gtk_register_page(link, SZFRIENDS_GTK_PAGE_LINK, &klass, NULL);
}

/* ---- For hosts ------------------------------------------------------------------------------------------- */

gboolean szfriends_gtk_link_offers_links(SZFriendsGtkLink *link) {
    return link && szfriends_gtk_link_get_state(link) == SZFRIENDS_GTK_LINK_READY &&
           szfriends_gtk_link_helper_has_capability(link, "links");
}

void szfriends_gtk_show_link(SZFriendsGtkLink *link, GtkWindow *window, const char *payload) {
    if (!link || !payload || !*payload) return;
    SZFriendsGtkDropdown *dropdown = szfriends_gtk_dropdown_for_button(szfriends_gtk_link_window_button(link, window));
    if (!dropdown) return;
    szfriends_gtk_dropdown_open(dropdown);
    szfriends_gtk_dropdown_open_link(dropdown, payload);
}

typedef struct {
    GWeakRef source;
    SZFriendsGtkLinkCopied done;
    gpointer data;
} SZFriendsGtkCopying;

static void copy_replied(JsonObject *result, const SZFriendsGtkError *error, gpointer data) {
    SZFriendsGtkCopying *copying = data;
    SZFriendsGtkDownloadLinkResult *link = result ? szfriends_gtk_download_link_result_parse(result) : NULL;
    GtkWidget *source = g_weak_ref_get(&copying->source);
    gboolean copied = link && *link->url && source;
    if (copied) szfriends_gtk_copy_text(source, link->url);
    if (copying->done) copying->done(copied ? link->message : error ? error->message : NULL, copied, copying->data);
    if (link) szfriends_gtk_download_link_result_free(link);
    if (source) g_object_unref(source);
}

static void copying_free(gpointer data) {
    SZFriendsGtkCopying *copying = data;
    g_weak_ref_clear(&copying->source);
    g_free(copying);
}

void szfriends_gtk_copy_download_link(SZFriendsGtkLink *link, GtkWidget *source, const SZFriendsGtkHostItem *item,
                                      int days, SZFriendsGtkLinkCopied done, gpointer data) {
    SZFriendsGtkFile *file = item ? szfriends_gtk_file_new(item) : NULL;
    SZFriendsGtkCopying *copying = g_new0(SZFriendsGtkCopying, 1);
    g_weak_ref_init(&copying->source, source);
    copying->done = done;
    copying->data = data;
    szfriends_gtk_link_send(link, file ? szfriends_intent_make_download_link(&file->file, days) : NULL, copy_replied,
                            copying, copying_free);
    if (file) szfriends_gtk_file_free(file);
}
