/* The composer's pickers (szfriends_gtk_conversation.h; mirrors SZFriendsAttachPicker in mac/): a panel over the
 * history, just above the composer. Up and Down move, Return chooses, Escape closes it and only it.
 *
 *   `#` lists the host's items (attachable_items) for what is typed after the `#` in the composer, which keeps the
 *       focus; a space, a new line or moving away from that word closes it. When nothing matches, one row in the
 *       host's words says so. Choosing one puts a chip in place of the `#` and what followed it, and sends nothing.
 *   `@` lists the friends who may be mentioned: a second `list` subscription, filtered with set_filter as the person
 *       types, showing rows whose `mentionable` is true, with the composer's mention_note under them saying what the
 *       friend will get (PROTOCOL.md § Mentions). Choosing one puts an @ chip in the text. */

#include "gtk/szfriends_gtk_conversation.h"
#include "gtk/szfriends_gtk_avatars.h"

/* Six rows keep the panel within a short window, as the AppKit picker. */
#define SZFRIENDS_GTK_PICKER_ROWS 6

typedef struct {
    char *conversation_id, *name; /* the name this person sees for the friend, without the "@" */
    SZFriendsGtkAvatar avatar;    /* strings owned */
} SZFriendsGtkMentionChoice;

typedef struct {
    SZFriendsGtkComposerView *composer;
    gboolean mentions;
    GtkWidget *panel, *entry, *rows, *empty; /* `#` has no entry; only `#` has the empty row */
    GPtrArray *choices; /* SZFriendsGtkHostItem * for `#`, SZFriendsGtkMentionChoice * for `@` */
    char *query;        /* `#`: what followed the `#` when the host was last asked */
    gboolean waiting;   /* `#`: the rows are the host's at-once ones until attachable_items answers */
    gboolean choose_when_answered; /* Return or a click came meanwhile */
    int selected;
    GCancellable *cancellable;
    guint request, subscription;
} SZFriendsGtkPicker;

/* `#` answers arrive later, maybe after the picker closed: they find it by request number, or find nothing. */
static GHashTable *pending_pickers;
static guint next_request;

static void choice_free(gpointer data) {
    SZFriendsGtkMentionChoice *choice = data;
    g_free(choice->conversation_id);
    g_free(choice->name);
    g_free(choice->avatar.initials);
    g_free(choice->avatar.color);
    g_free(choice->avatar.path);
    g_free(choice);
}

static GtkTextBuffer *buffer_of(SZFriendsGtkComposerView *composer) {
    return gtk_text_view_get_buffer(GTK_TEXT_VIEW(szfriends_gtk_composer_get_text_view(composer)));
}

static SZFriendsGtkPicker *picker_of(GtkWidget *panel) {
    return panel ? g_object_get_data(G_OBJECT(panel), "szfriends-picker") : NULL;
}

static void select_row(SZFriendsGtkPicker *picker, int index) {
    int count = (int)picker->choices->len;
    picker->selected = count ? CLAMP(index, 0, count - 1) : -1;
    int i = 0;
    for (GtkWidget *row = gtk_widget_get_first_child(picker->rows); row; row = gtk_widget_get_next_sibling(row), i++)
        if (i == picker->selected) gtk_widget_add_css_class(row, "szfriends-selected");
        else gtk_widget_remove_css_class(row, "szfriends-selected");
}

/* `#`: the `#` that opened the picker (the composer marks it as it is typed) and what follows it up to the insertion
 * point. FALSE when the `#` is gone, the insertion point left the word, or a space or a new line ended it. */
static gboolean typed_range(SZFriendsGtkPicker *picker, GtkTextIter *start, GtkTextIter *end) {
    GtkTextBuffer *buffer = buffer_of(picker->composer);
    GtkTextMark *hash = gtk_text_buffer_get_mark(buffer, SZFRIENDS_GTK_HASH_MARK);
    if (picker->mentions || !hash) return FALSE;
    gtk_text_buffer_get_iter_at_mark(buffer, start, hash);
    gtk_text_buffer_get_iter_at_mark(buffer, end, gtk_text_buffer_get_insert(buffer));
    if (gtk_text_buffer_get_has_selection(buffer) || gtk_text_iter_get_char(start) != '#' ||
        gtk_text_iter_compare(end, start) <= 0)
        return FALSE;
    GtkTextIter at = *start;
    while (gtk_text_iter_forward_char(&at) && gtk_text_iter_compare(&at, end) < 0)
        if (g_unichar_isspace(gtk_text_iter_get_char(&at))) return FALSE;
    return TRUE;
}

