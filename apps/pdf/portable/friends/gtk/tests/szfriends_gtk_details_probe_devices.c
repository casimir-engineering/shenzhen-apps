/* One profile on several computers offscreen, against the fake helper (PROTOCOL.md § Devices, § Joining): Your
 * computers renames this computer within its byte limit and removes another only after the helper's confirmation;
 * the list shows join requests with Approve, an armed Deny and the code to type, and a removed computer's notice with
 * no Add by ID and no Nearby; the name prompt's "Use my existing profile…" opens the join page, which sends what was
 * typed and shows why a code failed. Renders light and dark at the dropdown's 400 points and at the 320 and 600 a
 * host may give it, and checks no key line of these views is cut or reaches past the edge, and that they follow the
 * width (the join page's column stops growing past 400). */

#include "szfriends_gtk_details_probe.h"
#include "gtk/szfriends_gtk_devices.h"
#include "gtk/szfriends_gtk_list_page.h"

#include <string.h>

/* Whether `widget`'s accessible label is `label` (GTK's test accessor). */
static gboolean label_is(GtkWidget *widget, const char *label) {
    char *problem = gtk_test_accessible_check_property(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_PROPERTY_LABEL, label);
    if (problem) fprintf(stderr, "  accessible label: %s\n", problem);
    g_free(problem);
    return problem == NULL;
}

static SZFriendsGtkPageKind top_kind(SZFGRig *rig) {
    SZFriendsGtkPage *page = szfriends_gtk_dropdown_get_top_page(rig->dropdown);
    return page ? szfriends_gtk_page_get_kind(page) : SZFRIENDS_GTK_PAGE_KIND_COUNT;
}

static gboolean join_on_top(gpointer data) {
    return top_kind(data) == SZFRIENDS_GTK_PAGE_JOIN;
}

static void reply_error(SZFGHarness *harness, const char *intent, const char *code, const char *message) {
    char *reply = code ? g_strdup_printf("{\"type\":\"reply\",\"re\":\"0\",\"ok\":false,\"error\":{\"code\":\"%s\","
                                         "\"message\":\"%s\",\"retryable\":false,\"details\":{}}}", code, message)
                       : NULL;
    szfriends_fake_helper_set_reply(harness->fake, intent, reply);
    g_free(reply);
}

static GtkWidget *confirm_button(SZFGRig *rig) {
    GtkWidget *card = szfriends_gtk_dropdown_get_overlay(rig->dropdown);
    return card ? szfg_find_named(card, "szfriends.confirmation.confirm") : NULL;
}

/* A second, separate click: past the double-click time on the probes' clock. */
static void press_again(GtkWidget *button) {
    szfg_clock_advance_ms(szfriends_gtk_double_click_us(button) / 1000 + 1);
    szfg_press(button, 1);
}

