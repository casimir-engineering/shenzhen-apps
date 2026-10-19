/* The footer under both tabs (szfriends_gtk_list_page.h; mirrors mac/SZFriendsFooterView.m): the name friends see,
 * edited in place; Your ID with Copy, which copies the ASCII friends_id and never the display label; the note while the
 * ID is unreserved; and Add by ID, which opens the profile page. */

#include "gtk/szfriends_gtk_avatars.h"
#include "gtk/szfriends_gtk_glyphs.h"
#include "gtk/szfriends_gtk_list_page.h"

typedef struct {
    SZFriendsGtkFooterParts parts;
    SZFriendsGtkLink *link;
    SZFriendsGtkDropdown *dropdown;
    GtkWidget *box, *name_slot, *copy_glyph;
    char *name, *placeholder, *friends_id, *note;
    char *error; /* a refused name's reason, kept until the person edits again or the name changes */
    gboolean editing, cancelling;
    guint copied_source;
} SZFriendsGtkListFooter;

static SZFriendsGtkListFooter *footer_of(GtkWidget *box) {
    return box ? g_object_get_data(G_OBJECT(box), "szfriends-footer") : NULL;
}

static void replace(char **slot, const char *value) {
    char *copy = g_strdup(value);
    g_free(*slot);
    *slot = copy;
}

/* The refusal wins over the ID note: Nearby sends a snapshot every second while visible, and a reason that vanished
 * a second after it appeared would never be read. */
static void show_note(SZFriendsGtkListFooter *footer) {
    szfriends_gtk_list_label_set(footer->parts.note, footer->error ? footer->error : footer->note);
}

static void set_name_line(SZFriendsGtkListFooter *footer) {
    gboolean named = footer->name && *footer->name;
    gtk_label_set_text(GTK_LABEL(footer->parts.name_label),
                       named ? footer->name : footer->placeholder ? footer->placeholder : "");
    if (named) gtk_widget_add_css_class(footer->parts.name_label, "szfriends-footer-name");
    else gtk_widget_remove_css_class(footer->parts.name_label, "szfriends-footer-name");
}

static void show_copy_glyph(SZFriendsGtkListFooter *footer) {
    gtk_widget_set_visible(footer->copy_glyph, TRUE);
    gtk_widget_set_visible(footer->parts.copy_label, FALSE);
    const char *name = szfriends_gtk_link_string(footer->link, "copy_your_id");
    gtk_widget_set_tooltip_text(footer->parts.copy_button, *name ? name : NULL);
    if (*name)
        gtk_accessible_update_property(GTK_ACCESSIBLE(footer->parts.copy_button), GTK_ACCESSIBLE_PROPERTY_LABEL, name,
                                       -1);
}

void szfriends_gtk_footer_apply(GtkWidget *box, const SZFriendsGtkFooter *data) {
    SZFriendsGtkListFooter *footer = footer_of(box);
    if (!footer || !data) return;
    if (g_strcmp0(footer->name, data->name)) g_clear_pointer(&footer->error, g_free);
    replace(&footer->name, data->name);
    replace(&footer->placeholder, data->name_placeholder);
    replace(&footer->friends_id, data->friends_id);
    replace(&footer->note, data->id_note);
    szfriends_gtk_avatar_set(footer->parts.avatar, &data->avatar);
    set_name_line(footer);
    const char *edit = szfriends_gtk_link_string(footer->link, "edit_name");
    gtk_widget_set_tooltip_text(footer->parts.name_button, *edit ? edit : NULL);
    if (*edit)
        gtk_accessible_update_property(GTK_ACCESSIBLE(footer->parts.name_button), GTK_ACCESSIBLE_PROPERTY_LABEL, edit,
                                       -1);
    gtk_label_set_text(GTK_LABEL(footer->parts.id_label), data->id_label);
    gtk_widget_set_visible(footer->parts.copy_button, data->friends_id && *data->friends_id);
    if (!footer->copied_source) show_copy_glyph(footer);
    gtk_button_set_label(GTK_BUTTON(footer->parts.add_button), data->add_label);
    gtk_widget_set_visible(footer->parts.add_button, *data->add_label != '\0');
    show_note(footer);
}

/* ---- Copy ---------------------------------------------------------------------------------------- */

static gboolean copied_over(gpointer data) {
    SZFriendsGtkListFooter *footer = data;
    footer->copied_source = 0;
    show_copy_glyph(footer);
    return G_SOURCE_REMOVE;
}

