/* Your profile offscreen, against the fake helper: the name sent only when changed and never overwritten while
 * typed, the animal set from this app's copy with the chosen one selected, your own photo chosen or dropped and placed
 * under the circle (only the square travels), a photo the views cannot show sent uncropped with the helper's refusal
 * shown, Copy, no QR while the helper sends none and the QR when it does, Add by ID with its answer, and Escape
 * closing the crop step, then the grid, then the dropdown. Renders light and dark: the page with the animals, the
 * crop step, the QR; the page's secondary text measured at WCAG AA and its text action on the column's edge. */

#include "szfriends_gtk_details_probe.h"
#include "gtk/szfriends_gtk_crop.h"

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <string.h>

static char *photos;

/* Two colours side by side, so the render shows where the circle sits on the photo. */
static char *write_photo(const char *name, const char *type) {
    GdkPixbuf *pixbuf = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, 640, 480);
    gdk_pixbuf_fill(pixbuf, 0x2f6474ff);
    GdkPixbuf *half = gdk_pixbuf_new_subpixbuf(pixbuf, 320, 0, 320, 480);
    gdk_pixbuf_fill(half, 0xe0a050ff);
    g_object_unref(half);
    char *path = g_build_filename(photos, name, NULL);
    EXPECT(gdk_pixbuf_save(pixbuf, path, type, NULL, NULL), "%s written", name);
    g_object_unref(pixbuf);
    return path;
}

static GtkWidget *open_profile(SZFGRig *rig) {
    szfriends_gtk_dropdown_open_profile(rig->dropdown);
    GtkWidget *page = szfg_rig_page(rig);
    EXPECT(szfg_wait_label(page, "Name friends see"), "the profile snapshot is drawn");
    return page;
}

static GtkWidget *crop_of(GtkWidget *page) {
    return szfg_find_named(page, "szfriends.crop");
}

static gboolean crop_loaded(gpointer data) {
    return szfriends_gtk_crop_is_loaded(crop_of(data));
}

static GtkWidget *choose(GtkWidget *page, const char *path) {
    GtkWidget *toggle = szfg_find_named(page, "szfriends.profile.picture");
    if (!gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(toggle)))
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(toggle), TRUE);
    g_free(szfg_outside.chosen);
    szfg_outside.chosen = g_strdup(path);
    g_signal_emit_by_name(szfg_find_named(page, "szfriends.profile.own-picture"), "clicked");
    return crop_of(page);
}

static void test_name_and_copy(SZFGHarness *harness, GtkWidget *page) {
    GtkWidget *name = szfg_find_named(page, "szfriends.profile.name");
    EXPECT(name && !g_strcmp0(gtk_editable_get_text(GTK_EDITABLE(name)), "Raph") &&
               gtk_entry_get_max_length(GTK_ENTRY(name)) == 40, "the name, and the helper's length limit");
    g_signal_emit_by_name(name, "activate");
    szfg_pump_for(100);
    EXPECT(szfg_fake_frames(harness, "set_name", NULL, NULL) == 0, "an unchanged name sends nothing");
    gtk_editable_set_text(GTK_EDITABLE(name), "Raph L.");
    g_signal_emit_by_name(name, "activate");
    EXPECT(szfg_wait_frames(harness, "set_name", "name", "Raph L.", 1), "Return sends the new name");
    GtkWidget *copy = szfg_find_named(page, "szfriends.profile.copy");
    if (copy) g_signal_emit_by_name(copy, "clicked");
    EXPECT(szfg_outside.copied && !strcmp(g_ptr_array_index(szfg_outside.copied, szfg_outside.copied->len - 1),
                                          "cottage-violet"), "Copy takes your ID");
    EXPECT(copy && !g_strcmp0(gtk_button_get_label(GTK_BUTTON(copy)), "Copied"), "and says it did");
    GtkWidget *qr = szfg_find_named(page, "szfriends.profile.qr");
    GtkWidget *qr_button = szfg_find_named(page, "szfriends.profile.qr-button");
    EXPECT(qr && qr_button && !gtk_widget_get_visible(qr) && !gtk_widget_get_visible(qr_button),
           "no QR and no QR button while the helper sends none");
}

static GtkEventController *focus_watch(GtkWidget *widget) {
    GListModel *controllers = gtk_widget_observe_controllers(widget);
    GtkEventController *found = NULL;
    for (guint i = 0; i < g_list_model_get_n_items(controllers) && !found; i++) {
        GtkEventController *candidate = g_list_model_get_item(controllers, i);
        if (GTK_IS_EVENT_CONTROLLER_FOCUS(candidate)) found = candidate;
        g_object_unref(candidate);
    }
    g_object_unref(controllers);
    return found;
}

