/* Action buttons and a stranger's mention card (szfriends_gtk_conversation.h); the request card is in
 * szfriends_gtk_mention_card_request.c.
 *
 * Buttons mirror mac/SZFriendsArming.m: Block arms first (the label becomes the red "Block?" pill and sends nothing),
 * a second click within arm.seconds sends, and the pill turns back when the time runs out, on Escape or when the
 * pointer leaves it. The second half of a double-click never counts as that second click: the one arming rule and
 * clock every Block in the views shares (szfriends_gtk_arming_*, szfriends_gtk_row.h). Each button keeps copies of
 * what it sends, so a reply arriving after its item changed still finds them. */

#include "gtk/szfriends_gtk_conversation.h"
#include "gtk/szfriends_gtk_avatars.h"
#include "gtk/szfriends_gtk_row.h"

#include <string.h>

typedef struct {
    SZFriendsGtkConversation *conversation;
    GtkWidget *button; /* weak */
    SZFriendsGtkAction action;
    SZFriendsGtkArm arm;
    char *conversation_id, *transfer_id, *item_id;
    SZFriendsGtkActionDone done;
    gpointer data;
    GDestroyNotify destroy;
    SZFriendsGtkArming *arming;
    int n_press; /* of the press that started the current click; 1 for the keyboard */
} SZFriendsGtkActionButton;

static void action_button_release(gpointer data) {
    SZFriendsGtkActionButton *state = data;
    szfriends_gtk_arming_free(state->arming); /* cancels its timer: it must never reach a freed state */
    if (state->destroy) state->destroy(state->data);
    g_free(state->action.label);
    g_free(state->action.note);
    g_free(state->action.path);
    g_free(state->action.friends_id);
    g_free(state->action.identity_key);
    g_free(state->action.name);
    g_free(state->arm.label);
    g_free(state->arm.accessibility_label);
    g_free(state->conversation_id);
    g_free(state->transfer_id);
    g_free(state->item_id);
    szfriends_gtk_conversation_unref(state->conversation);
}

static void action_button_unref(gpointer data) {
    g_rc_box_release_full(data, action_button_release);
}

/* Called after the arming changed: the label, the accessible name and the style follow it. */
static void show_armed(SZFriendsGtkActionButton *state) {
    gboolean armed = szfriends_gtk_arming_is_armed(state->arming);
    if (!state->button) return;
    GtkWidget *button = state->button;
    gtk_button_set_label(GTK_BUTTON(button), armed && *state->arm.label ? state->arm.label : state->action.label);
    if (armed) {
        gtk_widget_add_css_class(button, "szfriends-armed");
        gtk_widget_set_tooltip_text(button, state->arm.accessibility_label);
        gtk_accessible_update_property(GTK_ACCESSIBLE(button), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                       state->arm.accessibility_label, -1);
        if (*state->arm.accessibility_label)
            gtk_accessible_announce(GTK_ACCESSIBLE(button), state->arm.accessibility_label,
                                    GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM);
        g_ptr_array_add(state->conversation->armed, button);
    } else {
        gtk_widget_remove_css_class(button, "szfriends-armed");
        gtk_widget_set_tooltip_text(button, state->action.note);
        gtk_accessible_reset_property(GTK_ACCESSIBLE(button), GTK_ACCESSIBLE_PROPERTY_LABEL);
        g_ptr_array_remove(state->conversation->armed, button);
    }
}

/* The arming's timer ran out: only the latest arming's timer exists, so an old one never turns a new pill back. */
static void expired(gpointer data) {
    show_armed(data);
}

static gboolean disarm(SZFriendsGtkActionButton *state) {
    if (!szfriends_gtk_arming_disarm(state->arming)) return FALSE;
    show_armed(state);
    return TRUE;
}

static void replied(JsonObject *result, const SZFriendsGtkError *error, gpointer data) {
    SZFriendsGtkActionButton *state = data;
    if (state->button) gtk_widget_set_sensitive(state->button, TRUE);
    /* The helper's words say what happened from the person's side; the next snapshot shows the new state. */
    if (error && error->message && *error->message && state->button)
        gtk_accessible_announce(GTK_ACCESSIBLE(state->button), error->message,
                                GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM);
    /* `done` speaks to what holds the button (a card): gone with the button, it hears nothing. */
    if (state->done && state->button && state->conversation->page)
        state->done(state->conversation, &state->action, result, error, state->data);
}

