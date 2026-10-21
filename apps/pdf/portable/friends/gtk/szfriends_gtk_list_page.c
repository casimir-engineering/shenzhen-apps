/* The dropdown's root page (szfriends_gtk_list_page.h; mirrors mac/SZFriendsListPage.m): the title with its Beta
 * tag beside search, Friends / Nearby,
 * the rows the helper sorted, the footer. Rows are reused by position, so a refresh keeps hover, focus and an armed
 * "Block?" on the person it was armed for. */

#include "gtk/szfriends_gtk_details_page.h"
#include "gtk/szfriends_gtk_list_page_private.h"

#include <adwaita.h>

static SZFriendsGtkListPage *list_of(SZFriendsGtkPage *page) {
    SZFriendsGtkListPage *list = page && szfriends_gtk_page_get_kind(page) == SZFRIENDS_GTK_PAGE_LIST
                                     ? szfriends_gtk_page_get_data(page) : NULL;
    return list && list->magic == SZFRIENDS_GTK_LIST_MAGIC ? list : NULL;
}

static const char *string(SZFriendsGtkListPage *list, const char *key) {
    return szfriends_gtk_link_string(list->link, key);
}

/* The welcome's strings can arrive after the page exists; they are read again with every snapshot. */
static void apply_static_strings(SZFriendsGtkListPage *list) {
    SZFriendsGtkListParts *parts = &list->parts;
    /* Friends is a beta: the title and its tag say so. An older helper sends neither, and neither shows. */
    const char *title = string(list, "button_label"), *beta = string(list, "beta");
    gtk_label_set_text(GTK_LABEL(parts->title), title);
    gtk_widget_set_visible(parts->title, *title != '\0');
    gtk_label_set_text(GTK_LABEL(parts->beta), beta);
    gtk_widget_set_visible(parts->beta, *title != '\0' && *beta != '\0');
    const char *placeholder = string(list, "search_placeholder");
    gtk_search_entry_set_placeholder_text(GTK_SEARCH_ENTRY(parts->search), placeholder);
    if (*placeholder)
        gtk_accessible_update_property(GTK_ACCESSIBLE(parts->search), GTK_ACCESSIBLE_PROPERTY_LABEL, placeholder, -1);
    /* The search field stands where a title would; the page's own title still names it for assistive technology. */
    szfriends_gtk_page_set_name(list->page, string(list, "button_label"));
    AdwToggleGroup *tabs = ADW_TOGGLE_GROUP(parts->tabs);
    adw_toggle_set_label(adw_toggle_group_get_toggle_by_name(tabs, "friends"), string(list, "tab_friends"));
    adw_toggle_set_label(adw_toggle_group_get_toggle_by_name(tabs, "nearby"), string(list, "tab_nearby"));
}

/* ---- Subscriptions ------------------------------------------------------------------------------- */

static void apply_list(SZFriendsGtkListPage *list, JsonObject *data);

static void list_snapshot(JsonObject *data, gint64 rev, gpointer user_data) {
    (void)rev;
    SZFriendsGtkListPage *list = user_data;
    apply_list(list, data);
    list->parts.list_snapshots++;
}

static void nearby_snapshot(JsonObject *data, gint64 rev, gpointer user_data) {
    (void)rev;
    SZFriendsGtkListPage *list = user_data;
    apply_static_strings(list);
    szfriends_gtk_nearby_pane_apply(list->parts.nearby, szfriends_gtk_nearby_snapshot_parse(data));
    const SZFriendsGtkNearbySnapshot *nearby = szfriends_gtk_nearby_pane_snapshot(list->parts.nearby);
    if (list->parts.showing_nearby && nearby) szfriends_gtk_footer_apply(list->parts.footer, &nearby->footer);
    list->parts.nearby_snapshots++;
}