/* Typing is never overwritten by a snapshot, and leaving the field commits it, as Return does. An unmapped window
 * never has keyboard focus, so the probe plays the focus watcher's enter and leave itself. */
static void test_editing(SZFGHarness *harness, GtkWidget *page) {
    GtkWidget *name = szfg_find_named(page, "szfriends.profile.name");
    GtkEventController *focus = focus_watch(name);
    EXPECT(focus != NULL, "the name field watches focus");
    if (!focus) return;
    g_signal_emit_by_name(focus, "enter");
    gtk_editable_set_text(GTK_EDITABLE(name), "Ra");
    JsonObject *data = szfg_fixture_data("snapshots/profile-unreserved.json");
    json_object_set_string_member(json_object_get_object_member(data, "add"), "hint", "Two words.");
    szfg_script_view(harness, "profile", data);
    json_object_unref(data);
    EXPECT(szfg_wait_label(page, "Two words.") && !g_strcmp0(gtk_editable_get_text(GTK_EDITABLE(name)), "Ra"),
           "a snapshot leaves the name being typed alone");
    g_signal_emit_by_name(focus, "leave");
    EXPECT(szfg_wait_frames(harness, "set_name", "name", "Ra", 1), "leaving the field sends it");
    szfriends_fake_helper_set_view_fixture(harness->fake, "profile", "profile-unreserved.json");
    EXPECT(szfg_wait_label(page, "Two words, like amber‑falcon."), "the fixture again");
}

static void test_animals(SZFGHarness *harness, GtkWidget *page) {
    GtkWidget *toggle = szfg_find_named(page, "szfriends.profile.picture");
    EXPECT(toggle && !g_strcmp0(gtk_button_get_label(GTK_BUTTON(toggle)), "Change picture…"), "Change picture…");
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(toggle), TRUE);
    GtkWidget *animals = szfg_find_named(page, "szfriends.profile.animals");
    guint count = 0;
    for (GtkWidget *child = animals ? gtk_widget_get_first_child(animals) : NULL; child;
         child = gtk_widget_get_next_sibling(child))
        count++;
    GList *selected = animals ? gtk_flow_box_get_selected_children(GTK_FLOW_BOX(animals)) : NULL;
    EXPECT(gtk_widget_get_visible(animals) && count == 24 && selected &&
               gtk_flow_box_child_get_index(selected->data) == 0, "the whole set, the chosen animal selected (%u)",
           count);
    EXPECT(szfg_find_label(page, "Choose an animal") && szfg_find_button(page, "Use your own picture…"),
           "under the catalog's title, with your own picture offered");
    g_list_free(selected);
    GtkFlowBoxChild *fourth = gtk_flow_box_get_child_at_index(GTK_FLOW_BOX(animals), 3);
    g_signal_emit_by_name(animals, "child-activated", fourth);
    EXPECT(szfg_wait_frames(harness, "set_picture", NULL, NULL, 1), "choosing an animal sends it");
    JsonObject *frame = szfg_fake_last_frame(harness, "set_picture");
    JsonObject *picture = frame ? json_object_get_object_member(frame, "picture") : NULL;
    EXPECT(picture && !g_strcmp0(json_object_get_string_member(picture, "kind"), "animal") &&
               json_object_get_int_member(picture, "set") == 1 && json_object_get_int_member(picture, "index") == 3,
           "as its set and number, which friends' apps draw from their own copy");
    if (frame) json_object_unref(frame);
}

