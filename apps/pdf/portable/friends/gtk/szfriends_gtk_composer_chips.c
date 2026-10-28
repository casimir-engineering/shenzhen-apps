/* The composer's chips, drafts and drops (szfriends_gtk_composer_private.h): an @ chip is a child anchor in the text,
 * which GTK counts as U+FFFC, and goes out as U+FFFC with its friend in `mentions`; attachment chips sit above the
 * field; what is typed, attached and mentioned stays in the window's draft for the conversation; files dropped on the
 * composer become chips, sent with the next Send and never at once. */

#include "gtk/szfriends_gtk_composer_private.h"

#include <string.h>

#define FFFC SZFRIENDS_GTK_FFFC

/* ---- The message as pieces (display-free) ---------------------------------------------------------- */

szfriends_intent *szfriends_gtk_composer_intent(const char *conversation_id, const SZFriendsGtkComposerPiece *pieces,
                                                gsize count, GPtrArray *items, const char *token) {
    GString *text = g_string_new(NULL);
    GPtrArray *ids = g_ptr_array_new();
    for (gsize i = 0; i < count; i++) {
        if (pieces[i].mention_id) {
            g_string_append(text, FFFC);
            g_ptr_array_add(ids, (gpointer)pieces[i].mention_id);
            continue;
        }
        /* A U+FFFC the person pasted would count as a mention the helper cannot match, failing the whole send. */
        for (const char *p = pieces[i].text ? pieces[i].text : ""; *p; p++)
            if (strncmp(p, FFFC, 3) == 0) p += 2;
            else g_string_append_c(text, *p);
    }
    szfriends_intent *intent = NULL;
    if ((text->len || (items && items->len)) && ids->len <= SZFRIENDS_GTK_MAX_MENTIONS) {
        intent = szfriends_gtk_intent_send_message(conversation_id, text->str, items, token);
        if (intent && ids->len)
            intent = szfriends_intent_with_mentions(intent, (const char *const *)ids->pdata, ids->len);
    }
    g_ptr_array_unref(ids);
    g_string_free(text, TRUE);
    return intent;
}

/* Walks the buffer: words, and each anchor that is one of our chips; a pasted object character is dropped. */
GArray *szfriends_gtk_composer_pieces(SZFriendsGtkComposerView *composer, GPtrArray *strings) {
    GArray *pieces = g_array_new(FALSE, TRUE, sizeof(SZFriendsGtkComposerPiece));
    GString *run = g_string_new(NULL);
    GtkTextIter iter;
    gtk_text_buffer_get_start_iter(composer->buffer, &iter);
    for (; !gtk_text_iter_is_end(&iter); gtk_text_iter_forward_char(&iter)) {
        GtkTextChildAnchor *anchor = gtk_text_iter_get_child_anchor(&iter);
        const char *id = anchor ? g_object_get_data(G_OBJECT(anchor), "szfriends-mention-id") : NULL;
        gunichar c = gtk_text_iter_get_char(&iter);
        if (!id) {
            if (c != 0xFFFC) g_string_append_unichar(run, c);
            continue;
        }
        if (run->len) {
            char *words = g_strdup(run->str);
            g_ptr_array_add(strings, words);
            g_array_append_val(pieces, ((SZFriendsGtkComposerPiece){words, NULL}));
            g_string_truncate(run, 0);
        }
        g_array_append_val(pieces, ((SZFriendsGtkComposerPiece){NULL, id}));
    }
    if (run->len) {
        char *words = g_strdup(run->str);
        g_ptr_array_add(strings, words);
        g_array_append_val(pieces, ((SZFriendsGtkComposerPiece){words, NULL}));
    }
    g_string_free(run, TRUE);
    return pieces;
}

guint szfriends_gtk_composer_mention_count(SZFriendsGtkComposerView *composer) {
    GPtrArray *strings = g_ptr_array_new_with_free_func(g_free);
    GArray *pieces = szfriends_gtk_composer_pieces(composer, strings);
    guint count = 0;
    for (guint i = 0; i < pieces->len; i++)
        count += g_array_index(pieces, SZFriendsGtkComposerPiece, i).mention_id != NULL;
    g_array_unref(pieces);
    g_ptr_array_unref(strings);
    return count;
}