static void subscribe_visible(SZFriendsGtkListPage *list) {
    SZFriendsGtkListParts *parts = &list->parts;
    if (!szfriends_gtk_page_is_presented(list->page)) return;
    const char *query = gtk_editable_get_text(GTK_EDITABLE(parts->search));
    if (parts->showing_nearby && !parts->nearby_token) {
        parts->nearby_token = szfriends_gtk_link_subscribe(list->link, "nearby", NULL, nearby_snapshot, list, NULL);
        if (*query) szfriends_gtk_link_set_filter(list->link, parts->nearby_token, query);
    }
    /* The list stays subscribed on both tabs: the name card and the banner above the tabs come from it, and a name
     * saved on the Nearby tab must take the card away there too (it stayed after Return, 2026-10-20). */
    if (!parts->list_token) {
        parts->list_token = szfriends_gtk_link_subscribe(list->link, "list", NULL, list_snapshot, list, NULL);
        if (*query) szfriends_gtk_link_set_filter(list->link, parts->list_token, query);
    }
    /* Nearby counts down every second; nothing should keep that running while the Friends tab shows. */
    if (!parts->showing_nearby && parts->nearby_token) {
        szfriends_gtk_link_unsubscribe(list->link, parts->nearby_token);
        parts->nearby_token = 0;
    }
}

static void unsubscribe_all(SZFriendsGtkListPage *list) {
    SZFriendsGtkListParts *parts = &list->parts;
    if (parts->list_token) szfriends_gtk_link_unsubscribe(list->link, parts->list_token);
    if (parts->nearby_token) szfriends_gtk_link_unsubscribe(list->link, parts->nearby_token);
    parts->list_token = parts->nearby_token = 0;
}

void szfriends_gtk_list_page_show_nearby(SZFriendsGtkPage *page, gboolean nearby) {
    SZFriendsGtkListPage *list = list_of(page);
    if (!list) return;
    SZFriendsGtkListParts *parts = &list->parts;
    parts->showing_nearby = nearby;
    const char *name = nearby ? "nearby" : "friends";
    if (g_strcmp0(adw_toggle_group_get_active_name(ADW_TOGGLE_GROUP(parts->tabs)), name))
        adw_toggle_group_set_active_name(ADW_TOGGLE_GROUP(parts->tabs), name);
    gtk_stack_set_visible_child(GTK_STACK(parts->stack), nearby ? list->nearby_scroll : list->friends_scroll);
    subscribe_visible(list);
    const SZFriendsGtkNearbySnapshot *seen = szfriends_gtk_nearby_pane_snapshot(parts->nearby);
    const SZFriendsGtkFooter *footer = nearby && seen ? &seen->footer : list->list ? &list->list->footer : NULL;
    if (!footer && seen) footer = &seen->footer;
    if (footer) szfriends_gtk_footer_apply(parts->footer, footer);
}

static void tab_changed(GObject *tabs, GParamSpec *spec, gpointer data) {
    (void)spec;
    SZFriendsGtkListPage *list = data;
    gboolean nearby = !g_strcmp0(adw_toggle_group_get_active_name(ADW_TOGGLE_GROUP(tabs)), "nearby");
    if (nearby != list->parts.showing_nearby) szfriends_gtk_list_page_show_nearby(list->page, nearby);
}

static void search_changed(GtkSearchEntry *entry, gpointer data) {
    SZFriendsGtkListPage *list = data;
    /* Both lists answer to what the field holds, so the search follows the person to the other tab. */
    const char *query = gtk_editable_get_text(GTK_EDITABLE(entry));
    if (list->parts.list_token) szfriends_gtk_link_set_filter(list->link, list->parts.list_token, query);
    if (list->parts.nearby_token) szfriends_gtk_link_set_filter(list->link, list->parts.nearby_token, query);
}

/* ---- Rows ---------------------------------------------------------------------------------------- */

static void row_activated(GtkWidget *row, gpointer data) {
    SZFriendsGtkListPage *list = data;
    const char *conversation_id = szfriends_gtk_row_get_conversation_id(row);
    if (!conversation_id) return;
    char *id = g_strdup(conversation_id);
    GPtrArray *items = szfriends_gtk_dropdown_get_send_items(list->dropdown);
    if (items) {
        /* The send picker: the friend clicked next gets one offer per file. Rows that refuse drops cannot. */
        if (!szfriends_gtk_row_get_drop_label(row)) {
            g_free(id);
            return;
        }
        szfriends_gtk_link_send(list->link, szfriends_gtk_intent_send_items(id, items, NULL), NULL, NULL, NULL);
        szfriends_gtk_dropdown_finish_send_picker(list->dropdown);
    }
    szfriends_gtk_dropdown_open_conversation(list->dropdown, id, NULL);
    g_free(id);
}