static void run(SZFriendsGtkActionButton *state) {
    SZFriendsGtkConversation *conversation = state->conversation;
    const SZFriendsGtkHost *host = szfriends_gtk_link_host(conversation->link);
    GtkWindow *window = conversation->dropdown ? szfriends_gtk_dropdown_get_window(conversation->dropdown) : NULL;
    gboolean open = state->action.action == SZFRIENDS_GTK_ACTION_OPEN_FILE;
    if (open || state->action.action == SZFRIENDS_GTK_ACTION_SHOW_FILE) {
        /* Received files open or show through the host, never the helper: Files reveals them in its own window. */
        void (*func)(gpointer, GtkWindow *, const char *) = open ? host->open_received_file : host->reveal_file;
        if (func && state->action.path && *state->action.path) func(host->host_data, window, state->action.path);
        if (state->done) state->done(conversation, &state->action, NULL, NULL, state->data);
        return;
    }
    SZFriendsGtkActionIds ids = {.conversation_id = state->conversation_id, .transfer_id = state->transfer_id,
                                 .item_id = state->item_id, .message_id = state->item_id};
    szfriends_intent *intent = szfriends_gtk_intent_for_action(&state->action, &ids);
    if (!intent) return;
    if (state->button) gtk_widget_set_sensitive(state->button, FALSE); /* one press, one intent */
    szfriends_gtk_link_send(conversation->link, intent, replied, g_rc_box_acquire(state), action_button_unref);
}

/* GtkButton's own gesture says nothing about the click count; this one, in the capture phase, only listens. */
static void pressed(GtkGestureClick *gesture, int n_press, double x, double y, gpointer data) {
    (void)gesture, (void)x, (void)y;
    ((SZFriendsGtkActionButton *)data)->n_press = n_press;
}

static void clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkActionButton *state = data;
    int n_press = state->n_press > 0 ? state->n_press : 1;
    state->n_press = 1; /* a keyboard activation has no press: one, now */
    if (state->action.arm && !szfriends_gtk_arming_is_armed(state->arming)) {
        szfriends_gtk_arming_arm(state->arming, (double)state->arm.seconds, expired, state);
        show_armed(state);
        return;
    }
    if (szfriends_gtk_arming_is_armed(state->arming)) {
        /* The second half of a double-click, or a click too quick to have read the pill: stay armed, send nothing. */
        if (!szfriends_gtk_arming_press_confirms(state->arming, n_press,
                                                 szfriends_gtk_double_click_us(GTK_WIDGET(button))))
            return;
        disarm(state);
    }
    run(state);
}

static void pointer_left(GtkEventControllerMotion *motion, gpointer data) {
    (void)motion;
    disarm(data); /* a "Block?" never waits for a click aimed at something else */
}

static void button_gone(gpointer data, GObject *where) {
    SZFriendsGtkActionButton *state = data;
    g_ptr_array_remove(state->conversation->armed, where);
    state->button = NULL;
    szfriends_gtk_arming_disarm(state->arming); /* and its timer with it */
}

static char *dup_or_null(const char *text) {
    return text ? g_strdup(text) : NULL;
}