static void test_your_computers(SZFGHarness *harness) {
    szfriends_fake_helper_set_view_fixture(harness->fake, "profile", "devices-profile.json");
    SZFGRig *rig = szfg_rig_new(harness);
    szfriends_gtk_dropdown_open_profile(rig->dropdown);
    GtkWidget *page = szfg_rig_page(rig);
    EXPECT(szfg_wait_label(page, "Your computers"), "Your computers is drawn");
    EXPECT(szfg_find_label(page, "Raph’s MacBook Pro") && szfg_find_label(page, "macOS 26.1 · This computer") &&
               szfg_find_label(page, "Linux · Yesterday") &&
               szfg_find_label(page, "macOS 26.1 · Not connected to this computer yet"),
           "each computer with its system and last connection");
    EXPECT(szfg_find_label(page, "Add a computer or phone\n1. On the other computer or phone, open Friends and choose "
                                 "Use my existing profile.\n2. Type this ID there: cottage‑violet\n3. Choose Approve "
                                 "when the request appears in Friends here, then type the code this computer shows on "
                                 "the other one.") != NULL,
           "and how to add one, with the ID");
    GtkWidget *remove = szfg_find_named(page, "szfriends.profile.devices.remove");
    EXPECT(remove && label_is(remove, "Remove…, Raph’s Mac mini"), "Remove names its computer");
    if (remove) szfg_press(remove, 1);
    GtkWidget *card = szfriends_gtk_dropdown_get_overlay(rig->dropdown);
    EXPECT(card && szfg_find_label(card, "Remove Raph’s Mac mini?") &&
               szfg_fake_frames(harness, "revoke_device", NULL, NULL) == 0,
           "Remove asks first, with the helper's words, and sends nothing yet");
    GtkWidget *ok = confirm_button(rig);
    if (ok) g_signal_emit_by_name(ok, "clicked");
    EXPECT(szfg_wait_frames(harness, "revoke_device", "device_id", "d_5b07e2c9", 1), "then removes that computer");

    const SZFriendsGtkProfileDevicesParts *parts =
        szfriends_gtk_profile_devices_parts(szfg_find_named(page, "szfriends.profile.devices"));
    EXPECT(parts && gtk_widget_get_visible(parts->rename_button) && !gtk_widget_get_visible(parts->rename_box),
           "Rename on this computer's row");
    if (!parts) {
        szfg_rig_free(rig);
        return;
    }
    g_signal_emit_by_name(parts->rename_button, "clicked");
    EXPECT(gtk_widget_get_visible(parts->rename_box) &&
               !g_strcmp0(gtk_editable_get_text(GTK_EDITABLE(parts->rename_entry)), "Raph’s MacBook Pro"),
           "the field opens on the name");
    GString *long_name = g_string_new(NULL);
    for (int i = 0; i < 70; i++) g_string_append(long_name, "é");
    gtk_editable_set_text(GTK_EDITABLE(parts->rename_entry), long_name->str);
    g_string_free(long_name, TRUE);
    EXPECT(strlen(gtk_editable_get_text(GTK_EDITABLE(parts->rename_entry))) == 64, "at most 64 bytes are typed");
    reply_error(harness, "rename_device", "name_invalid", "Type a name for this computer.");
    gtk_editable_set_text(GTK_EDITABLE(parts->rename_entry), "Studio MacBook");
    g_signal_emit_by_name(parts->rename_entry, "activate");
    EXPECT(szfg_wait_frames(harness, "rename_device", "name", "Studio MacBook", 1), "Return renames it");
    EXPECT(szfg_wait_label(page, "Type a name for this computer.") && gtk_widget_get_visible(parts->rename_box),
           "a refused name says why and stays open");
    reply_error(harness, "rename_device", NULL, NULL);
    szfriends_gtk_dropdown_escape(rig->dropdown);
    EXPECT(!gtk_widget_get_visible(parts->rename_box) && szfriends_gtk_dropdown_is_open(rig->dropdown),
           "Escape closes the field first");
    szfg_rig_free(rig);
}

static const SZFriendsGtkListParts *list_parts(SZFGRig *rig) {
    return szfriends_gtk_list_page_parts(szfriends_gtk_dropdown_get_top_page(rig->dropdown));
}

typedef struct {
    SZFGRig *rig;
    guint seen;
} SZFGSeen;

static gboolean list_snapshot_after(gpointer data) {
    SZFGSeen *wait = data;
    const SZFriendsGtkListParts *parts =
        szfriends_gtk_list_page_parts(szfriends_gtk_dropdown_get_top_page(wait->rig->dropdown));
    return parts && parts->list_snapshots > wait->seen;
}

static gboolean you_first(gpointer data) {
    const SZFriendsGtkListParts *parts = data;
    return parts && parts->rows->len &&
           !g_strcmp0(szfriends_gtk_row_get_conversation_id(g_ptr_array_index(parts->rows, 0)), "you");
}

