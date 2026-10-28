/* The composer (szfriends_gtk_conversation.h; mirrors mac/SZFriendsComposerView.m): Return sends, Shift+Return breaks
 * the line, `#` opens the host's items, `@` the friends who may be mentioned, and files chosen with the paperclip
 * (Attach files), pasted (szfriends_gtk_composer_paste.c) or dropped become chips that go with the next Send;
 * nothing is sent until then.
 *
 * An @ chip is a child anchor in the text, which GTK counts as U+FFFC: the message goes out with one U+FFFC per chip
 * and one `mentions` entry per chip in the same order, and the helper writes each mention itself (PROTOCOL.md
 * § Mentions), so the view never handles a Friends ID or key. What is typed, attached and mentioned stays in the
 * window's draft for the conversation, so closing the dropdown or going back loses nothing. */

#include "gtk/szfriends_gtk_composer_private.h"
#include "gtk/szfriends_gtk_glyphs.h"
#include "gtk/szfriends_gtk_list_page.h"

static void composer_release(gpointer data) {
    SZFriendsGtkComposerView *composer = data;
    if (composer->own_draft) {
        g_free(composer->own_draft->text);
        g_ptr_array_unref(composer->own_draft->items);
        g_free(composer->own_draft);
    }
    g_free(composer->mention_note);
    szfriends_gtk_conversation_unref(composer->conversation);
}

static SZFriendsGtkComposerView *composer_ref(SZFriendsGtkComposerView *composer) {
    return g_rc_box_acquire(composer);
}

static void composer_unref(gpointer composer) {
    g_rc_box_release_full(composer, composer_release);
}

/* ---- Sending ----------------------------------------------------------------------------------------- */

void szfriends_gtk_composer_set_error(SZFriendsGtkComposerView *composer, const char *message) {
    gtk_label_set_text(GTK_LABEL(composer->error), message ? message : "");
    gtk_widget_set_visible(composer->error, message && *message);
}

static void sent(JsonObject *result, const SZFriendsGtkError *error, gpointer data) {
    (void)result;
    SZFriendsGtkComposerView *composer = data;
    composer->sending = FALSE;
    if (!composer->root) return;
    gtk_widget_set_sensitive(composer->send, composer->enabled);
    if (error) {
        /* The draft stays; the helper's message says what happened from the person's side. */
        szfriends_gtk_composer_set_error(composer, error->message);
        if (error->message && *error->message)
            gtk_accessible_announce(GTK_ACCESSIBLE(composer->text_view), error->message,
                                    GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM);
        return;
    }
    gtk_text_buffer_set_text(composer->buffer, "", -1);
    g_ptr_array_set_size(composer->draft->items, 0);
    szfriends_gtk_composer_add_items(composer, NULL);
    szfriends_gtk_composer_save_draft(composer);
}

void szfriends_gtk_composer_send(SZFriendsGtkComposerView *composer) {
    if (!composer->enabled || composer->sending) return;
    GPtrArray *strings = g_ptr_array_new_with_free_func(g_free);
    GArray *pieces = szfriends_gtk_composer_pieces(composer, strings);
    szfriends_intent *intent = szfriends_gtk_composer_intent(composer->conversation->conversation_id,
                                                             (SZFriendsGtkComposerPiece *)(void *)pieces->data,
                                                             pieces->len, composer->draft->items, NULL);
    g_array_unref(pieces);
    g_ptr_array_unref(strings);
    if (!intent) return;
    composer->sending = TRUE;
    gtk_widget_set_sensitive(composer->send, FALSE);
    szfriends_gtk_composer_set_error(composer, NULL);
    szfriends_gtk_link_send(composer->conversation->link, intent, sent, composer_ref(composer), composer_unref);
}

static void send_clicked(GtkButton *button, gpointer data) {
    (void)button;
    szfriends_gtk_composer_send(data);
}

/* ---- Attach files ---------------------------------------------------------------------------------------- */

void szfriends_gtk_composer_attach_files(SZFriendsGtkComposerView *composer, GSList *files) {
    if (!composer->root || !files) return;
    SZFriendsGtkLink *link = composer->conversation->link;
    SZFriendsGtkDropVerdict verdict = szfriends_gtk_drop_verdict_for_files(files);
    if (szfriends_gtk_drop_refused(verdict)) {
        szfriends_gtk_composer_set_error(composer, szfriends_gtk_drop_refusal(link, verdict));
    } else if (verdict == SZFRIENDS_GTK_DROP_ACCEPT) {
        GValue value = G_VALUE_INIT;
        g_value_init(&value, GDK_TYPE_FILE_LIST);
        g_value_take_boxed(&value, gdk_file_list_new_from_list(files));
        SZFriendsGtkDropVerdict taken = SZFRIENDS_GTK_DROP_NONE;
        GPtrArray *items = szfriends_gtk_drop_items(szfriends_gtk_link_host(link), &value, &taken);
        szfriends_gtk_composer_set_error(composer, NULL);
        if (items->len) {
            szfriends_gtk_composer_add_items(composer, items);
            szfriends_gtk_composer_save_draft(composer);
        }
        g_ptr_array_unref(items);
        g_value_unset(&value);
        gtk_widget_grab_focus(composer->text_view);
    }
}

