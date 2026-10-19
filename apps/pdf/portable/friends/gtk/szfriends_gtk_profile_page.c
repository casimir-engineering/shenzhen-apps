/* Your profile, behind Add by ID (szfriends_gtk_details_page.h). Mirrors mac/SZFriendsProfilePage.m: the name friends
 * see, the picture (the bundled animal set, or your own photo cropped to the circle, chosen or dropped), your
 * Friends ID with Copy, its reservation note and its QR once the helper sends one, and adding someone by ID. */

#include "gtk/szfriends_gtk_avatars.h"
#include "gtk/szfriends_gtk_crop.h"
#include "gtk/szfriends_gtk_details_page.h"
#include "gtk/szfriends_gtk_devices.h"
#include "gtk/szfriends_gtk_qr.h"

#include <adwaita.h>
#include <string.h>

typedef struct {
    SZFriendsGtkPage *page;
    guint token;
    SZFriendsGtkDetailsHeld *held;
    GtkWidget *stack, *box, *avatar, *name_label, *name_entry, *photo_button, *picture_error;
    GtkWidget *animals_box, *animals_title, *animals, *own_button;
    GtkWidget *id_title, *id_value, *copy, *qr_button, *id_note, *qr;
    GtkWidget *add_label, *add_entry, *add_button, *add_hint, *add_result;
    GtkWidget *crop, *links, *computers;
    gint64 animals_set; /* the set the grid was built for, -1 before */
    gboolean editing_name, adding;
} SZFriendsGtkProfile;

static const SZFriendsGtkProfileSnapshot *shown(SZFriendsGtkProfile *profile) {
    return szfriends_gtk_details_held_value(profile->held);
}

static SZFriendsGtkProfile *profile_of(GtkWidget *widget) {
    return widget ? g_object_get_data(G_OBJECT(widget), "szfriends-profile") : NULL;
}

/* ---- Your own picture -------------------------------------------------------------------------------------- */

static void picture_replied(SZFriendsGtkPage *page, JsonObject *result, const SZFriendsGtkError *error) {
    (void)result;
    SZFriendsGtkProfile *profile = szfriends_gtk_page_get_data(page);
    /* The helper's words say why a photo did not take and what to choose instead. Connection errors carry none:
     * the dropdown's own line already says the helper is away. */
    const char *message = error ? error->message : NULL;
    szfriends_gtk_details_label_set(profile->picture_error, message);
    szfriends_gtk_details_announce(profile->picture_error, message);
}

static void end_crop(SZFriendsGtkProfile *profile) {
    if (!profile->crop) return;
    gtk_stack_set_visible_child_name(GTK_STACK(profile->stack), "main");
    gtk_stack_remove(GTK_STACK(profile->stack), profile->crop);
    profile->crop = NULL;
}

static void crop_use(const char *path, const SZFriendsGtkCropGeometry *geometry, gpointer data) {
    SZFriendsGtkProfile *profile = data;
    szfriends_gtk_details_send(profile->page, szfriends_gtk_crop_intent(path, geometry), picture_replied);
    end_crop(profile);
}

static void crop_cancel(gpointer data) {
    end_crop(data);
}

static void begin_crop(SZFriendsGtkProfile *profile, const char *path) {
    end_crop(profile);
    szfriends_gtk_details_label_set(profile->picture_error, NULL);
    profile->crop = szfriends_gtk_crop_new(szfriends_gtk_page_get_link(profile->page), path, crop_use, crop_cancel,
                                           profile);
    gtk_stack_add_named(GTK_STACK(profile->stack), profile->crop, "crop");
    gtk_stack_set_visible_child(GTK_STACK(profile->stack), profile->crop);
}

/* The chooser may answer after the page is gone: it holds the page's box weakly, never the page. */
static void image_chosen(const char *path, gpointer data) {
    GWeakRef *box = data;
    GtkWidget *widget = g_weak_ref_get(box);
    SZFriendsGtkProfile *profile = profile_of(widget);
    if (profile && path) begin_crop(profile, path);
    if (widget) g_object_unref(widget);
    g_weak_ref_clear(box);
    g_free(box);
}