static void copy_clicked(GtkButton *button, gpointer data) {
    (void)button;
    SZFriendsGtkListFooter *footer = data;
    if (!footer->friends_id || !*footer->friends_id) return;
    szfriends_gtk_copy_text(footer->box, footer->friends_id);
    const char *copied = szfriends_gtk_link_string(footer->link, "copied");
    if (!*copied) return;
    /* "Copied" in place of the glyph for a moment, and said aloud, so the person knows it worked. */
    gtk_label_set_text(GTK_LABEL(footer->parts.copy_label), copied);
    gtk_widget_set_visible(footer->parts.copy_label, TRUE);
    gtk_widget_set_visible(footer->copy_glyph, FALSE);
    gtk_accessible_update_property(GTK_ACCESSIBLE(footer->parts.copy_button), GTK_ACCESSIBLE_PROPERTY_LABEL, copied,
                                   -1);
    gtk_accessible_announce(GTK_ACCESSIBLE(footer->parts.copy_button), copied,
                            GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM);
    szfriends_gtk_clock_cancel(footer->copied_source);
    footer->copied_source = szfriends_gtk_clock_schedule(1500, copied_over, footer);
}

/* ---- The name, edited in place ------------------------------------------------------------------- */

gboolean szfriends_gtk_footer_is_editing(GtkWidget *box) {
    SZFriendsGtkListFooter *footer = footer_of(box);
    return footer && footer->editing;
}

static void end_edit(SZFriendsGtkListFooter *footer) {
    footer->editing = FALSE;
    gtk_widget_set_visible(footer->parts.editor, FALSE);
    gtk_widget_set_visible(footer->parts.name_button, TRUE);
    footer->cancelling = FALSE;
}

void szfriends_gtk_footer_begin_edit(GtkWidget *box) {
    SZFriendsGtkListFooter *footer = footer_of(box);
    if (!footer || footer->editing) return;
    footer->editing = TRUE;
    g_clear_pointer(&footer->error, g_free);
    show_note(footer);
    gtk_editable_set_text(GTK_EDITABLE(footer->parts.editor), footer->name ? footer->name : "");
    gtk_entry_set_placeholder_text(GTK_ENTRY(footer->parts.editor), footer->placeholder);
    gtk_widget_set_visible(footer->parts.name_button, FALSE);
    gtk_widget_set_visible(footer->parts.editor, TRUE);
    gtk_widget_grab_focus(footer->parts.editor);
}

gboolean szfriends_gtk_footer_cancel_edit(GtkWidget *box) {
    SZFriendsGtkListFooter *footer = footer_of(box);
    if (!footer || !footer->editing) return FALSE;
    footer->cancelling = TRUE; /* hiding the field takes its focus, which must not commit what was typed */
    end_edit(footer);
    return TRUE;
}

static void weak_free(gpointer data) {
    g_weak_ref_clear(data);
    g_free(data);
}

static void name_replied(JsonObject *result, const SZFriendsGtkError *error, gpointer data) {
    (void)result;
    GtkWidget *box = g_weak_ref_get(data);
    SZFriendsGtkListFooter *footer = footer_of(box);
    /* The helper's words for a refused name ("Use 40 characters or fewer"), where the name was typed. */
    if (footer && error && error->message && *error->message) {
        replace(&footer->error, error->message);
        show_note(footer);
        gtk_accessible_announce(GTK_ACCESSIBLE(footer->parts.note), error->message,
                                GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_HIGH);
    }
    if (box) g_object_unref(box);
}

void szfriends_gtk_footer_commit_edit(GtkWidget *box) {
    SZFriendsGtkListFooter *footer = footer_of(box);
    if (!footer || !footer->editing) return;
    char *name = g_strdup(gtk_editable_get_text(GTK_EDITABLE(footer->parts.editor)));
    end_edit(footer);
    if (g_strcmp0(name, footer->name ? footer->name : "") != 0) {
        GWeakRef *ref = g_new0(GWeakRef, 1);
        g_weak_ref_init(ref, box);
        szfriends_gtk_link_send(footer->link, szfriends_intent_set_name(name), name_replied, ref, weak_free);
    }
    g_free(name);
}

static void editor_activated(GtkEntry *entry, gpointer data) {
    (void)entry;
    szfriends_gtk_footer_commit_edit(((SZFriendsGtkListFooter *)data)->box);
}

/* Clicking elsewhere keeps what was typed, as Finder's inline rename does; Escape discards it. */
static void editor_left(GtkEventControllerFocus *focus, gpointer data) {
    (void)focus;
    SZFriendsGtkListFooter *footer = data;
    if (footer->editing && !footer->cancelling) szfriends_gtk_footer_commit_edit(footer->box);
}

static void name_clicked(GtkButton *button, gpointer data) {
    (void)button;
    szfriends_gtk_footer_begin_edit(((SZFriendsGtkListFooter *)data)->box);
}

static void add_clicked(GtkButton *button, gpointer data) {
    (void)button;
    SZFriendsGtkListFooter *footer = data;
    if (footer->dropdown) szfriends_gtk_dropdown_open_profile(footer->dropdown);
}

/* ---- Construction -------------------------------------------------------------------------------- */

static void footer_free(gpointer data) {
    SZFriendsGtkListFooter *footer = data;
    szfriends_gtk_clock_cancel(footer->copied_source);
    g_free(footer->name);
    g_free(footer->placeholder);
    g_free(footer->friends_id);
    g_free(footer->note);
    g_free(footer->error);
    g_free(footer);
}