static void test_join_rows(SZFGHarness *harness) {
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list-join-requests.json");
    SZFGRig *rig = szfg_rig_new(harness);
    GtkWidget *page = szfg_rig_page(rig);
    EXPECT(szfg_wait_label(page, "Type this code on Raph’s Mac mini"), "the join requests are drawn");
    GtkWidget *code = szfg_find_label(page, "4831 2207");
    EXPECT(code && gtk_label_get_selectable(GTK_LABEL(code)) && gtk_widget_has_css_class(code, "szfriends-join-code") &&
               label_is(code, "4 8 3 1, 2 2 0 7"),
           "the code large, selectable and read digit by digit");
    GtkWidget *approve = szfg_find_button(page, "Approve"), *deny = szfg_find_button(page, "Deny");
    if (approve) szfg_press(approve, 1);
    EXPECT(szfg_wait_frames(harness, "approve_join", "join_id", "5f2d0c4be1a94a7b8d3e6f1a2b3c4d5e", 1), "Approve");
    EXPECT(approve && !gtk_widget_get_sensitive(approve), "Approve, once pressed, waits for the code");
    if (deny) szfg_press(deny, 1);
    EXPECT(deny && szfriends_gtk_details_button_is_armed(deny) &&
               szfg_fake_frames(harness, "deny_join", NULL, NULL) == 0, "Deny asks for a second click");
    szfriends_gtk_dropdown_escape(rig->dropdown);
    EXPECT(deny && !szfriends_gtk_details_button_is_armed(deny) && szfriends_gtk_dropdown_is_open(rig->dropdown),
           "Escape turns Deny? back first");
    if (deny) {
        szfg_press(deny, 1);
        press_again(deny);
    }
    EXPECT(szfg_wait_frames(harness, "deny_join", "join_id", "5f2d0c4be1a94a7b8d3e6f1a2b3c4d5e", 1),
           "a second, separate click denies");
    const SZFriendsGtkListParts *rows = list_parts(rig);
    GtkWidget *cancel = rows ? szfg_find_button(rows->join_requests, "Cancel") : NULL;
    if (cancel) szfg_press(cancel, 1);
    EXPECT(szfg_wait_frames(harness, "deny_join", "join_id", "0a1b2c3d4e5f60718293a4b5c6d7e8f9", 1),
           "Cancel withdraws the code");
    /* The same words for another request (the computer asked again): the buttons are that request's, never the
     * previous one's, so Approve sends the new join_id. */
    JsonObject *again = szfg_fixture_data("snapshots/list-join-requests.json");
    JsonObject *waiting = json_array_get_object_element(json_object_get_array_member(again, "join_requests"), 1);
    const char *renewed = "6a7b8c9d0e1f20314253647586970a1b";
    json_object_set_string_member(waiting, "join_id", renewed);
    JsonArray *actions = json_object_get_array_member(waiting, "actions");
    for (guint i = 0; i < json_array_get_length(actions); i++)
        json_object_set_string_member(json_array_get_object_element(actions, i), "join_id", renewed);
    guint seen = list_parts(rig)->list_snapshots;
    szfg_script_view(harness, "list", again);
    json_object_unref(again);
    EXPECT(szfg_pump_until(list_snapshot_after, &(SZFGSeen){rig, seen}, 3000), "the renewed request arrives");
    approve = szfg_find_button(list_parts(rig)->join_requests, "Approve");
    if (approve) szfg_press(approve, 1);
    EXPECT(szfg_wait_frames(harness, "approve_join", "join_id", renewed, 1), "Approve answers the renewed request");

    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "devices-list-removed.json");
    EXPECT(szfg_wait_label(page, "This computer was removed from your profile"), "the removed notice");
    const SZFriendsGtkListParts *parts = list_parts(rig);
    EXPECT(parts && !gtk_widget_get_visible(parts->tabs) &&
               !gtk_widget_get_visible(szfriends_gtk_footer_parts(parts->footer)->add_button) &&
               !gtk_widget_get_visible(parts->join_requests) && parts->rows->len == 1,
           "no Nearby, no Add by ID, no join rows; the chats stay");
    GtkWidget *start = szfg_find_button(page, "Start Over…");
    if (start) szfg_press(start, 1);
    GtkWidget *card = szfriends_gtk_dropdown_get_overlay(rig->dropdown);
    EXPECT(card && szfg_find_label(card, "Start over on this computer?"), "Start Over asks first");
    GtkWidget *ok = confirm_button(rig);
    if (ok) g_signal_emit_by_name(ok, "clicked");
    EXPECT(szfg_wait_frames(harness, "reset_friends", "confirm", "reset", 1), "then starts over");

    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "devices-list.json");
    EXPECT(szfg_pump_until(you_first, (gpointer)parts, 3000), "You among the rows");
    EXPECT(parts && gtk_widget_get_visible(parts->tabs) && parts->rows->len &&
               !g_strcmp0(szfriends_gtk_row_get_conversation_id(g_ptr_array_index(parts->rows, 0)), "you") &&
               !g_strcmp0(szfriends_gtk_row_get_drop_label(g_ptr_array_index(parts->rows, 0)),
                          "Send to all your computers"),
           "You first, taking files for every computer; the tabs are back");
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list.json");
    szfg_rig_free(rig);
}