typedef struct {
    GWeakRef row;
    char *conversation_id;
} SZFriendsGtkAnswer;

static void answer_free(gpointer data) {
    SZFriendsGtkAnswer *answer = data;
    g_weak_ref_clear(&answer->row);
    g_free(answer->conversation_id);
    g_free(answer);
}

/* The buttons rest until the reply, so a double click sends one answer; a success brings the new list (without
 * them) before its reply, and a refusal leaves them to try again. */
static void answered(JsonObject *result, const SZFriendsGtkError *error, gpointer data) {
    (void)result, (void)error;
    SZFriendsGtkAnswer *answer = data;
    GtkWidget *row = g_weak_ref_get(&answer->row);
    if (row && !g_strcmp0(szfriends_gtk_row_get_conversation_id(row), answer->conversation_id))
        szfriends_gtk_row_actions_set_busy(szfriends_gtk_row_get_actions(row), FALSE);
    if (row) g_object_unref(row);
}

static void row_action(GtkWidget *row, SZFriendsGtkActionKind action, gpointer data) {
    SZFriendsGtkListPage *list = data;
    SZFriendsGtkActionIds ids = {.conversation_id = szfriends_gtk_row_get_conversation_id(row)};
    szfriends_intent *intent = szfriends_gtk_intent_for_action_kind(action, &ids);
    if (!intent) return;
    SZFriendsGtkAnswer *answer = g_new0(SZFriendsGtkAnswer, 1);
    g_weak_ref_init(&answer->row, row);
    answer->conversation_id = g_strdup(ids.conversation_id);
    szfriends_gtk_row_actions_set_busy(szfriends_gtk_row_get_actions(row), TRUE);
    szfriends_gtk_link_send(list->link, intent, answered, answer, answer_free);
}

/* ---- A row's menu: Remove, Cancel request ---------------------------------------------------------- */

static void apply_rows(SZFriendsGtkListPage *list, const SZFriendsGtkListSnapshot *snapshot);

typedef struct {
    GWeakRef page; /* the page's widget: the list is gone once it is */
    SZFriendsGtkListPage *list;
    char *conversation_id;
} SZFriendsGtkRemoval;

static SZFriendsGtkListPage *removal_list(SZFriendsGtkRemoval *removal, GtkWidget **held) {
    *held = g_weak_ref_get(&removal->page);
    return *held ? removal->list : NULL;
}

/* The person confirmed: their row goes at once, before the helper's new list arrives. */
static void removal_sending(gpointer data) {
    SZFriendsGtkRemoval *removal = data;
    GtkWidget *held;
    SZFriendsGtkListPage *list = removal_list(removal, &held);
    if (!list) return;
    g_hash_table_add(list->hidden, g_strdup(removal->conversation_id));
    if (list->list) apply_rows(list, list->list);
    g_object_unref(held);
}

/* The helper answered: its new list (without them) came first, so the latest snapshot is the truth again. A refusal
 * brings the row back, and its reason is read out, as the row is where the person left it. */
static void removal_answered(JsonObject *result, const SZFriendsGtkError *error, gpointer data) {
    (void)result;
    SZFriendsGtkRemoval *removal = data;
    GtkWidget *held;
    SZFriendsGtkListPage *list = removal_list(removal, &held);
    if (list && g_hash_table_remove(list->hidden, removal->conversation_id) && list->list) {
        apply_rows(list, list->list);
        GtkWidget *row = NULL;
        for (guint i = 0; i < list->parts.rows->len && !row; i++)
            if (!g_strcmp0(szfriends_gtk_row_get_conversation_id(g_ptr_array_index(list->parts.rows, i)),
                           removal->conversation_id))
                row = g_ptr_array_index(list->parts.rows, i);
        if (row && error && error->message && *error->message)
            gtk_accessible_announce(GTK_ACCESSIBLE(row), error->message, GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_HIGH);
    }
    if (held) g_object_unref(held);
    g_weak_ref_clear(&removal->page);
    g_free(removal->conversation_id);
    g_free(removal);
}

static const SZFriendsGtkListRow *snapshot_row(SZFriendsGtkListPage *list, const char *conversation_id) {
    for (gsize i = 0; list->list && conversation_id && i < list->list->n_rows; i++)
        if (!g_strcmp0(list->list->rows[i].conversation_id, conversation_id)) return &list->list->rows[i];
    return NULL;
}