static void own_picture_clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkProfile *profile = data;
    GWeakRef *box = g_new0(GWeakRef, 1);
    g_weak_ref_init(box, profile->box);
    const SZFriendsGtkProfileSnapshot *snapshot = shown(profile);
    szfriends_gtk_choose_image(GTK_WIDGET(button), snapshot ? snapshot->picture.own_picture_label : NULL,
                               image_chosen, box);
}

/* One image file dropped on the page starts the same crop step (brief § Product contract: choose a file or drop
 * an image, then crop to the circle). */
static gboolean image_dropped(GtkDropTarget *target, const GValue *value, double x, double y, gpointer data) {
    (void)target, (void)x, (void)y;
    SZFriendsGtkProfile *profile = data;
    GSList *files = G_VALUE_HOLDS(value, GDK_TYPE_FILE_LIST) ? gdk_file_list_get_files(g_value_get_boxed(value))
                                                              : NULL;
    char *path = files && !files->next ? g_file_get_path(files->data) : NULL;
    char *type = path ? g_content_type_guess(path, NULL, 0, NULL) : NULL;
    char *mime = type ? g_content_type_get_mime_type(type) : NULL;
    gboolean image = mime && g_str_has_prefix(mime, "image/");
    if (image) begin_crop(profile, path);
    g_free(mime);
    g_free(type);
    g_free(path);
    g_slist_free(files);
    return image;
}

/* ---- The animal set --------------------------------------------------------------------------------------- */

static void animal_activated(GtkFlowBox *box, GtkFlowBoxChild *child, gpointer data) {
    (void)box;
    SZFriendsGtkProfile *profile = data;
    gint64 index = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(child), "szfriends-index"));
    szfriends_gtk_details_label_set(profile->picture_error, NULL);
    szfriends_gtk_details_send(profile->page, szfriends_intent_set_picture_animal(profile->animals_set, index),
                               picture_replied);
}

/* The whole set from this app's own copy, drawn as friends' apps draw it; the selected animal is the flow box's
 * selection. Built once per set, since a set never changes. */
static void sync_animals(SZFriendsGtkProfile *profile, const SZFriendsGtkProfilePicture *picture) {
    SZFriendsGtkAnimalSet *set = szfriends_gtk_link_animal_set(szfriends_gtk_page_get_link(profile->page));
    if (profile->animals_set != picture->animal_set) {
        profile->animals_set = picture->animal_set;
        gtk_flow_box_remove_all(GTK_FLOW_BOX(profile->animals));
        gsize count = set ? szfriends_gtk_animal_set_count(set) : 0;
        for (gsize index = 0; index < count; index++) {
            const char *name = szfriends_gtk_animal_set_name(set, (gint64)index);
            if (!name) continue;
            const char *color = szfriends_gtk_animal_set_color(set, (gint64)index);
            SZFriendsGtkAvatar avatar = {.kind = SZFRIENDS_GTK_AVATAR_ANIMAL, .set = picture->animal_set,
                                         .index = (gint64)index, .initials = "", .color = (char *)color};
            GtkWidget *view = szfriends_gtk_avatar_new(szfriends_gtk_page_get_link(profile->page), 36);
            szfriends_gtk_avatar_set(view, &avatar);
            GtkWidget *child = gtk_flow_box_child_new();
            gtk_flow_box_child_set_child(GTK_FLOW_BOX_CHILD(child), view);
            gtk_widget_set_size_request(child, 44, 44);
            gtk_widget_set_tooltip_text(child, name);
            gtk_accessible_update_property(GTK_ACCESSIBLE(child), GTK_ACCESSIBLE_PROPERTY_LABEL, name, -1);
            g_object_set_data(G_OBJECT(child), "szfriends-index", GINT_TO_POINTER((int)index));
            gtk_flow_box_append(GTK_FLOW_BOX(profile->animals), child);
        }
    }
    gtk_flow_box_unselect_all(GTK_FLOW_BOX(profile->animals));
    for (GtkWidget *child = gtk_widget_get_first_child(profile->animals); child;
         child = gtk_widget_get_next_sibling(child))
        if (picture->selected_index.set &&
            GPOINTER_TO_INT(g_object_get_data(G_OBJECT(child), "szfriends-index")) == picture->selected_index.value)
            gtk_flow_box_select_child(GTK_FLOW_BOX(profile->animals), GTK_FLOW_BOX_CHILD(child));
}