/* ---- Drafts --------------------------------------------------------------------------------------- */

/* The chips' ids and labels per conversation, in order, beside the dropdown's drafts (whose text holds U+FFFC). */
static GPtrArray *draft_chips(SZFriendsGtkComposerView *composer, gboolean create) {
    SZFriendsGtkDropdown *dropdown = composer->conversation->dropdown;
    if (!dropdown) return NULL;
    GObject *owner = G_OBJECT(szfriends_gtk_dropdown_get_content(dropdown));
    GHashTable *all = g_object_get_data(owner, "szfriends-mention-drafts");
    if (!all && create) {
        all = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GDestroyNotify)g_ptr_array_unref);
        g_object_set_data_full(owner, "szfriends-mention-drafts", all, (GDestroyNotify)g_hash_table_unref);
    }
    GPtrArray *chips = all ? g_hash_table_lookup(all, composer->conversation->conversation_id) : NULL;
    if (!chips && all && create) {
        chips = g_ptr_array_new_with_free_func(g_free);
        g_hash_table_insert(all, g_strdup(composer->conversation->conversation_id), chips);
    }
    return chips;
}

void szfriends_gtk_composer_save_draft(SZFriendsGtkComposerView *composer) {
    if (composer->restoring) return;
    GPtrArray *chips = draft_chips(composer, TRUE);
    if (chips) g_ptr_array_set_size(chips, 0);
    GString *text = g_string_new(NULL);
    GtkTextIter iter;
    gtk_text_buffer_get_start_iter(composer->buffer, &iter);
    for (; !gtk_text_iter_is_end(&iter); gtk_text_iter_forward_char(&iter)) {
        GtkTextChildAnchor *anchor = gtk_text_iter_get_child_anchor(&iter);
        const char *id = anchor ? g_object_get_data(G_OBJECT(anchor), "szfriends-mention-id") : NULL;
        gunichar c = gtk_text_iter_get_char(&iter);
        if (id && chips) {
            g_string_append(text, FFFC);
            g_ptr_array_add(chips, g_strdup(id));
            g_ptr_array_add(chips, g_strdup(g_object_get_data(G_OBJECT(anchor), "szfriends-mention-label")));
        } else if (c != 0xFFFC) {
            g_string_append_unichar(text, c);
        }
    }
    g_free(composer->draft->text);
    composer->draft->text = g_string_free(text, FALSE);
}

/* ---- The @ chip, on the line's baseline ------------------------------------------------------------------ */

/* GtkTextView sits a widget at an anchor with its bottom edge on the line's baseline (gtktextlayout.c: its height
 * becomes the shape's ascent), so a plain label's words rode its descent, about 2 points, above the words around it.
 * This box asks only for the height down to its label's baseline and lets the label hang below by its descent, so
 * the chip's words and the line's share one baseline; the fill reaches below them as a pill around words does. */
#define SZFRIENDS_GTK_TYPE_CHIP_BOX (szfriends_gtk_chip_box_get_type())
G_DECLARE_FINAL_TYPE(SZFriendsGtkChipBox, szfriends_gtk_chip_box, SZFRIENDS_GTK, CHIP_BOX, GtkWidget)

struct _SZFriendsGtkChipBox {
    GtkWidget parent;
};

G_DEFINE_FINAL_TYPE(SZFriendsGtkChipBox, szfriends_gtk_chip_box, GTK_TYPE_WIDGET)

static void chip_measure(GtkWidget *widget, GtkOrientation orientation, int for_size, int *minimum, int *natural,
                         int *minimum_baseline, int *natural_baseline) {
    (void)minimum_baseline, (void)natural_baseline;
    GtkWidget *label = gtk_widget_get_first_child(widget);
    int baseline = -1, unused = -1;
    gtk_widget_measure(label, orientation, orientation == GTK_ORIENTATION_HORIZONTAL ? for_size : -1, minimum,
                       natural, &unused, &baseline);
    /* The label's baseline counts from its margin box, its padding and border included. */
    if (orientation == GTK_ORIENTATION_VERTICAL && baseline >= 0) *minimum = *natural = baseline;
}

