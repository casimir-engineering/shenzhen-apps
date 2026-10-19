/* Links offscreen, against the fake helper (PROTOCOL.md § Links): a host's szfriends_gtk_show_link opens the window's
 * dropdown on the link page, which asks open_link and sends nothing else until the card's Add, whose payload goes as
 * it is and whose reply opens the conversation; Your links in the profile copies the friend link, asks before Reset
 * link and revokes a download link by its own id; Copy Download Link puts the helper's URL on the clipboard. Renders
 * the link page and the profile's links in light and dark, and checks each follows the appearance. */

#include "szfriends_gtk_details_probe.h"
#include "gtk/szfriends_gtk_link_private.h"

#include <string.h>

static const char *const payload = "f.AbTdSXSAjDJSLILKcnTFnJ61gwHnPY127KX0X8oI-0OqyMnKy8zNzs_Q0dLT1NXW1w1ib25maXJlLW90"
                                   "dGVyCExlbyBQYXJr";

static void present(SZFriendsGtkDropdown *dropdown, gpointer data) {
    (void)dropdown, (void)data;
}

static void dismiss(SZFriendsGtkDropdown *dropdown, gpointer data) {
    (void)data;
    szfriends_gtk_dropdown_presenter_closed(dropdown);
}

/* A window the way a host adds it (link_add_window), its dropdown shown through a presenter that shows nothing. */
static SZFriendsGtkDropdown *host_window(SZFGHarness *harness, GtkWidget **window_out) {
    GtkWidget *window = gtk_window_new();
    szfriends_gtk_link_add_window(harness->link, GTK_WINDOW(window));
    GtkWidget *button = szfriends_gtk_link_window_button(harness->link, GTK_WINDOW(window));
    gtk_window_set_child(GTK_WINDOW(window), button);
    SZFriendsGtkDropdown *dropdown = szfriends_gtk_dropdown_for_button(button);
    static const SZFriendsGtkPresenter presenter = {present, dismiss};
    szfriends_gtk_dropdown_set_presenter(dropdown, &presenter, NULL);
    *window_out = window;
    return dropdown;
}

static GtkWidget *top_widget(SZFriendsGtkDropdown *dropdown) {
    SZFriendsGtkPage *page = szfriends_gtk_dropdown_get_top_page(dropdown);
    return page ? szfriends_gtk_page_get_widget(page) : NULL;
}

static gboolean shows_conversation(gpointer data) {
    SZFriendsGtkPage *page = szfriends_gtk_dropdown_get_top_page(data);
    return page && szfriends_gtk_page_get_kind(page) == SZFRIENDS_GTK_PAGE_CONVERSATION;
}

/* Renders the dropdown at 400 x 640 and returns the colour near its bottom right corner, the page's own background. */
static guint32 render(SZFriendsGtkDropdown *dropdown, const char *name) {
    GtkWidget *content = szfriends_gtk_dropdown_get_content(dropdown);
    GtkWidget *window = szfg_probe_window(content);
    GdkTexture *texture = szfg_render(window, 400, 640, name);
    SZFGPixels pixels = szfg_pixels(texture);
    const guint8 *pixel = szfg_pixel(&pixels, pixels.width - 8, pixels.height - 8);
    guint32 colour = ((guint32)pixel[0] << 16) | ((guint32)pixel[1] << 8) | pixel[2];
    szfg_pixels_free(&pixels);
    g_object_unref(texture);
    g_object_ref(content);
    gtk_window_set_child(GTK_WINDOW(window), NULL);
    gtk_window_destroy(GTK_WINDOW(window));
    g_object_unref(content);
    return colour;
}

static void test_link_page(SZFGHarness *harness) {
    GtkWidget *window = NULL;
    SZFriendsGtkDropdown *dropdown = host_window(harness, &window);
    szfriends_gtk_show_link(harness->link, GTK_WINDOW(window), payload);
    EXPECT(szfriends_gtk_dropdown_is_open(dropdown), "the link opens the window's dropdown");
    SZFriendsGtkPage *page = szfriends_gtk_dropdown_get_top_page(dropdown);
    EXPECT(page && szfriends_gtk_page_get_kind(page) == SZFRIENDS_GTK_PAGE_LINK, "on the link page");
    EXPECT(szfg_wait_frames(harness, "open_link", "payload", payload, 1), "open_link with the payload as it came");
    EXPECT(szfg_wait_label(top_widget(dropdown), "Add Leo Park?"), "the helper's card is drawn");
    EXPECT(szfg_find_label(top_widget(dropdown), "Friends ID bonfire‑otter") != NULL, "with its subtitle");
    /* The scheme handler never acts by itself: nothing but the question went to the helper. */
    EXPECT(szfg_fake_frames(harness, "add_from_link", NULL, NULL) == 0, "nothing added before Add");
    GtkWidget *add = szfg_find_button(top_widget(dropdown), "Add");
    EXPECT(add != NULL, "the card's Add");
    if (add) g_signal_emit_by_name(add, "clicked");
    EXPECT(add && !gtk_widget_get_sensitive(add), "Add rests until the reply, so a double click asks once");
    EXPECT(szfg_wait_frames(harness, "add_from_link", "payload", payload, 1), "Add sends the card's payload");
    EXPECT(szfg_pump_until(shows_conversation, dropdown, 5000), "the reply opens the request's conversation");
    gtk_window_destroy(GTK_WINDOW(window));
    szfg_pump_for(20);
}

static void copied(const char *message, gboolean ok, gpointer data) {
    char **shown = data;
    *shown = g_strdup(ok && message ? message : "(not copied)");
}