/* From the latest snapshot, never a copy the row kept: the item does what the helper says now. */
static void row_menu_chosen(GtkWidget *row, guint index, gpointer data) {
    SZFriendsGtkListPage *list = data;
    const char *conversation_id = szfriends_gtk_row_get_conversation_id(row);
    const SZFriendsGtkListRow *person = snapshot_row(list, conversation_id);
    if (!person || index >= person->n_menu) return;
    SZFriendsGtkActionIds ids = {.conversation_id = conversation_id};
    SZFriendsGtkRemoval *removal = g_new0(SZFriendsGtkRemoval, 1);
    g_weak_ref_init(&removal->page, szfriends_gtk_page_get_widget(list->page));
    removal->list = list;
    removal->conversation_id = g_strdup(conversation_id);
    /* Every reply, or nothing sent (Cancel), reaches removal_answered once, which frees it. */
    szfriends_gtk_perform_sending(list->link, list->dropdown, row, &person->menu[index], &ids, removal_sending,
                                  removal_answered, removal);
}

/* Files dropped on a friend go at once, one offer per file, shown in the conversation with Cancel. */
static void row_dropped(GtkWidget *row, GPtrArray *items, gpointer data) {
    SZFriendsGtkListPage *list = data;
    const char *conversation_id = szfriends_gtk_row_get_conversation_id(row);
    if (!conversation_id || !items->len) return;
    szfriends_gtk_link_send(list->link, szfriends_gtk_intent_send_items(conversation_id, items, NULL), NULL, NULL,
                            NULL);
    szfriends_gtk_dropdown_set_drop_hint(list->dropdown, NULL);
}

static void apply_rows(SZFriendsGtkListPage *list, const SZFriendsGtkListSnapshot *snapshot) {
    GPtrArray *rows = list->parts.rows;
    GPtrArray *shown = g_ptr_array_new(); /* the snapshot's rows, without anyone just removed here */
    for (gsize i = 0; i < snapshot->n_rows; i++)
        if (!g_hash_table_contains(list->hidden, snapshot->rows[i].conversation_id))
            g_ptr_array_add(shown, &snapshot->rows[i]);
    while (rows->len > shown->len) {
        gtk_box_remove(GTK_BOX(list->rows_box), g_ptr_array_index(rows, rows->len - 1));
        g_ptr_array_remove_index(rows, rows->len - 1);
    }
    static const SZFriendsGtkRowHandlers handlers = {row_activated, row_action, row_dropped, NULL, row_menu_chosen};
    while (rows->len < shown->len) {
        GtkWidget *row = szfriends_gtk_row_new(list->link);
        szfriends_gtk_row_set_handlers(row, &handlers, list);
        gtk_box_append(GTK_BOX(list->rows_box), row);
        g_ptr_array_add(rows, row);
    }
    for (guint i = 0; i < shown->len; i++)
        szfriends_gtk_row_set_list_row(g_ptr_array_index(rows, i), g_ptr_array_index(shown, i));
    g_ptr_array_unref(shown);
    szfriends_gtk_list_dim_rows(list);
}

static void apply_list(SZFriendsGtkListPage *list, JsonObject *data) {
    SZFriendsGtkListSnapshot *snapshot = szfriends_gtk_list_snapshot_parse(data);
    SZFriendsGtkListParts *parts = &list->parts;
    apply_static_strings(list);
    szfriends_gtk_list_apply_notices(list, snapshot);
    apply_rows(list, snapshot);
    gtk_widget_set_visible(list->empty, snapshot->empty != NULL);
    szfriends_gtk_list_label_set(parts->empty_title, snapshot->empty ? snapshot->empty->title : NULL);
    szfriends_gtk_list_label_set(parts->empty_body, snapshot->empty ? snapshot->empty->body : NULL);
    if (!parts->showing_nearby || !szfriends_gtk_nearby_pane_snapshot(parts->nearby))
        szfriends_gtk_footer_apply(parts->footer, &snapshot->footer);
    szfriends_gtk_list_apply_devices(list, data);
    if (list->list) szfriends_gtk_list_snapshot_free(list->list);
    list->list = snapshot; /* after the rows: the banner's button reads it when pressed */
}

/* ---- The page ------------------------------------------------------------------------------------ */