static void test_join_page(SZFGHarness *harness) {
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "devices-list-new-computer.json");
    szfriends_fake_helper_set_view_fixture(harness->fake, "join", "join-idle.json");
    SZFGRig *rig = szfg_rig_new(harness);
    GtkWidget *page = szfg_rig_page(rig);
    GtkWidget *join = szfg_find_named(page, "szfriends.list.join");
    EXPECT(szfg_wait_label(page, "Choose the name friends see") && join && gtk_widget_get_visible(join) &&
               !g_strcmp0(gtk_button_get_label(GTK_BUTTON(join)), "Use my existing profile…"),
           "the name prompt offers joining");
    guint subscribed = szfg_fake_frames(harness, "subscribe", "view", "join");
    if (join) g_signal_emit_by_name(join, "clicked");
    EXPECT(top_kind(rig) == SZFRIENDS_GTK_PAGE_JOIN, "it opens the join page");
    EXPECT(szfg_wait_frames(harness, "subscribe", "view", "join", subscribed + 1), "which subscribes to join");
    page = szfg_rig_page(rig);
    SZFriendsGtkPage *join_page = szfriends_gtk_dropdown_get_top_page(rig->dropdown);
    const SZFriendsGtkJoinParts *parts = szfriends_gtk_join_page_parts(join_page);
    EXPECT(szfg_wait_label(page, "Use your existing profile") && parts && gtk_widget_get_visible(parts->id_entry) &&
               !gtk_widget_get_visible(parts->code_entry), "idle: the ID field");
    if (!parts) {
        szfg_rig_free(rig);
        return;
    }
    reply_error(harness, "join_profile", "id_is_yours", "That’s this computer’s own ID.");
    gtk_editable_set_text(GTK_EDITABLE(parts->id_entry), " cottage-violet ");
    g_signal_emit_by_name(parts->id_entry, "activate");
    EXPECT(szfg_wait_frames(harness, "join_profile", "friends_id", "cottage-violet", 1), "join_profile, trimmed");
    EXPECT(szfg_wait_label(page, "That’s this computer’s own ID."), "a refused ID says why");
    reply_error(harness, "join_profile", NULL, NULL);
    szfriends_fake_helper_set_view_fixture(harness->fake, "join", "join-wrong-code.json");
    EXPECT(szfg_wait_label(page, "That code didn’t match. Check the code on your other computer or phone and type "
                                 "it again.") &&
               gtk_widget_get_visible(parts->code_entry) && !gtk_widget_get_visible(parts->id_entry) &&
               gtk_widget_get_sensitive(parts->code_button), "the code field, and why the last code failed");
    gtk_editable_set_text(GTK_EDITABLE(parts->code_entry), "4831 2207");
    szfriends_gtk_join_page_submit_code(join_page);
    EXPECT(szfg_wait_frames(harness, "enter_join_code", "code", "4831 2207", 1), "the code as typed");
    GtkWidget *cancel = szfg_find_button(page, "Cancel");
    if (cancel) g_signal_emit_by_name(cancel, "clicked");
    EXPECT(szfg_wait_frames(harness, "cancel_join", NULL, NULL, 1), "Cancel stops asking");
    szfriends_fake_helper_set_view_fixture(harness->fake, "join", "join-denied.json");
    EXPECT(szfg_wait_label(page, "This computer wasn’t approved"), "denied");
    guint asked = szfg_fake_frames(harness, "join_profile", "friends_id", "cottage-violet");
    GtkWidget *again = szfg_find_button(page, "Start again");
    if (again) g_signal_emit_by_name(again, "clicked");
    EXPECT(szfg_wait_frames(harness, "join_profile", "friends_id", "cottage-violet", asked + 1),
           "Start again asks the same ID");
    szfriends_fake_helper_set_view_fixture(harness->fake, "join", "join-joined.json");
    EXPECT(szfg_wait_label(page, "This computer now uses your profile") && !gtk_widget_get_visible(parts->code_entry) &&
               !gtk_widget_get_visible(parts->id_entry) && !gtk_widget_get_visible(parts->actions),
           "joined: just what happened");
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list.json");
    szfg_rig_free(rig);
}

