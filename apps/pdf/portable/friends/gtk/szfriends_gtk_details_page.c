/* A friend's details, opened from the conversation header (szfriends_gtk_details_page.h). Mirrors
 * mac/SZFriendsDetailsPage.m: who this is (avatar, route, ID with Copy and the Friends server's check), a changed key
 * first when there is one, verification with the comparison code, "Accept files from Mei automatically", received
 * files, then Remove and Block with their notes. The `details` subscription is held only while the page is on
 * screen. */

#include "gtk/szfriends_gtk_avatars.h"
#include "gtk/szfriends_gtk_details_page.h"
#include "gtk/szfriends_gtk_glyphs.h"

#include <adwaita.h>

typedef struct {
    SZFriendsGtkPage *page;
    guint token;
    SZFriendsGtkDetailsHeld *held; /* the snapshot on screen */
    GtkWidget *box, *avatar, *route_line, *route_glyph, *route, *id_label, *check, *copy, *confirmed;
    GtkWidget *key_card, *key_title, *key_body, *key_buttons;
    GtkWidget *verify_icon, *verify_label, *verify_body, *verify_code, *verify_buttons;
    GtkWidget *auto_title, *auto_body, *auto_switch;
    GtkWidget *received_row, *received_label, *received_buttons;
    GtkWidget *actions;
    gboolean applying; /* the switch is being set from a snapshot, not by the person */
} SZFriendsGtkDetails;

static const SZFriendsGtkDetailsSnapshot *shown(SZFriendsGtkDetails *details) {
    return szfriends_gtk_details_held_value(details->held);
}

static SZFriendsGtkActionIds ids_for(SZFriendsGtkDetails *details) {
    const SZFriendsGtkDetailsSnapshot *snapshot = shown(details);
    const char *conversation = snapshot && *snapshot->conversation_id ? snapshot->conversation_id
                                                                      : szfriends_gtk_page_get_argument(details->page);
    return (SZFriendsGtkActionIds){.conversation_id = conversation};
}

/* One slot per known action: its button, then its note when `notes`. When every action is the one already drawn,
 * nothing is rebuilt, so an armed "Block?" and keyboard focus survive a snapshot that changed something else. */
static void sync_actions(SZFriendsGtkDetails *details, GtkWidget *box, const SZFriendsGtkAction *actions, gsize n,
                         gboolean notes) {
    SZFriendsGtkActionIds ids = ids_for(details);
    gsize known = 0;
    gboolean same = TRUE;
    GtkWidget *slot = gtk_widget_get_first_child(box);
    for (gsize i = 0; i < n; i++) {
        if (!szfriends_gtk_action_is_known(actions[i].action)) continue;
        known++;
        GtkWidget *button = slot ? g_object_get_data(G_OBJECT(slot), "szfriends-button") : NULL;
        same = same && szfriends_gtk_details_button_matches(button, &actions[i], &ids);
        slot = slot ? gtk_widget_get_next_sibling(slot) : NULL;
    }
    if (same && !slot) {
        gtk_widget_set_visible(box, known > 0);
        return;
    }
    while ((slot = gtk_widget_get_first_child(box))) gtk_box_remove(GTK_BOX(box), slot);
    for (gsize i = 0; i < n; i++) {
        GtkWidget *button = szfriends_gtk_details_button_new(details->page, details->held, &actions[i], &ids);
        if (!button) continue;
        slot = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
        g_object_set_data(G_OBJECT(slot), "szfriends-button", button);
        gtk_box_append(GTK_BOX(slot), button);
        if (notes) {
            /* Body size, as AppKit draws what Remove and Block will do: the person reads this before deciding. The
             * text actions have no side padding, so the note starts under the button's first letter. */
            GtkWidget *note = szfriends_gtk_details_label("szfriends-secondary");
            szfriends_gtk_details_label_set(note, actions[i].note);
            gtk_box_append(GTK_BOX(slot), note);
        }
        gtk_box_append(GTK_BOX(box), slot);
    }
    gtk_widget_set_visible(box, known > 0);
}