GtkWidget *szfriends_gtk_action_button_new(SZFriendsGtkConversation *conversation, const SZFriendsGtkAction *action,
                                           const SZFriendsGtkActionIds *ids, SZFriendsGtkActionDone done,
                                           gpointer data, GDestroyNotify destroy) {
    SZFriendsGtkActionButton *state = g_rc_box_new0(SZFriendsGtkActionButton);
    state->conversation = szfriends_gtk_conversation_ref(conversation);
    state->arming = szfriends_gtk_arming_new();
    state->n_press = 1;
    state->action = *action;
    state->action.label = g_strdup(action->label);
    state->action.note = dup_or_null(action->note);
    state->action.path = dup_or_null(action->path);
    state->action.friends_id = dup_or_null(action->friends_id);
    state->action.identity_key = dup_or_null(action->identity_key);
    state->action.name = dup_or_null(action->name);
    state->action.confirm = NULL;
    if (action->arm) {
        state->arm = *action->arm;
        state->arm.label = g_strdup(action->arm->label);
        state->arm.accessibility_label = g_strdup(action->arm->accessibility_label);
        state->action.arm = &state->arm;
    }
    state->conversation_id = dup_or_null(ids ? ids->conversation_id : NULL);
    state->transfer_id = dup_or_null(ids ? ids->transfer_id : NULL);
    state->item_id = dup_or_null(ids ? ids->item_id : NULL);
    state->done = done, state->data = data, state->destroy = destroy;
    GtkWidget *button = gtk_button_new_with_label(action->label);
    state->button = button;
    g_object_weak_ref(G_OBJECT(button), button_gone, state);
    g_object_set_data_full(G_OBJECT(button), "szfriends-action", state, action_button_unref);
    switch (action->style) {
    case SZFRIENDS_GTK_STYLE_PRIMARY: gtk_widget_add_css_class(button, "suggested-action"); break;
    case SZFRIENDS_GTK_STYLE_DESTRUCTIVE: gtk_widget_add_css_class(button, "szfriends-destructive"); /* fall through */
    case SZFRIENDS_GTK_STYLE_LINK:
        gtk_widget_add_css_class(button, "flat");
        gtk_widget_add_css_class(button, "szfriends-link");
        break;
    default: break;
    }
    gtk_widget_set_tooltip_text(button, action->note);
    g_signal_connect(button, "clicked", G_CALLBACK(clicked), state);
    if (action->arm) {
        GtkGesture *gesture = gtk_gesture_click_new();
        gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(gesture), GTK_PHASE_CAPTURE);
        g_signal_connect(gesture, "pressed", G_CALLBACK(pressed), state);
        gtk_widget_add_controller(button, GTK_EVENT_CONTROLLER(gesture));
        GtkEventController *motion = gtk_event_controller_motion_new();
        g_signal_connect(motion, "leave", G_CALLBACK(pointer_left), state);
        gtk_widget_add_controller(button, motion);
    }
    return button;
}

gboolean szfriends_gtk_action_button_is_armed(GtkWidget *button) {
    SZFriendsGtkActionButton *state = button ? g_object_get_data(G_OBJECT(button), "szfriends-action") : NULL;
    return state && szfriends_gtk_arming_is_armed(state->arming);
}

const SZFriendsGtkAction *szfriends_gtk_action_button_action(GtkWidget *button) {
    SZFriendsGtkActionButton *state = button ? g_object_get_data(G_OBJECT(button), "szfriends-action") : NULL;
    return state ? &state->action : NULL;
}

/* What makes two actions the same button: what it does, how it looks and says, and the conversation it acts on. */
static char *action_key(const SZFriendsGtkAction *action, const SZFriendsGtkActionIds *ids) {
    return g_strdup_printf("%d|%d|%s|%s|%s", action->action, action->style, action->label,
                           action->arm ? action->arm->label : "", ids && ids->conversation_id ? ids->conversation_id
                                                                                              : "");
}

static void leave_parent(GtkWidget *button) {
    GtkWidget *parent = gtk_widget_get_parent(button);
    if (GTK_IS_BOX(parent)) gtk_box_remove(GTK_BOX(parent), button);
}

GPtrArray *szfriends_gtk_action_buttons_update(SZFriendsGtkConversation *conversation, GHashTable *keys,
                                               const SZFriendsGtkAction *actions, gsize n_actions,
                                               const SZFriendsGtkActionIds *ids, SZFriendsGtkActionDone done,
                                               gpointer data) {
    GHashTable *keep = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    GHashTableIter iter;
    gpointer button, key;
    g_hash_table_iter_init(&iter, keys);
    while (g_hash_table_iter_next(&iter, &button, &key)) g_hash_table_insert(keep, g_strdup(key), button);
    GPtrArray *wanted = g_ptr_array_new_with_free_func(g_object_unref);
    for (gsize i = 0; i < n_actions; i++) {
        if (!szfriends_gtk_item_shows_action(&actions[i], FALSE)) continue;
        char *wanted_key = action_key(&actions[i], ids);
        GtkWidget *existing = g_hash_table_lookup(keep, wanted_key);
        if (existing) {
            g_object_ref(existing);
            g_hash_table_remove(keep, wanted_key);
            g_free(wanted_key);
            leave_parent(existing);
        } else {
            existing = g_object_ref_sink(szfriends_gtk_action_button_new(conversation, &actions[i], ids, done, data,
                                                                         NULL));
            g_hash_table_insert(keys, existing, wanted_key);
        }
        g_ptr_array_add(wanted, existing);
    }
    g_hash_table_iter_init(&iter, keep);
    while (g_hash_table_iter_next(&iter, &key, &button)) {
        leave_parent(button);
        g_hash_table_remove(keys, button);
    }
    g_hash_table_unref(keep);
    return wanted;
}

