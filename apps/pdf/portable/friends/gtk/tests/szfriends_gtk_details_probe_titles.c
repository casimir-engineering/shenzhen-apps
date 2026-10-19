/* Every page of the dropdown has a name from the moment it exists (UX verification, wave 6d): libadwaita warns about
 * an AdwNavigationPage mapped without a title, which Shenzhen Files printed each time its popover opened before the
 * helper had answered, and assistive technology announces a page by that name. Each page is rendered here, which
 * maps it as the popover would, both before any helper answers and on a ready link before the page's snapshot. */

#include "szfriends_gtk_details_probe.h"

#include <string.h>

static const char *page_name(SZFGRig *rig) {
    GtkWidget *page = szfg_rig_page(rig);
    return page && ADW_IS_NAVIGATION_PAGE(page) ? adw_navigation_page_get_title(ADW_NAVIGATION_PAGE(page)) : NULL;
}

/* The top page has a name, is mapped without a warning, and returns that name. */
static char *check_page(SZFGRig *rig, const char *what, const char *render) {
    const char *name = page_name(rig);
    EXPECT(name && *name, "%s has a name before its words arrive: \"%s\"", what, name ? name : "(none)");
    int before = szfg_unexpected_warnings();
    szfg_rig_render(rig, 480, render);
    EXPECT(szfg_unexpected_warnings() == before, "%s is mapped without a libadwaita warning", what);
    return g_strdup(name);
}

/* No helper answers: the pages carry the connection line, or the app's name, never "". */
static void test_names_without_helper(void) {
    SZFGHarness *harness = szfg_harness_new("titles", FALSE);
    SZFGRig *rig = szfg_rig_new(harness);
    char *list = check_page(rig, "the list", "titles-no-helper-list");
    const char *status = szfriends_gtk_link_status_text(harness->link);
    EXPECT(!g_strcmp0(list, status && *status ? status : harness->host.app_name),
           "named after what the person is waiting for: \"%s\" (status \"%s\")", list, status ? status : "");
    szfriends_gtk_dropdown_open_conversation(rig->dropdown, "c_mei", NULL);
    g_free(check_page(rig, "a conversation", "titles-no-helper-conversation"));
    szfriends_gtk_dropdown_open_details(rig->dropdown, "c_mei");
    g_free(check_page(rig, "a friend's details", "titles-no-helper-details"));
    szfriends_gtk_dropdown_pop_to_list(rig->dropdown);
    szfriends_gtk_dropdown_open_profile(rig->dropdown);
    g_free(check_page(rig, "the profile", "titles-no-helper-profile"));
    g_free(list);
    szfg_rig_free(rig);
    szfg_harness_free(harness);
}

static gboolean named_mei(gpointer data) {
    return !g_strcmp0(page_name(data), "Mei Lin");
}

/* A ready link: until a page's snapshot names it, it carries the Friends button's name; then the snapshot's. */
static void test_names_before_snapshot(void) {
    SZFGHarness *harness = szfg_details_harness("titles-ready");
    SZFGRig *rig = szfg_rig_new(harness);
    const char *button = szfriends_gtk_link_string(harness->link, "button_label");
    szfriends_gtk_dropdown_open_details(rig->dropdown, "c_mei");
    char *details = check_page(rig, "a friend's details on a ready link", "titles-ready-details");
    EXPECT(!strcmp(details, button) || !strcmp(details, "Mei Lin"), "the button's name, then Mei's: \"%s\"", details);
    EXPECT(szfg_pump_until(named_mei, rig, 3000), "the snapshot names the page: \"%s\"", page_name(rig));
    g_free(details);
    szfg_rig_free(rig);
    szfg_harness_free(harness);
}

void szfg_run_title_probes(void) {
    test_names_without_helper();
    test_names_before_snapshot();
}