static void photo_toggled(GtkToggleButton *button, gpointer data) {
    SZFriendsGtkProfile *profile = data;
    gtk_widget_set_visible(profile->animals_box, gtk_toggle_button_get_active(button));
}

/* ---- Name, ID and adding --------------------------------------------------------------------------------- */

static void commit_name(SZFriendsGtkProfile *profile) {
    const SZFriendsGtkProfileSnapshot *snapshot = shown(profile);
    szfriends_intent *intent = snapshot ? szfriends_gtk_details_name_intent(
                                              gtk_editable_get_text(GTK_EDITABLE(profile->name_entry)),
                                              snapshot->name.value)
                                        : NULL;
    if (intent) szfriends_gtk_details_send(profile->page, intent, NULL);
}

static void name_activated(GtkEntry *entry, gpointer data) {
    (void)entry;
    commit_name(data);
}

/* Typing is never overwritten by a snapshot; leaving the field commits it, as Return does. */
static void name_entered(GtkEventControllerFocus *focus, gpointer data) {
    (void)focus;
    ((SZFriendsGtkProfile *)data)->editing_name = TRUE;
}

static void name_left(GtkEventControllerFocus *focus, gpointer data) {
    (void)focus;
    SZFriendsGtkProfile *profile = data;
    profile->editing_name = FALSE;
    commit_name(profile);
}

static void copy_clicked(GtkButton *button, gpointer data) {
    SZFriendsGtkProfile *profile = data;
    const SZFriendsGtkProfileSnapshot *snapshot = shown(profile);
    if (snapshot) szfriends_gtk_details_copy(profile->page, GTK_WIDGET(button), snapshot->id.friends_id);
}

static void qr_toggled(GtkToggleButton *button, gpointer data) {
    szfriends_gtk_qr_set_large(((SZFriendsGtkProfile *)data)->qr, gtk_toggle_button_get_active(button));
}

static szfriends_intent *typed_add(SZFriendsGtkProfile *profile) {
    return szfriends_gtk_details_add_intent(gtk_editable_get_text(GTK_EDITABLE(profile->add_entry)));
}

static void update_add_button(SZFriendsGtkProfile *profile) {
    szfriends_intent *intent = typed_add(profile);
    gtk_widget_set_sensitive(profile->add_button, intent && !profile->adding);
    szfriends_intent_free(intent);
}

static void add_replied(SZFriendsGtkPage *page, JsonObject *result, const SZFriendsGtkError *error) {
    SZFriendsGtkProfile *profile = szfriends_gtk_page_get_data(page);
    profile->adding = FALSE;
    const char *message = error ? error->message
                                : json_object_get_string_member_with_default(result, "message", NULL);
    szfriends_gtk_details_label_set(profile->add_result, message);
    if (error) gtk_widget_add_css_class(profile->add_result, "error");
    else gtk_widget_remove_css_class(profile->add_result, "error");
    /* The answer appears under the field, away from where the person is looking: speak it too. */
    szfriends_gtk_details_announce(profile->add_result, message);
    if (!error) gtk_editable_set_text(GTK_EDITABLE(profile->add_entry), "");
    update_add_button(profile);
}

static void send_add(SZFriendsGtkProfile *profile) {
    szfriends_intent *intent = profile->adding ? NULL : typed_add(profile);
    if (!intent) return;
    /* One request at a time: a second press while the first is out would only ask twice. */
    profile->adding = TRUE;
    update_add_button(profile);
    szfriends_gtk_details_send(profile->page, intent, add_replied);
}