/* Deleting history reaches every computer, and the words say so: the helper's note and confirmation, drawn as sent. */
/* A computer with friends of its own: "Use my existing profile…" asks first, sends Reset Friends alone, and the join
 * page opens once the reset replied, as the Mac and React views do. */
static void test_join_after_reset(SZFGHarness *harness) {
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "devices-list-join-reset.json");
    szfriends_fake_helper_set_view_fixture(harness->fake, "join", "join-idle.json");
    SZFGRig *rig = szfg_rig_new(harness);
    GtkWidget *page = szfg_rig_page(rig);
    GtkWidget *join = szfg_find_named(page, "szfriends.list.join");
    EXPECT(szfg_wait_label(page, "Choose the name friends see") && join && gtk_widget_get_visible(join),
           "the name prompt offers it");
    guint resets = szfg_fake_frames(harness, "reset_friends", NULL, NULL);
    if (join) g_signal_emit_by_name(join, "clicked");
    GtkWidget *card = szfriends_gtk_dropdown_get_overlay(rig->dropdown);
    EXPECT(card != NULL, "it asks first");
    EXPECT(card && szfg_find_label(card, "Use your existing profile here?"), "saying what goes");
    EXPECT(szfg_fake_frames(harness, "reset_friends", NULL, NULL) == resets, "and sends nothing yet");
    EXPECT(top_kind(rig) != SZFRIENDS_GTK_PAGE_JOIN, "nor opens the join page yet");
    GtkWidget *ok = confirm_button(rig);
    if (ok) g_signal_emit_by_name(ok, "clicked");
    EXPECT(szfg_wait_frames(harness, "reset_friends", "confirm", "reset", resets + 1), "then Reset Friends");
    EXPECT(szfg_pump_until(join_on_top, rig, 3000), "and the join page once it replied");
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list.json");
    szfg_rig_free(rig);
}

static void test_history_everywhere(SZFGHarness *harness) {
    szfriends_fake_helper_set_view_fixture(harness->fake, "details", "devices-details-mei.json");
    SZFGRig *rig = szfg_rig_new(harness);
    szfriends_gtk_dropdown_open_details(rig->dropdown, "c_mei");
    GtkWidget *page = szfg_rig_page(rig);
    EXPECT(szfg_wait_label(page, "Clears this chat on all your computers. Mei stays your friend."),
           "the note says every computer");
    GtkWidget *delete = szfg_find_button(page, "Delete chat history…");
    if (delete) szfg_press(delete, 1);
    GtkWidget *card = szfriends_gtk_dropdown_get_overlay(rig->dropdown);
    EXPECT(card && szfg_find_label(card, "Your messages and file history with Mei are deleted from this computer, and "
                                         "from your other computers as soon as they connect. Anything still waiting to "
                                         "go to Mei won’t be sent. Mei stays your friend and keeps their own copy of "
                                         "the chat. Files you received stay where they were saved."),
           "the confirmation says every computer");
    GtkWidget *ok = confirm_button(rig);
    if (ok) g_signal_emit_by_name(ok, "clicked");
    EXPECT(szfg_wait_frames(harness, "delete_history", "conversation_id", "c_mei", 1), "then deletes");
    szfriends_fake_helper_set_view_fixture(harness->fake, "details", "details-mei.json");
    szfg_rig_free(rig);
}

