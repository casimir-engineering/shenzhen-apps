/* What sits above the list's rows (szfriends_gtk_list_page_private.h): "Send 2 files to…" with Cancel, or the drop
 * hint, while files are on their way in; the banner (an ID that changed, an identity that cannot be read, an update
 * that is needed); and the name field until a name is chosen, which never blocks the list. */

#include "gtk/szfriends_gtk_list_page_private.h"
#include "gtk/szfriends_gtk_schema.h"

/* ---- Files on their way in ----------------------------------------------------------------------- */

/* Whether the header shows one of the helper's drop refusals rather than drop_hint. */
static gboolean refusal_shown(SZFriendsGtkListPage *list, const char *title, const char *hint) {
    if (title || !hint || !*hint) return FALSE;
    return !g_strcmp0(hint, szfriends_gtk_drop_refusal(list->link, SZFRIENDS_GTK_DROP_REFUSE_FOLDER)) ||
           !g_strcmp0(hint, szfriends_gtk_drop_refusal(list->link, SZFRIENDS_GTK_DROP_REFUSE_NOT_A_FILE));
}

/* While files are dragged in through the Friends button, or wait for "Send 2 files to…", a row that refuses them (a
 * request, a blocked person) fades, so it never looks like a place to drop or click. When the header already says
 * why the files are refused, a friend's row under them shows the refuse style alone, not the sentence again. */
void szfriends_gtk_list_dim_rows(SZFriendsGtkListPage *list) {
    const char *title = szfriends_gtk_dropdown_get_send_title(list->dropdown);
    const char *hint = szfriends_gtk_dropdown_get_drop_hint(list->dropdown);
    gboolean sending = title || hint, refused = refusal_shown(list, title, hint);
    for (guint i = 0; i < list->parts.rows->len; i++) {
        GtkWidget *row = g_ptr_array_index(list->parts.rows, i);
        szfriends_gtk_row_set_dimmed(row, sending && !szfriends_gtk_row_get_drop_label(row));
        szfriends_gtk_row_set_refusal_above(row, refused);
    }
}

void szfriends_gtk_list_update_send_notice(SZFriendsGtkDropdown *dropdown, gpointer data) {
    SZFriendsGtkListPage *list = data;
    SZFriendsGtkListParts *parts = &list->parts;
    const char *title = szfriends_gtk_dropdown_get_send_title(dropdown);
    const char *text = title ? title : szfriends_gtk_dropdown_get_drop_hint(dropdown);
    gtk_widget_set_visible(parts->send_notice, text && *text);
    gtk_label_set_text(GTK_LABEL(parts->send_text), text ? text : "");
    if (title) gtk_widget_add_css_class(parts->send_text, "szfriends-notice-title");
    else gtk_widget_remove_css_class(parts->send_text, "szfriends-notice-title");
    /* A way out for the mouse, not only Escape; and the files' names under the pointer. */
    const char *cancel = szfriends_gtk_link_string(list->link, "cancel");
    gtk_button_set_label(GTK_BUTTON(parts->send_cancel), cancel);
    gtk_widget_set_visible(parts->send_cancel, title && *cancel);
    GString *names = g_string_new(NULL);
    GPtrArray *items = szfriends_gtk_dropdown_get_send_items(dropdown);
    for (guint i = 0; items && i < items->len; i++) {
        const SZFriendsGtkHostItem *item = g_ptr_array_index(items, i);
        if (!item->title || !*item->title) continue;
        if (names->len) g_string_append_c(names, '\n');
        g_string_append(names, item->title);
    }
    gtk_widget_set_tooltip_text(parts->send_notice, title && names->len ? names->str : NULL);
    g_string_free(names, TRUE);
    szfriends_gtk_list_dim_rows(list);
}

static void send_cancelled(GtkButton *button, gpointer data) {
    (void)button;
    szfriends_gtk_dropdown_finish_send_picker(((SZFriendsGtkListPage *)data)->dropdown);
}

/* ---- The banner ---------------------------------------------------------------------------------- */

