/* System notifications in the dropdown (PROTOCOL.md § Notifications), against a fake helper that announces
 * `notifications`: the hello's url_scheme and notifications.focus; set_focus sent only when what the active window's
 * dropdown shows changes (a conversation, then null for another page, a closed dropdown or an inactive window), and
 * again after a reconnect; nothing to a helper without `notifications`; the ask banner's Turn On and Not Now; and
 * szfriends_gtk_show_conversation, where a notification's click leads. Windows are never mapped: which one is active
 * is the probe's answer, notified as GTK notifies it. */

#include "szfriends_gtk_list_probe.h"

#include "gtk/szfriends_gtk_link_private.h"

static GtkWindow *active_window;

static gboolean probe_is_active(GtkWindow *window) {
    return window && window == active_window;
}

static void activate_window(GtkWidget *window) {
    GtkWindow *previous = active_window;
    active_window = window ? GTK_WINDOW(window) : NULL;
    if (previous && previous != active_window) g_object_notify(G_OBJECT(previous), "is-active");
    if (active_window) g_object_notify(G_OBJECT(active_window), "is-active");
}

/* The newest set_focus: TRUE when it names `conversation` (NULL: an explicit null). */
static gboolean last_focus_is(SZFGHarness *harness, const char *conversation) {
    JsonObject *frame = szfg_fake_last_frame(harness, "set_focus");
    if (!frame) return FALSE;
    JsonNode *node = json_object_get_member(frame, "conversation_id");
    gboolean same = conversation ? node && JSON_NODE_HOLDS_VALUE(node) &&
                                       !g_strcmp0(json_node_get_string(node), conversation)
                                 : node && JSON_NODE_HOLDS_NULL(node);
    json_object_unref(frame);
    return same;
}

static gboolean has_string(JsonArray *array, const char *value) {
    for (guint i = 0; array && i < json_array_get_length(array); i++)
        if (!g_strcmp0(json_array_get_string_element(array, i), value)) return TRUE;
    return FALSE;
}

static void test_hello(SZFGHarness *harness) {
    JsonObject *hello = szfg_fake_last_frame(harness, "hello");
    JsonObject *client = hello ? json_object_get_object_member(hello, "client") : NULL;
    EXPECT(client && !g_strcmp0(json_object_get_string_member_with_default(client, "url_scheme", NULL),
                                "shenzhenfiles"), "hello names the app's URL scheme, where a click opens it");
    JsonArray *capabilities = hello ? json_object_get_array_member(hello, "capabilities") : NULL;
    EXPECT(has_string(capabilities, "notifications.focus"), "the views claim notifications.focus");
#ifdef __APPLE__
    EXPECT(has_string(capabilities, "notifications.ask"), "on macOS they claim notifications.ask");
#else
    EXPECT(!has_string(capabilities, "notifications.ask"), "elsewhere no ask");
#endif
    if (hello) json_object_unref(hello);
}

/* Settles the main loop, then whether exactly `count` set_focus frames arrived. */
static gboolean focus_frames_are(SZFGHarness *harness, guint count) {
    szfg_wait_frames(harness, "set_focus", count);
    szfg_pump_for(50);
    return szfg_frames(harness, "set_focus") == count;
}