/* No key line is cut at any width: every visible label under `root` wraps or fits, none ends in an ellipsis. */
static void expect_whole(GtkWidget *root, const char *name) {
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        if (!gtk_widget_get_visible(child)) continue;
        if (GTK_IS_LABEL(child) && *gtk_label_get_text(GTK_LABEL(child)) &&
            gtk_widget_get_ancestor(child, GTK_TYPE_BUTTON) == NULL)
            EXPECT(!pango_layout_is_ellipsized(gtk_label_get_layout(GTK_LABEL(child))), "%s: \"%s\" is cut", name,
                   gtk_label_get_text(GTK_LABEL(child)));
        expect_whole(child, name);
    }
}

/* Nothing under `root` reaches past the dropdown's edges: every visible widget lies within `width` (but the header
 * bar, which libadwaita draws a point past each edge on purpose). */
static void expect_inside(GtkWidget *root, GtkWidget *content, int width, const char *name) {
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        if (!gtk_widget_get_visible(child) || !gtk_widget_get_child_visible(child) || ADW_IS_HEADER_BAR(child))
            continue;
        graphene_rect_t bounds;
        if (gtk_widget_compute_bounds(child, content, &bounds) && bounds.size.width > 0)
            EXPECT(bounds.origin.x >= -0.5f && bounds.origin.x + bounds.size.width <= (float)width + 0.5f,
                   "%s: %s spans %.0f to %.0f of %d", name, G_OBJECT_TYPE_NAME(child), bounds.origin.x,
                   bounds.origin.x + bounds.size.width, width);
        expect_inside(child, content, width, name);
    }
}

/* Drawn at `width`, as a host that gives the dropdown that width: whole, inside it, and returns how wide `own` is;
 * where `measure` (if any) was drawn goes to `measured`. */
static int render_rig_measuring(SZFGRig *rig, GtkWidget *own, int width, const char *name, GtkWidget *measure,
                                graphene_rect_t *measured) {
    GtkWidget *content = szfriends_gtk_dropdown_get_content(rig->dropdown);
    gtk_widget_set_size_request(content, width, -1);
    GtkWidget *window = szfg_probe_window(content);
    GdkTexture *texture = szfg_render(window, width, 640, name);
    SZFGPixels pixels = szfg_pixels(texture);
    const guint8 *corner = szfg_pixel(&pixels, pixels.width - 4, pixels.height - 4);
    EXPECT(szfg_count_differing(&pixels, 0, 0, pixels.width, pixels.height, corner, 40) > 2000, "%s is drawn", name);
    expect_whole(own, name);
    expect_inside(own, content, width, name);
    GtkWidget *card = szfriends_gtk_dropdown_get_overlay(rig->dropdown);
    if (card) expect_inside(card, content, width, name);
    int drawn = gtk_widget_get_width(own);
    if (measure && !gtk_widget_compute_bounds(measure, content, measured)) *measured = GRAPHENE_RECT_INIT(0, 0, 0, 0);
    szfg_pixels_free(&pixels);
    g_object_unref(texture);
    g_object_ref(content);
    gtk_window_set_child(GTK_WINDOW(window), NULL);
    gtk_window_destroy(GTK_WINDOW(window));
    g_object_unref(content);
    return drawn;
}

static int render_rig(SZFGRig *rig, GtkWidget *own, int width, const char *name) {
    return render_rig_measuring(rig, own, width, name, NULL, NULL);
}

/* Your computers with the rename field open, then with Remove's question over it, at the narrowest and a wide width. */
static void render_profile_states(SZFGRig *rig, GtkWidget *own, int dark) {
    const SZFriendsGtkProfileDevicesParts *parts = szfriends_gtk_profile_devices_parts(own);
    GtkWidget *remove = szfg_find_named(own, "szfriends.profile.devices.remove");
    if (!parts || !remove) return;
    g_signal_emit_by_name(parts->rename_button, "clicked");
    for (int w = 320; w <= 600; w += 280) {
        char *name = g_strdup_printf("devices-profile-rename-%d-%s", w, dark ? "dark" : "light");
        render_rig(rig, own, w, name);
        g_free(name);
    }
    szfriends_gtk_dropdown_escape(rig->dropdown);
    szfg_press(remove, 1);
    EXPECT(szfriends_gtk_dropdown_get_overlay(rig->dropdown) != NULL, "Remove asks");
    for (int w = 320; w <= 600; w += 280) {
        char *name = g_strdup_printf("devices-profile-remove-%d-%s", w, dark ? "dark" : "light");
        render_rig(rig, own, w, name);
        g_free(name);
    }
    szfriends_gtk_dropdown_escape(rig->dropdown);
}