static void add_activated(GtkWidget *widget, gpointer data) {
    (void)widget;
    send_add(data);
}

static void add_changed(GtkEditable *editable, gpointer data) {
    (void)editable;
    update_add_button(data);
}

/* ---- Snapshots -------------------------------------------------------------------------------------------- */

static void apply(SZFriendsGtkProfile *profile) {
    const SZFriendsGtkProfileSnapshot *snapshot = shown(profile);
    szfriends_gtk_page_set_title(profile->page, snapshot->title, NULL);
    szfriends_gtk_page_set_back(profile->page, &snapshot->back);
    szfriends_gtk_details_label_set(profile->name_label, snapshot->name.label);
    /* Never over what the person is typing. */
    if (!profile->editing_name) gtk_editable_set_text(GTK_EDITABLE(profile->name_entry), snapshot->name.value);
    gtk_entry_set_placeholder_text(GTK_ENTRY(profile->name_entry), snapshot->name.placeholder);
    gtk_entry_set_max_length(GTK_ENTRY(profile->name_entry), (int)CLAMP(snapshot->name.max_length, 0, 1000));
    gtk_accessible_update_property(GTK_ACCESSIBLE(profile->name_entry), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                   snapshot->name.label, -1);
    szfriends_gtk_avatar_set(profile->avatar, &snapshot->picture.avatar);
    gtk_button_set_label(GTK_BUTTON(profile->photo_button), snapshot->picture.choose_label);
    gtk_widget_set_visible(profile->photo_button, *snapshot->picture.choose_label != '\0');
    szfriends_gtk_details_label_set(profile->animals_title, szfriends_gtk_link_string(
                                                                szfriends_gtk_page_get_link(profile->page),
                                                                "animals_title"));
    gtk_button_set_label(GTK_BUTTON(profile->own_button), snapshot->picture.own_picture_label);
    sync_animals(profile, &snapshot->picture);
    const SZFriendsGtkProfileId *id = &snapshot->id;
    szfriends_gtk_details_label_set(profile->id_title, id->label);
    szfriends_gtk_details_label_set(profile->id_value, id->friends_id);
    szfriends_gtk_details_label_set(profile->id_note, id->note);
    /* A changed ID is news the person should not miss; every other state is a plain note. */
    if (id->state == SZFRIENDS_GTK_ID_CHANGED) gtk_widget_add_css_class(profile->id_note, "warning");
    else gtk_widget_remove_css_class(profile->id_note, "warning");
    gtk_button_set_label(GTK_BUTTON(profile->copy), id->copy_label);
    gtk_widget_set_visible(profile->copy, *id->copy_label && *id->friends_id);
    /* No QR while nothing can read one (null in M1): a code a camera cannot act on only invites a dead end. */
    gboolean qr = id->qr_payload && *id->qr_payload && szfriends_gtk_qr_set_payload(profile->qr, id->qr_payload);
    gtk_widget_set_visible(profile->qr, qr);
    gtk_widget_set_visible(profile->qr_button, qr && id->qr_label && *id->qr_label);
    if (qr && id->qr_label) gtk_button_set_label(GTK_BUTTON(profile->qr_button), id->qr_label);
    if (!qr) gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(profile->qr_button), FALSE);
    gtk_accessible_update_property(GTK_ACCESSIBLE(profile->qr), GTK_ACCESSIBLE_PROPERTY_LABEL, id->friends_id, -1);
    const SZFriendsGtkProfileAdd *add = &snapshot->add;
    szfriends_gtk_details_label_set(profile->add_label, add->label);
    gtk_entry_set_placeholder_text(GTK_ENTRY(profile->add_entry), add->placeholder);
    gtk_accessible_update_property(GTK_ACCESSIBLE(profile->add_entry), GTK_ACCESSIBLE_PROPERTY_LABEL, add->label,
                                   -1);
    gtk_button_set_label(GTK_BUTTON(profile->add_button), add->button_label);
    szfriends_gtk_details_label_set(profile->add_hint, add->hint);
    szfriends_gtk_profile_links_apply(profile->links, profile->held);
    szfriends_gtk_profile_devices_apply(profile->computers, profile->held);
}

