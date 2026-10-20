/* Shared by the details, profile and Settings probes (szfriends_gtk_details_probe.h). */

#include "szfriends_gtk_details_probe.h"

#include <math.h>
#include <string.h>

SZFGOutside szfg_outside;

static void record(GPtrArray **list, const char *text) {
    if (!*list) *list = g_ptr_array_new_with_free_func(g_free);
    g_ptr_array_add(*list, g_strdup(text ? text : ""));
}

static void copy_text(GtkWidget *source, const char *text, gpointer data) {
    (void)source, (void)data;
    record(&szfg_outside.copied, text);
}

static void confirm(GtkWidget *source, const SZFriendsGtkConfirm *question, gboolean destructive, SZFriendsGtkRun run,
                    gpointer run_data, GDestroyNotify run_destroy, gpointer data) {
    (void)source, (void)data;
    szfg_outside_answer(FALSE); /* a question left unanswered is withdrawn by the next */
    char *title = g_strdup_printf("%s%s", question->title, destructive ? " (destructive)" : "");
    record(&szfg_outside.confirms, title);
    record(&szfg_outside.confirm_bodies, question->body);
    g_free(title);
    szfg_outside.run = run;
    szfg_outside.run_data = run_data;
    szfg_outside.run_destroy = run_destroy;
}

static void choose_image(GtkWidget *source, const char *title, SZFriendsGtkChosen chosen, gpointer chosen_data,
                         gpointer data) {
    (void)source, (void)title, (void)data;
    szfg_outside.chooser_calls++;
    chosen(szfg_outside.chosen, chosen_data);
}

static void choose_folder(GtkWidget *source, const char *start, SZFriendsGtkChosen chosen, gpointer chosen_data,
                          gpointer data) {
    (void)source, (void)data;
    szfg_outside.chooser_calls++;
    g_free(szfg_outside.folder_start);
    szfg_outside.folder_start = g_strdup(start);
    chosen(szfg_outside.chosen, chosen_data);
}

static void open_uri(GtkWidget *source, const char *uri, gpointer data) {
    (void)source, (void)data;
    record(&szfg_outside.uris, uri);
}

static void clear(void) {
    GPtrArray **lists[] = {&szfg_outside.copied, &szfg_outside.revealed, &szfg_outside.opened, &szfg_outside.uris,
                           &szfg_outside.confirms, &szfg_outside.confirm_bodies};
    for (gsize i = 0; i < G_N_ELEMENTS(lists); i++) g_clear_pointer(lists[i], g_ptr_array_unref);
    g_clear_pointer(&szfg_outside.chosen, g_free);
    g_clear_pointer(&szfg_outside.folder_start, g_free);
    szfg_outside.chooser_calls = 0;
}

void szfg_outside_install(void) {
    szfg_outside_answer(FALSE);
    clear();
    static const SZFriendsGtkSeams seams = {.copy_text = copy_text, .open_uri = open_uri, .confirm = confirm,
                                            .choose_image = choose_image, .choose_folder = choose_folder};
    szfriends_gtk_set_seams(&seams);
}

void szfg_outside_uninstall(void) {
    szfg_outside_answer(FALSE);
    clear();
    szfriends_gtk_set_seams(NULL);
}

void szfg_outside_answer(gboolean yes) {
    SZFriendsGtkRun run = szfg_outside.run;
    gpointer data = szfg_outside.run_data;
    GDestroyNotify destroy = szfg_outside.run_destroy;
    szfg_outside.run = NULL;
    szfg_outside.run_data = NULL;
    szfg_outside.run_destroy = NULL;
    if (yes && run) run(data);
    if (destroy) destroy(data);
}

static void host_reveal(gpointer host_data, GtkWindow *window, const char *path) {
    (void)host_data, (void)window;
    record(&szfg_outside.revealed, path);
}

static void host_open(gpointer host_data, GtkWindow *window, const char *path) {
    (void)host_data, (void)window;
    record(&szfg_outside.opened, path);
}

static gboolean link_ready(gpointer data) {
    return szfriends_gtk_link_get_state(((SZFGHarness *)data)->link) == SZFRIENDS_GTK_LINK_READY;
}

SZFGHarness *szfg_details_harness(const char *label) {
    SZFGHarness *harness = g_new0(SZFGHarness, 1);
    harness->state = szfg_temp_dir(label);
    g_setenv(SZFRIENDS_ENV_STATE_DIR, harness->state, TRUE);
    harness->host.struct_size = sizeof harness->host;
    harness->host.app_id = "com.intuition.shenzhenfiles";
    harness->host.app_name = "Shenzhen Files";
    harness->host.app_version = "26.10.13";
    harness->host.reveal_in_name = "Shenzhen Files";
    harness->host.reveal_file = host_reveal;
    harness->host.open_received_file = host_open;
    harness->host.animals_manifest_path = szfg_manifest;
    harness->link = szfriends_gtk_link_new(&harness->host);
    szfg_harness_start_fake(harness);
    szfriends_gtk_link_start(harness->link);
    EXPECT(szfg_pump_until(link_ready, harness, 5000), "%s: the link reaches READY", label);
    return harness;
}

