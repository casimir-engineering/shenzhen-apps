/* A friend's details offscreen, against the fake helper: the `details` subscription held only while on screen,
 * every field of details-mei.json drawn as plain text, the route's icon before its words, Copy, Show in Finder
 * through the host, automatic acceptance sent and put back when refused, Delete chat history and Remove asked first
 * in a card, Block armed by a first click and sent by a second, separate one (never a double-click's second half),
 * turned back by Escape, by leaving it or after arm.seconds, a changed key leading the page, and the server's check.
 * Time is the hand-moved clock's, as for the list's Block. Renders light and dark, plain and with a changed key, and
 * measures the secondary text's contrast in each and that the text actions and their notes start at the column's
 * edge. */

#include "szfriends_gtk_details_probe.h"

#include "gtk/szfriends_gtk_glyphs.h"

#include <string.h>

static const char *const kBlock = "Block Mei";

static JsonObject *with_key_change(void) {
    JsonObject *data = szfg_fixture_data("snapshots/details-mei.json");
    JsonObject *key = json_object_new(), *action = json_object_new(), *arm = json_object_new();
    json_object_set_string_member(key, "title", "Mei’s key changed");
    json_object_set_string_member(key, "body", "Compare codes with Mei before you go on.");
    json_object_set_string_member(action, "action", "block");
    json_object_set_string_member(action, "label", kBlock);
    json_object_set_string_member(action, "style", "destructive");
    json_object_set_string_member(arm, "label", "Block?");
    json_object_set_string_member(arm, "accessibility_label", "Click again to block Mei");
    json_object_set_int_member(arm, "seconds", 1);
    json_object_set_object_member(action, "arm", arm);
    JsonArray *actions = json_array_new();
    json_array_add_object_element(actions, action);
    json_object_set_array_member(key, "actions", actions);
    json_object_set_object_member(data, "key_change", key);
    /* A changed key leaves Mei unverified until the codes are compared again. */
    JsonObject *verification = json_object_get_object_member(data, "verification"), *mark = json_object_new();
    json_object_set_string_member(verification, "state", "unverified");
    json_object_set_string_member(verification, "label", "Not verified");
    json_object_set_string_member(verification, "body", "Check that Mei sees the same code on her Mac.");
    json_object_set_string_member(verification, "comparison_code", "418 270");
    json_object_set_string_member(mark, "action", "mark_verified");
    json_object_set_string_member(mark, "label", "Codes match");
    json_object_set_string_member(mark, "style", "secondary");
    json_object_set_object_member(verification, "action", mark);
    json_object_set_boolean_member(data, "id_confirmed", TRUE);
    json_object_set_string_member(data, "id_confirmed_label", "ID confirmed by the Friends server");
    /* An action from a newer helper that this view does not know is left out, not drawn as a dead button. */
    JsonObject *unknown = json_object_new();
    json_object_set_string_member(unknown, "action", "wave_hello");
    json_object_set_string_member(unknown, "label", "Wave to Mei");
    json_object_set_string_member(unknown, "style", "primary");
    json_array_add_object_element(json_object_get_array_member(data, "actions"), unknown);
    /* A name with markup in it stays text: a Pango tag here would make it bold or break it. */
    json_object_set_string_member(data, "title", "<b>Mei</b> & Lin");
    return data;
}

static GtkWidget *open_details(SZFGRig *rig) {
    szfriends_gtk_dropdown_open_details(rig->dropdown, "c_mei");
    GtkWidget *page = szfg_rig_page(rig);
    EXPECT(szfg_wait_label(page, "ID jasmine‑street"), "the details snapshot is drawn");
    return page;
}