static void on_snapshot(JsonObject *data, gint64 rev, gpointer user_data) {
    (void)rev;
    SZFriendsGtkProfile *profile = user_data;
    SZFriendsGtkDetailsHeld *previous = profile->held;
    profile->held = szfriends_gtk_details_held_new(&szfriends_gtk_type_profile_snapshot,
                                                   szfriends_gtk_profile_snapshot_parse(data));
    apply(profile);
    szfriends_gtk_details_held_unref(previous);
}

/* ---- The page --------------------------------------------------------------------------------------------- */

static GtkWidget *margins(GtkWidget *widget, int top, int sides) {
    gtk_widget_set_margin_top(widget, top);
    gtk_widget_set_margin_bottom(widget, top);
    gtk_widget_set_margin_start(widget, sides);
    gtk_widget_set_margin_end(widget, sides);
    return widget;
}

static GtkWidget *build_top(SZFriendsGtkProfile *profile, SZFriendsGtkLink *link) {
    GtkWidget *top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    profile->avatar = szfriends_gtk_avatar_new(link, 44);
    gtk_widget_set_valign(profile->avatar, GTK_ALIGN_END);
    GtkWidget *name = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_hexpand(name, TRUE);
    profile->name_label = szfriends_gtk_details_label("szfriends-caption");
    profile->name_entry = gtk_entry_new();
    gtk_widget_set_name(profile->name_entry, "szfriends.profile.name");
    g_signal_connect(profile->name_entry, "activate", G_CALLBACK(name_activated), profile);
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "enter", G_CALLBACK(name_entered), profile);
    g_signal_connect(focus, "leave", G_CALLBACK(name_left), profile);
    gtk_widget_add_controller(profile->name_entry, focus);
    gtk_box_append(GTK_BOX(name), profile->name_label);
    gtk_box_append(GTK_BOX(name), profile->name_entry);
    profile->photo_button = gtk_toggle_button_new();
    gtk_widget_set_name(profile->photo_button, "szfriends.profile.picture");
    gtk_widget_set_valign(profile->photo_button, GTK_ALIGN_END);
    g_signal_connect(profile->photo_button, "toggled", G_CALLBACK(photo_toggled), profile);
    gtk_box_append(GTK_BOX(top), profile->avatar);
    gtk_box_append(GTK_BOX(top), name);
    gtk_box_append(GTK_BOX(top), profile->photo_button);
    return top;
}

static GtkWidget *build_animals(SZFriendsGtkProfile *profile) {
    profile->animals_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    profile->animals_title = szfriends_gtk_details_label("heading");
    profile->animals = gtk_flow_box_new();
    gtk_widget_set_name(profile->animals, "szfriends.profile.animals");
    gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(profile->animals), GTK_SELECTION_SINGLE);
    gtk_flow_box_set_activate_on_single_click(GTK_FLOW_BOX(profile->animals), TRUE);
    gtk_flow_box_set_homogeneous(GTK_FLOW_BOX(profile->animals), TRUE);
    gtk_flow_box_set_min_children_per_line(GTK_FLOW_BOX(profile->animals), 4);
    gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(profile->animals), 8);
    gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(profile->animals), 4);
    gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(profile->animals), 4);
    g_signal_connect(profile->animals, "child-activated", G_CALLBACK(animal_activated), profile);
    profile->own_button = gtk_button_new();
    gtk_widget_set_name(profile->own_button, "szfriends.profile.own-picture");
    gtk_widget_add_css_class(profile->own_button, "flat");
    gtk_widget_add_css_class(profile->own_button, "accent");
    gtk_widget_add_css_class(profile->own_button, "szfriends-text-action"); /* its words on the grid's left edge */
    gtk_widget_set_halign(profile->own_button, GTK_ALIGN_START);
    g_signal_connect(profile->own_button, "clicked", G_CALLBACK(own_picture_clicked), profile);
    gtk_box_append(GTK_BOX(profile->animals_box), profile->animals_title);
    gtk_box_append(GTK_BOX(profile->animals_box), profile->animals);
    gtk_box_append(GTK_BOX(profile->animals_box), profile->own_button);
    gtk_widget_set_visible(profile->animals_box, FALSE);
    return profile->animals_box;
}