static void chip_allocate(GtkWidget *widget, int width, int height, int baseline) {
    (void)height, (void)baseline;
    GtkWidget *label = gtk_widget_get_first_child(widget);
    int minimum = 0, natural = 0;
    gtk_widget_measure(label, GTK_ORIENTATION_VERTICAL, width, &minimum, &natural, NULL, NULL);
    gtk_widget_allocate(label, width, natural, -1, NULL); /* taller than the box: the descent hangs below */
}

static void chip_dispose(GObject *object) {
    GtkWidget *label;
    while ((label = gtk_widget_get_first_child(GTK_WIDGET(object)))) gtk_widget_unparent(label);
    G_OBJECT_CLASS(szfriends_gtk_chip_box_parent_class)->dispose(object);
}

static void szfriends_gtk_chip_box_class_init(SZFriendsGtkChipBoxClass *klass) {
    GTK_WIDGET_CLASS(klass)->measure = chip_measure;
    GTK_WIDGET_CLASS(klass)->size_allocate = chip_allocate;
    G_OBJECT_CLASS(klass)->dispose = chip_dispose;
}

static void szfriends_gtk_chip_box_init(SZFriendsGtkChipBox *box) {
    (void)box;
}

static void add_chip(SZFriendsGtkComposerView *composer, GtkTextIter *at, const char *id, const char *label) {
    GtkTextChildAnchor *anchor = gtk_text_buffer_create_child_anchor(composer->buffer, at);
    g_object_set_data_full(G_OBJECT(anchor), "szfriends-mention-id", g_strdup(id), g_free);
    g_object_set_data_full(G_OBJECT(anchor), "szfriends-mention-label", g_strdup(label), g_free);
    GtkWidget *words = gtk_label_new(label);
    gtk_widget_add_css_class(words, "szfriends-mention-chip");
    gtk_accessible_update_property(GTK_ACCESSIBLE(words), GTK_ACCESSIBLE_PROPERTY_LABEL, label, -1);
    GtkWidget *chip = g_object_new(SZFRIENDS_GTK_TYPE_CHIP_BOX, NULL);
    gtk_widget_set_parent(words, chip);
    gtk_text_view_add_child_at_anchor(GTK_TEXT_VIEW(composer->text_view), chip, anchor);
}

void szfriends_gtk_composer_restore_draft(SZFriendsGtkComposerView *composer) {
    GPtrArray *chips = draft_chips(composer, FALSE);
    composer->restoring = TRUE;
    GtkTextIter end;
    guint chip = 0;
    const char *text = composer->draft->text ? composer->draft->text : "";
    for (const char *p = text; *p;) {
        const char *mark = strstr(p, FFFC);
        gsize length = mark ? (gsize)(mark - p) : strlen(p);
        gtk_text_buffer_get_end_iter(composer->buffer, &end);
        gtk_text_buffer_insert(composer->buffer, &end, p, (int)length);
        if (!mark) break;
        gtk_text_buffer_get_end_iter(composer->buffer, &end);
        if (chips && chip + 1 < chips->len)
            add_chip(composer, &end, g_ptr_array_index(chips, chip), g_ptr_array_index(chips, chip + 1));
        chip += 2;
        p = mark + 3;
    }
    composer->restoring = FALSE;
}

/* ---- Chips for attachments -------------------------------------------------------------------------- */

static void remove_attachment(GtkButton *button, gpointer data) {
    SZFriendsGtkComposerView *composer = data;
    guint index = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(button), "szfriends-index"));
    if (index < composer->draft->items->len) g_ptr_array_remove_index(composer->draft->items, index);
    szfriends_gtk_composer_add_items(composer, NULL); /* redraws the chips */
}