static void files_chosen(GSList *files, gpointer data) {
    szfriends_gtk_composer_attach_files(data, files);
    composer_unref(data);
}

static void attach_clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkComposerView *composer = data;
    if (!composer->enabled || composer->sending) return;
    szfriends_gtk_choose_files(GTK_WIDGET(button), files_chosen, composer_ref(composer));
}

/* Named by the helper; without its words (an older helper) the paperclip stays hidden rather than unnamed. */
static void name_attach(SZFriendsGtkComposerView *composer) {
    const char *label = szfriends_gtk_link_string(composer->conversation->link, "attach_files");
    gboolean named = label && *label;
    gtk_widget_set_tooltip_text(composer->attach, named ? label : NULL);
    if (named) gtk_accessible_update_property(GTK_ACCESSIBLE(composer->attach), GTK_ACCESSIBLE_PROPERTY_LABEL, label, -1);
    gtk_widget_set_visible(composer->attach, named);
}

/* ---- Typing --------------------------------------------------------------------------------------------- */

static gboolean key_pressed(GtkEventControllerKey *keys, guint keyval, guint keycode, GdkModifierType state,
                            gpointer data) {
    (void)keys, (void)keycode;
    SZFriendsGtkComposerView *composer = data;
    if (keyval != GDK_KEY_Return && keyval != GDK_KEY_KP_Enter && keyval != GDK_KEY_ISO_Enter) return FALSE;
    /* Return while an input method composes (pinyin, kana) commits what it composed; it never sends. */
    if (composer->preedit || (state & GDK_SHIFT_MASK)) return FALSE;
    szfriends_gtk_composer_send(composer);
    return TRUE;
}

static void preedit_changed(GtkTextView *view, const char *preedit, gpointer data) {
    (void)view;
    ((SZFriendsGtkComposerView *)data)->preedit = preedit && *preedit;
}

static gboolean open_picker_later(gpointer data) {
    SZFriendsGtkComposerView *composer = data;
    gboolean mentions = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(composer->buffer), "szfriends-picker-kind"));
    if (composer->root) {
        if (mentions) szfriends_gtk_composer_open_mention_picker(composer);
        else szfriends_gtk_composer_open_attach_picker(composer);
    }
    composer_unref(composer);
    return G_SOURCE_REMOVE;
}

static void inserted(GtkTextBuffer *buffer, GtkTextIter *at, const char *text, int length, gpointer data) {
    (void)at;
    SZFriendsGtkComposerView *composer = data;
    if (composer->restoring || !composer->enabled || length != 1 || (text[0] != '#' && text[0] != '@')) return;
    /* `@` only where the helper writes mentions: an older one would send each U+FFFC as it is (PROTOCOL.md). */
    gboolean mentions = text[0] == '@';
    if (mentions && (!szfriends_gtk_link_helper_has_capability(composer->conversation->link, "mentions") ||
                     szfriends_gtk_composer_mention_count(composer) >= SZFRIENDS_GTK_MAX_MENTIONS))
        return;
    if (!mentions && !szfriends_gtk_link_host(composer->conversation->link)->attachable_items) return;
    /* The picker takes focus; that waits until the buffer finished inserting. */
    g_object_set_data(G_OBJECT(buffer), "szfriends-picker-kind", GINT_TO_POINTER(mentions));
    g_idle_add(open_picker_later, composer_ref(composer));
}

static void changed(GtkTextBuffer *buffer, gpointer data) {
    SZFriendsGtkComposerView *composer = data;
    gtk_widget_set_visible(composer->placeholder, gtk_text_buffer_get_char_count(buffer) == 0);
    szfriends_gtk_composer_save_draft(composer);
}

/* ---- Building and applying ------------------------------------------------------------------------- */

static GtkWidget *wrapping_label(const char *css_class) {
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_widget_add_css_class(label, css_class);
    gtk_widget_set_visible(label, FALSE);
    return label;
}

static void root_gone(gpointer data, GObject *where) {
    (void)where;
    SZFriendsGtkComposerView *composer = data;
    composer->root = NULL;
    if (composer->conversation->composer == composer) composer->conversation->composer = NULL;
    composer_unref(composer);
}