static gboolean answered(gpointer data) {
    return *(char **)data != NULL;
}

static void test_copy_download_link(SZFGHarness *harness) {
    GtkWidget *source = gtk_label_new("");
    g_object_ref_sink(source);
    SZFriendsGtkHostItem *item = szfriends_gtk_host_item_new("Site photos.pdf", "", "PDF",
                                                             "/Users/raph/Documents/Site photos.pdf", NULL);
    char *shown = NULL;
    szfriends_gtk_copy_download_link(harness->link, source, item, 30, copied, &shown);
    EXPECT(szfg_pump_until(answered, &shown, 5000), "Copy Download Link answers");
    JsonObject *frame = szfg_fake_last_frame(harness, "make_download_link");
    JsonObject *file = frame ? json_object_get_object_member(frame, "file") : NULL;
    EXPECT(frame && json_object_get_int_member_with_default(frame, "expires_days", 0) == 30 && file &&
               !g_strcmp0(json_object_get_string_member_with_default(file, "path", ""),
                          "/Users/raph/Documents/Site photos.pdf"),
           "make_download_link with the file and the expiry");
    EXPECT(shown && g_str_has_prefix(shown, "Download link copied"), "the helper's words: %s", shown);
    const char *last = szfg_outside.copied && szfg_outside.copied->len
                           ? g_ptr_array_index(szfg_outside.copied, szfg_outside.copied->len - 1) : "";
    EXPECT(g_str_has_prefix(last, "https://friends.example/d#"), "the link on the clipboard: %s", last);
    if (frame) json_object_unref(frame);
    g_free(shown);
    szfriends_gtk_host_item_free(item);
    g_object_unref(source);
}

static GtkWidget *open_links(SZFGRig *rig) {
    szfriends_gtk_dropdown_open_profile(rig->dropdown);
    GtkWidget *page = szfg_rig_page(rig);
    EXPECT(szfg_wait_label(page, "Your links"), "the profile's links are drawn");
    return page;
}

static void test_your_links(SZFGHarness *harness) {
    SZFGRig *rig = szfg_rig_new(harness);
    GtkWidget *page = open_links(rig);
    EXPECT(szfg_find_label(page, "Site photos.pdf") && szfg_find_label(page, "3 downloads · Expires in 6 days"),
           "a download link's file, downloads and expiry");
    g_signal_emit_by_name(szfg_find_named(page, "szfriends.profile.links.copy"), "clicked");
    const char *last = szfg_outside.copied->len ? g_ptr_array_index(szfg_outside.copied, szfg_outside.copied->len - 1)
                                                : "";
    EXPECT(g_str_has_prefix(last, "https://friends.example/f#"), "Copy takes the friend link: %s", last);
    GtkWidget *reset = szfg_find_button(page, "Reset link");
    if (reset) szfg_press(reset, 1);
    GtkWidget *card = szfriends_gtk_dropdown_get_overlay(rig->dropdown);
    EXPECT(card && szfg_find_label(card, "Reset your friend link?") &&
               szfg_fake_frames(harness, "reset_friend_link", NULL, NULL) == 0,
           "Reset link asks first and sends nothing yet");
    GtkWidget *ok = card ? szfg_find_named(card, "szfriends.confirmation.confirm") : NULL;
    if (ok) g_signal_emit_by_name(ok, "clicked");
    EXPECT(szfg_wait_frames(harness, "reset_friend_link", NULL, NULL, 1), "and resets on the confirm button");
    GtkWidget *revoke = szfg_find_named(page, "szfriends.profile.links.revoke");
    EXPECT(revoke != NULL, "Revoke beside each link");
    if (revoke) szfg_press(revoke, 1);
    EXPECT(szfg_wait_frames(harness, "revoke_link", "link_id", "EBESExQVFhcYGRobHB0eHw", 1),
           "Revoke sends that link's own id");
    szfg_rig_free(rig);
}

void szfg_run_link_probes(void) {
    SZFGHarness *harness = szfg_details_harness("links");
    szfg_outside_install();
    test_link_page(harness);
    test_copy_download_link(harness);
    szfriends_fake_helper_set_view_fixture(harness->fake, "profile", "profile-links.json");
    test_your_links(harness);
    guint32 backgrounds[2][2];
    for (int dark = 0; dark < 2; dark++) {
        szfg_set_dark(dark);
        szfg_pump_for(50);
        GtkWidget *window = NULL;
        SZFriendsGtkDropdown *dropdown = host_window(harness, &window);
        szfriends_gtk_show_link(harness->link, GTK_WINDOW(window), payload);
        EXPECT(szfg_wait_label(top_widget(dropdown), "Add Leo Park?"), "the card to render");
        backgrounds[0][dark] = render(dropdown, dark ? "link-friend-dark" : "link-friend-light");
        gtk_window_destroy(GTK_WINDOW(window));
        SZFGRig *rig = szfg_rig_new(harness);
        open_links(rig);
        backgrounds[1][dark] = render(rig->dropdown, dark ? "profile-links-dark" : "profile-links-light");
        szfg_rig_free(rig);
    }
    szfg_set_dark(FALSE);
    for (int view = 0; view < 2; view++)
        EXPECT(backgrounds[view][0] != backgrounds[view][1], "%s follows the appearance (%06x, %06x)",
               view ? "Your links" : "the link page", backgrounds[view][0], backgrounds[view][1]);
    szfg_outside_uninstall();
    szfg_harness_free(harness);
}
