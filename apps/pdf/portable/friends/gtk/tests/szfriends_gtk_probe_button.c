/* The Friends button offscreen: the helper's badge inside the button's frame and clear of the second person, the drop
 * highlight, spring-loading after 500 ms, folders, links and special files refused with the helper's words and never
 * the drop hint, "Send 2 files to…" on release, and the host's placement callbacks. The dropdown is presented through
 * a recorder, so no popover ever reaches the screen. */

#include "szfriends_gtk_probe.h"

#include <glib/gstdio.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    int presents, dismisses;
} SZFGRecorder;

static void record_present(SZFriendsGtkDropdown *dropdown, gpointer data) {
    (void)dropdown;
    ((SZFGRecorder *)data)->presents++;
}

static void record_dismiss(SZFriendsGtkDropdown *dropdown, gpointer data) {
    ((SZFGRecorder *)data)->dismisses++;
    szfriends_gtk_dropdown_presenter_closed(dropdown);
}

static const SZFriendsGtkPresenter recorder = {record_present, record_dismiss};

static gboolean badge_arrived(gpointer data) {
    return szfriends_gtk_link_badge(data) != NULL;
}

static GValue *files_value(const char *const *paths) {
    GSList *files = NULL;
    for (const char *const *path = paths; *path; path++) files = g_slist_append(files, g_file_new_for_path(*path));
    GValue *value = g_new0(GValue, 1);
    g_value_init(value, GDK_TYPE_FILE_LIST);
    g_value_take_boxed(value, gdk_file_list_new_from_list(files));
    g_slist_free_full(files, g_object_unref);
    return value;
}

static void value_free(GValue *value) {
    g_value_unset(value);
    g_free(value);
}

static gboolean dropdown_open(gpointer data) {
    return szfriends_gtk_dropdown_is_open(data);
}

/* The spring-open timer is the main loop's 500 ms: waits for it, bounded, rather than a fixed time a loaded machine
 * can overrun. */
static gboolean springs_open(SZFriendsGtkDropdown *dropdown) {
    return szfg_pump_until(dropdown_open, dropdown, 3000);
}

/* The icon's pixels, rendered with the badge itself transparent: how many fall inside the badge's rectangle, and
 * where their centre is (render pixels, scale 2). */
typedef struct {
    int under_badge;
    double x, y;
} SZFGIconSpot;

static SZFGIconSpot icon_spot(GtkWidget *window, GtkWidget *anchor, const char *name) {
    SZFGIconSpot spot = {0, 0, 0};
    GtkWidget *badge = szfriends_gtk_button_get_badge(anchor), *frame = gtk_window_get_child(GTK_WINDOW(window));
    szfg_layout(window, 48, -1);
    graphene_rect_t bounds, button;
    EXPECT(gtk_widget_compute_bounds(badge, frame, &bounds) &&
               gtk_widget_compute_bounds(szfriends_gtk_button_get_menu_button(anchor), frame, &button), "placed");
    gtk_widget_set_opacity(badge, 0);
    GdkTexture *texture = szfg_render(window, 48, -1, name);
    gtk_widget_set_opacity(badge, 1);
    SZFGPixels pixels = szfg_pixels(texture);
    guint8 background[4];
    memcpy(background, szfg_pixel(&pixels, 1, 1), 4);
    spot.under_badge = szfg_count_differing(&pixels, (int)(bounds.origin.x * 2), (int)(bounds.origin.y * 2),
                                            (int)(bounds.size.width * 2), (int)(bounds.size.height * 2), background,
                                            90);
    double count = 0;
    for (int y = (int)(button.origin.y * 2); y < (int)((button.origin.y + button.size.height) * 2); y++)
        for (int x = (int)(button.origin.x * 2); x < (int)((button.origin.x + button.size.width) * 2); x++) {
            const guint8 *p = szfg_pixel(&pixels, x, y);
            if (ABS(p[0] - background[0]) + ABS(p[1] - background[1]) + ABS(p[2] - background[2]) <= 90) continue;
            spot.x += x, spot.y += y, count++;
        }
    if (count) spot.x /= count, spot.y /= count;
    szfg_pixels_free(&pixels);
    g_object_unref(texture);
    return spot;
}

/* A window holding a fresh button. Probes never map a window, so GTK never revalidates styles after a change: every
 * visual state is built into a new button before its first layout instead of toggled on an old one. */
