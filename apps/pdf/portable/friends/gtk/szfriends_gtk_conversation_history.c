/* The history (szfriends_gtk_conversation.h): items oldest to newest in a GtkListView, Show earlier messages above
 * them while the helper has more, and the conversation's drop target, where dropped files are sent at once, one offer
 * per file (brief § Interface, drag and drop).
 *
 * Rows are kept by item id and content between snapshots, and only the run that changed is spliced, so a progress
 * tick rebuilds one card rather than the history. A history that ends at the bottom stays there as items arrive; one
 * scrolled up stays where the person left it; earlier items arriving above keep the visible ones in place. */

#include "gtk/szfriends_gtk_conversation.h"
#include "gtk/szfriends_gtk_schema.h"

#include <string.h>

struct _SZFriendsGtkHistory {
    SZFriendsGtkConversation *conversation;
    GtkWidget *root, *scroller, *list_view, *drop_mark, *drop_words;
    GListStore *store;
    guint subscription;
    gboolean has_earlier, loading_earlier, accepts_drops;
    gboolean pending_bottom; /* scroll to the end once the list knows its size */
    double last_value;
    char *scrolled_highlight;
    SZFriendsGtkDropVerdict verdict;
};

static const SZFriendsGtkType *item_type(void) {
    static const SZFriendsGtkType *type;
    for (const SZFriendsGtkType *const *t = szfriends_gtk_named_types; !type && *t; t++)
        if ((*t)->name && strcmp((*t)->name, "type.item") == 0) type = *t;
    return type;
}

static void item_free(gpointer item) {
    szfriends_gtk_value_free(item_type(), item);
}

GObject *szfriends_gtk_history_holder_new(JsonObject *item_json) {
    GObject *holder = g_object_new(G_TYPE_OBJECT, NULL);
    SZFriendsGtkConversationItem *item = szfriends_gtk_value_parse(item_type(), item_json);
    JsonNode *node = json_node_init_object(json_node_alloc(), item_json);
    g_object_set_data_full(holder, "szfriends-fingerprint", json_to_string(node, FALSE), g_free);
    json_node_unref(node);
    g_object_set_data_full(holder, "szfriends-key", g_strdup_printf("%d:%s", item->kind, item->item_id), g_free);
    g_object_set_data_full(holder, "szfriends-item", item, item_free);
    return holder;
}

const SZFriendsGtkConversationItem *szfriends_gtk_history_item(GObject *holder) {
    return holder ? g_object_get_data(holder, "szfriends-item") : NULL;
}

/* ---- Rows ---------------------------------------------------------------------------------------------- */

static void load_earlier(SZFriendsGtkHistory *history) {
    if (!history->subscription || history->loading_earlier || !history->has_earlier) return;
    history->loading_earlier = TRUE; /* once, until the next 200 items arrive */
    szfriends_gtk_link_load_earlier(history->conversation->link, history->subscription);
}

static void earlier_clicked(GtkButton *button, gpointer data) {
    load_earlier(data);
    gtk_widget_set_sensitive(GTK_WIDGET(button), FALSE);
}

static void row_setup(GtkSignalListItemFactory *factory, GtkListItem *list_item, gpointer data) {
    (void)factory, (void)data;
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(box, "szfriends-history-row");
    gtk_list_item_set_child(list_item, box);
    gtk_list_item_set_activatable(list_item, FALSE);
    gtk_list_item_set_selectable(list_item, FALSE);
    gtk_list_item_set_focusable(list_item, FALSE); /* Tab reaches the buttons in a row, not the row itself */
}

static void row_clear(GtkListItem *list_item) {
    GtkWidget *box = gtk_list_item_get_child(list_item), *child;
    while ((child = gtk_widget_get_first_child(box))) gtk_box_remove(GTK_BOX(box), child);
}