static void test_own_photo(SZFGHarness *harness, SZFGRig *rig, GtkWidget *page) {
    char *photo = write_photo("photo.png", "png");
    GtkWidget *crop = choose(page, photo);
    EXPECT(crop && szfg_pump_until(crop_loaded, page, 5000), "the chosen photo comes up under the circle");
    GtkWidget *scale = crop ? szfg_find_named(crop, "szfriends.crop.use") : NULL;
    for (GtkWidget *w = crop ? gtk_widget_get_first_child(crop) : NULL; w; w = gtk_widget_get_next_sibling(w))
        if (GTK_IS_SCALE(w)) gtk_range_set_value(GTK_RANGE(w), 2);
    guint before = szfg_fake_frames(harness, "set_picture", NULL, NULL);
    if (scale) g_signal_emit_by_name(scale, "clicked");
    EXPECT(szfg_wait_frames(harness, "set_picture", NULL, NULL, before + 1) && !crop_of(page),
           "Use Picture sends it and the crop step goes");
    JsonObject *frame = szfg_fake_last_frame(harness, "set_picture");
    JsonObject *picture = frame ? json_object_get_object_member(frame, "picture") : NULL;
    JsonObject *square = picture && json_object_has_member(picture, "crop")
                             ? json_object_get_object_member(picture, "crop") : NULL;
    EXPECT(picture && !g_strcmp0(json_object_get_string_member(picture, "path"), photo) && square &&
               json_object_get_int_member(square, "side") == 240 && json_object_get_int_member(square, "x") == 200 &&
               json_object_get_int_member(square, "y") == 120 && !json_object_has_member(picture, "data_base64"),
           "the path and the square at twice the zoom, centred; no image data from the views");
    if (frame) json_object_unref(frame);
    /* A BMP: not the helper's kind of picture, so never decoded here; the helper says why. */
    szfriends_fake_helper_set_reply(harness->fake, "set_picture",
                                    "{\"type\":\"reply\",\"re\":\"0\",\"ok\":false,\"error\":{\"code\":"
                                    "\"picture_invalid\",\"message\":\"This file can’t be read as a picture. Choose a "
                                    "JPEG, PNG or HEIC image.\",\"retryable\":false,\"details\":{}}}");
    char *bmp = write_photo("photo.bmp", "bmp");
    before = szfg_fake_frames(harness, "set_picture", NULL, NULL);
    choose(page, bmp);
    EXPECT(szfg_wait_frames(harness, "set_picture", NULL, NULL, before + 1), "sent at once, uncropped");
    frame = szfg_fake_last_frame(harness, "set_picture");
    picture = frame ? json_object_get_object_member(frame, "picture") : NULL;
    EXPECT(picture && !g_strcmp0(json_object_get_string_member(picture, "path"), bmp) &&
               (!json_object_has_member(picture, "crop") || json_object_get_null_member(picture, "crop")),
           "with its path and no square");
    if (frame) json_object_unref(frame);
    EXPECT(szfg_wait_label(page, "This file can’t be read as a picture. Choose a JPEG, PNG or HEIC image."),
           "the helper's refusal is shown under the picture");
    szfriends_fake_helper_set_reply(harness->fake, "set_picture", NULL);
    /* Escape: the crop step first, then the grid, then the dropdown. */
    choose(page, photo);
    EXPECT(crop_of(page) != NULL, "the crop step is open");
    szfriends_gtk_dropdown_escape(rig->dropdown);
    GtkWidget *animals = szfg_find_named(page, "szfriends.profile.animals");
    EXPECT(!crop_of(page) && szfriends_gtk_dropdown_is_open(rig->dropdown) && gtk_widget_get_visible(
                                                                                    gtk_widget_get_parent(animals)),
           "Escape closes the crop step first");
    szfriends_gtk_dropdown_escape(rig->dropdown);
    EXPECT(!gtk_widget_get_visible(gtk_widget_get_parent(animals)) && szfriends_gtk_dropdown_is_open(rig->dropdown),
           "then the animal grid");
    szfriends_gtk_dropdown_escape(rig->dropdown);
    EXPECT(!szfriends_gtk_dropdown_is_open(rig->dropdown), "then the dropdown");
    szfriends_gtk_dropdown_open(rig->dropdown);
    g_free(photo);
    g_free(bmp);
}

static GtkDropTarget *drop_target(GtkWidget *root) {
    GListModel *controllers = gtk_widget_observe_controllers(root);
    GtkDropTarget *found = NULL;
    for (guint i = 0; i < g_list_model_get_n_items(controllers) && !found; i++) {
        GtkEventController *candidate = g_list_model_get_item(controllers, i);
        if (GTK_IS_DROP_TARGET(candidate)) found = GTK_DROP_TARGET(candidate);
        g_object_unref(candidate);
    }
    g_object_unref(controllers);
    for (GtkWidget *child = gtk_widget_get_first_child(root); child && !found;
         child = gtk_widget_get_next_sibling(child))
        found = drop_target(child);
    return found;
}

static gboolean drop(GtkDropTarget *target, const char *path) {
    GFile *file = g_file_new_for_path(path);
    GSList *files = g_slist_prepend(NULL, file);
    GValue value = G_VALUE_INIT;
    g_value_init(&value, GDK_TYPE_FILE_LIST);
    g_value_take_boxed(&value, gdk_file_list_new_from_list(files));
    gboolean taken = FALSE;
    g_signal_emit_by_name(target, "drop", &value, 10.0, 10.0, &taken);
    g_value_unset(&value);
    g_slist_free(files);
    g_object_unref(file);
    return taken;
}