static GtkWidget *button_window(SZFriendsGtkLink *link, GtkWidget **anchor_out) {
    GtkWidget *window = gtk_window_new();
    GtkWidget *anchor = szfriends_gtk_button_new(link, GTK_WINDOW(window));
    GtkWidget *frame = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_margin_start(frame, 6), gtk_widget_set_margin_end(frame, 6);
    gtk_widget_set_margin_top(frame, 6), gtk_widget_set_margin_bottom(frame, 6);
    gtk_box_append(GTK_BOX(frame), anchor);
    gtk_window_set_child(GTK_WINDOW(window), frame);
    gtk_widget_realize(window);
    *anchor_out = anchor;
    return window;
}

static void test_badge(SZFGHarness *harness) {
    EXPECT(szfg_pump_until(badge_arrived, harness->link, 3000), "the badge snapshot arrives");
    GtkWidget *anchor = NULL, *window;
    for (int dark = 0; dark < 2; dark++) {
        szfg_set_dark(dark);
        window = button_window(harness->link, &anchor);
        GdkTexture *texture = szfg_render(window, 60, -1, dark ? "button-badge-dark" : "button-badge-light");
        g_object_unref(texture);
        gtk_window_destroy(GTK_WINDOW(window));
    }
    szfg_set_dark(FALSE);
    window = button_window(harness->link, &anchor);
    GtkWidget *badge = szfriends_gtk_button_get_badge(anchor), *menu = szfriends_gtk_button_get_menu_button(anchor);
    EXPECT(strcmp(gtk_widget_get_name(anchor), "szfriends.title-button") == 0, "the button carries the Friends mark");
    EXPECT(gtk_widget_get_visible(badge) && strcmp(gtk_label_get_text(GTK_LABEL(badge)), "2") == 0,
           "the badge shows the helper's count");
    EXPECT(!gtk_widget_get_can_target(badge), "the badge takes no clicks: the button keeps one hit area");
    EXPECT(g_strcmp0(gtk_widget_get_tooltip_text(menu), "Friends (Beta)") == 0, "the tooltip is the helper's words");
    /* The badge sits inside the button's own frame, and clear of the second person: covered, two read as one. */
    SZFGIconSpot shifted = icon_spot(window, anchor, "button-badge-clearance");
    graphene_rect_t badge_bounds, button_bounds;
    gboolean placed = gtk_widget_compute_bounds(badge, anchor, &badge_bounds) &&
                      gtk_widget_compute_bounds(menu, anchor, &button_bounds);
    EXPECT(placed && graphene_rect_contains_rect(&button_bounds, &badge_bounds), "the badge lies inside the button");
    gtk_window_destroy(GTK_WINDOW(window));
    GtkCssProvider *unshifted = gtk_css_provider_new();
    gtk_css_provider_load_from_string(unshifted, ".szfriends-badged image { -gtk-icon-transform: none; }");
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(unshifted),
                                               GTK_STYLE_PROVIDER_PRIORITY_USER);
    window = button_window(harness->link, &anchor);
    SZFGIconSpot centred = icon_spot(window, anchor, "button-badge-clearance-unshifted");
    gtk_window_destroy(GTK_WINDOW(window));
    gtk_style_context_remove_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(unshifted));
    g_object_unref(unshifted);
    EXPECT(shifted.under_badge <= 2, "no icon pixel under the badge (%d)", shifted.under_badge);
    /* 3 px left and 3 px down at scale 2, as the AppKit button nudges its icon (mac/SZFriendsTitleButton.m). */
    EXPECT(ABS(shifted.x - centred.x + 6) < 1.5 && ABS(shifted.y - centred.y - 6) < 1.5,
           "with a count the icon moves down and left (%.1f, %.1f)", shifted.x - centred.x, shifted.y - centred.y);
}

/* Pixels that differ between two renders of the same size. */
static int differing(GdkTexture *a, GdkTexture *b) {
    SZFGPixels p = szfg_pixels(a), q = szfg_pixels(b);
    int count = 0;
    for (int y = 0; y < MIN(p.height, q.height); y++)
        for (int x = 0; x < MIN(p.width, q.width); x++) {
            const guint8 *u = szfg_pixel(&p, x, y), *v = szfg_pixel(&q, x, y);
            if (ABS(u[0] - v[0]) + ABS(u[1] - v[1]) + ABS(u[2] - v[2]) > 30) count++;
        }
    szfg_pixels_free(&p), szfg_pixels_free(&q);
    return count;
}