static void set_route_style(GtkWidget *label, SZFriendsGtkRouteKind kind) {
    static const char *const classes[] = {"success", "accent", "szfriends-secondary"};
    for (gsize i = 0; i < G_N_ELEMENTS(classes); i++) gtk_widget_remove_css_class(label, classes[i]);
    /* The route colours of the list's route icons, in libadwaita's words: local green, online accent. */
    gtk_widget_add_css_class(label, kind == SZFRIENDS_GTK_ROUTE_LOCAL    ? "success"
                                    : kind == SZFRIENDS_GTK_ROUTE_ONLINE ? "accent"
                                                                         : "szfriends-secondary");
}

static void set_name(GtkWidget *widget, const char *name) {
    if (name && *name) {
        gtk_accessible_update_property(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_PROPERTY_LABEL, name, -1);
        gtk_widget_set_tooltip_text(widget, name);
    } else {
        gtk_accessible_reset_property(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_PROPERTY_LABEL);
        gtk_widget_set_tooltip_text(widget, NULL);
    }
}

static void apply(SZFriendsGtkDetails *details) {
    const SZFriendsGtkDetailsSnapshot *snapshot = shown(details);
    SZFriendsGtkPage *page = details->page;
    szfriends_gtk_page_set_title(page, snapshot->title, NULL);
    szfriends_gtk_page_set_back(page, &snapshot->back);
    szfriends_gtk_avatar_set(details->avatar, &snapshot->avatar);
    szfriends_gtk_details_label_set(details->route, snapshot->route.label);
    set_route_style(details->route, snapshot->route.kind);
    /* The route's icon before its words, in their colour, as the conversation header one step before shows it. */
    SZFriendsGtkGlyphKind glyph = szfriends_gtk_route_glyph(snapshot->route.kind, snapshot->route.method);
    gboolean has_route = gtk_widget_get_visible(details->route);
    szfriends_gtk_glyph_set_kind(details->route_glyph, glyph);
    set_route_style(details->route_glyph, snapshot->route.kind);
    gtk_widget_set_visible(details->route_glyph, has_route && glyph != SZFRIENDS_GTK_GLYPH_NONE);
    gtk_widget_set_visible(details->route_line, has_route);
    szfriends_gtk_details_label_set(details->id_label, snapshot->id_label);
    /* The check beside an ID the Friends server confirmed, with its meaning written under the ID line. */
    gboolean confirmed = snapshot->id_confirmed && snapshot->id_label && *snapshot->id_label;
    gtk_widget_set_visible(details->check, confirmed);
    set_name(details->check, confirmed ? snapshot->id_confirmed_label : NULL);
    szfriends_gtk_details_label_set(details->confirmed, confirmed ? snapshot->id_confirmed_label : NULL);
    gtk_widget_set_visible(details->copy, snapshot->friends_id && *snapshot->friends_id);
    set_name(details->copy, snapshot->copy_id_accessibility_label);

    const SZFriendsGtkKeyChange *key = snapshot->key_change;
    gtk_widget_set_visible(details->key_card, key != NULL);
    szfriends_gtk_details_label_set(details->key_title, key ? key->title : NULL);
    szfriends_gtk_details_label_set(details->key_body, key ? key->body : NULL);
    sync_actions(details, details->key_buttons, key ? key->actions : NULL, key ? key->n_actions : 0, FALSE);

    const SZFriendsGtkVerification *verification = &snapshot->verification;
    gboolean verified = verification->state == SZFRIENDS_GTK_VERIFIED;
    szfriends_gtk_details_label_set(details->verify_label, verification->label);
    if (verified) gtk_widget_add_css_class(details->verify_label, "success");
    else gtk_widget_remove_css_class(details->verify_label, "success");
    gtk_image_set_from_icon_name(GTK_IMAGE(details->verify_icon),
                                 verified ? "object-select-symbolic" : "help-about-symbolic");
    gtk_widget_add_css_class(details->verify_icon, verified ? "success" : "szfriends-secondary");
    gtk_widget_remove_css_class(details->verify_icon, verified ? "szfriends-secondary" : "success");
    gtk_widget_set_visible(details->verify_icon, verification->label && *verification->label);
    szfriends_gtk_details_label_set(details->verify_body, verification->body);
    szfriends_gtk_details_label_set(details->verify_code, verification->comparison_code);
    sync_actions(details, details->verify_buttons, verification->action, verification->action ? 1 : 0, FALSE);

    const SZFriendsGtkAutoAccept *automatic = &snapshot->auto_accept;
    szfriends_gtk_details_label_set(details->auto_title, automatic->title);
    szfriends_gtk_details_label_set(details->auto_body, automatic->body);
    details->applying = TRUE;
    gtk_switch_set_active(GTK_SWITCH(details->auto_switch), automatic->enabled);
    details->applying = FALSE;
    gtk_widget_set_sensitive(details->auto_switch, automatic->available);
    set_name(details->auto_switch, automatic->title);
    gtk_widget_set_tooltip_text(details->auto_switch, NULL);

    const SZFriendsGtkReceived *received = snapshot->received;
    szfriends_gtk_details_label_set(details->received_label, received ? received->label : NULL);
    sync_actions(details, details->received_buttons, received ? received->action : NULL,
                 received && received->action ? 1 : 0, FALSE);
    gtk_widget_set_visible(details->received_row, gtk_widget_get_visible(details->received_label) ||
                                                      gtk_widget_get_visible(details->received_buttons));
    sync_actions(details, details->actions, snapshot->actions, snapshot->n_actions, TRUE);
}

