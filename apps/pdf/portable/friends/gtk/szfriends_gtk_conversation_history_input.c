/* The person's hands on the history (szfriends_gtk_conversation_history_private.h): presses on its rows, which hold
 * the rows still until the release; their own scrolling, told apart from the list view's moves so only theirs takes
 * the history off its end; and drops, sent at once, one offer per file (brief § Interface, drag and drop). */

#include "gtk/szfriends_gtk_conversation_history_private.h"

#include <string.h>

/* ---- Scrolling ------------------------------------------------------------------------------------------ */

gboolean szfriends_gtk_history_person_moving(SZFriendsGtkHistory *history) {
    return history->scrollbar_held || g_get_monotonic_time() - history->keyed_at < G_USEC_PER_SEC / 2;
}

static gboolean wheel(GtkEventControllerScroll *controller, double dx, double dy, gpointer data) {
    (void)controller, (void)dx;
    if (dy < 0) ((SZFriendsGtkHistory *)data)->following = FALSE; /* up, away from the end */
    return FALSE;
}

static gboolean key_down(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state,
                         gpointer data) {
    (void)controller, (void)keyval, (void)keycode, (void)state;
    ((SZFriendsGtkHistory *)data)->keyed_at = g_get_monotonic_time();
    return FALSE;
}

static gboolean scrollbar_event(GtkEventControllerLegacy *controller, GdkEvent *event, gpointer data) {
    (void)controller;
    GdkEventType type = gdk_event_get_event_type(event);
    if (type == GDK_BUTTON_PRESS || type == GDK_TOUCH_BEGIN) ((SZFriendsGtkHistory *)data)->scrollbar_held = TRUE;
    else if (type == GDK_BUTTON_RELEASE || type == GDK_TOUCH_END || type == GDK_TOUCH_CANCEL)
        ((SZFriendsGtkHistory *)data)->scrollbar_held = FALSE;
    return GDK_EVENT_PROPAGATE;
}

/* ---- Drops: sent at once, one offer per file ----------------------------------------------------------- */

static void show_verdict(SZFriendsGtkHistory *history, SZFriendsGtkDropVerdict verdict) {
    history->verdict = verdict;
    const char *refusal = szfriends_gtk_drop_refusal(history->conversation->link, verdict);
    gtk_label_set_text(GTK_LABEL(history->drop_words), refusal);
    gtk_widget_set_visible(history->drop_words, *refusal);
    if (szfriends_gtk_drop_refused(verdict)) gtk_widget_add_css_class(history->drop_mark, "szfriends-refuse");
    else gtk_widget_remove_css_class(history->drop_mark, "szfriends-refuse");
    gtk_widget_set_visible(history->drop_mark, verdict != SZFRIENDS_GTK_DROP_NONE);
}

void szfriends_gtk_history_drag_value(SZFriendsGtkHistory *history, const GValue *value) {
    const SZFriendsGtkHost *host = szfriends_gtk_link_host(history->conversation->link);
    show_verdict(history, value && history->accepts_drops ? szfriends_gtk_drop_verdict(host, value)
                                                          : SZFRIENDS_GTK_DROP_NONE);
}

gboolean szfriends_gtk_history_drop(SZFriendsGtkHistory *history, const GValue *value) {
    SZFriendsGtkConversation *conversation = history->conversation;
    SZFriendsGtkDropVerdict verdict = SZFRIENDS_GTK_DROP_NONE;
    GPtrArray *items = szfriends_gtk_drop_items(szfriends_gtk_link_host(conversation->link), value, &verdict);
    show_verdict(history, SZFRIENDS_GTK_DROP_NONE);
    gboolean taken = history->accepts_drops && verdict == SZFRIENDS_GTK_DROP_ACCEPT && items->len;
    if (taken)
        szfriends_gtk_link_send(conversation->link,
                                szfriends_gtk_intent_send_items(conversation->conversation_id, items, NULL), NULL,
                                NULL, NULL);
    g_ptr_array_unref(items);
    return taken;
}

static gboolean drop_accept(GtkDropTarget *target, GdkDrop *drop, gpointer data) {
    SZFriendsGtkHistory *history = data;
    return history->accepts_drops &&
           gdk_content_formats_match(gtk_drop_target_get_formats(target), gdk_drop_get_formats(drop));
}

static void drop_value(GObject *target, GParamSpec *spec, gpointer data) {
    (void)spec;
    szfriends_gtk_history_drag_value(data, gtk_drop_target_get_value(GTK_DROP_TARGET(target)));
}

static GdkDragAction drop_motion(GtkDropTarget *target, double x, double y, gpointer data) {
    (void)target, (void)x, (void)y;
    return szfriends_gtk_drop_refused(((SZFriendsGtkHistory *)data)->verdict) ? 0 : GDK_ACTION_COPY;
}

static void drop_leave(GtkDropTarget *target, gpointer data) {
    (void)target;
    show_verdict(data, SZFRIENDS_GTK_DROP_NONE);
}

static gboolean dropped(GtkDropTarget *target, const GValue *value, double x, double y, gpointer data) {
    (void)target, (void)x, (void)y;
    return szfriends_gtk_history_drop(data, value);
}

/* ---- Presses ------------------------------------------------------------------------------------------- */