static void choose(SZFriendsGtkPicker *picker, int index) {
    if (index < 0 || index >= (int)picker->choices->len) return;
    /* An at-once row: what attachable_items answers, a moment later, is what gets attached. */
    if (!picker->mentions && picker->waiting) {
        picker->selected = index;
        picker->choose_when_answered = TRUE;
        return;
    }
    SZFriendsGtkComposerView *composer = picker->composer;
    gpointer choice = g_ptr_array_index(picker->choices, index);
    if (picker->mentions) {
        SZFriendsGtkMentionChoice *mention = choice;
        /* The chip shows "@" and the name, as the sent mention's words will; the list it came from shows names. */
        char *id = g_strdup(mention->conversation_id), *label = g_strconcat("@", mention->name, NULL);
        szfriends_gtk_composer_close_picker(composer); /* frees the choices */
        szfriends_gtk_composer_insert_mention(composer, id, label);
        g_free(id);
        g_free(label);
    } else {
        SZFriendsGtkHostItem *item = szfriends_gtk_host_item_copy(choice);
        GtkTextIter start, end;
        gboolean typed = typed_range(picker, &start, &end);
        szfriends_gtk_composer_close_picker(composer); /* frees the picker */
        /* The `#` and what was typed after it become the chip. */
        if (typed) gtk_text_buffer_delete(buffer_of(composer), &start, &end);
        szfriends_gtk_composer_attach(composer, item);
        szfriends_gtk_host_item_free(item);
    }
}

static void row_clicked(GtkButton *button, gpointer data) {
    choose(data, GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "szfriends-index")));
}

/* The title, with the host's badge ("Current") as a small pill right after it, and the detail under it. A long
 * title is cut short; the badge never is. */
static GtkWidget *two_lines(const char *first, const char *second, const char *badge) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1);
    gtk_widget_set_hexpand(box, TRUE);
    gtk_widget_set_valign(box, GTK_ALIGN_CENTER);
    for (int line = 0; line < 2; line++) {
        const char *text = line ? second : first;
        if (!text || !*text) continue;
        GtkWidget *label = gtk_label_new(text);
        gtk_widget_add_css_class(label, line ? "szfriends-secondary" : "szfriends-row-title");
        gtk_label_set_xalign(GTK_LABEL(label), 0);
        gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
        if (line || !badge || !*badge) {
            gtk_box_append(GTK_BOX(box), label);
            continue;
        }
        GtkWidget *title = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6), *pill = gtk_label_new(badge);
        gtk_widget_add_css_class(pill, "szfriends-badge-pill");
        gtk_widget_set_valign(pill, GTK_ALIGN_CENTER);
        gtk_box_append(GTK_BOX(title), label);
        gtk_box_append(GTK_BOX(title), pill);
        gtk_box_append(GTK_BOX(box), title);
    }
    return box;
}

/* `selected`: the row to choose (the first, the document on screen, unless the host's answer takes the places of
 * its at-once rows and the person had moved). */
static void show_rows_selecting(SZFriendsGtkPicker *picker, int selected);

static void show_rows(SZFriendsGtkPicker *picker) {
    show_rows_selecting(picker, 0);
}