static void row_bind(GtkSignalListItemFactory *factory, GtkListItem *list_item, gpointer data) {
    (void)factory;
    SZFriendsGtkHistory *history = data;
    GObject *holder = gtk_list_item_get_item(list_item);
    row_clear(list_item);
    GtkWidget *box = gtk_list_item_get_child(list_item), *row;
    if (g_object_get_data(holder, "szfriends-earlier")) {
        /* A visible way to older history besides scrolling to the top, which not everyone discovers. */
        row = gtk_button_new_with_label(szfriends_gtk_link_string(history->conversation->link, "load_earlier"));
        gtk_widget_add_css_class(row, "flat");
        gtk_widget_add_css_class(row, "szfriends-link");
        gtk_widget_set_halign(row, GTK_ALIGN_CENTER);
        gtk_widget_set_sensitive(row, !history->loading_earlier);
        g_signal_connect(row, "clicked", G_CALLBACK(earlier_clicked), history);
        gtk_box_append(GTK_BOX(box), row);
        return;
    }
    const SZFriendsGtkConversationItem *item = szfriends_gtk_history_item(holder);
    if (item->kind == SZFRIENDS_GTK_ITEM_MESSAGE) row = szfriends_gtk_message_row_new(history->conversation, holder,
                                                                                      item);
    else if (item->kind == SZFRIENDS_GTK_ITEM_TRANSFER) row = szfriends_gtk_transfer_row_new(history->conversation,
                                                                                            item);
    else row = szfriends_gtk_simple_row_new(item);
    gtk_box_append(GTK_BOX(box), row);
    gtk_list_item_set_accessible_label(list_item, item->accessibility_label);
}

static void row_unbind(GtkSignalListItemFactory *factory, GtkListItem *list_item, gpointer data) {
    (void)factory, (void)data;
    row_clear(list_item); /* rows let go of their items as soon as they leave the screen */
}

/* ---- Snapshots ------------------------------------------------------------------------------------------ */

static GObject *store_item(SZFriendsGtkHistory *history, guint position) {
    GObject *item = g_list_model_get_item(G_LIST_MODEL(history->store), position);
    g_object_unref(item); /* the store keeps it */
    return item;
}

static void splice(SZFriendsGtkHistory *history, GPtrArray *next) {
    guint old_count = g_list_model_get_n_items(G_LIST_MODEL(history->store)), prefix = 0, suffix = 0;
    while (prefix < old_count && prefix < next->len && store_item(history, prefix) == next->pdata[prefix]) prefix++;
    while (suffix < old_count - prefix && suffix < next->len - prefix &&
           store_item(history, old_count - 1 - suffix) == next->pdata[next->len - 1 - suffix])
        suffix++;
    g_list_store_splice(history->store, prefix, old_count - prefix - suffix, next->pdata + prefix,
                        next->len - prefix - suffix);
}

static gboolean at_bottom(SZFriendsGtkHistory *history) {
    GtkAdjustment *adjustment = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(history->scroller));
    return gtk_adjustment_get_value(adjustment) + gtk_adjustment_get_page_size(adjustment) >=
           gtk_adjustment_get_upper(adjustment) - 4;
}

static void scroll_to(SZFriendsGtkHistory *history, guint position) {
    guint count = g_list_model_get_n_items(G_LIST_MODEL(history->store));
    if (count) gtk_list_view_scroll_to(GTK_LIST_VIEW(history->list_view), MIN(position, count - 1),
                                       GTK_LIST_SCROLL_NONE, NULL);
}