static GtkWidget *centred(GtkWidget *label) {
    gtk_label_set_xalign(GTK_LABEL(label), 0.5f);
    gtk_label_set_justify(GTK_LABEL(label), GTK_JUSTIFY_CENTER);
    return label;
}

static GtkWidget *scroller(GtkWidget *child) {
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), child);
    gtk_widget_set_vexpand(scroll, TRUE);
    return scroll;
}

static void build_tabs(SZFriendsGtkListPage *list) {
    list->parts.tabs = adw_toggle_group_new();
    gtk_widget_add_css_class(list->parts.tabs, "szfriends-tabs");
    adw_toggle_group_set_homogeneous(ADW_TOGGLE_GROUP(list->parts.tabs), TRUE);
    static const char *const names[] = {"friends", "nearby"};
    for (gsize i = 0; i < G_N_ELEMENTS(names); i++) {
        AdwToggle *toggle = adw_toggle_new();
        adw_toggle_set_name(toggle, names[i]);
        adw_toggle_group_add(ADW_TOGGLE_GROUP(list->parts.tabs), toggle);
    }
    adw_toggle_group_set_active_name(ADW_TOGGLE_GROUP(list->parts.tabs), "friends");
    g_signal_connect(list->parts.tabs, "notify::active-name", G_CALLBACK(tab_changed), list);
}