static void test_focus(SZFGHarness *harness) {
    SZFGList *list = szfg_list_open(harness);
    guint sent = szfg_frames(harness, "set_focus");
    activate_window(list->window);
    EXPECT(focus_frames_are(harness, sent), "the list is no conversation: nothing to say");
    szfriends_gtk_dropdown_open_conversation(list->dropdown, "c_mei", NULL);
    EXPECT(focus_frames_are(harness, sent + 1) && last_focus_is(harness, "c_mei"),
           "a conversation on screen in the active window is named");
    activate_window(list->window);
    szfriends_gtk_dropdown_open_conversation(list->dropdown, "c_mei", "i_1");
    EXPECT(focus_frames_are(harness, sent + 1), "only changes are sent");
    activate_window(NULL);
    EXPECT(focus_frames_are(harness, sent + 2) && last_focus_is(harness, NULL), "the window going inactive: null");
    activate_window(list->window);
    EXPECT(focus_frames_are(harness, sent + 3) && last_focus_is(harness, "c_mei"), "and back");
    szfriends_gtk_dropdown_go_back(list->dropdown);
    EXPECT(focus_frames_are(harness, sent + 4) && last_focus_is(harness, NULL), "another page: null");
    szfriends_gtk_dropdown_open_conversation(list->dropdown, "c_mei", NULL);
    EXPECT(focus_frames_are(harness, sent + 5) && last_focus_is(harness, "c_mei"), "the conversation again");
    szfriends_gtk_dropdown_close(list->dropdown);
    EXPECT(focus_frames_are(harness, sent + 6) && last_focus_is(harness, NULL), "the dropdown closing: null");
    szfriends_gtk_dropdown_open(list->dropdown);
    EXPECT(focus_frames_are(harness, sent + 7) && last_focus_is(harness, "c_mei"),
           "reopened on the same conversation: named again");
    EXPECT(!g_strcmp0(szfriends_gtk_focus_sent(harness->link), "c_mei"), "the link remembers what it said");

    /* The helper drops a connection's focus with it: after the reconnect the focus is said again. */
    guint from = harness->n_states;
    szfriends_fake_helper_drop_clients(harness->fake);
    EXPECT(szfg_harness_wait_state(harness, SZFRIENDS_GTK_LINK_WAITING, from, 3000) &&
               szfg_harness_wait_state(harness, SZFRIENDS_GTK_LINK_READY, from, 8000), "the link reconnects");
    EXPECT(focus_frames_are(harness, sent + 8) && last_focus_is(harness, "c_mei"), "focus named again after READY");

    activate_window(NULL);
    EXPECT(focus_frames_are(harness, sent + 9) && last_focus_is(harness, NULL), "inactive again: null");
    activate_window(list->window);
    EXPECT(focus_frames_are(harness, sent + 10), "active again");
    activate_window(NULL);
    szfg_list_close(list);
    szfg_pump_for(50);
    EXPECT(last_focus_is(harness, NULL), "the window gone: null");
}

/* A helper without `notifications` hears no set_focus at all. */
static void test_older_helper(SZFGHarness *older) {
    SZFGList *list = szfg_list_open(older);
    guint sent = szfg_frames(older, "set_focus");
    activate_window(list->window);
    szfriends_gtk_dropdown_open_conversation(list->dropdown, "c_mei", NULL);
    szfg_pump_for(100);
    EXPECT(szfg_frames(older, "set_focus") == sent, "no set_focus for a helper without notifications");
    activate_window(NULL);
    szfg_list_close(list);
}

static gboolean banner_says(gpointer data) {
    SZFGList *list = data;
    return gtk_widget_get_visible(list->parts->banner) &&
           !g_strcmp0(gtk_label_get_text(GTK_LABEL(list->parts->banner_text)),
                      "Get a notification when friends send you a message or a file.");
}

static void test_banner(SZFGHarness *harness) {
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "views-notifications-list.json");
    SZFGList *list = szfg_list_open(harness);
    EXPECT(szfg_pump_until(banner_says, list, 3000), "the ask shows its words");
    const SZFriendsGtkListParts *parts = list->parts;
    EXPECT(gtk_widget_get_visible(parts->banner_button) &&
               !g_strcmp0(gtk_button_get_label(GTK_BUTTON(parts->banner_button)), "Turn On") &&
               gtk_widget_has_css_class(parts->banner_button, "suggested-action"), "Turn On, drawn primary");
    EXPECT(gtk_widget_get_visible(parts->banner_dismiss) &&
               !g_strcmp0(gtk_button_get_label(GTK_BUTTON(parts->banner_dismiss)), "Not Now"), "and Not Now");
    guint allows = szfg_frames(harness, "allow_notifications"), dismissals = szfg_frames(harness, "dismiss_banner");
    g_signal_emit_by_name(parts->banner_button, "clicked");
    EXPECT(szfg_wait_frames(harness, "allow_notifications", allows + 1), "Turn On sends allow_notifications");
    EXPECT(szfg_frames(harness, "dismiss_banner") == dismissals, "and dismisses nothing");
    g_signal_emit_by_name(parts->banner_dismiss, "clicked");
    EXPECT(szfg_wait_frames(harness, "dismiss_banner", dismissals + 1), "Not Now dismisses the ask");
    char *kind = szfg_last_field(harness, "dismiss_banner", "kind");
    EXPECT(!g_strcmp0(kind, "notifications"), "by its kind (%s)", kind);
    g_free(kind);
    EXPECT(szfg_frames(harness, "allow_notifications") == allows + 1, "without asking the system");

    /* Other banners keep their one button. */
    guint seen = parts->list_snapshots;
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list-id-changed.json");
    EXPECT(szfg_list_wait_snapshot(list, seen) && gtk_widget_get_visible(parts->banner_button) &&
               !gtk_widget_get_visible(parts->banner_dismiss), "an ID change's banner has no second button");
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list.json");
    szfg_list_close(list);
}