static void on_snapshot(JsonObject *data, gint64 rev, gpointer user_data) {
    (void)rev;
    SZFriendsGtkDetails *details = user_data;
    SZFriendsGtkDetailsHeld *previous = details->held;
    details->held = szfriends_gtk_details_held_new(&szfriends_gtk_type_details_snapshot,
                                           szfriends_gtk_details_snapshot_parse(data));
    apply(details);
    szfriends_gtk_details_held_unref(previous);
}

static void auto_accept_replied(SZFriendsGtkPage *page, JsonObject *result, const SZFriendsGtkError *error) {
    (void)result;
    SZFriendsGtkDetails *details = szfriends_gtk_page_get_data(page);
    /* The helper decides; a refused change goes back to what the snapshot says. */
    if (error && details->held) apply(details);
}

static void auto_accept_toggled(GObject *toggle, GParamSpec *pspec, gpointer data) {
    (void)pspec;
    SZFriendsGtkDetails *details = data;
    if (details->applying) return;
    SZFriendsGtkActionIds ids = ids_for(details);
    if (!ids.conversation_id) return;
    gboolean enabled = gtk_switch_get_active(GTK_SWITCH(toggle));
    szfriends_gtk_details_send(details->page, szfriends_intent_set_auto_accept(ids.conversation_id, enabled),
                            auto_accept_replied);
}

static void copy_clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkDetails *details = data;
    const SZFriendsGtkDetailsSnapshot *snapshot = shown(details);
    if (snapshot) szfriends_gtk_details_copy(details->page, GTK_WIDGET(button), snapshot->friends_id);
}

static GtkWidget *row(int spacing) {
    return gtk_box_new(GTK_ORIENTATION_HORIZONTAL, spacing);
}

static GtkWidget *column(int spacing) {
    return gtk_box_new(GTK_ORIENTATION_VERTICAL, spacing);
}

static GtkWidget *build_who(SZFriendsGtkDetails *details, SZFriendsGtkLink *link) {
    GtkWidget *who = row(12);
    details->avatar = szfriends_gtk_avatar_new(link, 48);
    gtk_widget_set_valign(details->avatar, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(who), details->avatar);
    GtkWidget *text = column(2);
    gtk_widget_set_valign(text, GTK_ALIGN_CENTER);
    details->route = szfriends_gtk_details_label(NULL);
    details->route_line = row(4);
    gtk_widget_set_name(details->route_line, "szfriends.details.route");
    details->route_glyph = szfriends_gtk_glyph_new(SZFRIENDS_GTK_GLYPH_NONE, 11);
    gtk_widget_set_valign(details->route_glyph, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(details->route_line), details->route_glyph);
    gtk_box_append(GTK_BOX(details->route_line), details->route);
    GtkWidget *id_line = row(2);
    details->id_label = szfriends_gtk_details_label("szfriends-secondary numeric");
    /* One line: an ID's words belong together (U+2011 already keeps them so), and the check and Copy follow it. */
    gtk_label_set_wrap(GTK_LABEL(details->id_label), FALSE);
    gtk_label_set_ellipsize(GTK_LABEL(details->id_label), PANGO_ELLIPSIZE_END);
    gtk_widget_set_hexpand(details->id_label, FALSE);
    details->check = gtk_image_new_from_icon_name("object-select-symbolic");
    gtk_image_set_pixel_size(GTK_IMAGE(details->check), 12);
    gtk_widget_add_css_class(details->check, "success");
    gtk_widget_set_visible(details->check, FALSE);
    /* A small glyph in a 24 px target, as the list's Copy, so it is easy to hit. */
    details->copy = gtk_button_new_from_icon_name("edit-copy-symbolic");
    gtk_widget_set_name(details->copy, "szfriends.details.copy");
    gtk_widget_add_css_class(details->copy, "flat");
    gtk_widget_add_css_class(details->copy, "circular");
    gtk_widget_set_size_request(details->copy, 24, 24);
    GtkWidget *glyph = gtk_button_get_child(GTK_BUTTON(details->copy));
    if (GTK_IS_IMAGE(glyph)) gtk_image_set_pixel_size(GTK_IMAGE(glyph), 12);
    gtk_widget_set_valign(details->copy, GTK_ALIGN_CENTER);
    g_signal_connect(details->copy, "clicked", G_CALLBACK(copy_clicked), details);
    gtk_box_append(GTK_BOX(id_line), details->id_label);
    gtk_box_append(GTK_BOX(id_line), details->check);
    gtk_box_append(GTK_BOX(id_line), details->copy);
    details->confirmed = szfriends_gtk_details_label("szfriends-caption");
    gtk_box_append(GTK_BOX(text), details->route_line);
    gtk_box_append(GTK_BOX(text), id_line);
    gtk_box_append(GTK_BOX(text), details->confirmed);
    gtk_box_append(GTK_BOX(who), text);
    return who;
}