static void test_fields(SZFGHarness *harness, SZFGRig *rig, GtkWidget *page) {
    JsonObject *subscribe = szfg_fake_last_frame(harness, "subscribe");
    JsonObject *params = subscribe ? json_object_get_object_member(subscribe, "params") : NULL;
    EXPECT(params && !g_strcmp0(json_object_get_string_member(params, "conversation_id"), "c_mei"),
           "for this friend's conversation");
    if (subscribe) json_object_unref(subscribe);
    EXPECT(!g_strcmp0(adw_navigation_page_get_title(ADW_NAVIGATION_PAGE(page)), "Mei Lin"), "the title is the name");
    GtkWidget *route = szfg_find_label(page, "Nearby, on your network");
    EXPECT(route && gtk_widget_has_css_class(route, "success"), "the route, green while local");
    EXPECT(szfg_find_label(page, "ID jasmine‑street") != NULL, "the ID line, its hyphen unbreakable");
    GtkWidget *copy = szfg_find_named(page, "szfriends.details.copy");
    EXPECT(copy && gtk_widget_get_visible(copy) && !g_strcmp0(gtk_widget_get_tooltip_text(copy), "Copy Mei’s ID"),
           "Copy, named for whose ID it copies");
    if (copy) g_signal_emit_by_name(copy, "clicked");
    EXPECT(szfg_outside.copied && szfg_outside.copied->len == 1 &&
               !strcmp(g_ptr_array_index(szfg_outside.copied, 0), "jasmine-street"),
           "Copy takes the ASCII ID, the one people paste");
    GtkWidget *glyph = copy ? gtk_button_get_child(GTK_BUTTON(copy)) : NULL;
    EXPECT(GTK_IS_IMAGE(glyph) && !g_strcmp0(gtk_image_get_icon_name(GTK_IMAGE(glyph)), "object-select-symbolic") &&
               gtk_image_get_pixel_size(GTK_IMAGE(glyph)) == 12, "and the button says it worked, at its own size");
    GtkWidget *automatic = szfg_find_named(page, "szfriends.details.auto-accept");
    EXPECT(automatic && gtk_switch_get_active(GTK_SWITCH(automatic)) && gtk_widget_get_sensitive(automatic),
           "automatic acceptance on and available");
    EXPECT(szfg_find_label(page, "Accept files from Mei automatically") != NULL, "its title from the helper");
    GtkWidget *show = szfg_find_button(page, "Show in Finder");
    if (show) g_signal_emit_by_name(show, "clicked");
    EXPECT(szfg_outside.revealed && szfg_outside.revealed->len == 1 &&
               !g_strcmp0(g_ptr_array_index(szfg_outside.revealed, 0), "/Users/raph/Downloads"),
           "Show in Finder goes to the host with the folder's path");
    EXPECT(szfg_find_label(page, "Keeps your conversation. Mei can send you a new request.") != NULL,
           "each action's note under it");
    (void)rig;
}

/* The route's icon stands before its words, one per method, as in the conversation header; kind none, nothing. */
static void test_route_icon(SZFGHarness *harness, GtkWidget *page) {
    static const struct {
        const char *kind, *method, *label;
        SZFriendsGtkGlyphKind glyph;
    } routes[] = {
        {"local", "bluetooth", "Nearby, over Bluetooth", SZFRIENDS_GTK_GLYPH_ROUTE_BLUETOOTH},
        {"online", "relay", "Online, through the Friends relay", SZFRIENDS_GTK_GLYPH_ROUTE_RELAY},
        {"offline", NULL, "Not nearby right now", SZFRIENDS_GTK_GLYPH_ROUTE_OFFLINE},
        {"local", "lan", "Nearby, on your network", SZFRIENDS_GTK_GLYPH_ROUTE_LAN},
    };
    GtkWidget *line = szfg_find_named(page, "szfriends.details.route");
    GtkWidget *glyph = line ? gtk_widget_get_first_child(line) : NULL;
    for (gsize i = 0; i < G_N_ELEMENTS(routes) && glyph; i++) {
        JsonObject *data = szfg_fixture_data("snapshots/details-mei.json");
        JsonObject *route = json_object_get_object_member(data, "route");
        json_object_set_string_member(route, "kind", routes[i].kind);
        if (routes[i].method) json_object_set_string_member(route, "method", routes[i].method);
        else json_object_set_null_member(route, "method");
        json_object_set_string_member(route, "label", routes[i].label);
        szfg_script_view(harness, "details", data);
        json_object_unref(data);
        GtkWidget *words = szfg_wait_label(page, routes[i].label) ? szfg_find_label(page, routes[i].label) : NULL;
        graphene_rect_t icon_box, words_box;
        EXPECT(words && gtk_widget_get_parent(words) == line && gtk_widget_get_visible(glyph) &&
                   szfriends_gtk_glyph_get_kind(glyph) == routes[i].glyph &&
                   gtk_widget_compute_bounds(glyph, page, &icon_box) &&
                   gtk_widget_compute_bounds(words, page, &words_box) &&
                   icon_box.origin.x + icon_box.size.width <= words_box.origin.x,
               "details: %s's icon before \"%s\"", routes[i].method ? routes[i].method : routes[i].kind,
               routes[i].label);
    }
    EXPECT(glyph != NULL, "the details page has a route line with an icon");
}