static void show_rows_selecting(SZFriendsGtkPicker *picker, int selected) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(picker->rows))) gtk_box_remove(GTK_BOX(picker->rows), child);
    SZFriendsGtkLink *link = szfriends_gtk_composer_conversation(picker->composer)->link;
    for (guint i = 0; i < picker->choices->len; i++) {
        GtkWidget *row = gtk_button_new(), *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
        gtk_widget_add_css_class(row, "flat");
        gtk_widget_add_css_class(row, "szfriends-picker-row");
        const char *name;
        if (picker->mentions) {
            SZFriendsGtkMentionChoice *choice = g_ptr_array_index(picker->choices, i);
            GtkWidget *avatar = szfriends_gtk_avatar_new(link, 28);
            szfriends_gtk_avatar_set(avatar, &choice->avatar);
            gtk_box_append(GTK_BOX(box), avatar);
            gtk_box_append(GTK_BOX(box), two_lines(choice->name, NULL, NULL));
            name = choice->name;
        } else {
            SZFriendsGtkHostItem *item = g_ptr_array_index(picker->choices, i);
            GtkWidget *glyph = gtk_label_new(item->kind_label);
            gtk_widget_add_css_class(glyph, "szfriends-file-glyph");
            gtk_label_set_yalign(GTK_LABEL(glyph), 1);
            gtk_box_append(GTK_BOX(box), glyph);
            gtk_box_append(GTK_BOX(box), two_lines(item->title, item->detail, item->badge));
            name = item->title;
            if (item->badge && *item->badge)
                gtk_accessible_update_property(GTK_ACCESSIBLE(row), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, item->badge, -1);
        }
        gtk_button_set_child(GTK_BUTTON(row), box);
        gtk_accessible_update_property(GTK_ACCESSIBLE(row), GTK_ACCESSIBLE_PROPERTY_LABEL, name, -1);
        g_object_set_data(G_OBJECT(row), "szfriends-index", GINT_TO_POINTER(i));
        g_signal_connect(row, "clicked", G_CALLBACK(row_clicked), picker);
        gtk_box_append(GTK_BOX(picker->rows), row);
    }
    gtk_widget_set_visible(picker->rows, picker->choices->len > 0);
    select_row(picker, selected);
}

static void show_empty(SZFriendsGtkPicker *picker, gboolean answered) {
    if (picker->empty)
        gtk_widget_set_visible(picker->empty, answered && !picker->choices->len &&
                                                  *gtk_label_get_text(GTK_LABEL(picker->empty)));
}

/* ---- `#`: the host's items -------------------------------------------------------------------------- */

static void fill(SZFriendsGtkPicker *picker, GPtrArray *items) {
    g_ptr_array_set_size(picker->choices, 0);
    for (guint i = 0; items && i < items->len && i < SZFRIENDS_GTK_PICKER_ROWS; i++)
        g_ptr_array_add(picker->choices, szfriends_gtk_host_item_copy(g_ptr_array_index(items, i)));
}

static void items_ready(GPtrArray *items, gpointer data) {
    SZFriendsGtkPicker *picker = pending_pickers ? g_hash_table_lookup(pending_pickers, data) : NULL;
    if (pending_pickers) g_hash_table_remove(pending_pickers, data);
    /* A slower answer to an older query must not replace a newer one. */
    if (picker && GPOINTER_TO_UINT(data) == picker->request) {
        gboolean replaces = picker->waiting && picker->choices->len;
        picker->waiting = FALSE;
        fill(picker, items);
        show_rows_selecting(picker, replaces ? picker->selected : 0);
        show_empty(picker, TRUE);
        if (picker->choose_when_answered) {
            picker->choose_when_answered = FALSE;
            if (items) g_ptr_array_unref(items);
            choose(picker, picker->selected); /* may free the picker */
            return;
        }
    }
    if (items) g_ptr_array_unref(items);
}

static void ask_host(SZFriendsGtkPicker *picker, const char *query) {
    SZFriendsGtkConversation *conversation = szfriends_gtk_composer_conversation(picker->composer);
    const SZFriendsGtkHost *host = szfriends_gtk_link_host(conversation->link);
    if (!host->attachable_items) return;
    if (picker->cancellable) g_cancellable_cancel(picker->cancellable);
    g_clear_object(&picker->cancellable);
    picker->cancellable = g_cancellable_new();
    if (!pending_pickers) pending_pickers = g_hash_table_new(g_direct_hash, g_direct_equal);
    if (picker->request) g_hash_table_remove(pending_pickers, GUINT_TO_POINTER(picker->request));
    picker->request = ++next_request;
    g_hash_table_insert(pending_pickers, GUINT_TO_POINTER(picker->request), picker);
    GtkWindow *window = conversation->dropdown ? szfriends_gtk_dropdown_get_window(conversation->dropdown) : NULL;
    /* The rows the host has at once, on this frame; without any, the rows shown stay until it answers. */
    GPtrArray *at_once = host->attachable_items_at_once
                             ? host->attachable_items_at_once(host->host_data, window, query) : NULL;
    picker->waiting = TRUE;
    picker->choose_when_answered = FALSE;
    if (at_once && at_once->len) {
        fill(picker, at_once);
        show_rows(picker);
        show_empty(picker, FALSE);
    }
    if (at_once) g_ptr_array_unref(at_once);
    host->attachable_items(host->host_data, window, query, picker->cancellable, items_ready,
                           GUINT_TO_POINTER(picker->request));
}