gboolean szfriends_gtk_conversation_disarm(SZFriendsGtkConversation *conversation) {
    gboolean any = FALSE;
    while (conversation->armed->len) {
        GtkWidget *button = g_ptr_array_index(conversation->armed, 0);
        SZFriendsGtkActionButton *state = g_object_get_data(G_OBJECT(button), "szfriends-action");
        if (!state || !disarm(state)) g_ptr_array_remove_index(conversation->armed, 0);
        any = TRUE;
    }
    return any;
}

/* ---- A stranger's mention card ---------------------------------------------------------------------- */

/* WHY the name shows literally (as mac/SZFriendsMentionCard.m): it is the name the sender wrote for someone the
 * reader does not know, and the card is where the reader decides whether to add them, so a character that draws
 * nothing shows as its code point rather than hiding what the name really is (szfriends_gtk_mention_card_text.c).
 * The card follows new snapshots, as AppKit's does: the same mention, still a stranger's, updates in place ("Request
 * sent", "Blocked", an armed Block kept), and the card closes once the mention names a friend or nobody. */

static GtkWidget *card_label(const char *text, const char *css_class) {
    GtkWidget *label = gtk_label_new(text ? text : "");
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    if (css_class) gtk_widget_add_css_class(label, css_class);
    gtk_widget_set_visible(label, text && *text);
    return label;
}

static void set_card_label(GtkWidget *label, const char *text) {
    gtk_label_set_text(GTK_LABEL(label), text ? text : "");
    gtk_widget_set_visible(label, text && *text);
}

typedef struct {
    GtkWidget *title, *id, *status, *actions, *result; /* inside the card */
    GHashTable *keys;                                   /* button -> its action's key */
    char *item_id, *url, *label;                        /* the mention the card is for */
    char *signature;                                    /* the actions' keys as now shown */
    char *spent;    /* after Add: the signature then; those actions stay hidden while snapshots offer the same */
} SZFriendsGtkCardParts;

static void card_parts_free(gpointer data) {
    SZFriendsGtkCardParts *parts = data;
    g_hash_table_unref(parts->keys);
    g_free(parts->item_id);
    g_free(parts->url);
    g_free(parts->label);
    g_free(parts->signature);
    g_free(parts->spent);
    g_free(parts);
}

static void card_replied(SZFriendsGtkConversation *conversation, const SZFriendsGtkAction *action, JsonObject *result,
                         const SZFriendsGtkError *error, gpointer data) {
    GtkWidget *card = data;
    SZFriendsGtkCardParts *parts = g_object_get_data(G_OBJECT(card), "szfriends-card");
    if (!parts) return;
    if (!error && action->action != SZFRIENDS_GTK_ACTION_ADD_FROM_MENTION) {
        szfriends_gtk_conversation_close_popover(conversation); /* the snapshot after it shows the new state */
        return;
    }
    SZFriendsGtkAddByIdResult *added = !error && result ? szfriends_gtk_add_by_id_result_parse(result) : NULL;
    const char *message = error ? error->message : added ? added->message : NULL;
    if (!error) {
        /* What happens next, in the helper's words, under the buttons, which are spent. */
        g_free(parts->spent);
        parts->spent = g_strdup(parts->signature);
        gtk_widget_set_visible(parts->actions, FALSE);
    }
    if (error) gtk_widget_add_css_class(parts->result, "szfriends-failure");
    else gtk_widget_remove_css_class(parts->result, "szfriends-failure");
    if (message && *message) set_card_label(parts->result, message);
    if (added) szfriends_gtk_add_by_id_result_free(added);
}