/* An image dropped on the page starts the same crop step; anything else is turned away. */
static void test_drop(SZFGRig *rig, GtkWidget *page) {
    GtkDropTarget *target = drop_target(page);
    EXPECT(target != NULL, "the page takes dropped files");
    if (!target) return;
    char *text = g_build_filename(photos, "notes.txt", NULL), *photo = write_photo("dropped.png", "png");
    g_file_set_contents(text, "not a picture", -1, NULL);
    EXPECT(!drop(target, text) && !crop_of(page), "a text file is refused");
    EXPECT(drop(target, photo) && crop_of(page) && szfg_pump_until(crop_loaded, page, 5000),
           "a dropped image comes up under the circle");
    szfriends_gtk_dropdown_escape(rig->dropdown);
    EXPECT(!crop_of(page), "and Escape puts it away");
    g_free(text);
    g_free(photo);
}

static void test_add(SZFGHarness *harness, GtkWidget *page) {
    GtkWidget *entry = szfg_find_named(page, "szfriends.profile.add-id");
    GtkWidget *add = szfg_find_named(page, "szfriends.profile.add");
    GtkWidget *result = szfg_find_named(page, "szfriends.profile.add-result");
    EXPECT(add && !g_strcmp0(gtk_button_get_label(GTK_BUTTON(add)), "Send request") && !gtk_widget_get_sensitive(add),
           "Send request waits for an ID");
    gtk_editable_set_text(GTK_EDITABLE(entry), "  willow-breeze ");
    EXPECT(gtk_widget_get_sensitive(add), "and takes one");
    g_signal_emit_by_name(entry, "activate");
    EXPECT(!gtk_widget_get_sensitive(add), "one request at a time");
    EXPECT(szfg_wait_frames(harness, "add_by_id", "friends_id", "willow-breeze", 1), "Return asks, the ID trimmed");
    const char *sent = "Request sent to willow‑breeze. They’ll get it as soon as Friends reaches them, and you’ll "
                       "be friends once they accept.";
    EXPECT(szfg_wait_label(page, sent) && !gtk_widget_has_css_class(result, "error"), "the helper's answer shows");
    EXPECT(!*gtk_editable_get_text(GTK_EDITABLE(entry)) && !gtk_widget_get_sensitive(add), "the field is emptied");
    szfriends_fake_helper_set_reply(harness->fake, "add_by_id",
                                    "{\"type\":\"reply\",\"re\":\"0\",\"ok\":false,\"error\":{\"code\":\"id_invalid\","
                                    "\"message\":\"“lamp-moon” isn’t a Friends ID.\",\"retryable\":false,"
                                    "\"details\":{}}}");
    szfg_pump_for(50);
    gtk_editable_set_text(GTK_EDITABLE(entry), "lamp-moon");
    g_signal_emit_by_name(add, "clicked");
    EXPECT(szfg_wait_label(page, "“lamp-moon” isn’t a Friends ID.") && gtk_widget_has_css_class(result, "error") &&
               !g_strcmp0(gtk_editable_get_text(GTK_EDITABLE(entry)), "lamp-moon"),
           "a refusal shows in red and the ID stays to correct");
    szfriends_fake_helper_set_reply(harness->fake, "add_by_id", NULL);
}

static gboolean qr_hidden(gpointer data) {
    return !gtk_widget_get_visible(data);
}

static void script_qr(SZFGHarness *harness) {
    JsonObject *data = szfg_fixture_data("snapshots/profile-unreserved.json");
    JsonObject *id = json_object_get_object_member(data, "id");
    json_object_set_string_member(id, "qr_label", "Larger QR");
    json_object_set_string_member(id, "qr_payload", "szfriends:add?id=cottage-violet&key="
                                                    "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_abcde");
    szfg_script_view(harness, "profile", data);
    json_object_unref(data);
}