/* A changed key is why the person came here (its row says so): its card leads, right under who this is. */
static GtkWidget *build_key_card(SZFriendsGtkDetails *details) {
    details->key_card = column(6);
    gtk_widget_add_css_class(details->key_card, "card");
    gtk_widget_set_name(details->key_card, "szfriends.details.key-change");
    GtkWidget *inner = column(6);
    gtk_widget_set_margin_top(inner, 12);
    gtk_widget_set_margin_bottom(inner, 12);
    gtk_widget_set_margin_start(inner, 12);
    gtk_widget_set_margin_end(inner, 12);
    GtkWidget *heading = row(8);
    GtkWidget *icon = gtk_image_new_from_icon_name("dialog-warning-symbolic");
    gtk_widget_add_css_class(icon, "warning");
    details->key_title = szfriends_gtk_details_label("heading");
    gtk_box_append(GTK_BOX(heading), icon);
    gtk_box_append(GTK_BOX(heading), details->key_title);
    details->key_body = szfriends_gtk_details_label(NULL);
    details->key_buttons = row(8);
    gtk_box_append(GTK_BOX(inner), heading);
    gtk_box_append(GTK_BOX(inner), details->key_body);
    gtk_box_append(GTK_BOX(inner), details->key_buttons);
    gtk_box_append(GTK_BOX(details->key_card), inner);
    gtk_widget_set_visible(details->key_card, FALSE);
    return details->key_card;
}

static GtkWidget *build_verification(SZFriendsGtkDetails *details) {
    GtkWidget *verify = row(8);
    details->verify_icon = gtk_image_new_from_icon_name("help-about-symbolic");
    gtk_widget_set_valign(details->verify_icon, GTK_ALIGN_START);
    gtk_widget_set_margin_top(details->verify_icon, 1);
    GtkWidget *text = column(4);
    details->verify_label = szfriends_gtk_details_label(NULL);
    details->verify_body = szfriends_gtk_details_label("szfriends-secondary");
    /* The code people read aloud to each other: large, with digits that line up. */
    details->verify_code = szfriends_gtk_details_label("title-2 numeric");
    details->verify_buttons = column(6);
    gtk_box_append(GTK_BOX(text), details->verify_label);
    gtk_box_append(GTK_BOX(text), details->verify_body);
    gtk_box_append(GTK_BOX(text), details->verify_code);
    gtk_box_append(GTK_BOX(text), details->verify_buttons);
    gtk_box_append(GTK_BOX(verify), details->verify_icon);
    gtk_box_append(GTK_BOX(verify), text);
    return verify;
}