/* dismiss_banner names the banner's kind as the protocol spells it, read from the schema's own table. */
static const char *banner_kind_name(SZFriendsGtkBannerKind kind) {
    const SZFriendsGtkType *list = &szfriends_gtk_type_list_snapshot;
    for (gsize i = 0; i < list->n_fields; i++) {
        if (g_strcmp0(list->fields[i].name, "banner") || !list->fields[i].type) continue;
        const SZFriendsGtkType *banner = list->fields[i].type;
        for (gsize j = 0; j < banner->n_fields; j++)
            if (!g_strcmp0(banner->fields[j].name, "kind"))
                return szfriends_gtk_enum_name(banner->fields[j].enums, kind);
    }
    return NULL;
}

static void banner_clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkListPage *list = data;
    const SZFriendsGtkBanner *banner = list->list ? list->list->banner : NULL;
    if (!banner) return;
    SZFriendsGtkActionIds ids = {.kind = banner_kind_name(banner->kind)};
    szfriends_gtk_perform(list->link, list->dropdown, GTK_WIDGET(button), banner->action, &ids, NULL, NULL);
}

/* ---- The name field ------------------------------------------------------------------------------ */

static void weak_free(gpointer data) {
    g_weak_ref_clear(data);
    g_free(data);
}

/* A refused name's reason stays on the note until the person types again, whatever snapshots arrive meanwhile. */
#define SZFRIENDS_GTK_PROMPT_ERROR "szfriends-prompt-error"

static void name_replied(JsonObject *result, const SZFriendsGtkError *error, gpointer data) {
    (void)result;
    GtkWidget *note = g_weak_ref_get(data);
    /* The helper's words for a refused name, where it was typed. */
    if (note && error && error->message && *error->message) {
        g_object_set_data_full(G_OBJECT(note), SZFRIENDS_GTK_PROMPT_ERROR, g_strdup(error->message), g_free);
        szfriends_gtk_list_label_set(note, error->message);
        gtk_accessible_announce(GTK_ACCESSIBLE(note), error->message, GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_HIGH);
    }
    if (note) g_object_unref(note);
}

void szfriends_gtk_list_page_submit_name(SZFriendsGtkPage *page) {
    const SZFriendsGtkListParts *parts = szfriends_gtk_list_page_parts(page);
    if (!parts) return;
    SZFriendsGtkListPage *list = szfriends_gtk_page_get_data(page);
    GWeakRef *ref = g_new0(GWeakRef, 1);
    g_weak_ref_init(ref, parts->prompt_note);
    const char *name = gtk_editable_get_text(GTK_EDITABLE(parts->prompt_entry));
    szfriends_gtk_link_send(list->link, szfriends_intent_set_name(name), name_replied, ref, weak_free);
}

static void prompt_activated(GtkEntry *entry, gpointer data) {
    (void)entry;
    szfriends_gtk_list_page_submit_name(((SZFriendsGtkListPage *)data)->page);
}

static void prompt_edited(GtkEditable *entry, gpointer data) {
    (void)entry;
    SZFriendsGtkListPage *list = data;
    GtkWidget *note = list->parts.prompt_note;
    if (!g_object_get_data(G_OBJECT(note), SZFRIENDS_GTK_PROMPT_ERROR)) return;
    g_object_set_data(G_OBJECT(note), SZFRIENDS_GTK_PROMPT_ERROR, NULL);
    const SZFriendsGtkNamePrompt *prompt = list->list ? list->list->name_prompt : NULL;
    szfriends_gtk_list_label_set(note, prompt ? prompt->note : NULL);
}

/* ---- Building and applying ----------------------------------------------------------------------- */