static GtkWidget *build_id(SZFriendsGtkProfile *profile) {
    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(card, "card");
    GtkWidget *inner = margins(gtk_box_new(GTK_ORIENTATION_VERTICAL, 6), 12, 12);
    GtkWidget *line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    GtkWidget *text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_hexpand(text, TRUE);
    profile->id_title = szfriends_gtk_details_label("szfriends-secondary caption-heading");
    profile->id_value = szfriends_gtk_details_label("title-2");
    GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    profile->copy = gtk_button_new();
    gtk_widget_set_name(profile->copy, "szfriends.profile.copy");
    g_signal_connect(profile->copy, "clicked", G_CALLBACK(copy_clicked), profile);
    profile->qr_button = gtk_toggle_button_new();
    gtk_widget_set_name(profile->qr_button, "szfriends.profile.qr-button");
    gtk_widget_set_visible(profile->qr_button, FALSE);
    g_signal_connect(profile->qr_button, "toggled", G_CALLBACK(qr_toggled), profile);
    gtk_box_append(GTK_BOX(buttons), profile->copy);
    gtk_box_append(GTK_BOX(buttons), profile->qr_button);
    profile->id_note = szfriends_gtk_details_label(NULL);
    gtk_box_append(GTK_BOX(text), profile->id_title);
    gtk_box_append(GTK_BOX(text), profile->id_value);
    gtk_box_append(GTK_BOX(text), buttons);
    gtk_box_append(GTK_BOX(text), profile->id_note);
    profile->qr = szfriends_gtk_qr_new();
    gtk_widget_set_name(profile->qr, "szfriends.profile.qr");
    gtk_widget_set_valign(profile->qr, GTK_ALIGN_START);
    gtk_widget_set_visible(profile->qr, FALSE);
    gtk_box_append(GTK_BOX(line), text);
    gtk_box_append(GTK_BOX(inner), line);
    szfriends_gtk_qr_set_slots(profile->qr, line, inner);
    gtk_box_append(GTK_BOX(card), inner);
    return card;
}

static GtkWidget *build_add(SZFriendsGtkProfile *profile) {
    GtkWidget *add = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    profile->add_label = szfriends_gtk_details_label("heading");
    GtkWidget *line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    profile->add_entry = gtk_entry_new();
    gtk_widget_set_name(profile->add_entry, "szfriends.profile.add-id");
    gtk_widget_set_hexpand(profile->add_entry, TRUE);
    g_signal_connect(profile->add_entry, "activate", G_CALLBACK(add_activated), profile);
    g_signal_connect(profile->add_entry, "changed", G_CALLBACK(add_changed), profile);
    profile->add_button = gtk_button_new();
    gtk_widget_set_name(profile->add_button, "szfriends.profile.add");
    gtk_widget_add_css_class(profile->add_button, "suggested-action");
    gtk_widget_set_sensitive(profile->add_button, FALSE);
    g_signal_connect(profile->add_button, "clicked", G_CALLBACK(add_activated), profile);
    gtk_box_append(GTK_BOX(line), profile->add_entry);
    gtk_box_append(GTK_BOX(line), profile->add_button);
    profile->add_hint = szfriends_gtk_details_label("szfriends-secondary");
    profile->add_result = szfriends_gtk_details_label(NULL);
    gtk_widget_set_name(profile->add_result, "szfriends.profile.add-result");
    gtk_box_append(GTK_BOX(add), profile->add_label);
    gtk_box_append(GTK_BOX(add), line);
    gtk_box_append(GTK_BOX(add), profile->add_hint);
    gtk_box_append(GTK_BOX(add), profile->add_result);
    return add;
}