static void build_rows(SZFriendsGtkListPage *list) {
    SZFriendsGtkListParts *parts = &list->parts;
    GtkWidget *friends = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    list->rows_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    parts->rows = g_ptr_array_new();
    list->empty = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_vexpand(list->empty, TRUE);
    gtk_widget_set_valign(list->empty, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_start(list->empty, 36);
    gtk_widget_set_margin_end(list->empty, 36);
    gtk_widget_set_visible(list->empty, FALSE);
    parts->empty_title = centred(szfriends_gtk_list_label("szfriends-empty-title"));
    parts->empty_body = centred(szfriends_gtk_list_label("szfriends-secondary"));
    gtk_box_append(GTK_BOX(list->empty), parts->empty_title);
    gtk_box_append(GTK_BOX(list->empty), parts->empty_body);
    gtk_box_append(GTK_BOX(friends), list->rows_box);
    gtk_box_append(GTK_BOX(friends), list->empty);
    list->friends_scroll = scroller(friends);
    parts->nearby = szfriends_gtk_nearby_pane_new(list->link, list->dropdown);
    list->nearby_scroll = scroller(parts->nearby);
    parts->stack = gtk_stack_new();
    gtk_stack_add_child(GTK_STACK(parts->stack), list->friends_scroll);
    gtk_stack_add_child(GTK_STACK(parts->stack), list->nearby_scroll);
    gtk_stack_set_visible_child(GTK_STACK(parts->stack), list->friends_scroll);
}

static void state_changed(SZFriendsGtkLink *link, SZFriendsGtkLinkState state, gpointer data) {
    (void)link, (void)state;
    apply_static_strings(data);
}

static void list_free(gpointer data) {
    SZFriendsGtkListPage *list = data;
    if (list->parts.footer)
        g_object_remove_weak_pointer(G_OBJECT(list->parts.footer), (gpointer *)&list->parts.footer);
    if (list->list) szfriends_gtk_list_snapshot_free(list->list);
    g_ptr_array_unref(list->parts.rows); /* the row widgets went with the page */
    g_hash_table_unref(list->hidden);
    g_free(list);
}

static void page_build(SZFriendsGtkPage *page, gpointer data) {
    (void)data;
    SZFriendsGtkListPage *list = g_new0(SZFriendsGtkListPage, 1);
    list->magic = SZFRIENDS_GTK_LIST_MAGIC;
    list->page = page;
    list->hidden = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    list->link = szfriends_gtk_page_get_link(page);
    list->dropdown = szfriends_gtk_page_get_dropdown(page);
    szfriends_gtk_page_set_data(page, list, list_free);
    szfriends_gtk_list_style_ensure(szfriends_gtk_page_get_widget(page));
    SZFriendsGtkListParts *parts = &list->parts;
    parts->search = gtk_search_entry_new();
    gtk_widget_add_css_class(parts->search, "szfriends-list-search");
    gtk_widget_set_hexpand(parts->search, TRUE);
    gtk_search_entry_set_search_delay(GTK_SEARCH_ENTRY(parts->search), 0); /* searches as you type, as AppKit */
    g_signal_connect(parts->search, "search-changed", G_CALLBACK(search_changed), list);
    parts->title = gtk_label_new("");
    gtk_widget_add_css_class(parts->title, "szfriends-list-title");
    gtk_widget_set_visible(parts->title, FALSE);
    parts->beta = gtk_label_new("");
    gtk_widget_add_css_class(parts->beta, "szfriends-beta");
    gtk_widget_set_valign(parts->beta, GTK_ALIGN_CENTER);
    gtk_widget_set_visible(parts->beta, FALSE);
    GtkWidget *header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_box_append(GTK_BOX(header), parts->title);
    gtk_box_append(GTK_BOX(header), parts->beta);
    gtk_widget_set_margin_end(parts->beta, 4);
    gtk_box_append(GTK_BOX(header), parts->search);
    gtk_widget_set_hexpand(header, TRUE);
    szfriends_gtk_page_set_title_widget(page, header);
    build_tabs(list);
    szfriends_gtk_page_add_top_bar(page, parts->tabs);
    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    szfriends_gtk_list_build_notices(list, content);
    szfriends_gtk_list_build_devices(list, content);
    build_rows(list);
    gtk_box_append(GTK_BOX(content), parts->stack);
    szfriends_gtk_page_set_content(page, content);
    parts->footer = szfriends_gtk_footer_new(list->link, list->dropdown);
    /* Cleared when the footer goes: a page destroyed on screen hears it left after its widgets went. */
    g_object_add_weak_pointer(G_OBJECT(parts->footer), (gpointer *)&parts->footer);
    szfriends_gtk_page_add_bottom_bar(page, parts->footer);
    apply_static_strings(list);
    if (list->dropdown) {
        GCallback watch = G_CALLBACK(szfriends_gtk_list_update_send_notice);
        list->dropdown_watch = szfriends_gtk_dropdown_add_watch(list->dropdown, watch, list);
        szfriends_gtk_list_update_send_notice(list->dropdown, list);
    }
    list->state_watch = szfriends_gtk_link_add_state_watch(list->link, state_changed, list, NULL);
}

static void page_presented(SZFriendsGtkPage *page, gboolean presented, gpointer data) {
    (void)data;
    SZFriendsGtkListPage *list = list_of(page);
    if (!list) return;
    if (presented) {
        subscribe_visible(list);
        /* A popover with autohide off takes no focus by itself; Escape reaches the dropdown once focus is in it. */
        gtk_widget_grab_focus(list->parts.search);
        return;
    }
    unsubscribe_all(list);
    szfriends_gtk_footer_cancel_edit(list->parts.footer);
}

/* Escape turns an armed "Block?" back first: closing the dropdown under it would leave the person unsure whether
 * they blocked someone. Then it closes the name being edited, and only then the dropdown. */
static gboolean page_escape(SZFriendsGtkPage *page, gpointer data) {
    (void)data;
    SZFriendsGtkListPage *list = list_of(page);
    if (!list) return FALSE;
    for (guint i = 0; i < list->parts.rows->len; i++)
        if (szfriends_gtk_row_actions_disarm(szfriends_gtk_row_get_actions(g_ptr_array_index(list->parts.rows, i))))
            return TRUE;
    if (szfriends_gtk_details_disarm(list->parts.devices)) return TRUE; /* a join row's "Deny?" */
    return szfriends_gtk_footer_cancel_edit(list->parts.footer);
}

static void page_dispose(SZFriendsGtkPage *page, gpointer data) {
    (void)data;
    SZFriendsGtkListPage *list = list_of(page);
    if (!list) return;
    if (list->dropdown_watch) szfriends_gtk_dropdown_remove_watch(list->dropdown, list->dropdown_watch);
    if (list->state_watch) szfriends_gtk_link_remove_state_watch(list->link, list->state_watch);
    list->dropdown_watch = list->state_watch = 0;
}

const SZFriendsGtkPageClass szfriends_gtk_list_page_class = {page_build, page_presented, page_escape, page_dispose};

const SZFriendsGtkListParts *szfriends_gtk_list_page_parts(SZFriendsGtkPage *page) {
    SZFriendsGtkListPage *list = list_of(page);
    return list ? &list->parts : NULL;
}