static void test_drops(SZFGHarness *harness) {
    char *dir = szfg_temp_dir("button");
    char *file = g_build_filename(dir, "Site photos.pdf", NULL), *other = g_build_filename(dir, "Plan.pdf", NULL);
    char *folder = g_build_filename(dir, "Site visit", NULL), *link = g_build_filename(dir, "Link.pdf", NULL);
    g_file_set_contents(file, "%PDF-1.7\n", -1, NULL);
    g_file_set_contents(other, "%PDF-1.7\n", -1, NULL);
    g_mkdir(folder, 0700);
    EXPECT(symlink(file, link) == 0, "a link to a file");
    const char *one[] = {file, NULL}, *two[] = {file, other, NULL}, *dirs[] = {folder, NULL}, *links[] = {link, NULL};
    GValue *files = files_value(two), *folders = files_value(dirs), *single = files_value(one);
    GValue *linked = files_value(links);
    GtkWidget *anchor = NULL, *window = button_window(harness->link, &anchor);
    GdkTexture *plain = szfg_render(window, 48, -1, "button-drop-none");
    gtk_window_destroy(GTK_WINDOW(window));
    window = button_window(harness->link, &anchor);
    szfriends_gtk_button_drag_value(anchor, single);
    EXPECT(szfriends_gtk_button_is_highlighted(anchor), "files over the button highlight it");
    GdkTexture *lit = szfg_render(window, 48, -1, "button-drop-accept");
    int changed = differing(plain, lit);
    EXPECT(changed > 150, "the highlight is visible (%d pixels)", changed);
    g_object_unref(plain), g_object_unref(lit);
    SZFriendsGtkDropdown *dropdown = szfriends_gtk_dropdown_for_button(anchor);
    SZFGRecorder seen = {0};
    szfriends_gtk_dropdown_set_presenter(dropdown, &recorder, &seen);
    szfriends_gtk_button_drag_value(anchor, folders);
    EXPECT(!szfriends_gtk_button_is_highlighted(anchor), "a folder does not highlight it");
    szfriends_gtk_button_drag_leave(anchor);
    /* Spring-loading: resting 500 ms opens the list with the hint; leaving earlier opens nothing. */
    szfriends_gtk_button_drag_enter(anchor, NULL);
    szfg_pump_for(250);
    szfriends_gtk_button_drag_leave(anchor);
    szfg_pump_for(400);
    EXPECT(!szfriends_gtk_dropdown_is_open(dropdown) && seen.presents == 0, "a drag passing by opens nothing");
    szfriends_gtk_button_drag_value(anchor, single);
    szfriends_gtk_button_drag_enter(anchor, NULL);
    szfg_pump_for(250);
    EXPECT(!szfriends_gtk_dropdown_is_open(dropdown), "not before 500 ms");
    EXPECT(springs_open(dropdown) && seen.presents == 1, "resting on the button springs it open");
    EXPECT(g_strcmp0(szfriends_gtk_dropdown_get_drop_hint(dropdown),
                     szfriends_gtk_link_string(harness->link, "drop_hint")) == 0, "with the helper's drop hint");
    szfriends_gtk_dropdown_close(dropdown);
    szfriends_gtk_button_drag_leave(anchor);
    szfriends_gtk_button_drag_value(anchor, folders);
    szfriends_gtk_button_drag_enter(anchor, NULL);
    EXPECT(springs_open(dropdown) &&
               g_strcmp0(szfriends_gtk_dropdown_get_drop_hint(dropdown), "Folders can’t be sent yet") == 0,
           "a folder springs it open too, to say it is refused where the person looks");
    szfriends_gtk_dropdown_close(dropdown);
    EXPECT(szfriends_gtk_dropdown_get_drop_hint(dropdown) == NULL, "closing clears the hint");
    szfriends_gtk_button_drag_leave(anchor);
    /* A link (or a FIFO, a socket, a device) is refused as a folder is: no highlight, the helper's words for it,
     * never "Drop on a friend to send", which would promise what cannot happen (security review, wave 6b). */
    szfriends_gtk_button_drag_value(anchor, linked);
    EXPECT(!szfriends_gtk_button_is_highlighted(anchor), "a link does not highlight it");
    szfriends_gtk_button_drag_enter(anchor, NULL);
    const char *not_a_file = szfriends_gtk_link_string(harness->link, "drop_not_a_file");
    EXPECT(springs_open(dropdown) && *not_a_file &&
               g_strcmp0(szfriends_gtk_dropdown_get_drop_hint(dropdown), not_a_file) == 0,
           "a link springs it open with the helper's refusal: %s", szfriends_gtk_dropdown_get_drop_hint(dropdown));
    szfriends_gtk_dropdown_close(dropdown);
    szfriends_gtk_button_drag_leave(anchor);
    EXPECT(!szfriends_gtk_button_drop(anchor, linked), "a dropped link is refused");
    /* Released on the button: "Send 2 files to…", sent to the friend clicked next; Escape cancels, then closes. */
    EXPECT(!szfriends_gtk_button_drop(anchor, folders), "a dropped folder is refused");
    EXPECT(szfriends_gtk_button_drop(anchor, files), "dropped files are taken");
    EXPECT(szfriends_gtk_dropdown_is_open(dropdown) && szfriends_gtk_dropdown_get_send_items(dropdown) &&
               szfriends_gtk_dropdown_get_send_items(dropdown)->len == 2, "the send picker holds both files");
    EXPECT(g_strcmp0(szfriends_gtk_dropdown_get_send_title(dropdown), "Send Site photos.pdf and 1 more to…") == 0,
           "titled with the helper's words: %s", szfriends_gtk_dropdown_get_send_title(dropdown));
    szfriends_gtk_dropdown_escape(dropdown);
    EXPECT(szfriends_gtk_dropdown_get_send_items(dropdown) == NULL && szfriends_gtk_dropdown_is_open(dropdown),
           "Escape cancels the picker first");
    szfriends_gtk_dropdown_escape(dropdown);
    EXPECT(!szfriends_gtk_dropdown_is_open(dropdown), "then closes the dropdown");
    value_free(files), value_free(folders), value_free(single), value_free(linked);
    gtk_window_destroy(GTK_WINDOW(window));
    g_free(file), g_free(other), g_free(folder), g_free(link);
    szfg_remove_tree(dir);
    g_free(dir);
}