static void build(SZFriendsGtkPage *page, gpointer user_data) {
    (void)user_data;
    SZFriendsGtkProfile *profile = g_new0(SZFriendsGtkProfile, 1);
    profile->page = page;
    profile->animals_set = -1;
    szfriends_gtk_page_set_data(page, profile, g_free);
    SZFriendsGtkLink *link = szfriends_gtk_page_get_link(page);
    szfriends_gtk_list_style_ensure(szfriends_gtk_page_get_widget(page)); /* secondary text, text actions */
    profile->box = margins(gtk_box_new(GTK_ORIENTATION_VERTICAL, 14), 14, 16);
    g_object_set_data(G_OBJECT(profile->box), "szfriends-profile", profile);
    gtk_box_append(GTK_BOX(profile->box), build_top(profile, link));
    profile->picture_error = szfriends_gtk_details_label("error");
    gtk_widget_set_name(profile->picture_error, "szfriends.profile.picture-error");
    gtk_box_append(GTK_BOX(profile->box), profile->picture_error);
    gtk_box_append(GTK_BOX(profile->box), build_animals(profile));
    gtk_box_append(GTK_BOX(profile->box), build_id(profile));
    gtk_box_append(GTK_BOX(profile->box), profile->links = szfriends_gtk_profile_links_new(page));
    gtk_box_append(GTK_BOX(profile->box), profile->computers = szfriends_gtk_profile_devices_new(page));
    gtk_box_append(GTK_BOX(profile->box), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    gtk_box_append(GTK_BOX(profile->box), build_add(profile));
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(scroll), TRUE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), profile->box);
    GtkDropTarget *drop = gtk_drop_target_new(GDK_TYPE_FILE_LIST, GDK_ACTION_COPY);
    g_signal_connect(drop, "drop", G_CALLBACK(image_dropped), profile);
    gtk_widget_add_controller(scroll, GTK_EVENT_CONTROLLER(drop));
    /* The crop step takes the place of the page's content; the header and its back arrow stay. */
    profile->stack = gtk_stack_new();
    gtk_widget_set_vexpand(profile->stack, TRUE);
    gtk_stack_add_named(GTK_STACK(profile->stack), scroll, "main");
    szfriends_gtk_page_set_content(page, profile->stack);
}

static void presented(SZFriendsGtkPage *page, gboolean presented, gpointer user_data) {
    (void)user_data;
    SZFriendsGtkProfile *profile = szfriends_gtk_page_get_data(page);
    SZFriendsGtkLink *link = szfriends_gtk_page_get_link(page);
    if (presented && !profile->token) {
        profile->token = szfriends_gtk_link_subscribe(link, "profile", NULL, on_snapshot, profile, NULL);
        /* Add by ID opens this page, so its field is where typing goes; it also brings Escape into the popover. */
        gtk_widget_grab_focus(profile->add_entry);
    } else if (!presented && profile->token) {
        szfriends_gtk_link_unsubscribe(link, profile->token);
        profile->token = 0;
    }
}

/* Escape closes the crop step first, then the animal grid, before the dropdown. */
static gboolean escape(SZFriendsGtkPage *page, gpointer user_data) {
    (void)user_data;
    SZFriendsGtkProfile *profile = szfriends_gtk_page_get_data(page);
    if (szfriends_gtk_profile_devices_escape(profile->computers)) return TRUE;
    if (profile->crop) {
        end_crop(profile);
        return TRUE;
    }
    if (gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(profile->photo_button))) {
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(profile->photo_button), FALSE);
        return TRUE;
    }
    return FALSE;
}

static void dispose(SZFriendsGtkPage *page, gpointer user_data) {
    (void)user_data;
    SZFriendsGtkProfile *profile = szfriends_gtk_page_get_data(page);
    g_clear_pointer(&profile->held, szfriends_gtk_details_held_unref);
}

void szfriends_gtk_profile_page_register(SZFriendsGtkLink *link) {
    static const SZFriendsGtkPageClass klass = {build, presented, escape, dispose};
    szfriends_gtk_register_page(link, SZFRIENDS_GTK_PAGE_PROFILE, &klass, NULL);
}