void szfriends_gtk_history_apply(SZFriendsGtkHistory *history, JsonObject *data,
                                 const SZFriendsGtkConversationSnapshot *snapshot, guint subscription) {
    gboolean first = g_list_model_get_n_items(G_LIST_MODEL(history->store)) == 0, follow = first || at_bottom(history);
    guint old_count = g_list_model_get_n_items(G_LIST_MODEL(history->store));
    history->subscription = subscription;
    history->has_earlier = snapshot->has_earlier;
    history->accepts_drops = snapshot->composer.accepts_drops && snapshot->composer.enabled && !snapshot->request;
    GHashTable *old = g_hash_table_new(g_str_hash, g_str_equal);
    for (guint i = 0; i < old_count; i++) {
        const char *key = g_object_get_data(store_item(history, i), "szfriends-key");
        if (key) g_hash_table_insert(old, (gpointer)key, store_item(history, i));
    }
    GPtrArray *next = g_ptr_array_new_with_free_func(g_object_unref);
    /* Shown only with the helper's words for it (PROTOCOL.md § Static strings: never invent text). */
    if (snapshot->has_earlier && *szfriends_gtk_link_string(history->conversation->link, "load_earlier")) {
        GObject *row = old_count && g_object_get_data(store_item(history, 0), "szfriends-earlier")
                           ? g_object_ref(store_item(history, 0)) : g_object_new(G_TYPE_OBJECT, NULL);
        g_object_set_data(row, "szfriends-earlier", GINT_TO_POINTER(1));
        g_ptr_array_add(next, row);
    }
    JsonArray *items = data && json_object_has_member(data, "items") &&
                               JSON_NODE_HOLDS_ARRAY(json_object_get_member(data, "items"))
                           ? json_object_get_array_member(data, "items") : NULL;
    guint added = 0;
    for (guint i = 0; items && i < json_array_get_length(items); i++) {
        JsonNode *node = json_array_get_element(items, i);
        if (!JSON_NODE_HOLDS_OBJECT(node)) continue;
        GObject *fresh = szfriends_gtk_history_holder_new(json_node_get_object(node));
        GObject *kept = g_hash_table_lookup(old, g_object_get_data(fresh, "szfriends-key"));
        gboolean same = kept && strcmp(g_object_get_data(kept, "szfriends-fingerprint"),
                                       g_object_get_data(fresh, "szfriends-fingerprint")) == 0;
        added += !kept;
        g_ptr_array_add(next, same ? g_object_ref(kept) : g_object_ref(fresh));
        g_object_unref(fresh);
    }
    g_hash_table_unref(old);
    gboolean grew_above = history->loading_earlier && added > 0;
    if (grew_above || snapshot->highlight_item_id) history->pending_bottom = FALSE; /* never pulled away from them */
    splice(history, next);
    g_ptr_array_unref(next);
    /* The earlier items arrived (or there are none left): Show earlier messages works again. */
    if (grew_above || !snapshot->has_earlier) history->loading_earlier = FALSE;
    const char *highlight = snapshot->highlight_item_id;
    if (highlight && g_strcmp0(highlight, history->scrolled_highlight) != 0) {
        g_free(history->scrolled_highlight);
        history->scrolled_highlight = g_strdup(highlight);
        for (guint i = 0; i < g_list_model_get_n_items(G_LIST_MODEL(history->store)); i++) {
            const SZFriendsGtkConversationItem *item = szfriends_gtk_history_item(store_item(history, i));
            if (item && strcmp(item->item_id, highlight) == 0) {
                scroll_to(history, i);
                return;
            }
        }
    }
    /* Earlier items arriving above keep their place: the list view holds on to the row in view. A list not laid
     * out yet (the first snapshot) reaches its end once it knows its size. */
    if (follow && !grew_above) {
        scroll_to(history, G_MAXUINT);
        history->pending_bottom = TRUE;
    }
}

static void sized(GtkAdjustment *adjustment, gpointer data) {
    SZFriendsGtkHistory *history = data;
    if (!history->pending_bottom || gtk_adjustment_get_page_size(adjustment) <= 0) return;
    history->pending_bottom = FALSE;
    double bottom = gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment);
    gtk_adjustment_set_value(adjustment, bottom);
}

void szfriends_gtk_history_restyle(SZFriendsGtkHistory *history) {
    /* The factory again: every row on screen is made anew, with the colours resolved again. (Splicing the same items
     * back would not do: the list view keeps the rows of items it already has.) */
    GtkListItemFactory *factory = g_object_ref(gtk_list_view_get_factory(GTK_LIST_VIEW(history->list_view)));
    gtk_list_view_set_factory(GTK_LIST_VIEW(history->list_view), NULL);
    gtk_list_view_set_factory(GTK_LIST_VIEW(history->list_view), factory);
    g_object_unref(factory);
}

void szfriends_gtk_history_forget_highlight(SZFriendsGtkHistory *history) {
    g_clear_pointer(&history->scrolled_highlight, g_free);
}