static void test_renders(SZFGHarness *harness) {
    static const char *const views[][4] = {
        {"profile", "devices-profile.json", "Your computers", "devices-profile"},
        {"list", "list-join-requests.json", "Type this code on Raph’s Mac mini", "devices-join-rows"},
        {"list", "devices-list-removed.json", "This computer was removed from your profile", "devices-removed"},
        {"join", "join-wrong-code.json", "Approve this computer", "devices-join-code"},
    };
    for (int dark = 0; dark < 2; dark++) {
        szfg_set_dark(dark);
        szfg_pump_for(50);
        for (gsize i = 0; i < G_N_ELEMENTS(views); i++) {
            szfriends_fake_helper_set_view_fixture(harness->fake, views[i][0], views[i][1]);
            SZFGRig *rig = szfg_rig_new(harness);
            if (!strcmp(views[i][0], "profile")) szfriends_gtk_dropdown_open_profile(rig->dropdown);
            if (!strcmp(views[i][0], "join")) szfriends_gtk_dropdown_open_join(rig->dropdown);
            EXPECT(szfg_wait_label(szfg_rig_page(rig), views[i][2]), "%s to render", views[i][3]);
            /* What this change draws: the profile's computers, the list's notice and rows, the join page. */
            GtkWidget *page = szfg_rig_page(rig);
            GtkWidget *own = szfg_find_named(page, "szfriends.profile.devices");
            if (!own) own = szfg_find_named(page, "szfriends.list.devices");
            if (!own) own = page;
            /* The dropdown's own width, and the narrowest and a wider one a host may give it. */
            int drawn[3] = {0}, widths[3] = {400, 320, 600};
            const SZFriendsGtkJoinParts *join = szfriends_gtk_join_page_parts(szfriends_gtk_dropdown_get_top_page(
                rig->dropdown));
            graphene_rect_t code[3];
            for (int w = 0; w < 3; w++) {
                char *name = w ? g_strdup_printf("%s-%d-%s", views[i][3], widths[w], dark ? "dark" : "light")
                               : g_strdup_printf("%s-%s", views[i][3], dark ? "dark" : "light");
                drawn[w] = render_rig_measuring(rig, own, widths[w], name, join ? join->code_entry : NULL, &code[w]);
                g_free(name);
            }
            /* The join page's column fills a narrow dropdown and stays centred, no wider, in a wide one. */
            if (join)
                EXPECT(code[1].size.width > 200 && code[2].size.width <= SZFRIENDS_GTK_JOIN_COLUMN &&
                           code[2].size.width >= code[0].size.width - 1 &&
                           G_APPROX_VALUE(code[2].origin.x + code[2].size.width / 2, 300.0f, 1.0f),
                       "the code field: %.0f at 320, %.0f at 400, %.0f at 600 from %.0f", code[1].size.width,
                       code[0].size.width, code[2].size.width, code[2].origin.x);
            EXPECT(drawn[1] < drawn[0] && drawn[2] > drawn[0] + 150, "%s follows the width: %d, %d, %d", views[i][3],
                   drawn[1], drawn[0], drawn[2]);
            if (!strcmp(views[i][0], "profile")) render_profile_states(rig, own, dark);
            szfg_rig_free(rig);
        }
    }
    szfg_set_dark(FALSE);
    szfriends_fake_helper_set_view_fixture(harness->fake, "list", "list.json");
}

void szfg_run_device_probes(void) {
    SZFGHarness *harness = szfg_details_harness("devices");
    szfg_outside_install();
    test_your_computers(harness);
    test_join_rows(harness);
    test_join_page(harness);
    test_join_after_reset(harness);
    test_history_everywhere(harness);
    test_renders(harness);
    szfg_outside_uninstall();
    szfg_harness_free(harness);
}