/* ---- `@`: friends who may be mentioned ------------------------------------------------------------------ */

static void list_arrived(JsonObject *data, gint64 rev, gpointer user_data) {
    (void)rev;
    SZFriendsGtkPicker *picker = user_data;
    SZFriendsGtkListSnapshot *list = szfriends_gtk_list_snapshot_parse(data);
    g_ptr_array_set_size(picker->choices, 0);
    for (gsize i = 0; i < list->n_rows && picker->choices->len < SZFRIENDS_GTK_PICKER_ROWS; i++) {
        const SZFriendsGtkListRow *row = &list->rows[i];
        if (!row->mentionable || !*row->conversation_id) continue;
        SZFriendsGtkMentionChoice *choice = g_new0(SZFriendsGtkMentionChoice, 1);
        choice->conversation_id = g_strdup(row->conversation_id);
        choice->name = g_strdup(row->title); /* as AppKit's picker lists them: names, the "@" only on the chip */
        choice->avatar = row->avatar;
        choice->avatar.initials = g_strdup(row->avatar.initials);
        choice->avatar.color = g_strdup(row->avatar.color);
        choice->avatar.path = g_strdup(row->avatar.path);
        g_ptr_array_add(picker->choices, choice);
    }
    szfriends_gtk_list_snapshot_free(list);
    show_rows(picker);
}

/* ---- The panel ------------------------------------------------------------------------------------------ */

static void query_changed(GtkSearchEntry *entry, gpointer data) {
    SZFriendsGtkPicker *picker = data;
    SZFriendsGtkLink *link = szfriends_gtk_composer_conversation(picker->composer)->link;
    szfriends_gtk_link_set_filter(link, picker->subscription, gtk_editable_get_text(GTK_EDITABLE(entry)));
}

void szfriends_gtk_picker_follow(GtkWidget *panel) {
    SZFriendsGtkPicker *picker = picker_of(panel);
    if (!picker || picker->mentions) return;
    GtkTextIter start, end;
    if (!typed_range(picker, &start, &end)) {
        szfriends_gtk_composer_close_picker(picker->composer);
        return;
    }
    gtk_text_iter_forward_char(&start);
    char *query = gtk_text_iter_get_text(&start, &end);
    if (g_strcmp0(query, picker->query) == 0) {
        g_free(query);
        return;
    }
    g_free(picker->query);
    picker->query = query;
    ask_host(picker, query);
}

static void activated(GtkSearchEntry *entry, gpointer data) {
    (void)entry;
    SZFriendsGtkPicker *picker = data;
    choose(picker, picker->selected);
}

gboolean szfriends_gtk_picker_key(GtkWidget *panel, guint keyval) {
    SZFriendsGtkPicker *picker = picker_of(panel);
    if (!picker) return FALSE;
    gboolean enter = keyval == GDK_KEY_Return || keyval == GDK_KEY_KP_Enter || keyval == GDK_KEY_ISO_Enter;
    /* Return is the `#` picker's while it is open, rows or not: it never also sends the message. */
    if (enter && !picker->mentions) {
        choose(picker, picker->selected);
        return TRUE;
    }
    /* With no rows the arrows stay the composer's: they move the insertion point. */
    if (!picker->choices->len) return FALSE;
    if (keyval == GDK_KEY_Down || keyval == GDK_KEY_KP_Down) select_row(picker, picker->selected + 1);
    else if (keyval == GDK_KEY_Up || keyval == GDK_KEY_KP_Up) select_row(picker, picker->selected - 1);
    else if (keyval == GDK_KEY_Return || keyval == GDK_KEY_KP_Enter) choose(picker, picker->selected);
    else return FALSE;
    return TRUE;
}