static void test_qr(SZFGHarness *harness, GtkWidget *page) {
    script_qr(harness);
    EXPECT(szfg_wait_label(page, "Larger QR"), "the QR button once the helper sends a code");
    GtkWidget *qr = szfg_find_named(page, "szfriends.profile.qr");
    GtkWidget *beside = gtk_widget_get_parent(qr);
    EXPECT(gtk_widget_get_visible(qr), "and the code beside your ID");
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(szfg_find_named(page, "szfriends.profile.qr-button")), TRUE);
    int width = 0, height = 0;
    gtk_widget_get_size_request(qr, &width, &height);
    EXPECT(gtk_widget_get_parent(qr) != beside && width == 200 && height == 200, "larger, under the ID, to scan");
    szfriends_fake_helper_set_view_fixture(harness->fake, "profile", "profile-unreserved.json");
    GtkWidget *qr_button = szfg_find_named(page, "szfriends.profile.qr-button");
    EXPECT(szfg_pump_until(qr_hidden, qr, 3000) && !gtk_widget_get_visible(qr_button),
           "and both go when the helper stops sending one");
}

static void render_fresh(SZFGHarness *harness, gboolean dark, int what, const char *name) {
    szfg_set_dark(dark);
    if (what == 2) script_qr(harness);
    else szfriends_fake_helper_set_view_fixture(harness->fake, "profile", "profile-unreserved.json");
    szfg_pump_for(50);
    SZFGRig *rig = szfg_rig_new(harness);
    GtkWidget *page = open_profile(rig);
    if (what == 0) gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(szfg_find_named(page, "szfriends.profile.picture")),
                                                TRUE);
    char *photo = what == 1 ? write_photo("render.png", "png") : NULL;
    if (photo) EXPECT(choose(page, photo) && szfg_pump_until(crop_loaded, page, 5000), "%s: the photo", name);
    if (what == 2) EXPECT(szfg_wait_label(page, "Larger QR"), "%s: the QR", name);
    /* Secondary text at WCAG AA, 4.5:1 (UX review, wave 6b: .dimmed drew 3.2:1). */
    GtkWidget *labels[] = {szfg_find_label(page, "Name friends see"), szfg_find_label(page, "Your ID"),
                           szfg_find_label(page, "Two words, like amber‑falcon."), NULL};
    double contrast[G_N_ELEMENTS(labels)] = {0};
    szfg_rig_render_contrast(rig, 640, name, what == 0 ? labels : NULL, contrast);
    for (gsize i = 0; what == 0 && i + 1 < G_N_ELEMENTS(labels); i++)
        EXPECT(labels[i] && contrast[i] >= 4.5, "%s: secondary text %zu reads at %.2f:1, at least 4.5:1", name, i,
               contrast[i]);
    if (what == 0) {
        /* "Use your own picture…" starts where the grid's title does, as AppKit lines them up. */
        GtkWidget *own = szfg_find_named(page, "szfriends.profile.own-picture");
        GtkWidget *content = szfriends_gtk_dropdown_get_content(rig->dropdown), *window = szfg_probe_window(content);
        szfg_layout(window, 400, 640);
        EXPECT(own && szfg_same_left(page, gtk_button_get_child(GTK_BUTTON(own)),
                                     szfg_find_named(page, "szfriends.profile.animals")),
               "%s: the text action starts at the grid's edge", name);
        g_object_ref(content);
        gtk_window_set_child(GTK_WINDOW(window), NULL);
        gtk_window_destroy(GTK_WINDOW(window));
        g_object_unref(content);
    }
    g_free(photo);
    szfg_rig_free(rig);
    szfg_set_dark(FALSE);
}

void szfg_run_profile_probes(void) {
    photos = szfg_temp_dir("photos");
    SZFGHarness *harness = szfg_details_harness("profile");
    szfg_outside_install();
    const char *names[3][2] = {{"profile-light", "profile-dark"}, {"crop-light", "crop-dark"},
                               {"profile-qr-light", "profile-qr-dark"}};
    for (int what = 0; what < 3; what++)
        for (int dark = 0; dark < 2; dark++) render_fresh(harness, dark, what, names[what][dark]);
    szfriends_fake_helper_set_view_fixture(harness->fake, "profile", "profile-unreserved.json");
    SZFGRig *rig = szfg_rig_new(harness);
    GtkWidget *page = open_profile(rig);
    EXPECT(szfg_pump_until(qr_hidden, szfg_find_named(page, "szfriends.profile.qr"), 2000), "the fixture's no QR");
    test_name_and_copy(harness, page);
    test_editing(harness, page);
    test_animals(harness, page);
    test_own_photo(harness, rig, page);
    test_drop(rig, page);
    test_add(harness, page);
    test_qr(harness, page);
    szfg_rig_free(rig);
    szfg_outside_uninstall();
    szfg_harness_free(harness);
    szfg_remove_tree(photos);
    g_free(photos);
}