static void scrolled(GtkAdjustment *adjustment, gpointer data) {
    SZFriendsGtkHistory *history = data;
    double value = gtk_adjustment_get_value(adjustment);
    if (value < history->last_value) history->pending_bottom = FALSE; /* the person scrolled up: stay there */
    /* Moving up to the top with more history on the helper: the same as pressing Show earlier messages. */
    if (value < history->last_value && value <= 40) load_earlier(history);
    history->last_value = value;
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

/* ---- Building ------------------------------------------------------------------------------------------- */

SZFriendsGtkHistory *szfriends_gtk_history_new(SZFriendsGtkConversation *conversation) {
    SZFriendsGtkHistory *history = g_new0(SZFriendsGtkHistory, 1);
    history->conversation = szfriends_gtk_conversation_ref(conversation);
    history->store = g_list_store_new(G_TYPE_OBJECT);
    GtkListItemFactory *factory = gtk_signal_list_item_factory_new();
    g_signal_connect(factory, "setup", G_CALLBACK(row_setup), history);
    g_signal_connect(factory, "bind", G_CALLBACK(row_bind), history);
    g_signal_connect(factory, "unbind", G_CALLBACK(row_unbind), history);
    history->list_view = gtk_list_view_new(GTK_SELECTION_MODEL(gtk_no_selection_new(
                                               G_LIST_MODEL(g_object_ref(history->store)))), factory);
    gtk_widget_add_css_class(history->list_view, "szfriends-history");
    history->scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(history->scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    /* Short histories sit at the bottom, next to the composer, as chat histories do. */
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(history->scroller), TRUE);
    gtk_widget_set_valign(history->scroller, GTK_ALIGN_END);
    gtk_widget_set_vexpand(history->scroller, TRUE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(history->scroller), history->list_view);
    GtkAdjustment *adjustment = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(history->scroller));
    g_signal_connect(adjustment, "value-changed", G_CALLBACK(scrolled), history);
    g_signal_connect(adjustment, "changed", G_CALLBACK(sized), history);
    /* Held: the page's teardown reaches the history after GTK has let go of the page's children. */
    history->root = g_object_ref_sink(gtk_overlay_new());
    gtk_overlay_set_child(GTK_OVERLAY(history->root), history->scroller);
    /* Over the list while a drag hovers: an outline when it can be sent, the refusal when it cannot, its words on a
     * card of their own in the middle (on the tint alone they ran across the bubbles under them). It never takes
     * clicks, so the messages under it stay usable. */
    history->drop_mark = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(history->drop_mark, "szfriends-history-drop");
    gtk_widget_set_can_target(history->drop_mark, FALSE);
    gtk_widget_set_visible(history->drop_mark, FALSE);
    history->drop_words = gtk_label_new(NULL);
    gtk_widget_add_css_class(history->drop_words, "szfriends-history-drop-words");
    gtk_label_set_wrap(GTK_LABEL(history->drop_words), TRUE);
    gtk_label_set_justify(GTK_LABEL(history->drop_words), GTK_JUSTIFY_CENTER);
    gtk_widget_set_valign(history->drop_words, GTK_ALIGN_CENTER);
    gtk_widget_set_halign(history->drop_words, GTK_ALIGN_CENTER);
    gtk_widget_set_vexpand(history->drop_words, TRUE);
    gtk_box_append(GTK_BOX(history->drop_mark), history->drop_words);
    gtk_overlay_add_overlay(GTK_OVERLAY(history->root), history->drop_mark);
    gsize n_types = 0;
    GType *types = szfriends_gtk_drop_types(szfriends_gtk_link_host(conversation->link), &n_types);
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
    return history;
}

GtkWidget *szfriends_gtk_history_widget(SZFriendsGtkHistory *history) {
    return history->root;
}

GtkWidget *szfriends_gtk_history_list_view(SZFriendsGtkHistory *history) {
    return history->list_view;
}

GListModel *szfriends_gtk_history_model(SZFriendsGtkHistory *history) {
    return G_LIST_MODEL(history->store);
}

/* Called as the page goes: the widgets go with it, so nothing here may reach them later. */
void szfriends_gtk_history_free(SZFriendsGtkHistory *history) {
    if (!history) return;
    g_signal_handlers_disconnect_by_data(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(history->scroller)),
                                         history);
    g_list_store_remove_all(history->store);
    g_object_unref(history->root);
    g_object_unref(history->store);
    g_free(history->scrolled_highlight);
    szfriends_gtk_conversation_unref(history->conversation);
    g_free(history);
}