static void card_apply(SZFriendsGtkConversation *conversation, GtkWidget *box, const SZFriendsGtkMention *mention) {
    SZFriendsGtkCardParts *parts = g_object_get_data(G_OBJECT(box), "szfriends-card");
    const SZFriendsGtkMentionCard *card = mention->card;
    GdkRGBA warning;
    gboolean coloured = szfriends_gtk_conversation_warning(conversation, &warning);
    PangoAttrList *attributes = NULL;
    char *title = szfriends_gtk_literal_text(card->title, -1, coloured ? &warning : NULL, &attributes);
    gtk_label_set_text(GTK_LABEL(parts->title), title);
    gtk_label_set_attributes(GTK_LABEL(parts->title), attributes);
    gtk_widget_set_visible(parts->title, *title);
    pango_attr_list_unref(attributes);
    g_free(title);
    set_card_label(parts->id, card->id_label);
    set_card_label(parts->status, card->status_label);
    SZFriendsGtkActionIds ids = {.conversation_id = card->conversation_id};
    GPtrArray *buttons = szfriends_gtk_action_buttons_update(conversation, parts->keys, card->actions, card->n_actions,
                                                            &ids, card_replied, box);
    GString *signature = g_string_new(NULL);
    for (guint i = 0; i < buttons->len; i++) {
        GtkWidget *button = g_ptr_array_index(buttons, i);
        g_string_append_printf(signature, "%s\n", (const char *)g_hash_table_lookup(parts->keys, button));
        gtk_box_append(GTK_BOX(parts->actions), button);
    }
    g_free(parts->signature);
    parts->signature = g_string_free(signature, FALSE);
    if (parts->spent && strcmp(parts->spent, parts->signature) != 0) g_clear_pointer(&parts->spent, g_free);
    gtk_widget_set_visible(parts->actions, buttons->len > 0 && !parts->spent);
    g_ptr_array_unref(buttons);
    gtk_accessible_update_property(GTK_ACCESSIBLE(box), GTK_ACCESSIBLE_PROPERTY_LABEL, card->title, -1);
}

GtkWidget *szfriends_gtk_mention_card_new(SZFriendsGtkConversation *conversation,
                                          const SZFriendsGtkConversationItem *item,
                                          const SZFriendsGtkMention *mention) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_add_css_class(box, "szfriends-mention-card");
    gtk_widget_set_size_request(box, 240, -1);
    SZFriendsGtkCardParts *parts = g_new0(SZFriendsGtkCardParts, 1);
    parts->keys = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, g_free);
    parts->item_id = g_strdup(item ? item->item_id : NULL);
    parts->url = g_strdup(mention->url);
    parts->label = g_strdup(mention->label);
    parts->title = card_label(NULL, "szfriends-card-title");
    parts->id = card_label(NULL, "szfriends-secondary");
    parts->status = card_label(NULL, "szfriends-secondary");
    parts->actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_top(parts->actions, 6);
    parts->result = card_label(NULL, "szfriends-secondary");
    for (GtkWidget *const *part = (GtkWidget *const[]){parts->title, parts->id, parts->status, parts->actions,
                                                       parts->result, NULL};
         *part; part++)
        gtk_box_append(GTK_BOX(box), *part);
    g_object_set_data_full(G_OBJECT(box), "szfriends-card", parts, card_parts_free);
    card_apply(conversation, box, mention);
    return box;
}

void szfriends_gtk_mention_card_follow(SZFriendsGtkConversation *conversation,
                                       const SZFriendsGtkConversationSnapshot *snapshot) {
    GtkWidget *popover = conversation->popover;
    GtkWidget *box = popover && GTK_IS_POPOVER(popover) ? gtk_popover_get_child(GTK_POPOVER(popover)) : NULL;
    SZFriendsGtkCardParts *parts = box ? g_object_get_data(G_OBJECT(box), "szfriends-card") : NULL;
    if (!parts) return;
    for (gsize i = 0; snapshot && i < snapshot->n_items; i++) {
        const SZFriendsGtkConversationItem *item = &snapshot->items[i];
        if (g_strcmp0(item->item_id, parts->item_id) != 0) continue;
        for (gsize m = 0; m < item->n_mentions; m++) {
            const SZFriendsGtkMention *mention = &item->mentions[m];
            if (g_strcmp0(mention->url, parts->url) != 0 || g_strcmp0(mention->label, parts->label) != 0) continue;
            if (mention->kind == SZFRIENDS_GTK_MENTION_STRANGER && mention->card) {
                card_apply(conversation, box, mention);
                return;
            }
        }
    }
    /* The mention now opens a conversation, or nothing, or its message went: the card has nothing left to say. */
    szfriends_gtk_conversation_close_popover(conversation);
}