/* After the release has reached the row's button (its click runs first), each row held back takes its latest item. */
static gboolean flush_held(gpointer data) {
    SZFriendsGtkHistory *history = data;
    history->held_flush = 0;
    JsonObject *held = history->held_data;
    history->held_data = NULL;
    if (history->pressed || !held) {
        if (held) json_object_unref(held);
        return G_SOURCE_REMOVE;
    }
    JsonArray *items = json_object_has_member(held, "items") &&
                               JSON_NODE_HOLDS_ARRAY(json_object_get_member(held, "items"))
                           ? json_object_get_array_member(held, "items") : NULL;
    GHashTable *latest = g_hash_table_new_full(g_str_hash, g_str_equal, NULL, g_object_unref);
    for (guint i = 0; items && i < json_array_get_length(items); i++) {
        JsonNode *node = json_array_get_element(items, i);
        if (!JSON_NODE_HOLDS_OBJECT(node)) continue;
        GObject *fresh = szfriends_gtk_history_holder_new(json_node_get_object(node));
        g_hash_table_replace(latest, g_object_get_data(fresh, "szfriends-key"), fresh);
    }
    for (guint i = 0; i < g_list_model_get_n_items(G_LIST_MODEL(history->store)); i++) {
        GObject *kept = g_list_model_get_item(G_LIST_MODEL(history->store), i);
        g_object_unref(kept); /* the store keeps it */
        const char *key = g_object_get_data(kept, "szfriends-key");
        GObject *fresh = key ? g_hash_table_lookup(latest, key) : NULL;
        if (fresh && strcmp(g_object_get_data(kept, "szfriends-fingerprint"),
                            g_object_get_data(fresh, "szfriends-fingerprint")) != 0)
            g_list_store_splice(history->store, i, 1, (gpointer *)&fresh, 1);
    }
    g_hash_table_unref(latest);
    json_object_unref(held);
    return G_SOURCE_REMOVE;
}

static void press_ended(SZFriendsGtkHistory *history) {
    history->pressed = FALSE;
    if (history->press_limit) g_source_remove(history->press_limit);
    history->press_limit = 0;
    if (!history->held_flush) history->held_flush = g_idle_add(flush_held, history);
}

/* A press whose release never comes (a grab taken elsewhere) holds the rows 10 seconds at most. */
static gboolean press_too_long(gpointer data) {
    SZFriendsGtkHistory *history = data;
    history->press_limit = 0;
    press_ended(history);
    return G_SOURCE_REMOVE;
}

static gboolean pointer_event(GtkEventControllerLegacy *controller, GdkEvent *event, gpointer data) {
    (void)controller;
    SZFriendsGtkHistory *history = data;
    switch (gdk_event_get_event_type(event)) {
    case GDK_BUTTON_PRESS:
    case GDK_TOUCH_BEGIN:
        history->pressed = TRUE;
        if (history->press_limit) g_source_remove(history->press_limit);
        history->press_limit = g_timeout_add_seconds(10, press_too_long, history);
        break;
    case GDK_BUTTON_RELEASE:
    case GDK_TOUCH_END:
    case GDK_TOUCH_CANCEL:
        if (history->pressed) press_ended(history);
        break;
    default:
        break;
    }
    return GDK_EVENT_PROPAGATE;
}

/* ---- Watching ------------------------------------------------------------------------------------------- */

void szfriends_gtk_history_watch(SZFriendsGtkHistory *history) {
    /* Sees every press and release on the rows before their buttons do, and lets them through. */
    GtkEventController *presses = gtk_event_controller_legacy_new();
    gtk_event_controller_set_propagation_phase(presses, GTK_PHASE_CAPTURE);
    g_signal_connect(presses, "event", G_CALLBACK(pointer_event), history);
    gtk_widget_add_controller(history->list_view, presses);
    /* The person's own scrolling, told apart from the list view's (scrolled). */
    GtkEventController *wheels = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL);
    gtk_event_controller_set_propagation_phase(wheels, GTK_PHASE_CAPTURE);
    g_signal_connect(wheels, "scroll", G_CALLBACK(wheel), history);
    gtk_widget_add_controller(history->scroller, wheels);
    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(key_down), history);
    gtk_widget_add_controller(history->scroller, keys);
    GtkEventController *bar = gtk_event_controller_legacy_new();
    gtk_event_controller_set_propagation_phase(bar, GTK_PHASE_CAPTURE);
    g_signal_connect(bar, "event", G_CALLBACK(scrollbar_event), history);
    gtk_widget_add_controller(gtk_scrolled_window_get_vscrollbar(GTK_SCROLLED_WINDOW(history->scroller)), bar);
    gsize n_types = 0;
    GType *types = szfriends_gtk_drop_types(szfriends_gtk_link_host(history->conversation->link), &n_types);
    GtkDropTarget *drop = gtk_drop_target_new(G_TYPE_INVALID, GDK_ACTION_COPY);
    gtk_drop_target_set_gtypes(drop, types, n_types);
    gtk_drop_target_set_preload(drop, TRUE);
    g_free(types);
    g_signal_connect(drop, "accept", G_CALLBACK(drop_accept), history);
    g_signal_connect(drop, "notify::value", G_CALLBACK(drop_value), history);
    g_signal_connect(drop, "motion", G_CALLBACK(drop_motion), history);
    g_signal_connect(drop, "leave", G_CALLBACK(drop_leave), history);
    g_signal_connect(drop, "drop", G_CALLBACK(dropped), history);
    gtk_widget_add_controller(history->root, GTK_EVENT_CONTROLLER(drop));
}