static GtkWidget *build_auto_accept(SZFriendsGtkDetails *details) {
    GtkWidget *line = row(12);
    GtkWidget *text = column(4);
    details->auto_title = szfriends_gtk_details_label("heading");
    details->auto_body = szfriends_gtk_details_label("szfriends-secondary");
    gtk_box_append(GTK_BOX(text), details->auto_title);
    gtk_box_append(GTK_BOX(text), details->auto_body);
    details->auto_switch = gtk_switch_new();
    gtk_widget_set_name(details->auto_switch, "szfriends.details.auto-accept");
    gtk_widget_set_valign(details->auto_switch, GTK_ALIGN_START);
    g_signal_connect(details->auto_switch, "notify::active", G_CALLBACK(auto_accept_toggled), details);
    gtk_box_append(GTK_BOX(line), text);
    gtk_box_append(GTK_BOX(line), details->auto_switch);
    return line;
}

static void build(SZFriendsGtkPage *page, gpointer user_data) {
    (void)user_data;
    SZFriendsGtkDetails *details = g_new0(SZFriendsGtkDetails, 1);
    details->page = page;
    szfriends_gtk_page_set_data(page, details, g_free);
    SZFriendsGtkLink *link = szfriends_gtk_page_get_link(page);
    szfriends_gtk_list_style_ensure(szfriends_gtk_page_get_widget(page)); /* secondary text, text actions */
    details->box = column(14);
    gtk_widget_set_margin_top(details->box, 18);
    gtk_widget_set_margin_bottom(details->box, 18);
    gtk_widget_set_margin_start(details->box, 18);
    gtk_widget_set_margin_end(details->box, 18);
    gtk_box_append(GTK_BOX(details->box), build_who(details, link));
    gtk_box_append(GTK_BOX(details->box), build_key_card(details));
    gtk_box_append(GTK_BOX(details->box), build_verification(details));
    gtk_box_append(GTK_BOX(details->box), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    gtk_box_append(GTK_BOX(details->box), build_auto_accept(details));
    details->received_row = row(8);
    details->received_label = szfriends_gtk_details_label("szfriends-secondary");
    gtk_widget_set_valign(details->received_label, GTK_ALIGN_CENTER);
    details->received_buttons = row(0);
    gtk_box_append(GTK_BOX(details->received_row), details->received_label);
    gtk_box_append(GTK_BOX(details->received_row), details->received_buttons);
    gtk_widget_set_visible(details->received_row, FALSE);
    gtk_box_append(GTK_BOX(details->box), details->received_row);
    gtk_box_append(GTK_BOX(details->box), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    details->actions = column(12);
    gtk_widget_set_name(details->actions, "szfriends.details.actions");
    gtk_box_append(GTK_BOX(details->box), details->actions);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(scroll), TRUE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), details->box);
    gtk_widget_set_vexpand(scroll, TRUE);
    szfriends_gtk_page_set_content(page, scroll);
}

static void presented(SZFriendsGtkPage *page, gboolean presented, gpointer user_data) {
    (void)user_data;
    SZFriendsGtkDetails *details = szfriends_gtk_page_get_data(page);
    SZFriendsGtkLink *link = szfriends_gtk_page_get_link(page);
    if (presented && !details->token) {
        details->token = szfriends_gtk_link_subscribe(link, "details", szfriends_gtk_page_get_argument(page),
                                                      on_snapshot, details, NULL);
        /* A popover without autohide takes no focus by itself; Escape reaches the dropdown only from inside. */
        gtk_widget_grab_focus(details->box);
    } else if (!presented && details->token) {
        szfriends_gtk_link_unsubscribe(link, details->token);
        details->token = 0;
        /* Closed under an armed "Block?": it must not be waiting there, still armed, when the dropdown reopens. */
        szfriends_gtk_details_disarm(details->box);
    }
}

/* Escape turns an armed "Block?" back before it closes anything. */
static gboolean escape(SZFriendsGtkPage *page, gpointer user_data) {
    (void)user_data;
    SZFriendsGtkDetails *details = szfriends_gtk_page_get_data(page);
    return szfriends_gtk_details_disarm(details->box);
}

static void dispose(SZFriendsGtkPage *page, gpointer user_data) {
    (void)user_data;
    SZFriendsGtkDetails *details = szfriends_gtk_page_get_data(page);
    g_clear_pointer(&details->held, szfriends_gtk_details_held_unref);
}

void szfriends_gtk_details_page_register(SZFriendsGtkLink *link) {
    static const SZFriendsGtkPageClass klass = {build, presented, escape, dispose};
    szfriends_gtk_register_page(link, SZFRIENDS_GTK_PAGE_DETAILS, &klass, NULL);
}