GtkWidget *szfriends_gtk_composer_new(SZFriendsGtkConversation *conversation) {
    SZFriendsGtkComposerView *composer = g_rc_box_new0(SZFriendsGtkComposerView);
    composer->conversation = szfriends_gtk_conversation_ref(conversation);
    composer->enabled = TRUE;
    if (conversation->dropdown) {
        composer->draft = szfriends_gtk_dropdown_get_draft(conversation->dropdown, conversation->conversation_id);
    } else {
        composer->own_draft = composer->draft = g_new0(SZFriendsGtkDraft, 1);
        composer->draft->items = g_ptr_array_new_with_free_func((GDestroyNotify)szfriends_gtk_host_item_free);
    }
    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    composer->root = root;
    g_object_weak_ref(G_OBJECT(root), root_gone, composer);
    g_object_set_data(G_OBJECT(root), "szfriends-composer", composer);
    gtk_widget_add_css_class(root, "szfriends-composer");
    composer->note = wrapping_label("szfriends-secondary");
    composer->error = wrapping_label("szfriends-failure");
    composer->chips = adw_wrap_box_new();
    adw_wrap_box_set_child_spacing(ADW_WRAP_BOX(composer->chips), 6);
    adw_wrap_box_set_line_spacing(ADW_WRAP_BOX(composer->chips), 6);
    gtk_widget_set_visible(composer->chips, FALSE);
    composer->input_box = gtk_overlay_new();
    gtk_widget_add_css_class(composer->input_box, "szfriends-composer-input");
    GtkWidget *scroller = gtk_scrolled_window_new();
    /* A 56 px field, as AppKit's, growing to 120 px with what is typed, then scrolling. An external policy scrolls
     * without asking for the scrollbar's own 58 px, which would set the field's height instead. */
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroller), GTK_POLICY_NEVER, GTK_POLICY_EXTERNAL);
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(scroller), TRUE);
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroller), 48);
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(scroller), 112);
    composer->text_view = gtk_text_view_new();
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(composer->text_view), GTK_WRAP_WORD_CHAR);
    /* The same inset as the placeholder's margin (szfriends_gtk_conversation_state.c), so typing starts where the
     * placeholder's words were. */
    gtk_text_view_set_left_margin(GTK_TEXT_VIEW(composer->text_view), 6);
    gtk_text_view_set_right_margin(GTK_TEXT_VIEW(composer->text_view), 6);
    gtk_text_view_set_top_margin(GTK_TEXT_VIEW(composer->text_view), 6);
    gtk_text_view_set_bottom_margin(GTK_TEXT_VIEW(composer->text_view), 6);
    gtk_text_view_set_accepts_tab(GTK_TEXT_VIEW(composer->text_view), FALSE);
    gtk_widget_add_css_class(composer->text_view, "szfriends-composer-text");
    composer->buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(composer->text_view));
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), composer->text_view);
    gtk_overlay_set_child(GTK_OVERLAY(composer->input_box), scroller);
    composer->placeholder = gtk_label_new(NULL);
    gtk_widget_add_css_class(composer->placeholder, "szfriends-composer-placeholder");
    gtk_widget_set_halign(composer->placeholder, GTK_ALIGN_START);
    gtk_widget_set_valign(composer->placeholder, GTK_ALIGN_START);
    gtk_widget_set_can_target(composer->placeholder, FALSE);
    gtk_label_set_ellipsize(GTK_LABEL(composer->placeholder), PANGO_ELLIPSIZE_END);
    gtk_overlay_add_overlay(GTK_OVERLAY(composer->input_box), composer->placeholder);
    GtkWidget *bottom = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    composer->hint = gtk_label_new(NULL);
    gtk_widget_add_css_class(composer->hint, "szfriends-hint");
    gtk_label_set_ellipsize(GTK_LABEL(composer->hint), PANGO_ELLIPSIZE_END);
    gtk_label_set_xalign(GTK_LABEL(composer->hint), 0);
    gtk_widget_set_hexpand(composer->hint, TRUE);
    composer->send = gtk_button_new();
    gtk_widget_add_css_class(composer->send, "suggested-action");
    gtk_widget_set_size_request(composer->send, 64, -1);
    g_signal_connect(composer->send, "clicked", G_CALLBACK(send_clicked), composer);
    composer->attach = gtk_button_new();
    gtk_button_set_child(GTK_BUTTON(composer->attach), szfriends_gtk_glyph_new(SZFRIENDS_GTK_GLYPH_PAPERCLIP, 16));
    gtk_widget_add_css_class(composer->attach, "flat");
    gtk_widget_add_css_class(composer->attach, "szfriends-attach");
    gtk_widget_set_valign(composer->attach, GTK_ALIGN_CENTER);
    g_signal_connect(composer->attach, "clicked", G_CALLBACK(attach_clicked), composer);
    name_attach(composer);
    gtk_box_append(GTK_BOX(bottom), composer->hint);
    gtk_box_append(GTK_BOX(bottom), composer->attach);
    gtk_box_append(GTK_BOX(bottom), composer->send);
    for (GtkWidget *const *part = (GtkWidget *const[]){composer->note, composer->error, composer->chips,
                                                       composer->input_box, bottom, NULL}; *part; part++)
        gtk_box_append(GTK_BOX(root), *part);

    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(key_pressed), composer);
    gtk_widget_add_controller(composer->text_view, keys);
    g_signal_connect(composer->text_view, "preedit-changed", G_CALLBACK(preedit_changed), composer);
    szfriends_gtk_composer_restore_draft(composer);
    g_signal_connect_after(composer->buffer, "insert-text", G_CALLBACK(inserted), composer);
    g_signal_connect(composer->buffer, "changed", G_CALLBACK(changed), composer);
    gtk_widget_set_visible(composer->placeholder, gtk_text_buffer_get_char_count(composer->buffer) == 0);
    szfriends_gtk_composer_add_items(composer, NULL);

    szfriends_gtk_composer_add_drop_target(composer, root);
    szfriends_gtk_composer_add_paste(composer);
    conversation->composer = composer;
    return root;
}