static gboolean entry_key(GtkEventControllerKey *keys, guint keyval, guint keycode, GdkModifierType state,
                          gpointer data) {
    (void)keys, (void)keycode, (void)state;
    SZFriendsGtkPicker *picker = data;
    return keyval != GDK_KEY_Return && keyval != GDK_KEY_KP_Enter && szfriends_gtk_picker_key(picker->panel, keyval);
}

guint szfriends_gtk_picker_row_count(GtkWidget *panel) {
    SZFriendsGtkPicker *picker = picker_of(panel);
    return picker ? picker->choices->len : 0;
}

static GtkWidget *footer_label(const char *text, float xalign) {
    GtkWidget *label = gtk_label_new(text);
    gtk_widget_add_css_class(label, "szfriends-caption");
    gtk_label_set_xalign(GTK_LABEL(label), xalign);
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_widget_set_hexpand(label, TRUE);
    gtk_widget_set_visible(label, text && *text);
    return label;
}

GtkWidget *szfriends_gtk_picker_new(SZFriendsGtkComposerView *composer, gboolean mentions) {
    SZFriendsGtkConversation *conversation = szfriends_gtk_composer_conversation(composer);
    SZFriendsGtkLink *link = conversation->link;
    SZFriendsGtkPicker *picker = g_new0(SZFriendsGtkPicker, 1);
    picker->composer = composer;
    picker->mentions = mentions;
    picker->choices = g_ptr_array_new_with_free_func(mentions ? choice_free
                                                              : (GDestroyNotify)szfriends_gtk_host_item_free);
    picker->panel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_add_css_class(picker->panel, "szfriends-picker");
    gtk_widget_set_valign(picker->panel, GTK_ALIGN_END);
    g_object_set_data(G_OBJECT(picker->panel), "szfriends-picker", picker);
    if (mentions) {
        /* `@` searches in its own field, in the helper's words (AppKit's picker shows the same). */
        picker->entry = gtk_search_entry_new();
        const char *placeholder = szfriends_gtk_link_string(link, "search_placeholder");
        if (placeholder && *placeholder)
            gtk_search_entry_set_placeholder_text(GTK_SEARCH_ENTRY(picker->entry), placeholder);
        gtk_search_entry_set_search_delay(GTK_SEARCH_ENTRY(picker->entry), 100);
        g_signal_connect(picker->entry, "search-changed", G_CALLBACK(query_changed), picker);
        g_signal_connect(picker->entry, "activate", G_CALLBACK(activated), picker);
        GtkEventController *keys = gtk_event_controller_key_new();
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
        g_signal_connect(keys, "key-pressed", G_CALLBACK(entry_key), picker);
        gtk_widget_add_controller(picker->entry, keys);
        gtk_box_append(GTK_BOX(picker->panel), picker->entry);
    }
    picker->rows = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_box_append(GTK_BOX(picker->panel), picker->rows);
    if (!mentions) {
        const char *empty = szfriends_gtk_link_host(link)->attach_empty;
        picker->empty = gtk_label_new(empty ? empty : "");
        gtk_widget_add_css_class(picker->empty, "szfriends-secondary");
        gtk_label_set_xalign(GTK_LABEL(picker->empty), 0);
        gtk_label_set_ellipsize(GTK_LABEL(picker->empty), PANGO_ELLIPSIZE_END);
        /* Where a row's title would be. */
        gtk_widget_set_margin_start(picker->empty, 8);
        gtk_widget_set_margin_end(picker->empty, 8);
        gtk_widget_set_margin_top(picker->empty, 8);
        gtk_widget_set_margin_bottom(picker->empty, 8);
        gtk_widget_set_visible(picker->empty, FALSE);
        gtk_box_append(GTK_BOX(picker->panel), picker->empty);
        picker->query = g_strdup("");
    }
    GtkWidget *footer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    if (mentions) {
        /* What the friend gets, written from the sender's side by the helper. */
        gtk_box_append(GTK_BOX(footer), footer_label(szfriends_gtk_composer_mention_note(composer), 0));
    } else {
        gtk_box_append(GTK_BOX(footer), footer_label(szfriends_gtk_link_string(link, "attach_keys"), 0));
        gtk_box_append(GTK_BOX(footer), footer_label(szfriends_gtk_link_string(link, "attach_note"), 1));
    }
    gtk_box_append(GTK_BOX(picker->panel), footer);
    show_rows(picker);
    if (mentions) picker->subscription = szfriends_gtk_link_subscribe(link, "list", NULL, list_arrived, picker, NULL);
    else ask_host(picker, "");
    return picker->panel;
}

