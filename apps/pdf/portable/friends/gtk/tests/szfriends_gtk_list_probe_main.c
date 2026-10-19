/* friends-gtk-list-check, widget probes: the list page, its rows and Nearby, built by the real Friends button and
 * dropdown against the fake helper, driven through their handlers, and rendered offscreen in light and dark. Needs a
 * logged-in session for GDK's display; never maps a window and never launches either app.
 *
 * Usage: SZFriendsGtkListProbes <fixtures dir> <animals manifest.json> <renders dir> */

#include "szfriends_gtk_list_probe.h"

#include <gtk/gtk.h>
#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <ApplicationServices/ApplicationServices.h>
int szfriends_gtk_quiet_transform_calls(void); /* tests/szfriends_gtk_quiet.c */
#endif

char *szfg_copied, *szfg_opened;

/* ---- The seams ----------------------------------------------------------------------------------- */

static void seam_copy(GtkWidget *widget, const char *text, gpointer data) {
    (void)widget, (void)data;
    g_free(szfg_copied);
    szfg_copied = g_strdup(text);
}

static void seam_open(GtkWidget *widget, const char *uri, gpointer data) {
    (void)widget, (void)data;
    g_free(szfg_opened);
    szfg_opened = g_strdup(uri);
}

/* ---- The list in a dropdown ---------------------------------------------------------------------- */

static void present(SZFriendsGtkDropdown *dropdown, gpointer data) {
    (void)dropdown, (void)data;
}

static void dismiss(SZFriendsGtkDropdown *dropdown, gpointer data) {
    (void)data;
    szfriends_gtk_dropdown_presenter_closed(dropdown);
}

static const SZFriendsGtkPresenter recorded = {present, dismiss};

SZFGList *szfg_list_open(SZFGHarness *harness) {
    SZFGList *list = g_new0(SZFGList, 1);
    list->harness = harness;
    list->window = gtk_window_new();
    list->anchor = szfriends_gtk_button_new(harness->link, GTK_WINDOW(list->window));
    gtk_window_set_child(GTK_WINDOW(list->window), list->anchor);
    list->dropdown = szfriends_gtk_dropdown_for_button(list->anchor);
    szfriends_gtk_dropdown_set_presenter(list->dropdown, &recorded, NULL);
    szfriends_gtk_dropdown_open(list->dropdown);
    list->page = szfriends_gtk_dropdown_get_top_page(list->dropdown);
    list->parts = szfriends_gtk_list_page_parts(list->page);
    EXPECT(list->parts != NULL, "the list page is the dropdown's root");
    return list;
}

void szfg_list_close(SZFGList *list) {
    if (!list) return;
    szfriends_gtk_dropdown_close(list->dropdown);
    gtk_window_destroy(GTK_WINDOW(list->window));
    szfg_pump_for(20);
    g_free(list);
}

typedef struct {
    SZFGList *list;
    guint rows;
} SZFGRowsWait;

static gboolean rows_in(gpointer data) {
    SZFGRowsWait *wait = data;
    return wait->list->parts && wait->list->parts->rows->len == wait->rows;
}

gboolean szfg_list_wait_rows(SZFGList *list, guint rows) {
    SZFGRowsWait wait = {list, rows};
    return szfg_pump_until(rows_in, &wait, 3000);
}

static gboolean snapshot_after(gpointer data) {
    SZFGRowsWait *wait = data;
    return wait->list->parts && wait->list->parts->list_snapshots > wait->rows;
}

gboolean szfg_list_wait_snapshot(SZFGList *list, guint seen) {
    SZFGRowsWait wait = {list, seen};
    return szfg_pump_until(snapshot_after, &wait, 3000);
}

GtkWidget *szfg_list_row(SZFGList *list, const char *conversation_id) {
    for (guint i = 0; list->parts && i < list->parts->rows->len; i++) {
        GtkWidget *row = g_ptr_array_index(list->parts->rows, i);
        if (!g_strcmp0(szfriends_gtk_row_get_conversation_id(row), conversation_id)) return row;
    }
    return NULL;
}