static gboolean switch_on(gpointer data) {
    return gtk_switch_get_active(GTK_SWITCH(data));
}

static void test_auto_accept(SZFGHarness *harness, GtkWidget *page) {
    GtkWidget *automatic = szfg_find_named(page, "szfriends.details.auto-accept");
    szfriends_fake_helper_set_reply(harness->fake, "set_auto_accept",
                                    "{\"type\":\"reply\",\"re\":\"0\",\"ok\":false,\"error\":{\"code\":\"not_allowed\","
                                    "\"message\":null,\"retryable\":false,\"details\":{}}}");
    szfg_pump_for(50);
    gtk_switch_set_active(GTK_SWITCH(automatic), FALSE);
    EXPECT(szfg_wait_frames(harness, "set_auto_accept", "conversation_id", "c_mei", 1), "the switch asks the helper");
    JsonObject *frame = szfg_fake_last_frame(harness, "set_auto_accept");
    EXPECT(frame && !json_object_get_boolean_member(frame, "enabled"), "to turn it off");
    if (frame) json_object_unref(frame);
    EXPECT(szfg_pump_until(switch_on, automatic, 3000), "refused, the switch goes back to what the helper says");
    szfriends_fake_helper_set_reply(harness->fake, "set_auto_accept", NULL);
}

/* Delete chat history… asks first in the same card, with the helper's question word for word; Cancel sends nothing,
 * and confirming sends delete_history for Mei's chat alone. */
static void test_delete_history(SZFGHarness *harness, SZFGRig *rig, GtkWidget *page) {
    GtkWidget *delete = szfg_find_button(page, "Delete chat history…");
    EXPECT(delete && gtk_widget_has_css_class(delete, "error") &&
               szfg_find_label(page, "Clears this chat on this computer. Mei stays your friend."),
           "Delete chat history… is drawn destructive, with what it does under it");
    szfg_press(delete, 1);
    GtkWidget *card = szfriends_gtk_dropdown_get_overlay(rig->dropdown);
    EXPECT(card && szfg_find_label(card, "Delete your chat history with Mei?") &&
               szfg_find_label(card, "Your messages and file history with Mei are deleted from this computer, and "
                                     "anything still waiting to go to Mei won’t be sent. Mei stays your friend and "
                                     "keeps their own copy of the chat. Files you received stay where they were saved.") &&
               szfg_fake_frames(harness, "delete_history", NULL, NULL) == 0,
           "it asks first, saying what goes and what stays, and sends nothing yet");
    GtkWidget *cancel = card ? szfg_find_named(card, "szfriends.confirmation.cancel") : NULL;
    if (cancel) g_signal_emit_by_name(cancel, "clicked");
    szfg_pump_for(50);
    EXPECT(!szfriends_gtk_dropdown_get_overlay(rig->dropdown) &&
               szfg_fake_frames(harness, "delete_history", NULL, NULL) == 0, "Cancel sends nothing");
    szfg_press(delete, 1);
    card = szfriends_gtk_dropdown_get_overlay(rig->dropdown);
    GtkWidget *ok = card ? szfg_find_named(card, "szfriends.confirmation.confirm") : NULL;
    EXPECT(ok && gtk_widget_has_css_class(ok, "destructive-action") &&
               !g_strcmp0(gtk_button_get_label(GTK_BUTTON(ok)), "Delete History"), "it confirms in red");
    if (ok) g_signal_emit_by_name(ok, "clicked");
    EXPECT(szfg_wait_frames(harness, "delete_history", "conversation_id", "c_mei", 1) &&
               szfg_fake_frames(harness, "delete_history", NULL, NULL) == 1, "confirming deletes Mei's chat only");
    JsonObject *frame = szfg_fake_last_frame(harness, "delete_history");
    EXPECT(frame && !g_strcmp0(json_object_get_string_member_with_default(frame, "conversation_id", ""), "c_mei"),
           "the frame names Mei's chat");
    if (frame) json_object_unref(frame);
}