void szfriends_gtk_composer_add_items(SZFriendsGtkComposerView *composer, GPtrArray *items) {
    for (guint i = 0; items && i < items->len; i++)
        g_ptr_array_add(composer->draft->items, szfriends_gtk_host_item_copy(g_ptr_array_index(items, i)));
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(composer->chips))) adw_wrap_box_remove(ADW_WRAP_BOX(composer->chips),
                                                                                     child);
    for (guint i = 0; i < composer->draft->items->len; i++) {
        SZFriendsGtkHostItem *item = g_ptr_array_index(composer->draft->items, i);
        GtkWidget *chip = gtk_button_new();
        GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
        GtkWidget *title = gtk_label_new(item->title);
        gtk_label_set_ellipsize(GTK_LABEL(title), PANGO_ELLIPSIZE_MIDDLE);
        gtk_label_set_max_width_chars(GTK_LABEL(title), 28);
        gtk_box_append(GTK_BOX(box), title);
        gtk_box_append(GTK_BOX(box), gtk_image_new_from_icon_name("window-close-symbolic"));
        gtk_button_set_child(GTK_BUTTON(chip), box);
        gtk_widget_add_css_class(chip, "szfriends-chip");
        gtk_widget_set_tooltip_text(chip, item->detail && *item->detail ? item->detail : NULL);
        gtk_accessible_update_property(GTK_ACCESSIBLE(chip), GTK_ACCESSIBLE_PROPERTY_LABEL, item->title, -1);
        g_object_set_data(G_OBJECT(chip), "szfriends-index", GUINT_TO_POINTER(i));
        g_signal_connect(chip, "clicked", G_CALLBACK(remove_attachment), composer);
        adw_wrap_box_append(ADW_WRAP_BOX(composer->chips), chip);
    }
    gtk_widget_set_visible(composer->chips, composer->draft->items->len > 0);
}

void szfriends_gtk_composer_insert_mention(SZFriendsGtkComposerView *composer, const char *conversation_id,
                                           const char *label) {
    if (szfriends_gtk_composer_mention_count(composer) >= SZFRIENDS_GTK_MAX_MENTIONS) return;
    GtkTextIter cursor, before;
    gtk_text_buffer_get_iter_at_mark(composer->buffer, &cursor, gtk_text_buffer_get_insert(composer->buffer));
    before = cursor;
    composer->restoring = TRUE; /* one draft save once the chip carries its friend */
    /* The `@` typed to open the picker becomes the chip. */
    if (gtk_text_iter_backward_char(&before) && gtk_text_iter_get_char(&before) == '@') {
        gtk_text_buffer_delete(composer->buffer, &before, &cursor);
        gtk_text_buffer_get_iter_at_mark(composer->buffer, &cursor, gtk_text_buffer_get_insert(composer->buffer));
    }
    add_chip(composer, &cursor, conversation_id, label);
    if (!g_unichar_isspace(gtk_text_iter_get_char(&cursor))) gtk_text_buffer_insert(composer->buffer, &cursor, " ", 1);
    composer->restoring = FALSE;
    szfriends_gtk_composer_save_draft(composer);
}

void szfriends_gtk_composer_attach(SZFriendsGtkComposerView *composer, const SZFriendsGtkHostItem *item) {
    g_ptr_array_add(composer->draft->items, szfriends_gtk_host_item_copy(item));
    szfriends_gtk_composer_add_items(composer, NULL);
    szfriends_gtk_composer_save_draft(composer);
}

/* ---- Drops: chips, never an immediate send ------------------------------------------------------------ */