void szfriends_gtk_list_apply_notices(SZFriendsGtkListPage *list, const SZFriendsGtkListSnapshot *snapshot) {
    SZFriendsGtkListParts *parts = &list->parts;
    const SZFriendsGtkBanner *banner = snapshot->banner;
    gtk_widget_set_visible(parts->banner, banner != NULL);
    gtk_label_set_text(GTK_LABEL(parts->banner_text), banner ? banner->text : "");
    szfriends_gtk_list_action_button_set(parts->banner_button, banner ? banner->action : NULL);
    const SZFriendsGtkNamePrompt *prompt = snapshot->name_prompt;
    gtk_widget_set_visible(parts->prompt, prompt != NULL);
    szfriends_gtk_list_label_set(parts->prompt_title, prompt ? prompt->title : NULL);
    const char *error = g_object_get_data(G_OBJECT(parts->prompt_note), SZFRIENDS_GTK_PROMPT_ERROR);
    szfriends_gtk_list_label_set(parts->prompt_note, error ? error : prompt ? prompt->note : NULL);
    gtk_entry_set_placeholder_text(GTK_ENTRY(parts->prompt_entry), prompt ? prompt->placeholder : NULL);
    if (prompt && *prompt->title)
        gtk_accessible_update_property(GTK_ACCESSIBLE(parts->prompt_entry), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                       prompt->title, -1);
}

static GtkWidget *notice(const char *kind, GtkOrientation orientation) {
    GtkWidget *box = gtk_box_new(orientation, 6);
    gtk_widget_add_css_class(box, "szfriends-notice");
    gtk_widget_add_css_class(box, kind);
    gtk_widget_set_visible(box, FALSE);
    return box;
}

void szfriends_gtk_list_build_notices(SZFriendsGtkListPage *list, GtkWidget *content) {
    SZFriendsGtkListParts *parts = &list->parts;
    parts->send_notice = notice("send", GTK_ORIENTATION_HORIZONTAL);
    parts->send_text = szfriends_gtk_list_label(NULL);
    gtk_widget_set_hexpand(parts->send_text, TRUE);
    parts->send_cancel = gtk_button_new_with_label("");
    gtk_widget_add_css_class(parts->send_cancel, "flat");
    gtk_widget_add_css_class(parts->send_cancel, "szfriends-link");
    gtk_widget_set_valign(parts->send_cancel, GTK_ALIGN_CENTER);
    g_signal_connect(parts->send_cancel, "clicked", G_CALLBACK(send_cancelled), list);
    gtk_box_append(GTK_BOX(parts->send_notice), parts->send_text);
    gtk_box_append(GTK_BOX(parts->send_notice), parts->send_cancel);
    parts->banner = notice("banner", GTK_ORIENTATION_HORIZONTAL);
    parts->banner_text = szfriends_gtk_list_label(NULL);
    gtk_widget_set_hexpand(parts->banner_text, TRUE);
    parts->banner_button = szfriends_gtk_list_action_button_new();
    gtk_widget_set_valign(parts->banner_button, GTK_ALIGN_CENTER);
    g_signal_connect(parts->banner_button, "clicked", G_CALLBACK(banner_clicked), list);
    gtk_box_append(GTK_BOX(parts->banner), parts->banner_text);
    gtk_box_append(GTK_BOX(parts->banner), parts->banner_button);
    parts->prompt = notice("prompt", GTK_ORIENTATION_VERTICAL);
    parts->prompt_title = szfriends_gtk_list_label("szfriends-notice-title");
    parts->prompt_entry = gtk_entry_new();
    g_signal_connect(parts->prompt_entry, "activate", G_CALLBACK(prompt_activated), list);
    g_signal_connect(parts->prompt_entry, "changed", G_CALLBACK(prompt_edited), list);
    parts->prompt_note = szfriends_gtk_list_label("szfriends-caption");
    gtk_box_append(GTK_BOX(parts->prompt), parts->prompt_title);
    gtk_box_append(GTK_BOX(parts->prompt), parts->prompt_entry);
    gtk_box_append(GTK_BOX(parts->prompt), parts->prompt_note);
    gtk_box_append(GTK_BOX(content), parts->send_notice);
    gtk_box_append(GTK_BOX(content), parts->banner);
    gtk_box_append(GTK_BOX(content), parts->prompt);
}