static void present(SZFriendsGtkDropdown *dropdown, gpointer data) {
    (void)dropdown, (void)data;
}

static void dismiss(SZFriendsGtkDropdown *dropdown, gpointer data) {
    (void)data;
    szfriends_gtk_dropdown_presenter_closed(dropdown);
}

SZFGRig *szfg_rig_new(SZFGHarness *harness) {
    SZFGRig *rig = g_new0(SZFGRig, 1);
    rig->window = gtk_window_new();
    rig->anchor = szfriends_gtk_button_new(harness->link, GTK_WINDOW(rig->window));
    gtk_window_set_child(GTK_WINDOW(rig->window), rig->anchor);
    rig->dropdown = szfriends_gtk_dropdown_for_button(rig->anchor);
    static const SZFriendsGtkPresenter presenter = {present, dismiss};
    szfriends_gtk_dropdown_set_presenter(rig->dropdown, &presenter, NULL);
    szfriends_gtk_dropdown_open(rig->dropdown);
    return rig;
}

void szfg_rig_free(SZFGRig *rig) {
    if (szfriends_gtk_dropdown_is_open(rig->dropdown)) szfriends_gtk_dropdown_close(rig->dropdown);
    gtk_window_destroy(GTK_WINDOW(rig->window));
    szfg_pump_for(20);
    g_free(rig);
}

GtkWidget *szfg_rig_page(SZFGRig *rig) {
    SZFriendsGtkPage *page = szfriends_gtk_dropdown_get_top_page(rig->dropdown);
    return page ? szfriends_gtk_page_get_widget(page) : NULL;
}

void szfg_rig_render(SZFGRig *rig, int height, const char *name) {
    szfg_rig_render_contrast(rig, height, name, NULL, NULL);
}

void szfg_rig_render_contrast(SZFGRig *rig, int height, const char *name, GtkWidget *const *labels,
                              double *contrasts) {
    GtkWidget *content = szfriends_gtk_dropdown_get_content(rig->dropdown);
    GtkWidget *window = szfg_probe_window(content);
    GdkTexture *texture = szfg_render(window, 400, height, name);
    for (gsize i = 0; labels && labels[i]; i++) contrasts[i] = szfg_text_contrast(texture, content, labels[i]);
    g_object_unref(texture);
    g_object_ref(content);
    gtk_window_set_child(GTK_WINDOW(window), NULL);
    gtk_window_destroy(GTK_WINDOW(window));
    g_object_unref(content);
}

GtkWidget *szfg_find_named(GtkWidget *root, const char *name) {
    if (!root) return NULL;
    if (!g_strcmp0(gtk_widget_get_name(root), name)) return root;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = szfg_find_named(child, name);
        if (found) return found;
    }
    return NULL;
}

GtkWidget *szfg_find_label(GtkWidget *root, const char *text) {
    if (!root) return NULL;
    if (GTK_IS_LABEL(root) && !g_strcmp0(gtk_label_get_text(GTK_LABEL(root)), text)) return root;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = szfg_find_label(child, text);
        if (found) return found;
    }
    return NULL;
}

GtkWidget *szfg_find_button(GtkWidget *root, const char *label) {
    GtkWidget *text = szfg_find_label(root, label);
    return text ? gtk_widget_get_ancestor(text, GTK_TYPE_BUTTON) : NULL;
}

static GtkEventController *controller(GtkWidget *widget, GType type) {
    GListModel *controllers = gtk_widget_observe_controllers(widget);
    GtkEventController *found = NULL;
    for (guint i = 0; i < g_list_model_get_n_items(controllers) && !found; i++) {
        GtkEventController *candidate = g_list_model_get_item(controllers, i);
        if (G_TYPE_CHECK_INSTANCE_TYPE(candidate, type) &&
            (type != GTK_TYPE_GESTURE_CLICK ||
             gtk_event_controller_get_propagation_phase(candidate) == GTK_PHASE_CAPTURE))
            found = candidate;
        g_object_unref(candidate);
    }
    g_object_unref(controllers);
    return found;
}

void szfg_press(GtkWidget *button, int n_press) {
    GtkEventController *gesture = controller(button, GTK_TYPE_GESTURE_CLICK);
    if (gesture) g_signal_emit_by_name(gesture, "pressed", n_press, 4.0, 4.0);
    g_signal_emit_by_name(button, "clicked");
}

void szfg_leave(GtkWidget *button) {
    GtkEventController *motion = controller(button, GTK_TYPE_EVENT_CONTROLLER_MOTION);
    EXPECT(motion != NULL, "the button watches the pointer leave");
    if (motion) g_signal_emit_by_name(motion, "leave");
}