static void show_verdict(SZFriendsGtkComposerView *composer, SZFriendsGtkDropVerdict verdict) {
    SZFriendsGtkLink *link = composer->conversation->link;
    const char *shown = szfriends_gtk_drop_refusal(link, composer->verdict);
    composer->verdict = verdict;
    gboolean refused = szfriends_gtk_drop_refused(verdict);
    gtk_widget_remove_css_class(composer->input_box, "szfriends-drop-accept");
    gtk_widget_remove_css_class(composer->input_box, "szfriends-drop-refuse");
    if (verdict == SZFRIENDS_GTK_DROP_ACCEPT) gtk_widget_add_css_class(composer->input_box, "szfriends-drop-accept");
    if (refused) gtk_widget_add_css_class(composer->input_box, "szfriends-drop-refuse");
    /* The refusal shows under the field while the files hover, in the helper's words, and goes with them. */
    if (refused) szfriends_gtk_composer_set_error(composer, szfriends_gtk_drop_refusal(link, verdict));
    else if (*shown && strcmp(gtk_label_get_text(GTK_LABEL(composer->error)), shown) == 0)
        szfriends_gtk_composer_set_error(composer, NULL);
}

void szfriends_gtk_composer_drag_value(SZFriendsGtkComposerView *composer, const GValue *value) {
    show_verdict(composer, value ? szfriends_gtk_drop_verdict(szfriends_gtk_link_host(composer->conversation->link),
                                                              value) : SZFRIENDS_GTK_DROP_NONE);
}

gboolean szfriends_gtk_composer_drop(SZFriendsGtkComposerView *composer, const GValue *value) {
    SZFriendsGtkDropVerdict verdict = SZFRIENDS_GTK_DROP_NONE;
    GPtrArray *items = szfriends_gtk_drop_items(szfriends_gtk_link_host(composer->conversation->link), value,
                                                &verdict);
    show_verdict(composer, SZFRIENDS_GTK_DROP_NONE);
    gboolean taken = composer->enabled && composer->accepts_drops && verdict == SZFRIENDS_GTK_DROP_ACCEPT &&
                     items->len;
    if (taken) {
        szfriends_gtk_composer_add_items(composer, items);
        szfriends_gtk_composer_save_draft(composer);
    }
    g_ptr_array_unref(items);
    return taken;
}

static gboolean drop_accept(GtkDropTarget *target, GdkDrop *drop, gpointer data) {
    SZFriendsGtkComposerView *composer = data;
    return composer->enabled && composer->accepts_drops &&
           gdk_content_formats_match(gtk_drop_target_get_formats(target), gdk_drop_get_formats(drop));
}

static void drop_value(GObject *target, GParamSpec *spec, gpointer data) {
    (void)spec;
    szfriends_gtk_composer_drag_value(data, gtk_drop_target_get_value(GTK_DROP_TARGET(target)));
}

static GdkDragAction drop_motion(GtkDropTarget *target, double x, double y, gpointer data) {
    (void)target, (void)x, (void)y;
    SZFriendsGtkComposerView *composer = data;
    return szfriends_gtk_drop_refused(composer->verdict) ? 0 : GDK_ACTION_COPY;
}

static void drop_leave(GtkDropTarget *target, gpointer data) {
    (void)target;
    show_verdict(data, SZFRIENDS_GTK_DROP_NONE);
}

static gboolean dropped(GtkDropTarget *target, const GValue *value, double x, double y, gpointer data) {
    (void)target, (void)x, (void)y;
    return szfriends_gtk_composer_drop(data, value);
}

void szfriends_gtk_composer_add_drop_target(SZFriendsGtkComposerView *composer, GtkWidget *widget) {
    gsize n_types = 0;
    GType *types = szfriends_gtk_drop_types(szfriends_gtk_link_host(composer->conversation->link), &n_types);
    GtkDropTarget *drop = gtk_drop_target_new(G_TYPE_INVALID, GDK_ACTION_COPY);
    gtk_drop_target_set_gtypes(drop, types, n_types);
    gtk_drop_target_set_preload(drop, TRUE); /* folders refuse while they hover, before any intent */
    g_free(types);
    g_signal_connect(drop, "accept", G_CALLBACK(drop_accept), composer);
    g_signal_connect(drop, "notify::value", G_CALLBACK(drop_value), composer);
    g_signal_connect(drop, "motion", G_CALLBACK(drop_motion), composer);
    g_signal_connect(drop, "leave", G_CALLBACK(drop_leave), composer);
    g_signal_connect(drop, "drop", G_CALLBACK(dropped), composer);
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(drop));
}