static void test_remove(SZFGHarness *harness, SZFGRig *rig, GtkWidget *page) {
    GtkWidget *remove = szfg_find_button(page, "Remove friend");
    EXPECT(remove && gtk_widget_has_css_class(remove, "error"), "Remove is drawn destructive");
    szfg_press(remove, 1);
    GtkWidget *card = szfriends_gtk_dropdown_get_overlay(rig->dropdown);
    EXPECT(card && szfg_find_label(card, "Remove Mei as a friend?") && szfg_fake_frames(harness, "remove_friend",
                                                                                         NULL, NULL) == 0,
           "Remove asks first, in a card over the page, and sends nothing yet");
    GtkWidget *body = szfg_find_label(card, "Mei isn’t told. Your conversation stays, and Mei can send you a new "
                                            "request. Anything still waiting to go to Mei won’t be sent.");
    GtkWidget *measured[] = {body, NULL};
    double contrast[1] = {0};
    szfg_rig_render_contrast(rig, 560, "details-remove-light", measured, contrast);
    EXPECT(body && contrast[0] >= 4.5, "the question's body reads at %.2f:1, at least 4.5:1", contrast[0]);
    GtkWidget *cancel = szfg_find_named(card, "szfriends.confirmation.cancel");
    if (cancel) g_signal_emit_by_name(cancel, "clicked");
    EXPECT(!szfriends_gtk_dropdown_get_overlay(rig->dropdown), "Cancel takes the question away");
    szfg_press(remove, 1);
    card = szfriends_gtk_dropdown_get_overlay(rig->dropdown);
    GtkWidget *ok = card ? szfg_find_named(card, "szfriends.confirmation.confirm") : NULL;
    EXPECT(ok && gtk_widget_has_css_class(ok, "destructive-action"), "a destructive question confirms in red");
    if (ok) g_signal_emit_by_name(ok, "clicked");
    EXPECT(szfg_wait_frames(harness, "remove_friend", "conversation_id", "c_mei", 1), "confirming removes Mei");
    EXPECT(!szfriends_gtk_dropdown_get_overlay(rig->dropdown), "and the card goes");
}

static void test_block(SZFGHarness *harness, SZFGRig *rig, GtkWidget *page) {
    GtkWidget *block = szfg_find_button(page, kBlock);
    EXPECT(block && gtk_widget_has_css_class(block, "error"), "Block is drawn destructive");
    if (!block) return;
    szfg_press(block, 1);
    EXPECT(szfriends_gtk_details_button_is_armed(block) && szfg_find_button(page, "Block?") == block &&
               gtk_widget_has_css_class(block, "destructive-action") &&
               !g_strcmp0(gtk_widget_get_tooltip_text(block), "Click again to block Mei") &&
               szfg_fake_frames(harness, "block", NULL, NULL) == 0,
           "the first click arms a red Block? and sends nothing");
    szfg_press(block, 2);
    EXPECT(szfriends_gtk_details_button_is_armed(block) && szfg_fake_frames(harness, "block", NULL, NULL) == 0,
           "a double-click's second half does nothing");
    szfriends_gtk_dropdown_escape(rig->dropdown);
    EXPECT(!szfriends_gtk_details_button_is_armed(block) && szfriends_gtk_dropdown_is_open(rig->dropdown) &&
               szfg_find_button(page, kBlock) == block, "Escape turns the pill back before it closes anything");
    szfg_press(block, 1);
    szfg_leave(block);
    EXPECT(!szfriends_gtk_details_button_is_armed(block), "leaving the button turns it back");
    /* A snapshot that changed something else keeps the armed button. */
    szfg_press(block, 1);
    JsonObject *data = szfg_fixture_data("snapshots/details-mei.json");
    JsonObject *route = json_object_get_object_member(data, "route");
    json_object_set_string_member(route, "label", "Nearby, over Bluetooth");
    szfg_script_view(harness, "details", data);
    json_object_unref(data);
    EXPECT(szfg_wait_label(page, "Nearby, over Bluetooth") && szfg_find_button(page, "Block?") == block &&
               szfriends_gtk_details_button_is_armed(block), "an unchanged action keeps its armed pill");
    szfg_clock_advance_ms(szfriends_gtk_double_click_us(block) / 1000 - 1);
    szfg_press(block, 1);
    EXPECT(szfriends_gtk_details_button_is_armed(block) && szfg_fake_frames(harness, "block", NULL, NULL) == 0,
           "a press within the double-click time of arming is half a double-click: still armed, nothing sent");
    szfg_clock_advance_ms(2); /* past the double-click time: the next press is a deliberate second click */
    szfg_press(block, 1);
    EXPECT(szfg_wait_frames(harness, "block", "conversation_id", "c_mei", 1), "a separate second click blocks Mei");
}