typedef struct {
    SZFGHarness *harness;
    const char *type, *key, *value;
    guint count;
} SZFGFrameWait;

static gboolean frames_arrived(gpointer data) {
    SZFGFrameWait *wait = data;
    return szfg_fake_frames(wait->harness, wait->type, wait->key, wait->value) >= wait->count;
}

gboolean szfg_wait_frames(SZFGHarness *harness, const char *type, const char *key, const char *value, guint count) {
    SZFGFrameWait wait = {harness, type, key, value, count};
    return szfg_pump_until(frames_arrived, &wait, 3000);
}

void szfg_script_view(SZFGHarness *harness, const char *view, JsonObject *data) {
    JsonNode *node = json_node_new(JSON_NODE_OBJECT);
    json_node_set_object(node, data);
    char *text = json_to_string(node, FALSE);
    EXPECT(szfriends_fake_helper_set_view_data(harness->fake, view, text) == SZFRIENDS_OK, "%s scripted", view);
    g_free(text);
    json_node_unref(node);
}

JsonObject *szfg_fixture_data(const char *relative) {
    JsonObject *frame = szfg_fixture(relative);
    JsonObject *data = frame ? json_object_ref(json_object_get_object_member(frame, "data")) : NULL;
    if (frame) json_object_unref(frame);
    return data;
}

typedef struct {
    GtkWidget *root;
    const char *text;
} SZFGLabelWait;

static gboolean label_shown(gpointer data) {
    SZFGLabelWait *wait = data;
    return szfg_find_label(wait->root, wait->text) != NULL;
}

gboolean szfg_wait_label(GtkWidget *root, const char *text) {
    SZFGLabelWait wait = {root, text};
    return szfg_pump_until(label_shown, &wait, 3000);
}

/* ---- Contrast ------------------------------------------------------------------------------------------- */

static double luminance(const guint8 *pixel) {
    double linear[3];
    for (int i = 0; i < 3; i++) {
        double value = pixel[i] / 255.0;
        linear[i] = value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4);
    }
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

double szfg_text_contrast(GdkTexture *render, GtkWidget *root, GtkWidget *label) {
    graphene_rect_t box;
    if (!render || !label || !gtk_widget_compute_bounds(label, root, &box)) return 0;
    SZFGPixels pixels = szfg_pixels(render);
    int x0 = (int)(box.origin.x * 2), y0 = (int)(box.origin.y * 2);
    int x1 = (int)((box.origin.x + box.size.width) * 2), y1 = (int)((box.origin.y + box.size.height) * 2);
    /* The page is what most of a line of text's box shows; the text is the pixel farthest from it. */
    GHashTable *counts = g_hash_table_new(g_direct_hash, g_direct_equal);
    guint32 background = 0, best = 0;
    for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x++) {
            const guint8 *p = szfg_pixel(&pixels, x, y);
            guint32 key = (guint32)p[0] << 16 | (guint32)p[1] << 8 | p[2];
            guint count = GPOINTER_TO_UINT(g_hash_table_lookup(counts, GUINT_TO_POINTER(key))) + 1;
            g_hash_table_insert(counts, GUINT_TO_POINTER(key), GUINT_TO_POINTER(count));
            if (count > best) best = count, background = key;
        }
    g_hash_table_unref(counts);
    const guint8 page[3] = {background >> 16 & 255, background >> 8 & 255, background & 255};
    double page_luminance = luminance(page), text_luminance = page_luminance;
    for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x++) {
            double l = luminance(szfg_pixel(&pixels, x, y));
            if (fabs(l - page_luminance) > fabs(text_luminance - page_luminance)) text_luminance = l;
        }
    szfg_pixels_free(&pixels);
    return (MAX(page_luminance, text_luminance) + 0.05) / (MIN(page_luminance, text_luminance) + 0.05);
}

GtkWidget *szfg_find_css_name(GtkWidget *root, const char *css_name) {
    if (!root) return NULL;
    if (!g_strcmp0(gtk_widget_get_css_name(root), css_name)) return root;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = szfg_find_css_name(child, css_name);
        if (found) return found;
    }
    return NULL;
}

gboolean szfg_same_left(GtkWidget *root, GtkWidget *a, GtkWidget *b) {
    graphene_rect_t first, second;
    gboolean placed = a && b && gtk_widget_compute_bounds(a, root, &first) &&
                      gtk_widget_compute_bounds(b, root, &second);
    if (!placed) return FALSE;
    if (fabsf(first.origin.x - second.origin.x) > 1) fprintf(stderr, "  left edges %.1f and %.1f\n", first.origin.x,
                                                              second.origin.x);
    return fabsf(first.origin.x - second.origin.x) <= 1;
}