typedef struct {
    int installs, removes;
    GtkWidget *button;
} SZFGPlacement;

static void install(gpointer data, GtkWindow *window, GtkWidget *button) {
    SZFGPlacement *placement = data;
    (void)window;
    placement->installs++;
    placement->button = button;
}

static void uninstall(gpointer data, GtkWindow *window, GtkWidget *button) {
    SZFGPlacement *placement = data;
    (void)window;
    if (button == placement->button) placement->removes++;
}

static void test_placement(void) {
    SZFGPlacement placement = {0};
    char *state = szfg_temp_dir("placement");
    g_setenv(SZFRIENDS_ENV_STATE_DIR, state, TRUE); /* nothing listens there */
    SZFriendsGtkHost host = {.struct_size = sizeof host, .host_data = &placement, .app_id = "a", .app_name = "A",
                             .app_version = "1", .reveal_in_name = "A", .install_button = install,
                             .remove_button = uninstall};
    SZFriendsGtkLink *link = szfriends_gtk_link_new(&host);
    GtkWidget *window = gtk_window_new();
    gtk_widget_realize(window);
    szfriends_gtk_link_add_window(link, GTK_WINDOW(window));
    szfriends_gtk_link_add_window(link, GTK_WINDOW(window));
    EXPECT(placement.installs == 1 && placement.button && szfriends_gtk_dropdown_for_button(placement.button),
           "one button per window, handed to the host");
    szfriends_gtk_link_remove_window(link, GTK_WINDOW(window));
    EXPECT(placement.removes == 1, "removing the window's button tells the host");
    szfriends_gtk_link_add_window(link, GTK_WINDOW(window));
    szfriends_gtk_link_start(link); /* no helper here: it keeps trying until stopped */
    szfriends_gtk_link_stop(link, TRUE);
    EXPECT(placement.installs == 2 && placement.removes == 2, "turning Friends off removes every button");
    szfriends_gtk_link_add_window(link, GTK_WINDOW(window));
    gtk_window_destroy(GTK_WINDOW(window)); /* the window goes first: the link forgets it */
    szfg_pump_for(20);
    /* The host frees the link while a window still shows its button: the button keeps working, quietly. */
    window = gtk_window_new();
    gtk_widget_realize(window);
    GtkWidget *orphan = szfriends_gtk_button_new(link, GTK_WINDOW(window));
    gtk_window_set_child(GTK_WINDOW(window), orphan);
    szfriends_gtk_link_free(link);
    SZFriendsGtkDropdown *dropdown = szfriends_gtk_dropdown_for_button(orphan);
    SZFGRecorder seen = {0};
    szfriends_gtk_dropdown_set_presenter(dropdown, &recorder, &seen);
    szfriends_gtk_dropdown_open(dropdown);
    szfriends_gtk_dropdown_open_conversation(dropdown, "c_mei", NULL);
    szfg_pump_for(20);
    EXPECT(seen.presents == 1 && szfriends_gtk_dropdown_get_depth(dropdown) == 2, "a button outliving its link opens");
    gtk_window_destroy(GTK_WINDOW(window));
    szfg_pump_for(20);
    szfg_remove_tree(state);
    g_free(state);
}

void szfg_run_button_probes(void) {
    SZFGHarness *harness = szfg_probe_harness("button");
    test_badge(harness);
    test_drops(harness);
    szfg_harness_free(harness);
    test_placement();
}