guint szfg_frames(SZFGHarness *harness, const char *type) {
    return szfg_fake_frames(harness, type, NULL, NULL);
}

char *szfg_last_field(SZFGHarness *harness, const char *type, const char *key) {
    JsonObject *frame = szfg_fake_last_frame(harness, type);
    if (!frame) return NULL;
    char *value = g_strdup(json_object_get_string_member_with_default(frame, key, NULL));
    json_object_unref(frame);
    return value;
}

typedef struct {
    SZFGHarness *harness;
    const char *type;
    guint count;
} SZFGFrameWait;

static gboolean frames_in(gpointer data) {
    SZFGFrameWait *wait = data;
    return szfg_frames(wait->harness, wait->type) >= wait->count;
}

gboolean szfg_wait_frames(SZFGHarness *harness, const char *type, guint count) {
    SZFGFrameWait wait = {harness, type, count};
    return szfg_pump_until(frames_in, &wait, 3000);
}

gboolean szfg_accessible_label_is(GtkWidget *widget, const char *label) {
    char *problem = gtk_test_accessible_check_property(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_PROPERTY_LABEL, label);
    gboolean same = problem == NULL;
    if (problem) fprintf(stderr, "  accessible label: %s\n", problem);
    g_free(problem);
    return same;
}

/* ---- Main ---------------------------------------------------------------------------------------- */

/* Before GDK opens the display: prove the interposer will stop it from making this process a foreground app. */
static gboolean quiet_before_display(void) {
#ifdef __APPLE__
    int before = szfriends_gtk_quiet_transform_calls();
    TransformProcessType(NULL, 0); /* the real one refuses NULL and changes nothing */
    if (szfriends_gtk_quiet_transform_calls() != before + 1) {
        fprintf(stderr, "SZFriendsGtkListProbes: the interposer is not active; not opening a display\n");
        return FALSE;
    }
#endif
    return TRUE;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s <fixtures> <manifest.json> <renders>\n", argv[0]);
        return 2;
    }
    char *fixtures = realpath(argv[1], NULL), *manifest = realpath(argv[2], NULL);
    if (!fixtures || !manifest || !quiet_before_display()) return 2;
    szfg_fixtures = fixtures;
    szfg_manifest = manifest;
    szfg_renders = argv[3];
    g_mkdir_with_parents(szfg_renders, 0755);
    szfg_watch_logs();
    /* Tests choose every Friends variable themselves; the animal set comes from the source tree. */
    g_setenv("SZFRIENDS_AVATARS_MANIFEST", manifest, TRUE);
    if (!gtk_init_check()) {
        fprintf(stderr, "SZFriendsGtkListProbes: no display; the widget probes need a logged-in session\n");
        return 1;
    }
    adw_init();
    szfg_set_dark(FALSE);
    szfg_clock_install();
    static const SZFriendsGtkSeams seams = {.copy_text = seam_copy, .open_uri = seam_open};
    szfriends_gtk_set_seams(&seams);
    SZFGHarness *harness = szfg_probe_harness("list");
    szfg_run_list_row_probes(harness);
    szfg_run_list_page_probes(harness);
    szfg_run_list_nearby_probes(harness);
    szfg_run_list_reorder_probes(harness);
    szfg_run_list_live_probes(harness);
    szfg_run_list_route_probes(harness);
    szfg_run_list_renders(harness);
    szfg_harness_free(harness);
    g_unsetenv(SZFRIENDS_ENV_STATE_DIR);
    szfriends_gtk_set_seams(NULL);
    szfg_clock_uninstall();
    EXPECT(szfg_unexpected_warnings() == 0, "no GLib, GTK or libadwaita warnings (%d)", szfg_unexpected_warnings());
    g_free(szfg_copied);
    g_free(szfg_opened);
    free(fixtures);
    free(manifest);
    if (szfg_failures) {
        fprintf(stderr, "SZFriendsGtkListProbes: %d failure(s)\n", szfg_failures);
        return 1;
    }
    printf("SZFriendsGtkListProbes passed\n");
    return 0;
}