SZFriendsGtkComposerView *szfriends_gtk_composer_from_widget(GtkWidget *widget) {
    return widget ? g_object_get_data(G_OBJECT(widget), "szfriends-composer") : NULL;
}

static void set_text(GtkWidget *label, const char *text) {
    gtk_label_set_text(GTK_LABEL(label), text ? text : "");
    gtk_widget_set_visible(label, text && *text);
}

void szfriends_gtk_composer_apply(SZFriendsGtkComposerView *composer, const SZFriendsGtkComposer *snapshot) {
    composer->enabled = snapshot->enabled;
    composer->accepts_drops = snapshot->accepts_drops;
    g_free(composer->mention_note);
    composer->mention_note = g_strdup(snapshot->mention_note);
    /* Disabled (blocked, no longer friends): the field must not look ready to type in, and the note says why. */
    gtk_text_view_set_editable(GTK_TEXT_VIEW(composer->text_view), snapshot->enabled);
    gtk_text_view_set_cursor_visible(GTK_TEXT_VIEW(composer->text_view), snapshot->enabled);
    if (snapshot->enabled) gtk_widget_remove_css_class(composer->input_box, "szfriends-disabled");
    else gtk_widget_add_css_class(composer->input_box, "szfriends-disabled");
    gtk_label_set_text(GTK_LABEL(composer->placeholder), snapshot->placeholder);
    gtk_accessible_update_property(GTK_ACCESSIBLE(composer->text_view), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                   snapshot->placeholder, -1);
    set_text(composer->note, snapshot->note);
    PangoAttrList *attributes = NULL;
    char *hint = szfriends_gtk_rich_text(snapshot->hint, snapshot->n_hint, &attributes);
    gtk_label_set_text(GTK_LABEL(composer->hint), hint);
    gtk_label_set_attributes(GTK_LABEL(composer->hint), attributes);
    gtk_widget_set_visible(composer->hint, snapshot->enabled && *hint);
    pango_attr_list_unref(attributes);
    g_free(hint);
    gtk_button_set_label(GTK_BUTTON(composer->send), snapshot->send_label);
    gtk_widget_set_sensitive(composer->send, snapshot->enabled && !composer->sending);
    gtk_widget_set_sensitive(composer->attach, snapshot->enabled);
    name_attach(composer);
    if (!snapshot->enabled) szfriends_gtk_composer_close_picker(composer);
}

GtkWidget *szfriends_gtk_composer_get_text_view(SZFriendsGtkComposerView *composer) {
    return composer->text_view;
}

GtkWidget *szfriends_gtk_composer_get_send_button(SZFriendsGtkComposerView *composer) {
    return composer->send;
}

GtkWidget *szfriends_gtk_composer_get_error_label(SZFriendsGtkComposerView *composer) {
    return composer->error;
}

GtkWidget *szfriends_gtk_composer_get_attach_button(SZFriendsGtkComposerView *composer) {
    return composer->attach;
}

GtkWidget *szfriends_gtk_composer_get_chips(SZFriendsGtkComposerView *composer) {
    return composer->chips;
}

const char *szfriends_gtk_composer_mention_note(SZFriendsGtkComposerView *composer) {
    return composer->mention_note;
}

GtkWidget *szfriends_gtk_composer_get_picker(SZFriendsGtkComposerView *composer) {
    return composer->picker;
}

void szfriends_gtk_composer_set_picker(SZFriendsGtkComposerView *composer, GtkWidget *picker) {
    composer->picker = picker;
}

SZFriendsGtkConversation *szfriends_gtk_composer_conversation(SZFriendsGtkComposerView *composer) {
    return composer->conversation;
}