static GtkWidget *flat_button(GtkWidget *child, const char *css_class) {
    GtkWidget *button = gtk_button_new();
    gtk_widget_add_css_class(button, "flat");
    gtk_widget_add_css_class(button, css_class);
    gtk_button_set_child(GTK_BUTTON(button), child);
    return button;
}

GtkWidget *szfriends_gtk_footer_new(SZFriendsGtkLink *link, SZFriendsGtkDropdown *dropdown) {
    SZFriendsGtkListFooter *footer = g_new0(SZFriendsGtkListFooter, 1);
    SZFriendsGtkFooterParts *parts = &footer->parts;
    footer->link = link;
    footer->dropdown = dropdown;
    footer->box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_add_css_class(footer->box, "szfriends-footer");
    GtkWidget *top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    parts->avatar = szfriends_gtk_avatar_new(link, 28);
    gtk_widget_set_valign(parts->avatar, GTK_ALIGN_CENTER);
    GtkWidget *text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_hexpand(text, TRUE);
    gtk_widget_set_valign(text, GTK_ALIGN_CENTER);
    /* Name, then the ID line with its Copy: never on one pixel row, so a long placeholder cannot reach over the
     * copy button and split one click target in two. */
    GtkWidget *name_content = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    parts->name_label = gtk_label_new(NULL);
    gtk_label_set_ellipsize(GTK_LABEL(parts->name_label), PANGO_ELLIPSIZE_END);
    gtk_box_append(GTK_BOX(name_content), parts->name_label);
    gtk_box_append(GTK_BOX(name_content), szfriends_gtk_glyph_new(SZFRIENDS_GTK_GLYPH_PENCIL, 11));
    parts->name_button = flat_button(name_content, "szfriends-footer-button");
    gtk_widget_set_halign(parts->name_button, GTK_ALIGN_START);
    g_signal_connect(parts->name_button, "clicked", G_CALLBACK(name_clicked), footer);
    parts->editor = gtk_entry_new();
    gtk_widget_set_visible(parts->editor, FALSE);
    g_signal_connect(parts->editor, "activate", G_CALLBACK(editor_activated), footer);
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "leave", G_CALLBACK(editor_left), footer);
    gtk_widget_add_controller(parts->editor, focus);
    const char *edit = szfriends_gtk_link_string(link, "edit_name");
    if (*edit) gtk_accessible_update_property(GTK_ACCESSIBLE(parts->editor), GTK_ACCESSIBLE_PROPERTY_LABEL, edit, -1);
    footer->name_slot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_box_append(GTK_BOX(footer->name_slot), parts->name_button);
    gtk_box_append(GTK_BOX(footer->name_slot), parts->editor);
    GtkWidget *id_line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2);
    parts->id_label = gtk_label_new(NULL);
    gtk_label_set_ellipsize(GTK_LABEL(parts->id_label), PANGO_ELLIPSIZE_END);
    gtk_widget_add_css_class(parts->id_label, "szfriends-secondary");
    gtk_widget_set_margin_start(parts->id_label, 6);
    GtkWidget *copy_content = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    footer->copy_glyph = szfriends_gtk_glyph_new(SZFRIENDS_GTK_GLYPH_COPY, 12);
    parts->copy_label = gtk_label_new(NULL);
    gtk_widget_add_css_class(parts->copy_label, "szfriends-caption");
    gtk_box_append(GTK_BOX(copy_content), footer->copy_glyph);
    gtk_box_append(GTK_BOX(copy_content), parts->copy_label);
    parts->copy_button = flat_button(copy_content, "szfriends-footer-button");
    g_signal_connect(parts->copy_button, "clicked", G_CALLBACK(copy_clicked), footer);
    gtk_box_append(GTK_BOX(id_line), parts->id_label);
    gtk_box_append(GTK_BOX(id_line), parts->copy_button);
    gtk_box_append(GTK_BOX(text), footer->name_slot);
    gtk_box_append(GTK_BOX(text), id_line);
    parts->add_button = gtk_button_new_with_label("");
    gtk_widget_set_valign(parts->add_button, GTK_ALIGN_CENTER);
    g_signal_connect(parts->add_button, "clicked", G_CALLBACK(add_clicked), footer);
    gtk_box_append(GTK_BOX(top), parts->avatar);
    gtk_box_append(GTK_BOX(top), text);
    gtk_box_append(GTK_BOX(top), parts->add_button);
    parts->note = szfriends_gtk_list_label("szfriends-caption");
    gtk_widget_set_visible(parts->note, FALSE);
    gtk_box_append(GTK_BOX(footer->box), top);
    gtk_box_append(GTK_BOX(footer->box), parts->note);
    g_object_set_data_full(G_OBJECT(footer->box), "szfriends-footer", footer, footer_free);
    show_copy_glyph(footer);
    return footer->box;
}

const SZFriendsGtkFooterParts *szfriends_gtk_footer_parts(GtkWidget *box) {
    SZFriendsGtkListFooter *footer = footer_of(box);
    return footer ? &footer->parts : NULL;
}