static void present(SZFriendsGtkDropdown *dropdown, gpointer data) {
    (void)dropdown, (void)data;
}

static void dismiss(SZFriendsGtkDropdown *dropdown, gpointer data) {
    (void)data;
    szfriends_gtk_dropdown_presenter_closed(dropdown);
}

/* Where a click on a notification leads: the window's dropdown, open on that conversation, or on the list. */
static void test_show_conversation(SZFGHarness *harness) {
    static const SZFriendsGtkPresenter recorded = {present, dismiss};
    GtkWidget *window = gtk_window_new();
    szfriends_gtk_link_add_window(harness->link, GTK_WINDOW(window));
    SZFriendsGtkDropdown *dropdown =
        szfriends_gtk_dropdown_for_button(szfriends_gtk_link_window_button(harness->link, GTK_WINDOW(window)));
    EXPECT(dropdown != NULL, "the window has its button");
    if (!dropdown) {
        gtk_window_destroy(GTK_WINDOW(window));
        return;
    }
    szfriends_gtk_dropdown_set_presenter(dropdown, &recorded, NULL);
    szfriends_gtk_show_conversation(harness->link, NULL, "c_mei");
    SZFriendsGtkPage *top = szfriends_gtk_dropdown_get_top_page(dropdown);
    EXPECT(szfriends_gtk_dropdown_is_open(dropdown) && top &&
               szfriends_gtk_page_get_kind(top) == SZFRIENDS_GTK_PAGE_CONVERSATION &&
               !g_strcmp0(szfriends_gtk_page_get_argument(top), "c_mei"), "opens on the conversation");
    szfriends_gtk_show_conversation(harness->link, GTK_WINDOW(window), "c_daniel");
    top = szfriends_gtk_dropdown_get_top_page(dropdown);
    EXPECT(top && !g_strcmp0(szfriends_gtk_page_get_argument(top), "c_daniel") &&
               szfriends_gtk_dropdown_get_depth(dropdown) == 2, "another conversation replaces it, the list below");
    szfriends_gtk_show_conversation(harness->link, GTK_WINDOW(window), NULL);
    top = szfriends_gtk_dropdown_get_top_page(dropdown);
    EXPECT(szfriends_gtk_dropdown_is_open(dropdown) && top &&
               szfriends_gtk_page_get_kind(top) == SZFRIENDS_GTK_PAGE_LIST, "no conversation: the list");
    szfriends_gtk_dropdown_close(dropdown);
    EXPECT(!szfriends_gtk_dropdown_is_open(dropdown), "closed again");
    szfriends_gtk_show_conversation(harness->link, GTK_WINDOW(window), "c_mei");
    EXPECT(szfriends_gtk_dropdown_is_open(dropdown), "and opens from closed");
    szfriends_gtk_dropdown_close(dropdown);
    szfriends_gtk_link_remove_window(harness->link, GTK_WINDOW(window));
    gtk_window_destroy(GTK_WINDOW(window));
    szfg_pump_for(20);
}

void szfg_run_list_notification_probes(SZFGHarness *older) {
    szfriends_gtk_focus_set_active_func(probe_is_active);
    test_older_helper(older);
    char *previous = g_strdup(g_getenv(SZFRIENDS_ENV_STATE_DIR));
    SZFGHarness *harness = szfg_harness_new_custom("notify", "shenzhenfiles", SZFG_NOTIFYING_CAPABILITIES);
    if (szfg_harness_ready(harness, 5000)) {
        test_hello(harness);
        test_focus(harness);
        test_banner(harness);
        test_show_conversation(harness);
    }
    szfg_harness_free(harness);
    g_setenv(SZFRIENDS_ENV_STATE_DIR, previous, TRUE); /* the suite's own harness goes on */
    g_free(previous);
    szfriends_gtk_focus_set_active_func(NULL);
    active_window = NULL;
}