static void test_key_change(SZFGHarness *harness, SZFGRig *rig, GtkWidget *page) {
    JsonObject *data = with_key_change();
    szfg_script_view(harness, "details", data);
    json_object_unref(data);
    EXPECT(szfg_wait_label(page, "Mei’s key changed"), "a changed key shows its card");
    GtkWidget *card = szfg_find_named(page, "szfriends.details.key-change");
    GtkWidget *verification = szfg_find_label(page, "Not verified");
    graphene_rect_t key, verify;
    EXPECT(card && verification && gtk_widget_get_visible(card), "beside the verification");
    GtkWidget *code = szfg_find_label(page, "418 270");
    EXPECT(code && gtk_widget_get_visible(code) && gtk_widget_has_css_class(code, "numeric") &&
               !gtk_widget_has_css_class(verification, "success"), "the comparison code, large, while unverified");
    GtkWidget *match = szfg_find_button(page, "Codes match");
    if (match) szfg_press(match, 1);
    EXPECT(match && szfg_wait_frames(harness, "mark_verified", "conversation_id", "c_mei", 1),
           "Codes match marks Mei verified");
    EXPECT(!g_strcmp0(adw_navigation_page_get_title(ADW_NAVIGATION_PAGE(page)), "<b>Mei</b> & Lin"),
           "a title with markup characters stays as typed");
    GtkWidget *check = szfg_find_label(page, "ID confirmed by the Friends server");
    EXPECT(check && gtk_widget_get_visible(check), "the server's check is explained under the ID");
    EXPECT(!szfg_find_label(page, "Wave to Mei") && szfg_find_button(page, "Remove friend"),
           "an action this view does not know is left out; the others stay");
    GtkWidget *content = szfriends_gtk_dropdown_get_content(rig->dropdown), *window = szfg_probe_window(content);
    szfg_layout(window, 400, 640);
    EXPECT(card && verification && gtk_widget_compute_bounds(card, page, &key) &&
               gtk_widget_compute_bounds(verification, page, &verify) && key.origin.y < verify.origin.y,
           "the key-change card leads, before verification");
    g_object_ref(content);
    gtk_window_set_child(GTK_WINDOW(window), NULL);
    gtk_window_destroy(GTK_WINDOW(window));
    g_object_unref(content);
    GtkWidget *block = szfg_find_button(card, kBlock);
    if (block) szfg_press(block, 1);
    EXPECT(block && szfriends_gtk_details_button_is_armed(block) && szfg_clock_live(1000) == 1,
           "the card's Block arms the same way, for the snapshot's 1 second");
    EXPECT(szfg_clock_fire(1000) && block && !szfriends_gtk_details_button_is_armed(block) &&
               szfg_find_button(card, kBlock) == block, "and turns back by itself after arm.seconds");
}