void szfriends_gtk_picker_free_state(GtkWidget *panel) {
    SZFriendsGtkPicker *picker = picker_of(panel);
    if (!picker) return;
    g_object_set_data(G_OBJECT(panel), "szfriends-picker", NULL);
    /* The entry's delayed search-changed, and anything still queued for the rows, must not find this state. */
    for (GtkWidget *row = gtk_widget_get_first_child(picker->rows); row; row = gtk_widget_get_next_sibling(row))
        g_signal_handlers_disconnect_by_data(row, picker);
    if (picker->entry) {
        g_signal_handlers_disconnect_by_data(picker->entry, picker);
        GListModel *controllers = gtk_widget_observe_controllers(picker->entry);
        for (guint i = 0; i < g_list_model_get_n_items(controllers); i++) {
            GObject *controller = g_list_model_get_item(controllers, i);
            g_signal_handlers_disconnect_by_data(controller, picker);
            g_object_unref(controller);
        }
        g_object_unref(controllers);
    }
    SZFriendsGtkLink *link = szfriends_gtk_composer_conversation(picker->composer)->link;
    if (picker->subscription) szfriends_gtk_link_unsubscribe(link, picker->subscription);
    if (picker->request && pending_pickers) g_hash_table_remove(pending_pickers, GUINT_TO_POINTER(picker->request));
    if (picker->cancellable) g_cancellable_cancel(picker->cancellable);
    g_clear_object(&picker->cancellable);
    g_ptr_array_unref(picker->choices);
    g_free(picker->query);
    g_free(picker);
}

/* ---- Opening and closing, for the composer ----------------------------------------------------------- */

static void open_picker(SZFriendsGtkComposerView *composer, gboolean mentions) {
    SZFriendsGtkConversation *conversation = szfriends_gtk_composer_conversation(composer);
    if (!conversation->content) return;
    szfriends_gtk_composer_close_picker(composer);
    GtkWidget *panel = szfriends_gtk_picker_new(composer, mentions);
    szfriends_gtk_composer_set_picker(composer, panel);
    gtk_overlay_add_overlay(GTK_OVERLAY(conversation->content), panel);
    /* `@` types in its field; `#` follows what is typed in the composer, which keeps the focus. */
    if (mentions) gtk_widget_grab_focus(picker_of(panel)->entry);
    else szfriends_gtk_picker_follow(panel);
}

void szfriends_gtk_composer_open_attach_picker(SZFriendsGtkComposerView *composer) {
    open_picker(composer, FALSE);
}

void szfriends_gtk_composer_open_mention_picker(SZFriendsGtkComposerView *composer) {
    open_picker(composer, TRUE);
}

void szfriends_gtk_composer_close_picker(SZFriendsGtkComposerView *composer) {
    GtkWidget *panel = szfriends_gtk_composer_get_picker(composer);
    if (!panel) return;
    szfriends_gtk_composer_set_picker(composer, NULL);
    szfriends_gtk_picker_free_state(panel);
    GtkWidget *overlay = gtk_widget_get_parent(panel);
    if (overlay) gtk_overlay_remove_overlay(GTK_OVERLAY(overlay), panel);
    GtkWidget *text = szfriends_gtk_composer_get_text_view(composer);
    if (gtk_widget_get_mapped(text) && !gtk_widget_has_focus(text)) gtk_widget_grab_focus(text);
}

gboolean szfriends_gtk_composer_escape(SZFriendsGtkComposerView *composer) {
    if (!composer || !szfriends_gtk_composer_get_picker(composer)) return FALSE;
    szfriends_gtk_composer_close_picker(composer);
    return TRUE;
}