static void render_fresh(SZFGHarness *harness, gboolean dark, gboolean key_change, const char *name) {
    szfg_set_dark(dark);
    if (key_change) {
        JsonObject *data = with_key_change();
        szfg_script_view(harness, "details", data);
        json_object_unref(data);
    } else {
        szfriends_fake_helper_set_view_fixture(harness->fake, "details", "details-mei.json");
    }
    szfg_pump_for(50);
    SZFGRig *rig = szfg_rig_new(harness);
    GtkWidget *page = open_details(rig);
    if (key_change) EXPECT(szfg_wait_label(page, "Mei’s key changed") && !szfg_find_label(page, "Wave to Mei") &&
                               szfg_find_label(page, "418 270"),
                           "%s: the scripted key change, without the action this view does not know", name);
    /* Secondary text reads at WCAG AA (4.5:1 for text of 11 to 13 px): what Remove and Block do, the ID line, the
     * server's check, the verification and automatic acceptance notes (UX review, wave 6b: .dimmed drew 3.2:1). */
    GtkWidget *labels[] = {szfg_find_label(page, "Keeps your conversation. Mei can send you a new request."),
                           szfg_find_label(page, "Mei can’t reach you or send requests until you unblock."),
                           szfg_find_label(page, "ID jasmine‑street"),
                           szfg_find_label(page, key_change ? "ID confirmed by the Friends server"
                                                            : "Received from Mei: 14 files"),
                           szfg_find_label(page, key_change ? "Check that Mei sees the same code on her Mac."
                                                            : "Files from Mei download without asking. They’re saved "
                                                              "where other received files go and never open by "
                                                              "themselves."),
                           NULL};
    double contrast[G_N_ELEMENTS(labels)] = {0};
    /* Taller with a changed key: its card and three actions run past 640 px, where the page scrolls. */
    szfg_rig_render_contrast(rig, key_change ? 800 : 640, name, labels, contrast);
    for (gsize i = 0; i + 1 < G_N_ELEMENTS(labels); i++)
        EXPECT(labels[i] && contrast[i] >= 4.5, "%s: secondary text %zu reads at %.2f:1, at least 4.5:1", name, i,
               contrast[i]);
    /* The notes are body size, as AppKit draws them, and the text actions start at the column's edge, the avatar's,
     * with their notes under their first letter (UX review, wave 6b: 17 px of button padding pushed them in). */
    GtkWidget *remove = szfg_find_button(page, "Remove friend"), *avatar = szfg_find_css_name(page, "szfriends-avatar");
    EXPECT(labels[0] && !gtk_widget_has_css_class(labels[0], "caption") &&
               !gtk_widget_has_css_class(labels[0], "szfriends-caption"),
           "%s: the consequence notes are body size", name);
    GtkWidget *content = szfriends_gtk_dropdown_get_content(rig->dropdown), *window = szfg_probe_window(content);
    szfg_layout(window, 400, 640);
    EXPECT(remove && szfg_same_left(page, gtk_button_get_child(GTK_BUTTON(remove)), avatar) &&
               szfg_same_left(page, labels[0], avatar), "%s: Remove friend and its note start at the column's edge",
           name);
    GtkWidget *card = szfg_find_named(page, "szfriends.details.key-change");
    GtkWidget *card_block = key_change ? szfg_find_button(card, kBlock) : NULL;
    GtkWidget *card_words = szfg_find_label(card, "Compare codes with Mei before you go on.");
    EXPECT(!key_change ||
               (card_block && szfg_same_left(page, gtk_button_get_child(GTK_BUTTON(card_block)), card_words)),
           "%s: the key-change card's Block starts where its words do", name);
    g_object_ref(content);
    gtk_window_set_child(GTK_WINDOW(window), NULL);
    gtk_window_destroy(GTK_WINDOW(window));
    g_object_unref(content);
    szfg_rig_free(rig);
    szfg_set_dark(FALSE);
}

void szfg_run_details_probes(void) {
    SZFGHarness *harness = szfg_details_harness("details");
    szfg_outside_install();
    render_fresh(harness, FALSE, FALSE, "details-light");
    render_fresh(harness, TRUE, FALSE, "details-dark");
    render_fresh(harness, FALSE, TRUE, "details-key-change-light");
    render_fresh(harness, TRUE, TRUE, "details-key-change-dark");
    szfriends_fake_helper_set_view_fixture(harness->fake, "details", "details-mei.json");
    SZFGRig *rig = szfg_rig_new(harness);
    guint subscribed = szfg_fake_frames(harness, "subscribe", "view", "details");
    GtkWidget *page = open_details(rig);
    EXPECT(szfg_fake_frames(harness, "subscribe", "view", "details") == subscribed + 1, "one subscription");
    test_fields(harness, rig, page);
    test_route_icon(harness, page);
    test_auto_accept(harness, page);
    test_delete_history(harness, rig, page);
    test_remove(harness, rig, page);
    test_block(harness, rig, page);
    test_key_change(harness, rig, page);
    guint unsubscribed = szfg_fake_frames(harness, "unsubscribe", NULL, NULL);
    szfriends_gtk_dropdown_close(rig->dropdown);
    EXPECT(szfg_wait_frames(harness, "unsubscribe", NULL, NULL, unsubscribed + 1),
           "closing the dropdown lets the subscription go");
    szfg_rig_free(rig);
    szfg_outside_uninstall();
    szfg_harness_free(harness);
}
